#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

DEFAULT_URL="https://github.com/hf805864818/vbox-ios/releases/download/mpvkit-deps-0.0.1/MPVKit-xcframework.zip"

MPVKIT_DEPS_URL="${MPVKIT_DEPS_URL:-$DEFAULT_URL}"
MPVKIT_DEPS_SHA256_URL="${MPVKIT_DEPS_SHA256_URL:-${MPVKIT_DEPS_URL}.sha256}"
MPVKIT_DEPS_CACHE_DIR="${MPVKIT_DEPS_CACHE_DIR:-.mpv-cache}"
MPVKIT_DEPS_SKIP_INSTALL="${MPVKIT_DEPS_SKIP_INSTALL:-0}"

usage() {
    cat <<'USAGE'
用法: scripts/fetch_mpv_dependencies.sh [选项]

选项:
  --cache-dir <dir>     缓存目录（默认 .mpv-cache，也可用 MPVKIT_DEPS_CACHE_DIR）
  --url <url>           下载地址（默认走仓库 Release，也可用 MPVKIT_DEPS_URL）
  --sha256-url <url>    sha256 文件地址（默认 <url>.sha256）
  --skip-install        只下载与校验，不调用 install_mpv_dependencies.sh
  -h, --help            打印帮助

行为:
  1. 下载 MPVKit-xcframework.zip 到缓存目录
  2. 下载 sha256 文件并校验
  3. 如果缓存中的压缩包 sha256 已匹配，跳过重复下载
  4. 默认调用 install_mpv_dependencies.sh 与 check_mpv_installed_dependencies.py

只服务 MPVKit 内核依赖，不处理后续自由度 libmpv.xcframework。
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --cache-dir)
            MPVKIT_DEPS_CACHE_DIR="$2"
            shift 2
            ;;
        --url)
            MPVKIT_DEPS_URL="$2"
            MPVKIT_DEPS_SHA256_URL="${MPVKIT_DEPS_URL}.sha256"
            shift 2
            ;;
        --sha256-url)
            MPVKIT_DEPS_SHA256_URL="$2"
            shift 2
            ;;
        --skip-install)
            MPVKIT_DEPS_SKIP_INSTALL=1
            shift 1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "未知参数: $1"
            usage
            exit 2
            ;;
    esac
done

mkdir -p "$MPVKIT_DEPS_CACHE_DIR"

ARCHIVE_PATH="$MPVKIT_DEPS_CACHE_DIR/MPVKit-xcframework.zip"
SHA256_PATH="$MPVKIT_DEPS_CACHE_DIR/MPVKit-xcframework.zip.sha256"

sha256_of() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        sha256sum "$1" | awk '{print $1}'
    fi
}

echo "MPVKit 依赖下载配置:"
echo "  url:        $MPVKIT_DEPS_URL"
echo "  sha256 url: $MPVKIT_DEPS_SHA256_URL"
echo "  cache:      $MPVKIT_DEPS_CACHE_DIR"

EXPECTED_SHA=""
if curl -L --fail --silent --retry 3 --retry-delay 3 -o "$SHA256_PATH" "$MPVKIT_DEPS_SHA256_URL"; then
    EXPECTED_SHA="$(awk '{print $1}' "$SHA256_PATH" | head -1)"
    echo "已获取期望 sha256: $EXPECTED_SHA"
else
    echo "未下载到 sha256 文件，将不做校验。"
    rm -f "$SHA256_PATH"
fi

NEED_DOWNLOAD=1
if [ -f "$ARCHIVE_PATH" ] && [ -n "$EXPECTED_SHA" ]; then
    CACHED_SHA="$(sha256_of "$ARCHIVE_PATH")"
    if [ "$CACHED_SHA" = "$EXPECTED_SHA" ]; then
        echo "缓存命中，跳过下载: $ARCHIVE_PATH"
        NEED_DOWNLOAD=0
    fi
fi

if [ "$NEED_DOWNLOAD" -eq 1 ]; then
    echo "下载 MPVKit 依赖包..."
    curl -L --fail --retry 3 --retry-delay 3 -o "$ARCHIVE_PATH" "$MPVKIT_DEPS_URL"
fi

if [ -n "$EXPECTED_SHA" ]; then
    ACTUAL_SHA="$(sha256_of "$ARCHIVE_PATH")"
    if [ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]; then
        echo "sha256 校验失败"
        echo "  expected: $EXPECTED_SHA"
        echo "  actual:   $ACTUAL_SHA"
        exit 1
    fi
    echo "sha256 校验通过: $ACTUAL_SHA"
fi

if [ "$MPVKIT_DEPS_SKIP_INSTALL" = "1" ]; then
    echo "已按 --skip-install 终止，未调用 install / check。"
    exit 0
fi

scripts/install_mpv_dependencies.sh "$ARCHIVE_PATH"
python3 scripts/check_mpv_installed_dependencies.py --allow-missing-external
