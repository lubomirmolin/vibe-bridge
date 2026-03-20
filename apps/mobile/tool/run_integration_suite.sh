#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <simulator-or-emulator-id>" >&2
  exit 64
fi

device_id="$1"
shift || true

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mobile_dir="$(cd "${script_dir}/.." && pwd)"
retries="${INTEGRATION_TEST_RETRIES:-2}"

tests=(
  "integration_test/live_bridge_approval_flow_test.dart"
  "integration_test/live_thread_streaming_test.dart"
  "integration_test/reconnect_offline_cache_test.dart"
)

cd "${mobile_dir}"

run_test() {
  local test_file="$1"
  shift || true
  local attempt=1

  while (( attempt <= retries )); do
    echo "==> [${attempt}/${retries}] flutter test ${test_file} -d ${device_id}"
    flutter clean >/dev/null
    if flutter test "${test_file}" -d "${device_id}" "$@"; then
      return 0
    fi

    if (( attempt == retries )); then
      return 1
    fi

    echo "Retrying ${test_file} after a failed device run..."
    sleep 2
    attempt=$((attempt + 1))
  done
}

for test_file in "${tests[@]}"; do
  run_test "${test_file}" "$@"
done
