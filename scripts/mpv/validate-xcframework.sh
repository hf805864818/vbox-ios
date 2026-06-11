#!/usr/bin/env bash
set -euo pipefail

XCFRAMEWORK_PATH="${1:-}"
EXPECTED_NAME="${2:-}"

if [[ -z "$XCFRAMEWORK_PATH" ]]; then
  echo "用法: $0 <path-to-xcframework> [expected-name]"
  exit 2
fi

if [[ ! -d "$XCFRAMEWORK_PATH" ]]; then
  echo "❌ 未找到 xcframework: $XCFRAMEWORK_PATH"
  exit 1
fi

if [[ "${XCFRAMEWORK_PATH##*.}" != "xcframework" ]]; then
  echo "❌ 目标不是 .xcframework: $XCFRAMEWORK_PATH"
  exit 1
fi

if [[ -n "$EXPECTED_NAME" && "$(basename "$XCFRAMEWORK_PATH")" != "$EXPECTED_NAME.xcframework" ]]; then
  echo "❌ framework 名称不匹配，期望: $EXPECTED_NAME.xcframework，实际: $(basename "$XCFRAMEWORK_PATH")"
  exit 1
fi

INFO_PLIST="$XCFRAMEWORK_PATH/Info.plist"
if [[ ! -f "$INFO_PLIST" ]]; then
  echo "❌ 缺少 Info.plist: $INFO_PLIST"
  exit 1
fi

echo "📦 检查: $XCFRAMEWORK_PATH"
echo "📄 Info.plist: $INFO_PLIST"

AVAILABLE_LIBS="$(plutil -extract AvailableLibraries xml1 -o - "$INFO_PLIST" 2>/dev/null || true)"
if [[ -z "$AVAILABLE_LIBS" ]]; then
  echo "❌ 无法读取 AvailableLibraries"
  exit 1
fi

echo "🔎 可用 slice:"
plutil -p "$INFO_PLIST" | sed -n '/AvailableLibraries/,$p' | sed -n '1,120p'

if ! plutil -p "$INFO_PLIST" | grep -q "ios-arm64"; then
  echo "❌ 未发现 iOS 真机 arm64 slice，无法用于 iPhone 真机"
  exit 1
fi

if plutil -p "$INFO_PLIST" | grep -q "ios-arm64.*simulator\\|ios-arm64_x86_64-simulator"; then
  echo "✅ 包含模拟器 slice"
else
  echo "⚠️ 未发现模拟器 slice，后续可能只能真机测试"
fi

SIZE="$(du -sh "$XCFRAMEWORK_PATH" | awk '{print $1}')"
echo "📏 大小: $SIZE"
echo "✅ xcframework 验证通过"
