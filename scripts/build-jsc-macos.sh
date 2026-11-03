#!/usr/bin/env bash
set -euo pipefail

# 批次 Q · Q-04：编译 macOS libvbox_jsc.dylib（系统 JavaScriptCore.framework，零第三方依赖）。
#
# 产物：libvbox_jsc.dylib（install name = @rpath/libvbox_jsc.dylib）
# 用途：
#   · build-jsc.yml build-macos job：产物上传 + vj_* ABI smoke
#   · scripts/bundle-jsc-macos.sh：随 App 分发（Contents/Frameworks，
#     经主二进制 @executable_path/../Frameworks rpath 被 Dart FFI / Swift dlopen 解析）
#
# 用法：scripts/build-jsc-macos.sh [输出目录]（默认 <repo>/build/vbox-jsc/macos）
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/build/vbox-jsc/macos}"

mkdir -p "$OUT"

# install name 设为 @rpath/...：拷入 App Frameworks 后由 LC_RPATH 解析（D28 同款），
# 不携带编译机绝对路径。
clang -shared -fPIC -O2 \
  -framework JavaScriptCore \
  "$ROOT/jsc/wrapper.c" \
  -o "$OUT/libvbox_jsc.dylib"

install_name_tool -id @rpath/libvbox_jsc.dylib "$OUT/libvbox_jsc.dylib"

echo "✅ 编译完成：$OUT/libvbox_jsc.dylib"
otool -D "$OUT/libvbox_jsc.dylib"
