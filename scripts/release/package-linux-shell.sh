#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

require_command cargo
require_command flutter
ensure_dist_dir

APP_ROOT="${REPO_ROOT}/apps/linux-shell"
ARCH="$(normalize_arch "$(uname -m)")"
ARCHIVE_BASE="$(release_basename codex-mobile-companion linux "${ARCH}")"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

pushd "${APP_ROOT}" >/dev/null
flutter pub get
flutter build linux --release
popd >/dev/null

BUNDLE_DIR="$(find "${APP_ROOT}/build/linux" -path '*/release/bundle' -type d | head -n 1)"
if [ -z "${BUNDLE_DIR}" ]; then
  echo "error: Linux release bundle was not produced." >&2
  exit 1
fi

STAGED_BUNDLE_DIR="${TMP_DIR}/${ARCHIVE_BASE}"
mkdir -p "${STAGED_BUNDLE_DIR}"
cp -R "${BUNDLE_DIR}/." "${STAGED_BUNDLE_DIR}/"

tar -C "${TMP_DIR}" -czf "${DIST_DIR}/${ARCHIVE_BASE}.tar.gz" "${ARCHIVE_BASE}"
echo "Created ${DIST_DIR}/${ARCHIVE_BASE}.tar.gz"

if command -v appimagetool >/dev/null 2>&1; then
  pushd "${APP_ROOT}" >/dev/null
  ./tool/build_appimage.sh
  popd >/dev/null

  APPIMAGE_SOURCE="$(find "${APP_ROOT}/build/appimage" -maxdepth 1 -name '*.AppImage' | head -n 1)"
  if [ -n "${APPIMAGE_SOURCE}" ]; then
    cp "${APPIMAGE_SOURCE}" "${DIST_DIR}/${ARCHIVE_BASE}.AppImage"
    echo "Created ${DIST_DIR}/${ARCHIVE_BASE}.AppImage"
  fi
fi
