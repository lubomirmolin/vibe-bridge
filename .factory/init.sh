#!/usr/bin/env bash
set -euo pipefail

ROOT="/Users/lubomirmolin/PhpstormProjects/codex-mobile-companion"

if [ ! -d "$ROOT/.git" ]; then
  git init "$ROOT" >/dev/null 2>&1 || true
fi

if [ -f "$ROOT/apps/mobile/pubspec.yaml" ]; then
  flutter pub get --directory "$ROOT/apps/mobile"
fi

if [ -f "$ROOT/Cargo.toml" ]; then
  cargo fetch --manifest-path "$ROOT/Cargo.toml"
fi

if command -v rustup >/dev/null 2>&1 && [ -f "$ROOT/apps/mobile/pubspec.yaml" ]; then
  rustup target add \
    --toolchain stable \
    aarch64-linux-android \
    armv7-linux-androideabi \
    x86_64-linux-android \
    i686-linux-android
fi

if ! command -v codex >/dev/null 2>&1; then
  echo "warning: codex CLI not found in PATH; real-data thread validation will be limited" >&2
fi

if command -v adb >/dev/null 2>&1; then
  adb start-server >/dev/null 2>&1 || true
fi

if [ -f "$ROOT/apps/mac-shell/CodexMobileCompanion.xcodeproj/project.pbxproj" ]; then
  xcodebuild -project "$ROOT/apps/mac-shell/CodexMobileCompanion.xcodeproj" -scheme CodexMobileCompanion -list >/dev/null
fi
