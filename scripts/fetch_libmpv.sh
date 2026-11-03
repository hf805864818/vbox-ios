#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

# SHA256 跨平台取值：Linux/Windows(git-bash) 有 sha256sum，macOS 只有 shasum，
# 兜底 openssl（Windows git-bash 无 shasum，直接用会 exit 127）。
sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        openssl dgst -sha256 "$1" | awk '{print $NF}'
    fi
}

# G-02-C（D28）：libmpv 原生二进制分发 —— 不入 git 仓库，
# 由本脚本从 GitHub Release 资产下载（Windows：libmpv-{os}-{arch}-{ver}.dll 单一自包含；
# macOS：libmpv-{os}-{arch}-{ver}.tar.gz 动态库集合），随侧载产物（DMG / EXE）分发。
# 沿用 iOS mpvkit-deps 模式（fetch_mpv_dependencies.sh）：
# 私有仓库 release 资产走 GitHub API 资产端点（releases/assets/{id} + octet-stream）。
#
# macOS 为何是「集合」：libmpv.dylib 的 LC_LOAD_DYLIB 为 @rpath/libass.dylib、
# @rpath/libavcodec.dylib 等同组依赖，公开源自包含 FFmpeg 的自包含单文件不可得，
# 故整组 dylib 随 App 的 Contents/Frameworks 分发（与 media_kit / Flutter 生态同款）。

# ─────────────── 参数 / 环境变量（带默认） ───────────────
LIBMPV_DEPS_REPO="${LIBMPV_DEPS_REPO:-q2787244398/vbox-deps}"
LIBMPV_DEPS_TAG="${LIBMPV_DEPS_TAG:-libmpv-deps-0.0.1}"
LIBMPV_DEPS_VERSION="${LIBMPV_DEPS_VERSION:-0.0.1}"
LIBMPV_DEPS_OS="${LIBMPV_DEPS_OS:-$(uname -s | tr '[:upper:]' '[:lower:]')}"
LIBMPV_DEPS_ARCH="${LIBMPV_DEPS_ARCH:-$(uname -m)}"
LIBMPV_DEPS_CACHE_DIR="${LIBMPV_DEPS_CACHE_DIR:-.mpv-cache}"
LIBMPV_DEPS_TOKEN="${LIBMPV_DEPS_TOKEN:-${GITHUB_TOKEN:-}}"

# 直链覆盖（镜像 / 自定义地址）：设置 LIBMPV_DEPS_URL 时改走普通 curl。
LIBMPV_DEPS_URL="${LIBMPV_DEPS_URL:-}"
LIBMPV_DEPS_SHA256_URL="${LIBMPV_DEPS_SHA256_URL:-}"

usage() {
    cat <<'USAGE'
用法: scripts/fetch_libmpv.sh [选项]

选项:
  --os <os>            目标系统（macos / windows / linux；默认本机 uname -s）
  --arch <arch>        目标架构（arm64 / x86_64；默认本机 uname -m）
  --tag <tag>          GitHub Release tag（默认 libmpv-deps-0.0.1，也可用 LIBMPV_DEPS_TAG）
  --version <ver>      资产版本段（默认 0.0.1，也可用 LIBMPV_DEPS_VERSION）
  --repo <repo>        GitHub 仓库（默认 q2787244398/vbox-deps，也可用 LIBMPV_DEPS_REPO）
  --url <url>          显式直链 URL，覆盖 API 方式（也可用 LIBMPV_DEPS_URL）
  --sha256-url <url>   sha256 文件直链地址（默认 <url>.sha256）
  --token <token>      访问私有仓库 release 的认证 token（也可用 LIBMPV_DEPS_TOKEN / GITHUB_TOKEN）
  --cache-dir <dir>    输出/缓存目录（默认 .mpv-cache，也可用 LIBMPV_DEPS_CACHE_DIR）
  -h, --help           打印帮助

资产命名（D28）：
  macos   → libmpv-macos-{arch}-{ver}.tar.gz（动态库集合：libmpv.dylib + 依赖 dylib）
  windows → libmpv-windows-{arch}-{ver}.dll（单一自包含）
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --os) LIBMPV_DEPS_OS="$2"; shift 2 ;;
        --arch) LIBMPV_DEPS_ARCH="$2"; shift 2 ;;
        --tag) LIBMPV_DEPS_TAG="$2"; shift 2 ;;
        --version) LIBMPV_DEPS_VERSION="$2"; shift 2 ;;
        --repo) LIBMPV_DEPS_REPO="$2"; shift 2 ;;
        --url) LIBMPV_DEPS_URL="$2"; shift 2 ;;
        --sha256-url) LIBMPV_DEPS_SHA256_URL="$2"; shift 2 ;;
        --token) LIBMPV_DEPS_TOKEN="$2"; shift 2 ;;
        --cache-dir) LIBMPV_DEPS_CACHE_DIR="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "未知参数: $1" >&2; usage >&2; exit 1 ;;
    esac
