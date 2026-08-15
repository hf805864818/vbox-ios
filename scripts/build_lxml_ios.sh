#!/bin/bash
# ============================================================
# build_lxml_ios.sh — 为 iOS arm64 交叉编译 lxml
# ============================================================
# 依赖: macOS runner + Xcode 16 + Python 3.14 (host)
# 产出: lxml .so (arm64) + libxml2.a + libxslt.a
#
# 安全设计:
#   - 不修改任何现有文件（不碰 site-packages、不碰 build-ipa.yml）
#   - 所有编译产物放在 /tmp/lxml-build/ 下
#   - 仅在脚本末尾输出验证结果，由 CI workflow 上传 artifact
#
# 方案 A 纯版 — 不含方案 B fallback
# ============================================================
set -euo pipefail

# ─── 配置 ───
WORK="/tmp/lxml-build"
OUTPUT_DIR="$WORK/output"           # 最终产物目录
LXML_VERSION="5.4.0"                # lxml 版本
LIBXML2_VERSION="2.13.5"            # libxml2 版本 (避免已知 CVE)
LIBXSLT_VERSION="1.1.42"            # libxslt 版本

# iOS 交叉编译工具链（与 build-quickjs.yml 相同的配置）
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
CC="$(xcrun --sdk iphoneos -f clang) -arch arm64 -isysroot $SDK -miphoneos-version-min=15.0"
CFLAGS_IOS="-arch arm64 -isysroot $SDK -miphoneos-version-min=15.0 -O2 -fPIC"
LDFLAGS_IOS="-arch arm64 -isysroot $SDK -miphoneos-version-min=15.0"

echo "============================================"
echo "🐍 lxml iOS arm64 交叉编译 (方案 A)"
echo "============================================"
echo "   SDK:        $SDK"
echo "   lxml:       $LXML_VERSION"
echo "   libxml2:    $LIBXML2_VERSION"
echo "   libxslt:    $LIBXSLT_VERSION"
echo "   CC:         $CC"
echo "   CFLAGS:     $CFLAGS_IOS"
echo "   LDFLAGS:    $LDFLAGS_IOS"
echo "   工作目录:    $WORK"
echo "   产物目录:    $OUTPUT_DIR"
echo "============================================"
echo ""

# 清理旧的编译目录（不影响仓库文件）
rm -rf "$WORK"
mkdir -p "$WORK" "$OUTPUT_DIR"
cd "$WORK"

# ============================================================
# Step 1: 交叉编译 libxml2
# ============================================================
echo "📦 [1/5] 下载并编译 libxml2..."

LIBXML2_DIR="libxml2-$LIBXML2_VERSION"
LIBXML2_TARBALL="libxml2-$LIBXML2_VERSION.tar.xz"

# 使用 GNOME 官方 release tarball（包含预生成的 configure 脚本）
# gitlab archive 不包含 configure，需要 autoreconf，太复杂
if [ ! -f "$LIBXML2_TARBALL" ]; then
  curl -sLO "https://download.gnome.org/sources/libxml2/$(echo $LIBXML2_VERSION | cut -d. -f1-2)/$LIBXML2_TARBALL"
fi
tar xf "$LIBXML2_TARBALL"
cd "$LIBXML2_DIR"

# 官方 release tarball 自带 config.sub/config.guess，但可能不识别 aarch64-apple-darwin
# 尝试用系统 automake 的 config.sub 替换
CONFIG_SUB=""
for cs in /usr/share/automake*/config.sub /usr/local/share/automake*/config.sub /opt/homebrew/share/automake*/config.sub; do
  if [ -f "$cs" ]; then
    CONFIG_SUB="$cs"
    break
  fi
done
if [ -n "$CONFIG_SUB" ]; then
  cp "$CONFIG_SUB" config.sub 2>/dev/null || true
  cp "${CONFIG_SUB%config.sub}config.guess" config.guess 2>/dev/null || true
  echo "   使用 config.sub: $CONFIG_SUB"
else
  echo "   ⚠️ 未找到 automake config.sub，使用自带版本"
fi

