# Contributing to mobhook

Thanks for your interest in contributing!

## Development Setup

1. Install Rust: https://rustup.rs
2. Clone the repo:
   ```bash
   git clone https://github.com/iqbal-mekari/mobhook.git
   cd mobhook
   ```
3. Build and test:
   ```bash
   cargo build
   cargo test
   ```

## Running Locally

```bash
cargo run -- init          # run mobhook init
cargo run -- doctor        # run mobhook doctor
cargo run -- --help        # show help
```

## Code Style

- Run `cargo fmt` before committing
- Run `cargo clippy` and fix all warnings
- Write tests for new functionality

## Pull Requests

1. Fork the repo
2. Create a feature branch
3. Make your changes with tests
4. Submit a PR with a clear description

## Adding a New Preset

1. Create `src/presets/your_preset.rs` implementing the `Preset` trait
2. Add preset files to `presets/your_preset/`
3. Register in `src/presets/mod.rs`
4. Add tests

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
