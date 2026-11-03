#!/usr/bin/env bash
set -euo pipefail

# ND-02-desktop：把 Node 引擎（node 二进制）随 macOS App Bundle 分发。
#
# 对齐 iOS「引擎随包内置、零外部依赖」语义：桌面端 ProcessNodeHost 探测链
# ② `<exeDir>/noderuntime/node` 是为随包内置预留的落点（见
# lib/platform/node/node_host.dart），本脚本把 nodejs.org 官方引擎拷入
# `<App>/Contents/MacOS/noderuntime/node` → 用户免装 Node.js。
#
# 流程（与 bundle-jsc-macos.sh 同模式）：
#   1. 下载固定版本官方 darwin 引擎 tar.gz（.node-cache 缓存 + sha256 校验）；
#   2. 解出 bin/node → <App>/Contents/MacOS/noderuntime/node；
#   3. ad-hoc 签名（嵌套二进制须签，统一 re-sign 会覆盖 App 本体）；
#   4. 冒烟：`node -p "21*2"` 期望输出 42。
#
# 用法：scripts/bundle-node-macos.sh [--config Debug|Release] [--app <path.app>]
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

NODE_VERSION="v22.14.0"
SHA_ARM64="e9404633bc02a5162c5c573b1e2490f5fb44648345d64a958b17e325729a5e42"
SHA_X64="6698587713ab565a94a360e091df9f6d91c8fadda6d00f0cf6526e9b40bed250"

CONFIG="Release"
APP=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG="$2"; shift 2 ;;
    --app)    APP="$2"; shift 2 ;;
    *) echo "用法: $0 [--config Debug|Release] [--app <path.app>]"; exit 1 ;;
  esac
done

# ── 按宿主架构选引擎（macos-15 CI = arm64）──
ARCH="$(uname -m)"
case "$ARCH" in
  arm64) DIST="darwin-arm64"; EXPECTED="$SHA_ARM64" ;;
  x86_64) DIST="darwin-x64"; EXPECTED="$SHA_X64" ;;
  *) echo "❌ 不支持的架构：$ARCH"; exit 1 ;;
esac

CACHE="$ROOT/.node-cache"
mkdir -p "$CACHE"
TARBALL="$CACHE/node-$NODE_VERSION-$DIST.tar.gz"
if [[ ! -f "$TARBALL" ]]; then
  echo "⬇️  下载 https://nodejs.org/dist/$NODE_VERSION/node-$NODE_VERSION-$DIST.tar.gz（ND-02-desktop 引擎内置）"
  curl -fsSL "https://nodejs.org/dist/$NODE_VERSION/node-$NODE_VERSION-$DIST.tar.gz" -o "$TARBALL"
fi
ACTUAL="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
[[ "$ACTUAL" == "$EXPECTED" ]] || { echo "❌ sha256 校验失败：期望 ${EXPECTED}，实际 $ACTUAL"; exit 1; }
echo "✅ sha256 校验通过: $ACTUAL"

# ── 解出 node 二进制 ──
EXTRACT="$CACHE/extract-$DIST"
rm -rf "$EXTRACT" && mkdir -p "$EXTRACT"
tar -xzf "$TARBALL" -C "$EXTRACT"
NODE_BIN="$EXTRACT/node-$NODE_VERSION-$DIST/bin/node"
[[ -f "$NODE_BIN" ]] || { echo "❌ tar 包内未找到 bin/node"; exit 1; }

# ── .app 定位 ──
if [[ -z "$APP" ]]; then
  APP="$(ls -d "$ROOT"/build/macos/Build/Products/"$CONFIG"/*.app 2>/dev/null | head -1 || true)"
  if [[ -z "$APP" ]]; then
    echo "❌ 未找到 $CONFIG 产物 .app（先 flutter build macos --${CONFIG}，或用 --app 指定）"
    exit 1
  fi
fi
[[ -d "$APP" ]] || { echo "❌ .app 不存在：$APP"; exit 1; }

# ── 拷入 noderuntime/node（探测链 ② 落点）+ ad-hoc 签名 ──
RUNTIME_DIR="$APP/Contents/MacOS/noderuntime"
mkdir -p "$RUNTIME_DIR"
cp "$NODE_BIN" "$RUNTIME_DIR/node"
chmod +x "$RUNTIME_DIR/node"
codesign --force --sign - "$RUNTIME_DIR/node" 2>/dev/null || true
SIZE="$(du -m "$RUNTIME_DIR/node" | awk '{print $1}')"
echo "✅ Node 引擎已随 App 分发：Contents/MacOS/noderuntime/node（${SIZE} MB）"

# ── 冒烟 ──
SMOKE="$("$RUNTIME_DIR/node" -p "21*2")"
[[ "$SMOKE" == "42" ]] || { echo "❌ node 冒烟失败：21*2 → '$SMOKE'（期望 42）"; exit 1; }
echo "✅ node 冒烟通过（21*2 → 42）"
