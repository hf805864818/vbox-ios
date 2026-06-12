#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

ARCHIVE_PATH="${1:-}"
MODE="${2:-}"

if [ -z "${ARCHIVE_PATH}" ]; then
    echo "用法: scripts/install_mpv_dependencies.sh /path/to/MPVKit-xcframework.zip [--dry-run]"
    exit 2
fi

if [ ! -f "${ARCHIVE_PATH}" ]; then
    echo "文件不存在: ${ARCHIVE_PATH}"
    exit 2
fi

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TEMP_DIR}"' EXIT

python3 - "${ARCHIVE_PATH}" "${TEMP_DIR}" "${MODE}" <<'PY'
from __future__ import annotations

import shutil
import sys
import zipfile
from pathlib import Path

archive = Path(sys.argv[1]).resolve()
temp_dir = Path(sys.argv[2]).resolve()
mode = sys.argv[3] if len(sys.argv) > 3 else ""
dry_run = mode == "--dry-run"

project_root = Path.cwd()
target_dir = project_root / "vbox" / "Libraries" / "MPV" / "MPVKitDependencies"
core_targets = [
    "Libmpv",
    "Libavcodec",
    "Libavdevice",
    "Libavfilter",
    "Libavformat",
    "Libavutil",
    "Libswresample",
    "Libswscale",
]

with zipfile.ZipFile(archive) as outer_zip:
    bundle_names = [name for name in outer_zip.namelist() if name.endswith("MPVKit-binary-bundle.zip")]
    if bundle_names:
        outer_zip.extract(bundle_names[0], temp_dir)
        bundle_zip = temp_dir / bundle_names[0]
    else:
        bundle_zip = archive

bundle_dir = temp_dir / "bundle"
with zipfile.ZipFile(bundle_zip) as inner_zip:
    inner_zip.extractall(bundle_dir)

release_dir = bundle_dir / "release"
if not release_dir.exists():
    raise SystemExit("未找到 release/ 目录，无法安装 MPV 依赖。")

available = set()
for path in release_dir.glob("*.xcframework.zip"):
    available.add(path.name.replace(".xcframework.zip", ""))
for path in (release_dir / "xcframework").glob("*.xcframework"):
    available.add(path.name.replace(".xcframework", ""))

missing = [target for target in core_targets if target not in available]
if missing:
    print("核心依赖缺失，停止安装:")
    for target in missing:
        print(f"  - {target}")
    raise SystemExit(1)

print(f"安装目标目录: {target_dir}")
print("将安装 MPVKit 运行所需核心依赖:")
for target in core_targets:
    print(f"  - {target}.xcframework")

if dry_run:
    print("dry-run 模式：未写入文件。")
    raise SystemExit(0)

target_dir.mkdir(parents=True, exist_ok=True)

for target in core_targets:
    destination = target_dir / f"{target}.xcframework"
    if destination.exists():
        shutil.rmtree(destination)

    source_dir = release_dir / "xcframework" / f"{target}.xcframework"
    if source_dir.exists():
        shutil.copytree(source_dir, destination)
        continue

    zip_path = release_dir / f"{target}.xcframework.zip"
    extract_dir = temp_dir / f"extract-{target}"
    extract_dir.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(zip_path) as dependency_zip:
        dependency_zip.extractall(extract_dir)

    extracted = extract_dir / f"{target}.xcframework"
    if not extracted.exists():
        matches = list(extract_dir.rglob(f"{target}.xcframework"))
        if not matches:
            raise SystemExit(f"未能从 {zip_path.name} 中找到 {target}.xcframework")
        extracted = matches[0]

    shutil.copytree(extracted, destination)

print("MPVKit 核心依赖已安装。")
print("注意：脚本只安装 MPVKit 运行依赖，不安装后续自由度 libmpv.xcframework。")
print("注意：脚本不修改 Xcode Link/Embed。")
print("如果后续走 Swift Package，还需要处理 Package.swift 中未随包携带的 binaryTarget。")
PY
