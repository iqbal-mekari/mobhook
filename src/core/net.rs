use anyhow::{Context, Result};
use regex::Regex;
use reqwest::Url;
use std::io::Read;
use std::sync::OnceLock;
use std::time::Duration;

const HTTP_TIMEOUT: Duration = Duration::from_secs(120);

/// Transport a validated remote URL will be fetched over.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RemoteScheme {
    Https,
    Ssh,
}

const CREDENTIALS_HINT: &str = "Remove them from mobhook.yaml: use a git credential helper \
(git config credential.helper) for https:// remotes or an SSH key loaded in ssh-agent for ssh:// remotes.";

/// Accept only authenticated transports: https://, ssh:// and scp-like
/// `user@host:path`. Plain http://, git://, file:// and local paths are rejected,
/// as is any URL that embeds credentials.
pub fn validate_remote_url(url: &str) -> Result<RemoteScheme> {
    let shown = redact_url(url);

    if !url.contains("://") && is_scp_like(url) {
        return Ok(RemoteScheme::Ssh);
    }

    let parsed = Url::parse(url).with_context(|| {
        format!(
            "Invalid remote URL '{shown}': use https://host/org/repo.git or git@host:org/repo.git"
        )
    })?;

    let scheme = parsed.scheme();
    if scheme != "https" && scheme != "ssh" {
        anyhow::bail!(
            "Unsupported remote URL scheme '{scheme}' in '{shown}': only https:// and ssh:// remotes are allowed"
        );
    }

    let host = parsed.host_str().unwrap_or("");
    if host.is_empty() || host.starts_with('-') {
        anyhow::bail!("Invalid remote URL '{shown}': missing or invalid host");
    }

    // A user name (git@) is normal for SSH; for https it is a token, and a
    // password is never acceptable.
    if parsed.password().is_some() || (scheme == "https" && !parsed.username().is_empty()) {
        anyhow::bail!("Remote URL '{shown}' embeds credentials. {CREDENTIALS_HINT}");
    }

    if scheme == "https" {
        Ok(RemoteScheme::Https)
    } else {
        if parsed.username().starts_with('-') {
            anyhow::bail!("Invalid remote URL '{shown}': invalid SSH user name");
        }
        Ok(RemoteScheme::Ssh)
    }
}

/// scp-like SSH syntax, e.g. `git@github.com:org/rules.git`. The user part is
/// required so that strings such as `file:/etc` are never read as host "file".
fn is_scp_like(url: &str) -> bool {
    static SCP_LIKE: OnceLock<Regex> = OnceLock::new();
    SCP_LIKE
        .get_or_init(|| {
            Regex::new(r"^[A-Za-z0-9][A-Za-z0-9._\-]*@[A-Za-z0-9][A-Za-z0-9.\-]*:[^\s]+$").unwrap()
        })
        .is_match(url)
}

/// Make a URL safe to print: user info and query strings are masked.
/// Use this for every log line or error context that includes a remote URL.
pub fn redact_url(url: &str) -> String {
    if let Ok(mut parsed) = Url::parse(url) {
        if parsed.has_host() {
            if !parsed.username().is_empty() || parsed.password().is_some() {
                // Only fails for cannot-be-a-base URLs, excluded by has_host().
                let _ = parsed.set_password(None);
                let _ = parsed.set_username("****");
            }
            if parsed.query().is_some() {
                parsed.set_query(Some("****"));
            }
            return parsed.to_string();
        }
    }

    // Unparseable or scp-like: mask anything before '@' in the authority part.
    let start = url.find("://").map(|i| i + 3).unwrap_or(0);
    let end = url[start..]
        .find('/')
        .map(|i| start + i)
        .unwrap_or(url.len());
    match url[start..end].rfind('@') {
        Some(at) => format!("{}****{}", &url[..start], &url[start + at..]),
        None => url.to_string(),
    }
}

/// HTTPS-only client: plain-http URLs and redirects to them are refused.
pub fn http_client() -> Result<reqwest::blocking::Client> {
    reqwest::blocking::Client::builder()
        .https_only(true)
        .timeout(HTTP_TIMEOUT)
        .build()
        .context("Failed to build HTTPS client")
}

/// Download `url` into memory, refusing bodies larger than `max_bytes`.
pub fn download_capped(url: &str, max_bytes: u64) -> Result<Vec<u8>> {
    let shown = redact_url(url);
    let response = http_client()?
        .get(url)
        .send()
        // reqwest embeds the full URL in its errors; ours already names it, redacted.
        .map_err(|e| e.without_url())
        .with_context(|| format!("Failed to download {shown}"))?;

    if !response.status().is_success() {
        anyhow::bail!("HTTP {} downloading {shown}", response.status());
    }

    let declared = response.content_length();
    read_capped(response, declared, max_bytes)
        .with_context(|| format!("Failed to download {shown}"))
}

