#!/usr/bin/env python3
"""VBox 一致性测试运行器（conformance runner）。

用途
----
消费 conformance/fixtures/ 下的样本，验证契约可执行性：
  ① spider_io_v1.json    —— Spider ABI v1.0 的 5 个操作 + 容错解码 + 错误规则 + 编码链 + 站点模式
  ② sample_v4.sqlite3    —— v4 schema 结构 + 数据可读回
  ③ backup_v1.json       —— 备份格式 + 加密参数 + 白名单 + 遗留字段容错
  ④ manifest_v1.json     —— 远程源 manifest 契约（版本探测 + 必需文件 + 默认值）
  ⑤ engine_abi_v1.json   —— 双引擎 ABI 一致性（JSC 主 / QuickJS 降级）

退出码
------
0 = 全部通过；1 = 存在失败项

说明
----
本 runner 用 Python 实现「参考解析器」，镜像 Dart 侧容错规则
（lib/domain/entities/spider/spider_models.dart）。三端（Dart/Kotlin/Swift）
实现须产出与本 fixture 完全一致的输出。
结果同时写入 conformance/runner/results.json，供 CI 归档。
"""
from __future__ import annotations

import base64
import hashlib
import json
import pathlib
import re
import sqlite3
import sys
from typing import Any

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
FIX = ROOT / "conformance" / "fixtures"
DOCS = ROOT / "contract" / "docs"
SCHEMA = ROOT / "contract" / "schema"

RESULTS: list[dict[str, Any]] = []


def check(suite: str, name: str, ok: bool, detail: str = "") -> bool:
    """记录一条检查结果。"""
    RESULTS.append({"suite": suite, "name": name, "ok": ok, "detail": detail})
    mark = "✅" if ok else "❌"
    line = f"  {mark} {name}"
    if detail and not ok:
        line += f"  —— {detail}"
    print(line)
    return ok


# ---------------------------------------------------------------- 参考实现
def to_str(v: Any) -> str | None:
    """容错转字符串：String 直用；Int/Double 转字符串；其余 None。"""
    if isinstance(v, str):
        return v
    if isinstance(v, bool):
        return None
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        return str(int(v)) if v == int(v) else str(v)
    return None


STR_FIELDS = ("vod_id", "vod_name", "vod_pic", "type_id", "type_name")


def normalize_item(item: dict[str, Any]) -> dict[str, Any]:
    """镜像 Dart 容错解码规则（vodItem / classItem）。"""
    out = dict(item)
    for k in STR_FIELDS:
        if k in out and not isinstance(out[k], str):
            s = to_str(out[k])
            if s is not None:
                out[k] = s
    out.setdefault("vod_name", "")
    out.setdefault("vod_pic", "")
    out.setdefault("engineKey", None)
    out.setdefault("metaDuration", None)
    out.setdefault("availQualities", [])
    return out


def normalize_container(d: dict[str, Any]) -> dict[str, Any]:
    """镜像 PlayerContentResult 的容错规则（urls 回填 + url 数组形态）。"""
    out = dict(d)
    url = out.get("url")
    if isinstance(url, list):
        # url 数组形态（多线路/多音质蜘蛛，对齐 iOS init(from:)）：
        # urls = 全列表、url = 首元素；此形态下 urls 键不再参与。
        items = [str(i) for i in url]
        out["url"] = items[0] if items else None
        out["urls"] = items
    elif "urls" not in out:
        out["urls"] = [url] if isinstance(url, str) and url else None
    if isinstance(out.get("list"), list):
        out["list"] = [
            normalize_item(i) if isinstance(i, dict) else i for i in out["list"]
        ]
    if isinstance(out.get("class"), list):
        out["class"] = [
            normalize_item(i) if isinstance(i, dict) else i for i in out["class"]
        ]
    return out


