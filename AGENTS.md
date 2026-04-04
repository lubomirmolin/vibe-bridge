# AI Agent Instructions

This document is the working contract for AI agents in the `codex-mobile-companion` repository. Follow it when making code changes, refactoring, debugging, or validating behavior.

## 1. Project Overview
This repository is a monorepo for a mobile companion app and host-side bridge stack for local Codex sessions. The main parts are:
- **`apps/mobile`**: Flutter mobile app targeting iOS and Android.
- **`apps/linux-shell`**: Flutter Linux host shell.
- **`apps/mac-shell`**: SwiftUI macOS companion shell.
- **`crates/bridge-core`**: Rust bridge server.
- **`crates/shared-contracts`**: Rust shared contracts and schema helpers.
- **`shared/contracts`**: Shared contract fixtures/versioning used across the stack.
- **`packages/codex_ui`**: Shared Flutter UI package.

The system connects a mobile app to a locally running Codex session through a host bridge. First-party host shells currently target Linux and macOS.

## 2. Core Architectural Rules
- **No Direct Codex Connection from Mobile**: The Flutter app must **NEVER** communicate directly with the `codex app-server`. It must always route through our custom `bridge-core`.
- **Bridge Responsibilities**: The host bridge is the source of truth for pairing, trust state, application API exposition, and command approval gating. It securely wraps the local `codex app-server` JSON-RPC interface.
- **Tailscale First**: Remote device-to-device connectivity is built on Tailscale. The bridge binds securely to localhost and is served to the tailnet via Tailscale Serve.
- **Desktop UI Independence**: Do not attempt to automate or scrape the `Codex.app` Electron GUI. Rely on local SQLite/JSONL state under `~/.codex` and the `app-server` runtime protocol.
- **QR Pairing Mechanism**: Trust between mobile and a host bridge is established via a QR-based pairing process generating persistent keys (e.g., Ed25519 identity).

### Codex App-Server Protocol Notes
- **Handshake is two-step, not one-step**: After opening a Codex app-server transport, clients must send `initialize` and then immediately send an `initialized` notification on the same connection. Sending only `initialize` is not enough.
- **Missing `initialized` can break live streaming without breaking requests**: The bridge previously started turns successfully but received no live `item/*` notifications because the transport never sent `initialized`. This presents as "final archive appears later, but no live assistant/tool stream".
- **Live turn stream is carried by JSON-RPC notifications**: After `turn/start`, keep reading the same transport for `turn/started`, `item/started`, item deltas such as `item/agentMessage/delta`, tool output events, `item/completed`, and finally `turn/completed`.
- **`thread/start` auto-subscribes the connection to thread events**: Fresh threads do not need extra subscription logic beyond the normal app-server protocol. `thread/resume` is for continuing an existing thread on a connection.
- **Notification opt-out is exact-match only**: `initialize.params.capabilities.optOutNotificationMethods` suppresses only the exact method names listed. Be careful not to suppress `item/agentMessage/delta` or other `item/*` notifications needed for live mobile streaming.
- **Reference source**: The authoritative app-server implementation/docs for this repo-local debugging flow are in `/Users/lubomirmolin/PhpstormProjects/codex-mobile-companion/tmp/codex/codex-rs/app-server/README.md`, `/Users/lubomirmolin/PhpstormProjects/codex-mobile-companion/tmp/codex/codex-rs/app-server/src/message_processor.rs`, and `/Users/lubomirmolin/PhpstormProjects/codex-mobile-companion/tmp/codex/codex-rs/app-server/src/transport/mod.rs`.

## 3. Tech Stack and Tooling
- **Flutter / Dart** for the mobile app (`apps/mobile`).
  - *Key Packages*: Riverpod (State), Go Router, Freezed (DTOs).
- **Rust / Cargo** for the backend bridge daemon (`crates/`).
- **Swift / Xcode** for the macOS shell (`apps/mac-shell`).
- **Tailscale** for private connectivity layer.

## 4. Development & Validation Commands
Always ensure your changes adhere to linting and type-checking rules. Run these validation commands from the repository root before finalizing any code updates:

### Formatting & Linting
```bash
# Flutter
flutter analyze apps/mobile

# Rust
cargo fmt --manifest-path Cargo.toml --all --check
cargo clippy --manifest-path Cargo.toml --workspace --all-targets -- -D warnings

# macOS Shell
xcodebuild -project apps/mac-shell/VibeBridgeCompanion.xcodeproj -scheme VibeBridgeCompanion -destination 'platform=macOS' build >/dev/null
```

### Typechecking & Tests
```bash
# Flutter
(cd apps/mobile && flutter test --concurrency=5)

# Rust
cargo check --manifest-path Cargo.toml --workspace --all-targets
cargo test --manifest-path Cargo.toml --workspace --jobs 5

# macOS Shell
xcodebuild test -project apps/mac-shell/VibeBridgeCompanion.xcodeproj -scheme VibeBridgeCompanion -destination 'platform=macOS'
```

### Build Commands
```bash
# Mobile (Android APK)
(cd apps/mobile && flutter build apk --debug)

# Rust Bridge
cargo build --manifest-path Cargo.toml --workspace

# macOS Shell
xcodebuild -project apps/mac-shell/VibeBridgeCompanion.xcodeproj -scheme VibeBridgeCompanion -destination 'platform=macOS' build
```

## 5. Working Guidelines for Agents
- **Sync Contracts**: When modifying the API layer between the Flutter app and the Bridge, ensure updates are properly synchronized in the `shared-contracts`.
- **Formatting**: Always apply native formatters (`cargo fmt`, `dart format`) to modified files.
- **Consistency**: Keep mobile UI code dense, prioritizing a coding-tool aesthetic with clear monospaced outputs for logs and terminal content.
- **Resilience**: Assume mobile connections drop often; ensure WebSockets in the mobile app handle reconnections securely.
- **Do Not Repeat Yourself**: Prefer extracting shared logic, helpers, widgets, or types instead of copying behavior into multiple places. Do not preserve obvious duplication just to keep a change narrowly local.
- **Finish the Task Completely**: Do not stop at a partial repair, temporary workaround, or "good enough for now" patch. Do the full fix in the same pass whenever reasonably possible, including the follow-through needed to keep the codebase coherent.
- **No Stopgap Framing**: Avoid approaches justified as the fastest way to stop a regression if they knowingly leave structural problems behind. The default expectation is to implement the correct fix from the start, not a band-aid that someone else has to finish later.
- **Refactor When Needed**: If the right fix requires refactoring for reuse, separation of concerns, or readability, do that work as part of the task instead of treating refactoring as optional cleanup.
- **File Size Discipline**: Keep files below 1000 lines of code when practical. `1500` lines is the absolute hard limit for any code file. If a file is trending large, split responsibilities before adding more weight.
- **Prefer Cohesive Modules**: Do not solve file-size limits by scattering tiny abstractions with unclear ownership. Split code along meaningful boundaries so each file has one understandable job.

You can read claude code source code in the /claudecodesrc folder
