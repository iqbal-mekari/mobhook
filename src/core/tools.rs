use anyhow::{Context, Result};
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::Command;

/// Get the mobhook bin directory for cached tool binaries.
pub fn mobhook_bin_dir() -> PathBuf {
    let home = dirs::home_dir().unwrap_or_else(|| PathBuf::from("/tmp"));
    home.join(".mobhook").join("bin")
}

/// Check if a tool is available on PATH or in ~/.mobhook/bin/.
pub fn find_tool(name: &str) -> Option<PathBuf> {
    // Check ~/.mobhook/bin/ first
    let cached = mobhook_bin_dir().join(name);
    if cached.exists() {
        return Some(cached);
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

/// Download gitleaks binary from GitHub releases.
pub fn ensure_gitleaks() -> Result<PathBuf> {
    if let Some(path) = find_tool("gitleaks") {
        return Ok(path);
    }

    println!("⬇️  Downloading gitleaks...");

    let bin_dir = mobhook_bin_dir();
    fs::create_dir_all(&bin_dir)?;

    let (os, arch) = platform_triple();
    let ext = if os == "windows" { ".zip" } else { ".tar.gz" };

    // Get latest version tag from GitHub API
    let version_url = "https://api.github.com/repos/gitleaks/gitleaks/releases/latest";
    let version_resp =
        reqwest::blocking::get(version_url).context("Failed to query gitleaks releases")?;
    let release: serde_json::Value = version_resp
        .json()
        .context("Failed to parse gitleaks release info")?;
    let tag = release["tag_name"]
        .as_str()
        .unwrap_or("v8.21.2")
        .trim_start_matches('v');

    let url = format!(
        "https://github.com/gitleaks/gitleaks/releases/download/v{tag}/gitleaks_{tag}_{os}_{arch}{ext}"
    );

    let response = reqwest::blocking::get(&url)
        .with_context(|| format!("Failed to download gitleaks from {url}"))?;

    if !response.status().is_success() {
        anyhow::bail!(
            "Failed to download gitleaks: HTTP {} from {url}",
            response.status()
        );
    }

    let bytes = response.bytes()?;
    let decoder = flate2::read::GzDecoder::new(&bytes[..]);
    let mut archive = tar::Archive::new(decoder);
    archive.unpack(&bin_dir)?;

    let gitleaks_path = bin_dir.join("gitleaks");
    if gitleaks_path.exists() {
        let mut perms = fs::metadata(&gitleaks_path)?.permissions();
        perms.set_mode(0o755);
        fs::set_permissions(&gitleaks_path, perms)?;
        println!("✅ gitleaks installed to {}", gitleaks_path.display());
        Ok(gitleaks_path)
    } else {
        anyhow::bail!("gitleaks binary not found after download")
    }
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
    cmd.arg("install").arg("mobsfscan");
    if let Some(py) = &python {
        cmd.arg("--python").arg(py);
    }

    let status = cmd
        .status()
        .context("Failed to run pipx install mobsfscan")?;

    if !status.success() {
        anyhow::bail!("pipx install mobsfscan failed");
    }

    let local_bin = dirs::home_dir()
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join(".local")
        .join("bin")
        .join("mobsfscan");

    if local_bin.exists() {
        println!("✅ mobsfscan installed");
        Ok(local_bin)
    } else if let Some(path) = which("mobsfscan") {
        Ok(path)
    } else {
        anyhow::bail!("mobsfscan not found after pipx install")
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
