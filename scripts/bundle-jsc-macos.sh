#!/usr/bin/env bash
set -euo pipefail

# 批次 Q · Q-04：把 libvbox_jsc.dylib 打入 macOS App Bundle（JSC 主引擎随包分发）。
#
# 流程（对齐 D28 libmpv 的分发模式）：
#   1. scripts/build-jsc-macos.sh 编译 dylib（系统 JavaScriptCore.framework）
#   2. 拷贝 → <App>/Contents/Frameworks/（App 主二进制自带
#      @executable_path/../Frameworks rpath，Dart FFI open("libvbox_jsc.dylib")
#      与 MainFlutterWindow 的 Swift dlopen 预加载均经 rpath 命中）
#   3. ad-hoc re-sign：向 Frameworks 追加 dylib 会使 Flutter 构建签名失效，
#      先签嵌套 dylib 再签 App 本体（entitlements 按构建配置选择）
#   4. dlopen 冒烟：python ctypes 加载验证（签名/依赖/符号健全）
#
# 用法：scripts/bundle-jsc-macos.sh [--config Debug|Release] [--app <path.app>]
#   --config  Flutter 构建配置（决定 .app 搜索目录与 entitlements；默认 Release）
#   --app     显式 .app 路径（跳过自动定位）
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

CONFIG="Release"
APP=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG="$2"; shift 2 ;;
    --app)    APP="$2"; shift 2 ;;
    *) echo "用法: $0 [--config Debug|Release] [--app <path.app>]"; exit 1 ;;
  esac
done

DYLIB_DIR="$ROOT/build/vbox-jsc/macos"
bash "$ROOT/scripts/build-jsc-macos.sh" "$DYLIB_DIR"
DYLIB="$DYLIB_DIR/libvbox_jsc.dylib"

if [[ -z "$APP" ]]; then
  APP="$(ls -d "$ROOT"/build/macos/Build/Products/"$CONFIG"/*.app 2>/dev/null | head -1 || true)"
  if [[ -z "$APP" ]]; then
    echo "❌ 未找到 $CONFIG 产物 .app（先 flutter build macos --${CONFIG}，或用 --app 指定）"
    exit 1
  fi
fi
[[ -d "$APP" ]] || { echo "❌ .app 不存在：$APP"; exit 1; }

mkdir -p "$APP/Contents/Frameworks"
cp "$DYLIB" "$APP/Contents/Frameworks/libvbox_jsc.dylib"

case "$CONFIG" in
  Debug)   ENT="$ROOT/macos/Runner/DebugProfile.entitlements" ;;
  Release) ENT="$ROOT/macos/Runner/Release.entitlements" ;;
  *) ENT="$ROOT/macos/Runner/Release.entitlements" ;;
esac

codesign --force --sign - "$APP/Contents/Frameworks/libvbox_jsc.dylib"
codesign --force --sign - --entitlements "$ENT" "$APP"
codesign --verify --verbose=1 "$APP" 2>&1 | tail -1

# dlopen 冒烟：ctypes 绝对路径加载（验证签名链/依赖解析/vj_* 可查）
python3 - "$APP/Contents/Frameworks/libvbox_jsc.dylib" <<'PY'
import ctypes, sys
lib = ctypes.CDLL(sys.argv[1])
# vj_* 语义冒烟（等价 Dart FFI 路径）：eval 结果为原生 malloc 缓冲，
# 以 c_void_p 持有地址复制后必须回传 vj_free_string（对齐 jsc_ffi.dart）
lib.vj_create_context.restype = ctypes.c_void_p
lib.vj_eval.restype = ctypes.c_void_p
lib.vj_eval.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
lib.vj_free_string.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
ctx = lib.vj_create_context(None)
assert ctx, "vj_create_context 失败"
ptr = lib.vj_eval(ctx, b"21*2")
assert ptr, "vj_eval 返回 NULL"
val = ctypes.string_at(ptr).decode()
assert val == "42", f"vj_eval 异常: {val!r}"
lib.vj_free_string(None, ptr)
print(f"✅ dlopen + vj_* 语义冒烟通过（eval 21*2 → {val}）")
PY

echo "✅ JSC dylib 已随 App 分发：$APP/Contents/Frameworks/libvbox_jsc.dylib"