# 禁用不需要的功能，减小体积和编译复杂度
# 注意: 不能用 --without-schemas，lxml 的 RelaxNG 代码依赖 schema 头文件
./configure \
  --host=aarch64-apple-darwin \
  --prefix="$WORK/opt" \
  --enable-static \
  --disable-shared \
  --without-python \
  --without-lzma \
  --without-http \
  --without-ftp \
  --without-legacy \
  CC="$CC" \
  CFLAGS="$CFLAGS_IOS" \
  LDFLAGS="$LDFLAGS_IOS" \
  || {
    echo "❌ libxml2 configure 失败！"
    echo "--- config.log 末尾 ---"
    tail -50 config.log 2>/dev/null || true
    exit 1
  }

make -j$(sysctl -n hw.ncpu) || {
  echo "❌ libxml2 编译失败！"
  exit 1
}
make install
cd "$WORK"
echo "✅ libxml2 编译完成: $(ls -lh "$WORK/opt/lib/libxml2.a" | awk '{print $5}')"
echo ""

# ============================================================
# Step 2: 交叉编译 libxslt
# ============================================================
echo "📦 [2/5] 下载并编译 libxslt..."

LIBXSLT_DIR="libxslt-$LIBXSLT_VERSION"
LIBXSLT_TARBALL="libxslt-$LIBXSLT_VERSION.tar.xz"

# 使用 GNOME 官方 release tarball（包含预生成的 configure 脚本）
if [ ! -f "$LIBXSLT_TARBALL" ]; then
  curl -sLO "https://download.gnome.org/sources/libxslt/$(echo $LIBXSLT_VERSION | cut -d. -f1-2)/$LIBXSLT_TARBALL"
fi
tar xf "$LIBXSLT_TARBALL"
cd "$LIBXSLT_DIR"

# 使用与 libxml2 相同的 config.sub 搜索逻辑
CONFIG_SUB=""
for cs in /usr/share/automake*/config.sub /usr/local/share/automake*/config.sub /opt/homebrew/share/automake*/config.sub; do
  if [ -f "$cs" ]; then
    CONFIG_SUB="$cs"
    break
  fi
done
if [ -n "$CONFIG_SUB" ]; then
  cp "$CONFIG_SUB" config.sub 2>/dev/null || true
  cp "${CONFIG_SUB%config.sub}config.guess" config.guess 2>/dev/null || true
fi

./configure \
  --host=aarch64-apple-darwin \
  --prefix="$WORK/opt" \
  --enable-static \
  --disable-shared \
  --without-python \
  --without-crypto \
  --with-libxml-prefix="$WORK/opt" \
  CC="$CC" \
  CFLAGS="$CFLAGS_IOS -I$WORK/opt/include/libxml2" \
  LDFLAGS="$LDFLAGS_IOS -L$WORK/opt/lib" \
  || {
    echo "❌ libxslt configure 失败！"
    echo "--- config.log 末尾 ---"
    tail -50 config.log 2>/dev/null || true
    exit 1
  }

make -j$(sysctl -n hw.ncpu) || {
  echo "❌ libxslt 编译失败！"
  exit 1
}
make install
cd "$WORK"
echo "✅ libxslt 编译完成: $(ls -lh "$WORK/opt/lib/libxslt.a" | awk '{print $5}')"
echo ""

# ============================================================
# Step 3: 准备 Python 交叉编译环境
# ============================================================
echo "🐍 [3/5] 准备 Python 编译环境..."

# 查找 host Python 3.14（用于运行 setup.py）
HOST_PY=""
for p in \
  "/Library/Frameworks/Python.framework/Versions/3.14/bin/python3.14" \
  python3.14 \
  python3; do
  if command -v "$p" >/dev/null 2>&1; then
    HOST_PY="$p"
    break
  fi
done
PY="${HOST_PY:-python3}"
echo "   使用 host python: $PY ($($PY --version 2>&1))"

# Python 3.12+ 移除了 distutils，3.14 不再自带 setuptools
# lxml setup.py 需要这两个模块
echo "   安装 setuptools（Python 3.14 不再自带）..."
$PY -m pip install --quiet setuptools wheel 2>&1 | tail -2 || {
  echo "   ⚠️ pip install setuptools 失败，尝试 ensurepip..."
  $PY -m ensurepip --upgrade 2>&1 | tail -2
  $PY -m pip install --quiet setuptools wheel 2>&1 | tail -2
}

# 关键: 不使用 --embed（避免链接到 libpython 导致运行时 segfault）
# iOS 扩展模块通过 Python.framework 的符号在运行时自动解析

