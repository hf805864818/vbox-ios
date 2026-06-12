#!/usr/bin/env python3
"""检查 MPVKit 二进制依赖包内容。

用法：
  python3 scripts/inspect_mpvkit_bundle.py /path/to/MPVKit-xcframework.zip

脚本只读取压缩包，不修改项目文件。
"""
from __future__ import annotations

import hashlib
import re
import sys
import tempfile
import zipfile
from pathlib import Path


LOCAL_CORE_TARGETS = {
    "Libmpv",
    "Libavcodec",
    "Libavdevice",
    "Libavfilter",
    "Libavformat",
    "Libavutil",
    "Libswresample",
    "Libswscale",
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def extract_outer_bundle(archive: Path, workdir: Path) -> Path:
    with zipfile.ZipFile(archive) as outer_zip:
        names = outer_zip.namelist()
        bundle_names = [name for name in names if name.endswith("MPVKit-binary-bundle.zip")]
        if bundle_names:
            outer_zip.extract(bundle_names[0], workdir)
            bundle_path = workdir / bundle_names[0]

            checksum_names = [name for name in names if name.endswith("MPVKit-binary-bundle.zip.sha256")]
            if checksum_names:
                outer_zip.extract(checksum_names[0], workdir)
                checksum_text = (workdir / checksum_names[0]).read_text(errors="replace").strip()
                actual = sha256(bundle_path)
                print(f"外层校验: {'通过' if actual in checksum_text else '失败'}")
                print(f"  sha256: {actual}")
            return bundle_path

    return archive


def read_package_targets(release_dir: Path) -> list[str]:
    package_file = release_dir / "Package.swift"
    if not package_file.exists():
        return []

    content = package_file.read_text(errors="replace")
    return re.findall(r"\.binaryTarget\(\s*name:\s*\"([^\"]+)\"", content)


def inspect_bundle(bundle_zip: Path, workdir: Path) -> int:
    bundle_dir = workdir / "bundle"
    with zipfile.ZipFile(bundle_zip) as inner_zip:
        inner_zip.extractall(bundle_dir)

    release_dir = bundle_dir / "release"
    if not release_dir.exists():
        print("未找到 release/ 目录，无法识别为 MPVKit binary bundle。")
        return 1

    local_zips = {
        path.name.replace(".xcframework.zip", "")
        for path in release_dir.glob("*.xcframework.zip")
    }
    local_xcframeworks = {
        path.name.replace(".xcframework", "")
        for path in (release_dir / "xcframework").glob("*.xcframework")
    }
    local_targets = local_zips | local_xcframeworks
    package_targets = read_package_targets(release_dir)

    print("\n本地包含的核心依赖:")
    for target in sorted(LOCAL_CORE_TARGETS):
        status = "有" if target in local_targets else "缺少"
        print(f"  {status}: {target}")

    missing_core = sorted(LOCAL_CORE_TARGETS - local_targets)
    if missing_core:
        print("\n核心依赖不完整:")
        for target in missing_core:
            print(f"  - {target}")
    else:
        print("\n核心 Libmpv + FFmpeg 组件齐全。")

    if package_targets:
        non_gpl_targets = [target for target in package_targets if not target.endswith("-GPL")]
        missing_package_targets = sorted(set(non_gpl_targets) - local_targets)
        print("\nPackage.swift 声明但包内未携带的非 GPL 依赖:")
        if missing_package_targets:
            for target in missing_package_targets:
                print(f"  - {target}")
        else:
            print("  无")

    libmpv_info = release_dir / "xcframework" / "Libmpv.xcframework" / "Info.plist"
    if libmpv_info.exists():
        info_text = libmpv_info.read_text(errors="replace")
        print("\nLibmpv 架构:")
        for identifier in re.findall(r"<string>(ios-[^<]+)</string>", info_text):
            print(f"  - {identifier}")

    print("\n结论:")
    if missing_core:
        print("  该包不能作为 MPV 核心依赖安装，需要先补齐核心组件。")
        return 1

    print("  该包可作为 MPV 核心依赖来源，但不是完整离线 Swift Package 依赖包。")
    print("  若走 Swift Package，还需要下载 Package.swift 中未随包携带的 binaryTarget。")
    return 0


def main() -> int:
    if len(sys.argv) != 2:
        print("用法: python3 scripts/inspect_mpvkit_bundle.py /path/to/MPVKit-xcframework.zip")
        return 2

    archive = Path(sys.argv[1]).expanduser().resolve()
    if not archive.exists():
        print(f"文件不存在: {archive}")
        return 2

    with tempfile.TemporaryDirectory(prefix="mpvkit-inspect-") as temp_dir:
        workdir = Path(temp_dir)
        bundle_zip = extract_outer_bundle(archive, workdir)
        return inspect_bundle(bundle_zip, workdir)


if __name__ == "__main__":
    raise SystemExit(main())
