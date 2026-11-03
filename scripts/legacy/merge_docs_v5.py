#!/usr/bin/env python3
"""把分散的项目文档合并进唯一主文档，并升版至 v5。

合并来源：
  docs/DEV_PLAN_v4_with_progress.md  主文档（方案正文 + P.1–P.11）
  docs/PROGRESS.md        → 附录 A（项目状态快照）
  docs/PROJECT_LAYOUT.md  → 附录 B（目录结构）
  docs/KNOWN_GAPS.md      → 附录 C（缺口登记表）

产出：docs/VBOX_PLAN_v6.md
"""
# 说明：本脚本为 v5 期一次性合并工具（历史留存）；产出目标已随文档
# 更名更新为 v6，实际内容由后续增量编辑维护。
from __future__ import annotations

import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"

APPENDIX_A = """# 附录 A：项目状态快照（2026-09-29）

> 本附录合并原 `PROGRESS.md`。**详细进度、核查结果与门禁结论见 P.1–P.11**，
> 本附录仅保留总览与 CI 状态，避免与正文重复。

## A.1 阶段总览

```
第 0 阶段  契约冻结        ████████████████████ 100%  ✅ 已过 D13 门禁
第 1 轮    核心骨架        ███████████░░░░░░░░░  56%  🔄 进行中（E.10b 未通过）
第 2 轮    功能补全        ░░░░░░░░░░░░░░░░░░░░   0%  ⬜ 未开始
第 3 轮    兼容性与稳定性   ░░░░░░░░░░░░░░░░░░░░   0%  ⬜ 未开始
第 4 轮    数据互通与边界   ░░░░░░░░░░░░░░░░░░░░   0%  ⬜ 未开始
第 5 轮    发布准备        ░░░░░░░░░░░░░░░░░░░░   0%  ⬜ 未开始
```

**第 1 轮 56% 的依据**：9 个交付块完成 5 个——
✅ 契约层镜像 · ✅ 数据层 · ✅ 领域层实体 · ✅ 入口与形态判定 · ✅ conformance runner；
⬜ UI 三形态 · ⬜ 平台插件层 · ⬜ 单元测试 · ⬜ Spider 引擎实现。

## A.2 第 0 阶段交付产物（15 文件）

| 类别 | 文件 | 状态 |
|------|------|------|
| SQLite DDL | `contract/schema/schema_v1.sql` | ✅ 9 表 + v1→v4 迁移链 |
| Prefs 契约 | `contract/schema/prefs_keys_v1.json` | ⚠️ 初版 53 键 → **第 1 轮修订为 98 键** |
| JSON Schema | `manifest_v1.json` / `site_v1.json` / `welfare_v1.json` | ✅ |
| Spider ABI | `contract/docs/abi_v1.md` | ✅ 引擎/操作/回调/错误全规范 |
| 备份格式 | `contract/docs/backup_v1.md` | ✅ AES-GCM + PBKDF2 字节级规范 |
| Android 兼容 | `contract/docs/android-compat.md` | ✅ minSdk 24 依据 |
| 检查模板 | `stage_check_template.yaml` / `bug_report_template.yaml` | ✅ |
| 阶段 0 报告 | `stage_check_report_stage0.yaml` | ✅ verdict: pass |
| 一致性样本 | `conformance/fixtures/`（3 类） | ✅ |

## A.3 iOS CI 构建状态

| 项 | 状态 |
|----|------|
| MPVKit 依赖资产缺失 | ✅ 已修复（资产迁入 vboxapp release `mpvkit-deps-0.0.1`，sha256 校验通过） |
| `scripts/*.sh` 缺执行位 | ✅ 已修复（100644 → 100755） |
| 最新构建 | ✅ run `36540984193` = success（IPA 链路跑通） |
| 版本自动 bump | ✅ 已到 `3.1614` |

## A.4 环境约束摘要

| 问题 | 影响 | 应对 |
|------|------|------|
| 无可用 Flutter SDK | **无法编译 / 静态分析 / 单测** | 官方 Linux 包仅 x86-64，本机 aarch64（详见 P.7） |
| `github.com:443` 不可达 | `git push/fetch` 失败 | 推送走 `scripts/api_push2.py`（API 通道，自动 diff） |
| 本地 git 历史与远程不一致 | 无法直接比对 | 网络恢复后 `git fetch && git reset --hard origin/main` |

> ⚠️ **所有 Dart 代码仅通过静态检查，未经编译验证**——当前最大技术风险。
"""

VERSION_NOTE = """> **v5 定稿变更（本版）**：**文档合并**——原 `PROGRESS.md`、`PROJECT_LAYOUT.md`、
> `KNOWN_GAPS.md` 三份附属文档**全部并入本方案**（附录 A / B / C），全项目**仅此一份文档**；
> 新增 P.1–P.11 实际开发进度与核查章节；conformance runner 交付（45/45）；
> 新增文档漂移守护脚本；E.10b 不达标项 12 → 9。

## 版本历史

| 版本 | 主要变更 |
|------|---------|
| v3 | 确认 iOS 方案 A4（契约共享，零改造）；TV 同一 APK 双形态；新增第 0 阶段契约层 |
| v4 | **全部代码由 AI 编写，人力只做测试**（D8）；验收改为自动化 + conformance 自证（D10）；新增第 E 章执行计划、第 V 章 TV 调研、第 S 章侧载方案 |
| **v5（现行）** | **三份附属文档并入（附录 A/B/C），全项目仅一份文档**；补 P.1–P.11 实际进度与核查；conformance runner 交付；文档漂移治理（16→0） |

"""


