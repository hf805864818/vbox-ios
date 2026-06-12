#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

DEFAULT_URL="https://github.com/hf805864818/vbox-ios/releases/download/mpvkit-deps-0.0.1/MPVKit-xcframework.zip"
MPVKIT_DEPS_URL="${MPVKIT_DEPS_URL:-$DEFAULT_URL}"
MPVKIT_DEPS_SHA256_URL="${MPVKIT_DEPS_SHA256_URL:-${MPVKIT_DEPS_URL}.sha256}"
MPVKIT_DEPS_CACHE_DIR="${MPVKIT_DEPS_CACHE_DIR:-.mpv-cache}"

mkdir -p "$MPVKIT_DEPS_CACHE_DIR"

ARCHIVE_PATH="$MPVKIT_DEPS_CACHE_DIR/MPVKit-xcframework.zip"
SHA256_PATH="$MPVKIT_DEPS_CACHE_DIR/MPVKit-xcframework.zip.sha256"

echo "下载 MPVKit 依赖包:"
echo "  $MPVKIT_DEPS_URL"

curl -L --fail --retry 3 --retry-delay 3 -o "$ARCHIVE_PATH" "$MPVKIT_DEPS_URL"

echo "下载 sha256:"
echo "  $MPVKIT_DEPS_SHA256_URL"
if curl -L --fail --retry 3 --retry-delay 3 -o "$SHA256_PATH" "$MPVKIT_DEPS_SHA256_URL"; then
    EXPECTED_SHA="$(awk '{print $1}' "$SHA256_PATH" | head -1)"
    ACTUAL_SHA="$(shasum -a 256 "$ARCHIVE_PATH" | awk '{print $1}')"
    if [ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]; then
        echo "sha256 校验失败"
        echo "  expected: $EXPECTED_SHA"
        echo "  actual:   $ACTUAL_SHA"
        exit 1
    fi
    echo "sha256 校验通过: $ACTUAL_SHA"
else
    echo "未下载到 sha256 文件，跳过校验。"
fi

scripts/install_mpv_dependencies.sh "$ARCHIVE_PATH"
python3 scripts/check_mpv_installed_dependencies.py
