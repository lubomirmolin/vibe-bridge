# Codex Mobile Companion

Mobile companion for local Codex sessions routed through a host bridge.

## Workspace

- `apps/mobile` — Flutter app for iOS and Android
- `apps/linux-shell` — Flutter Linux host shell
- `apps/mac-shell` — macOS host shell
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

## Ubuntu VM Access

For Linux validation from macOS, the simplest setup is a UTM Ubuntu VM with
`openssh-server` enabled. Discover the guest IP from inside Ubuntu:

```bash
hostname -I
```

Then connect from the Mac host:

```bash
ssh <user>@<vm-ip>
```

If you use a dedicated key for the VM, connect and sync like this:

```bash
ssh -i /path/to/key <user>@<vm-ip>
rsync -az --delete \
  --exclude='.git/' \
  --exclude='**/.dart_tool/' \
  --exclude='**/build/' \
  /path/to/codex-mobile-companion/ \
  <user>@<vm-ip>:/home/<user>/codex-mobile-companion/
```

Inside the VM, rebuild the Linux shell with:

```bash
export PATH="$HOME/toolchain-bin:$HOME/flutter/bin:$HOME/.cargo/bin:$PATH"
cd ~/codex-mobile-companion/apps/linux-shell
flutter clean
flutter pub get
flutter build linux
```

## Validate

```bash
./scripts/release/run-checks.sh
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

## GitHub Automation

The repository now includes:

- `.github/workflows/release.yml` for tagged or manually triggered
  multi-platform release builds
- `./scripts/release/run-checks.sh` for local validation before release

Release builds package:

- the Flutter Android APK
- the Flutter Linux desktop bundle
- the macOS shell app bundle
- standalone `bridge-server` archives for Linux and macOS

See [docs/github-public-release.md](docs/github-public-release.md) for the public-repo checklist, required GitHub secrets, and local release commands.