# 覆盖 Python distutils 的默认 SDK 路径
# distutils 默认使用 MacOSX.sdk，但我们需要 iPhoneOS.sdk
export SDKROOT="$SDK"
# -undefined dynamic_lookup: Python C API 符号在运行时由 Python.framework 提供
# 不需要链接 libpython（避免 segfault）
export LDSHARED="$CC -dynamiclib -undefined dynamic_lookup"
export LDFLAGS="$LDFLAGS_IOS -isysroot $SDK -L$WORK/opt/lib -undefined dynamic_lookup"
export CFLAGS="$CFLAGS_IOS -I$WORK/opt/include/libxml2 -I$WORK/opt/include"

echo "✅ Python 环境准备完成"
echo ""

# ============================================================
# Step 4: 编译 lxml C 扩展
# ============================================================
echo "📦 [4/5] 下载并编译 lxml C 扩展..."

LXML_SRC="lxml-$LXML_VERSION"
LXML_TARBALL="lxml-$LXML_VERSION.tar.gz"

if [ ! -f "$LXML_TARBALL" ]; then
  # 通过 PyPI JSON API 获取源码包下载 URL（避免 pip download 触发构建依赖）
  echo "   通过 PyPI API 获取 lxml 源码包 URL..."
  PYPI_JSON=$($PY -c "
import urllib.request, json
url = 'https://pypi.org/pypi/lxml/$LXML_VERSION/json'
with urllib.request.urlopen(url) as r:
    data = json.load(r)
for ext in data['urls']:
    if ext['packagetype'] == 'sdist':
        print(ext['url'])
        break
" 2>/dev/null)

  if [ -n "$PYPI_JSON" ]; then
    echo "   下载: $PYPI_JSON"
    curl -sL "$PYPI_JSON" -o "$LXML_TARBALL"
  else
    # 后备: 直接用固定 URL 模式
    echo "   后备: 使用固定 URL..."
    curl -sL "https://files.pythonhosted.org/packages/source/l/lxml/$LXML_TARBALL" -o "$LXML_TARBALL"
  fi
fi

# 确认文件存在且非空
if [ ! -s "$LXML_TARBALL" ]; then
  echo "❌ lxml 源码包下载失败"
  exit 1
fi
echo "   源码包大小: $(ls -lh "$LXML_TARBALL" | awk '{print $5}')"
tar xzf "$LXML_TARBALL"
cd "$LXML_SRC"

# 环境变量已在 Step 3 中设置（CFLAGS/LDFLAGS/LDSHARED/SDKROOT）
# 额外设置 LIBS 供 lxml 链接
export LIBS="-lxml2 -lxslt -lexslt"

# 关键: 覆盖 xml2-config 和 xslt-config 的输出（交叉编译 hack）
# lxml setup.py 会调用 xml2-config 获取路径，但交叉编译时返回的是 host 路径
# 创建 wrapper 脚本来返回正确的 target 路径
mkdir -p "$WORK/bin"
cat > "$WORK/bin/xml2-config" << 'XMLEOF'
#!/bin/bash
case "$1" in
  --cflags) echo "-I/tmp/lxml-build/opt/include/libxml2" ;;
  --libs)   echo "-L/tmp/lxml-build/opt/lib -lxml2" ;;
  --version) echo "2.13.5" ;;
  *) echo "" ;;
esac
XMLEOF
cat > "$WORK/bin/xslt-config" << 'XSLTEOF'
#!/bin/bash
case "$1" in
  --cflags) echo "-I/tmp/lxml-build/opt/include/libxslt" ;;
  --libs)   echo "-L/tmp/lxml-build/opt/lib -lxslt -lexslt" ;;
  --version) echo "1.1.42" ;;
  *) echo "" ;;
esac
XSLTEOF
chmod +x "$WORK/bin/xml2-config" "$WORK/bin/xslt-config"
export PATH="$WORK/bin:$PATH"

