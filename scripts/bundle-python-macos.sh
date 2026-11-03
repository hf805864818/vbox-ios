#!/usr/bin/env bash
set -euo pipefail
# ND-02-desktop：把内置 CPython（python-build-standalone）+ lxml + 纯 py 依赖
# 随 macOS .app 分发（<App>/Contents/Resources/pyruntime），让桌面端 `.py` 源可用。
#   **落点必须是 Contents/Resources（数据区）**：codesign 把 Contents/MacOS 下整棵
#   子树视为代码，`python-stdlib/**/*.py` 会被判为「未签名的嵌套代码」而令 App
#   重签失败（Node 仅单个 Mach-O，故放 MacOS 无碍）。
#   1. 下载固定版本 pbs install_only（.python-cache 缓存 + sha256 校验）；
#   2. 解压 python/ → <App>/Contents/Resources/pyruntime/（bin/python3 + lib/）；
#   3. pip 安装 lxml（官方 cp314 wheel，免编译）；
#   4. 拷 assets/python-stdlib → pyruntime/python-stdlib；
#   5. 裁剪 tkinter/idlelib/turtledemo/ensurepip/tcl/__pycache__ 减小体积；
#   6. ad-hoc 递归签名（嵌套 Mach-O：python3 / *.dylib / *.so 均须签）；
#   7. 冒烟：bin/python3 校验解释器 + lxml + base.spider 可导入。
# 用法：scripts/bundle-python-macos.sh [--config Debug|Release] [--app <path.app>]
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# ── 锚定 python-build-standalone（astral-sh）tag 20261009 / CPython 3.14.8 ──
PBS_TAG="20261009"
PYTHON_VERSION="3.14.8"
SHA_ARM64="ff8e1ddc02a9df3190b62d5af475cb642a02cfc77901ef780f9826cc23b51934"
SHA_X64="9694bf8c8c1fb1250dd6f05e7914ebbbe7180e0f11b7feaf5edb2f6acebe4153"
# lxml 版本：**不能沿用 iOS 的 5.4.0** —— 5.4.0 仅发到 cp313，CPython 3.14 无 wheel，
# pip 会退化为源码编译并因缺 libxml2 头文件失败；6.0.1 起才提供 cp314 wheel。
LXML_VERSION="6.1.3"

CONFIG="Release"; APP=""
while [[ $# -gt 0 ]]; do case "$1" in
  --config) CONFIG="$2"; shift 2 ;;
  --app)    APP="$2"; shift 2 ;;
  *) echo "用法: $0 [--config Debug|Release] [--app <path.app>]"; exit 1 ;;
esac; done

# pbs 无官方 universal2 → 与 bundle-node-macos.sh 一致：按宿主架构取单架构包
ARCH="$(uname -m)"
case "$ARCH" in
  arm64)  PBS_TARGET="aarch64-apple-darwin"; EXPECTED="$SHA_ARM64" ;;
  x86_64) PBS_TARGET="x86_64-apple-darwin";  EXPECTED="$SHA_X64" ;;
  *) echo "❌ 不支持的架构：$ARCH"; exit 1 ;;
esac
ASSET="cpython-$PYTHON_VERSION+$PBS_TAG-$PBS_TARGET-install_only.tar.gz"

CACHE="$ROOT/.python-cache"; mkdir -p "$CACHE"
TARBALL="$CACHE/$ASSET"
if [[ ! -f "$TARBALL" ]]; then
  echo "⬇️  下载 https://github.com/astral-sh/python-build-standalone/releases/download/$PBS_TAG/${ASSET}（内置 CPython，ND-02-desktop）"
  curl -fsSL "https://github.com/astral-sh/python-build-standalone/releases/download/$PBS_TAG/$ASSET" -o "$TARBALL"
fi
ACTUAL="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
[[ "$ACTUAL" == "$EXPECTED" ]] || { echo "❌ sha256 校验失败：期望 ${EXPECTED}，实际 $ACTUAL"; exit 1; }
echo "✅ sha256 校验通过: $ACTUAL"

