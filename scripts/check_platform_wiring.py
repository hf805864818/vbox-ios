#!/usr/bin/env python3
"""平台层组件接线守卫（S-07-a，第 15 个校验脚本）。

背景：v3.0 §14 的核心教训 ——「数据层 / 平台层完成 ≠ 功能可用」。
平台层能力（控制器 / 解析器 / 代理 / 桥）已实现、文档已登记、单测也全绿，
但表现层从未引用它，用户侧等于「功能不存在」。`flutter analyze` 与单测都
发现不了这类**悬空组件**（代码本身完全合法、测试也全过），只有真机点一遍
才会暴露。

本脚本对 [GUARDS] 登记的能力逐一核对「类是否存在」与「是否被消费域引用」，
把「已接线 / 未接线」变成机器可判定的事实，在本地 / CI 秒级兜住回归。

验证项：
  1. [MISSING]：登记类在 `lib/platform/` 下找不到 → 改名 / 删除需同步本表；
  2. [UNWIRED]：类存在，但消费域零引用 → 悬空组件（失败）；
  3. [豁免残留]：豁免表登记为「未接线」的项实际已被引用 → 提示移除豁免
     （仅提醒不失败：接线是正确动作，不该因此变红）。

判定口径：
  · 消费域 = `lib/` 下**除 `lib/platform/` 外**的全部 Dart 文件；
    presentation / data / domain / app.dart 任一层的引用都算已接线。
    只被平台层内部互相引用**不算** —— 那正是「悬空」的定义。
  · 计数前剥离注释与字符串字面量：防「注释里提一句」「日志文案里出现类名」
    被误当成接线。
  · 只认类名标识符，不做调用图分析（零依赖、秒级、无误报）。

不做的事：调用点深度分析 / 参数级校验（交给 `flutter analyze` 与单测）。

另提供**清单模式** `--audit`：把同样的「零消费者」判定从 9 项守卫扩展到
整个扫描根（默认 `lib/platform` + `lib/domain/services`），一次列出全部
悬空类，供人工分诊。它是**清单而非门禁**（恒返回 0），因为平台层存在
合理的内聚私有类，是否「应当接线」必须由业务判定。
用法：`python3 scripts/check_platform_wiring.py --audit [相对路径 …]`
"""
from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
LIB = ROOT / "lib"
PLATFORM = LIB / "platform"

# 守卫清单：类名 → 能力说明。
# 对齐 v3.0 §2「S-07 悬空组件接线守卫（9 项族）」。其中三项在 Flutter 侧
# 落地时改了名，此处按**现行类名**登记（改名即需同步本表，否则报 [MISSING]）：
#   AutoPlayService     → AutoPlayNextController（playthrough.dart）
#   RemuxProxyServer    → RemuxProxy（remux_proxy.dart）
#   DirectLinkValidator → MediaUrlChecker（media_url_checker.dart，直链可达性校验）
GUARDS: dict[str, str] = {
    "PanPlayer": "网盘播放编排",
    "SubtitleParser": "字幕解析（SRT / VTT / ASS）",
    "LongPressSpeedController": "长按倍速",
    "AutoPlayNextController": "自动连播（下一集）",
    "RemuxProxy": "转封装代理 18081",
    "GoProxyClient": "Go 代理 10078",
    "MediaUrlChecker": "直链可达性 / Content-Type 校验",
    "BackgroundPlayController": "后台播放",
    "PipController": "画中画",
}

# 已登记豁免：S-07 未收口的存量未接线项 —— 点名提示但不失败，
# 免得这批存量噪音把「新增悬空」这一真正要拦的回归淹没。
# 接线后请把对应行删掉（残留豁免会在运行时以「豁免残留」形式点名）。
# 现仅一项：GoProxyClient —— F21 统一播放源交付（0478888）把消费端的
# 代理注册收敛进 `PanPlayer.sourceFor`（平台层内部封装），消费域不再直接
# 引用该标识符；能力本身经 `PanPlayer`（已接线）运行期可达，故点名不判失败。
EXEMPT: dict[str, str] = {
    "GoProxyClient": "经 PanPlayer.sourceFor 平台层封装接入（消费域不再直接引用）",
}

