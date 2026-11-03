#!/usr/bin/env bash
set -euo pipefail

# 批次 Q · Q-02：获取 Android JSC 预编译 .so（四 ABI）。
#
# 来源：RN 生态官方产物 `jsc-android` npm 包（org.webkit/android-jsc AAR，
# WebKit r250231，LGPL-2.1 + BSD-2 双许可，动态链接合规口径见
# docs/评估_JSC_Windows可行性.md §3.3；体积/许可正式核销在 Q-06）。
#
# 产物：android/app/src/main/jniLibs/<abi>/libjsc.so
#   armeabi-v7a / arm64-v8a / x86 / x86_64
# AGP 自动将 src/main/jniLibs 打入 APK 的 lib/<abi>/，System.loadLibrary
# 经 MainActivity 触发后，libvbox_jsc.so（NDK 编译 jsc/wrapper.c）按
# SONAME 解析到同目录 libjsc.so。
#
# 原生二进制不入 git 仓库（同 D28 libmpv 分发决策），本地构建 Android
# 前必须先跑本脚本；CI（build-jsc.yml android job / build-release-assets.yml
# apk job）已内置本步骤。
#
# 用法：scripts/fetch-jsc-android.sh [--force]
# 环境变量：
#   JSC_ANDROID_VERSION  npm 版本（默认 250231.0.0，即 WebKit r250231）
#   NPM_REGISTRY         npm 镜像覆盖（默认 https://registry.npmjs.org）

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT/android/app/src/main/jniLibs"
VERSION="${JSC_ANDROID_VERSION:-250231.0.0}"
REGISTRY="${NPM_REGISTRY:-https://registry.npmjs.org}"
FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

ABIS=(armeabi-v7a arm64-v8a x86 x86_64)

# 幂等：四 ABI 已就位则直接退出（CI 缓存友好）
all_present=1
for abi in "${ABIS[@]}"; do
  [[ -f "$OUT_DIR/$abi/libjsc.so" ]] || all_present=0
done
if [[ $all_present -eq 1 && $FORCE -eq 0 ]]; then
  echo "✅ libjsc.so（四 ABI）已存在，跳过（--force 强制重取）"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "⬇️  下载 jsc-android@${VERSION}（npm pack）"
TARBALL="$WORK/jsc-android.tgz"
curl -fSL --retry 3 "$REGISTRY/jsc-android/-/jsc-android-$VERSION.tgz" -o "$TARBALL"

echo "📦 解包 AAR 与头文件"
tar xzf "$TARBALL" -C "$WORK" \
  "package/dist/org/webkit/android-jsc/r${VERSION%%.*}/android-jsc-r${VERSION%%.*}.aar"
mkdir -p "$WORK/aar"
unzip -o -q "$WORK/package/dist/org/webkit/android-jsc/r${VERSION%%.*}/android-jsc-r${VERSION%%.*}.aar" \
  'jni/*/libjsc.so' -d "$WORK/aar"

for abi in "${ABIS[@]}"; do
  src="$WORK/aar/jni/$abi/libjsc.so"
  [[ -f "$src" ]] || { echo "❌ AAR 缺少 $abi/libjsc.so"; exit 1; }
  mkdir -p "$OUT_DIR/$abi"
  cp "$src" "$OUT_DIR/$abi/libjsc.so"
  echo "  → jniLibs/$abi/libjsc.so（$(du -h "$OUT_DIR/$abi/libjsc.so" | cut -f1)）"
done

echo "✅ Android JSC 预编译库就位（四 ABI，android/app/src/main/jniLibs/）"
