#!/usr/bin/env python3
"""检查 MPVKitDependencies 是否已安装 MPVKit 依赖。

脚本只检查项目目录中的依赖文件，不下载、不修改、不 Link/Embed。
核心依赖缺失会失败；外部静态依赖只提示缺失，不让当前 CI 失败。
"""
from __future__ import annotations

import plistlib
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEPENDENCY_DIR = ROOT / "vbox" / "Libraries" / "MPV" / "MPVKitDependencies"
FREEDOM_DIR = ROOT / "vbox" / "Libraries" / "MPV" / "Freedom"

REQUIRED_TARGETS = [
    "Libmpv",
    "Libavcodec",
    "Libavdevice",
    "Libavfilter",
    "Libavformat",
    "Libavutil",
    "Libswresample",
    "Libswscale",
]

OPTIONAL_STATIC_TARGETS = [
    "Libcrypto",
    "Libssl",
    "gmp",
    "nettle",
    "hogweed",
    "gnutls",
    "Libunibreak",
    "Libfreetype",
    "Libfribidi",
    "Libharfbuzz",
    "Libass",
    "Libsmbclient",
    "Libbluray",
    "Libuavs3d",
    "Libdovi",
    "MoltenVK",
    "Libshaderc_combined",
    "lcms2",
    "Libplacebo",
    "Libdav1d",
    "Libuchardet",
]

MINIMUM_STATIC_TARGETS = [
    "gmp",
    "Libass",
    "Libbluray",
    "lcms2",
]

SYSTEM_FRAMEWORKS_FOR_STATIC_LINK = [
    "VideoToolbox.framework",
    "CoreMedia.framework",
    "CoreVideo.framework",
    "AudioToolbox.framework",
    "AVFoundation.framework",
    "Metal.framework",
]


def read_library_identifiers(xcframework: Path) -> list[str]:
    info_plist = xcframework / "Info.plist"
    if not info_plist.exists():
        return []

    with info_plist.open("rb") as file:
        info = plistlib.load(file)

    identifiers: list[str] = []
    for library in info.get("AvailableLibraries", []):
        identifier = library.get("LibraryIdentifier")
        if identifier:
            identifiers.append(identifier)
    return identifiers


def check_target(name: str) -> bool:
    path = DEPENDENCY_DIR / f"{name}.xcframework"
    if not path.exists():
        print(f"缺少: {path.relative_to(ROOT)}")
        return False

    identifiers = read_library_identifiers(path)
    if not identifiers:
        print(f"异常: {path.relative_to(ROOT)} 缺少可读 Info.plist/AvailableLibraries")
        return False

    has_device = any(identifier == "ios-arm64" for identifier in identifiers)
    has_simulator = any("simulator" in identifier for identifier in identifiers)
    status = "通过" if has_device else "缺少真机 ios-arm64"
    simulator_status = "含模拟器" if has_simulator else "无模拟器"
    print(f"{status}: {name}.xcframework ({', '.join(identifiers)}，{simulator_status})")
    return has_device


def existing_xcframework_names() -> set[str]:
    if not DEPENDENCY_DIR.exists():
        return set()

    return {
        path.name.removesuffix(".xcframework")
        for path in DEPENDENCY_DIR.glob("*.xcframework")
        if path.is_dir()
    }


def print_optional_static_dependency_report() -> None:
    installed = existing_xcframework_names()
    missing_minimum = [name for name in MINIMUM_STATIC_TARGETS if name not in installed]
    present_minimum = [name for name in MINIMUM_STATIC_TARGETS if name in installed]
    missing = [name for name in OPTIONAL_STATIC_TARGETS if name not in installed]
    present = [name for name in OPTIONAL_STATIC_TARGETS if name in installed]

    print("")
    print("Libmpv 静态链接外部依赖检查（提示项，不影响当前退出码）:")
    print("最小外部依赖集:")
    if present_minimum:
        print("  已安装:")
        for name in present_minimum:
            print(f"    - {name}.xcframework")
    if missing_minimum:
        print("  仍缺:")
        for name in missing_minimum:
            print(f"    - {name}.xcframework")
    else:
        print("  最小外部依赖集已安装。")

    if present:
        print("")
        print("已安装外部依赖:")
        for name in present:
            print(f"  - {name}.xcframework")

    if missing:
        print("仍缺外部依赖:")
        for name in missing:
            print(f"  - {name}.xcframework")
        print("")
        print("说明：当前 Libmpv.framework 是静态库。未补齐这些依赖前，不要直接 import Libmpv 或调用 mpv_create/mpv_initialize。")
    else:
        print("外部静态依赖已全部安装，可进入下一阶段 mpv_create 初始化验证。")

    print("")
    print("打开 Libmpv 静态初始化时还需要确认系统 framework Link:")
    for name in SYSTEM_FRAMEWORKS_FOR_STATIC_LINK:
        print(f"  - {name}")


def main() -> int:
    print(f"检查 MPVKit 运行依赖目录: {DEPENDENCY_DIR.relative_to(ROOT)}")
    if not DEPENDENCY_DIR.exists():
        print("目录尚未创建，请先运行 scripts/fetch_mpv_dependencies.sh 或 scripts/install_mpv_dependencies.sh。")
        return 1

    results = [check_target(name) for name in REQUIRED_TARGETS]
    print_optional_static_dependency_report()

    print("")
    print(f"自由度内核占位目录: {FREEDOM_DIR.relative_to(ROOT)}")
    print("该目录不属于 MPVKit 依赖检查范围，后续 Freedom/libmpv.xcframework 单独验证。")

    if all(results):
        print("")
        print("MPVKit 核心运行依赖检查通过。")
        print("注意：这不代表 Package.swift 外部静态 binaryTarget 已全部补齐。")
        return 0

    print("")
    print("MPVKit 核心运行依赖不完整。")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