def strip_header(text: str) -> str:
    """去掉文档的 H1 标题与其后的引用头，返回正文。"""
    lines = text.splitlines(keepends=True)
    i = 0
    while i < len(lines) and (lines[i].startswith("#") or lines[i].strip() == ""):
        if lines[i].startswith("#"):
            i += 1
            break
        i += 1
    while i < len(lines) and lines[i].lstrip().startswith(">"):
        i += 1
    while i < len(lines) and lines[i].strip() in ("", "---"):
        i += 1
    return "".join(lines[i:])


def main() -> int:
    master = (DOCS / "DEV_PLAN_v4_with_progress.md").read_text(encoding="utf-8")
    prog = strip_header((DOCS / "PROGRESS.md").read_text(encoding="utf-8"))
    layout = strip_header((DOCS / "PROJECT_LAYOUT.md").read_text(encoding="utf-8"))
    gaps = strip_header((DOCS / "KNOWN_GAPS.md").read_text(encoding="utf-8"))

    # ① 标题与版本
    master = master.replace(
        "# vbox 项目全面分析与 Flutter 多端重构方案（v4 定稿版 · AI 全量开发）",
        "# vbox 项目全面分析与 Flutter 多端重构方案（**v5 定稿版** · AI 全量开发）", 1)
    # 插入 v5 变更说明 + 版本历史（在首个 D14/D15/D16 段之后、正文分隔之前）
    anchor = "> 迁移已于 2026-09-29 完成（481 文件），Commit `bef4e9e`。\n"
    assert anchor in master, "未找到头部锚点"
    master = master.replace(anchor, anchor + ">\n" + VERSION_NOTE, 1)

    # ② P.11 中的历史文件名加说明（先处理，避免被后续全局替换误改）
    master = master.replace(
        "| 1 | `docs/PROGRESS.md` 严重过期 |",
        "| 1 | 原 `PROGRESS.md` 严重过期（已并入附录 A） |")
    master = master.replace(
        "| 2 | `docs/PROJECT_LAYOUT.md` 与 D18 冲突 |",
        "| 2 | 原 `PROJECT_LAYOUT.md` 与 D18 冲突（已并入附录 B） |")
    master = master.replace(
        "| 4 | 进度文档遗漏 `pubspec.yaml` |",
        "| 4 | 原进度文档遗漏 `pubspec.yaml` |")

    # ③ 全局：指向新附录
    for old, new in (
        ("docs/KNOWN_GAPS.md", "附录 C"),
        ("`KNOWN_GAPS.md`", "附录 C"),
        ("docs/PROGRESS.md", "附录 A"),
        ("docs/PROJECT_LAYOUT.md", "附录 B"),
    ):
        master = master.replace(old, new)

    # ④ 删掉 P.11 中"关键文档必须存在"的旧清单描述（已不再适用）
    master = master.replace(
        "| 关键文档 | `PROGRESS.md` / `KNOWN_GAPS.md` / 本方案 必须存在 |",
        "| 关键文档 | 主方案文档（本文件）必须存在 |")

    # ⑤ 追加附录
    master = master.rstrip()
    master = master.replace("**文档结束**", "")
    master = master.rstrip().rstrip("-").rstrip()

    parts = [
        master,
        "\n\n---\n\n# 附录部分\n",
        "\n---\n\n" + APPENDIX_A.strip() + "\n",
        "\n---\n\n# 附录 B：目录结构（方案 §2.4 落地快照）\n\n> 本附录合并原 `PROJECT_LAYOUT.md`。\n\n" + layout.strip() + "\n",
        "\n---\n\n# 附录 C：缺口登记表（Known Gaps）\n\n> 本附录合并原 `KNOWN_GAPS.md`。"
        "按 E.10b ④「无 TODO 遗留（必须登记或清除）」要求，所有未完成项必须登记于此。\n\n"
        + gaps.strip() + "\n",
        "\n---\n\n**文档结束**\n",
    ]
    out = "".join(parts)

    # ⑥ 校验：不得再出现已删除文件名
    for bad in ("PROGRESS.md", "PROJECT_LAYOUT.md", "KNOWN_GAPS.md", "DEV_PLAN_v4"):
        n = out.count(bad)
        if bad == "PROGRESS.md":
            n -= out.count("原 `PROGRESS.md`")  # 历史叙述允许
        if n > 0:
            print(f"⚠️  仍引用已删文件名 {bad} ×{n}")

    dst = DOCS / "VBOX_PLAN_v6.md"
    dst.write_text(out, encoding="utf-8")
    print(f"✅ 已生成 {dst.relative_to(ROOT)}（{len(out)} 字符 / {out.count(chr(10))+1} 行）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
