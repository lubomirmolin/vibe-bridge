#!/usr/bin/env bash
set -euo pipefail

if command -v kiss >/dev/null 2>&1; then
  KISS_BIN="$(command -v kiss)"
elif [ -x "${HOME}/.cargo/bin/kiss" ]; then
  KISS_BIN="${HOME}/.cargo/bin/kiss"
else
  echo "kiss is not installed. Expected 'kiss' on PATH or \$HOME/.cargo/bin/kiss." >&2
  exit 1
fi

cd "$(git rev-parse --show-toplevel)"
exec "${KISS_BIN}" check --lang rust "$@" crates
