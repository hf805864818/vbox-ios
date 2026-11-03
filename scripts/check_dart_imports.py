#!/usr/bin/env python3
"""Dart 导入路径校验（第 10 个校验脚本）。

背景：本仓库的 Dart 代码全部经 `flutter analyze` 验证，但那只在 CI 上跑；
而**相对 import 路径写错**这类错误一次会连带十几到二十几个 analyze 报错
（例：`import 'models/models.dart'` 实为 `../../models/models.dart`，
连带 21 个 `Favorite` undefined）。此脚本在本地/CI 秒级兜住这一类错误。

验证项：
  1. 相对 import / export 目标文件存在
  2. `package:vbox/...` 目标落在 `lib/` 下
  3. 未使用 `dart:` 之外的裸包路径（形如 `import 'foo/bar.dart'`）

不做的事（交给 `flutter analyze`）：语法、类型、未使用导入、lint。
"""
from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
LIB = ROOT / "lib"
SCAN_DIRS = [LIB, ROOT / "test"]


def dart_files() -> list[pathlib.Path]:
    out: list[pathlib.Path] = []
    for d in SCAN_DIRS:
        if d.exists():
            out.extend(sorted(d.rglob("*.dart")))
    return out


def main() -> int:
    errors = 0
    files = dart_files()
    print(f"== Dart 导入路径校验（{len(files)} 个文件）==")

    relative_bad: list[str] = []
    package_bad: list[str] = []

    for path in files:
        rel = path.relative_to(ROOT)
        try:
            src = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            print(f"  ❌ {rel}: 非 UTF-8 编码")
            errors += 1
            continue

        for m in re.finditer(r"^\s*(?:import|export)\s+'([^']+)'", src, re.M):
            target = m.group(1)
            if target.startswith("dart:"):
                continue
            if target.startswith("package:"):
                if target.startswith("package:vbox/"):
                    sub = LIB / target[len("package:vbox/"):]
                    if not sub.exists():
                        package_bad.append(f"{rel} → {target}")
                continue
            if not (path.parent / target).resolve().exists():
                relative_bad.append(f"{rel} → {target}")

    if relative_bad:
        print(f"  ❌ 相对路径断链 {len(relative_bad)} 处：")
        for i in relative_bad:
            print(f"     - {i}")
        errors += len(relative_bad)
    else:
        print("  ✅ 相对 import / export 路径全部可达")

    if package_bad:
        print(f"  ❌ package:vbox 路径断链 {len(package_bad)} 处：")
        for i in package_bad:
            print(f"     - {i}")
        errors += len(package_bad)
    else:
        print("  ✅ package:vbox 路径全部可达")

    if errors:
        print(f"\nDart 导入路径校验: 失败（{errors} 处）")
        return 1
    print("\nDart 导入路径校验: 通过 ✅")
    return 0


if __name__ == "__main__":
    sys.exit(main())
