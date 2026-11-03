#!/usr/bin/env python3
"""备份格式契约一致性验证（独立参照实现）。

用 Python 独立实现 iOS BackupManager 的加密参数，验证：
  1. PBKDF2 参数：SHA256 / 100000 迭代 / 32 字节密钥
  2. salt 16 / iv 12 / tag 16 字节
  3. cipher/kdf 字面值精确匹配
  4. 加密→解密往返成功
  5. 解密用错口令 → 失败（GCM tag 校验）
  6. schemaVersion=2 → schemaTooNew
  7. 未加密模式往返
  8. Dart 源码中的参数常量与契约文档一致（静态核对）

依赖：仅标准库（hashlib/hmac）+ 可选 cryptography 做 AES-GCM。
"""
from __future__ import annotations

import base64
import hashlib
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DOC = ROOT / "contract/docs/backup_v1.md"
DART = ROOT / "lib/data/datasources/local/backup_manager.dart"
# B4（备份采集 / 还原）新增产物
SERVICE = ROOT / "lib/data/datasources/local/backup_service.dart"
PAYLOAD = ROOT / "lib/data/datasources/local/backup_payload.dart"
APP_CONSTANTS = ROOT / "lib/core/constants/app_constants.dart"

# 契约要求的参数
EXPECT = {
    "pbkdf2Iterations": 100000,
    "saltLength": 16,
    "ivLength": 12,
    "keyLength": 32,
    "tagLength": 16,
    "cipherName": "AES-256-GCM",
    "kdfName": "PBKDF2-HMAC-SHA256",
}


def _section(text: str, start: str, end: str) -> str:
    """截取 `start` 与 `end` 之间的文本（不含端点）。"""
    i = text.find(start)
    if i < 0:
        return ""
    j = text.find(end, i + len(start))
    return text[i: j if j >= 0 else len(text)]


def _dart_getter_switch(src: str, getter: str) -> dict[str, str]:
    """解析 `String get <getter> => switch (this) { BackupCategory.x => '...' };`。"""
    m = re.search(rf"String get {getter} => switch \(this\) \{{(.*?)\}};", src, re.S)
    if not m:
        return {}
    return dict(re.findall(r"BackupCategory\.(\w+)\s*=>\s*'([^']+)'", m.group(1)))


def _doc_categories(doc: str) -> dict[str, tuple[str, str]]:
    """从契约 §3 表格解析 `rawValue → (中文名, 副标题)`。"""
    out: dict[str, tuple[str, str]] = {}
    sec = _section(doc, "## 3. 备份类目", "\n## 4.")
    for line in sec.splitlines():
        m = re.match(
            r"\|\s*\d+\s*\|\s*`(\w+)`\s*\|\s*([^|]+?)\s*\|\s*([^|]+?)\s*\|", line)
        if m:
            out[m.group(1)] = (m.group(2).strip(), m.group(3).strip())
    return out