def resolve_site_mode(site: dict[str, Any]) -> str:
    """镜像 Dart `SiteConfig.resolveSiteMode`（契约 abi_v1.md §1.1）。"""
    key = site.get("key", "")
    typ = site.get("type", 0)
    api = site.get("api", "") or ""
    group = site.get("group")
    if (group == "node" or key.startswith("nodejs_")
            or (key.startswith("csp_") and typ == 3)
            or api.startswith("nodejs_")
            or (api.startswith("csp_") and typ == 3)
            or ("://127.0.0.1" in api and "/spider/" in api)):
        return "node"
    if typ in (0, 1):
        return "apiEndpoint"
    if typ == 2:
        return "zhanyuan"
    if typ == 3:
        if ".jar" in api:
            return "unsupported"
        if api.endswith(".py"):
            return "pythonSpider"
        is_http = api.startswith("http://") or api.startswith("https://")
        if is_http and api.endswith(".js"):
            return "jsSpider"
        if is_http and not api.endswith(".js"):
            return "apiEndpoint"
        if api.endswith(".js") or api.startswith("./"):
            return "jsSpider"
        return "unsupported"
    return "unsupported"


def normalize_manifest(m: dict[str, Any]) -> dict[str, Any]:
    """镜像 Dart `RemoteManifest.fromJson` + `RemoteManifestDatasource` 校验链。"""
    cfg = str(m.get("configVersion", "") or "")
    files = m.get("files") or {}
    return {
        "schemaVersion": m.get("schemaVersion", 1),
        "configVersion": cfg,
        "hasValidConfigVersion":
            re.match(r"^\d{4}\.\d{2}\.\d{2}\.\d+$", cfg) is not None,
        "hasAllSources": "allSources" in files,
        "ttlSeconds": m.get("ttlSeconds", 21600),
        "forceRefresh": m.get("forceRefresh", True),
        "disabledKeys": list(m.get("disabledKeys", []) or []),
        "minAppVersion": m.get("minAppVersion"),
    }


def subset(expected: Any, actual: Any) -> tuple[bool, str]:
    """校验 expected 是 actual 的子集（逐键递归）。"""
    if isinstance(expected, dict):
        if not isinstance(actual, dict):
            return False, f"期望 dict，实为 {type(actual).__name__}"
        for k, v in expected.items():
            if k not in actual:
                return False, f"缺键 {k}"
            ok, why = subset(v, actual[k])
            if not ok:
                return False, f"{k}: {why}"
        return True, ""
    if isinstance(expected, list):
        if not isinstance(actual, list) or len(actual) != len(expected):
            return False, "列表长度或类型不符"
        for i, (e, a) in enumerate(zip(expected, actual)):
            ok, why = subset(e, a)
            if not ok:
                return False, f"[{i}]: {why}"
        return True, ""
    if expected != actual:
        return False, f"期望 {expected!r}，实为 {actual!r}"
    return True, ""


def extract_whitelist() -> list[str]:
    """从 contract/docs/backup_v1.md §7 提取 14 键白名单。"""
    txt = (DOCS / "backup_v1.md").read_text(encoding="utf-8")
    m = re.search(r"##\s*7\.\s*个人设置白名单（14 键）(.*?)\n---", txt, re.S)
    if not m:
        return []
    return re.findall(r"^\|\s*\d+\s*\|\s*`([a-z0-9_]+)`", m.group(1), re.M)


def parse_contract_tables() -> dict[str, set[str]]:
    """解析 contract/schema/schema_v1.sql 的最终（v4）表结构。"""
    ddl = (SCHEMA / "schema_v1.sql").read_text(encoding="utf-8")
    ddl = re.sub(r"--.*", "", ddl)
    tables: dict[str, set[str]] = {}
    for name, body in re.findall(
        r"CREATE TABLE IF NOT EXISTS\s+(\w+)\s*\((.*?)\n\);", ddl, re.S
    ):
        cols: set[str] = set()
        for raw in body.split("\n"):
            line = raw.strip().rstrip(",")
            if not line or line.startswith(
                ("UNIQUE", "PRIMARY", "FOREIGN", "CHECK", "CONSTRAINT")
            ):
                continue
            cols.add(line.split()[0])
        tables[name] = cols
    # v4 迁移采用 ALTER TABLE ADD COLUMN，须一并纳入
    for t, col in re.findall(r"ALTER TABLE\s+(\w+)\s+ADD COLUMN\s+(\w+)", ddl):
        tables.setdefault(t, set()).add(col)
    return tables


