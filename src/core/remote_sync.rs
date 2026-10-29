use anyhow::{Context, Result};
use git2::{Cred, CredentialType};
use sha2::{Digest, Sha256};
use std::cell::Cell;
use std::collections::HashMap;
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use super::config::RemoteConfig;
use super::logger::Logger;
use super::net::{self, RemoteScheme};
use super::tools::mobhook_home_from;

const STALE_THRESHOLD: Duration = Duration::from_secs(300); // 5 minutes

/// Remote rule archives are small text bundles; anything larger is refused.
const MAX_ARCHIVE_BYTES: u64 = 20 * 1024 * 1024;
const MAX_EXTRACTED_BYTES: u64 = 100 * 1024 * 1024;
const MAX_ARCHIVE_ENTRIES: usize = 10_000;
/// Deepest directory level indexed under presets/.
const MAX_INDEX_DEPTH: usize = 16;
/// libgit2 re-asks for credentials after a rejected attempt; stop eventually.
const MAX_CREDENTIAL_ATTEMPTS: usize = 3;

pub struct RemoteSync<'a> {
    logger: &'a Logger,
    cache_root: Option<PathBuf>,
}

impl<'a> RemoteSync<'a> {
    pub fn new(logger: &'a Logger) -> Self {
        Self {
            logger,
            cache_root: None,
        }
    }

    /// Use `cache_root` instead of ~/.mobhook/cache.
    pub fn with_cache_root(logger: &'a Logger, cache_root: &Path) -> Self {
        Self {
            logger,
            cache_root: Some(cache_root.to_path_buf()),
        }
    }

    fn cache_base(&self) -> Result<PathBuf> {
        match &self.cache_root {
            Some(root) => Ok(root.clone()),
            None => Ok(mobhook_home_from(dirs::home_dir())?.join("cache")),
        }
    }

    fn cache_dir_for(&self, url: &str) -> Result<PathBuf> {
        let hash: String = Sha256::digest(url.as_bytes())
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect();
        let short = &hash[..12];
        Ok(self.cache_base()?.join(short))
    }

    /// Sync remote and return a map of relative paths to absolute file paths.
    pub fn sync_and_get_files(&self, remote: &RemoteConfig) -> Result<HashMap<String, PathBuf>> {
        let scheme = net::validate_remote_url(&remote.url)?;
        self.warn_if_mutable_ref(&remote.ref_);
        let cache_dir = self.cache_dir_for(&remote.url)?;

        if cache_dir.exists() {
            if !self.is_stale(&cache_dir) {
                self.logger
                    .detail("Using cached remote rules (< 5 min old)");
            } else {
                self.pull(&cache_dir, &remote.ref_)?;
            }
        } else {
            self.clone_repo(&remote.url, scheme, &cache_dir, &remote.ref_)?;
        }

        self.touch_cache(&cache_dir);
        self.index_preset_files(&cache_dir)
    }

    /// Force re-clone (used by `mobhook update`).
    pub fn force_update(&self, remote: &RemoteConfig) -> Result<HashMap<String, PathBuf>> {
        net::validate_remote_url(&remote.url)?;
        let cache_dir = self.cache_dir_for(&remote.url)?;
        if cache_dir.exists() {
            fs::remove_dir_all(&cache_dir)?;
        }
        self.sync_and_get_files(remote)
    }

    fn warn_if_mutable_ref(&self, ref_: &str) {
        if !is_full_commit_sha(ref_) {
            self.logger.warn(&format!(
                "remote.ref {:?} can move; pin a full commit SHA so synced rules cannot change underneath you",
                ref_
            ));
        }
    }

    fn is_stale(&self, cache_dir: &Path) -> bool {
        let stamp = cache_dir.join(".mobhook_fetch_time");
        if !stamp.exists() {
            return true;
        }
        match fs::metadata(&stamp) {
            Ok(meta) => {
                let modified = meta.modified().unwrap_or(SystemTime::UNIX_EPOCH);
                SystemTime::now()
                    .duration_since(modified)
                    .unwrap_or(Duration::MAX)
                    > STALE_THRESHOLD
            }
            Err(_) => true,
        }
    }

    fn touch_cache(&self, cache_dir: &Path) {
        let stamp = cache_dir.join(".mobhook_fetch_time");
        fs::write(&stamp, "").ok();
    }

