#!/usr/bin/env python3
"""UI 令牌守卫（批次 A · A-11）—— R-2 圆角 / R-3 字号 / R-4 主色不散落。

唯一真相源：`docs/UI对齐基准_v1.0.md` §5（验收口径 R-1~R-5）与 §2.4 / §2.3。

与数据层的 `check_contract_sync.py` 对称：数据层守护契约键，本脚本守护表现层令牌。
只扫 `lib/`（`vbox/` 为 iOS 基准侧，D1 零改动，不在约束范围）。

验证项：
  R-2 圆角受控：`BorderRadius.circular(N)` / `Radius.circular(N)` 的 N 必须取自
      §2.4 档位集合 {4, 6, 8, 10, 12, 14, 16, 20}（常量引用不触发）。
  R-3 字号受控：`fontSize: N` 的 N 必须取自 §2.3 档位集合
      {10, 11, 12, 13, 14, 15, 16, 18, 24, 28}。
  R-4 主色不散落：禁止 `Color(0x...)` 十六进制字面量；仅令牌文件
      `lib/presentation/theme/tokens/colors.dart` 例外。

遗留豁免：`LEGACY_EXEMPT` 仅登记第 1 轮已交付、且改动会牵动既有视觉的既有值；
新增代码不得进入该表（R-5 的精神：豁免须显式登记且可审计）。

用法：
  python3 scripts/check_ui_tokens.py            # 全量扫描
  python3 scripts/check_ui_tokens.py --selftest # 负向自测（守卫须能拦截）
"""
from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
LIB = ROOT / "lib"

# ── 档位集合（UI 基准 §2.3 / §2.4，与 Dart 令牌层一一对应）──────────────
RADIUS_SCALE: frozenset[int] = frozenset({4, 6, 8, 10, 12, 14, 16, 20})
FONT_SIZE_SCALE: frozenset[int] = frozenset({10, 11, 12, 13, 14, 15, 16, 18, 24, 28})

# R-4 例外：颜色令牌文件是唯一允许出现十六进制字面量的位置。
COLOR_TOKEN_WHITELIST: frozenset[str] = frozenset(
    {"lib/presentation/theme/tokens/colors.dart"}
)

# 遗留豁免：`相对路径 → {规则: 允许值集合}`。仅第 1 轮既有值，新增代码禁止入表。
LEGACY_EXEMPT: dict[str, dict[str, frozenset[int]]] = {
    # 第 1 轮：观看记录进度条圆角 2px（细条收边），改档位会牵动既有视觉，暂豁免。
    "lib/presentation/widgets/library_views.dart": {"R2": frozenset({2})},
}

# ── 检测正则 ───────────────────────────────────────────────────────────
COLOR_RE = re.compile(r"Color\(\s*0x")
RADIUS_RE = re.compile(r"\b(?:BorderRadius|Radius)\.circular\(\s*(\d+)")
FONT_SIZE_RE = re.compile(r"\bfontSize:\s*(\d+)")


def _is_comment(line: str) -> bool:
    """整行注释（`//` / `///`）不计入 —— 文档里常有示例值。"""
    return line.lstrip().startswith("//")


def scan_source(rel: str, src: str) -> list[tuple[str, int, str]]:
    """扫描单个源文本，返回 `[(规则, 行号, 片段)]`（行号 1-based）。"""
    hits: list[tuple[str, int, str]] = []
    exempt: dict[str, frozenset[int]] = LEGACY_EXEMPT.get(rel, {})

    for idx, raw in enumerate(src.splitlines(), start=1):
        if _is_comment(raw):
            continue

        if COLOR_RE.search(raw) and rel not in COLOR_TOKEN_WHITELIST:
            hits.append(("R4", idx, raw.strip()))

        for m in RADIUS_RE.finditer(raw):
            value = int(m.group(1))
            if value not in RADIUS_SCALE and value not in exempt.get("R2", frozenset()):
                hits.append(("R2", idx, raw.strip()))

        for m in FONT_SIZE_RE.finditer(raw):
            value = int(m.group(1))
            if value not in FONT_SIZE_SCALE and value not in exempt.get("R3", frozenset()):
                hits.append(("R3", idx, raw.strip()))

    return hits


