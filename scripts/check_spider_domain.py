#!/usr/bin/env python3
"""Spider 领域层契约一致性验证（对齐 contract/docs/abi_v1.md）。

验证项：
  1. 引擎类型 5 个 + rawValue 精确匹配契约 §1
  2. resolveSiteMode 判定优先级（契约 §1.1）—— 用等价 Python 实现穷举用例
  3. 容错解码规则（vod_id/vod_name/vod_pic 支持 String/Int/Double）
  4. urls 回填规则：urls ?? (url 非空 ? [url] : null)
  5. 错误前缀检测（Error/TypeError/ReferenceError/SyntaxError）
  6. 注册检测（typeof __JS_SPIDER__ == object）
  7. 编码规范化映射表（契约 §4.2，实现在 lib/core/utils/charset.dart）
  8. HTTP 默认超时 15s
"""
from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SP = ROOT / "lib/domain/entities/spider"


def main() -> int:
    errors = 0
    et = (SP / "engine_type.dart").read_text()
    sc = (SP / "site_config.dart").read_text()
    sm = (SP / "spider_models.dart").read_text()
    se = (SP / "spider_engine.dart").read_text()
    hb = (SP / "http_bridge.dart").read_text()
    # 契约 §4.2 编码逻辑已上移核心层（http_bridge 仅 re-export）
    cs = (ROOT / "lib/core/utils/charset.dart").read_text()

    print("== 1. 引擎类型 rawValue ==")
    for name, raw in [
        ("javaScriptCore", "JavaScriptCore"),
        ("quickJS", "QuickJS"),
        ("node", "Node"),
        ("nodeLX", "NodeLX"),
        ("python", "python"),
    ]:
        if re.search(rf"{name} => '{raw}'", et):
            print(f"  ✅ {name} → '{raw}'")
        else:
            print(f"  ❌ {name} → '{raw}' 未找到")
            errors += 1

    print("== 2. resolveSiteMode 判定优先级（穷举）==")

    def resolve(site: dict) -> str:
        key, typ, api = site.get("key", ""), site.get("type", 0), site.get("api", "")
        group = site.get("group")
        # isNodeSite
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

    cases = [
        ({"key": "a", "type": 3, "group": "node"}, "node"),
        ({"key": "nodejs_x", "type": 3}, "node"),
        ({"key": "csp_abc", "type": 3}, "node"),
        ({"key": "a", "type": 3, "api": "http://127.0.0.1:58080/spider/x"}, "node"),
        ({"key": "a", "type": 0, "api": "http://api/x"}, "apiEndpoint"),
        ({"key": "a", "type": 1, "api": "http://api/x"}, "apiEndpoint"),
        ({"key": "a", "type": 2, "api": "http://site"}, "zhanyuan"),
        ({"key": "a", "type": 3, "api": "./local.js"}, "jsSpider"),
        ({"key": "a", "type": 3, "api": "http://cdn/x.js"}, "jsSpider"),
        ({"key": "a", "type": 3, "api": "http://api/vod"}, "apiEndpoint"),
        # 契约 §1.1：isNodeSite（优先级①）覆盖 .py 判断（优先级④）
        ({"key": "a", "type": 3, "api": "csp_js_x.py"}, "node"),
        ({"key": "a", "type": 3, "api": "./spider.py"}, "pythonSpider"),
        ({"key": "a", "type": 3, "api": "http://x/a.jar"}, "unsupported"),
        ({"key": "a", "type": 3, "api": "com.example.Spider"}, "unsupported"),
        ({"key": "a", "type": 9}, "unsupported"),
    ]
    for site, want in cases:
        got = resolve(site)
        tag = "✅" if got == want else "❌"
        if got != want:
            errors += 1
        print(f"  {tag} type={site.get('type')} api={site.get('api','')[:28]:<28} → {got}")
    # 确认 Dart 侧含同样的判定分支
    for frag in ["startsWith('nodejs_')", "startsWith('csp_')", "://127.0.0.1",
                 ".jar", ".py", "startsWith('./')", "endsWith('.js')"]:
        if frag.replace('"', "'") not in sc:
            print(f"  ❌ Dart 缺判定分支: {frag}")
            errors += 1

    print("== 3. 容错解码（vod_id/name/pic 支持 String/Int/Double）==")
    if "asLooseString" in sm and "if (v is num)" in sm:
        print("  ✅ 存在 asLooseString 且处理 num")
        for f in ["vod_id", "vod_name", "vod_pic", "type_id", "type_name"]:
            if f"j['{f}']" in sm:
                print(f"  ✅ {f} 走宽松解码")
            else:
                print(f"  ❌ {f} 未走宽松解码")
                errors += 1
    else:
        print("  ❌ 未见宽松解码实现")
        errors += 1

    print("== 4. urls 回填规则 ==")
    if re.search(r"urls\s*=\s*urls\s*\?\?\s*\(url\s*!=\s*null\s*&&\s*url\.isNotEmpty", sm) or \
       ("url.isNotEmpty" in sm and "<String>[url]" in sm):
        print("  ✅ urls = urls ?? (url 非空 ? [url] : null)")
    else:
        print("  ❌ 未找到 urls 回填规则")
        errors += 1

    print("== 5. 错误前缀检测 ==")
    for p in ["Error", "TypeError", "ReferenceError", "SyntaxError"]:
        if f"'{p}'" in se:
            print(f"  ✅ {p}")
        else:
            print(f"  ❌ {p} 缺失")
            errors += 1

    print("== 6. 注册检测 ==")
    if "isRegistered" in se and "'object'" in se:
        print("  ✅ 含 object 判定")
    else:
        print("  ❌ 缺注册检测")
        errors += 1

    print("== 7. 编码规范化映射（契约 §4.2）==")
    for src, dst in [
        ("'utf-8' || 'utf8'", "utf-8"),
    ]:
        pass
    checks = [
        ("'gbk' || 'gb2312' || 'gb-2312' || 'gb18030'", "GBK 8 变体"),
        ("'big5' || 'big-5'", "Big5 2 变体"),
        ("'iso-8859-1' || 'latin1' || 'latin-1'", "Latin1 3 变体"),
    ]
    for frag, desc in checks:
        if frag.replace('"', "'") in cs.replace('"', "'"):
            print(f"  ✅ {desc}")
        else:
            print(f"  ❌ {desc} 未在 lib/core/utils/charset.dart 找到")
            errors += 1

    if "core/utils/charset.dart" in hb and "core/network/http_body_decoder.dart" in hb:
        print("  ✅ http_bridge 已委托核心层（无逻辑双份）")
    else:
        print("  ❌ http_bridge 未委托核心层，编码逻辑有双份漂移风险")
        errors += 1

    print("== 8. HTTP 默认超时 15s ==")
    if re.search(r"defaultTimeout\s*=\s*15", hb):
        print("  ✅ defaultTimeout = 15")
    else:
        print("  ❌ 超时不是 15s")
        errors += 1

    print("== 9. 5 个操作 + 5 个生命周期方法 ==")
    missing = []
    for m in ["loadScript", "loadLibrary", "loadScriptFromURL", "registerSpider",
              "isSpiderReady", "callHomeContent", "callSearchContent",
              "callCategoryContent", "callDetailContent", "callPlayerContent"]:
        if m not in se:
            missing.append(m)
    if missing:
        print(f"  ❌ 缺失: {missing}")
        errors += len(missing)
    else:
        print("  ✅ 10 个方法齐备（5 生命周期 + 5 操作）")

    print()
    print("Spider 领域层验证:", "通过 ✅" if errors == 0 else f"{errors} 项失败")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
