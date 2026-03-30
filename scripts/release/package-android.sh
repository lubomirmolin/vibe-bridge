#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

decode_base64_to_file() {
  local payload="${1:?base64 payload required}"
  local output_path="${2:?output path required}"

  mkdir -p "$(dirname "${output_path}")"
  if base64 --help 2>&1 | grep -q -- '--decode'; then
    printf '%s' "${payload}" | base64 --decode >"${output_path}"
  else
    printf '%s' "${payload}" | base64 -D >"${output_path}"
  fi
}

require_command flutter
ensure_dist_dir

if [ -n "${ANDROID_KEYSTORE_BASE64:-}" ] && [ -z "${ANDROID_KEYSTORE_PATH:-}" ]; then
  export ANDROID_KEYSTORE_PATH="${REPO_ROOT}/apps/mobile/android/upload-keystore.jks"
  decode_base64_to_file "${ANDROID_KEYSTORE_BASE64}" "${ANDROID_KEYSTORE_PATH}"
fi

has_release_signing=true
for signing_var in \
  ANDROID_KEYSTORE_PATH \
  ANDROID_KEYSTORE_PASSWORD \
  ANDROID_KEY_ALIAS \
  ANDROID_KEY_PASSWORD
do
  if [ -z "${!signing_var:-}" ]; then
    has_release_signing=false
    break
  fi
done

if [ "${REQUIRE_ANDROID_RELEASE_SIGNING:-0}" = "1" ] && [ "${has_release_signing}" != "true" ]; then
  echo "error: tagged Android releases require ANDROID_KEYSTORE_BASE64 or ANDROID_KEYSTORE_PATH plus the release signing secrets." >&2
  exit 1
fi

pushd "${REPO_ROOT}/apps/mobile" >/dev/null
flutter pub get
flutter build apk \
  --release \
  --build-name "$(resolve_release_version)" \
  --build-number "$(resolve_build_number)"
popd >/dev/null

APK_SOURCE="${REPO_ROOT}/apps/mobile/build/app/outputs/flutter-apk/app-release.apk"
APK_TARGET="${DIST_DIR}/$(release_basename codex-mobile-companion android universal).apk"

cp "${APK_SOURCE}" "${APK_TARGET}"
echo "Created ${APK_TARGET}"
