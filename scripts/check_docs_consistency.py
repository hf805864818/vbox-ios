#!/usr/bin/env python3
"""文档一致性校验：防止文档漂移（documentation drift）。

背景
----
历史上出现过同一事实在文档间矛盾的情况：
  · 键数 57 / 63 / 53 / 98 四种口径并存
  · 目录重构后仍引用已删除路径（lib/contract/schema.dart 等）
  · 校验脚本数量 6 / 8 / 9 并存

v6.34 补丁（第 2 轮批次 A · A-06）：契约新增 `app_ui_form_override`，键数 **98 → 99**。
按 v6.2 建立的「陈旧口径入 STALE」惯例，把 **98** 纳入 STALE_KEY_COUNTS，
使残留的「98 键」现行写法当场失败（历史语境仍由 is_history / 块级标记豁免）。

本脚本把「文档漂移」转为可自动检测，规则如下：
  1. 现行键数/组数必须与契约唯一真相源一致（含表格/加粗/合计三种写法，v6.2 起）
  2. 校验脚本数量必须与 scripts/ 目录实际数量一致（含 conformance runner 时 +1）
  3. 不得引用已删除的旧路径或已并入的附属文档（PROJECT_LAYOUT/PROGRESS/KNOWN_GAPS）
  4. 源码（`lib/**/*.dart`）注释不得引用已删除文档 / 失效路径（v6.2 新增）
  5. 关键文档（唯一主方案文档）必须存在，且 `docs/` 下仅此一份
  6. 文件名版本 ↔ 版本历史「（现行）」行 ↔ 顶部「本版变更」块，三处必须一致（v6.9 新增，D24/D25）
  7. 决策编号在决策表内唯一 + 全文 `D<编号>` 引用无悬空（v6.9 新增）
  8. `pubspec.yaml` 的 `version`（`X.Y.Z+N`）↔ `AppInfo.version` / `buildNumber` 必须一致（v6.10 新增）
  9. 现行文档不得出现「空目录」声明：git 不跟踪空目录，此类声明无法验证，须改用「未创建 / 待填充」（v6.10 新增）
  10. `docs/*.md` 的引用必须真实存在：按字面量 DEAD_DOCS 防回流只覆盖主方案文档旧名，
      其他 docs 文档改名/删除后（如检查报告 `_v6.25.md`）残留引用无法被发现（v6.27 新增）

v6.9 补丁：D24/D25 把「文档版本」升级为强制治理 —— 此前版本只活在正文里，文件名可长期停在
`VBOX_PLAN_v6.md`，且「（本版）」标记曾同时出现在两处（v6.6/v6.7）。故新增规则 6/7，
并把旧文件名纳入 DEAD_DOCS，使「改名后残留引用」当场失败。

v6.2 补丁：v6.1 的键数规则要求数字紧邻「键」字，§C.3 把合计写成
``| **合计** | **57** |``（数字后是竖线），整节 57 键 / 14 组得以绕过检测。
现按「表格单元格 / 加粗 / 合计」三种包裹形式识别数值，堵住该格式化逃逸。

历史豁免的两种显式方式（二者取一，禁止靠模糊措辞自我豁免）：
  · 行内强标记：v1.0/v1.1/v1.2、修订、历史、误抓、已删除、废弃、→ 等
  · 块级标记：``<!-- docs-guard:history -->`` 与 ``<!-- /docs-guard:history -->`` 之间的整块
「修复前 vs 修复后」对比表、历史数值表必须放进块级标记；
不得再用「（初版估计值，见 P.6）」这类措辞冒充历史语境（该漏洞已随 v6.1 移除）。

退出码：0 通过 / 1 存在漂移
"""
from __future__ import annotations

import json
import pathlib
import re
import sys
from typing import Iterable

ROOT = pathlib.Path(__file__).resolve().parent.parent
CONTRACT = ROOT / "contract" / "schema" / "prefs_keys_v1.json"

