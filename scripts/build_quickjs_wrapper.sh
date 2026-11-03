#!/usr/bin/env bash
# 编译 vbox QuickJS FFI wrapper（G-03-B-1）—— 纯 C，三端通用（CI ubuntu 验证用）。
#
# 用法：scripts/build_quickjs_wrapper.sh [输出目录]
# 默认输出到 /tmp/vbox_quickjs_build/，产物 libvbox_quickjs.so（Windows 为 .dll）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-/tmp/vbox_quickjs_build}"
QJS="$ROOT/quickjs/quickjs-2024-01-13"

mkdir -p "$OUT"

CC="${CC:-gcc}"
EXT="so"
case "$(uname -s)" in
  Darwin) EXT="dylib" ;;
  MINGW*|MSYS*|CYGWIN*) EXT="dll" ;;
esac

# 与 quickjs 官方 Makefile 一致的必要宏（CONFIG_BIGNUM=y：bignum/十进制大数，
# 缺失会导致 libbf.c bfdec_* undefined reference；_GNU_SOURCE 对齐官方 DEFINES）
DEFS=(-D_GNU_SOURCE -DCONFIG_BIGNUM -DCONFIG_VERSION="\"$(cat "$QJS/VERSION" 2>/dev/null || echo 2024-01-13)\"")
LIBS=()
LDFLAGS=()
if [ "$EXT" = "dylib" ]; then
  LIBS=(-lm)
  # @rpath 安装名 → App Bundle 的 Contents/Frameworks 经 rpath 命中（对齐 bundle-jsc-macos.sh）
  LDFLAGS=(-Wl,-install_name,@rpath/libvbox_quickjs.dylib)
elif [ "$EXT" = "so" ]; then
  LIBS=(-lm)
elif [ "$EXT" = "dll" ]; then
  # mingw-w64（QuickJS 依赖 __int128/__attribute__，MSVC 无法编译）：静态链
  # winpthread / libgcc，避免随包分发 libwinpthread-1.dll / libgcc_s_*.dll。
  LIBS=(-static-libgcc -Wl,-Bstatic -lwinpthread -Wl,-Bdynamic)
fi

"$CC" -shared -fPIC -O2 "${DEFS[@]}" -I "$QJS" "${LDFLAGS[@]}" -o "$OUT/libvbox_quickjs.$EXT" \
  "$ROOT/quickjs/wrapper.c" \
  "$QJS/quickjs.c" \
  "$QJS/cutils.c" \
  "$QJS/libbf.c" \
  "$QJS/libregexp.c" \
  "$QJS/libunicode.c" \
  "${LIBS[@]}"

echo "✅ 编译完成：$OUT/libvbox_quickjs.$EXT"
