#!/usr/bin/env python3
"""单测覆盖率门槛校验（第 11 个校验脚本，v6.6 新增）。

背景（P.17 #1「覆盖率口径陷阱」）
--------------------------------
`flutter test --coverage` 生成的 `coverage/lcov.info` **只包含被测试触达的文件**；
零触达文件根本不进分母。若直接读 lcov 的 `LH/LF` 汇总，会把「41/69 文件触达」
误读成 83%（实际整体远低于此），门禁 ⑤ 长期不可判。

本脚本按**全 lib 行数口径**重算整体覆盖率：
    分子 = lcov 命中行数（LH 之和）
    分母 = 已触达文件的行数（LF 之和）+ 零触达文件的**可执行行估计**

零触达文件在 lcov 里没有任何记录，故其分母用启发式「非空且非注释行数」估计——
该估计**系统性偏大**（把 class/字段/括号等非插桩行也算进去），因此算出的整体
覆盖率是**保守下界**；真实值只会更高，不会更低。

**纯 export barrel 文件（仅含 export/library/part 语句，无任何可执行代码）不进
分母**：Dart 覆盖率只对可插桩语句计数，export 是声明而非语句，lcov 不会为其生成
记录；若把它们算进分母，等于对「零代码文件」虚增分母，属双重高估。

验证项：
  1. `coverage/lcov.info` 存在（否则提示先跑 `flutter test --coverage`）
  2. 整体覆盖率（全 lib 口径）≥ 门槛 70%
  3. 打印零触达文件清单（不得静默，供补测跟踪）

退出码：0 通过 / 1 不达标或缺少覆盖率数据
"""
from __future__ import annotations

import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
LIB = ROOT / "lib"
LCOV = ROOT / "coverage" / "lcov.info"

# 门禁 ⑤：整体覆盖率（全 lib 口径）≥ 70%
THRESHOLD = 70.0


def lib_files() -> list[pathlib.Path]:
    return sorted(LIB.rglob("*.dart"))


def parse_lcov(path: pathlib.Path) -> dict[str, tuple[int, int]]:
    """返回 {归一化文件路径: (LH, LF)}。"""
    recs: dict[str, tuple[int, int]] = {}
    sf: str | None = None
    lh = lf = 0
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if line.startswith("SF:"):
            sf = line[3:]
        elif line.startswith("LH:"):
            lh = int(line[3:])
        elif line.startswith("LF:"):
            lf = int(line[3:])
        elif line == "end_of_record" and sf is not None:
            # SF 可能是绝对路径：归一化为相对仓库根的路径
            p = pathlib.Path(sf)
            try:
                p = p.relative_to(ROOT)
            except ValueError:
                pass
            recs[str(p)] = (lh, lf)
            sf = None
            lh = lf = 0
    return recs


def code_lines(path: pathlib.Path) -> int:
    """零触达文件的可执行行启发式估计（非空、非注释、非多行字符串内容）。

    多行原始/三引号字符串（单引号或双引号的三连界定）中间的每一行都是字符串
    字面量内容，不是独立的 Dart 可执行行。若不加区分，会把「承载内置脚本 / 大段
    文案」的纯数据字符串（如 `python_bridge_script.dart` 的桥接脚本常量）误当数百
    行待测代码，虚增分母。Dart 原始三引号字符串无转义，闭合符即首个同符三连；
    普通三引号字符串此处亦按首个同符三连近似闭合（启发式方向为少计可执行行，
    不抬高门禁）。
    """
    n = 0
    closer = None
    for raw in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        s = raw.strip()
        # 正处于某多行字符串内部：跳过，直到出现对应的闭合符
        if closer is not None:
            if closer in s:
                closer = None
            continue
        if not s or s.startswith("//") or s.startswith("*") or s.startswith("/*"):
            continue
        # 同行进入多行字符串：打开符之后若未见闭合符，则该字符串跨行
        for opener, close in (
            ("r'''", "'''"),
            ('r"""', '"""'),
            ("'''", "'''"),
            ('"""', '"""'),
        ):
            idx = s.find(opener)
            if idx != -1:
                if s.find(close, idx + len(opener)) == -1:
                    closer = close
                break
        n += 1
    return n