# 允许出现「旧数值」的语境标记（历史叙述、修订对比）
# v6.1：移除「初版 / 估计 / 见 P.6」——这三个弱标记曾让主方案 §2.x 的
#       4 处陈旧「57 键」整行自我豁免，是历史豁免的真实漏洞。
HISTORY_MARKS = (
    "v1.0", "v1.1", "v1.2", "修订", "历史", "原", "误抓", "移除", "→", "->",
    "前", "旧", "曾", "回退", "对比", "before", "deprecated", "废弃",
    "未修复", "bug", "缺陷", "教训", "误报", "故障",
    # v6.10：移除「遗漏」「冗余」——二者过泛，曾让现行清单行
    #        「Prefs 键名 57 个全覆盖，无遗漏无拼错」凭「无遗漏」自我豁免。
    "陈旧", "仍写", "仍列", "过时", "已删除", "同类", "失效",
    "取代",  # v6.2：历史对比用词（如 D18「取代中途生成的 PROJECT_LAYOUT.md」）
)

# 块级历史标记：两行之间的整块豁免「数值规则」（已删除路径规则仍生效）
BLOCK_ON = "<!-- docs-guard:history -->"
BLOCK_OFF = "<!-- /docs-guard:history -->"

# 已知的陈旧总数（曾出现过的错误口径）——仅这些值触发失败
# v6.34：98 入列（A-06 契约扩键 98 → 99 后成为陈旧口径）。
# 2026-10-13（契约 v1.5）：移除误抓键 dns_cache_clear，键数 99 → 98；99 入列、98 出列。
STALE_KEY_COUNTS = {44, 53, 57, 63, 99}
STALE_GROUP_COUNTS = {12, 13}

# 目录重构后已失效的路径（不得作为现行路径引用）
DEAD_PATHS = (
    "lib/contract/schema.dart",
    "lib/data/database_manager.dart",
    "lib/data/prefs_manager.dart",
    "lib/data/backup_manager.dart",
    "lib/domain/spider/",
    "lib/domain/remote_source/",
    "lib/domain/player/player.dart",
)

