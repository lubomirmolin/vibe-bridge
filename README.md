# Codex Mobile Companion

Flutter Android/iOS companion for local Codex sessions, backed by a Rust bridge and a macOS menu bar shell.

## Workspace

- `apps/mobile` — Flutter mobile app
- `apps/mac-shell` — SwiftUI macOS companion shell
- `crates/bridge-core` — Rust bridge server
- `crates/shared-contracts` / `shared/contracts` — shared contract coverage

## Requirements

- Flutter SDK
- Rust / Cargo
- Xcode for macOS + iOS simulator
- Android SDK / emulator
- Tailscale
- `codex` CLI with `codex app-server`

## Notification scope

Notifications are foreground-only. True background/terminated-app push delivery is out of scope for this local-only build.

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

Optional private route:

```bash
tailscale serve --bg 3110
```

Run the mobile app from `apps/mobile` on an iOS simulator or Android emulator.

## Validation

```bash
.factory/init.sh
```

```bash
# lint
flutter analyze apps/mobile
cargo fmt --manifest-path Cargo.toml --all --check
cargo clippy --manifest-path Cargo.toml --workspace --all-targets -- -D warnings
xcodebuild -project apps/mac-shell/CodexMobileCompanion.xcodeproj -scheme CodexMobileCompanion -destination 'platform=macOS' build >/dev/null
```

```bash
# typecheck
flutter analyze apps/mobile
cargo check --manifest-path Cargo.toml --workspace --all-targets
xcodebuild -project apps/mac-shell/CodexMobileCompanion.xcodeproj -scheme CodexMobileCompanion -destination 'platform=macOS' build >/dev/null
```

```bash
# tests
(cd apps/mobile && flutter test --concurrency=5)
cargo test --manifest-path Cargo.toml --workspace --jobs 5
xcodebuild test -project apps/mac-shell/CodexMobileCompanion.xcodeproj -scheme CodexMobileCompanion -destination 'platform=macOS'
```

```bash
# build
(cd apps/mobile && flutter build apk --debug)
cargo build --manifest-path Cargo.toml --workspace
xcodebuild -project apps/mac-shell/CodexMobileCompanion.xcodeproj -scheme CodexMobileCompanion -destination 'platform=macOS' build
```

### Real-data thread-detail parity

For the canonical real-data regression thread `019d0d0c-07df-7632-81fa-a1636651400a` (`Investigate thread detail sync`), run the live bridge checks directly:

```bash
curl -sf http://127.0.0.1:3110/threads/019d0d0c-07df-7632-81fa-a1636651400a
curl -sf http://127.0.0.1:3110/threads/019d0d0c-07df-7632-81fa-a1636651400a/timeline?limit=80
curl -sf http://127.0.0.1:3110/policy/access-mode
```
