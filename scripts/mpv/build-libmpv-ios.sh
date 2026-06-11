#!/usr/bin/env bash
set -euo pipefail

OUTPUT_DIR="${1:-mpv-build-output}"
MPV_VERSION="${MPV_VERSION:-v0.39.0}"
FFMPEG_VERSION="${FFMPEG_VERSION:-n6.1.1}"
IOS_MIN_VERSION="${IOS_MIN_VERSION:-16.0}"
BUILD_ROOT="${BUILD_ROOT:-mpv-source-build}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUTPUT_DIR="$REPO_ROOT/$OUTPUT_DIR"
BUILD_ROOT="$REPO_ROOT/$BUILD_ROOT"

log() {
  echo ""
  echo "==> $*"
}

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "❌ 缺少工具: $1"
    exit 1
  fi
}

sdk_path() {
  xcrun --sdk "$1" --show-sdk-path
}

sdk_clang() {
  xcrun --sdk "$1" --find clang
}

sdk_ar() {
  xcrun --sdk "$1" --find ar
}

sdk_strip() {
  xcrun --sdk "$1" --find strip
}

download_sources() {
  mkdir -p "$BUILD_ROOT/src"

  if [[ ! -d "$BUILD_ROOT/src/ffmpeg" ]]; then
    log "下载 FFmpeg $FFMPEG_VERSION"
    curl -L --fail --retry 3 \
      "https://github.com/FFmpeg/FFmpeg/archive/refs/tags/${FFMPEG_VERSION}.tar.gz" \
      -o "$BUILD_ROOT/src/ffmpeg.tar.gz"
    mkdir -p "$BUILD_ROOT/src/ffmpeg"
    tar -xzf "$BUILD_ROOT/src/ffmpeg.tar.gz" -C "$BUILD_ROOT/src/ffmpeg" --strip-components=1
  fi

  if [[ ! -d "$BUILD_ROOT/src/mpv" ]]; then
    log "下载 mpv $MPV_VERSION"
    curl -L --fail --retry 3 \
      "https://github.com/mpv-player/mpv/archive/refs/tags/${MPV_VERSION}.tar.gz" \
      -o "$BUILD_ROOT/src/mpv.tar.gz"
    mkdir -p "$BUILD_ROOT/src/mpv"
    tar -xzf "$BUILD_ROOT/src/mpv.tar.gz" -C "$BUILD_ROOT/src/mpv" --strip-components=1
  fi
}

build_ffmpeg() {
  local platform="$1"
  local sdk="$2"
  local arch="$3"
  local install_dir="$4"
  local sdkroot
  local clang

  sdkroot="$(sdk_path "$sdk")"
  clang="$(sdk_clang "$sdk")"

  log "编译 FFmpeg: $platform / $arch"
  rm -rf "$BUILD_ROOT/build/ffmpeg-$platform" "$install_dir"
  mkdir -p "$BUILD_ROOT/build/ffmpeg-$platform" "$install_dir"

  pushd "$BUILD_ROOT/build/ffmpeg-$platform" >/dev/null

  local cflags="-arch $arch -isysroot $sdkroot -mios-version-min=$IOS_MIN_VERSION -fembed-bitcode-marker"
  local ldflags="-arch $arch -isysroot $sdkroot -mios-version-min=$IOS_MIN_VERSION"
  if [[ "$sdk" == "iphonesimulator" ]]; then
    cflags="-arch $arch -isysroot $sdkroot -mios-simulator-version-min=$IOS_MIN_VERSION"
    ldflags="-arch $arch -isysroot $sdkroot -mios-simulator-version-min=$IOS_MIN_VERSION"
  fi

  "$BUILD_ROOT/src/ffmpeg/configure" \
    --prefix="$install_dir" \
    --target-os=darwin \
    --arch="$arch" \
    --cc="$clang" \
    --enable-cross-compile \
    --sysroot="$sdkroot" \
    --extra-cflags="$cflags" \
    --extra-ldflags="$ldflags" \
    --disable-programs \
    --disable-doc \
    --disable-debug \
    --disable-shared \
    --enable-static \
    --enable-pic \
    --enable-network \
    --disable-autodetect \
    --disable-securetransport \
    --disable-videotoolbox \
    --disable-audiotoolbox

  make -j"$JOBS"
  make install
  popd >/dev/null
}