done

# 架构归一（macOS 本机 arm64 / x86_64）
case "$LIBMPV_DEPS_ARCH" in
    amd64|x64) LIBMPV_DEPS_ARCH="x86_64" ;;
    aarch64|arm64) LIBMPV_DEPS_ARCH="arm64" ;;
esac

# 系统归一（uname -s 的 darwin → macos）
case "$LIBMPV_DEPS_OS" in
    darwin) LIBMPV_DEPS_OS="macos" ;;
esac

# 资产名（D28）：Windows 单一自包含 dll；macOS 为动态库集合 tar。
case "$LIBMPV_DEPS_OS" in
    macos)
        ASSET_NAME="libmpv-${LIBMPV_DEPS_OS}-${LIBMPV_DEPS_ARCH}-${LIBMPV_DEPS_VERSION}.tar.gz"
        IS_TARBALL=1
        ;;
    windows)
        ASSET_NAME="libmpv-${LIBMPV_DEPS_OS}-${LIBMPV_DEPS_ARCH}-${LIBMPV_DEPS_VERSION}.dll"
        IS_TARBALL=0
        ;;
    *) echo "不支持的 os: ${LIBMPV_DEPS_OS}（仅 macos / windows）" >&2; exit 1 ;;
esac

DEST_DIR="${LIBMPV_DEPS_CACHE_DIR}"
mkdir -p "${DEST_DIR}"
DEST="${DEST_DIR}/${ASSET_NAME}"

# 若已下载且校验通过 → 直接复用（macOS 集合还需确认已解包到缓存目录）
if [ -f "${DEST}" ] && [ -f "${DEST}.sha256" ] && \
   [ "$(cat "${DEST}.sha256")" = "$(sha256_of "${DEST}")" ] && \
   { [ "${IS_TARBALL}" = "0" ] || [ -f "${DEST_DIR}/libmpv.dylib" ]; }; then
    echo "✅ 已缓存并校验通过: ${DEST}"
    exit 0
fi

