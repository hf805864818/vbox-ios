#!/bin/bash
# 打包 CPython 编译产物为 tar.gz，用于上传到 GitHub Release 附件
# 产物包含: libpython3.14.a + Python.framework + Headers + 完整标准库
# 用法: bash scripts/pack_python_artifacts.sh [输出目录]
set -euo pipefail

# 从环境变量或参数获取工作区
WORKSPACE="${GITHUB_WORKSPACE:-$(pwd)}"
OUTPUT_DIR="${1:-/tmp}"
PYTHON_VERSION="3.14.7"
PYTHON_TAG="python-${PYTHON_VERSION}-ios-arm64"

echo "📦 打包 CPython 产物..."

# 检查产物是否存在
LIB="vbox/Libraries/python-ios/libpython3.14.a"
FRAMEWORK="vbox/Libraries/python-ios/Python.framework"
HEADERS="vbox/Libraries/python-ios/Headers"
STDLIB="vbox/Resources/python-stdlib"

cd "$WORKSPACE"

for f in "$LIB" "$FRAMEWORK" "$HEADERS" "$STDLIB"; do
  if [ ! -e "$f" ]; then
    echo "❌ 未找到: $f"
    exit 1
  fi
done

echo "✅ 所有产物存在"
echo "  libpython3.14.a: $(du -h "$LIB" | cut -f1)"
echo "  Python.framework: $(du -sh "$FRAMEWORK" | cut -f1)"
echo "  Headers: $(du -sh "$HEADERS" | cut -f1)"
echo "  python-stdlib: $(du -sh "$STDLIB" | cut -f1)"

# 创建临时打包目录
STAGING="/tmp/python-artifacts-staging"
rm -rf "$STAGING"
mkdir -p "$STAGING/vbox/Libraries/python-ios"
mkdir -p "$STAGING/vbox/Resources"

# 复制产物到暂存目录（保持相对路径结构）
cp "$LIB" "$STAGING/vbox/Libraries/python-ios/"
cp -r "$FRAMEWORK" "$STAGING/vbox/Libraries/python-ios/"
cp -r "$HEADERS" "$STAGING/vbox/Libraries/python-ios/"
cp -r "$STDLIB" "$STAGING/vbox/Resources/"

# 写入版本信息
cat > "$STAGING/VERSION.txt" << EOF
Python: ${PYTHON_VERSION}
Target: ios/iphoneos.arm64
Source: beeware/Python-Apple-support
Packed: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF

# 打包
TARBALL="${OUTPUT_DIR}/${PYTHON_TAG}.tar.gz"
cd "$STAGING"
tar czf "$TARBALL" .
cd "$WORKSPACE"

echo "✅ 打包完成: ${TARBALL} ($(du -h "$TARBALL" | cut -f1))"

# 同时生成 SHA256
shasum -a 256 "$TARBALL" | awk '{print $1}' > "${TARBALL}.sha256"
echo "  SHA256: $(cat "${TARBALL}.sha256")"

# 清理暂存
rm -rf "$STAGING"

echo ""
echo "上传到 GitHub Release:"
echo "  gh release create ${PYTHON_TAG} \"\${TARBALL}\" \"\${TARBALL}.sha256\" --title \"CPython ${PYTHON_VERSION} iOS arm64\" --notes \"Pre-built CPython for iOS arm64\""
