#!/usr/bin/env python3
"""端到端验证：用 SQL 建库 + 按模型字段做插入/读取往返。

模拟 Dart 侧 toMap()/fromMap() 的列名，验证：
  1. 每张表都能建
  2. 用模型列名插入成功
  3. 读回值与写入值一致（含 download 的 v4 可空列 NULL 容忍）
  4. 唯一约束 (zhanyuan.name+dyurl) 生效
"""
from __future__ import annotations

import pathlib
import sqlite3
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent


def main() -> int:
    con = sqlite3.connect(":memory:")
    con.executescript((ROOT / "contract/schema/schema_v1.sql").read_text())
    # 补 v2 之外的索引（v3）
    cur = con.cursor()
    errors = 0

    # zhanyuan 往返
    cur.execute(
        "INSERT INTO zhanyuan (name,searchUrl,searchUA,playUA,websearchurl,searchname,"
        "searchid,searchpic,searchstarr,detaillist,detailxl,detailjs,detailjsurl,"
        "isActive,updatedAt,dyurl) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        ("源A", "http://a/s", "", "", "", "", "", "", "", "", "", "", "", 1, 1700000000, "dy1"),
    )
    row = cur.execute("SELECT name,isActive,dyurl FROM zhanyuan WHERE name='源A'").fetchone()
    if row == ("源A", 1, "dy1"):
        print("  ✅ zhanyuan 插入/读取往返 OK (bool→1)")
    else:
        print(f"  ❌ zhanyuan 往返异常: {row}"); errors += 1

    # 唯一约束 (name,dyurl)
    try:
        cur.execute(
            "INSERT INTO zhanyuan (name,searchUrl,updatedAt,dyurl) VALUES (?,?,?,?)",
            ("源A", "http://b/s", 1700000001, "dy1"),
        )
        print("  ❌ zhanyuan UNIQUE(name,dyurl) 未生效"); errors += 1
    except sqlite3.IntegrityError:
        print("  ✅ zhanyuan UNIQUE(name,dyurl) 生效")

    # download v4 可空列 —— 旧数据 NULL 容忍
    cur.execute(
        "INSERT INTO download (name,laiyuan,imgurl,detailurl,playurl,jishu,progress,"
        "status,filePath,fileSize,downloadedSize,addedAt) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
        ("下载1", "", "", "", "http://v/1.m3u8", 1, 0.5, "downloading", "/tmp/a", 100, 50, 1700000000),
    )
    row = cur.execute("SELECT name,status,progress,sourceType,engineKey,vodId,headers FROM download").fetchone()
    if row[2] == 0.5 and row[3:] == (None, None, None, None):
        print("  ✅ download v4 可空列 NULL 容忍 OK")
    else:
        print(f"  ❌ download 可空列异常: {row}"); errors += 1

    # 全表计数
    tables = ["zhanyuan", "apiyuan", "subscription", "favorite", "history",
              "download", "settings", "jiexisetting", "search_history"]
    for t in tables:
        cur.execute(f"SELECT COUNT(*) FROM {t}")
    print(f"  ✅ 9 张表全部可查（{', '.join(tables)}）")

    print()
    print("端到端验证:", "通过 ✅" if errors == 0 else f"{errors} 项失败")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
