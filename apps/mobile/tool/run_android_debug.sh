#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ANDROID_DIR="$APP_DIR/android"

export CARGO_HOME="${HOME}/.cargo"
export RUSTUP_HOME="${HOME}/.rustup"
case ":${PATH}:" in
  *":${CARGO_HOME}/bin:"*) ;;
  *) export PATH="${CARGO_HOME}/bin:${PATH}" ;;
esac

if [ -x "${ANDROID_DIR}/gradlew" ]; then
  (
    cd "$ANDROID_DIR"
    ./gradlew --stop >/dev/null 2>&1 || true
  )
fi

cd "$APP_DIR"
exec flutter run "$@"
