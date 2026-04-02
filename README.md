# Codex Mobile Companion

<!-- Badges -->
<div align="center">

[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-iOS%20%7C%20Android%20%7C%20Linux%20%7C%20macOS-blue?style=flat-square)]()
[![Flutter](https://img.shields.io/badge/Flutter-3.x-blue?style=flat-square)](https://flutter.dev)
[![Rust](https://img.shields.io/badge/Rust-1.75+-orange?style=flat-square)](https://rust-lang.org)

</div>

---

> **Mobile companion app for local Codex sessions** — Securely connect your mobile device to a local Codex AI session through a host bridge, enabling remote command approval, session monitoring, and seamless workflow integration.

<p align="center">
  <img src="docs/assets/architecture.svg" alt="Architecture Overview" width="600"/>
</p>

## Features

### Core Capabilities

- **QR-Based Pairing** — Secure device pairing using Ed25519 identity keys
- **Command Approval** — Approve or reject Codex commands from your mobile device
- **Session Monitoring** — Real-time visibility into active Codex sessions
- **Tailscale Integration** — Secure remote access via your private tailnet
- **Cross-Platform** — Works on iOS, Android, Linux, and macOS

### Architecture Highlights

- **Bridge Core** — Rust-based secure bridge daemon wrapping Codex JSON-RPC
- **Mobile-First** — Flutter app with Riverpod state management
- **No Direct Connection** — All traffic routes through the host bridge (never directly to Codex)
- **Persistent Trust** — Ed25519-based identity for long-lived device trust

## Quick Start

### Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| Flutter SDK | 3.x | Mobile app development |
| Rust / Cargo | 1.75+ | Bridge server |
| Xcode | 15+ | macOS/iOS development |
| Android SDK | API 21+ | Android builds |
| Tailscale | Latest | Remote connectivity |
| Codex CLI | Latest | Local AI session |

### Setup

```bash
# Clone the repository
git clone https://github.com/your-org/codex-mobile-companion.git
cd codex-mobile-companion

# Initialize dependencies
.factory/init.sh
```

### Running

**1. Start Codex app-server:**

```bash
codex app-server --listen ws://127.0.0.1:4222
```

**2. Start the bridge server:**

```bash
cargo run -p bridge-core --bin bridge-server -- \
  --host 127.0.0.1 --port 3110 --admin-port 3111
```

**3. Run the mobile app:**

```bash
cd apps/mobile
flutter run
```

## Project Structure

```
codex-mobile-companion/
├── apps/
│   ├── mobile/          # Flutter app (iOS & Android)
│   ├── linux-shell/     # Flutter Linux desktop shell
│   └── mac-shell/       # SwiftUI macOS companion shell
│
├── crates/
│   ├── bridge-core/      # Rust bridge daemon
│   └── shared-contracts/ # Shared API contracts
│
├── .factory/            # Initialization scripts
├── scripts/             # Build & release scripts
└── docs/                # Documentation
```

## How It Works

```
┌─────────────────┐         ┌─────────────────┐         ┌─────────────────┐
│                 │         │                 │         │                 │
│  Mobile App     │◄───────►│  Bridge Server  │◄───────►│  Codex Session  │
│  (Flutter)      │  WS/REST│  (Rust)         │ JSON-RPC│  (app-server)   │
│                 │         │                 │         │                 │
└─────────────────┘         └─────────────────┘         └─────────────────┘
        │                           │
        │                           │
        ▼                           ▼
┌─────────────────┐         ┌─────────────────┐
│  QR Pairing     │         │  Tailscale Serve│
│  (Ed25519)      │         │  (HTTPS)        │
└─────────────────┘         └─────────────────┘
```

1. **Pairing** — Mobile scans QR code from host; Ed25519 keys establish trust
2. **Connection** — Bridge serves mobile app via Tailscale Serve (HTTPS)
3. **Commands** — Mobile approves/rejects commands via bridge proxy
4. **Sessions** — Bridge monitors Codex state from local SQLite/JSONL

## Live Streaming Correctness

The bridge must preserve Codex live text exactly. For message and plan streaming, the mobile app should see the same text that Codex app-server emits, in the same order, without bridge-added reconstruction artifacts.

### Bug Class We Hit

We investigated a recurring live-text corruption bug where the bridge stream could produce output like:

- `first20 seconds` instead of `first 20 seconds`
- `GIF2.` instead of `GIF\n2.`
- missing markdown markers or indentation before headings and bullets
- earlier duplicate-fragment issues such as repeated chunks on second turns

The important finding was that bridge `/history` often remained clean while raw bridge `/events` was wrong. That means the corruption was happening in the bridge live path, not necessarily in Codex final stored history.

### Root Causes

We found multiple independent bridge bugs:

1. Exact duplicate live assistant frames were being published from two internal bridge paths at the same time:
   - the bridge-owned turn stream
   - the background notification forwarder

2. Whitespace-only live deltas were being dropped by the bridge because publish gating treated `" "` and `"\n"` as empty content.

3. Real Codex `item/*/delta` notifications were being expanded into accumulated full text inside the bridge and then compacted back into deltas again before publication. That extra transform layer could distort separator and markdown boundaries.

4. Desktop IPC snapshot updates were also allowed to emit competing live message events during bridge-owned turns.

### Fixes

The fixes are structural, not post-hoc masking:

1. During a bridge-owned active Codex turn, the bridge does not allow overlapping live publication paths for the same assistant output.

2. Whitespace-only deltas are treated as real live content and are no longer dropped.

3. For Codex text streaming notifications, the bridge now forwards raw upstream deltas instead of reconstructing full text and re-deltafying it.

4. The live compactor is now reserved for snapshot-style full-text sources. Raw Codex text deltas pass through unchanged.

5. Desktop IPC may still refresh snapshots, but it must not publish competing live message events for bridge-owned turns.

### Invariants To Preserve

If you touch bridge live streaming, these must remain true:

1. Raw bridge `/events` for Codex text streaming should match Codex app-server text deltas semantically 1:1.
2. Bridge `/history` and raw bridge `/events` should converge to the same final assistant text for a completed turn.
3. Whitespace-only deltas are valid and must not be filtered out.
4. Only one bridge path should be authoritative for live assistant text during a bridge-owned turn.
5. Snapshot refresh sources must not race with or rewrite active raw text streaming.

### Debugging Recipe

When debugging a live-text issue, verify in this order:

1. Probe Codex app-server directly and compare:
   - raw `item/agentMessage/delta`
   - final `item/completed.item.text`

2. Probe bridge raw `/events` directly and compare it to bridge `/history`.

3. Only after that, check Flutter/controller reconciliation.

This order matters because it tells you whether the bug is:

- upstream in Codex
- introduced in the bridge live path
- or introduced in the mobile merge/replay path

### Regression Coverage

The bridge and app now have targeted regression coverage for this class of issue:

- bridge duplicate live frame detection
- whitespace-only live delta publication
- raw Codex text delta passthrough
- bridge-owned desktop IPC live-event suppression
- live mobile thread creation / second-turn streaming regression

## Development

### Building

```bash
# Flutter analyze
flutter analyze apps/mobile

# Rust format check
cargo fmt --manifest-path Cargo.toml --all --check

# Rust clippy
cargo clippy --manifest-path Cargo.toml --workspace -- -D warnings
```

### Testing

```bash
# Flutter tests
cd apps/mobile && flutter test --concurrency=5

# Rust tests
cargo test --manifest-path Cargo.toml --workspace --jobs 5

# macOS shell
xcodebuild test -project apps/mac-shell/VibeBridgeCompanion.xcodeproj \
  -scheme VibeBridgeCompanion -destination 'platform=macOS'
```

### Building Releases

```bash
# Android APK
cd apps/mobile && flutter build apk --debug

# Linux bundle
cd apps/linux-shell && flutter build linux

# macOS app
xcodebuild -project apps/mac-shell/VibeBridgeCompanion.xcodeproj \
  -scheme VibeBridgeCompanion -destination 'platform=macOS' build

# Rust bridge
cargo build --manifest-path Cargo.toml --workspace
```

## Linux Development (macOS Host)

For testing Linux builds from macOS, use UTM with Ubuntu:

```bash
# Inside Ubuntu VM, discover IP
hostname -I

# From macOS, sync project
rsync -az --delete \
  --exclude='.git/' \
  --exclude='**/.dart_tool/' \
  --exclude='**/build/' \
  /path/to/codex-mobile-companion/ \
  user@<vm-ip>:/home/user/codex-mobile-companion/

# Inside VM, rebuild
cd ~/codex-mobile-companion/apps/linux-shell
flutter clean && flutter pub get && flutter build linux
```

## Resources

| Resource | Link |
|----------|------|
| Documentation | [docs/](docs/) |
| GitHub Releases | [Releases](https://github.com/your-org/codex-mobile-companion/releases) |
| Release Guide | [docs/github-public-release.md](docs/github-public-release.md) |

## Contributing

Contributions are welcome! Please read our guidelines and submit PRs.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

MIT License — see [LICENSE](LICENSE) for details.

---

<div align="center">

**Built with** Flutter · Rust · Tailscale

</div>