# ------------------------------------------------------------------- 套件 ①
def suite_spider_io() -> None:
    print("\n【套件 ①】Spider ABI v1.0（spider_io_v1.json）")
    d = json.loads((FIX / "spider_io_v1.json").read_text(encoding="utf-8"))
    check("spider", "schemaVersion 为 1.0", d.get("schemaVersion") == "1.0")

    ops = ["homeContent", "searchContent", "categoryContent", "detailContent",
           "playerContent"]
    for op in ops:
        blk = d.get(op, {})
        req = blk.get("request", {})
        resp = blk.get("expectedResponse", {})
        ok = req.get("op") == op and resp.get("ok") is True and "data" in resp
        check("spider", f"{op} 请求/响应结构合法", ok,
              f"request.op={req.get('op')} ok={resp.get('ok')}")

    # 容错解码：参考实现输出须满足 fixture 期望
    tol = d.get("$comment_tolerance", {})
    for name, case in tol.items():
        if not isinstance(case, dict) or "input" not in case:
            continue
        norm = normalize_container(case["input"])
        ok, why = subset(case["expected"], norm)
        check("spider", f"容错[{name}] {case.get('rule', '')}", ok, why)

    # 错误规则
    errs = d.get("$comment_errors", {})
    codes = {v.get("expected", {}).get("error", {}).get("code")
             for v in errs.values() if isinstance(v, dict)}
    check("spider", "错误码含 E_REGISTER / E_SCRIPT_LOAD",
          {"E_REGISTER", "E_SCRIPT_LOAD"} <= codes, f"实为 {sorted(codes)}")
    abi = (DOCS / "abi_v1.md").read_text(encoding="utf-8")
    for pre in ["Error", "TypeError", "ReferenceError", "SyntaxError"]:
        check("spider", f"契约声明错误前缀 {pre}",
              re.search(rf"\b{pre}\b", abi) is not None)

    # 编码链
    enc = d.get("$comment_encoding", {}).get("cases", [])
    fam: dict[str, str] = {}
    for c in enc:
        fam[c["charset"].lower()] = c["expectedDecode"]
    check("spider", "gb2312/gb18030 归一为 GBK（同一家族）",
          fam.get("gb2312") == fam.get("gb18030") == fam.get("gbk") == "GBK")
    check("spider", "未知编码降级 base64",
          fam.get("unknown-xyz") == "base64", f"实为 {fam.get('unknown-xyz')}")
    check("spider", "big5 / latin1 映射齐备",
          fam.get("big5") == "Big5" and fam.get("iso-8859-1") == "ISO Latin1")

    # —— 扩五操作：data 字段形状（镜像 SpiderModels 各 Result）——
    op_fields = {
        "homeContent": {"class": list, "list": list},
        "searchContent": {"page": int, "pagecount": int, "list": list},
        "categoryContent": {"page": int, "pagecount": int, "limit": int,
                            "total": int, "list": list},
        "detailContent": {"list": list},
        "playerContent": {"parse": int, "url": (str, list), "urls": list,
                          "header": dict},
    }

    def _shape_ok(v: Any, want: Any) -> bool:
        if isinstance(want, tuple):
            return any(isinstance(v, w) for w in want)
        if want is list:
            return isinstance(v, list)
        if want is dict:
            return isinstance(v, dict)
        if want is int:
            return isinstance(v, int) and not isinstance(v, bool)
        if want is str:
            return isinstance(v, str)
        return False

    shape_ok = True
    for op, fields in op_fields.items():
        data = d.get(op, {}).get("expectedResponse", {}).get("data", {})
        missing = [f for f in fields if f not in data]
        bad = [f for f in fields if f in data and not _shape_ok(data[f], fields[f])]
        if missing or bad:
            shape_ok = False
            check("spider", f"{op} data 字段形状", False, f"缺 {missing} 类型错 {bad}")
    if shape_ok:
        check("spider", "五操作 data 字段形状齐备", True)

    # —— 站点模式（契约 §1.1）——
    site_modes = d.get("$comment_siteMode", {}).get("cases", [])
    sm_ok = True
    for i, case in enumerate(site_modes):
        site = case.get("site", {})
        want = case.get("mode")
        got = resolve_site_mode(site)
        if got != want:
            sm_ok = False
            check("spider", f"站点模式[{case.get('name', i)}]", False,
                  f"期望 {want} 实为 {got}")
    if sm_ok and site_modes:
        check("spider", f"站点模式判定一致（{len(site_modes)} 例）", True)


