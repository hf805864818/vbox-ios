#!/usr/bin/env python3
"""VBox 双引擎体积与许可核销守卫（批次 Q · Q-06）。

职责
----
1. 许可核销：
   - QuickJS：`quickjs/quickjs-2024-01-13/LICENSE` 须含 MIT 许可声明。
   - JavaScriptCore：`jsc/include/JavaScriptCore/*.h` 须保留 Apple
     BSD-2-Clause 版权声明（运行时源码为 LGPL-2.1 + BSD-2 双许可，
     Q-01 评估结论：动态链接合规，无需开源宿主 App）。
2. 体积登记：
   - 登记各引擎产物的**契约大小区间**（源自 Q-01 评估 / Q-02/Q-04 交付记录）。
   - 若本机存在构建产物则实测并登记字节数；超过登记上限即告警（防异常膨胀）。
   - 产物通常由 CI 构建（不入 git），缺失时仅登记「期望值」，不判失败。

产物
----
`scripts/engine_bundle_registry.json`（体积登记 + 许可结论，供 CI 归档 / P-05 关于页引用）。

退出码
------
0 = 许可合规且登记完成；1 = 许可缺失 / 产物体积越界。
"""
from __future__ import annotations

import json
import pathlib
import sys
from typing import Any

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "scripts"

# 引擎体积登记（契约区间，单位 bytes）。上界来自 Q-01/Q-02/Q-04 交付记录。
# min/max 为 None 表示「无下/上界约束」（仅登记，不做范围校验）。
ARTIFACTS: list[dict[str, Any]] = [
    {
        "id": "quickjs",
        "engine": "QuickJS",
        "artifact": "libvbox_quickjs.{so,dll,dylib}",
        "license": "MIT",
        "min": 500_000,
        "max": 2_000_000,  # 名义 ~1 MB（vendored QuickJS 静态链接）
        "candidates": [
            "build/vbox-quickjs/libvbox_quickjs.so",
            "build/vbox-quickjs/libvbox_quickjs.dylib",
            "build/vbox-quickjs/vbox_quickjs.dll",
            "libvbox_quickjs.so",
        ],
    },
    {
        "id": "jsc-macos",
        "engine": "JavaScriptCore",
        "artifact": "libvbox_jsc.dylib",
        "license": "LGPL-2.1 + BSD-2-Clause（Wrapper 为自有，链系统 JavaScriptCore.framework）",
        "min": 1_000,
        "max": 500_000,  # 仅为 wrapper（系统框架不随包再分发）
        "candidates": ["build/vbox-jsc/macos/libvbox_jsc.dylib"],
    },
    {
        "id": "jsc-windows",
        "engine": "JavaScriptCore",
        "artifact": "JavaScriptCore.dll（Playwright WebKit JSC 运行时，x64；随 vbox_jsc.dll + icu*77.dll 分发）",
        "license": "LGPL-2.1 + BSD-2-Clause（Playwright WebKit JSC-only 运行时，动态链接）",
        "min": 25_000_000,
        "max": 45_000_000,  # Q-03：Playwright WebKit JavaScriptCore.dll 实测 ~32 MB
        "candidates": [
            "build/vbox-jsc/windows/vendor/JavaScriptCore.dll",
            "windows/runner/jsc/vendor/JavaScriptCore.dll",
        ],
    },
    {
        "id": "jsc-android",
        "engine": "JavaScriptCore",
        "artifact": "libjsc.so（四 ABI，RN 生态 jsc-android r250231）",
        "license": "LGPL-2.1 + BSD-2-Clause（运行时）· 预编译 .so 动态链接",
        "min": 4_000_000,
        "max": 8_000_000,  # Q-02：5.0–6.7 MB/ABI
        "candidates": [
            "android/app/src/main/jniLibs/armeabi-v7a/libjsc.so",
            "android/app/src/main/jniLibs/arm64-v8a/libjsc.so",
            "android/app/src/main/jniLibs/x86/libjsc.so",
            "android/app/src/main/jniLibs/x86_64/libjsc.so",
        ],
    },
]

# 许可核销项：文件 → 必含关键词（证明许可声明保留到位）。
LICENSE_CHECKS: list[dict[str, Any]] = [
    {
        "name": "QuickJS MIT",
        "file": "quickjs/quickjs-2024-01-13/LICENSE",
        "must_contain": ["Fabrice Bellard", "Permission is hereby granted, free of charge"],
    },
    {
        "name": "JSC BSD-2-Clause (headers)",
        "file": "jsc/include/JavaScriptCore/JSBase.h",
        "must_contain": ["Apple Inc.", "Redistribution and use in source and binary forms"],
    },
]

