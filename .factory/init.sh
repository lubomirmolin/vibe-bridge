#!/bin/bash
# Mission initialization script — runs at start of each worker session
set -euo pipefail

REPO_ROOT="/Users/lubomirmolin/PhpstormProjects/codex-mobile-companion"

# Check Flutter dependencies
cd "$REPO_ROOT/apps/mobile"
flutter pub get 2>/dev/null || true

# Check Rust compilation
cargo check --manifest-path "$REPO_ROOT/Cargo.toml" --workspace --all-targets 2>/dev/null || true

# Ensure adb port forwarding is set up
ADB="$HOME/Library/Android/sdk/platform-tools/adb"
BRIDGE_PORT=3210

# Check if emulator is accessible
if $ADB devices 2>/dev/null | grep -q "emulator-5554"; then
  $ADB -s emulator-5554 reverse tcp:$BRIDGE_PORT tcp:$BRIDGE_PORT 2>/dev/null || true
fi

echo "Init complete"
