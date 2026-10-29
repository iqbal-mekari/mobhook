# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Security
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

[Unreleased]: https://github.com/iqbal-mekari/mobhook/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/iqbal-mekari/mobhook/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/iqbal-mekari/mobhook/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/iqbal-mekari/mobhook/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/iqbal-mekari/mobhook/releases/tag/v0.1.0
