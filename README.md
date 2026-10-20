# mobhook

Mobile-first git hooks manager — like [Husky](https://github.com/typicode/husky), but for mobile devs. Manage hooks, sync rules from remote, and run security scans with a single CLI.

## Features

- **Zero-dependency install** — `brew install mobhook` and it works. No SDKs, no runtime deps.
- **Built-in security scanning** — Ships with [gitleaks](https://github.com/gitleaks/gitleaks) (secret detection) and [mobsfscan](https://github.com/MobSF/mobsfscan) (mobile security patterns)
- **Preset-based hooks** — Install ready-made presets or create custom hooks
- **Remote rule sync** — Centralize hook rules in a git repo, auto-sync across projects
- **Ordered execution** — Control step order and per-step blocking/warning mode
- **Global kill switch** — `MOBHOOK=0` disables all hooks

## Installation

### Homebrew (recommended)

```bash
brew tap iqbal-mekari/mobhook
brew install mobhook
```

### From source

```bash
git clone https://github.com/iqbal-mekari/mobhook.git
cd mobhook
cargo install --path .
```

## Quick Start

```bash
# 1. Initialize — creates mobhook.toml and .mobhook/
mobhook init

# 2. Edit mobhook.toml to configure your hooks

# 3. Apply changes
mobhook update
```

## Commands

| Command | Description |
|---------|-------------|
| `mobhook init` | Create `mobhook.toml` and set up `.mobhook/` |
| `mobhook update` | Sync remote presets + regenerate `.mobhook/` |
| `mobhook create <name>` | Scaffold a custom hook |
| `mobhook fetch <preset>` | Install a bundled preset |
| `mobhook list` | Show available/installed presets and custom hooks |
| `mobhook remove` | Remove mobhook from the project |
| `mobhook doctor` | Check tools, validate config, report issues |

## Configuration

`mobhook.toml` in your project root:

```toml
# Global mode: "blocking" (abort on failure) or "warning" (continue)
mode = "warning"

# Optional: sync rules from a remote git repo
[remote]
url = "https://github.com/your-org/hook-rules.git"
ref = "main"

# Hook definitions
[hooks.pre-push]
order = [
    { name = "security", mode = "blocking" },
    "quality-report",   # must come after security (reads its reports)
    "flutter-test",
]

[hooks.pre-commit]
order = []
```

## Built-in Presets

| Preset | What it does |
|--------|-------------|
| `security` | Runs gitleaks (secret detection) + mobsfscan (mobile security patterns) |
| `flutter-test` | Runs `flutter test` |
| `quality-report` | Local SonarQube-style summary (Security, Reliability, Maintainability, Accepted issues, Coverage, Duplications, Security Hotspots) written to `.hook-reports/quality-report.md` |

### quality-report

A lightweight, local, latest-state approximation of the SonarQube "Overall Code" tiles for Flutter, Android and iOS projects. No server, no container, no history.

**Ordering:** list `security` before `quality-report`. Security and Security Hotspots are read from `.hook-reports/gitleaks-report.json` and `mobsfscan-report.json`; nothing is scanned twice. Without them those tiles show "not available".

| Tile | Source |
|------|--------|
| Security | gitleaks findings + mobsfscan `ERROR` findings, rating from worst severity |
| Reliability | `dart analyze` errors and a short list of bug-prone rules, detekt `potential-bugs` |
| Maintainability | remaining `dart analyze`, detekt and SwiftLint findings, rating from estimated debt ratio |
| Accepted issues | findings matched by `baseline.txt` |
| Coverage | `flutter test --coverage` (`coverage/lcov.info`), lines hit / lines to cover |
| Duplications | `jscpd` over `lib/`, `android/`, `ios/`, duplicated lines / total lines |
| Security Hotspots | mobsfscan `WARNING`/`INFO` findings, rating from share of hotspots accepted in `baseline.txt` |

**Tools** (a missing tool turns its tile into "not available"; the hook never crashes): `jq` (required), `dart` + `flutter`, `jscpd`, `detekt` (Android Kotlin), `swiftlint` (iOS, macOS only). `mobhook doctor` reports which are present.

**Configuration** (files in the installed preset folder):

- `thresholds.conf`: A-E bands, debt effort per smell, duplication limits and the optional gate. Bands follow the standard Sonar scheme (ASSUMPTION; confirm against the SonarQube docs).
- `baseline.txt`: accepted issues, one `tool|rule|file` fingerprint per line, `*` wildcards allowed.

**Modes:** report-only by default (always exit 0). Set `FAIL_ON_RATING_WORSE_THAN`, `FAIL_ON_COVERAGE_BELOW` or `FAIL_ON_DUPLICATION_ABOVE` in `thresholds.conf` and use `mode: blocking` to reject pushes. `MOBHOOK=0` and `--no-verify` skip it like any hook. It runs the full test suite and linters, so prefer `pre-push` or on-demand use. If `flutter-test` is also configured, set `QUALITY_REPORT_REUSE_COVERAGE=1` to reuse an existing `coverage/lcov.info` instead of running tests twice.

**Known parity gap vs SonarQube:** Sonar computes metrics server-side with its own rule engine. This preset normalizes different linters into one issue model (bug/smell/vulnerability/hotspot with severity), so counts and ratings will differ from a Sonar dashboard. There is no "New Code" period, no trends, and no Android Lint integration (detekt only). Hotspot "review" is approximated by the baseline file.

## Custom Hooks

```bash
# Create a custom hook
mobhook create lint-check

# Edit .mobhook/lint-check/script.sh with your logic

# Add to mobhook.toml:
# [hooks.pre-commit]
# order = ["lint-check"]

# Apply
mobhook update
```

## How It Works

1. `mobhook init` creates `.mobhook/` and sets `core.hooksPath`
2. Preset folders are installed into `.mobhook/`
3. Combined bash scripts are generated per hook type
4. Commit `.mobhook/` to share with your team

## Skipping Hooks

```bash
git push --no-verify          # skip for one operation
export MOBHOOK=0              # disable globally
```

## License

MIT — see [LICENSE](LICENSE).