    fn clone_repo(&self, url: &str, scheme: RemoteScheme, dest: &Path, ref_: &str) -> Result<()> {
        let shown = net::redact_url(url);
        self.logger
            .info(&format!("Cloning remote rules from {shown}..."));
        fs::create_dir_all(dest)?;

        // Try HTTP tarball for archive URLs
        let result = if url.ends_with(".tar.gz") || url.ends_with(".tgz") || url.ends_with(".zip") {
            if scheme == RemoteScheme::Https {
                self.download_tarball(url, dest)
            } else {
                Err(anyhow::anyhow!(
                    "Archive remotes must use https:// ({shown})"
                ))
            }
        } else {
            self.clone_git(url, dest, ref_)
        };

        // Never leave a half-populated cache that a later run would trust.
        // Best effort: the original error is the one worth reporting.
        if result.is_err() {
            fs::remove_dir_all(dest).ok();
        }
        result
    }

    /// Clone with libgit2. Callers validate `url` first (see `clone_repo`).
    fn clone_git(&self, url: &str, dest: &Path, ref_: &str) -> Result<()> {
        let shown = net::redact_url(url);
        let repo = git2::build::RepoBuilder::new()
            .fetch_options(fetch_options())
            .clone(url, dest)
            .with_context(|| format!("Failed to clone {shown}"))?;

        let (object, reference) = repo
            .revparse_ext(ref_)
            .with_context(|| format!("Failed to find ref '{ref_}'"))?;

        repo.checkout_tree(&object, None)
            .with_context(|| format!("Failed to checkout '{ref_}'"))?;

        match reference {
            Some(gref) => {
                let name = gref.name().unwrap_or(ref_);
                repo.set_head(name)?;
            }
            None => {
                repo.set_head_detached(object.id())?;
            }
        }

        self.logger.success("Cloned remote rules");
        Ok(())
    }

    fn pull(&self, dir: &Path, ref_: &str) -> Result<()> {
        self.logger.info("Updating remote rules...");

        let repo = git2::Repository::open(dir).context("Failed to open cached remote repo")?;

        let mut remote = repo
            .find_remote("origin")
            .context("Failed to find 'origin' remote")?;

        // A pinned commit never changes: only fetch if the cache lacks it.
        if is_full_commit_sha(ref_) {
            let oid = git2::Oid::from_str(ref_)?;
            if repo.find_commit(oid).is_err() {
                remote
                    .fetch::<&str>(&[], Some(&mut fetch_options()), None)
                    .context("Failed to fetch from remote")?;
            }
            let commit = repo
                .find_commit(oid)
                .with_context(|| format!("Pinned commit {ref_} not found in remote"))?;
            repo.checkout_tree(commit.as_object(), None)?;
            repo.set_head_detached(oid)?;
            self.logger.success("Updated remote rules");
            return Ok(());
        }

        remote
            .fetch(&[ref_], Some(&mut fetch_options()), None)
            .context("Failed to fetch from remote")?;

        let fetch_head = repo
            .find_reference("FETCH_HEAD")
            .context("Failed to find FETCH_HEAD")?;
        let fetch_commit = repo.reference_to_annotated_commit(&fetch_head)?;
        let commit = repo.find_commit(fetch_commit.id())?;

        repo.checkout_tree(commit.as_object(), None)?;
        repo.set_head_detached(fetch_commit.id())?;

        self.logger.success("Updated remote rules");
        Ok(())
    }

    fn download_tarball(&self, url: &str, dest: &Path) -> Result<()> {
        let shown = net::redact_url(url);
        self.logger
            .info(&format!("Downloading remote rules from {shown}..."));

        let bytes = net::download_capped(url, MAX_ARCHIVE_BYTES)?;
        let skipped = extract_tar_gz(&bytes[..], dest, MAX_EXTRACTED_BYTES, MAX_ARCHIVE_ENTRIES)
            .with_context(|| format!("Failed to unpack {shown}"))?;
        for name in skipped {
            self.logger
                .warn(&format!("Skipped non-regular archive entry {name:?}"));
        }

        self.logger.success("Downloaded remote rules");
        Ok(())
    }

