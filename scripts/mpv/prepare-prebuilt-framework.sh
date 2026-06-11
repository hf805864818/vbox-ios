#!/usr/bin/env bash
set -euo pipefail

SOURCE_URL="${1:-}"
FRAMEWORK_KIND="${2:-libmpv}"
WORK_DIR="${3:-mpv-work}"

if [[ -z "$SOURCE_URL" ]]; then
  echo "用法: $0 <source-url> [MPVKit|libmpv] [work-dir]"
  exit 2
fi

case "$FRAMEWORK_KIND" in
  MPVKit|libmpv) ;;
  *)
    echo "❌ FRAMEWORK_KIND 只能是 MPVKit 或 libmpv，当前: $FRAMEWORK_KIND"
    exit 1
    ;;
esac

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR/download" "$WORK_DIR/extracted"

ARCHIVE="$WORK_DIR/download/source"
echo "⬇️ 下载 framework: $SOURCE_URL"
curl -L --fail --retry 3 --retry-delay 5 -o "$ARCHIVE" "$SOURCE_URL"

FILE_TYPE="$(file "$ARCHIVE")"
echo "📄 下载文件类型: $FILE_TYPE"

if echo "$FILE_TYPE" | grep -qi "Zip archive"; then
  unzip -q "$ARCHIVE" -d "$WORK_DIR/extracted"
elif echo "$FILE_TYPE" | grep -qi "gzip compressed"; then
  tar -xzf "$ARCHIVE" -C "$WORK_DIR/extracted"
elif echo "$FILE_TYPE" | grep -qi "bzip2 compressed"; then
  tar -xjf "$ARCHIVE" -C "$WORK_DIR/extracted"
else
  echo "⚠️ 无法识别压缩格式，尝试按 zip 解压"
  unzip -q "$ARCHIVE" -d "$WORK_DIR/extracted"
fi

FOUND="$(find "$WORK_DIR/extracted" -name "${FRAMEWORK_KIND}.xcframework" -type d | head -1 || true)"
if [[ -z "$FOUND" ]]; then
  FOUND="$(find "$WORK_DIR/extracted" -name "*.xcframework" -type d | head -1 || true)"
fi

if [[ -z "$FOUND" ]]; then
  echo "❌ 解压后未找到 .xcframework"
  find "$WORK_DIR/extracted" -maxdepth 4 -type d | sed -n '1,120p'
  exit 1
fi

DEST="$WORK_DIR/${FRAMEWORK_KIND}.xcframework"
rm -rf "$DEST"
cp -R "$FOUND" "$DEST"

echo "✅ 已准备 framework: $DEST"
echo "$DEST"
