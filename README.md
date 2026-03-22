# Codex Mobile Companion

Mobile companion for local Codex sessions.

## Workspace

- `apps/mobile` — Flutter app for iOS and Android
- `apps/mac-shell` — macOS companion shell
- `crates/bridge-core` — Rust bridge server
- `crates/shared-contracts` — shared API contracts

## Requirements

- Flutter SDK
- Rust / Cargo
- Xcode
- Android SDK
- Tailscale
- `codex` CLI with `codex app-server`

## Setup

```bash
.factory/init.sh
```

## Run

Start Codex app-server:

```bash
codex app-server --listen ws://127.0.0.1:4222
```

Start the bridge:

```bash
cargo run --manifest-path Cargo.toml -p bridge-core --bin bridge-server -- --host 127.0.0.1 --port 3110 --admin-port 3111
```

Run the mobile app from `apps/mobile`.

## Validate

```bash
flutter analyze apps/mobile
cargo fmt --manifest-path Cargo.toml --all --check
cargo check --manifest-path Cargo.toml --workspace --all-targets
cargo test --manifest-path Cargo.toml --workspace --jobs 5
```
