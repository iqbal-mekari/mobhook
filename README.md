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
