#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DIST_DIR="${DIST_DIR:-${REPO_ROOT}/dist}"

require_command() {
  local command_name="${1:?command name required}"
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "error: required command not found: ${command_name}" >&2
    exit 1
  fi
}

ensure_dist_dir() {
  mkdir -p "${DIST_DIR}"
}

pubspec_version() {
  sed -n 's/^version:[[:space:]]*//p' "${REPO_ROOT}/apps/mobile/pubspec.yaml" | head -n 1
}

resolve_release_version() {
  if [ -n "${RELEASE_VERSION:-}" ]; then
    printf '%s\n' "${RELEASE_VERSION}"
    return 0
  fi

  if [ -n "${GITHUB_REF_NAME:-}" ] && [[ "${GITHUB_REF_NAME}" == v* ]]; then
    printf '%s\n' "${GITHUB_REF_NAME#v}"
    return 0
  fi

  local version
  version="$(pubspec_version)"
  printf '%s\n' "${version%%+*}"
}

resolve_build_number() {
  if [ -n "${RELEASE_BUILD_NUMBER:-}" ]; then
    printf '%s\n' "${RELEASE_BUILD_NUMBER}"
    return 0
  fi

  local version
  version="$(pubspec_version)"
  if [[ "${version}" == *+* ]]; then
    printf '%s\n' "${version#*+}"
    return 0
  fi

  printf '1\n'
}

normalize_arch() {
  case "${1:?architecture required}" in
    x86_64 | amd64)
      printf 'x86_64\n'
      ;;
    arm64 | aarch64)
      printf 'arm64\n'
      ;;
    *)
      printf '%s\n' "$1"
      ;;
  esac
}

release_basename() {
  local name="${1:?artifact name required}"
  local platform="${2:?platform required}"
  local arch="${3:?architecture required}"

  printf '%s-%s-%s-%s\n' \
    "${name}" \
    "${platform}" \
    "${arch}" \
    "$(resolve_release_version)"
}
