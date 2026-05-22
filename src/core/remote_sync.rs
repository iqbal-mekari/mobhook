use anyhow::{Context, Result};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use super::config::RemoteConfig;
use super::logger::Logger;

const STALE_THRESHOLD: Duration = Duration::from_secs(300); // 5 minutes

pub struct RemoteSync<'a> {
    logger: &'a Logger,
}

impl<'a> RemoteSync<'a> {
    pub fn new(logger: &'a Logger) -> Self {
        Self { logger }
    }

    fn cache_base() -> PathBuf {
        let home = dirs::home_dir().unwrap_or_else(|| PathBuf::from("/tmp"));
        home.join(".mobhook").join("cache")
    }

    fn cache_dir_for(url: &str) -> PathBuf {
        let hash = format!("{:x}", Sha256::digest(url.as_bytes()));
        let short = &hash[..12];
        Self::cache_base().join(short)
    }

    /// Sync remote and return a map of relative paths to absolute file paths.
    pub fn sync_and_get_files(&self, remote: &RemoteConfig) -> Result<HashMap<String, PathBuf>> {
        let cache_dir = Self::cache_dir_for(&remote.url);

        if cache_dir.exists() {
            if !self.is_stale(&cache_dir) {
                self.logger
                    .detail("Using cached remote rules (< 5 min old)");
            } else {
                self.pull(&cache_dir, &remote.ref_)?;
            }
        } else {
            self.clone_repo(&remote.url, &cache_dir, &remote.ref_)?;
        }

        self.touch_cache(&cache_dir);
        self.index_preset_files(&cache_dir)
    }

    /// Force re-clone (used by `mobhook update`).
    pub fn force_update(&self, remote: &RemoteConfig) -> Result<HashMap<String, PathBuf>> {
        let cache_dir = Self::cache_dir_for(&remote.url);
        if cache_dir.exists() {
            fs::remove_dir_all(&cache_dir)?;
        }
        self.sync_and_get_files(remote)
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

    fn clone_repo(&self, url: &str, dest: &Path, ref_: &str) -> Result<()> {
        self.logger
            .info(&format!("Cloning remote rules from {url}..."));
        fs::create_dir_all(dest)?;

        // Try HTTP tarball for archive URLs
        if url.ends_with(".tar.gz") || url.ends_with(".tgz") || url.ends_with(".zip") {
            return self.download_tarball(url, dest);
        }

        // Use git2 for git repos
        let repo =
            git2::Repository::clone(url, dest).with_context(|| format!("Failed to clone {url}"))?;

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

        remote
            .fetch(&[ref_], None, None)
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
        self.logger
            .info(&format!("Downloading remote rules from {url}..."));

        let response =
            reqwest::blocking::get(url).with_context(|| format!("Failed to download {url}"))?;

        if !response.status().is_success() {
            anyhow::bail!("HTTP {} downloading {url}", response.status());
        }

        let bytes = response.bytes()?;
        let decoder = flate2::read::GzDecoder::new(&bytes[..]);
        let mut archive = tar::Archive::new(decoder);
        archive.unpack(dest)?;

        self.logger.success("Downloaded remote rules");
        Ok(())
    }

    fn index_preset_files(&self, cache_dir: &Path) -> Result<HashMap<String, PathBuf>> {
        let presets_dir = cache_dir.join("presets");
        let mut result = HashMap::new();

        if !presets_dir.exists() {
            return Ok(result);
        }

        for entry in walkdir(&presets_dir)? {
            if entry.is_file() {
                let rel = entry
                    .strip_prefix(&presets_dir)
                    .unwrap()
                    .to_string_lossy()
                    .to_string();
                result.insert(rel, entry);
            }
        }

        Ok(result)
    }
}

fn walkdir(dir: &Path) -> Result<Vec<PathBuf>> {
    let mut files = Vec::new();
    if dir.is_dir() {
        for entry in fs::read_dir(dir)? {
            let entry = entry?;
            let path = entry.path();
            if path.is_dir() {
                files.extend(walkdir(&path)?);
            } else {
                files.push(path);
            }
        }
    }
    Ok(files)
}
