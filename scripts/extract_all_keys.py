#!/usr/bin/env python3
"""从 iOS 源码精确提取 prefs 键 + 类型 + 默认值（含变量间接引用追踪）。

策略：
  1. 先收集所有 `let/var xKey = "k"` 与 `static let y = "k"` 的常量映射（文件内）
  2. 再扫描 `defaults.xxx(forKey: VAR)` / `object(forKey: VAR) as? T`，
     把 VAR 解析回键名，得到类型
  3. forKey:"literal" 直接取其类型
"""
from __future__ import annotations

import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "contract/schema/_extracted_keys.json"

NOISE_EXACT = {
    "apiyuan", "download", "favorite", "history", "settings",
    "subscription", "zhanyuan", "search_history", "jiexisetting",
    "bufferedPosition", "currentPosition", "duration", "checked", "pause",
    "width", "height", "timeout", "networkTimeout", "maxBufferDuration",
    "highBufferDuration", "startBufferDuration", "maxDelayTime",
    "positionTimerIntervalMs", "reconnect", "danmaku_scroll",
    "headers", "httpHeaders", "playerUrl", "referer", "orientation",
    "inputCorrectionLevel", "inputMessage", "MPV", "NetworkLoggerHandled",
    "builtin_",
}

ACCESSOR = {
    "bool": "bool", "integer": "int", "double": "float", "float": "float",
    "string": "string", "stringArray": "stringArray", "url": "string",
    "data": "string",
}
AS_TYPE = {"Bool": "bool", "Int": "int", "Double": "float",
           "Float": "float", "String": "string"}


def main() -> int:
    files = [p for p in (ROOT / "vbox").rglob("*.swift")
             if ".framework" not in str(p) and ".xcframework" not in str(p)]

    found: dict[str, dict] = {}

    def reg(k, typ, default, ev):
        if k in NOISE_EXACT or re.fullmatch(r"[0-9a-f]{32}", k):
            return
        if not re.match(r"^[a-z]", k):
            return
        e = found.setdefault(k, {"type": None, "default": None, "evidence": []})
        if typ and not e["type"]:
            e["type"] = typ
        if default is not None and e["default"] is None:
            e["default"] = default
        if len(e["evidence"]) < 2:
            e["evidence"].append(ev)

    # 全局常量映射（跨文件用，如 enum XXXKeys）
    const_map: dict[str, str] = {}

    for p in files:
        txt = p.read_text(errors="ignore")
        # 收集本文件常量
        local: dict[str, str] = {}
        for m in re.finditer(
                r'(?:static\s+)?(?:let|var)\s+(\w*[Kk]ey\w*|\w+Key)\s*=\s*'
                r'"([a-zA-Z_][\w]*)"', txt):
            local[m.group(1)] = m.group(2)
            const_map[m.group(1)] = m.group(2)
        # 也收 static let 常量（如 enabledKey = "app_log_enabled"）
        for m in re.finditer(r'static\s+let\s+(\w+)\s*=\s*"([a-zA-Z_][\w]*)"', txt):
            if re.match(r"^[a-z]", m.group(2)):
                local[m.group(1)] = m.group(2)
                const_map[m.group(1)] = m.group(2)

    # 第二轮：解析访问器（含变量）
    for p in files:
        txt = p.read_text(errors="ignore")
        local = {}
        for m in re.finditer(r'(?:static\s+)?(?:let|var)\s+(\w+)\s*=\s*'
                             r'"([a-zA-Z_][\w]*)"', txt):
            local[m.group(1)] = m.group(2)

        def resolve(ref: str) -> str | None:
            ref = ref.strip()
            if ref.startswith('"') and ref.endswith('"'):
                return ref[1:-1]
            return local.get(ref) or const_map.get(ref)

        # 字面量访问器
        for m in re.finditer(r'\.(\w+)\(forKey:\s*"([a-zA-Z_][\w]*)"', txt):
            typ = ACCESSOR.get(m.group(1))
            if typ:
                ln = txt[:m.start()].count("\n") + 1
                reg(m.group(2), typ, None, f"{p.name}:{ln}")

        # 变量访问器：.bool(forKey: VAR)
        for m in re.finditer(r'\.(\w+)\(forKey:\s*([A-Za-z_]\w*)\)', txt):
            k = resolve(m.group(2))
            typ = ACCESSOR.get(m.group(1))
            if k and typ:
                ln = txt[:m.start()].count("\n") + 1
                reg(k, typ, None, f"{p.name}:{ln}")

        # object(...) as? T ?? D （字面量 + 变量）
        for m in re.finditer(
                r'\.object\(forKey:\s*(?:"([a-zA-Z_][\w]*)"|([A-Za-z_]\w*))\)'
                r'\s*as\?\s*(\w+)(?:\s*\?\?\s*([^)\n]+))?', txt):
            k = m.group(1) or resolve(m.group(2) or "")
            typ = AS_TYPE.get(m.group(3))
            dv = m.group(4).strip() if m.group(4) else None
            if k:
                ln = txt[:m.start()].count("\n") + 1
                reg(k, typ, dv, f"{p.name}:{ln}")

        # 键常量登记（无类型）
        for name, k in local.items():
            ln = txt.find(f'"{k}"')
            ln = txt[:ln].count("\n") + 1 if ln >= 0 else 0
            reg(k, None, None, f"{p.name}:{ln}")

    out = {}
    for k, v in sorted(found.items()):
        out[k] = {"type": v["type"] or "unknown", "default": v["default"],
                  "evidence": v["evidence"]}
    OUT.write_text(json.dumps(out, ensure_ascii=False, indent=2))

    typed = [k for k, v in out.items() if v["type"] != "unknown"]
    print(f"提取 {len(out)} 键 | 类型已知 {len(typed)} | 未知 {len(out)-len(typed)}")
    print(f"输出: {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
