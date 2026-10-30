# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in mobhook, please report it responsibly.

**Do NOT open a public GitHub issue.**

Report privately through GitHub Private Vulnerability Reporting: open the repository's
**Security** tab and click **"Report a vulnerability"**
(https://github.com/iqbal-mekari/mobhook/security/advisories/new).

Please include:
- Description of the vulnerability
- Steps to reproduce
- Potential impact

Please do not include real secrets, customer data, or personal data in a report; mask them.

We will acknowledge receipt within 48 hours and provide a detailed response within 7 days.

## Supported Versions

Based on the published tags (v0.1.0, v0.1.1, v0.2.0, v0.3.0, v0.4.0, v0.4.1, v0.4.2), the latest release is v0.4.2.

| Version | Supported |
|---------|-----------|
| 0.4.x (latest: v0.4.2) | Yes |
| < 0.4.0 | No |

Only the latest release receives security fixes. Upgrade to the newest tag before reporting.

## Release Integrity

Releases are built from `vMAJOR.MINOR.PATCH[-prerelease]` tags on commits reachable from `main`.
Each release publishes a `SHA256SUMS` asset; verify downloaded tarballs against it
(`shasum -a 256 -c SHA256SUMS`).

## Scope

Security issues in:
- The mobhook binary
- Bundled preset scripts
- The generated hook scripts
- The CI/release pipeline (`.github/`)

Out of scope:
- Third-party tools (gitleaks, mobsfscan)
- User-created custom hook scripts
