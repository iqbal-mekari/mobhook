# mobhook

Mobile-first git hooks manager — like [Husky](https://github.com/typicode/husky), but for mobile devs. Manage hooks, pull rules from a remote repo, and run security scans with a single CLI.

## Features

- **Zero-dependency install** — `brew install mobhook` and it works. No SDKs, no runtime deps.
- **Built-in security scanning** — Ships with [gitleaks](https://github.com/gitleaks/gitleaks) (secret detection) and [mobsfscan](https://github.com/MobSF/mobsfscan) (mobile security patterns)
- **Preset-based hooks** — Install ready-made presets or create custom hooks
- **Remote rule sync** — Centralize hook rules in a git repo, pulled in by `mobhook fetch`
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
# 1. Initialize — creates mobhook.yaml and .mobhook/
mobhook init

# 2. Edit mobhook.yaml to configure your hooks

# 3. Apply changes
mobhook update
```

## Commands

| Command | Description |
|---------|-------------|
| `mobhook init [--force] [path]` | Create `mobhook.yaml`, set up `.mobhook/` and `core.hooksPath` (no network) |
| `mobhook update` | Regenerate `.mobhook/` from `mobhook.yaml` (no network) |
| `mobhook create <name>` | Scaffold a custom hook |
| `mobhook fetch <preset>` | Install a bundled preset; the only command that syncs `remote` rules |
| `mobhook list` | Show available/installed presets and custom hooks (local only) |
| `mobhook remove` | Remove mobhook from the project |
| `mobhook doctor` | Check tools, validate `mobhook.yaml`, report issues |

## Configuration

`mobhook.yaml` in your project root:

```yaml
# Global mode: "blocking" (default, abort on failure) or "warning" (continue)
mode: warning

# Optional: rules fetched by `mobhook fetch` from a remote git repo
remote:
  url: https://github.com/your-org/hook-rules.git
  ref: main   # default "main"; pin a full commit SHA instead (recommended)

# Hook definitions: each key is a git hook type
hooks:
  pre-push:
    order:
      - name: security
        mode: blocking   # per-step override
      - flutter-test     # short form, inherits global mode
  pre-commit:
    order: []
```

`mode` also accepts `block` / `warn` as aliases.

## Security & validation rules

`mobhook.yaml` is validated on every command that loads it (`init`, `update`, `fetch`, `list`, `doctor`):

- **Hook types** must be a client-side git hook: `applypatch-msg`, `pre-applypatch`, `post-applypatch`, `pre-commit`, `pre-merge-commit`, `prepare-commit-msg`, `commit-msg`, `post-commit`, `pre-rebase`, `post-checkout`, `post-merge`, `pre-push`, `pre-auto-gc`, `post-rewrite`, `sendemail-validate`, `fsmonitor-watchman`, `post-index-change`, `reference-transaction`. Anything else is rejected.
- **Step and hook names** (`order` entries, `mobhook create <name>`) match `^[a-z0-9]([a-z0-9\-]*[a-z0-9])?$`: lowercase letters, digits and inner hyphens (e.g. `lint-check`).
- **`remote.url`** must be `https://...`, `ssh://...` or scp-style `user@host:path`. `http://`, `git://`, `file://` and local paths are rejected.
- **No credentials in URLs.** A URL with a password, or a user/token in an `https://` URL, is rejected. Use a git credential helper (`git config credential.helper`) for `https://` or an SSH key in `ssh-agent` for `ssh://`.
- **Pin `remote.ref` to a full commit SHA** so synced rules cannot change underneath you. A branch or tag still works but prints a warning.
- **`MOBHOOK=0`** makes the generated hook scripts exit 0 immediately (kill switch).

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

# Add to mobhook.yaml:
# hooks:
#   pre-commit:
#     order:
#       - lint-check

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
