#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${1:-$(pwd)}"
OUTPUT_DIR="${2:-$ROOT_DIR/vbox/Libraries/MPV}"
SOURCE_URL="${MPVKIT_SOURCE_URL:-}"
RELEASE_TAG="${MPVKIT_RELEASE_TAG:-}"
ASSET_NAME="${MPVKIT_ASSET_NAME:-MPVKit.xcframework.zip}"

mkdir -p "$OUTPUT_DIR"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

ZIP_PATH="$WORK_DIR/$ASSET_NAME"

echo "MPVKit 下载目标目录：$OUTPUT_DIR"

if [ -n "$SOURCE_URL" ]; then
  echo "使用 MPVKIT_SOURCE_URL 下载：$SOURCE_URL"
  curl -L --fail --retry 3 --retry-delay 2 -o "$ZIP_PATH" "$SOURCE_URL"
else
  if ! command -v gh >/dev/null 2>&1; then
    echo "未找到 gh CLI，且未提供 MPVKIT_SOURCE_URL。"
    exit 2
  fi

  if [ -z "$RELEASE_TAG" ]; then
    RELEASE_TAG="$(gh release list --limit 50 --json tagName --jq '.[] | select(.tagName | startswith("mpvkit-wrapper-")) | .tagName' | head -1)"
  fi

  if [ -z "$RELEASE_TAG" ]; then
    echo "未找到 mpvkit-wrapper-* Release。请先在 rebuild-8db3547 分支运行 MPVKit 构建并发布 Release，或设置 MPVKIT_SOURCE_URL。"
    exit 3
  fi

  echo "从 Release 下载 MPVKit：$RELEASE_TAG / $ASSET_NAME"
  gh release download "$RELEASE_TAG" --pattern "$ASSET_NAME" --dir "$WORK_DIR" --clobber
fi

if [ ! -f "$ZIP_PATH" ]; then
  FOUND_ZIP="$(find "$WORK_DIR" -maxdepth 1 -name '*.zip' -type f | head -1)"
  if [ -n "$FOUND_ZIP" ]; then
    ZIP_PATH="$FOUND_ZIP"
  fi
fi

if [ ! -f "$ZIP_PATH" ]; then
  echo "未找到 MPVKit.xcframework.zip。"
  find "$WORK_DIR" -maxdepth 2 -print
  exit 4
fi

rm -rf "$OUTPUT_DIR/MPVKit.xcframework"
ditto -x -k "$ZIP_PATH" "$OUTPUT_DIR"

if [ ! -d "$OUTPUT_DIR/MPVKit.xcframework" ]; then
  echo "解压后未找到 MPVKit.xcframework。"
  find "$OUTPUT_DIR" -maxdepth 3 -print
  exit 5
fi

echo "MPVKit.xcframework 已准备完成：$OUTPUT_DIR/MPVKit.xcframework"
find "$OUTPUT_DIR/MPVKit.xcframework" -maxdepth 2 -name Info.plist -print
