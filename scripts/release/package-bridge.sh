#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

PLATFORM="${1:-}"
if [ -z "${PLATFORM}" ]; then
  echo "usage: $(basename "$0") <linux|macos>" >&2
  exit 1
fi

require_command cargo
ensure_dist_dir

ARCH="$(normalize_arch "$(uname -m)")"
ARCHIVE_BASE="$(release_basename bridge-server "${PLATFORM}" "${ARCH}")"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

cargo build --manifest-path "${REPO_ROOT}/Cargo.toml" -p bridge-core --bin bridge-server --release

STAGED_DIR="${TMP_DIR}/${ARCHIVE_BASE}"
mkdir -p "${STAGED_DIR}"
cp "${REPO_ROOT}/target/release/bridge-server" "${STAGED_DIR}/bridge-server"
chmod 755 "${STAGED_DIR}/bridge-server"

tar -C "${TMP_DIR}" -czf "${DIST_DIR}/${ARCHIVE_BASE}.tar.gz" "${ARCHIVE_BASE}"
echo "Created ${DIST_DIR}/${ARCHIVE_BASE}.tar.gz"
