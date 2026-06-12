#!/usr/bin/env python3
"""下载并安装 MPVKit 的外部静态 binaryTarget 依赖。

默认只安装 minimum=true 的最小缺失集：
gmp / Libass / Libbluray / lcms2。

脚本只服务 MPVKitDependencies，不处理 Freedom 自由度内核。
"""
from __future__ import annotations

import argparse
import json
import shutil
import sys
import tempfile
import time
import urllib.request
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEPENDENCY_DIR = ROOT / "vbox" / "Libraries" / "MPV" / "MPVKitDependencies"
MANIFEST_PATH = ROOT / "scripts" / "mpvkit_external_dependencies.json"
DEFAULT_CACHE_DIR = ROOT / ".mpv-cache" / "external"


def load_manifest() -> list[dict[str, object]]:
    with MANIFEST_PATH.open("r", encoding="utf-8") as file:
        payload = json.load(file)
    return list(payload["dependencies"])


def selected_dependencies(only_minimum: bool, names: list[str]) -> list[dict[str, object]]:
    dependencies = load_manifest()
    if names:
        wanted = set(names)
        dependencies = [item for item in dependencies if str(item["name"]) in wanted]
        missing_names = wanted - {str(item["name"]) for item in dependencies}
        if missing_names:
            raise SystemExit(f"清单中未找到依赖: {', '.join(sorted(missing_names))}")
        return dependencies

    if only_minimum:
        return [item for item in dependencies if bool(item.get("minimum"))]

    return dependencies


def download(url: str, destination: Path, retries: int = 3) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    last_error: Exception | None = None

    for attempt in range(1, retries + 1):
        try:
            print(f"下载: {url}")
            with urllib.request.urlopen(url, timeout=120) as response, destination.open("wb") as file:
                shutil.copyfileobj(response, file)
            return
        except Exception as error:  # noqa: BLE001 - CI 脚本需要打印真实下载错误
            last_error = error
            print(f"下载失败（第 {attempt}/{retries} 次）: {error}")
            if attempt < retries:
                time.sleep(2 * attempt)

    raise SystemExit(f"下载失败: {url}\n原因: {last_error}")


def find_xcframework(extract_dir: Path, name: str) -> Path:
    direct = extract_dir / f"{name}.xcframework"
    if direct.exists():
        return direct

    matches = list(extract_dir.rglob(f"{name}.xcframework"))
    if not matches:
        raise SystemExit(f"未能从压缩包中找到 {name}.xcframework")

    return matches[0]


def install_dependency(item: dict[str, object], cache_dir: Path, dry_run: bool) -> None:
    name = str(item["name"])
    url = str(item["url"])
    destination = DEPENDENCY_DIR / f"{name}.xcframework"
    archive = cache_dir / f"{name}.xcframework.zip"

    if destination.exists():
        print(f"已存在，跳过: {destination.relative_to(ROOT)}")
        return

    print("")
    print(f"准备安装外部依赖: {name}.xcframework")
    print(f"说明: {item.get('reason', '')}")

    if dry_run:
        print(f"dry-run: 将下载 {url}")
        return

    if not archive.exists():
        download(url, archive)
    else:
        print(f"使用缓存: {archive.relative_to(ROOT)}")

    with tempfile.TemporaryDirectory() as temp:
        extract_dir = Path(temp)
        with zipfile.ZipFile(archive) as zip_file:
            zip_file.extractall(extract_dir)

        source = find_xcframework(extract_dir, name)
        DEPENDENCY_DIR.mkdir(parents=True, exist_ok=True)
        if destination.exists():
            shutil.rmtree(destination)
        shutil.copytree(source, destination)

    print(f"已安装: {destination.relative_to(ROOT)}")


def main() -> int:
    parser = argparse.ArgumentParser(description="下载 MPVKit 外部静态依赖")
    parser.add_argument("--all", action="store_true", help="安装清单中的全部外部依赖")
    parser.add_argument("--name", action="append", default=[], help="只安装指定依赖，可重复传入")
    parser.add_argument("--cache-dir", default=str(DEFAULT_CACHE_DIR), help="下载缓存目录")
    parser.add_argument("--dry-run", action="store_true", help="只打印将要安装的依赖，不下载不写入")
    args = parser.parse_args()

    dependencies = selected_dependencies(only_minimum=not args.all, names=args.name)
    cache_dir = Path(args.cache_dir)

    print("MPVKit 外部静态依赖安装模式:")
    if args.name:
        print(f"  指定依赖: {', '.join(args.name)}")
    elif args.all:
        print("  全部外部依赖")
    else:
        print("  最小缺失集")
    print(f"  缓存目录: {cache_dir}")

    for item in dependencies:
        install_dependency(item, cache_dir, args.dry_run)

    print("")
    print("外部静态依赖安装步骤完成。")
    print("注意：3.157 只安装/检查依赖，不重新打开 import Libmpv 或 mpv_create。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