def dart_files() -> list[pathlib.Path]:
    if not LIB.exists():
        return []
    return sorted(LIB.rglob("*.dart"))


def run_scan() -> int:
    files = dart_files()
    print(f"== UI 令牌守卫 R-2/R-3/R-4（{len(files)} 个文件）==")

    buckets: dict[str, list[str]] = {"R2": [], "R3": [], "R4": []}
    for path in files:
        rel = path.relative_to(ROOT).as_posix()
        try:
            src = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            buckets["R4"].append(f"{rel}: 非 UTF-8 编码")
            continue
        for rule, line_no, snippet in scan_source(rel, src):
            buckets[rule].append(f"{rel}:{line_no}  {snippet}")

    labels = {
        "R2": f"R-2 圆角受控（档位 {sorted(RADIUS_SCALE)}）",
        "R3": f"R-3 字号受控（档位 {sorted(FONT_SIZE_SCALE)}）",
        "R4": "R-4 主色不散落（仅令牌文件可写十六进制）",
    }

    errors = 0
    for rule in ("R2", "R3", "R4"):
        found = buckets[rule]
        if found:
            print(f"  ❌ {labels[rule]}：{len(found)} 处越界")
            for item in found:
                print(f"     - {item}")
            errors += len(found)
        else:
            print(f"  ✅ {labels[rule]}：通过")

    if errors:
        print(f"\nUI 令牌守卫: 失败（{errors} 处）")
        return 1
    print("\nUI 令牌守卫: 通过 ✅")
    return 0


# ── 负向自测：守卫必须能拦截越界样例 ────────────────────────────────────
_SELFTEST_CASES: list[tuple[str, str, str, bool]] = [
    # (规则, 说明, 源码片段, 期望被拦截)
    ("R2", "圆角越界 2", "ClipRRect(borderRadius: BorderRadius.circular(2)),", True),
    ("R2", "圆角越界 5", "ClipRRect(borderRadius: Radius.circular(5)),", True),
    ("R2", "圆角合规 8", "ClipRRect(borderRadius: BorderRadius.circular(8)),", False),
    ("R2", "常量引用不触发", "BorderRadius.all(Radius.circular(r8)),", False),
    ("R3", "字号越界 17", "TextStyle(fontSize: 17),", True),
    ("R3", "字号合规 13", "TextStyle(fontSize: 13),", False),
    ("R3", "变量引用不触发", "TextStyle(fontSize: size),", False),
    ("R4", "十六进制散落", "color: const Color(0xFFE11D48),", True),
    ("R4", "令牌引用不触发", "color: VboxColors.skinPrimaryRose,", False),
    ("R4", "注释里的示例不触发", "// 允许示例 Color(0x000000)", False),
]


def run_selftest() -> int:
    print(f"== UI 令牌守卫 · 负向自测（{len(_SELFTEST_CASES)} 例）==")
    failures = 0
    for rule, desc, snippet, should_flag in _SELFTEST_CASES:
        hit = any(r == rule for r, _, _ in scan_source("<selftest>", snippet))
        ok = hit == should_flag
        mark = "✅" if ok else "❌"
        expect = "应拦截" if should_flag else "应放行"
        print(f"  {mark} [{rule}] {desc}（{expect}）")
        if not ok:
            failures += 1

    if failures:
        print(f"\n负向自测: 失败（{failures} 例）")
        return 1
    print("\n负向自测: 通过 ✅")
    return 0


def main(argv: list[str]) -> int:
    if "--selftest" in argv:
        return run_selftest()
    return run_scan()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))