if [[ -z "$APP" ]]; then
  APP="$(ls -d "$ROOT"/build/macos/Build/Products/"$CONFIG"/*.app 2>/dev/null | head -1 || true)"
  if [[ -z "$APP" ]]; then echo "❌ 未找到 $CONFIG 产物 .app（先 flutter build macos --${CONFIG}，或用 --app 指定）"; exit 1; fi
fi
[[ -d "$APP" ]] || { echo "❌ .app 不存在：$APP"; exit 1; }

EXTRACT="$CACHE/extract-$PBS_TARGET"; rm -rf "$EXTRACT" && mkdir -p "$EXTRACT"
tar -xzf "$TARBALL" -C "$EXTRACT"
PYTHON_SRC="$EXTRACT/python"
[[ -f "$PYTHON_SRC/bin/python3" ]] || { echo "❌ tar 包内未找到 python/bin/python3"; exit 1; }

RUNTIME_DIR="$APP/Contents/Resources/pyruntime"
rm -rf "$RUNTIME_DIR"
mkdir -p "$APP/Contents/Resources"
cp -R "$PYTHON_SRC" "$RUNTIME_DIR"
PYTHON_BIN="$RUNTIME_DIR/bin/python3"

echo "📦 pip 安装 lxml==$LXML_VERSION"
"$PYTHON_BIN" -m pip install --no-cache-dir --no-warn-script-location --disable-pip-version-check --only-binary=:all: "lxml==$LXML_VERSION"

STDLIB_SRC="$ROOT/assets/python-stdlib"
[[ -d "$STDLIB_SRC" ]] || { echo "❌ 未找到 ${STDLIB_SRC}（先落盘 assets/python-stdlib）"; exit 1; }
STDLIB_DST="$RUNTIME_DIR/python-stdlib"
cp -R "$STDLIB_SRC" "$STDLIB_DST"

# 裁剪：tkinter 系（tkinter/idlelib/turtledemo/tcl）+ ensurepip + 缓存
PYLIB="$RUNTIME_DIR/lib/python$PYTHON_VERSION"
for d in tkinter idlelib turtledemo ensurepip; do
  rm -rf "$PYLIB/$d" 2>/dev/null || true
done
rm -rf "$RUNTIME_DIR/lib/tcl"* "$RUNTIME_DIR/lib/tk"* 2>/dev/null || true
rm -f "$PYLIB/lib-dynload/_tkinter"*.so 2>/dev/null || true
rm -f "$RUNTIME_DIR/bin/idle3"* 2>/dev/null || true
find "$RUNTIME_DIR" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
find "$RUNTIME_DIR" -name '*.pyc' -delete 2>/dev/null || true

# ad-hoc 递归签名：嵌套 Mach-O（python3 / *.dylib / *.so）不签会被 Gatekeeper 拒绝
find "$RUNTIME_DIR" -type f \( -perm -u+x -o -name '*.dylib' -o -name '*.so' \) -print0 2>/dev/null \
  | while IFS= read -r -d '' f; do codesign --force --sign - "$f" >/dev/null 2>&1 || true; done

SMOKE="$("$PYTHON_BIN" -c "import sys, lxml.etree; print('PYOK', sys.version_info[:3])")"
[[ "$SMOKE" == PYOK* ]] || { echo "❌ python 冒烟失败：$SMOKE"; exit 1; }
echo "✅ python 冒烟通过（${SMOKE}）"
SMOKE2="$(PYTHONPATH="$STDLIB_DST" "$PYTHON_BIN" -c "import base.spider; print('BASEOK')")"
[[ "$SMOKE2" == "BASEOK" ]] || { echo "❌ base.spider 冒烟失败：$SMOKE2"; exit 1; }
echo "✅ base.spider 冒烟通过（PYTHONPATH=pyruntime/python-stdlib）"

SIZE="$(du -sm "$RUNTIME_DIR" | awk '{print $1}')"
echo "✅ 内置 CPython 已随 App 分发：Contents/Resources/pyruntime/（${SIZE} MB）"
