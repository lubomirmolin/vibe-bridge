#!/usr/bin/env bash
set -euo pipefail

REPAIR_ONLY=0

if [ "${1:-}" = "--repair-only" ]; then
  REPAIR_ONLY=1
elif [ -n "${1:-}" ]; then
  echo "Unsupported argument: $1" >&2
  echo "Usage: $0 [--repair-only]" >&2
  exit 2
fi

resolve_android_sdk_root() {
  for candidate in "${ANDROID_SDK_ROOT:-}" "${ANDROID_HOME:-}" "$HOME/Library/Android/sdk" "$HOME/Android/Sdk"; do
    if [ -z "$candidate" ]; then
      continue
    fi

    if [ -x "$candidate/emulator/emulator" ] && [ -d "$candidate/system-images" ]; then
      echo "$candidate"
      return 0
    fi
  done

  return 1
}

ANDROID_SDK_ROOT_RESOLVED="$(resolve_android_sdk_root || true)"
if [ -z "$ANDROID_SDK_ROOT_RESOLVED" ]; then
  echo "Unable to resolve Android SDK root. Set ANDROID_SDK_ROOT or install the SDK in ~/Library/Android/sdk." >&2
  exit 1
fi

export ANDROID_SDK_ROOT="$ANDROID_SDK_ROOT_RESOLVED"
export ANDROID_HOME="$ANDROID_SDK_ROOT_RESOLVED"

if [ -x "$ANDROID_SDK_ROOT/cmdline-tools/latest/bin/avdmanager" ]; then
  AVDMANAGER_BIN="$ANDROID_SDK_ROOT/cmdline-tools/latest/bin/avdmanager"
elif command -v avdmanager >/dev/null 2>&1; then
  AVDMANAGER_BIN="$(command -v avdmanager)"
else
  echo "Could not find avdmanager in Android SDK or PATH." >&2
  exit 1
fi

ANDROID_AVD_HOME="${ANDROID_AVD_HOME:-$HOME/.android/avd}"
export ANDROID_AVD_HOME
mkdir -p "$ANDROID_AVD_HOME"

ensure_system_image() {
  local package_id="$1"
  local package_path
  package_path="$ANDROID_SDK_ROOT/$(printf '%s' "$package_id" | tr ';' '/')"
  if [ ! -d "$package_path" ]; then
    echo "Missing required Android system image: $package_id" >&2
    echo "Install with: \"$ANDROID_SDK_ROOT/cmdline-tools/latest/bin/sdkmanager\" \"$package_id\"" >&2
    exit 1
  fi
}

ensure_avd() {
  local avd_name="$1"
  local package_id="$2"
  local device_id="$3"
  local ini_path="$ANDROID_AVD_HOME/$avd_name.ini"
  local avd_path="$ANDROID_AVD_HOME/$avd_name.avd"
  local resolved_ini_path=""

  if [ -f "$ini_path" ]; then
    resolved_ini_path="$(awk -F'=' '/^path=/{print $2}' "$ini_path")"
  fi

  if [ -n "$resolved_ini_path" ] && [ -d "$resolved_ini_path" ]; then
    echo "AVD ready: $avd_name"
    return 0
  fi

  echo "Repairing AVD: $avd_name"
  rm -f "$ini_path"
  rm -rf "$avd_path"

  printf 'no\n' | "$AVDMANAGER_BIN" create avd \
    --force \
    --name "$avd_name" \
    --package "$package_id" \
    --device "$device_id" \
    --path "$avd_path" >/dev/null
}

while IFS='|' read -r avd_name package_id device_id; do
  ensure_system_image "$package_id"
  ensure_avd "$avd_name" "$package_id" "$device_id"
done <<'EOF'
Pixel_6_Pro_API_34|system-images;android-34;google_apis;arm64-v8a|pixel_6_pro
Pixel_3a_API_34_extension_level_7_arm64-v8a|system-images;android-34;google_apis;arm64-v8a|pixel_3a
Medium_Tablet_API_34|system-images;android-34;google_apis;arm64-v8a|medium_tablet
Wear_OS_Large_Round_API_33|system-images;android-33;android-wear;arm64-v8a|wearos_large_round
EOF

android_avds="$($ANDROID_SDK_ROOT/emulator/emulator -list-avds | awk 'NF')"
if [ -z "$android_avds" ]; then
  echo "No Android AVD definitions are available after repair." >&2
  exit 1
fi

if [ "$REPAIR_ONLY" -eq 1 ]; then
  echo "Android emulator repair completed. Available AVDs:"
  printf '%s\n' "$android_avds"
  exit 0
fi

echo "Running flutter emulators"
emulators_output="$(flutter emulators)"
printf '%s\n' "$emulators_output"

android_emulator_count="$(printf '%s\n' "$emulators_output" | awk '/[[:space:]]android$/ {count++} END {print count+0}')"
if [ "$android_emulator_count" -lt 1 ]; then
  echo "Expected at least one Android emulator target in flutter emulators output." >&2
  exit 1
fi

echo "Running flutter devices"
flutter devices

echo "Android validation harness completed successfully."
