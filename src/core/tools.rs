use anyhow::{Context, Result};
use sha2::{Digest, Sha256};
use std::fs;
use std::io::{Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;

use super::net;

/// gitleaks release installed when it is not already on PATH. Bump together
/// with GITLEAKS_SHA256, copied from the publisher's
/// gitleaks_<version>_checksums.txt on the GitHub release.
const GITLEAKS_VERSION: &str = "8.21.2";

/// SHA-256 of each supported release asset (gitleaks_8.21.2_checksums.txt).
const GITLEAKS_SHA256: &[(&str, &str)] = &[
    (
        "darwin_arm64",
        "cad3de5dc9a4d5447d967a70a4d49499c557f04db028274cc324f9ff983f6502",
    ),
    (
        "darwin_x64",
        "5b42c6e4b1fd693eaeb2b5b7faa5f17a1434299d4deb2de63d4b2efd7c753128",
    ),
    (
        "linux_arm64",
        "654c935542c89f565aabe7bf7c6c500830f116c114f0aeb509d2460c1ac2e6da",
    ),
    (
        "linux_x64",
        "5bc41815076e6ed6ef8fbecc9d9b75bcae31f39029ceb55da08086315316e3ba",
    ),
];

const MAX_GITLEAKS_ARCHIVE_BYTES: u64 = 50 * 1024 * 1024;
const MAX_GITLEAKS_BINARY_BYTES: u64 = 100 * 1024 * 1024;

/// Pinned mobsfscan release installed via pipx (PyPI).
const MOBSFSCAN_SPEC: &str = "mobsfscan==1.0.1";

/// ~/.mobhook for the given home dir. Without a home dir we fail closed rather
/// than fall back to a shared, world-writable location such as /tmp.
pub fn mobhook_home_from(home: Option<PathBuf>) -> Result<PathBuf> {
    let home = home.context(
        "Cannot determine your home directory (set $HOME); refusing to fall back to a shared temp dir",
    )?;
    Ok(home.join(".mobhook"))
}

/// Get the mobhook bin directory for cached tool binaries.
pub fn mobhook_bin_dir() -> Result<PathBuf> {
    Ok(mobhook_home_from(dirs::home_dir())?.join("bin"))
}

/// Check if a tool is available on PATH or in ~/.mobhook/bin/.
pub fn find_tool(name: &str) -> Option<PathBuf> {
    // Check ~/.mobhook/bin/ first
    if let Ok(bin_dir) = mobhook_bin_dir() {
        let cached = bin_dir.join(name);
        if cached.exists() {
            return Some(cached);
        }
    }
    // Check system PATH
    which(name)
}

/// Find a binary on PATH.
fn which(name: &str) -> Option<PathBuf> {
    Command::new("which")
        .arg(name)
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| PathBuf::from(String::from_utf8_lossy(&o.stdout).trim()))
}

/// Download the pinned gitleaks release from GitHub and verify its checksum.
pub fn ensure_gitleaks() -> Result<PathBuf> {
    if let Some(path) = find_tool("gitleaks") {
        return Ok(path);
    }

    println!("⬇️  Downloading gitleaks...");

    let bin_dir = mobhook_bin_dir()?;
    fs::create_dir_all(&bin_dir)?;

    let (os, arch) = platform_triple();
    let platform = format!("{os}_{arch}");
    let expected = gitleaks_sha256(&platform)?;

    let url = format!(
        "https://github.com/gitleaks/gitleaks/releases/download/v{GITLEAKS_VERSION}/gitleaks_{GITLEAKS_VERSION}_{platform}.tar.gz"
    );

    let bytes = net::download_capped(&url, MAX_GITLEAKS_ARCHIVE_BYTES)?;
    verify_sha256(&bytes, expected).with_context(|| {
        format!(
            "Refusing to install gitleaks from {}",
            net::redact_url(&url)
        )
    })?;

    let binary = extract_file_from_tar_gz(&bytes[..], "gitleaks", MAX_GITLEAKS_BINARY_BYTES)?;
    let gitleaks_path = install_binary(&bin_dir, "gitleaks", &binary)?;
    println!("✅ gitleaks installed to {}", gitleaks_path.display());
    Ok(gitleaks_path)
}