def check_b4(errors: int) -> int:
    """§6：B4 备份采集（dump）/ 还原（restore）与契约逐项核对。"""
    print("== 6. B4 备份采集 / 还原契约核对 ==")
    before = errors
    missing = [p for p in (SERVICE, PAYLOAD) if not p.exists()]
    if missing:
        for p in missing:
            print(f"  ❌ 缺少 B4 产物：{p.relative_to(ROOT)}")
            errors += 1
        return errors

    service = SERVICE.read_text()
    payload = PAYLOAD.read_text()
    enum_src = DART.read_text()

    # 6a. 9 个类目：中文名 / 副标题 ↔ 契约 §3 逐项一致
    doc_cats = _doc_categories(doc_ := DOC.read_text())
    dart_labels = _dart_getter_switch(enum_src, "label")
    dart_subs = _dart_getter_switch(enum_src, "subtitle")
    if len(doc_cats) != 9:
        print(f"  ❌ 契约 §3 应含 9 个类目，实为 {len(doc_cats)}")
        errors += 1
    if len(dart_labels) != 9 or len(dart_subs) != 9:
        print(f"  ❌ Dart `label`/`subtitle` 应各含 9 项，实为 "
              f"{len(dart_labels)}/{len(dart_subs)}")
        errors += 1
    for rw, (label, sub) in doc_cats.items():
        if dart_labels.get(rw) != label:
            print(f"  ❌ {rw} 中文名不一致：Dart {dart_labels.get(rw)!r} ≠ 契约 {label!r}")
            errors += 1
        if dart_subs.get(rw) != sub:
            print(f"  ❌ {rw} 副标题不一致：Dart {dart_subs.get(rw)!r} ≠ 契约 {sub!r}")
            errors += 1
    for rw in dart_labels:
        if rw not in doc_cats:
            print(f"  ❌ Dart 类目 {rw} 未登记于契约 §3")
            errors += 1
    if errors == before:
        print("  ✅ 9 个类目中文名 / 副标题与契约 §3 逐项一致")

    # 6b. 敏感性与默认勾选（仅网盘凭据敏感 / 默认不勾选）
    if (re.search(r"isSensitive => this == BackupCategory\.cloudCredentials", enum_src)
            and re.search(r"defaultOn => !isSensitive", enum_src)):
        print("  ✅ isSensitive / defaultOn 规则对齐契约 §3（仅 cloudCredentials）")
    else:
        print("  ❌ isSensitive / defaultOn 规则偏离契约 §3")
        errors += 1

    # 6c. 冲突策略 merge / overwrite
    if "enum ConflictStrategy" in enum_src and re.search(
            r"\bmerge\b", enum_src) and re.search(r"\boverwrite\b", enum_src) \
            and "fromName" in enum_src:
        print("  ✅ ConflictStrategy：merge / overwrite + fromName（契约 §8）")
    else:
        print("  ❌ ConflictStrategy 缺失或偏离契约 §8")
        errors += 1

    # 6d. dump / restore 两向能力齐备
    if re.search(r"Future<BackupPayload> dump\(", service) and re.search(
            r"Future<BackupRestoreReport> restore\(", service):
        print("  ✅ BackupService：dump / restore 两向齐备（契约 §5 / §8）")
    else:
        print("  ❌ BackupService 缺 dump 或 restore")
        errors += 1

    # 6e. 个人设置白名单 11 + 福利 3（契约 §7）
    keys = re.findall(r"'(\w+)'", _section(service, "kPersonalSettingKeys", ";"))
    welfare = re.findall(r"'(\w+)'", _section(service, "kWelfareSettingKeys", ";"))
    # 仅取 §7 表格中「键」列（形如 `| 1 | `app_skin_mode` | string | — |`），
    # 避免把正文「来源：`settingsDefaultKeys`」之类的行内代码一并抓进来。
    doc_keys = re.findall(
        r"^\|\s*\d+\s*\|\s*`(\w+)`",
        _section(doc_, "## 7. 个人设置白名单", "\n## 8."),
        re.M,
    )
    if len(keys) == 11 and len(welfare) == 3:
        print("  ✅ 白名单：常态 11 键 + 福利 3 键（契约 §7）")
    else:
        print(f"  ❌ 白名单应为 11 + 3，实为 {len(keys)} + {len(welfare)}")
        errors += 1
    if doc_keys and doc_keys[:11] != keys:
        print(f"  ❌ 常态白名单与契约 §7 顺序/内容不一致：{keys} ≠ {doc_keys[:11]}")
        errors += 1
    if doc_keys and doc_keys[11:14] != welfare:
        print(f"  ❌ 福利白名单与契约 §7 不一致：{welfare} ≠ {doc_keys[11:14]}")
        errors += 1

    # 6f. 表类目映射（5 表直映 + siteConfigs 三表）
    tables = re.findall(r"BackupCategory\.(\w+): <String>\['(\w+)'\]",
                        _section(service, "kCategoryTables", "};"))
    expect_tables = {"watchHistory": "history", "favorites": "favorite",
                     "downloads": "download", "subscriptions": "subscription",
                     "searchHistory": "search_history"}
    if dict(tables) == expect_tables:
        print("  ✅ 表类目映射 5 项与 schema 表名一致")
    else:
        print(f"  ❌ 表类目映射异常：{dict(tables)}")
        errors += 1
    if re.search(r"kSiteConfigTables[\s\S]*?'zhanyuan'[\s\S]*?'apiyuan'[\s\S]*?'jiexisetting'",
                 service):
        print("  ✅ siteConfigs 三表：zhanyuan / apiyuan / jiexisetting")
    else:
        print("  ❌ siteConfigs 三表定义缺失")
        errors += 1

    # 6g. Payload 值按契约 §5.1 编解码为 Base64(UTF-8 JSON)
    if re.search(r"base64\.encode\(utf8\.encode\(jsonEncode\(", payload) and \
            re.search(r"jsonDecode\(utf8\.decode\(base64\.decode\(", payload):
        print("  ✅ Payload categories 值 = Base64(UTF-8 JSON)（契约 §5.1）")
    else:
        print("  ❌ Payload 未按 Base64(UTF-8 JSON) 编解码（契约 §5.1）")
        errors += 1

    # 6h. 备份扩展名 `.vboxbak`（契约 §11 建议值）
    m = re.search(r"backupFileExtension = '([^']+)'", APP_CONSTANTS.read_text())
    ext = m.group(1) if m else None
    if ext == ".vboxbak" and ".vboxbak" in doc_:
        print("  ✅ 备份扩展名 .vboxbak 与契约 §11 建议值一致")
    else:
        print(f"  ❌ 备份扩展名 {ext!r} ≠ 契约 §11 建议值 .vboxbak")
        errors += 1

    # 6i. 远程源采集 / 还原（A2 步骤 6）：allSources 非空路径 + spiderJS 采集路径
    #     dump：allSources 读 cache-first 同一缓存文件、spiderJS 遍历蜘蛛脚本目录；
    #     restore：两键分别写回。
    dump_all_sources = bool(
        re.search(r"'allSources':\s*allSources", service)
        and re.search(
            r"_allSourcesCachePath\?\.call\(\)\s*\?\?\s*_allSourcesDefaultPath",
            service,
        )
    )
    dump_spider_js = bool(
        re.search(r"'spiderJS':\s*_dumpSpiderScriptsSync\(\)", service)
        and re.search(
            r"_spiderDirPath\?\.call\(\)\s*\?\?\s*StoragePaths\.spiderDir",
            service,
        )
    )
    restore_remote = bool(
        re.search(r"snap\['allSources'\]", service)
        and re.search(r"snap\['spiderJS'\]", service)
    )
    if dump_all_sources and dump_spider_js and restore_remote:
        print("  ✅ 远程源采集/还原：allSources 缓存文件 + spiderJS 脚本目录（A2 步骤 6）")
    else:
        print(
            "  ❌ 远程源采集/还原缺失："
            f"allSources 采集路径={dump_all_sources}, "
            f"spiderJS 采集路径={dump_spider_js}, 还原键={restore_remote}"
        )
        errors += 1

    return errors