# macOS 集合资产：下载校验后解包出 *.dylib 到缓存目录（供工作流整组拷入 App Frameworks）
extract_if_needed() {
    if [ "${IS_TARBALL}" = "1" ]; then
        echo "📦 解包动态库集合 → ${DEST_DIR}/"
        TMP_EXTRACT="${DEST_DIR}/.extract-$$"
        rm -rf "${TMP_EXTRACT}"
        mkdir -p "${TMP_EXTRACT}"
        tar -xzf "${DEST}" -C "${TMP_EXTRACT}"
        find "${TMP_EXTRACT}" -name '*.dylib' -exec cp -f {} "${DEST_DIR}/" \;
        rm -rf "${TMP_EXTRACT}"
        ls -1 "${DEST_DIR}"/*.dylib
    fi
}

# 无 token / 无显式直链时：vbox-deps 为公开仓库，改走 Release 直链
# （`releases/download/{tag}/{asset}`，免 API 鉴权与 60 次/时匿名速率限制）。
if [ -z "${LIBMPV_DEPS_TOKEN}" ] && [ -z "${LIBMPV_DEPS_URL}" ]; then
    LIBMPV_DEPS_URL="https://github.com/${LIBMPV_DEPS_REPO}/releases/download/${LIBMPV_DEPS_TAG}/${ASSET_NAME}"
    echo "ℹ️ 未提供 token → 按公开仓库直链下载（如需私有仓库请配 LIBMPV_DEPS_TOKEN）"
fi

# 直链模式
if [ -n "${LIBMPV_DEPS_URL}" ]; then
    SHA_URL="${LIBMPV_DEPS_SHA256_URL:-${LIBMPV_DEPS_URL}.sha256}"
    echo "⬇️  直链下载 ${LIBMPV_DEPS_URL}"
    curl -fL --retry 3 -o "${DEST}" "${LIBMPV_DEPS_URL}"
    curl -fsL --retry 3 -o "${DEST}.sha256" "${SHA_URL}" || echo "(sha256 直链不可得，跳过)"
    EXPECTED="$(cat "${DEST}.sha256" 2>/dev/null || true)"
    ACTUAL="$(sha256_of "${DEST}")"
    if [ -n "$EXPECTED" ] && [ "$EXPECTED" != "$ACTUAL" ]; then
        echo "❌ sha256 校验失败" >&2; exit 1
    fi
    extract_if_needed
    echo "✅ 下载完成（sha256 ${ACTUAL}）: ${DEST}"
    exit 0
fi

# GitHub API 资产端点模式（私有仓库需认证）
echo "⬇️  GitHub Release 下载 ${ASSET_NAME} @ ${LIBMPV_DEPS_REPO}:${LIBMPV_DEPS_TAG}"
AUTH_HEADER=()
if [ -n "${LIBMPV_DEPS_TOKEN}" ]; then
    AUTH_HEADER=(-H "Authorization: Bearer ${LIBMPV_DEPS_TOKEN}")
fi

# 取资产 id（按 name 精确匹配）
ASSET_JSON="$(curl -fsL "${AUTH_HEADER[@]}" \
    "https://api.github.com/repos/${LIBMPV_DEPS_REPO}/releases/tags/${LIBMPV_DEPS_TAG}")"
ASSET_ID="$(printf '%s' "$ASSET_JSON" | python3 -c "import json,sys;d=json.load(sys.stdin);print(next((a['id'] for a in d.get('assets',[]) if a['name']=='$ASSET_NAME'),''))")"
if [ -z "${ASSET_ID}" ]; then
    echo "❌ 资产不存在: ${ASSET_NAME}（tag=${LIBMPV_DEPS_TAG}，repo=${LIBMPV_DEPS_REPO}）" >&2
    exit 1
fi

curl -fL "${AUTH_HEADER[@]}" \
    -H "Accept: application/octet-stream" \
    -o "${DEST}" \
    "https://api.github.com/repos/${LIBMPV_DEPS_REPO}/releases/assets/${ASSET_ID}"

# 校验和：优先 .sha256 资产，其次清单登记
SHA_ASSET_NAME="${ASSET_NAME}.sha256"
SHA_ASSET_ID="$(printf '%s' "$ASSET_JSON" | python3 -c "import json,sys;d=json.load(sys.stdin);print(next((a['id'] for a in d.get('assets',[]) if a['name']=='$SHA_ASSET_NAME'),''))")"
EXPECTED=""
if [ -n "${SHA_ASSET_ID}" ]; then
    curl -fsL "${AUTH_HEADER[@]}" \
        -H "Accept: application/octet-stream" \
        -o "${DEST}.sha256" \
        "https://api.github.com/repos/${LIBMPV_DEPS_REPO}/releases/assets/${SHA_ASSET_ID}"
    EXPECTED="$(cat "${DEST}.sha256")"
fi
ACTUAL="$(sha256_of "${DEST}")"
if [ -n "$EXPECTED" ] && [ "$EXPECTED" != "$ACTUAL" ]; then
    echo "❌ sha256 校验失败（期望 ${EXPECTED}，实际 ${ACTUAL}）" >&2; exit 1
fi

extract_if_needed
echo "✅ 下载完成（sha256 ${ACTUAL}）: ${DEST}"
