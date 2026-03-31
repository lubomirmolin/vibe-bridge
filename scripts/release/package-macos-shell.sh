#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

require_command cargo
require_command rustc
require_command xcodebuild
ensure_dist_dir

DERIVED_DATA_PATH="${REPO_ROOT}/build/macos-shell"
APP_PATH="${DERIVED_DATA_PATH}/Build/Products/Release/VibeBridgeCompanion.app"
ARCH="$(normalize_arch "$(uname -m)")"
ARCHIVE_PATH="${DIST_DIR}/$(release_basename codex-mobile-companion macos "${ARCH}").zip"

rm -rf "${DERIVED_DATA_PATH}"

CODEX_MOBILE_COMPANION_CARGO_BIN="$(command -v cargo)" \
CODEX_MOBILE_COMPANION_RUSTC_BIN="$(command -v rustc)" \
xcodebuild \
  -project "${REPO_ROOT}/apps/mac-shell/VibeBridgeCompanion.xcodeproj" \
  -scheme VibeBridgeCompanion \
  -configuration Release \
  -destination "platform=macOS,arch=${ARCH}" \
  -derivedDataPath "${DERIVED_DATA_PATH}" \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

if [ ! -d "${APP_PATH}" ]; then
  echo "error: macOS app bundle was not produced at ${APP_PATH}" >&2
  exit 1
fi

ditto -c -k --sequesterRsrc --keepParent "${APP_PATH}" "${ARCHIVE_PATH}"
echo "Created ${ARCHIVE_PATH}"