# v5 并入本方案后已删除的附属文档：不得作为「现行真相源」引用。
# v6.2 新增：此前 app.dart 注释仍写「唯一真相源：docs/PROJECT_LAYOUT.md」，
#           而守卫只扫 *.md，源码注释里的失效引用完全失控。
DEAD_DOCS = ("PROJECT_LAYOUT.md", "PROGRESS.md", "KNOWN_GAPS.md")
# v6.9 新增：D25 起主方案文档文件名携带修订版本号，旧文件名不得再作现行引用
# （历史叙述行含「→」等强标记，仍走 is_history 豁免）。
# v6.10：追加 v6.9 —— 本轮把文件名升到 v6.10，v6.9 成为旧名，纳入防回流。
# v6.11：追加 v6.10 —— 本轮把文件名升到 v6.11，v6.10 成为旧名，纳入防回流。
# v6.12：追加 v6.11 —— 本轮把文件名升到 v6.12（CI 首跑验证），v6.11 成为旧名，纳入防回流。
# v6.13：追加 v6.12 —— 本轮把文件名升到 v6.13（P0 清障批次），v6.12 成为旧名，纳入防回流。
# v6.14：追加 v6.13 —— 本轮把文件名升到 v6.14（前置收口批次），v6.13 成为旧名，纳入防回流。
# v6.15：追加 v6.14 —— 本轮把文件名升到 v6.15（phone 书架批次），v6.14 成为旧名，纳入防回流。
# v6.16：追加 v6.15 —— 本轮把文件名升到 v6.16（远程源列表批次），v6.15 成为旧名，纳入防回流。
# v6.17：追加 v6.16 —— 本轮把文件名升到 v6.17（desktop 形态批次），v6.16 成为旧名，纳入防回流。
# v6.18：追加 v6.17 —— 本轮把文件名升到 v6.18（tv 形态批次，G-01 收官），v6.17 成为旧名，纳入防回流。
# v6.19：追加 v6.18 —— 本轮把文件名升到 v6.19（G-03 评估登记批次），v6.18 成为旧名，纳入防回流。
# v6.20：追加 v6.19 —— 本轮把文件名升到 v6.20（G-02 评估登记批次），v6.19 成为旧名，纳入防回流。
# v6.21：追加 v6.20 —— 本轮把文件名升到 v6.21（G-03-A 桥接协议层交付批次），v6.20 成为旧名，纳入防回流。
# v6.22：追加 v6.21 —— 本轮把文件名升到 v6.22（G-02-A 播放器插件层交付批次），v6.21 成为旧名，纳入防回流。
# v6.23：追加 v6.22 —— 本轮把文件名升到 v6.23（第 1 轮全面检查报告交付批次），v6.22 成为旧名，纳入防回流。
# v6.24：追加 v6.23 —— 本轮把文件名升到 v6.24（G-02-B / G-03-B 平台插件与运行时交付批次），v6.23 成为旧名，纳入防回流。
# v6.25：追加 v6.24 —— 本轮把文件名升到 v6.25（详情页·播放入口接线交付批次），v6.24 成为旧名，纳入防回流。
# v6.26：追加 v6.25 —— 本轮把文件名升到 v6.26（G-02-C / G-05 / 真机验收清单批次），v6.25 成为旧名，纳入防回流。
# v6.27：追加 v6.26 —— 本轮把文件名升到 v6.27（P2 遗留清理批次），v6.26 成为旧名，纳入防回流。
# v6.28：追加 v6.27 —— 本轮把文件名升到 v6.28（A2/A3/B4 接线批次），v6.27 成为旧名，纳入防回流。
# v6.29：追加 v6.28 —— 本轮把文件名升到 v6.29（推送 + CI 反馈修复批次），v6.28 成为旧名，纳入防回流。
# v6.30：追加 v6.29 —— 本轮把文件名升到 v6.30（CI 反馈修复第二轮批次），v6.29 成为旧名，纳入防回流。
# v6.31：追加 v6.30 —— 本轮把文件名升到 v6.31（真机验收排期修订批次，D30），v6.30 成为旧名，纳入防回流。
# v6.32：追加 v6.31 —— 本轮把文件名升到 v6.32（Spider 引擎口径 D31 + 残留漂移订正批次），v6.31 成为旧名，纳入防回流。
# v6.33：追加 v6.32 —— 本轮把文件名升到 v6.33（第 2 轮批次 A「设计基座」首批交付），v6.32 成为旧名，纳入防回流。
# v6.34：追加 v6.33 —— 本轮把文件名升到 v6.34（第 2 轮批次 A「设计基座」续交付 A-05 形态模型 / A-06 契约扩键），v6.33 成为旧名，纳入防回流。
# v6.35：追加 v6.34 —— 本轮把文件名升到 v6.35（第 2 轮批次 A/B/Q 三批次全交付），v6.34 成为旧名，纳入防回流。
# v6.39：追加 v6.38 —— 本轮把文件名升到 v6.39（批次 D 收口 + 批次 E 全交付 + 批次 F 首段网盘），v6.38 成为旧名，纳入防回流。
# v6.40：追加 v6.39 —— 本轮把文件名升到 v6.40（批次 F 第二段 · F-02 登录模式首段），v6.39 成为旧名，纳入防回流。
# v6.41：追加 v6.40 —— 本轮把文件名升到 v6.41（批次 F 第三段 · F-02 收官 + F-03 Node 凭据同步），v6.40 成为旧名，纳入防回流。
# v6.42：追加 v6.41 —— 本轮把文件名升到 v6.42（批次 F 第四段 · F-04 阿里 extscreen 加密链路），v6.41 成为旧名，纳入防回流。
# v6.43：追加 v6.42 —— 本轮把文件名升到 v6.43（批次 F 第五段 · F-05 B站扫码 + 百度专用代理），v6.42 成为旧名，纳入防回流。
# v6.44：追加 v6.43 —— 本轮把文件名升到 v6.44（批次 F 第六段 · F-07 文件列表 / 转存 / 清理队列），v6.43 成为旧名，纳入防回流。
# v6.45：追加 v6.44 —— 本轮把文件名升到 v6.45（批次 F 第七段 · F-08 网盘播放 pan 模式），v6.44 成为旧名，纳入防回流。
# v6.46：追加 v6.45 —— 本轮把文件名升到 v6.46（批次 F 第八段 · F-09 PG 自动化），v6.45 成为旧名，纳入防回流。
# v6.47：追加 v6.46 —— 本轮把文件名升到 v6.47（批次 G 首段 · G-01 音乐队列 + 迷你播放器），v6.46 成为旧名，纳入防回流。
DEAD_DOCS += ("VBOX_PLAN_v6.46.md", "VBOX_PLAN_v6.45.md", "VBOX_PLAN_v6.44.md", "VBOX_PLAN_v6.43.md", "VBOX_PLAN_v6.42.md", "VBOX_PLAN_v6.41.md", "VBOX_PLAN_v6.40.md", "VBOX_PLAN_v6.39.md", "VBOX_PLAN_v6.38.md", "VBOX_PLAN_v6.34.md", "VBOX_PLAN_v6.33.md", "VBOX_PLAN_v6.32.md", "VBOX_PLAN_v6.31.md", "VBOX_PLAN_v6.30.md", "VBOX_PLAN_v6.29.md", "VBOX_PLAN_v6.28.md", "VBOX_PLAN_v6.27.md", "VBOX_PLAN_v6.26.md", "VBOX_PLAN_v6.25.md", "VBOX_PLAN_v6.24.md", "VBOX_PLAN_v6.23.md", "VBOX_PLAN_v6.22.md", "VBOX_PLAN_v6.21.md", "VBOX_PLAN_v6.20.md", "VBOX_PLAN_v6.19.md", "VBOX_PLAN_v6.18.md", "VBOX_PLAN_v6.17.md", "VBOX_PLAN_v6.16.md", "VBOX_PLAN_v6.15.md", "VBOX_PLAN_v6.14.md", "VBOX_PLAN_v6.13.md", "VBOX_PLAN_v6.12.md", "VBOX_PLAN_v6.11.md", "VBOX_PLAN_v6.10.md", "VBOX_PLAN_v6.9.md", "VBOX_PLAN_v6.md", "VBOX_PLAN_v5.md")
# v6.51：追加 v6.50 —— 本轮把文件名升到 v6.51（文档口径修正 · 明确「本机不安装 Flutter SDK」，D25），v6.50 成为旧名，纳入防回流。
DEAD_DOCS += ("VBOX_PLAN_v6.50.md",)