write_meson_cross_file() {
  local platform="$1"
  local sdk="$2"
  local arch="$3"
  local ffmpeg_install="$4"
  local cross_file="$5"
  local sdkroot
  local clang
  local ar
  local strip
  local min_flag

  sdkroot="$(sdk_path "$sdk")"
  clang="$(sdk_clang "$sdk")"
  ar="$(sdk_ar "$sdk")"
  strip="$(sdk_strip "$sdk")"
  min_flag="-mios-version-min=$IOS_MIN_VERSION"
  if [[ "$sdk" == "iphonesimulator" ]]; then
    min_flag="-mios-simulator-version-min=$IOS_MIN_VERSION"
  fi

  cat > "$cross_file" <<EOF
[binaries]
c = '$clang'
cpp = '$clang'
ar = '$ar'
strip = '$strip'
pkg-config = 'pkg-config'

[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = '$arch'
endian = 'little'

[built-in options]
c_args = ['-arch', '$arch', '-isysroot', '$sdkroot', '$min_flag', '-I$ffmpeg_install/include']
cpp_args = ['-arch', '$arch', '-isysroot', '$sdkroot', '$min_flag', '-I$ffmpeg_install/include']
c_link_args = ['-arch', '$arch', '-isysroot', '$sdkroot', '$min_flag', '-L$ffmpeg_install/lib']
cpp_link_args = ['-arch', '$arch', '-isysroot', '$sdkroot', '$min_flag', '-L$ffmpeg_install/lib']

[properties]
pkg_config_libdir = '$ffmpeg_install/lib/pkgconfig'
pkg_config_path = '$ffmpeg_install/lib/pkgconfig'
EOF
}

build_mpv() {
  local platform="$1"
  local sdk="$2"
  local arch="$3"
  local ffmpeg_install="$4"
  local mpv_install="$5"
  local cross_file="$BUILD_ROOT/build/mpv-$platform-cross.ini"

  log "编译 libmpv: $platform / $arch"
  rm -rf "$BUILD_ROOT/build/mpv-$platform" "$mpv_install"
  mkdir -p "$BUILD_ROOT/build"
  write_meson_cross_file "$platform" "$sdk" "$arch" "$ffmpeg_install" "$cross_file"

  export PKG_CONFIG_PATH="$ffmpeg_install/lib/pkgconfig"
  export PKG_CONFIG_LIBDIR="$ffmpeg_install/lib/pkgconfig"

  local meson_options=(
    "--cross-file=$cross_file"
    "--prefix=$mpv_install"
    "--default-library=shared"
    "-Dlibmpv=true"
    "-Dcplayer=false"
    "-Dtests=false"
    "-Dlua=disabled"
    "-Djavascript=disabled"
    "-Dlibarchive=disabled"
    "-Duchardet=disabled"
    "-Djpeg=disabled"
    "-Dlcms2=disabled"
    "-Drubberband=disabled"
    "-Dzimg=disabled"
    "-Dswift-build=disabled"
  )

  if [[ -n "${MPV_EXTRA_MESON_OPTIONS:-}" ]]; then
    # shellcheck disable=SC2206
    local extra_options=( $MPV_EXTRA_MESON_OPTIONS )
    meson_options+=("${extra_options[@]}")
  fi

  if ! meson setup "$BUILD_ROOT/build/mpv-$platform" "$BUILD_ROOT/src/mpv" "${meson_options[@]}"; then
    echo "❌ meson setup 失败。可通过 MPV_EXTRA_MESON_OPTIONS 调整选项。"
    echo "可用选项参考：meson configure $BUILD_ROOT/build/mpv-$platform"
    exit 1
  fi

  meson compile -C "$BUILD_ROOT/build/mpv-$platform" -j "$JOBS"
  meson install -C "$BUILD_ROOT/build/mpv-$platform"
}

find_mpv_dylib() {
  local install_dir="$1"
  find "$install_dir" -name "libmpv*.dylib" -type f | head -1
}

create_framework() {
  local platform="$1"
  local install_dir="$2"
  local framework_dir="$3"
  local dylib

  dylib="$(find_mpv_dylib "$install_dir")"
  if [[ -z "$dylib" ]]; then
    echo "❌ 未找到 libmpv dylib: $install_dir"
    find "$install_dir" -maxdepth 4 -type f | sed -n '1,120p'
    exit 1
  fi

  log "创建 framework: $platform"
  rm -rf "$framework_dir"
  mkdir -p "$framework_dir/Headers" "$framework_dir/Modules"
  cp "$dylib" "$framework_dir/libmpv"

  if [[ -d "$install_dir/include/mpv" ]]; then
    cp -R "$install_dir/include/mpv/"* "$framework_dir/Headers/"
  elif [[ -d "$BUILD_ROOT/src/mpv/libmpv" ]]; then
    cp "$BUILD_ROOT/src/mpv/libmpv/client.h" "$framework_dir/Headers/"
    cp "$BUILD_ROOT/src/mpv/libmpv/render.h" "$framework_dir/Headers/" 2>/dev/null || true
    cp "$BUILD_ROOT/src/mpv/libmpv/render_gl.h" "$framework_dir/Headers/" 2>/dev/null || true
  fi

  cat > "$framework_dir/Modules/module.modulemap" <<'EOF'
framework module libmpv {
  umbrella header "client.h"
  export *
  module * { export * }
}
EOF

  cat > "$framework_dir/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>libmpv</string>
  <key>CFBundleIdentifier</key>
  <string>org.mpv.libmpv.${platform}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>libmpv</string>
  <key>CFBundlePackageType</key>
  <string>FMWK</string>
  <key>CFBundleShortVersionString</key>
  <string>${MPV_VERSION#v}</string>
  <key>CFBundleVersion</key>
  <string>${MPV_VERSION#v}</string>
</dict>
</plist>
EOF

  install_name_tool -id "@rpath/libmpv.framework/libmpv" "$framework_dir/libmpv" || true
  codesign --force --sign - "$framework_dir/libmpv" >/dev/null 2>&1 || true
}

build_slice() {
  local platform="$1"
  local sdk="$2"
  local arch="arm64"
  local ffmpeg_install="$BUILD_ROOT/install/ffmpeg-$platform"
  local mpv_install="$BUILD_ROOT/install/mpv-$platform"
  local framework_dir="$BUILD_ROOT/frameworks/$platform/libmpv.framework"

  build_ffmpeg "$platform" "$sdk" "$arch" "$ffmpeg_install"
  build_mpv "$platform" "$sdk" "$arch" "$ffmpeg_install" "$mpv_install"
  create_framework "$platform" "$mpv_install" "$framework_dir"
}

main() {
  require_tool xcrun
  require_tool xcodebuild
  require_tool curl
  require_tool meson
  require_tool ninja
  require_tool pkg-config
  require_tool make

  rm -rf "$OUTPUT_DIR"
  mkdir -p "$OUTPUT_DIR" "$BUILD_ROOT"

  download_sources
  build_slice "ios-arm64" "iphoneos"
  build_slice "ios-arm64-simulator" "iphonesimulator"

  log "创建 libmpv.xcframework"
  rm -rf "$OUTPUT_DIR/libmpv.xcframework"
  xcodebuild -create-xcframework \
    -framework "$BUILD_ROOT/frameworks/ios-arm64/libmpv.framework" \
    -framework "$BUILD_ROOT/frameworks/ios-arm64-simulator/libmpv.framework" \
    -output "$OUTPUT_DIR/libmpv.xcframework"

  "$SCRIPT_DIR/package-xcframework.sh" "$OUTPUT_DIR/libmpv.xcframework" "$OUTPUT_DIR" "libmpv"
  log "libmpv.xcframework 构建完成"
}

main "$@"
