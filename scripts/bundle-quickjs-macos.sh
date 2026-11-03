#!/usr/bin/env bash
set -euo pipefail

# 批次 G-03-B：把 libvbox_quickjs.dylib 打入 macOS App Bundle（QuickJS JS 引擎随包分发）。
#
# 背景：域层 `_effectiveEngineType` 将 JS 站点（javaScriptCore）映射为 quickJS，
# 故桌面端 JS 蜘蛛依赖 libvbox_quickjs；缺失时切源分类无数据（见 quickjs_ffi.dart）。
#
# 流程（对齐 bundle-jsc-macos.sh / D28 libmpv 分发模式）：
#   1. scripts/build_quickjs_wrapper.sh 编译 dylib（vendored QuickJS，@rpath 安装名）
#   2. 拷贝 → <App>/Contents/Frameworks/（App 主二进制自带
#      @executable_path/../Frameworks rpath，Dart FFI open("libvbox_quickjs.dylib") 命中）
#   3. ad-hoc re-sign：向 Frameworks 追加 dylib 会使 Flutter 构建签名失效，
#      先签嵌套 dylib 再签 App 本体（entitlements 按构建配置选择）
#   4. dlopen 冒烟：python ctypes 加载验证（签名/依赖/vq_* 语义健全）
#
# 用法：scripts/bundle-quickjs-macos.sh [--config Debug|Release] [--app <path.app>]
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

DYLIB_DIR="$ROOT/build/vbox-quickjs"
bash "$ROOT/scripts/build_quickjs_wrapper.sh" "$DYLIB_DIR"
DYLIB="$DYLIB_DIR/libvbox_quickjs.dylib"

if [[ -z "$APP" ]]; then
  APP="$(ls -d "$ROOT"/build/macos/Build/Products/"$CONFIG"/*.app 2>/dev/null | head -1 || true)"
  if [[ -z "$APP" ]]; then
    echo "❌ 未找到 $CONFIG 产物 .app（先 flutter build macos --${CONFIG}，或用 --app 指定）"
    exit 1
  fi
fi
[[ -d "$APP" ]] || { echo "❌ .app 不存在：$APP"; exit 1; }

mkdir -p "$APP/Contents/Frameworks"
cp "$DYLIB" "$APP/Contents/Frameworks/libvbox_quickjs.dylib"

case "$CONFIG" in
  Debug)   ENT="$ROOT/macos/Runner/DebugProfile.entitlements" ;;
  Release) ENT="$ROOT/macos/Runner/Release.entitlements" ;;
  *) ENT="$ROOT/macos/Runner/Release.entitlements" ;;
esac

codesign --force --sign - "$APP/Contents/Frameworks/libvbox_quickjs.dylib"
codesign --force --sign - --entitlements "$ENT" "$APP"
codesign --verify --verbose=1 "$APP" 2>&1 | tail -1

# dlopen 冒烟：ctypes 绝对路径加载（验证签名链/依赖解析/vq_* 可查）
python3 - "$APP/Contents/Frameworks/libvbox_quickjs.dylib" <<'PY'
import ctypes, sys
lib = ctypes.CDLL(sys.argv[1])
# vq_* 语义冒烟（等价 Dart FFI 路径）：eval 为堆缓冲，复制后须 vq_free_buffer
lib.vq_create_runtime.restype = ctypes.c_void_p
lib.vq_create_context.restype = ctypes.c_void_p
lib.vq_create_context.argtypes = [ctypes.c_void_p]
lib.vq_eval.restype = ctypes.c_void_p
lib.vq_eval.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
lib.vq_free_buffer.argtypes = [ctypes.c_void_p]
lib.vq_free_context.argtypes = [ctypes.c_void_p]
lib.vq_free_runtime.argtypes = [ctypes.c_void_p]
rt = lib.vq_create_runtime()
ctx = lib.vq_create_context(rt)
assert ctx, "vq_create_context 失败"
ptr = lib.vq_eval(ctx, b"21*2")
assert ptr, "vq_eval 返回 NULL"
val = ctypes.string_at(ptr).decode()
assert val == "42", f"vq_eval 异常: {val!r}"
lib.vq_free_buffer(ptr)
lib.vq_free_context(ctx)
lib.vq_free_runtime(rt)
print(f"✅ dlopen + vq_* 语义冒烟通过（eval 21*2 → {val}）")
PY

echo "✅ QuickJS dylib 已随 App 分发：$APP/Contents/Frameworks/libvbox_quickjs.dylib"