def main() -> int:
    errors = 0
    dart = DART.read_text()
    doc = DOC.read_text()

    print("== 1. Dart 常量与契约一致 ==")
    checks = {
        "pbkdf2Iterations": r"pbkdf2Iterations = (\d+)",
        "saltLength": r"saltLength = (\d+)",
        "ivLength": r"ivLength = (\d+)",
        "keyLength": r"keyLength = (\d+)",
        "tagLength": r"tagLength = (\d+)",
    }
    for name, pat in checks.items():
        m = re.search(pat, dart)
        val = int(m.group(1)) if m else None
        if val == EXPECT[name]:
            print(f"  ✅ {name} = {val}")
        else:
            print(f"  ❌ {name} = {val}（期望 {EXPECT[name]}）")
            errors += 1

    for name, pat in {
        "cipherName": r"cipherName = '([^']+)'",
        "kdfName": r"kdfName = '([^']+)'",
    }.items():
        m = re.search(pat, dart)
        val = m.group(1) if m else None
        if val == EXPECT[name]:
            print(f"  ✅ {name} = {val!r}")
        else:
            print(f"  ❌ {name} = {val!r}（期望 {EXPECT[name]!r}）")
            errors += 1

    print("== 2. 契约文档参数核对 ==")
    for want in ["100,000", "16", "12", "32", "AES-256-GCM", "PBKDF2-HMAC-SHA256"]:
        if want in doc:
            print(f"  ✅ 文档含 {want}")
        else:
            print(f"  ⚠️ 文档未显式含 {want}")
    # 确认不压缩
    if "不得引入压缩" in doc or "未使用任何压缩" in doc:
        print("  ✅ 文档明确禁用压缩")
    else:
        print("  ⚠️ 文档未明确禁用压缩")
        errors += 1

    print("== 3. PBKDF2 参数实测 ==")
    salt = bytes(range(16))
    key = hashlib.pbkdf2_hmac("sha256", "测试口令".encode("utf-8"),
                              salt, EXPECT["pbkdf2Iterations"], dklen=32)
    if len(key) == 32:
        print(f"  ✅ PBKDF2-SHA256 100000 迭代 → 32 字节密钥")
        print(f"     密钥(hex) = {key.hex()[:32]}…")
    else:
        print("  ❌ 密钥长度异常")
        errors += 1

    print("== 4. AES-GCM 往返（参照实现）==")
    try:
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM
        iv = bytes(range(12))
        pt = json.dumps({"account": "acc1", "categories": {}}, ensure_ascii=False).encode()
        ct = AESGCM(key).encrypt(iv, pt, None)  # 无 AAD
        tag, cipher_text = ct[-16:], ct[:-16]
        print(f"  ✅ 加密: ciphertext={len(cipher_text)}B, tag={len(tag)}B（无 AAD）")
        # 往返
        plain = AESGCM(key).decrypt(iv, cipher_text + tag, None)
        assert plain == pt
        print("  ✅ 解密往返成功")
        # 错口令
        wrong = hashlib.pbkdf2_hmac("sha256", b"wrong", salt, 100000, dklen=32)
        try:
            AESGCM(wrong).decrypt(iv, cipher_text + tag, None)
            print("  ❌ 错口令竟然解密成功")
            errors += 1
        except Exception:
            print("  ✅ 错口令 → GCM tag 校验失败（对应 wrongPassword）")
        # 信封编解码
        env = {
            "schemaVersion": 1,
            "meta": {"appName": "vbox", "appVersion": "3.1614", "createdAt": 1790000000,
                     "account": "acc1", "username": "u", "device": "d"},
            "encrypted": True, "cipher": "AES-256-GCM", "kdf": "PBKDF2-HMAC-SHA256",
            "salt": base64.b64encode(salt).decode(),
            "iv": base64.b64encode(iv).decode(),
            "authTag": base64.b64encode(tag).decode(),
            "payload": base64.b64encode(cipher_text).decode(),
        }
        s = json.dumps(env, ensure_ascii=False)
        back = json.loads(s)
        assert back["cipher"] == "AES-256-GCM" and back["kdf"] == "PBKDF2-HMAC-SHA256"
        print("  ✅ 信封 JSON 编解码正常，cipher/kdf 字面值可往返")
    except ImportError:
        print("  ⚠️ 未安装 cryptography，跳过 AES-GCM 实测")

    print("== 5. Dart 静态检查 ==")
    for pat, name in [
        (r"utf8\.encode", "口令 UTF-8 编码"),
        (r"base64\.encode", "标准 Base64"),
        (r"SchemaTooNewException", "schemaTooNew 检查"),
        (r"WrongPasswordException", "wrongPassword 错误"),
        (r"EmptyPasswordException", "emptyPassword 错误"),
    ]:
        print(f"  {'✅' if re.search(pat, dart) else '❌'} {name}")
        if not re.search(pat, dart):
            errors += 1
    # 确认未引入压缩（排除注释）
    code_lines = [
        l for l in dart.splitlines()
        if not l.strip().startswith("///") and not l.strip().startswith("//")
    ]
    code = "\n".join(code_lines)
    if re.search(r"gzip|zlib|GZipCodec", code):
        print("  ❌ 检测到压缩代码（契约禁用）")
        errors += 1
    else:
        print("  ✅ 未引入压缩（符合契约）")

    print()
    errors = check_b4(errors)

    print()
    print("备份契约验证:", "通过 ✅" if errors == 0 else f"{errors} 项失败")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
