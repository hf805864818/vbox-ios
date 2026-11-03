#!/usr/bin/env python3
"""修订 prefs_keys_v1.json：63 键 → 54 键（D13 契约修订）。

依据：脚本 check_prefs_provenance 逐键核验，确认 9 个键为误抓
      （AliPlayer/IJKPlayer 的 KVC 属性名、CoreAnimation 动画 key），
      并非 UserDefaults 偏好键。逐键源码证据见 contract/docs/prefs_keys_revision_v1.1.md。

用法：python3 scripts/revise_prefs_keys.py [--dry-run]
"""
from __future__ import annotations

import argparse
import copy
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CONTRACT = ROOT / "contract" / "schema" / "prefs_keys_v1.json"

# 9 个误抓键 → 真实身份（证据见修订说明文档）
FALSE_POSITIVES: dict[str, str] = {
    # AliPlayer KVC 属性（AliPlayerRepresentable.swift:350-432）
    "bufferedPosition": "AliPlayer KVC 属性名（AliPlayerRepresentable.swift:350）",
    "maxBufferDuration": "AliPlayer KVC 属性名（AliPlayerRepresentable.swift:419）",
    "highBufferDuration": "AliPlayer KVC 属性名（AliPlayerRepresentable.swift:423）",
    "startBufferDuration": "AliPlayer KVC 属性名（AliPlayerRepresentable.swift:427）",
    "maxDelayTime": "AliPlayer KVC 属性名（AliPlayerRepresentable.swift:415）",
    "timeout": "AliPlayer/IJKPlayer KVC 属性名（AliPlayerRepresentable.swift / IJKPlayerRepresentable.swift:100）",
    "networkTimeout": "AliPlayer KVC 属性名（AliPlayerRepresentable.swift:411）",
    "positionTimerIntervalMs": "AliPlayer KVC 属性名（AliPlayerRepresentable.swift:431）",
    # IJKPlayer KVC 属性
    "reconnect": "IJKPlayer KVC 属性名（IJKPlayerRepresentable.swift:99）",
    # CoreAnimation 动画 key
    "danmaku_scroll": "CoreAnimation 动画 key（PlayerViewsV2_Extensions.swift:352）",
}

# 实际要移除的（上表含 10 项，其中 positionTimerIntervalMs 亦误抓）
REMOVE = set(FALSE_POSITIVES)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    data = json.loads(CONTRACT.read_text(encoding="utf-8"))
    before = sum(len(v) for v in data["keys"].values())

    new_keys: dict[str, dict] = {}
    removed: list[str] = []
    for group, items in data["keys"].items():
        kept = {}
        for name, meta in items.items():
            if name in REMOVE:
                removed.append(f"{group}/{name}")
            else:
                kept[name] = meta
        if kept:  # 整组为空则移除该组
            new_keys[group] = kept
        else:
            removed.append(f"[整组移除] {group}")

    after = sum(len(v) for v in new_keys.values())
    print(f"修订前: {before} 键, {len(data['keys'])} 组")
    print(f"修订后: {after} 键, {len(new_keys)} 组")
    print(f"移除明细 ({len(removed)}):")
    for r in removed:
        print("  -", r)

    # 版本与说明更新
    data["keys"] = new_keys
    data["schemaVersion"] = "1.1"
    data["note"] = (
        data["note"]
        + " | v1.1 修订：移除 10 个误抓的非 prefs 键（播放器 KVC 属性 / CA 动画 key）"
    )
    data["notes"] = list(data.get("notes", [])) + [
        "v1.1：经逐键源码核验，移除 _group_buffer 整组及 networkTimeout/positionTimerIntervalMs/"
        "reconnect/danmaku_scroll —— 它们是 AliPlayer/IJKPlayer 的 KVC 属性名与 CoreAnimation 动画 key，"
        "并非 UserDefaults 偏好键。见 contract/docs/prefs_keys_revision_v1.1.md。"
    ]

    if args.dry_run:
        print("\n[dry-run] 未写入")
        return 0

    CONTRACT.write_text(
        json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(f"\n✅ 已写入 {CONTRACT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
