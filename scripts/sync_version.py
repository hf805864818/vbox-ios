#!/usr/bin/env python3
"""从 `.version`（仓库版本唯一真相源）同步版本号到 Flutter 侧。

背景：iOS 侧版本号（`vbox/Info.plist` / `vbox.xcodeproj/project.pbxproj` /
`.version`）由 CI（build-ipa.yml「自动递增版本号」步骤）托管自增；而 Flutter 侧
的 `pubspec.yaml` 与 `lib/core/constants/app_constants.dart`（`AppInfo`）此前
为独立硬编码，**不会跟随仓库版本变动**（表现为设置页 / 启动页版本号停在旧值）。

本脚本把 Flutter 侧的两个落点对齐 `.version`：
  - `pubspec.yaml`                       version: <MAJOR>.<BUILD>.0+<BUILD>
  - `lib/core/constants/app_constants.dart`
        AppInfo.version      = '<MAJOR>.<BUILD>.0'
        AppInfo.buildNumber  = <BUILD>

Android（`flutter.versionName/versionCode`）、Windows（`FLUTTER_VERSION_*`）、
macOS（`$(FLUTTER_BUILD_NUMBER)`）的原生版本号由 Flutter 构建期从 pubspec 自动
派生，故无需单独同步。

守卫规则 8（`scripts/check_docs_consistency.py`）要求 pubspec 与 `AppInfo` 一致，
本脚本同时写这两处，天然满足。

用法：
    python3 scripts/sync_version.py           # 写入（幂等）
    python3 scripts/sync_version.py --check   # 仅校验，不一致则退出码 1
"""
from __future__ import annotations

import argparse
import pathlib
import re
import sys

# Windows 控制台默认 cp1252，输出 emoji / 中文会触发 UnicodeEncodeError
# （Build Release Assets · Windows job 曾因此失败）。
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8")
    except (AttributeError, ValueError):
        pass

ROOT = pathlib.Path(__file__).resolve().parent.parent
VERSION_FILE = ROOT / ".version"
PUBSPEC = ROOT / "pubspec.yaml"
APP_CONSTANTS = ROOT / "lib" / "core" / "constants" / "app_constants.dart"


def read_version_source() -> tuple[int, int]:
    """读取 `.version` 的 MAJOR_VERSION / BASE_BUILD。"""
    if not VERSION_FILE.is_file():
        print(f"❌ 缺少版本真相源：{VERSION_FILE}")
        sys.exit(1)
    text = VERSION_FILE.read_text(encoding="utf-8")
    major = re.search(r"^MAJOR_VERSION=(\d+)", text, re.M)
    build = re.search(r"^BASE_BUILD=(\d+)", text, re.M)
    if not major or not build:
        print("❌ `.version` 缺少 MAJOR_VERSION / BASE_BUILD")
        sys.exit(1)
    return int(major.group(1)), int(build.group(1))


def main() -> int:
    parser = argparse.ArgumentParser(description="同步仓库版本号到 Flutter 侧")
    parser.add_argument("--check", action="store_true", help="只校验不写入")
    args = parser.parse_args()

    major, build = read_version_source()
    semver = f"{major}.{build}.0"
    pubspec_line = f"version: {semver}+{build}"

    changed: list[str] = []

    # ── pubspec.yaml ──
    pub_text = PUBSPEC.read_text(encoding="utf-8")
    new_pub, n_pub = re.subn(
        r"^version:\s*.*$", pubspec_line, pub_text, count=1, flags=re.M
    )
    if n_pub != 1:
        print("❌ pubspec.yaml 未找到 `version:` 行")
        return 1
    if new_pub != pub_text:
        changed.append(f"pubspec.yaml → {pubspec_line}")

    # ── app_constants.dart ──
    app_text = APP_CONSTANTS.read_text(encoding="utf-8")
    new_app = re.sub(
        r"static const String version = '[^']*';",
        f"static const String version = '{semver}';",
        app_text,
        count=1,
    )
    new_app = re.sub(
        r"static const int buildNumber = \d+;",
        f"static const int buildNumber = {build};",
        new_app,
        count=1,
    )
    if new_app == app_text:
        pass  # 已一致
    else:
        changed.append(f"app_constants.dart → {semver} / {build}")

    if not changed:
        print(f"✅ 版本号已一致：{semver}+{build}（无需改动）")
        return 0

    if args.check:
        print(f"❌ 版本号未跟随 `.version`：{semver}+{build}")
        for c in changed:
            print(f"   - {c}")
        return 1

    PUBSPEC.write_text(new_pub, encoding="utf-8")
    APP_CONSTANTS.write_text(new_app, encoding="utf-8")
    print(f"📝 已同步版本号 → {semver}+{build}")
    for c in changed:
        print(f"   - {c}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())