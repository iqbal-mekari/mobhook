# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.4.2] - 2026-10-30

### Security
- Updated vulnerable transitive dependencies flagged by RustSec in `Cargo.lock`: `rustls`
  0.23.46, `rustls-webpki` 0.103.16, `webpki-roots` 1.0.11 (TLS stack used for remote
  preset downloads), `quinn-proto` 0.11.19, `libz-sys` 1.1.31, and `tokio` 1.54.1.

### Fixed
- Security preset: `ci-security-scan.sh` computed `OVERALL_SEVERITY` by feeding two JSON
  documents to one `jq` call, so any failing scan reported `high`. It now reports `none`,
  `low`, `medium`, `high` or `critical` from the findings (any gitleaks finding, a mobsfscan
  ERROR/HIGH, an unknown severity or a tool crash still report `high`). `scan-summary.json`
  keys, `status`, exit codes and `FAIL_ON_FINDINGS` are unchanged; consumers that assumed
  `high` for every failing scan should be checked.

### Added
- CI `audit` job: `cargo audit` (pinned `cargo-audit`, read-only token) on pull requests,
  pushes to `main` and weekly; fails on RustSec vulnerabilities, warns on unmaintained or
  yanked crates.

### Changed
- Dependencies: `anyhow` 1.0.104, `bytes` 1.12.1, `regex` 1.13.1, `flate2` 1.1.10.
- `SECURITY.md` now points to GitHub private vulnerability reporting; README documents
  `mode` fallback behavior.

## [0.4.1] - 2026-10-30

### Changed
- Dependencies: `git2` 0.19 -> 0.21, `sha2` 0.10 -> 0.11, `dirs` 6 -> 7, `serde` 1.0.229,
  `thiserror` 2.0.21. `git2` 0.21 has no default features, so `https` and `ssh` are now
  enabled explicitly (a test fails if libgit2 lacks either transport). No behavior change
  for users; the remote cache directory names are unchanged (pinned by a test).
- Release workflow actions bumped (all still pinned to commit SHAs): `checkout` 7.0.1,
  `upload-artifact` 7.0.2, `download-artifact` 8.0.2, `action-gh-release` 3.0.3.
  `download-artifact` now errors on an artifact digest mismatch (previously a warning).

## [0.4.0] - 2026-10-29

### Changed (breaking)
- Configs that previously loaded are now rejected: unknown `hooks:` keys (only the 18
  standard client-side git hook names are accepted), step names that are not
  `[a-z0-9-]` (lowercase, no leading/trailing hyphen), an invalid per-entry `mode`,
  remotes that are not `https://`, `ssh://` or `user@host:path`, and URLs with embedded
  credentials. Run `mobhook update` afterwards to regenerate hooks.
- `init`, `update` and `list` no longer contact the remote; only `fetch` syncs it.
- Generated hook scripts are quoted differently and honour `MOBHOOK=0`; run
  `mobhook update` to regenerate them.
- The security preset scripts now block on a gitleaks crash, an unusable report or a
  mobsfscan failure, require `jq`, and write reports with mode 600. Tracked `.env`,
  `google-services.json` and similar files now produce findings.
- Bare-number tags (e.g. `0.1.0`) no longer start a release.

### Security
- Hook keys and step names are validated and single-quoted in generated scripts,
  preventing path traversal and shell injection from `mobhook.yaml`.
- Remote presets: https/ssh only, credentials in URLs rejected and redacted in logs,
  symlinks skipped, download and extraction size caps, no fallback to a shared `/tmp`.
  `remote.ref` may be pinned to a commit SHA (a mutable ref only warns).
- The gitleaks auto-install is pinned and verified by SHA-256; custom hooks are backed
  up to a private temp directory.
- The security preset secret gate no longer fails open (gitleaks' own exit code is used),
  temp files use `mktemp` with trap cleanup, `--redact` is on, and raw secret values are
  no longer printed. `FAIL_ON_FINDINGS=1` makes the CI scan exit non-zero.
- Prerelease tags (e.g. `v0.5.0-rc.1`) publish a GitHub prerelease and no longer update
  the Homebrew formula.
- Release workflow now triggers only on strict `vMAJOR.MINOR.PATCH[-prerelease]` tags;
  bare-number tags (e.g. `0.1.0`) no longer start a release.
- New `verify` job runs first: validates the tag (strict SemVer), checks it equals the
  `Cargo.toml` version, requires the tagged commit to be reachable from `origin/main`,
  and runs `cargo test --locked`. Build, release and Homebrew jobs depend on it.
- Least-privilege workflow permissions: `contents: read` by default, `contents: write`
  only on the release job. `ci.yml` gained `permissions: contents: read`.
- Third-party GitHub Actions pinned to full commit SHAs; `cross` installed with
  `--locked` at a fixed tag. Added Dependabot (weekly) for GitHub Actions and Cargo.
- Release builds and CI use `--locked`.
- Releases publish a `SHA256SUMS` asset computed from the built artifacts; the Homebrew
  job verifies downloaded assets against it.
- Homebrew formula is rendered by `.github/scripts/render-formula.sh`, which validates
  the version and checksums, and the tap is pushed without persisting the token in
  `.git/config`. Formula `test do` now asserts the version in `mobhook --version`.
- Checkouts no longer persist credentials.
- Workflow `run:` steps no longer interpolate event data directly.

### Added
- `SECURITY.md`: private reporting section (contact is a placeholder) and supported versions.
- Regression tests for the release scripts and workflows (`tests/release_scripts_test.rs`).

### Changed
- `.gitignore` now excludes `.DS_Store`, `.env*`, key/certificate files,
  Firebase config files and `.hook-reports/`.

## [0.3.0] - 2026-05-28

### Added
- Bundle `ci-security-scan.sh` from darthook into the security preset.

## [0.2.0] - 2026-05-28

### Changed
- Switch config format from TOML to YAML (`mobhook.yaml`).
- Bump version to 0.2.0.

## [0.1.1] - 2026-05-26

### Added
- CI: automatically update the Homebrew tap on release.

## [0.1.0] - 2026-05-22

### Added
- Initial release: CLI skeleton, colored terminal logger, config parser with per-entry
  mode overrides, trait-based preset system with embedded security and flutter-test
  presets, remote sync (git2 clone/pull with HTTP tarball fallback), tool management
  (gitleaks auto-download, mobsfscan pipx auto-install), hook manager with bash script
  generation and `.mobhook/` lifecycle, and the commands `init`, `update`, `create`,
  `fetch`, `list`, `remove`, `doctor`.
- Public repo files: LICENSE, README, CI/CD, contributing guide, security policy.

### Fixed
- Use rustls-tls (no OpenSSL) and fix clippy warnings.
- Add `vendored-openssl` to git2 for cross-platform builds.

[Unreleased]: https://github.com/iqbal-mekari/mobhook/compare/v0.4.2...HEAD
[0.4.2]: https://github.com/iqbal-mekari/mobhook/compare/v0.4.1...v0.4.2
[0.4.1]: https://github.com/iqbal-mekari/mobhook/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/iqbal-mekari/mobhook/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/iqbal-mekari/mobhook/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/iqbal-mekari/mobhook/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/iqbal-mekari/mobhook/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/iqbal-mekari/mobhook/releases/tag/v0.1.0