# 声明式检索：抓 `class / mixin / enum <Name>`。
_DECL = re.compile(
    r"^\s*(?:abstract\s+|final\s+|sealed\s+|base\s+|interface\s+)*"
    r"(?:class|mixin|enum)\s+(\w+)",
    re.M,
)

# 审计模式专用：只抓 `class <Name>`。刻意排除 enum / mixin / 私有类 ——
# 它们多为模块内部枚举与工具，零外部引用是常态，混进来只会淹没有效信号。
_AUDIT_DECL = re.compile(
    r"^\s*(?:abstract\s+|final\s+|sealed\s+|base\s+|interface\s+)*"
    r"class\s+(\w+)",
    re.M,
)

# `--audit` 默认扫描根：平台层与领域服务层 —— 悬空组件的高发区。
AUDIT_ROOTS: tuple[str, ...] = ("lib/platform", "lib/domain/services")

# 单个扫描根最多打印的悬空条目数（超出只报计数，免得输出淹没终端）。
AUDIT_PRINT_CAP = 60


def mask_noncode(src: str) -> str:
    """把注释与字符串字面量整体掩成空格（**保留换行与长度**）。

    用单趟状态机而非「先删注释、再删字符串」的组合正则：后者无法同时兼顾
    「注释里出现引号」与「字符串里出现 `//`」这两种互相矛盾的情形，
    任何一种顺序都会误吞真实代码（如 `\"https://x\"`、`/* don't */`）。

    掩码串与源串等长且换行位置一致，故掩码串上的下标可直接在原串换算行号。
    """
    out: list[str] = []
    i, n = 0, len(src)

    def blank(a: int, b: int) -> None:
        out.append("".join("\n" if ch == "\n" else " " for ch in src[a:b]))

    while i < n:
        c = src[i]
        nxt = src[i + 1] if i + 1 < n else ""

        # `//` 行注释
        if c == "/" and nxt == "/":
            j = i
            while j < n and src[j] != "\n":
                j += 1
            blank(i, j)
            i = j
            continue

        # `/* */` 块注释（Dart 允许嵌套）
        if c == "/" and nxt == "*":
            j, depth = i + 2, 1
            while j < n and depth:
                if src[j] == "/" and src[j + 1 : j + 2] == "*":
                    depth += 1
                    j += 2
                elif src[j] == "*" and src[j + 1 : j + 2] == "/":
                    depth -= 1
                    j += 2
                else:
                    j += 1
            blank(i, j)
            i = j
            continue

        # 字符串字面量（含 `r'…'` 原始串与三引号多行串）
        raw = c == "r" and nxt in "\"'"
        if raw or c in "\"'":
            j = i + 1 if raw else i
            delim = src[j] * 3 if src[j : j + 3] == src[j] * 3 else src[j]
            triple = len(delim) == 3
            k = j + len(delim)
            while k < n:
                if not raw and src[k] == "\\":
                    k += 2
                    continue
                if src[k : k + len(delim)] == delim:
                    k += len(delim)
                    break
                if not triple and src[k] == "\n":
                    break
                k += 1
            end = min(k, n)
            blank(i, end)
            i = end
            continue

        out.append(c)
        i += 1

    return "".join(out)


def line_of(src: str, idx: int) -> int:
    """掩码串下标 → 源串行号（1 起）。"""
    return src.count("\n", 0, idx) + 1