def is_declaration_only(path: pathlib.Path) -> bool:
    """纯声明文件：仅含 `library;` / `export` / `part` / `import` 语句，
    或仅含抽象接口（`abstract interface class` / `abstract class`）成员签名。

    Dart 覆盖率只对可插桩语句（即具实体的可执行语句）计数：
    - export/part/import 是声明，`library;` 是库指令，均非语句；
    - 抽象接口方法签名以 `;` 结尾、无函数体，同样不可插桩。
    lcov 不会为这些文件生成记录。此类文件不进分母（避免对零可执行代码文件
    虚增分母，属双重高估）。
    """
    in_interface = False
    for raw in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        s = raw.strip()
        if not s or s.startswith("//") or s.startswith("///"):
            continue
        # 库指令 / 声明
        if s == "library;" or s.startswith("library "):
            continue
        if s.startswith(("export ", "import ", "part ")):
            continue
        # 抽象接口起始（方法签名均为 `;` 结尾、无函数体）
        if s.startswith(("abstract interface class ", "abstract class ", "abstract final class ")):
            in_interface = True
            continue
        if in_interface:
            if s == "}":
                in_interface = False
            continue
        return False
    return True


def main() -> int:
    print("== 单测覆盖率门槛校验（全 lib 行数口径）==")

    if not LCOV.exists():
        print(f"  ❌ 缺少 {LCOV.relative_to(ROOT)}")
        print("     请先运行：flutter test --coverage")
        return 1

    recs = parse_lcov(LCOV)
    all_files = lib_files()
    all_rel = {str(p.relative_to(ROOT)) for p in all_files}
    touched = {k: v for k, v in recs.items() if k in all_rel}
    untouched = sorted(all_rel - set(touched))

    # 纯声明文件（export barrel / 抽象接口）不进分母，也不列入补测跟踪
    export_only = [f for f in untouched if is_declaration_only(ROOT / f)]
    code_untouched = [f for f in untouched if not is_declaration_only(ROOT / f)]

    lh = sum(v[0] for v in touched.values())
    lf_touched = sum(v[1] for v in touched.values())
    lf_untouched = sum(code_lines(ROOT / f) for f in code_untouched)

    denom = lf_touched + lf_untouched
    overall = 100.0 * lh / denom if denom else 0.0
    touched_pct = 100.0 * lh / lf_touched if lf_touched else 0.0

    print(f"  lib 文件：{len(all_files)} 个 · 触达 {len(touched)} · 零触达 {len(untouched)}"
          f"（纯 export {len(export_only)} 不进分母）")
    print(f"  触达口径（仅统计被触达文件）：{lh}/{lf_touched} = {touched_pct:.1f}%（口径陷阱，不作门禁）")
    print(f"  整体口径（全 lib，保守下界）：{lh}/{denom} = {overall:.1f}%（门槛 {THRESHOLD:.0f}%）")

    if code_untouched:
        print(f"  ⚠️  零触达代码文件 {len(code_untouched)} 个（供补测跟踪）：")
        for f in code_untouched:
            print(f"     - {f}")

    errors = 0
    if overall < THRESHOLD:
        print(f"  ❌ 整体覆盖率 {overall:.1f}% < 门槛 {THRESHOLD:.0f}%")
        errors += 1
    else:
        print(f"  ✅ 整体覆盖率达标（{overall:.1f}% ≥ {THRESHOLD:.0f}%）")

    print()
    if errors:
        print("覆盖率门槛校验: 失败")
        return 1
    print("覆盖率门槛校验: 通过 ✅")
    return 0


if __name__ == "__main__":
    sys.exit(main())