    fn index_preset_files(&self, cache_dir: &Path) -> Result<HashMap<String, PathBuf>> {
        let presets_dir = cache_dir.join("presets");
        let mut result = HashMap::new();

        match fs::symlink_metadata(&presets_dir) {
            Ok(meta) if meta.is_dir() => {}
            Ok(meta) if meta.file_type().is_symlink() => {
                self.logger
                    .warn("Skipping remote presets/: it is a symlink");
                return Ok(result);
            }
            _ => return Ok(result),
        }

        let root = cache_dir
            .canonicalize()
            .with_context(|| format!("Failed to resolve {}", cache_dir.display()))?;
        let mut skipped = Vec::new();

        for entry in walk_files(&presets_dir, 0, &mut skipped)? {
            let rel = entry
                .strip_prefix(&presets_dir)
                .context("Indexed file outside presets/")?
                .to_string_lossy()
                .to_string();
            // Belt and braces: only hand out paths that really live in the cache.
            let resolved = entry.canonicalize()?;
            if !resolved.starts_with(&root) {
                skipped.push(entry);
                continue;
            }
            result.insert(rel, resolved);
        }

        for path in skipped {
            let rel = path.strip_prefix(&presets_dir).unwrap_or(&path);
            self.logger.warn(&format!(
                "Skipping symlink in remote rules: presets/{}",
                rel.display()
            ));
        }

        Ok(result)
    }
}

/// True for a full 40- (SHA-1) or 64-char (SHA-256) hex commit id.
pub fn is_full_commit_sha(ref_: &str) -> bool {
    matches!(ref_.len(), 40 | 64) && ref_.bytes().all(|b| b.is_ascii_hexdigit())
}

/// Collect regular files under `dir` without following symlinks; symlinks are
/// reported in `skipped`. Fails past MAX_INDEX_DEPTH.
fn walk_files(dir: &Path, depth: usize, skipped: &mut Vec<PathBuf>) -> Result<Vec<PathBuf>> {
    if depth > MAX_INDEX_DEPTH {
        anyhow::bail!(
            "Remote rules nest deeper than {MAX_INDEX_DEPTH} levels at {}",
            dir.display()
        );
    }

    let mut files = Vec::new();
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        let path = entry.path();
        // DirEntry::file_type does not follow symlinks.
        let file_type = entry.file_type()?;
        if file_type.is_symlink() {
            skipped.push(path);
        } else if file_type.is_dir() {
            files.extend(walk_files(&path, depth + 1, skipped)?);
        } else if file_type.is_file() {
            files.push(path);
        }
    }
    Ok(files)
}

/// Unpack only regular files and directories, within size and entry limits.
/// Returns the names of skipped entries (symlinks, hard links, devices, or paths
/// escaping `dest`, which tar's `unpack_in` refuses).
fn extract_tar_gz<R: Read>(
    reader: R,
    dest: &Path,
    max_bytes: u64,
    max_entries: usize,
) -> Result<Vec<String>> {
    let mut archive = tar::Archive::new(flate2::read::GzDecoder::new(reader));
    let mut total: u64 = 0;
    let mut skipped = Vec::new();

    for (i, entry) in archive.entries()?.enumerate() {
        if i >= max_entries {
            anyhow::bail!("Archive has more than {max_entries} entries");
        }
        let mut entry = entry?;
        let name = entry.path()?.to_string_lossy().to_string();
        let kind = entry.header().entry_type();
        if !kind.is_file() && !kind.is_dir() {
            skipped.push(name);
            continue;
        }

        total = total.saturating_add(entry.header().size()?);
        if total > max_bytes {
            anyhow::bail!("Archive expands to more than {max_bytes} bytes");
        }
        if !entry.unpack_in(dest)? {
            skipped.push(name);
        }
    }

    Ok(skipped)
}

fn fetch_options<'cb>() -> git2::FetchOptions<'cb> {
    let mut callbacks = git2::RemoteCallbacks::new();
    callbacks.credentials(credentials_handler(git2::Config::open_default));
    let mut options = git2::FetchOptions::new();
    options.remote_callbacks(callbacks);
    options
}