def run_guard() -> int:
    """门禁模式：9 项登记能力的接线校验（失败即返回 1）。"""
    errors = 0

    # 自检：豁免表键必须都在守卫清单内，否则是拼写错误（静默失效很危险）。
    stray = sorted(set(EXEMPT) - set(GUARDS))
    if stray:
        print(f"  ❌ 豁免表登记了未守卫的类：{', '.join(stray)}（请先在 GUARDS 登记）")
        errors += len(stray)

    consumers = [p for p in sorted(LIB.rglob("*.dart")) if PLATFORM not in p.parents]
    sources: dict[pathlib.Path, tuple[str, str]] = {}
    for p in consumers:
        src = p.read_text(encoding="utf-8", errors="ignore")
        sources[p] = (src, mask_noncode(src))

    print(
        f"== 平台层组件接线守卫（守卫 {len(GUARDS)} 项能力 / "
        f"消费域 {len(consumers)} 个文件）=="
    )

    # 平台层类声明索引（类名 → 声明文件）。
    declarations: dict[str, pathlib.Path] = {}
    for p in sorted(PLATFORM.rglob("*.dart")):
        src = p.read_text(encoding="utf-8", errors="ignore")
        for m in _DECL.finditer(src):
            declarations.setdefault(m.group(1), p)

    n_wired = n_exempt = n_dangling = n_missing = n_stale = 0

    for name, capability in GUARDS.items():
        decl = declarations.get(name)

        if decl is None:
            n_missing += 1
            errors += 1
            print(f"  ❌ [MISSING] {name}（{capability}）→ lib/platform/ 下无此类")
            continue

        pat = re.compile(rf"\b{re.escape(name)}\b")
        refs = [
            (p, line_of(src, m.start()))
            for p, (src, masked_src) in sources.items()
            for m in pat.finditer(masked_src)
        ]

        if not refs:
            if name in EXEMPT:
                n_exempt += 1
                print(f"  ⏭  [未接线·已豁免] {name}（{capability}）—— {EXEMPT[name]}")
            else:
                n_dangling += 1
                errors += 1
                print(
                    f"  ❌ [UNWIRED] {name}（{capability}）→ "
                    f"平台层有实现（{decl.relative_to(ROOT)}），消费域零引用"
                )
            continue

        n_wired += 1
        first_path, first_line = refs[0]
        if name in EXEMPT:
            n_stale += 1
            print(
                f"  ⚠️  {name}（{capability}）→ {first_path.relative_to(ROOT)}:{first_line}"
                f"（共 {len(refs)} 处）· 已接线，请从 EXEMPT 移除"
            )
        else:
            print(
                f"  ✅ {name}（{capability}）→ {first_path.relative_to(ROOT)}:{first_line}"
                f"（共 {len(refs)} 处）"
            )

    print()
    print(
        f"已接线 {n_wired} · 未接线（已豁免）{n_exempt} · 悬空 {n_dangling} · "
        f"未找到 {n_missing} · 豁免残留 {n_stale}"
    )

    if errors:
        print(f"\n平台层组件接线守卫: 失败（{errors} 处）")
        return 1
    print("\n平台层组件接线守卫: 通过 ✅")
    return 0


# 抓 Dart `import` / `export` 的目标路径（构建模块依赖图用）。
_IMPORT_TARGET = re.compile(r"""^\s*(?:import|export)\s+['"]([^'"]+)['"]""", re.M)


def _resolve_import(src_file: pathlib.Path, target: str) -> pathlib.Path | None:
    """把 Dart import / export 目标解析为绝对路径；非本项目文件返回 None。

    注意 Dart 允许**省略 `./` 前缀**的相对路径（`import 'foo.dart';`），
    barrel 文件普遍这么写；把这类目标当成「非相对」会直接切断整条
    `export` 链，使经 barrel 转出的模块被误判为不可达。
    """
    if target.startswith("dart:"):
        return None
    if target.startswith("package:"):
        if not target.startswith("package:vbox/"):
            return None
        return (LIB / target[len("package:vbox/") :]).resolve()
    # 其余一律按相对路径解析（含省略前缀的写法）。
    return (src_file.parent / target).resolve()