# v6.27 新增：规则 10 —— 捕获任意「引用 docs/ 下已不存在的 .md」的残留
# （DEAD_DOCS 只按字面量匹配主方案旧名；检查报告等文档改名后引用同样会失效）
# （负向断言排除 contract/docs/，避免误伤契约文档引用）
DOC_REF_PAT = re.compile(r"(?<!contract/)docs/([\w\u4e00-\u9fff-]+\.md)")

# 规则 10 的「自我解决」豁免标记：引用所在行同时说明该文档实际位置/命名差异
# （如 ~~`docs/android-min-sdk21-compat.md`~~ ✅ 已生成（`contract/docs/android-compat.md`）），
# 这类行是交付核验表的有意记载，不应误判为失效引用。
SELF_RESOLVED_MARKS = ("已生成", "实际为", "命名差异")

# 规则 10 扫描范围：凡可能以文本形式引用 docs/ 文档的现行文件
REF_GLOBS = (
    "docs/*.md", "contract/docs/*.md", "*.md",
    "lib/**/*.dart", "test/**/*.dart",
    ".github/workflows/*.yml", "scripts/*.py", "scripts/*.sh",
    "android/**/*.kt", "android/**/*.kts", "macos/**/*.swift",
    "windows/**/*.iss", "quickjs/*.c", "quickjs/*.h",
)

# v6.10 新增：现行契约校验套件（check_*.py）总数，供规则 2 使用
APP_CONSTANTS = ROOT / "lib" / "core" / "constants" / "app_constants.dart"

