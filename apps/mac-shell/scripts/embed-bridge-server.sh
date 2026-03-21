#!/bin/sh

set -eu

REPO_ROOT="$(cd "${SRCROOT}/../.." && pwd)"
MANIFEST_PATH="${REPO_ROOT}/Cargo.toml"
PRODUCT_BINARY_DIR="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/bin"
PRODUCT_BINARY_PATH="${PRODUCT_BINARY_DIR}/bridge-server"

resolve_cargo() {
  if [ -n "${CODEX_MOBILE_COMPANION_CARGO_BIN:-}" ] && [ -x "${CODEX_MOBILE_COMPANION_CARGO_BIN}" ]; then
    printf '%s\n' "${CODEX_MOBILE_COMPANION_CARGO_BIN}"
    return 0
  fi

  if command -v cargo >/dev/null 2>&1; then
    command -v cargo
    return 0
  fi

  for candidate in \
    "${HOME}/.cargo/bin/cargo" \
    "/opt/homebrew/bin/cargo" \
    "/usr/local/bin/cargo"
  do
    if [ -x "${candidate}" ]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  echo "error: cargo not found. Set CODEX_MOBILE_COMPANION_CARGO_BIN or install Rust so Xcode can reach cargo." >&2
  echo "PATH=${PATH}" >&2
  exit 1
}

CARGO_BIN="$(resolve_cargo)"
RUST_BIN_DIR="$(dirname "${CARGO_BIN}")"

resolve_rustc() {
  if [ -n "${CODEX_MOBILE_COMPANION_RUSTC_BIN:-}" ] && [ -x "${CODEX_MOBILE_COMPANION_RUSTC_BIN}" ]; then
    printf '%s\n' "${CODEX_MOBILE_COMPANION_RUSTC_BIN}"
    return 0
  fi

  if [ -x "${RUST_BIN_DIR}/rustc" ]; then
    printf '%s\n' "${RUST_BIN_DIR}/rustc"
    return 0
  fi

  if command -v rustc >/dev/null 2>&1; then
    command -v rustc
    return 0
  fi

  for candidate in \
    "${HOME}/.cargo/bin/rustc" \
    "/opt/homebrew/bin/rustc" \
    "/usr/local/bin/rustc"
  do
    if [ -x "${candidate}" ]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  echo "error: rustc not found. Set CODEX_MOBILE_COMPANION_RUSTC_BIN or install Rust so Xcode can reach rustc." >&2
  echo "PATH=${PATH}" >&2
  exit 1
}

RUSTC_BIN="$(resolve_rustc)"

export PATH="${RUST_BIN_DIR}:${PATH}"
export RUSTC="${RUSTC_BIN}"

case "${CONFIGURATION}" in
  Release)
    CARGO_PROFILE_FLAG="--release"
    CARGO_TARGET_SUBDIR="release"
    ;;
  *)
    CARGO_PROFILE_FLAG=""
    CARGO_TARGET_SUBDIR="debug"
    ;;
esac

echo "Embedding bridge-server-next into app bundle"
mkdir -p "${PRODUCT_BINARY_DIR}"

cd "${REPO_ROOT}"

"${CARGO_BIN}" build \
  --manifest-path "${MANIFEST_PATH}" \
  -p bridge-core \
  --bin bridge-server-next \
  ${CARGO_PROFILE_FLAG}

cp "${REPO_ROOT}/target/${CARGO_TARGET_SUBDIR}/bridge-server-next" "${PRODUCT_BINARY_PATH}"
chmod 755 "${PRODUCT_BINARY_PATH}"

echo "Embedded rewrite bridge helper at ${PRODUCT_BINARY_PATH}"