def run_audit(roots: list[pathlib.Path]) -> int:
    """清单模式：按**模块可达性**列出「消费域永远到不了」的悬空模块。

    判定单位刻意从「单个类」提升到「模块」，因为「类名零引用」有两种成因，
    只有其一才是缺口：

      · **内部抽象**（`NodeHost`、`M3u8Parser`）：只被同层模块引用，而那个
        模块本身经 `app.dart` / `download_manager.dart` 等外部入口被触达 ——
        对平台层是合理的分层，**不是缺口**；
      · **整块能力未被任何外部文件 import**（`pip/`、`cast/`、`floating/`）：
        外部入口永远到不了 —— 这才是**真缺口**。

    故先算「从消费域出发的模块可达集」，再报未触达模块。这样 `NodeHost`
    不再冒充缺口，而 `PipController` / `CastService` 这类仍会被准确点名。
    """
    print(f"== 悬空组件审计（按模块可达性；扫描根 {len(roots)} 个）==")

    raw: dict[pathlib.Path, str] = {
        p.resolve(): p.read_text(encoding="utf-8", errors="ignore")
        for p in sorted(LIB.rglob("*.dart"))
    }
    masked_cache: dict[pathlib.Path, str] = {}

    def masked(p: pathlib.Path) -> str:
        if p not in masked_cache:
            masked_cache[p] = mask_noncode(raw[p])
        return masked_cache[p]

    # 模块依赖图（仅保留项目内可解析的目标）。
    imports: dict[pathlib.Path, set[pathlib.Path]] = {}
    for p, src in raw.items():
        deps: set[pathlib.Path] = set()
        for target in _IMPORT_TARGET.findall(src):
            resolved = _resolve_import(p, target)
            if resolved is not None and resolved in raw:
                deps.add(resolved)
        imports[p] = deps

    n_gap = n_internal = 0

    for root in roots:
        root = root.resolve()

        # 可达集：种子 = 被「非本根」文件直接 import 的本根文件；再在本根内传播。
        reached: set[pathlib.Path] = set()
        stack: list[pathlib.Path] = []
        for p, deps in imports.items():
            if root in p.parents:
                continue
            for dep in deps:
                if root in dep.parents and dep not in reached:
                    reached.add(dep)
                    stack.append(dep)
        while stack:
            for dep in imports.get(stack.pop(), ()):
                if root in dep.parents and dep not in reached:
                    reached.add(dep)
                    stack.append(dep)

        root_files = [p for p in raw if root in p.parents]
        unreached = sorted(p for p in root_files if p not in reached)
        n_gap += len(unreached)

        print(
            f"\n-- {root.relative_to(ROOT)}：文件 {len(root_files)} 个 · "
            f"外部可达 {len(root_files) - len(unreached)} · **未触达 {len(unreached)}** --"
        )
        for p in unreached[:AUDIT_PRINT_CAP]:
            names = [
                m.group(1)
                for m in _AUDIT_DECL.finditer(masked(p))
                if not m.group(1).startswith("_")
            ]
            suffix = f"（{'、'.join(names)}）" if names else ""
            print(f"  ❗ {p.relative_to(ROOT)}{suffix}")
        if len(unreached) > AUDIT_PRINT_CAP:
            print(f"  … 其余 {len(unreached) - AUDIT_PRINT_CAP} 个省略")

        # 可达文件里「类名零引用」的类：内部抽象 / 工厂函数模式，仅报计数。
        for p in root_files:
            if p not in reached:
                continue
            for m in _AUDIT_DECL.finditer(masked(p)):
                name = m.group(1)
                if name.startswith("_"):
                    continue
                pat = re.compile(rf"\b{re.escape(name)}\b")
                if not any(
                    pat.search(masked(q))
                    for q in raw
                    if root not in q.parents
                ):
                    n_internal += 1

    print(
        f"\n合计：未触达模块 {n_gap} 个（**真缺口候选**）· "
        f"可达但类名零引用 {n_internal} 个（内部抽象，通常无需处理）。"
        "清单模式不影响退出码；确认应当接线的项请登记进 GUARDS。"
    )
    return 0


def main() -> int:
    argv = sys.argv[1:]
    if "--audit" in argv:
        args = [a for a in argv if not a.startswith("-")]
        roots = [ROOT / a for a in args] or [ROOT / r for r in AUDIT_ROOTS]
        return run_audit(roots)
    return run_guard()


if __name__ == "__main__":
    sys.exit(main())