# 用 release tarball 的预生成 C 代码编译（不需要 Cython）
# 不使用 --static-deps（那会让 lxml 自己下载编译 libxml2/libxslt/zlib/iconv，交叉编译会失败）
# 改为直接指定预编译的库路径
$PY setup.py build_ext --inplace \
  --xml2-config="$WORK/bin/xml2-config" \
  --xslt-config="$WORK/bin/xslt-config" \
  -I "$WORK/opt/include/libxml2:$WORK/opt/include" \
  -L "$WORK/opt/lib" \
  || {
    echo "❌ lxml 编译失败！"
    echo "--- 可能的原因 ---"
    echo "1. Python 3.14 C API 不兼容（尝试降低 lxml 版本号，如 5.3.0）"
    echo "2. 预生成 C 代码需要重新生成（安装 Cython 后重试）"
    echo "3. iOS SDK 头文件缺失"
    echo "4. libxml2/libxslt 路径问题（检查 xml2-config 输出）"
    echo ""
    echo "--- 调试信息 ---"
    echo "xml2-config --cflags: $($WORK/bin/xml2-config --cflags)"
    echo "xml2-config --libs: $($WORK/bin/xml2-config --libs)"
    echo "libxml2.a exists: $([ -f "$WORK/opt/lib/libxml2.a" ] && echo YES || echo NO)"
    echo "libxslt.a exists: $([ -f "$WORK/opt/lib/libxslt.a" ] && echo YES || echo NO)"
    exit 1
  }

echo "✅ lxml 编译完成"
echo ""

# ============================================================
# Step 4.5: 重命名 .so 文件 (cpython-314-darwin → cpython-314-iphoneos)
# ============================================================
# 交叉编译时 host Python 标记 .so 为 darwin，但 iOS Python 需要 iphoneos 标记
# 不重命名的话 import lxml.etree 会找不到模块
echo "🏷️  [4.5/5] 重命名 .so 平台标记 (darwin → iphoneos)..."
RENAMED=0
find . -name "*.cpython-314-*.so" -type f | while read -r sofile; do
  dir=$(dirname "$sofile")
  base=$(basename "$sofile")
  # 将 cpython-314-darwin 或 cpython-314-x86_64-apple-darwin 等替换为 cpython-314-iphoneos
  newname=$(echo "$base" | sed 's/cpython-314-[a-z0-9_]*\.so/cpython-314-iphoneos.so/')
  if [ "$base" != "$newname" ]; then
    mv "$sofile" "$dir/$newname"
    echo "   $base → $newname"
    RENAMED=$((RENAMED + 1))
  fi
done
echo "   重命名完成"
echo ""

# ============================================================
# Step 5: 验证产物 + 打包
# ============================================================
echo "🔍 [5/5] 验证编译产物..."

# 查找编译出的 .so 文件（重命名后应为 cpython-314-iphoneos.so）
SO_FILE=$(find . -name "etree.*.so" -o -name "etree.cpython-*.so" | head -1)
if [ -z "$SO_FILE" ]; then
  echo "❌ 未找到编译产物 etree.so"
  echo "   查找所有 .so 文件:"
  find . -name "*.so" -type f 2>/dev/null || echo "   (无)"
  exit 1
fi
echo "   找到 .so: $SO_FILE"

# 验证 1: 架构是否为 arm64
echo ""
echo "─── 验证 1: 架构 ───"
FILE_INFO=$(file "$SO_FILE")
echo "   $FILE_INFO"
if echo "$FILE_INFO" | grep -q "arm64"; then
  echo "   ✅ 架构验证通过: arm64"
else
  echo "   ❌ 架构异常！期望 arm64"
  exit 1
fi

# 验证 2: 是否链接了 libpython（致命风险检查）
echo ""
echo "─── 验证 2: libpython 链接检查 ───"
OTOOL_OUTPUT=$(otool -L "$SO_FILE" 2>/dev/null || echo "(otool 不可用)")
echo "   otool -L 输出:"
echo "$OTOOL_OUTPUT" | sed 's/^/     /'
if echo "$OTOOL_OUTPUT" | grep -q "libpython"; then
  echo "   ❌ etree.so 链接了 libpython！"
  echo "   这会导致运行时 segfault（CPython issue #92158）"
  echo "   解决方案: 确保编译时不使用 --embed 标志"
  exit 1
else
  echo "   ✅ 未链接 libpython（安全）"
fi

# 验证 3: 检查所有 .so 文件
echo ""
echo "─── 验证 3: 所有 .so 文件 ───"
ALL_SO=$(find . -name "*.cpython-*.so" -type f 2>/dev/null)
if [ -z "$ALL_SO" ]; then
  echo "   ⚠️ 未找到 cpython .so 文件（可能编译方式不同）"
else
  echo "$ALL_SO" | while read -r f; do
    echo "   $f ($(file "$f" | grep -o 'arm64\|x86_64' | head -1))"
  done
fi