# ------------------------------------------------------------------- 套件 ②
def suite_sqlite() -> None:
    print("\n【套件 ②】SQLite v4 schema（sample_v4.sqlite3）")
    con = sqlite3.connect(f"file:{FIX / 'sample_v4.sqlite3'}?mode=ro", uri=True)
    tables = {
        r[0] for r in con.execute(
            "SELECT name FROM sqlite_master WHERE type='table'")
    }
    user = tables - {"sqlite_sequence"}
    expect = parse_contract_tables()
    check("sqlite", f"用户表数量与契约一致（{len(expect)} 表）",
          user == set(expect), f"fixture={sorted(user)}")

    col_ok = True
    for t, cols in expect.items():
        actual = {c[1] for c in con.execute(f"PRAGMA table_info({t})")}
        missing = cols - actual
        extra = actual - cols
        if missing or extra:
            col_ok = False
            check("sqlite", f"{t} 字段一致", False,
                  f"缺 {sorted(missing)} 多 {sorted(extra)}")
    if col_ok:
        check("sqlite", "全部表字段级一致", True)

    # v4 可空列：4 列须存在且可空（旧数据为 NULL，契约 §v4_add_download_columns）
    dl = {c[1]: c[3] for c in con.execute("PRAGMA table_info(download)")}
    v4cols = ["sourceType", "engineKey", "vodId", "headers"]
    bad = [c for c in v4cols if dl.get(c) != 0]
    check("sqlite", "download 的 4 个 v4 列存在且可空",
          all(c in dl for c in v4cols) and not bad,
          f"缺失或非空: {bad}")
    # 基线列须保持 NOT NULL（迁移不得放宽约束）
    relaxed = [c for c in ("name", "laiyuan", "addedAt") if dl.get(c) != 1]
    check("sqlite", "download 基线列仍为 NOT NULL",
          not relaxed, f"被放宽: {relaxed}")

    # UNIQUE(name, dyurl)：内联约束生成隐式索引（sql 为 NULL），
    # 必须用 PRAGMA index_list + index_info 判定，不能查 sqlite_master.sql
    uniq: set[tuple[str, ...]] = set()
    for row in con.execute("PRAGMA index_list(zhanyuan)"):
        idx_name, is_unique = row[1], row[2]
        if not is_unique:
            continue
        cols = tuple(r[2] for r in con.execute(f"PRAGMA index_info({idx_name})"))
        if cols == ("name", "dyurl"):
            uniq.add(cols)
    check("sqlite", "zhanyuan 唯一约束为 (name, dyurl)",
          ("name", "dyurl") in uniq, f"实为 {sorted(uniq)}")

    # 数据可读回
    total = 0
    for t in sorted(user):
        rows = con.execute(f'SELECT * FROM "{t}"').fetchall()
        cols = [c[1] for c in con.execute(f"PRAGMA table_info({t})")]
        for r in rows:
            json.dumps(dict(zip(cols, r)), ensure_ascii=False)
        total += len(rows)
    check("sqlite", f"全部行可读回并 JSON 化（{total} 行）", True)
    con.close()


