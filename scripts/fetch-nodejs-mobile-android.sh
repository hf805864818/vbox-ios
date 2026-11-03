#!/usr/bin/env bash
set -euo pipefail

# 批次 I · ND-01-native：获取 Android Node.js 引擎预编译库（nodejs-mobile）。
#
# 严格对齐 iOS 侧做法（.github/workflows/build-ipa.yml「下载 NodeMobile.xcframework」）：
# 同一官方 release（nodejs-mobile v18.20.4）、同一 curl 3 次重试口径，仅产物形态不同：
#   iOS    → NodeMobile.xcframework（nm/arm64 slice）
#   Android→ include/node/node.h（node::Start 入口头文件）+ bin/<abi>/libnode.so
#
# 官方 Android 集成口径（nodejs-mobile 文档 guide-android/getting-started）：
#   · 头文件 include/node/node.h    → CMake include_directories，供 node::Start；
#   · libnode.so（armeabi-v7a / arm64-v8a / x86_64）→ jniLibs，AGP 随 APK 打包；
#   · JNI 桥 src/main/jni/node_bridge.cpp 编译为 libnode_bridge.so（对齐 iOS NodeRunner.mm）。
#
# 注：官方 v18.20.4 Android 仅 3 ABI（armeabi-v7a / arm64-v8a / x86_64，x86 已停供），
#     与本工程 defaultConfig.ndk.abiFilters 完全一致。
#
# 原生二进制不入 git（同 D28 / libjsc 分发口径）：本地构建 Android 前先跑本脚本；
# CI（flutter-check.yml / build-release-assets.yml 的 android job）已内置本步骤。
#
# 用法：scripts/fetch-nodejs-mobile-android.sh [--force]
# 环境变量：
#   NODEJS_MOBILE_VERSION  官方 tag（默认 v18.20.4，与 iOS 侧同版本）

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JNI_DIR="$ROOT/android/app/src/main/jni"
JNILIBS_DIR="$ROOT/android/app/src/main/jniLibs"
VERSION="${NODEJS_MOBILE_VERSION:-v18.20.4}"
FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

ABIS=(armeabi-v7a arm64-v8a x86_64)

# 幂等：头文件 + 三 ABI 已就位则直接退出（CI 缓存友好）
all_present=1
for abi in "${ABIS[@]}"; do
  [[ -f "$JNILIBS_DIR/$abi/libnode.so" ]] || all_present=0
done
[[ -f "$JNI_DIR/libnode/include/node/node.h" ]] || all_present=0
if [[ $all_present -eq 1 && $FORCE -eq 0 ]]; then
  echo "✅ libnode.so（三 ABI）+ node::Start 头文件已存在，跳过（--force 强制重取）"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

URL="https://github.com/nodejs-mobile/nodejs-mobile/releases/download/${VERSION}/nodejs-mobile-${VERSION}-android.zip"
ZIP="$WORK/nodejs-mobile-android.zip"

echo "⬇️  下载 nodejs-mobile ${VERSION}（Android；同 iOS build-ipa.yml 口径）"
ok=0
for attempt in 1 2 3; do
  echo "   第 ${attempt}/3 次..."
  if curl -L --retry 3 --retry-delay 5 --fail -o "$ZIP" "$URL"; then
    ok=1
    break
  fi
  [[ "$attempt" -lt 3 ]] && sleep $((attempt * 10))
done
[[ $ok -eq 1 && -s "$ZIP" ]] || { echo "❌ nodejs-mobile 下载失败：$URL"; exit 1; }

echo "📦 解包 include/ 与 bin/"
unzip -o -q "$ZIP" -d "$WORK/extract"

# 顶层可能是 include/ + bin/，也可能多一层包装目录 → 用 find 稳健定位
HDR="$(find "$WORK/extract" -type f -path '*/include/node/node.h' | head -1)"
[[ -n "$HDR" ]] || { echo "❌ zip 内未找到 include/node/node.h"; exit 1; }
INC_DIR="$(cd "$(dirname "$HDR")/.." && pwd)"   # → .../include

rm -rf "$JNI_DIR/libnode"
mkdir -p "$JNI_DIR/libnode"
cp -R "$INC_DIR" "$JNI_DIR/libnode/include"
echo "  → jni/libnode/include/node/node.h"

for abi in "${ABIS[@]}"; do
  SO="$(find "$WORK/extract" -type f -path "*/bin/$abi/libnode.so" | head -1)"
  [[ -n "$SO" ]] || { echo "❌ zip 内未找到 bin/$abi/libnode.so"; exit 1; }
  mkdir -p "$JNILIBS_DIR/$abi"
  cp "$SO" "$JNILIBS_DIR/$abi/libnode.so"
  echo "  → jniLibs/$abi/libnode.so（$(du -h "$JNILIBS_DIR/$abi/libnode.so" | cut -f1)）"
done

echo "✅ Android Node 引擎就位（node::Start 头文件 + 三 ABI libnode.so）"