#!/usr/bin/env python3
"""迁移链验证：模拟 sqflite 的 onCreate(v0→v4) 与 onUpgrade(v1→v4) 两条路径。

校验：
  1. 两条路径最终结构一致
  2. 与 contract/schema/schema_v1.sql 一致
  3. download 表 v4 的 4 个可空列存在
  4. zhanyuan/apiyuan 的 UNIQUE(name, dyurl) 已生效
  5. v2 重建迁移能保留旧数据
"""
from __future__ import annotations

import pathlib
import re
import sqlite3
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent


def extract(dart: str, name: str) -> list[str]:
    m = re.search(rf"const List<String> {name} = <String>\[(.*?)\n\];", dart, re.S)
    body = m.group(1)
    out = [b.strip() for b in re.findall(r"'''(.*?)'''", body, re.S) if b.strip()]
    rest = re.sub(r"'''.*?'''", "", body, flags=re.S)
    for line in rest.splitlines():
        mm = re.match(r"\s*'([A-Z][^']*)',?\s*$", line)
        if mm:
            out.append(mm.group(1).strip())
    return out


def run(con: sqlite3.Connection, stmts: list[str]) -> None:
    for s in stmts:
        con.executescript(s.rstrip(";") + ";")


def cols_of(con: sqlite3.Connection) -> dict[str, set[str]]:
    return {
        t: {c[1] for c in con.execute(f"PRAGMA table_info({t})")}
        for (t,) in con.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"
        )
    }


def main() -> int:
    dart = (ROOT / "lib/contract/schema/schema.dart").read_text()
    v = {
        1: extract(dart, "_v1CreateTables"),
        2: extract(dart, "_v2Migrate"),
        3: extract(dart, "_v3Migrate"),
        4: extract(dart, "_v4Migrate"),
    }
    errors = 0

    # 路径 A：onCreate
    a = sqlite3.connect(":memory:")
    for k in (1, 2, 3, 4):
        run(a, v[k])
    cols_a = cols_of(a)

    # 路径 B：onUpgrade（先建 v1 并写入旧数据，验证 v2 重建不丢数据）
    b = sqlite3.connect(":memory:")
    run(b, v[1])
    b.execute(
        "INSERT INTO zhanyuan (name,searchUrl,updatedAt) VALUES ('旧源','http://old',123)"
    )
    for k in (2, 3, 4):
        run(b, v[k])
    cols_b = cols_of(b)
    kept = b.execute("SELECT name, dyurl FROM zhanyuan").fetchall()

    # 契约
    c = sqlite3.connect(":memory:")
    c.executescript((ROOT / "contract/schema/schema_v1.sql").read_text())
    cols_c = cols_of(c)

    print("== 1. 两条路径结构一致 ==")
    if cols_a == cols_b:
        print("  ✅ onCreate 与 onUpgrade 结果一致")
    else:
        print("  ❌ 两条路径不一致")
        errors += 1

    print("== 2. 与 SQL 契约一致 ==")
    if cols_a == cols_c:
        print(f"  ✅ 9 表字段与 schema_v1.sql 一致")
    else:
        print("  ❌ 与契约不一致")
        errors += 1

    print("== 3. download v4 可空列 ==")
    need = {"sourceType", "engineKey", "vodId", "headers"}
    if need <= cols_a["download"]:
        print("  ✅ 4 个可空列存在")
    else:
        print(f"  ❌ 缺 {sorted(need - cols_a['download'])}")
        errors += 1

    print("== 4. UNIQUE(name, dyurl) ==")
    for t in ("zhanyuan", "apiyuan"):
        ddl = a.execute(
            "SELECT sql FROM sqlite_master WHERE name=?", (t,)
        ).fetchone()[0]
        if "UNIQUE(name, dyurl)" in ddl:
            print(f"  ✅ {t}")
        else:
            print(f"  ❌ {t} 缺唯一约束")
            errors += 1

    print("== 5. v2 重建迁移保留旧数据 ==")
    if kept == [("旧源", "")]:
        print(f"  ✅ 旧数据保留且 dyurl 补空: {kept}")
    else:
        print(f"  ❌ 数据迁移异常: {kept}")
        errors += 1

    print()
    print("迁移链验证:", "通过 ✅" if errors == 0 else f"{errors} 项失败")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
