#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
APPDIR="${APP_ROOT}/build/appimage/CodexMobileCompanion.AppDir"

case "$(uname -m)" in
  x86_64)
    FLUTTER_ARCH="x64"
    APPIMAGE_ARCH="x86_64"
    ;;
  aarch64 | arm64)
    FLUTTER_ARCH="arm64"
    APPIMAGE_ARCH="aarch64"
    ;;
  *)
    echo "Unsupported architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

BUNDLE_DIR="${APP_ROOT}/build/linux/${FLUTTER_ARCH}/release/bundle"
OUTPUT_IMAGE="${APP_ROOT}/build/appimage/CodexMobileCompanion-${APPIMAGE_ARCH}.AppImage"

if ! command -v appimagetool >/dev/null 2>&1; then
  echo "appimagetool is required to package the Linux shell as an AppImage." >&2
  exit 1
fi

pushd "${APP_ROOT}" >/dev/null
flutter build linux
popd >/dev/null

rm -rf "${APPDIR}"
mkdir -p "${APPDIR}/usr"

cp -R "${BUNDLE_DIR}/." "${APPDIR}/usr/"
install -Dm755 "${APP_ROOT}/linux/packaging/AppRun" "${APPDIR}/AppRun"
install -Dm644 \
  "${APP_ROOT}/linux/packaging/codex-mobile-companion.desktop" \
  "${APPDIR}/codex-mobile-companion.desktop"
install -Dm644 \
  "${APP_ROOT}/linux/packaging/codex-mobile-companion.svg" \
  "${APPDIR}/codex-mobile-companion.svg"

appimagetool "${APPDIR}" "${OUTPUT_IMAGE}"
echo "Created ${OUTPUT_IMAGE}"
