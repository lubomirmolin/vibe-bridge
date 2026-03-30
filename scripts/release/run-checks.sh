#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'EOF'
Usage: ./scripts/release/run-checks.sh [target...]

Targets:
  rust        Run Rust formatting, linting, typecheck, and tests.
  mobile      Run Flutter mobile analysis, tests, and debug APK build.
  linux       Run Flutter Linux shell analysis, tests, and release build.
  macos       Run macOS shell build and tests.
  all         Run every target above.

Examples:
  ./scripts/release/run-checks.sh
  ./scripts/release/run-checks.sh rust mobile
  ./scripts/release/run-checks.sh linux
EOF
}

require_targets=()

if [ "$#" -eq 0 ]; then
  require_targets=(all)
else
  require_targets=("$@")
fi

declare -A selected_targets=()

for target in "${require_targets[@]}"; do
  case "${target}" in
    all)
      selected_targets[rust]=1
      selected_targets[mobile]=1
      selected_targets[linux]=1
      selected_targets[macos]=1
      ;;
    rust | mobile | linux | macos)
      selected_targets["${target}"]=1
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown target '${target}'" >&2
      usage >&2
      exit 1
      ;;
  esac
done

run_rust_checks() {
  require_command cargo
  echo "==> Rust checks"
  cargo fmt --manifest-path "${REPO_ROOT}/Cargo.toml" --all --check
  cargo clippy --manifest-path "${REPO_ROOT}/Cargo.toml" --workspace --all-targets -- -D warnings
  cargo check --manifest-path "${REPO_ROOT}/Cargo.toml" --workspace --all-targets
  cargo test --manifest-path "${REPO_ROOT}/Cargo.toml" --workspace --jobs 5
}

run_mobile_checks() {
  require_command flutter
  echo "==> Mobile checks"
  pushd "${REPO_ROOT}/apps/mobile" >/dev/null
  flutter pub get
  flutter analyze --no-fatal-infos --no-fatal-warnings
  flutter test --concurrency=5
  flutter build apk --debug
  popd >/dev/null
}

run_linux_checks() {
  require_command flutter
  echo "==> Linux shell checks"
  pushd "${REPO_ROOT}/apps/linux-shell" >/dev/null
  flutter pub get
  flutter analyze --no-fatal-infos --no-fatal-warnings
  flutter test
  flutter build linux --release
  popd >/dev/null
}

run_macos_checks() {
  require_command cargo
  require_command rustc
  require_command xcodebuild
  echo "==> macOS shell checks"
  local macos_arch
  macos_arch="$(normalize_arch "$(uname -m)")"
  CODEX_MOBILE_COMPANION_CARGO_BIN="$(command -v cargo)" \
  CODEX_MOBILE_COMPANION_RUSTC_BIN="$(command -v rustc)" \
  xcodebuild test \
    -project "${REPO_ROOT}/apps/mac-shell/CodexMobileCompanion.xcodeproj" \
    -scheme CodexMobileCompanion \
    -destination "platform=macOS,arch=${macos_arch}" \
    ONLY_ACTIVE_ARCH=YES \
    CODE_SIGNING_ALLOWED=NO

  CODEX_MOBILE_COMPANION_CARGO_BIN="$(command -v cargo)" \
  CODEX_MOBILE_COMPANION_RUSTC_BIN="$(command -v rustc)" \
  xcodebuild \
    -project "${REPO_ROOT}/apps/mac-shell/CodexMobileCompanion.xcodeproj" \
    -scheme CodexMobileCompanion \
    -configuration Release \
    -destination "platform=macOS,arch=${macos_arch}" \
    ONLY_ACTIVE_ARCH=YES \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build
}

if [[ -n "${selected_targets[rust]:-}" ]]; then
  run_rust_checks
fi

if [[ -n "${selected_targets[mobile]:-}" ]]; then
  run_mobile_checks
fi

if [[ -n "${selected_targets[linux]:-}" ]]; then
  run_linux_checks
fi

if [[ -n "${selected_targets[macos]:-}" ]]; then
  run_macos_checks
fi