/// Pinned checksum for a platform's release asset; unknown platforms fail closed.
fn gitleaks_sha256(platform: &str) -> Result<&'static str> {
    GITLEAKS_SHA256
        .iter()
        .find(|(p, _)| *p == platform)
        .map(|(_, sha)| *sha)
        .with_context(|| {
            format!(
                "No verified gitleaks {GITLEAKS_VERSION} checksum for platform '{platform}' (unverified); install gitleaks manually"
            )
        })
}

fn verify_sha256(bytes: &[u8], expected_hex: &str) -> Result<()> {
    let actual: String = Sha256::digest(bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect();
    if !actual.eq_ignore_ascii_case(expected_hex) {
        anyhow::bail!("SHA-256 mismatch: expected {expected_hex}, got {actual}");
    }
    Ok(())
}

/// Read a single regular file named exactly `name` from a .tar.gz, ignoring every
/// other entry (docs, links, anything with a path).
fn extract_file_from_tar_gz<R: Read>(reader: R, name: &str, max_bytes: u64) -> Result<Vec<u8>> {
    let mut archive = tar::Archive::new(flate2::read::GzDecoder::new(reader));
    for entry in archive.entries()? {
        let entry = entry?;
        if !entry.header().entry_type().is_file() || entry.path()?.as_ref() != Path::new(name) {
            continue;
        }
        let size = entry.header().size()?;
        if size > max_bytes {
            anyhow::bail!("'{name}' in archive is too large: {size} bytes (limit {max_bytes})");
        }
        let mut buf = Vec::new();
        entry.take(max_bytes).read_to_end(&mut buf)?;
        return Ok(buf);
    }
    anyhow::bail!("'{name}' not found in archive")
}

/// Write `data` to `dir/name` as an executable, atomically (temp file + rename).
fn install_binary(dir: &Path, name: &str, data: &[u8]) -> Result<PathBuf> {
    let mut tmp = tempfile::NamedTempFile::new_in(dir)
        .with_context(|| format!("Failed to create temp file in {}", dir.display()))?;
    tmp.write_all(data)?;
    tmp.as_file()
        .set_permissions(fs::Permissions::from_mode(0o755))?;
    let dest = dir.join(name);
    tmp.persist(&dest)
        .with_context(|| format!("Failed to install {}", dest.display()))?;
    Ok(dest)
}

/// Ensure mobsfscan is installed via pipx.
pub fn ensure_mobsfscan() -> Result<PathBuf> {
    if let Some(path) = find_tool("mobsfscan") {
        return Ok(path);
    }

    println!("⬇️  Installing mobsfscan via pipx...");

    if which("pipx").is_none() {
        anyhow::bail!("pipx not found. Install it first:\n  brew install pipx\n  pipx ensurepath");
    }

    let python = find_compatible_python();

    let mut cmd = Command::new("pipx");
    cmd.arg("install").arg(MOBSFSCAN_SPEC);
    if let Some(py) = &python {
        cmd.arg("--python").arg(py);
    }

    let status = cmd
        .status()
        .context("Failed to run pipx install mobsfscan")?;

    if !status.success() {
        anyhow::bail!("pipx install mobsfscan failed");
    }

    let local_bin = dirs::home_dir().map(|home| home.join(".local").join("bin").join("mobsfscan"));

    match local_bin {
        Some(path) if path.exists() => {
            println!("✅ mobsfscan installed");
            Ok(path)
        }
        _ => which("mobsfscan").context("mobsfscan not found after pipx install"),
    }
}

fn find_compatible_python() -> Option<String> {
    for ver in &["python3.13", "python3.12", "python3.11"] {
        if let Some(path) = which(ver) {
            let status = Command::new(&path).arg("--version").output();
            if status.map(|o| o.status.success()).unwrap_or(false) {
                return Some(path.to_string_lossy().to_string());
            }
        }
    }
    None
}

fn platform_triple() -> (&'static str, &'static str) {
    let os = if cfg!(target_os = "macos") {
        "darwin"
    } else if cfg!(target_os = "linux") {
        "linux"
    } else {
        "windows"
    };

    let arch = if cfg!(target_arch = "aarch64") {
        "arm64"
    } else {
        "x64"
    };

    (os, arch)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn tar_gz(entries: &[(&str, tar::EntryType, &[u8])]) -> Vec<u8> {
        let mut builder = tar::Builder::new(Vec::new());
        for (path, kind, data) in entries {
            let mut header = tar::Header::new_gnu();
            header.set_entry_type(*kind);
            header.set_mode(0o755);
            if *kind == tar::EntryType::Symlink {
                header.set_size(0);
                builder.append_link(&mut header, path, "/bin/sh").unwrap();
            } else {
                header.set_size(data.len() as u64);
                header.set_cksum();
                builder.append_data(&mut header, path, *data).unwrap();
            }
        }
        let tar_bytes = builder.into_inner().unwrap();
        let mut gz = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::fast());
        gz.write_all(&tar_bytes).unwrap();
        gz.finish().unwrap()
    }

    #[test]
    fn checksum_table_is_well_formed() {
        for (platform, sha) in GITLEAKS_SHA256 {
            assert_eq!(sha.len(), 64, "{platform}");
            assert!(sha.bytes().all(|b| b.is_ascii_hexdigit()), "{platform}");
        }
        let (os, arch) = platform_triple();
        if os != "windows" {
            assert!(gitleaks_sha256(&format!("{os}_{arch}")).is_ok());
        }
    }

    #[test]
    fn unknown_platform_fails_closed() {
        let err = gitleaks_sha256("windows_x64").unwrap_err().to_string();
        assert!(err.contains("unverified"), "{err}");
    }

    #[test]
    fn verify_sha256_accepts_match_rejects_mismatch() {
        // SHA-256("abc"), FIPS 180-2 test vector.
        let abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
        assert!(verify_sha256(b"abc", abc).is_ok());
        assert!(verify_sha256(b"abc", &abc.to_uppercase()).is_ok());
        let err = verify_sha256(b"abd", abc).unwrap_err().to_string();
        assert!(err.contains("mismatch"), "{err}");
    }

    #[test]
    fn extracts_only_the_named_binary() {
        let archive = tar_gz(&[
            ("README.md", tar::EntryType::Regular, b"docs"),
            ("sub/gitleaks", tar::EntryType::Regular, b"wrong"),
            ("gitleaks", tar::EntryType::Regular, b"\x7fELF-binary"),
        ]);
        let data = extract_file_from_tar_gz(&archive[..], "gitleaks", 1024).unwrap();
        assert_eq!(data, b"\x7fELF-binary");
    }

    #[test]
    fn extract_ignores_symlink_named_like_binary() {
        let archive = tar_gz(&[("gitleaks", tar::EntryType::Symlink, b"")]);
        let err = extract_file_from_tar_gz(&archive[..], "gitleaks", 1024).unwrap_err();
        assert!(err.to_string().contains("not found"));
    }

    #[test]
    fn extract_rejects_oversized_binary() {
        let archive = tar_gz(&[("gitleaks", tar::EntryType::Regular, &[0u8; 2048])]);
        let err = extract_file_from_tar_gz(&archive[..], "gitleaks", 1024).unwrap_err();
        assert!(err.to_string().contains("too large"));
    }

    #[test]
    fn install_binary_is_executable() {
        let tmp = TempDir::new().unwrap();
        let path = install_binary(tmp.path(), "gitleaks", b"#!/bin/sh\n").unwrap();
        assert_eq!(path, tmp.path().join("gitleaks"));
        let mode = fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o755);
        // Only the binary is left behind, no stray temp files.
        assert_eq!(fs::read_dir(tmp.path()).unwrap().count(), 1);
    }

    #[test]
    fn no_home_dir_fails_closed() {
        let err = mobhook_home_from(None).unwrap_err().to_string();
        assert!(err.contains("home directory"));
        assert!(!err.contains("/tmp"));
        assert_eq!(
            mobhook_home_from(Some(PathBuf::from("/home/u"))).unwrap(),
            PathBuf::from("/home/u/.mobhook")
        );
    }

    #[test]
    fn mobsfscan_is_pinned() {
        assert!(MOBSFSCAN_SPEC.starts_with("mobsfscan=="));
    }
}