# v6.10 新增：规则 9 的禁词 —— git 不跟踪空目录，任何「空目录」声明都不可验证
EMPTY_DIR_WORD = "空目录"

DOC_GLOBS = ("docs/*.md", "contract/docs/*.md", "*.md")

# 源码目录：其中注释引用的失效路径/文档同样纳管（v6.2 新增）
DART_GLOBS = ("lib/**/*.dart",)

# 数值的「表格 / 加粗 / 合计」写法（v6.2 新增，堵 §C.3 式逃逸）：
#   旧漏洞：C.3 的合计写成 `| **合计** | **57** |`，数字后无「键」字，
#   得以绕过 `(\d+)\s*键` 规则；本组正则按「数值被表格/加粗/合计包裹」识别。
INLINE_COUNT_PATTERNS = (
    r"\*\*(\d{2,3})\*\*",                          # **57**
    r"\|\s*(\d{2,3})\s*\|",                        # | 57 |
    r"(?:合计|总计|共)\s*[:：]?\s*\*{0,2}(\d{2,3})",  # 合计 57
)

# 历史记录类文档（修订说明/变更日志）：其数值描述的是当时状态，整体豁免数值规则
HISTORICAL_DOC_PAT = re.compile(r"(revision|history|changelog|修订|历史)", re.I)

# ── v6.9 新增：主方案文档版本治理（D24/D25）+ 决策编号引用一致性 ──────────────
# 文件名：D25 起必须携带修订次版本号 —— docs/VBOX_PLAN_v<主>.<次>.md
PLAN_NAME_PAT = re.compile(r"^VBOX_PLAN_v(\d+\.\d+)\.md$")
# 版本历史表「（现行）」行：| **v6.9（现行）** | …
CUR_VER_PAT = re.compile(r"\|\s*\*{0,2}v(\d+\.\d+)（现行）\*{0,2}\s*\|")
# 顶部变更块：> **v6.9 变更（本版）**：…
TOP_VER_PAT = re.compile(r"\*{0,2}v(\d+\.\d+)\s*变更（本版）")
# 决策表定义行：| **D8** | …（仅在「决策记录」小节内算定义，别处的均按引用处理）
DEC_ROW_PAT = re.compile(r"^\|\s*\*{0,2}(D\d+)\*{0,2}\s*\|")
DEC_ID_PAT = re.compile(r"\bD(\d+)\b")
DEC_SECTION = "## 〇、决策记录（Decision Log）"


def iter_docs() -> Iterable[pathlib.Path]:
    seen: set[pathlib.Path] = set()
    for g in DOC_GLOBS:
        for p in ROOT.glob(g):
            if p.is_file() and p not in seen:
                seen.add(p)
                yield p


def is_history(line: str) -> bool:
    """判断该行是否为历史/对比叙述（含对比语境，避免自指误报）。"""
    return any(m in line for m in HISTORY_MARKS)


def is_comparative(line: str, cur: int) -> bool:
    """行内同时出现现行数值 → 属新旧对比叙述，豁免。"""
    return str(cur) in line


def is_historical_doc(p: pathlib.Path) -> bool:
    return bool(HISTORICAL_DOC_PAT.search(p.name))


def check_plan_doc_versions(p: pathlib.Path) -> int:
    """规则 6：文件名 / 版本历史「（现行）」行 / 顶部「本版变更」块，三处版本必须一致。"""
    m = PLAN_NAME_PAT.match(p.name)
    if not m:
        print(f"  ❌ 主方案文档文件名 {p.name} 不合规：须为 VBOX_PLAN_vX.Y.md（D25）")
        return 1
    text = p.read_text(encoding="utf-8")
    cur = CUR_VER_PAT.findall(text)
    top = TOP_VER_PAT.findall(text)
    errs = 0
    if len(cur) != 1:
        print(f"  ❌ 版本历史「（现行）」行应恰好 1 处，实为 {len(cur)} 处 {cur}")
        errs += 1
    if len(top) != 1:
        print(f"  ❌ 顶部「本版变更」块应恰好 1 处，实为 {len(top)} 处 {top}")
        errs += 1
    if errs:
        return errs
    if not (m.group(1) == cur[0] == top[0]):
        print(f"  ❌ 版本三处不一致：文件名 v{m.group(1)} · 「（现行）」v{cur[0]} · "
              f"「本版变更」v{top[0]}（D24/D25）")
        return 1
    print(f"  ✅ 版本三处一致：v{m.group(1)}（文件名 / 「（现行）」行 / 「本版变更」块）")
    return 0