/// Read at most `max_bytes` from `reader`. A declared length over the cap fails
/// fast; the bounded read also catches bodies that lie about their length.
pub fn read_capped<R: Read>(
    reader: R,
    declared_len: Option<u64>,
    max_bytes: u64,
) -> Result<Vec<u8>> {
    if let Some(len) = declared_len {
        if len > max_bytes {
            anyhow::bail!("Download too large: {len} bytes (limit {max_bytes})");
        }
    }

    let mut buf = Vec::new();
    reader
        .take(max_bytes.saturating_add(1))
        .read_to_end(&mut buf)
        .context("Failed to read download body")?;
    if buf.len() as u64 > max_bytes {
        anyhow::bail!("Download too large: more than {max_bytes} bytes");
    }
    Ok(buf)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{self, Cursor};

    #[test]
    fn accepts_https_and_ssh() {
        let cases = [
            ("https://github.com/org/rules.git", RemoteScheme::Https),
            ("HTTPS://github.com/org/rules.git", RemoteScheme::Https),
            ("https://example.com/rules.tar.gz", RemoteScheme::Https),
            ("ssh://git@github.com/org/rules.git", RemoteScheme::Ssh),
            ("ssh://github.com:2222/org/rules.git", RemoteScheme::Ssh),
            ("git@github.com:org/rules.git", RemoteScheme::Ssh),
        ];
        for (url, scheme) in cases {
            assert_eq!(validate_remote_url(url).unwrap(), scheme, "{url}");
        }
    }

    #[test]
    fn rejects_insecure_and_local_schemes() {
        for url in [
            "http://github.com/org/rules.git",
            "http://example.com/rules.tar.gz",
            "git://github.com/org/rules.git",
            "file:///etc",
            "file:/etc",
            "ftp://example.com/rules.tar.gz",
            "/home/user/rules",
            "./rules",
            "../rules",
            "github.com:org/rules.git",
            "ext::sh -c touch% /tmp/pwned",
            "",
        ] {
            let err = validate_remote_url(url).unwrap_err().to_string();
            assert!(
                err.contains("scheme") || err.contains("Invalid remote URL"),
                "{url}: {err}"
            );
        }
    }

    #[test]
    fn rejects_option_like_hosts_and_users() {
        assert!(validate_remote_url("ssh://-oProxyCommand=x/org/repo").is_err());
        assert!(validate_remote_url("ssh://-oProxyCommand=x@host/org/repo").is_err());
        assert!(validate_remote_url("-oProxyCommand=x@host:org/repo").is_err());
    }

    #[test]
    fn rejects_embedded_credentials_without_echoing_them() {
        for url in [
            "https://tok3n****@github.com/org/rules.git",
            "https://user:pa****ss@github.com/org/rules.git",
            "ssh://git:pa****ss@github.com/org/rules.git",
        ] {
            let err = format!("{:#}", validate_remote_url(url).unwrap_err());
            assert!(err.contains("embeds credentials"), "{err}");
            assert!(err.contains("credential helper"), "{err}");
            assert!(!err.contains("tok3n") && !err.contains("pa****ss"), "{err}");
        }
    }

    #[test]
    fn redacts_userinfo_and_query() {
        assert_eq!(
            redact_url("https://tok3n@github.com/org/r.git"),
            "https://****@github.com/org/r.git"
        );
        assert_eq!(
            redact_url("https://u:pw@github.com/org/r.git"),
            "https://****@github.com/org/r.git"
        );
        assert_eq!(
            redact_url("https://example.com/r.tar.gz?token=abc"),
            "https://example.com/r.tar.gz?****"
        );
        assert_eq!(
            redact_url("https://github.com/org/r.git"),
            "https://github.com/org/r.git"
        );
        assert_eq!(
            redact_url("git@github.com:org/r.git"),
            "****@github.com:org/r.git"
        );
        assert_eq!(redact_url("not a url"), "not a url");
    }

    #[test]
    fn read_capped_accepts_body_within_limit() {
        let body = read_capped(Cursor::new(vec![7u8; 10]), Some(10), 10).unwrap();
        assert_eq!(body.len(), 10);
        let body = read_capped(Cursor::new(vec![7u8; 3]), None, 10).unwrap();
        assert_eq!(body.len(), 3);
    }

    #[test]
    fn read_capped_rejects_declared_oversize() {
        let err = read_capped(io::empty(), Some(11), 10).unwrap_err();
        assert!(err.to_string().contains("too large"));
    }

    #[test]
    fn read_capped_rejects_body_lying_about_length() {
        // Endless stream: only the bounded read keeps this from exhausting memory.
        let err = read_capped(io::repeat(0), Some(5), 1024).unwrap_err();
        assert!(err.to_string().contains("too large"));
        let err = read_capped(io::repeat(0), None, 1024).unwrap_err();
        assert!(err.to_string().contains("too large"));
    }

    #[test]
    fn http_client_refuses_plain_http_without_network() {
        // https_only fails before any connection is attempted.
        let err = http_client()
            .unwrap()
            .get("http://127.0.0.1:9/rules.tar.gz")
            .send()
            .unwrap_err();
        assert!(
            err.is_builder() || err.to_string().contains("https"),
            "{err}"
        );
    }
}