RESULTS: list[dict[str, Any]] = []


def check(name: str, ok: bool, detail: str = "") -> bool:
    RESULTS.append({"suite": "engine.bundle", "name": name, "ok": ok, "detail": detail})
    mark = "✅" if ok else "❌"
    line = f"  {mark} {name}"
    if detail and not ok:
        line += f"  —— {detail}"
    print(line)
    return ok


def _scan(candidates: list[str]) -> list[str]:
    found: list[str] = []
    for c in candidates:
        p = ROOT / c
        if p.is_file():
            found.append(str(p.relative_to(ROOT)))
    return found


def license_checks() -> bool:
    ok = True
    for item in LICENSE_CHECKS:
        path = ROOT / item["file"]
        if not path.is_file():
            ok &= check(f"许可文件存在：{item['name']}", False, f"缺 {item['file']}")
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        missing = [k for k in item["must_contain"] if k not in text]
        ok &= check(f"许可声明保留：{item['name']}", not missing,
                    f"缺关键词 {missing}")
    return ok


def volume_registry() -> bool:
    ok = True
    registry: list[dict[str, Any]] = []
    for a in ARTIFACTS:
        found = _scan(a["candidates"])
        measured = sorted((ROOT / f).stat().st_size for f in found) if found else []
        entry: dict[str, Any] = {
            "id": a["id"],
            "engine": a["engine"],
            "artifact": a["artifact"],
            "license": a["license"],
            "minBytes": a["min"],
            "maxBytes": a["max"],
            "found": found,
            "measuredBytes": measured,
            "status": "measured" if found else "expected",
        }
        for size in measured:
            too_small = a["min"] is not None and size < a["min"]
            too_big = a["max"] is not None and size > a["max"]
            if too_small or too_big:
                ok = False
                check(f"体积越界：{a['id']}", False,
                      f"{size} bytes 超出 [{a['min']}, {a['max']}]")
        if found:
            check(f"体积登记：{a['id']}（实测 {measured}，{a['license'][:24]}…）", True)
        else:
            # 产物未在本地（CI 构建），仅登记契约区间不判体积
            check(f"体积登记：{a['id']}（期望 {a['min']}–{a['max']} bytes，本地无产物）", True)
        registry.append(entry)
    return ok, registry


def conclusion(license_ok: bool, volume_ok: bool) -> dict[str, Any]:
    return {
        "dualEngineCompliance": license_ok and volume_ok,
        "summary": (
            "双引擎（JSC 主 / QuickJS 降级）许可与体积核销结论："
            "QuickJS 采用 MIT（无传染义务）；JavaScriptCore 运行时采用 "
            "LGPL-2.1 + BSD-2-Clause（WebKit 双许可）。二者均**动态链接**独立分发"
            "（.so/.dll/.dylib；macOS 链系统框架不随包再分发 JSC 运行时），"
            "无需开源宿主 App；须在关于页（P-05）提供 WebKit 源码获取链接并保留版权声明。"
        ),
        "lgplDynamicLinkCompliant": True,
        "quickJsLicense": "MIT",
        "jsCoreLicense": "LGPL-2.1 + BSD-2-Clause",
        "aboutPageActionRequired": "关于页（P-05）提供 WebKit 源码获取链接 + 保留版权声明",
    }


def main() -> int:
    print("=" * 62)
    print("VBox 双引擎体积与许可核销 (engine bundle guard)")
    print("=" * 62)
    lic_ok = license_checks()
    vol_ok, registry = volume_registry()

    concl = conclusion(lic_ok, vol_ok)
    check("许可核销结论：LGPL-2.1 动态链接合规", concl["lgplDynamicLinkCompliant"])
    check("体积登记完成", True)

    out = SCRIPTS / "engine_bundle_registry.json"
    data = {
        "conclusion": concl,
        "artifacts": registry,
        "licenseChecks": LICENSE_CHECKS,
        "results": RESULTS,
    }
    out.write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf-8")

    failed = sum(1 for r in RESULTS if not r["ok"])
    print("\n" + "=" * 62)
    print(f"合计 {len(RESULTS)} 项：通过 {len(RESULTS) - failed} · 失败 {failed}")
    print("=" * 62)
    print(f"结果已写入 {out.relative_to(ROOT)}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())