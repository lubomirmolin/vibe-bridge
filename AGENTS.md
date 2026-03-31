# AI Agent Instructions

Welcome! This document provides context, architectural rules, and guidelines for AI agents working in the `codex-mobile-companion` repository. Please read and adhere to these guidelines when making code changes, refactoring, or assisting with development.

## 1. Project Overview
This repository contains a mobile companion app for local Codex sessions. It's a monorepo consisting of:
- **`apps/mobile`**: Flutter mobile app targeting iOS and Android.
- **`apps/linux-shell`**: Flutter Linux host shell.
- **`apps/mac-shell`**: SwiftUI macOS companion shell.
- **`crates/bridge-core`**: Rust bridge server.
- **`crates/shared-contracts`**: Shared API contracts across the stack.

The system connects a mobile app to a locally running Codex session through a host bridge. First-party host shells currently target Linux and macOS.

## 2. Core Architectural Rules
- **No Direct Codex Connection from Mobile**: The Flutter app must **NEVER** communicate directly with the `codex app-server`. It must always route through our custom `bridge-core`.
- **Bridge Responsibilities**: The host bridge is the source of truth for pairing, trust state, application API exposition, and command approval gating. It securely wraps the local `codex app-server` JSON-RPC interface.
- **Tailscale First**: Remote device-to-device connectivity is built on Tailscale. The bridge binds securely to localhost and is served to the tailnet via Tailscale Serve.
- **Desktop UI Independence**: Do not attempt to automate or scrape the `Codex.app` Electron GUI. Rely on local SQLite/JSONL state under `~/.codex` and the `app-server` runtime protocol.
- **QR Pairing Mechanism**: Trust between mobile and a host bridge is established via a QR-based pairing process generating persistent keys (e.g., Ed25519 identity).

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
