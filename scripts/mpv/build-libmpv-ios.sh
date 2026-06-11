#!/usr/bin/env bash
set -euo pipefail

OUTPUT_DIR="${1:-mpv-build-output}"

cat <<'MSG'
⚠️ libmpv 源码编译入口已预留，但当前还没有启用完整源码编译链。

原因：
- libmpv iOS 构建需要先编译 FFmpeg、libass、freetype、fribidi、harfbuzz 等依赖。
- 需要确定依赖版本、许可证、iOS SDK、最小系统版本、真机/模拟器 slice。
- 直接写死未验证的源码编译脚本容易让 Actions 长时间失败。

当前可用能力：
- 使用 build-mpv-framework.yml 的 package-prebuilt 模式，从 URL 下载已有 MPVKit/libmpv xcframework。
- 验证 xcframework 是否包含 ios-arm64。
- 重新打包并上传 artifact。

后续迭代目标：
1. 新增 scripts/mpv/build-deps-ios.sh
2. 编译 FFmpeg iOS arm64
3. 编译 libass/freetype/fribidi/harfbuzz
4. 编译 mpv/libmpv
5. 生成 libmpv.framework
6. 使用 xcodebuild -create-xcframework 打包 libmpv.xcframework
MSG

mkdir -p "$OUTPUT_DIR"
exit 64
