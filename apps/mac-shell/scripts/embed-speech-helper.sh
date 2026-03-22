#!/bin/sh

set -eu

PRODUCT_BINARY_DIR="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/bin"
PRODUCT_BINARY_PATH="${PRODUCT_BINARY_DIR}/CodexSpeechHelper"
HELPER_BINARY_PATH="${BUILT_PRODUCTS_DIR}/CodexSpeechHelper"

if [ ! -x "${HELPER_BINARY_PATH}" ]; then
  echo "error: bundled speech helper was not built at ${HELPER_BINARY_PATH}" >&2
  exit 1
fi

echo "Embedding CodexSpeechHelper into app bundle"
mkdir -p "${PRODUCT_BINARY_DIR}"
cp "${HELPER_BINARY_PATH}" "${PRODUCT_BINARY_PATH}"
chmod 755 "${PRODUCT_BINARY_PATH}"

echo "Embedded speech helper at ${PRODUCT_BINARY_PATH}"
