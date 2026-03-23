# Codex Mobile Companion

Mobile companion for local Codex sessions.

## Workspace

- `apps/mobile` — Flutter app for iOS and Android
- `apps/linux-shell` — Flutter Linux host shell
- `apps/mac-shell` — macOS companion shell
- `crates/bridge-core` — Rust bridge server
- `crates/shared-contracts` — shared API contracts

## Requirements

- Flutter SDK
- Rust / Cargo
- Xcode
- Android SDK
- GTK 3 development headers for Linux desktop builds
- `libayatana-appindicator3-dev` for Linux tray support
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

Run the Linux host shell from `apps/linux-shell`:

```bash
(cd apps/linux-shell && flutter run -d linux)
```

The Linux app supervises a local `bridge-server`, bundles that helper into the
desktop artifact at build time, and resolves `codex` from
`CODEX_MOBILE_COMPANION_CODEX_BINARY`, then `PATH`, then common user-local
locations.

## Validate

```bash
flutter analyze apps/mobile
(cd apps/linux-shell && flutter analyze)
cargo fmt --manifest-path Cargo.toml --all --check
cargo check --manifest-path Cargo.toml --workspace --all-targets
cargo test --manifest-path Cargo.toml --workspace --jobs 5
(cd apps/linux-shell && flutter test)
```

## Linux Packaging

Build the Linux desktop bundle:

```bash
(cd apps/linux-shell && flutter build linux)
```

Package the bundle as an AppImage when `appimagetool` is installed:

```bash
./apps/linux-shell/tool/build_appimage.sh
```
