#!/usr/bin/env bash
set -euo pipefail

XCFRAMEWORK_PATH="${1:-}"
OUTPUT_DIR="${2:-mpv-artifacts}"
EXPECTED_NAME="${3:-}"

if [[ -z "$XCFRAMEWORK_PATH" ]]; then
  echo "用法: $0 <path-to-xcframework> [output-dir] [expected-name]"
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

"$SCRIPT_DIR/validate-xcframework.sh" "$XCFRAMEWORK_PATH" "$EXPECTED_NAME"

mkdir -p "$OUTPUT_DIR"
ABS_OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
ABS_XCFRAMEWORK="$(cd "$(dirname "$XCFRAMEWORK_PATH")" && pwd)/$(basename "$XCFRAMEWORK_PATH")"
BASE_NAME="$(basename "$ABS_XCFRAMEWORK" .xcframework)"
ZIP_PATH="$ABS_OUTPUT_DIR/${BASE_NAME}.xcframework.zip"

rm -f "$ZIP_PATH"
(
  cd "$(dirname "$ABS_XCFRAMEWORK")"
  ditto -c -k --sequesterRsrc --keepParent "$(basename "$ABS_XCFRAMEWORK")" "$ZIP_PATH"
)

echo "📦 已打包: $ZIP_PATH"
ls -lh "$ZIP_PATH"

if command -v shasum >/dev/null 2>&1; then
  shasum -a 256 "$ZIP_PATH" | tee "$ZIP_PATH.sha256"
fi

echo "✅ 打包完成"