def check_decision_ids(p: pathlib.Path) -> int:
    """规则 7：决策表内编号唯一 + 全文 `D<编号>` 引用无悬空。"""
    lines = p.read_text(encoding="utf-8").splitlines()
    start = next((i for i, l in enumerate(lines) if l.startswith(DEC_SECTION)), None)
    if start is None:
        print(f"  ❌ 未找到决策记录小节：{DEC_SECTION}")
        return 1
    end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("## ")),
               len(lines))
    defined = [m.group(1) for m in
               (DEC_ROW_PAT.match(l) for l in lines[start:end]) if m]
    errs = 0
    dupes = sorted({d for d in defined if defined.count(d) > 1})
    if dupes:
        print(f"  ❌ 决策编号重复定义：{dupes}")
        errs += 1
    known = set(defined)
    dangling = sorted({f"D{n}" for n in DEC_ID_PAT.findall("\n".join(lines))
                       if f"D{n}" not in known}, key=lambda s: int(s[1:]))
    if dangling:
        print(f"  ❌ 引用了决策表中不存在的编号：{dangling}")
        errs += 1
    if not errs:
        print(f"  ✅ 决策编号：{len(defined)} 条定义唯一，全文引用无悬空")
    return errs


def check_version_sync() -> int:
    """规则 8：`pubspec.yaml` 的 `version`(X.Y.Z+N) ↔ `AppInfo.version` / `buildNumber`。"""
    pub = (ROOT / "pubspec.yaml").read_text(encoding="utf-8")
    m = re.search(r"^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$", pub, re.M)
    if not m:
        print("  ❌ pubspec.yaml 缺 `version: X.Y.Z+N` 形式的版本号（规则 8）")
        return 1
    ver, build = m.group(1), m.group(2)
    src = APP_CONSTANTS.read_text(encoding="utf-8")
    mv = re.search(r"static const String version = '([^']+)'", src)
    mb = re.search(r"static const int buildNumber = (\d+)", src)
    if not mv or not mb:
        print(f"  ❌ {APP_CONSTANTS.relative_to(ROOT)} 缺 `AppInfo.version` / `buildNumber`（规则 8）")
        return 1
    errs = 0
    if mv.group(1) != ver:
        print(f"  ❌ AppInfo.version={mv.group(1)} ≠ pubspec.yaml {ver}（规则 8）")
        errs += 1
    if mb.group(1) != build:
        print(f"  ❌ AppInfo.buildNumber={mb.group(1)} ≠ pubspec.yaml +{build}（规则 8）")
        errs += 1
    if not errs:
        print(f"  ✅ 版本一致：pubspec {ver}+{build} ↔ AppInfo（规则 8）")
    return errs


def check_empty_dir_words(docs: Iterable[pathlib.Path]) -> int:
    """规则 9：现行文档不得声明「空目录」（git 不跟踪空目录，声明不可验证）。"""
    errs = 0
    for p in docs:
        rel = p.relative_to(ROOT)
        in_block = False
        for i, line in enumerate(p.read_text(encoding="utf-8").splitlines(), 1):
            if BLOCK_OFF in line:
                in_block = False
                continue
            if BLOCK_ON in line:
                in_block = True
                continue
            if in_block or is_history(line):
                continue
            if EMPTY_DIR_WORD in line:
                print(f"  ❌ {rel}:{i} 出现「{EMPTY_DIR_WORD}」声明（不可验证，请写「未创建/待填充」）（规则 9）")
                print(f"      {line.strip()[:100]}")
                errs += 1
    if not errs:
        print(f"  ✅ 无不可验证的「{EMPTY_DIR_WORD}」声明（规则 9）")
    return errs


