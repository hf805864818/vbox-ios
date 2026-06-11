#!/usr/bin/env bash
set -euo pipefail

OUTPUT_DIR="${1:-mpv-artifacts}"
BUILD_ROOT="${BUILD_ROOT:-ffmpegkit-source-build}"
KINGS_LAY_REPO="${KINGS_LAY_REPO:-https://github.com/kingslay/FFmpegKit.git}"
KINGS_LAY_REF="${KINGS_LAY_REF:-main}"
KINGS_LAY_PLATFORMS="${KINGS_LAY_PLATFORMS:-platforms=ios,isimulator}"
KINGS_LAY_USE_PREBUILT="${KINGS_LAY_USE_PREBUILT:-true}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUTPUT_DIR="$REPO_ROOT/$OUTPUT_DIR"
BUILD_ROOT="$REPO_ROOT/$BUILD_ROOT"
CHECKOUT_DIR="$BUILD_ROOT/FFmpegKit"

log() {
  echo ""
  echo "==> $*"
}

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "❌ 缺少工具: $1"
    exit 1
  fi
}

checkout_source() {
  mkdir -p "$BUILD_ROOT"
  if [[ -d "$CHECKOUT_DIR/.git" ]]; then
    log "更新 FFmpegKit: $KINGS_LAY_REF"
    git -C "$CHECKOUT_DIR" fetch --depth 1 origin "$KINGS_LAY_REF"
    git -C "$CHECKOUT_DIR" checkout FETCH_HEAD
  else
    log "克隆 FFmpegKit: $KINGS_LAY_REF"
    rm -rf "$CHECKOUT_DIR"
    git clone --depth 1 --branch "$KINGS_LAY_REF" "$KINGS_LAY_REPO" "$CHECKOUT_DIR"
  fi
}

build_libmpv() {
  log "使用 kingslay/FFmpegKit 构建 libmpv"
  pushd "$CHECKOUT_DIR" >/dev/null

  swift package --disable-sandbox BuildFFmpeg \
    "$KINGS_LAY_PLATFORMS" \
    enable-libfreetype \
    enable-libfribidi \
    enable-libharfbuzz \
    enable-libass \
    enable-FFmpeg \
    enable-libmpv

  popd >/dev/null
}

dump_build_logs() {
  echo ""
  echo "==> FFmpegKit 内部构建日志"
  if [[ ! -d "$CHECKOUT_DIR/.Script" ]]; then
    echo "未发现 .Script 日志目录"
    return 0
  fi

  find "$CHECKOUT_DIR/.Script" -name "*.log" -type f | sort | while read -r log_file; do
    echo ""
    echo "----- $log_file -----"
    tail -200 "$log_file" || true
  done
}

package_framework() {
  local framework_path="$1"
  log "找到 libmpv.xcframework: $framework_path"
  "$SCRIPT_DIR/package-xcframework.sh" "$framework_path" "$OUTPUT_DIR" "libmpv"
}

find_libmpv_xcframework() {
  local found
  found="$(find "$CHECKOUT_DIR" -name "libmpv.xcframework" -type d | head -1 || true)"
  if [[ -z "$found" ]]; then
    found="$(find "$CHECKOUT_DIR" -iname "*mpv*.xcframework" -type d | head -1 || true)"
  fi

  if [[ -z "$found" ]]; then
    echo "❌ 未找到 libmpv.xcframework"
    echo "已发现的 xcframework:"
    find "$CHECKOUT_DIR" -name "*.xcframework" -type d | sed -n '1,120p'
    exit 1
  fi

  echo "$found"
}

main() {
  require_tool git
  require_tool swift
  require_tool xcodebuild

  mkdir -p "$OUTPUT_DIR"
  checkout_source

  local prebuilt_framework="$CHECKOUT_DIR/Sources/libmpv.xcframework"
  if [[ "$KINGS_LAY_USE_PREBUILT" == "true" && -d "$prebuilt_framework" ]]; then
    log "使用 kingslay/FFmpegKit 仓库自带的 Sources/libmpv.xcframework"
    package_framework "$prebuilt_framework"
    return 0
  fi

  if ! build_libmpv; then
    dump_build_logs
    exit 1
  fi

  local framework_path
  framework_path="$(find_libmpv_xcframework)"
  package_framework "$framework_path"
}

main "$@"