# ------------------------------------------------------------------- 套件 ③
def suite_backup() -> None:
    print("\n【套件 ③】备份格式 v1.0（backup_v1.json）")
    d = json.loads((FIX / "backup_v1.json").read_text(encoding="utf-8"))
    check("backup", "schemaVersion 为 1.0", d.get("schemaVersion") == "1.0")

    cp = d.get("cryptoParams", {})
    kdf, cipher, tag = cp.get("kdf"), cp.get("cipher"), cp.get("gcmTagLength")
    check("backup", "加密参数 = PBKDF2-HMAC-SHA256 + AES-256-GCM",
          kdf == "PBKDF2-HMAC-SHA256" and cipher == "AES-256-GCM")
    check("backup", "迭代 100000 / salt16 / iv12 / key32",
          (cp.get("pbkdf2Iterations"), cp.get("saltLength"),
           cp.get("ivLength"), cp.get("keyLength")) == (100000, 16, 12, 32),
          f"实为 {cp.get('pbkdf2Iterations')}/{cp.get('saltLength')}/"
          f"{cp.get('ivLength')}/{cp.get('keyLength')}")
    check("backup", "GCM tag 16 字节且无 AAD",
          tag == 16 and cp.get("aad") is None)

    for key in ("unencryptedEnvelope", "encryptedEnvelope", "payload"):
        check("backup", f"fixture 含 {key}", key in d)

    enc = d.get("encryptedEnvelope", {})
    need = {"schemaVersion", "meta", "encrypted", "cipher", "kdf", "salt",
            "iv", "authTag", "payload"}
    check("backup", "加密信封字段齐备",
          need <= set(enc), f"缺 {need - set(enc)}")
    check("backup", "加密信封 encrypted=true", enc.get("encrypted") is True)

    # 白名单
    wl = extract_whitelist()
    check("backup", f"契约 §7 白名单解析出 14 键（实为 {len(wl)}）", len(wl) == 14)
    defaults = d.get("personalSettingsSnapshot", {}).get("defaults", {})
    check("backup", "defaults 键全部在白名单内", set(defaults) <= set(wl),
          f"越界 {sorted(set(defaults) - set(wl))}")
    check("backup", "未加密备份仅含前 11 键（不含福利 3 键）",
          len(defaults) == 11 and not (set(defaults) & set(wl[11:])))
    ps = d.get("personalSettingsSnapshot", {})
    check("backup", "个人设置快照仅 username/avatarBase64/defaults",
          set(ps) <= {"$comment", "username", "avatarBase64", "defaults"},
          f"实为 {sorted(ps)}")

    # 遗留字段容错
    legacy = d.get("remoteSourcesSnapshotLegacy", {})
    check("backup", "旧备份缺 lxPlugins 字段（须能解码为空字典）",
          "lxPlugins" not in legacy and "version" in legacy)

    # 真实加解密往返
    try:
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM
        salt = b"0123456789abcdef"[:cp["saltLength"]]
        iv = b"0123456789ab"[:cp["ivLength"]]
        key = hashlib.pbkdf2_hmac(
            "sha256", b"conformance-pass", salt,
            cp["pbkdf2Iterations"], dklen=cp["keyLength"])
        pt = json.dumps({"probe": "vbox"}, ensure_ascii=False).encode()
        blob = AESGCM(key).encrypt(iv, pt, None)
        ct, t = blob[:-16], blob[-16:]
        check("backup", "PBKDF2(100k) + AES-256-GCM 往返一致",
              AESGCM(key).decrypt(iv, ct + t, None) == pt and len(t) == 16)
        check("backup", "密文与 tag 分离（备份格式要求 tag 独立存放）",
              len(ct) == len(pt) and len(t) == cp["gcmTagLength"])
        wrong = hashlib.pbkdf2_hmac("sha256", b"wrong", salt,
                                    cp["pbkdf2Iterations"],
                                    dklen=cp["keyLength"])
        try:
            AESGCM(wrong).decrypt(iv, ct + t, None)
            check("backup", "错误口令必须解密失败", False, "竟然解密成功")
        except Exception:
            check("backup", "错误口令解密失败（GCM 校验生效）", True)
    except ImportError:
        check("backup", "cryptography 库可用", False, "未安装，跳过加解密实测")

    tcs = d.get("testCases", [])
    check("backup", f"声明测试用例（{len(tcs)} 条）均带 platforms",
          bool(tcs) and all("platforms" in c for c in tcs))
    check("backup", "风险清单已声明", bool(d.get("knownRisks")))