def check_doc_refs() -> int:
    """规则 10：`docs/*.md` 的引用必须真实存在（v6.27 新增）。

    与规则 1/3/9 相同的豁免口径：历史记录文档（is_historical_doc）、
    块级历史标记、is_history 行、以及引用行自带「已生成/实际为/命名差异」
    等自我解决说明（交付核验表的有意记载）。
    """
    errs = 0
    n_hits = 0
    for g in REF_GLOBS:
        for p in sorted(ROOT.glob(g)):
            if not p.is_file() or is_historical_doc(p):
                continue
            rel = p.relative_to(ROOT)
            in_block = False
            for i, line in enumerate(p.read_text(encoding="utf-8").splitlines(), 1):
                if BLOCK_OFF in line:
                    in_block = False
                    continue
                if BLOCK_ON in line:
                    in_block = True
                    continue
                if in_block or is_history(line):
                    continue
                if "~~" in line or any(m in line for m in SELF_RESOLVED_MARKS):
                    continue
                for m in DOC_REF_PAT.finditer(line):
                    n_hits += 1
                    name = m.group(1)
                    if not (ROOT / "docs" / name).exists():
                        print(f"  ❌ {rel}:{i} 引用 docs/ 下不存在的文档 {name}")
                        print(f"      {line.strip()[:100]}")
                        errs += 1
    if not errs:
        print(f"  ✅ docs/*.md 引用全部存在（规则 10，共核对 {n_hits} 处）")
    return errs