# 验证 4: 静态库是否存在
echo ""
echo "─── 验证 4: 静态库 ───"
for lib in libxml2.a libxslt.a libexslt.a; do
  if [ -f "$WORK/opt/lib/$lib" ]; then
    echo "   ✅ $lib: $(ls -lh "$WORK/opt/lib/$lib" | awk '{print $5}')"
  else
    echo "   ⚠️ $lib: 不存在"
  fi
done

# 打包产物到 output 目录（保留完整目录结构）
echo ""
echo "📦 打包编译产物..."
rm -rf "$OUTPUT_DIR/lxml"
mkdir -p "$OUTPUT_DIR/lxml"

# 复制整个 lxml 包目录（含 .so + .py + 子目录 html/sax 等）
# build_ext --inplace 将 .so 放在 src/lxml/ 下
if [ -d "src/lxml" ]; then
  cp -r src/lxml/* "$OUTPUT_DIR/lxml/"
elif [ -d "lxml" ]; then
  cp -r lxml/* "$OUTPUT_DIR/lxml/"
fi

# 确保有 __init__.py
if [ ! -f "$OUTPUT_DIR/lxml/__init__.py" ]; then
  find . -name "__init__.py" -path "*/lxml/*" -exec cp {} "$OUTPUT_DIR/lxml/__init__.py" \; 2>/dev/null || true
fi

# 清理不需要的构建产物
find "$OUTPUT_DIR/lxml" -name "*.o" -delete 2>/dev/null || true
find "$OUTPUT_DIR/lxml" -name "*.c" -delete 2>/dev/null || true
find "$OUTPUT_DIR/lxml" -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
find "$OUTPUT_DIR/lxml" -name "*.pyc" -delete 2>/dev/null || true

echo "   lxml 包文件列表:"
find "$OUTPUT_DIR/lxml" -type f | sed 's|^|   |'

# 复制静态库（备用）
mkdir -p "$OUTPUT_DIR/lib"
cp "$WORK/opt/lib/libxml2.a" "$OUTPUT_DIR/lib/" 2>/dev/null || true
cp "$WORK/opt/lib/libxslt.a" "$OUTPUT_DIR/lib/" 2>/dev/null || true
cp "$WORK/opt/lib/libexslt.a" "$OUTPUT_DIR/lib/" 2>/dev/null || true

# 复制头文件（备用）
mkdir -p "$OUTPUT_DIR/include"
cp -r "$WORK/opt/include/libxml2" "$OUTPUT_DIR/include/" 2>/dev/null || true
cp -r "$WORK/opt/include/libxslt" "$OUTPUT_DIR/include/" 2>/dev/null || true

# 生成验证报告
cat > "$OUTPUT_DIR/VERIFY_REPORT.txt" << EOF
lxml iOS arm64 交叉编译验证报告
================================
日期: $(date)
编译环境: $(uname -a)
Python: $($PY --version 2>&1)
Xcode: $(xcodebuild -version 2>&1 | head -1)
SDK: $SDK

版本信息:
  lxml: $LXML_VERSION
  libxml2: $LIBXML2_VERSION
  libxslt: $LIBXSLT_VERSION

验证结果:
  1. etree.so 架构: arm64 ✅
  2. libpython 链接: 无 ✅ (安全)
  3. 静态库:
$(ls -lh "$WORK/opt/lib/"*.a 2>/dev/null | awk '{print "     - "$NF": "$5}')

产物文件列表:
$(find "$OUTPUT_DIR" -type f | sed 's|^|  |')

下一步:
  1. 检查 artifact 中的 .so 文件
  2. 如验证通过，将 lxml 编译步骤合并到 build-ipa.yml（阶段 2）
  3. 合并时确保 lxml .so 安装在 find .so -delete 之后
EOF

echo ""
echo "============================================"
echo "🎉 lxml 交叉编译完成！"
echo "============================================"
echo ""
echo "产物目录: $OUTPUT_DIR"
echo "   lxml/:    $(find "$OUTPUT_DIR/lxml" -type f 2>/dev/null | wc -l | tr -d ' ') 个文件"
echo "   lib/:     $(find "$OUTPUT_DIR/lib" -type f 2>/dev/null | wc -l | tr -d ' ') 个静态库"
echo "   include/: $(find "$OUTPUT_DIR/include" -type f 2>/dev/null | wc -l | tr -d ' ') 个头文件"
echo ""
echo "验证报告:"
cat "$OUTPUT_DIR/VERIFY_REPORT.txt"