# ------------------------------------------------------------------- 套件 ④
def suite_manifest() -> None:
    print("\n【套件 ④】远程源 manifest v1.0（manifest_v1.json）")
    d = json.loads((FIX / "manifest_v1.json").read_text(encoding="utf-8"))
    check("manifest", "schemaVersion 为 1", d.get("schemaVersion") == 1)
    check("manifest", "configVersion 格式 = YYYY.MM.DD.N",
          d.get("configVersionPattern") == r"^\d{4}\.\d{2}\.\d{2}\.\d+$")
    check("manifest", "默认 TTL = 21600（6h）", d.get("defaultTtlSeconds") == 21600)
    check("manifest", "必需文件条目 = allSources",
          d.get("requiredFiles") == ["allSources"])
    known = d.get("knownFileKeys", [])
    check("manifest", f"已知文件键 10 个（实为 {len(known)}）", len(known) == 10)

    cases = d.get("cases", [])
    all_ok = True
    for case in cases:
        norm = normalize_manifest(case.get("input", {}))
        valid = bool(norm["hasAllSources"] and norm["hasValidConfigVersion"])
        name = case.get("name", "?")
        if valid != case.get("valid"):
            all_ok = False
            check("manifest", f"用例[{name}] 有效性", False,
                  f"期望 {case.get('valid')} 实为 {valid}")
            continue
        exp = case.get("expected", {})
        ok, why = subset(exp, norm)
        if not ok:
            all_ok = False
            check("manifest", f"用例[{name}] 字段", False, why)
        else:
            check("manifest", f"用例[{name}]", True)
    if all_ok:
        check("manifest", f"全部用例通过（{len(cases)} 例）", True)


# ------------------------------------------------------------------- 套件 ⑤
def suite_engine_abi() -> None:
    print("\n【套件 ⑤】双引擎 ABI 一致性（engine_abi_v1.json）")
    d = json.loads((FIX / "engine_abi_v1.json").read_text(encoding="utf-8"))
    check("engine", "schemaVersion 为 1.0", d.get("schemaVersion") == "1.0")

    et = (ROOT / "lib/domain/entities/spider/engine_type.dart").read_text()
    for e in d.get("engines", []):
        name, raw = e["type"], e["rawValue"]
        check("engine", f"引擎 {name} rawValue={raw}",
              re.search(rf"{name} => '{raw}'", et) is not None)

    qjs = (ROOT / "lib/platform/runtime/quickjs_ffi.dart").read_text()
    jsc = (ROOT / "lib/platform/runtime/jsc_ffi.dart").read_text()
    frag = {
        "isAvailable": "bool get isAvailable",
        "createRuntime": "int createRuntime()",
        "createContext": "int createContext(int runtime)",
        "freeContext": "void freeContext(int context)",
        "freeRuntime": "void freeRuntime(int runtime)",
        "eval": "String? eval(int context, String script)",
    }
    for m in d.get("bridgeMethods", []):
        present = frag.get(m, m) in qjs and frag.get(m, m) in jsc
        check("engine", f"bridge 方法 {m} 双端齐备", present)

    pre = d.get("cSymbols", {}).get("prefixes", {})
    for s in d.get("cSymbols", {}).get("suffixes", []):
        vq = f"'{pre.get('quickjs')}_{s}'"
        vj = f"'{pre.get('jsCore')}_{s}'"
        check("engine", f"C 符号 {vq} / {vj}", vq in qjs and vj in jsc)

    if d.get("cSymbols", {}).get("freeStringArgs") == 2:
        two_arg = "Void Function(Pointer<Void>, Pointer<Utf8>)"
        check("engine", "free_string 双端 2 参（ctx + str）",
              two_arg in qjs and two_arg in jsc)

    fac = (ROOT / "lib/platform/spider/spider_engine_factory.dart").read_text()
    for m in d.get("fallback", {}).get("markers", []):
        check("engine", f"降级可观测标记 {m!r}", m in fac)


def main() -> int:
    print("=" * 62)
    print("VBox 一致性测试运行器 (conformance runner)")
    print(f"fixtures: {FIX.relative_to(ROOT)}")
    print("=" * 62)
    suite_spider_io()
    suite_sqlite()
    suite_backup()
    suite_manifest()
    suite_engine_abi()

    passed = sum(1 for r in RESULTS if r["ok"])
    failed = [r for r in RESULTS if not r["ok"]]
    print("\n" + "=" * 62)
    print(f"合计 {len(RESULTS)} 项：通过 {passed} · 失败 {len(failed)}")
    if failed:
        for r in failed:
            print(f"  ❌ [{r['suite']}] {r['name']} —— {r['detail']}")
    print("=" * 62)

    out = ROOT / "conformance" / "runner" / "results.json"
    out.write_text(
        json.dumps({"total": len(RESULTS), "passed": passed,
                    "failed": len(failed), "results": RESULTS},
                   ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"结果已写入 {out.relative_to(ROOT)}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