def main() -> int:
    errors = 0
    d = json.loads(CONTRACT.read_text(encoding="utf-8"))
    keys = sum(len(v) for v in d["keys"].values())
    groups = len(d["keys"])
    print(f"真相源：{keys} 键 / {groups} 组 / "
          f"v{d['schemaVersion']}（{CONTRACT.relative_to(ROOT)}）\n")

    docs = sorted(iter_docs())
    print(f"扫描 {len(docs)} 个文档\n")

    # 1 + 3：键数/组数 + 旧路径
    for p in docs:
        rel = p.relative_to(ROOT)
        if is_historical_doc(p):
            print(f"  ·  {rel}（历史记录文档，数值规则豁免）")
            continue
        in_block = False
        for i, line in enumerate(p.read_text(encoding="utf-8").splitlines(), 1):
            if BLOCK_OFF in line:
                in_block = False
                continue
            if BLOCK_ON in line:
                in_block = True
                continue
            if in_block or is_history(line):
                continue
            # 键数（仅在命中已知陈旧口径时失败，避免误伤白名单/KVC 等异对象计数）
            for m in re.finditer(r"(\d+)\s*键", line):
                n = int(m.group(1))
                if n in STALE_KEY_COUNTS and not is_comparative(line, keys):
                    print(f"  ❌ {rel}:{i} 陈旧键数 {n}（现行 {keys}）")
                    print(f"      {line.strip()[:100]}")
                    errors += 1
            # 组数（须与「键」或「分组」共现，避免误伤「5 组验证」等措辞）
            if "键" in line or "分组" in line:
                for m in re.finditer(r"(\d+)\s*组", line):
                    n = int(m.group(1))
                    if n in STALE_GROUP_COUNTS and not is_comparative(line, groups):
                        print(f"  ❌ {rel}:{i} 陈旧组数 {n}（现行 {groups}）")
                        print(f"      {line.strip()[:100]}")
                        errors += 1
            # 「NN 个」写法（v6.10：曾以「Prefs 键名 57 个全覆盖」绕过 —— 数字后是「个」而非「键」）
            if "键" in line:
                for m in re.finditer(r"(\d+)\s*个", line):
                    n = int(m.group(1))
                    if n in STALE_KEY_COUNTS and not is_comparative(line, keys):
                        print(f"  ❌ {rel}:{i} 陈旧键数（「NN 个」写法）{n}（现行 {keys}）")
                        print(f"      {line.strip()[:100]}")
                        errors += 1
            # 数值的表格 / 加粗 / 合计写法（v6.2：堵 §C.3 式「无键字」逃逸）
            for pat in INLINE_COUNT_PATTERNS:
                for m in re.finditer(pat, line):
                    n = int(m.group(1))
                    if n in STALE_KEY_COUNTS and not is_comparative(line, keys):
                        print(f"  ❌ {rel}:{i} 陈旧键数（表格写法）{n}（现行 {keys}）")
                        print(f"      {line.strip()[:100]}")
                        errors += 1
            # 旧路径 / 已删除文档
            for old in DEAD_PATHS + DEAD_DOCS:
                if old in line and not is_comparative(line, keys):
                    print(f"  ❌ {rel}:{i} 引用已失效路径/文档 {old}")
                    print(f"      {line.strip()[:100]}")
                    errors += 1

    # 2：校验脚本数量（v6.1 起为硬失败：须与 scripts/ 目录实际数量一致）
    print()
    n_scripts = len([
        p for p in (ROOT / "scripts").glob("check_*.py")
        if "mpv" not in p.name  # iOS CI 依赖检查，不属契约校验套件
    ])
    runner = (ROOT / "conformance" / "runner" / "run_conformance.py").exists()
    print(f"校验脚本：{n_scripts} 个 check_*.py，runner={'有' if runner else '无'}")
    for p in docs:
        rel = p.relative_to(ROOT)
        in_block = False
        for i, line in enumerate(p.read_text(encoding="utf-8").splitlines(), 1):
            if BLOCK_OFF in line:
                in_block = False
                continue
            if BLOCK_ON in line:
                in_block = True
                continue
            if in_block or is_history(line):
                continue
            if "校验" not in line:
                continue
            m = re.search(r"(\d+)\s*(?:个\s*)?(?:校验\s*)?脚本", line)
            if m:
                n = int(m.group(1))
                # 排除「100% ... 脚本」这类百分号误匹配
                if "%" in line[m.start():m.end()]:
                    continue
                if n not in (n_scripts, n_scripts + (1 if runner else 0)):
                    print(f"  ❌ {rel}:{i} 脚本数 {n}（目录实为 {n_scripts}）")
                    print(f"      {line.strip()[:100]}")
                    errors += 1

    # 4：源码注释不得引用已删除文档 / 失效路径（v6.2 新增）
    print()
    for g in DART_GLOBS:
        for p in sorted(ROOT.glob(g)):
            rel = p.relative_to(ROOT)
            for i, line in enumerate(p.read_text(encoding="utf-8").splitlines(), 1):
                for bad in DEAD_DOCS + DEAD_PATHS:
                    if bad in line:
                        print(f"  ❌ {rel}:{i} 源码引用已失效路径/文档 {bad}")
                        print(f"      {line.strip()[:100]}")
                        errors += 1

    # 5：关键文档存在（主方案文档），6/7：版本三处一致 + 决策编号（v6.9 新增）
    print()
    plans = sorted((ROOT / "docs").glob("VBOX_PLAN_v*.md"))
    if len(plans) != 1:
        print(f"  ❌ docs/ 下主方案文档应恰好 1 个，实为 {len(plans)} 个："
              f"{[p.name for p in plans]}")
        errors += 1
    else:
        plan = plans[0]
        print(f"  ✅ {plan.relative_to(ROOT)} 存在（主方案文档唯一）")
        errors += check_plan_doc_versions(plan)
        print()
        errors += check_decision_ids(plan)

    # 8：pubspec ↔ AppInfo 版本一致；9：不得声明「空目录」（v6.10 新增）
    print()
    errors += check_version_sync()
    print()
    errors += check_empty_dir_words(docs)

    print()
    errors += check_doc_refs()

    print()
    if errors:
        print(f"校验失败：发现 {errors} 处文档漂移")
        return 1
    print("校验通过：文档与真相源一致，无失效路径引用")
    return 0


if __name__ == "__main__":
    sys.exit(main())
