#!/usr/bin/env python3
"""校验 prefs_manager.dart 与契约的一致性。

1. 文件内所有键名字面量必须在 prefs_keys_v1.json 内
2. jsonListKeys 集合必须是契约键的子集
3. 安全存储分派必须覆盖「敏感键 ∪ storage=keychain ∪ storage=credential_extra」且经统一 helper（静态检查）
"""
from __future__ import annotations

import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent


def main() -> int:
    c = json.loads((ROOT / "contract/schema/prefs_keys_v1.json").read_text())
    contract_keys: set[str] = set()
    for items in c["keys"].values():
        contract_keys |= set(items.keys())
    sensitive = set(c["sensitiveKeys"])

    pm = (ROOT / "lib/data/datasources/local/prefs_manager.dart").read_text()
    errors = 0

    print("== 1. 键名字面量必须在契约内 ==")
    literals = set(re.findall(r"'([a-z_][a-zA-Z0-9_]{3,})'", pm))
    refs = {k for k in literals if "_" in k}
    unknown = refs - contract_keys
    if unknown:
        print(f"  ❌ 契约外键: {sorted(unknown)}")
        errors += 1
    else:
        print(f"  ✅ {len(refs & contract_keys)} 个键引用全部在契约内")

    print("== 2. jsonListKeys 必须是契约子集 ==")
    m = re.search(r"jsonListKeys = <String>\{(.*?)\}", pm, re.S)
    jlk = set(re.findall(r"'(\w+)'", m.group(1))) if m else set()
    bad = jlk - contract_keys
    if bad:
        print(f"  ❌ 契约外: {sorted(bad)}")
        errors += 1
    else:
        print(f"  ✅ {len(jlk)} 个 JSON 列表键均在契约内")

    print("== 3. 安全存储分派（敏感键 ∪ storage=keychain ∪ credential_extra）==")
    has_helper = "_isSecure" in pm
    covers_sensitive = "meta.sensitive" in pm
    covers_keychain = "PrefsStorage.keychain" in pm
    covers_cred_extra = "PrefsStorage.credentialExtra" in pm
    # v6.13：安全后端已抽象为核心层 SecureStore（实现见数据层适配器）；
    # prefs_manager 必须经该抽象读写，且**不得**直接依赖 flutter_secure_storage 插件。
    # v6.27：B2 裁定新增 credential_extra（PG 凭据 extra 字段）纳入安全分派。
    uses_secure_abstraction = (
        "SecureStore" in pm
        and "package:flutter_secure_storage" not in pm
    )
    if (has_helper and covers_sensitive and covers_keychain
            and covers_cred_extra and uses_secure_abstraction):
        print("  ✅ 存在 _isSecure 分派：敏感键 ∪ keychain ∪ credential_extra，经核心层 SecureStore 抽象")
    else:
        print(f"  ❌ 分派不完整 helper={has_helper} "
              f"sensitive={covers_sensitive} keychain={covers_keychain} "
              f"cred_extra={covers_cred_extra} "
              f"abstract={uses_secure_abstraction}")
        errors += 1

    print("== 4. 契约键总数核对 ==")
    print(f"  ✅ 契约 {len(contract_keys)} 键，敏感 {len(sensitive)} 个")

    print()
    print("prefs_manager 校验:", "通过 ✅" if errors == 0 else f"{errors} 项失败")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
