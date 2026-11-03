#!/usr/bin/env python3
"""契约完整性校验（双向）：契约 ↔ iOS 源码。

修问题 1 的根因：原有校验只验「实现 ↔ 契约」，不验「契约 ↔ 源码」，
导致契约漏了 44 个键却仍全绿。

本脚本反向穷举 iOS 源码的 prefs 键，检查是否都在契约内。
"""
from __future__ import annotations

import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CONTRACT = ROOT / "contract/schema/prefs_keys_v1.json"

# 明确排除的非 prefs 键（KVC 属性 / CA 动画 / 表名 / 测试数据 / UI 状态）
EXCLUDE = {
    # 表名
    "apiyuan", "download", "favorite", "history", "settings",
    "subscription", "zhanyuan", "search_history", "jiexisetting",
    # 播放器 KVC / SDK 属性
    "bufferedPosition", "currentPosition", "duration", "checked", "pause",
    "width", "height", "timeout", "networkTimeout", "maxBufferDuration",
    "highBufferDuration", "startBufferDuration", "maxDelayTime",
    "positionTimerIntervalMs", "reconnect", "danmaku_scroll",
    "headers", "httpHeaders", "playerUrl", "referer", "orientation",
    "inputCorrectionLevel", "inputMessage", "MPV", "NetworkLoggerHandled",
    "builtin_",
    # IJK 播放器 FFmpeg 选项（非 prefs 键；v1.5 修订移除的误抓键）
    "dns_cache_clear",
    # 测试数据 / UI 局部状态 / 非键字符串
    "a1b2c3d4e5f60708", "abcdefghijklmnopqrstuvwxyz0123456789",
    "app", "feedback", "samsung", "today", "wy", "drpy_js_腾云驾雾",
    # 签名密钥常量（非 prefs 键）
    "l3srvtd7p42l0d0x1u8d7yc8ye9kki4d",
}


def main() -> int:
    files = [p for p in (ROOT / "vbox").rglob("*.swift")
             if ".framework" not in str(p) and ".xcframework" not in str(p)]

    # 反向提取
    src_keys: set[str] = set()
    for p in files:
        txt = p.read_text(errors="ignore")
        for m in re.finditer(r'forKey:\s*"([a-zA-Z_][\w]*)"', txt):
            src_keys.add(m.group(1))
        for pat in [r'let\s+\w*[Kk]ey\s*=\s*"([a-zA-Z_][\w]*)"',
                    r'static let \w+\s*=\s*"([a-zA-Z_][\w]*)"']:
            for m in re.finditer(pat, txt):
                src_keys.add(m.group(1))

    src_keys = {k for k in src_keys
                if k not in EXCLUDE
                and not re.fullmatch(r"[0-9a-f]{24,}", k)
                and re.match(r"^[a-z]", k)}

    # 契约键
    d = json.loads(CONTRACT.read_text())
    ck: set[str] = set()
    for items in d["keys"].values():
        ck |= set(items.keys())

    missing = sorted(src_keys - ck)
    errors = 0

    print("== 契约完整性（源码 → 契约）==")
    print(f"  iOS 源码真实键: {len(src_keys)}")
    print(f"  契约键:         {len(ck)}")
    if missing:
        print(f"  ❌ 契约遗漏 {len(missing)} 个键:")
        for k in missing:
            print(f"      - {k}")
        errors += 1
    else:
        print(f"  ✅ 无遗漏（契约已覆盖源码全部真实键）")

    print("== 契约冗余（契约 → 源码）==")
    extra = sorted(ck - src_keys)
    if extra:
        print(f"  ⚠️ 契约含 {len(extra)} 个源码未见的键（需人工确认）:")
        for k in extra[:15]:
            print(f"      - {k}")
    else:
        print("  ✅ 契约无冗余键")

    print()
    print("契约完整性:", "通过 ✅" if errors == 0 else f"{errors} 项失败")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