/// Credentials come only from the user's environment -- ssh-agent for SSH, the
/// configured git credential helper for HTTPS -- never from mobhook.yaml.
fn credentials_handler<F>(
    git_config: F,
) -> impl FnMut(&str, Option<&str>, CredentialType) -> Result<Cred, git2::Error>
where
    F: Fn() -> Result<git2::Config, git2::Error>,
{
    let attempts = Cell::new(0usize);
    move |url, username, allowed| {
        attempts.set(attempts.get() + 1);
        if attempts.get() > MAX_CREDENTIAL_ATTEMPTS {
            return Err(git2::Error::from_str(
                "authentication failed: check your ssh-agent keys or git credential helper",
            ));
        }

        if allowed.contains(CredentialType::SSH_KEY) {
            return Cred::ssh_key_from_agent(username.unwrap_or("git"));
        }
        if allowed.contains(CredentialType::USER_PASS_PLAINTEXT) {
            return Cred::credential_helper(&git_config()?, url, username);
        }
        if allowed.contains(CredentialType::USERNAME) {
            return Cred::username(username.unwrap_or("git"));
        }
        if allowed.contains(CredentialType::DEFAULT) {
            return Cred::default();
        }
        Err(git2::Error::from_str(
            "no supported credential type: use ssh-agent or a git credential helper",
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;
    use tempfile::TempDir;

    fn sync_in<'a>(tmp: &TempDir, logger: &'a Logger) -> RemoteSync<'a> {
        RemoteSync::with_cache_root(logger, &tmp.path().join("cache"))
    }

    fn remote(url: &str, ref_: &str) -> RemoteConfig {
        RemoteConfig {
            url: url.to_string(),
            ref_: ref_.to_string(),
        }
    }

    #[test]
    fn libgit2_has_https_and_ssh_transports() {
        // git2 >= 0.21 has no default features; remote sync needs both transports.
        let version = git2::Version::get();
        assert!(version.https(), "libgit2 built without https");
        assert!(version.ssh(), "libgit2 built without ssh");
    }

    #[test]
    fn cache_dir_name_is_stable_sha256_prefix() {
        let tmp = TempDir::new().unwrap();
        let logger = Logger::quiet();
        let dir = sync_in(&tmp, &logger).cache_dir_for("abc").unwrap();
        // SHA-256("abc") starts with ba7816bf8f01cfea...; keeps existing caches valid.
        assert_eq!(dir.file_name().unwrap(), "ba7816bf8f01");
    }

    /// Local origin repo on branch `main`; returns the commit id of each commit.
    fn origin_repo(dir: &Path, commits: &[&str]) -> Vec<String> {
        let mut opts = git2::RepositoryInitOptions::new();
        opts.initial_head("main");
        let repo = git2::Repository::init_opts(dir, &opts).unwrap();
        let sig = git2::Signature::now("Test", "te****@test.com").unwrap();
        let mut ids = Vec::new();
        for content in commits {
            fs::create_dir_all(dir.join("presets/security")).unwrap();
            fs::write(dir.join("presets/security/rules.toml"), content).unwrap();
            let mut index = repo.index().unwrap();
            index
                .add_all(["*"], git2::IndexAddOption::DEFAULT, None)
                .unwrap();
            index.write().unwrap();
            let tree = repo.find_tree(index.write_tree().unwrap()).unwrap();
            let parents: Vec<git2::Commit> = repo
                .head()
                .ok()
                .and_then(|h| h.peel_to_commit().ok())
                .into_iter()
                .collect();
            let parent_refs: Vec<&git2::Commit> = parents.iter().collect();
            let id = repo
                .commit(Some("HEAD"), &sig, &sig, content, &tree, &parent_refs)
                .unwrap();
            ids.push(id.to_string());
        }
        ids
    }

    #[test]
    fn full_commit_sha_detection() {
        assert!(is_full_commit_sha(&"a".repeat(40)));
        assert!(is_full_commit_sha(
            &"0123456789abcdefABCDEF".repeat(3)[..40]
        ));
        assert!(is_full_commit_sha(&"b".repeat(64)));
        assert!(!is_full_commit_sha("main"));
        assert!(!is_full_commit_sha("v1.2.3"));
        assert!(!is_full_commit_sha(&"a".repeat(39)));
        assert!(!is_full_commit_sha(&"g".repeat(40)));
    }

    #[test]
    fn sync_rejects_insecure_urls_before_touching_cache() {
        let tmp = TempDir::new().unwrap();
        let logger = Logger::quiet();
        let sync = sync_in(&tmp, &logger);
        for url in [
            "http://example.com/rules.git",
            "git://example.com/rules.git",
            "file:///etc",
            "https://tok3n@example.com/rules.git",
        ] {
            assert!(
                sync.sync_and_get_files(&remote(url, "main")).is_err(),
                "{url}"
            );
            assert!(sync.force_update(&remote(url, "main")).is_err(), "{url}");
        }
        assert!(!tmp.path().join("cache").exists());
    }

    #[test]
    fn ssh_archive_url_is_rejected() {
        let tmp = TempDir::new().unwrap();
        let logger = Logger::quiet();
        let sync = sync_in(&tmp, &logger);
        let dest = tmp.path().join("dest");
        let err = sync
            .clone_repo(
                "ssh://git@host/rules.tar.gz",
                RemoteScheme::Ssh,
                &dest,
                "main",
            )
            .unwrap_err();
        assert!(err.to_string().contains("https://"));
        assert!(!dest.exists(), "failed clone must not leave a cache dir");
    }

    #[test]
    fn no_home_dir_fails_closed() {
        let err = mobhook_home_from(None).unwrap_err();
        assert!(err.to_string().contains("home directory"));
        let base = mobhook_home_from(Some(PathBuf::from("/home/u"))).unwrap();
        assert_eq!(base, PathBuf::from("/home/u/.mobhook"));
    }

    #[test]
    fn clone_and_pull_pinned_commit_from_local_origin() {
        let tmp = TempDir::new().unwrap();
        let logger = Logger::quiet();
        let origin = tmp.path().join("origin");
        let ids = origin_repo(&origin, &["v1", "v2"]);
        let sync = sync_in(&tmp, &logger);
        let cache = tmp.path().join("cache").join("pinned");

        // clone_git skips URL validation, which is what lets a local path be used here.
        sync.clone_git(origin.to_str().unwrap(), &cache, &ids[0])
            .unwrap();
        let rules = cache.join("presets/security/rules.toml");
        assert_eq!(fs::read_to_string(&rules).unwrap(), "v1");
        let repo = git2::Repository::open(&cache).unwrap();
        assert_eq!(repo.head().unwrap().target().unwrap().to_string(), ids[0]);

        sync.pull(&cache, &ids[1]).unwrap();
        assert_eq!(fs::read_to_string(&rules).unwrap(), "v2");

        let files = sync.index_preset_files(&cache).unwrap();
        assert!(files.contains_key("security/rules.toml"));
    }

    #[test]
    fn clone_mutable_branch_still_works() {
        let tmp = TempDir::new().unwrap();
        let logger = Logger::quiet();
        let origin = tmp.path().join("origin");
        origin_repo(&origin, &["v1"]);
        let sync = sync_in(&tmp, &logger);
        let cache = tmp.path().join("cache").join("branch");

        sync.warn_if_mutable_ref("main");
        sync.clone_git(origin.to_str().unwrap(), &cache, "main")
            .unwrap();
        assert!(cache.join("presets/security/rules.toml").is_file());
    }

    #[test]
    fn pull_unknown_pinned_commit_fails() {
        let tmp = TempDir::new().unwrap();
        let logger = Logger::quiet();
        let origin = tmp.path().join("origin");
        let ids = origin_repo(&origin, &["v1"]);
        let sync = sync_in(&tmp, &logger);
        let cache = tmp.path().join("cache").join("x");
        sync.clone_git(origin.to_str().unwrap(), &cache, &ids[0])
            .unwrap();

        let err = sync.pull(&cache, &"f".repeat(40)).unwrap_err();
        assert!(err.to_string().contains("not found"));
    }

    #[test]
    fn index_skips_symlinks_and_loops() {
        let tmp = TempDir::new().unwrap();
        let logger = Logger::quiet();
        let secret = tmp.path().join("secret.txt");
        fs::write(&secret, "local file").unwrap();

        let cache = tmp.path().join("cache").join("abc");
        let presets = cache.join("presets").join("security");
        fs::create_dir_all(&presets).unwrap();
        fs::write(presets.join("script.sh"), "#!/bin/bash\n").unwrap();
        symlink(&secret, presets.join("gitleaks.toml")).unwrap();
        symlink(tmp.path(), presets.join("outside-dir")).unwrap();
        symlink("..", presets.join("loop")).unwrap();

        let sync = sync_in(&tmp, &logger);
        let files = sync.index_preset_files(&cache).unwrap();

        assert_eq!(files.len(), 1, "{files:?}");
        assert!(files.contains_key("security/script.sh"));
        let root = cache.canonicalize().unwrap();
        assert!(files.values().all(|p| p.starts_with(&root)));
    }

    #[test]
    fn index_ignores_symlinked_presets_dir() {
        let tmp = TempDir::new().unwrap();
        let logger = Logger::quiet();
        let elsewhere = tmp.path().join("elsewhere");
        fs::create_dir_all(elsewhere.join("security")).unwrap();
        fs::write(elsewhere.join("security/script.sh"), "x").unwrap();
        let cache = tmp.path().join("cache").join("abc");
        fs::create_dir_all(&cache).unwrap();
        symlink(&elsewhere, cache.join("presets")).unwrap();

        let files = sync_in(&tmp, &logger).index_preset_files(&cache).unwrap();
        assert!(files.is_empty());
    }

    #[test]
    fn index_caps_depth() {
        let tmp = TempDir::new().unwrap();
        let logger = Logger::quiet();
        let cache = tmp.path().join("cache").join("abc");
        let mut deep = cache.join("presets");
        for i in 0..=MAX_INDEX_DEPTH + 1 {
            deep = deep.join(format!("d{i}"));
        }
        fs::create_dir_all(&deep).unwrap();
        fs::write(deep.join("f"), "x").unwrap();

        let err = sync_in(&tmp, &logger)
            .index_preset_files(&cache)
            .unwrap_err();
        assert!(err.to_string().contains("deeper"));
    }

    fn tar_gz(build: impl FnOnce(&mut tar::Builder<Vec<u8>>)) -> Vec<u8> {
        let mut builder = tar::Builder::new(Vec::new());
        build(&mut builder);
        let tar_bytes = builder.into_inner().unwrap();
        let mut gz = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::fast());
        std::io::Write::write_all(&mut gz, &tar_bytes).unwrap();
        gz.finish().unwrap()
    }

    fn add_file(b: &mut tar::Builder<Vec<u8>>, path: &str, data: &[u8]) {
        let mut header = tar::Header::new_gnu();
        header.set_size(data.len() as u64);
        header.set_mode(0o644);
        header.set_entry_type(tar::EntryType::Regular);
        header.set_cksum();
        b.append_data(&mut header, path, data).unwrap();
    }

    #[test]
    fn extract_unpacks_regular_files_and_skips_links() {
        let tmp = TempDir::new().unwrap();
        let archive = tar_gz(|b| {
            add_file(b, "presets/security/script.sh", b"echo ok");
            let mut link = tar::Header::new_gnu();
            link.set_entry_type(tar::EntryType::Symlink);
            link.set_size(0);
            b.append_link(&mut link, "presets/security/leak", "/etc/hosts")
                .unwrap();
        });

        let dest = tmp.path().join("dest");
        fs::create_dir_all(&dest).unwrap();
        let skipped = extract_tar_gz(&archive[..], &dest, 1024, 10).unwrap();

        assert!(dest.join("presets/security/script.sh").is_file());
        assert!(fs::symlink_metadata(dest.join("presets/security/leak")).is_err());
        assert_eq!(skipped, vec!["presets/security/leak".to_string()]);
    }

    #[test]
    fn extract_rejects_oversized_content() {
        let tmp = TempDir::new().unwrap();
        let archive = tar_gz(|b| {
            add_file(b, "a", &[0u8; 600]);
            add_file(b, "b", &[0u8; 600]);
        });
        let err = extract_tar_gz(&archive[..], tmp.path(), 1000, 10).unwrap_err();
        assert!(err.to_string().contains("more than 1000 bytes"));
    }

    #[test]
    fn extract_rejects_too_many_entries() {
        let tmp = TempDir::new().unwrap();
        let archive = tar_gz(|b| {
            for i in 0..5 {
                add_file(b, &format!("f{i}"), b"x");
            }
        });
        let err = extract_tar_gz(&archive[..], tmp.path(), 1024, 3).unwrap_err();
        assert!(err.to_string().contains("more than 3 entries"));
    }

    #[test]
    fn credentials_prefer_agent_and_give_up() {
        let tmp = TempDir::new().unwrap();
        let cfg_path = tmp.path().join("gitconfig");
        fs::write(&cfg_path, "").unwrap();
        let mut handler = credentials_handler(move || git2::Config::open(&cfg_path));

        let cred = handler("ssh://git@host/r.git", Some("git"), CredentialType::SSH_KEY).unwrap();
        assert!(cred.has_username());
        // No helper configured in the isolated config: nothing to hand out.
        assert!(handler(
            "https://host/r.git",
            None,
            CredentialType::USER_PASS_PLAINTEXT
        )
        .is_err());
        assert!(handler("https://host/r.git", None, CredentialType::SSH_MEMORY).is_err());
        // Attempt cap reached: even a supported type is refused now.
        let err = handler("ssh://git@host/r.git", Some("git"), CredentialType::SSH_KEY)
            .err()
            .unwrap();
        assert!(err.message().contains("authentication failed"));
    }
}
