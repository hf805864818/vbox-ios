#!/usr/bin/env python3
"""福利专区三重隔离守卫（对齐 contract/schema/welfare_v1.json $comment_isolation）。

背景
----
福利内容与普通内容必须严格隔离（welfare-js/README.md 发布要求）：
  1. 福利 Spider 脚本只允许放在 sources/welfare-js/
  2. 福利平台只允许配置在 welfare_platforms.json
  3. 不得加入 spider_sources.json
  4. visibleInNormalSpider / visibleInGlobalSearch / visibleInHome 必须为 false
     （不进普通 Spider / 全局搜索 / 首页）
  5. 福利平台只使用 domain_overrides.json 做域名覆盖

本守卫把上述约束转为 CI 可自动检测项（H-04）：
  · 领域层：welfare_isolation.dart 策略实现一致性（脚本路径 / 三重隔离判定）
  · 契约层：welfare_v1.json 的 allOf 强制约束存在
  · 模型层：welfare_platform_config.dart 解析 api 与三个可见性字段
  · 表现层：welfare_platform_router.dart 已接入隔离校验
  · 源仓层：sources 模板目录——福利脚本目录 / 普通源文件不得混入福利平台
    （spider_sources / api_sources / cloud_sources 的 sites 不得命中福利平台键）
  · 代码层：普通 Spider 链路（lib/platform/spider、lib/domain/spider）不得引用
    sources/welfare-js/ 路径
  · 负向自测：--selftest 用等价 Python 判定穷举正负用例

退出码：0 通过 / 1 存在越界。
"""
from __future__ import annotations

import argparse
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CONTRACT = ROOT / "contract" / "schema" / "welfare_v1.json"
ISOLATION_DART = ROOT / "lib" / "domain" / "entities" / "welfare" / "welfare_isolation.dart"
CONFIG_DART = ROOT / "lib" / "domain" / "entities" / "welfare" / "welfare_platform_config.dart"
ROUTER_DART = ROOT / "lib" / "presentation" / "welfare" / "welfare_platform_router.dart"

SOURCES_CANDIDATES = (
    ROOT / "sources",
    ROOT / "remote-source-repo-template" / "sources",
)

# 普通 Spider 链路目录（不得引用福利脚本路径）
SPIDER_DIRS = (
    ROOT / "lib" / "platform" / "spider",
    ROOT / "lib" / "domain" / "spider",
)
WELFARE_MARK = "sources/welfare-js/"

# 普通源清单文件（福利平台不得出现在这些文件的 sites 中）
SOURCE_LISTS = ("spider_sources.json", "api_sources.json", "cloud_sources.json")


# ---------- 等价 Python 判定（与 welfare_isolation.dart 逻辑一致） ----------

def normalize_script_path(path: str) -> str:
    return path.replace("\\", "/").replace("./", "")


def is_allowed_script_path(api) -> bool:
    if not api or not str(api).strip():
        return False
    normalized = normalize_script_path(str(api).strip())
    return "sources/welfare-js/" in normalized or normalized.startswith("welfare-js/")


def is_welfare_spider(platform: dict) -> bool:
    return str(platform.get("serviceType", "")).strip() == "welfare_spider"


def satisfies_triple_isolation(platform: dict) -> bool:
    if not is_welfare_spider(platform):
        return True  # 契约约束只作用于 welfare_spider
    return not (
        bool(platform.get("visibleInNormalSpider", False))
        or bool(platform.get("visibleInGlobalSearch", False))
        or bool(platform.get("visibleInHome", False))
    )


def violation_for(platform: dict) -> str | None:
    if not is_welfare_spider(platform):
        return None
    fields = [k for k in (
        "visibleInNormalSpider", "visibleInGlobalSearch", "visibleInHome")
        if bool(platform.get(k, False))]
    if fields:
        return f"三重隔离违规: {fields}"
    api = platform.get("api")
    if api and not is_allowed_script_path(api):
        return f"脚本路径越界: {api}"
    return None


# ---------- 自测 ----------

def self_test() -> int:
    errors = 0

    def check(name: str, got, want) -> None:
        nonlocal errors
        ok = got == want
        print(f"  {'✅' if ok else '❌'} {name} → {got}")
        if not ok:
            errors += 1

    print("== 自测 1: 脚本路径判定（对齐 iOS isAllowedWelfareScriptPath）==")
    for api, want in [
        ("./sources/welfare-js/missav.py", True),
        ("sources/welfare-js/a.js", True),
        ("welfare-js/b.py", True),
        ("./sources/welfare-js/sub/c.py", True),
        ("./sources/other/x.py", False),
        ("sources/spider_sources.json", False),
        ("http://cdn/x.js", False),
        ("", False),
        (None, False),
        ("./welfare-js/../sources/x.py", True),  # 剥离 ./ 后仍含 welfare-js/
    ]:
        check(f"api={api!r}", is_allowed_script_path(api), want)

    print("== 自测 2: 三重隔离判定 ==")
    for p, want in [
        ({"serviceType": "welfare_spider"}, True),
        ({"serviceType": "welfare_spider", "visibleInNormalSpider": False,
          "visibleInGlobalSearch": False, "visibleInHome": False}, True),
        ({"serviceType": "welfare_spider", "visibleInNormalSpider": True}, False),
        ({"serviceType": "welfare_spider", "visibleInGlobalSearch": True}, False),
        ({"serviceType": "welfare_spider", "visibleInHome": True}, False),
        ({"serviceType": "ybox_special", "visibleInHome": True}, True),  # 非 Spider 不校验
        ({"serviceType": "python_spider", "visibleInNormalSpider": True}, True),
    ]:
        check(f"platform={p.get('serviceType')}", satisfies_triple_isolation(p), want)

    print("== 自测 3: violation_for 组合 ==")
    check("合规福利 Spider", violation_for(
        {"serviceType": "welfare_spider", "api": "./sources/welfare-js/a.py"}), None)
    check("三重隔离违规", violation_for(
        {"serviceType": "welfare_spider", "visibleInNormalSpider": True}), "三重隔离违规: ['visibleInNormalSpider']")
    check("脚本路径越界", violation_for(
        {"serviceType": "welfare_spider", "api": "./sources/other/a.py"}),
        "脚本路径越界: ./sources/other/a.py")
    check("非 Spider 不校验", violation_for(
        {"serviceType": "kanliao", "visibleInHome": True}), None)

    return errors


# ---------- 主流程 ----------

def main() -> int:
    parser = argparse.ArgumentParser(description="福利三重隔离守卫")
    parser.add_argument("--selftest", action="store_true", help="仅跑负向自测")
    args = parser.parse_args()

    if args.selftest:
        errs = self_test()
        print()
        print("隔离判定自测:", "通过 ✅" if errs == 0 else f"{errs} 项失败")
        return 1 if errs else 0

    errors = 0

    def fail(msg: str) -> None:
        nonlocal errors
        print(f"  ❌ {msg}")
        errors += 1

    def ok(msg: str) -> None:
        print(f"  ✅ {msg}")

    # 1. 契约层：allOf 强制约束
    print("== 1. 契约 allOf 三重隔离约束（welfare_v1.json）==")
    contract = json.loads(CONTRACT.read_text(encoding="utf-8"))
    platform_def = contract["$defs"]["platform"]
    allof = json.dumps(platform_def.get("allOf", []), ensure_ascii=False)
    if "visibleInNormalSpider" in allof and '"const": false' in allof \
            and "welfare_spider" in allof:
        ok("allOf 含 welfare_spider → 三字段 const false")
    else:
        fail("契约 allOf 缺少三重隔离强制约束")
    for key in ("visibleInNormalSpider", "visibleInGlobalSearch", "visibleInHome"):
        if key in json.dumps(platform_def.get("properties", {}), ensure_ascii=False):
            ok(f"properties 含 {key}")
        else:
            fail(f"properties 缺 {key}")

    # 2. 领域层：isolation.dart 实现一致性
    print("== 2. 领域层 isolation.dart ==")
    if ISOLATION_DART.is_file():
        iso = ISOLATION_DART.read_text(encoding="utf-8")
        for frag in [
            "kWelfareScriptDir", "sources/welfare-js/",
            "kWelfareScriptPrefix", "welfare-js/",
            "kWelfareSpiderServiceType", "welfare_spider",
            "replaceAll('\\\\', '/')", "replaceAll('./', '')",
            "normalized.contains", "normalized.startsWith",
            "visibleInNormalSpider", "visibleInGlobalSearch", "visibleInHome",
            "violationFor",
        ]:
            if frag in iso:
                ok(f"含 {frag}")
            else:
                fail(f"缺 {frag}")
    else:
        fail("welfare_isolation.dart 不存在")

    # 3. 模型层：三可见字段 + api 解析
    print("== 3. 模型层 welfare_platform_config.dart ==")
    cfg = CONFIG_DART.read_text(encoding="utf-8")
    for frag in [
        "this.api", "this.visibleInNormalSpider = false",
        "this.visibleInGlobalSearch = false", "this.visibleInHome = false",
        "j['visibleInNormalSpider']", "j['visibleInGlobalSearch']",
        "j['visibleInHome']", "j['api']",
        "'visibleInNormalSpider': visibleInNormalSpider",
    ]:
        if frag in cfg:
            ok(f"含 {frag}")
        else:
            fail(f"缺 {frag}")

    # 4. 表现层：路由接入隔离校验
    print("== 4. 路由接入 ==")
    if ROUTER_DART.is_file() and "WelfareIsolationPolicy.violationFor" in \
            ROUTER_DART.read_text(encoding="utf-8"):
        ok("welfareSpider 分支已接 violationFor")
    else:
        fail("路由未接入隔离校验")

    # 5. 源仓层：sources 目录
    print("== 5. 源仓目录检查 ==")
    sources_root = next((p for p in SOURCES_CANDIDATES if p.is_dir()), None)
    if sources_root is None:
        ok("仓库内无 sources 目录（发布时生成，跳过源仓检查）")
    else:
        welfare_dir = sources_root / "welfare-js"
        if welfare_dir.is_dir():
            bad_ext = [f.name for f in welfare_dir.iterdir()
                       if f.suffix not in (".py", ".js")]
            if bad_ext:
                fail(f"welfare-js/ 含非脚本扩展名: {bad_ext}")
            else:
                ok(f"welfare-js/ 存在且仅 .py/.js（{len(list(welfare_dir.iterdir()))} 项）")
        else:
            ok("welfare-js/ 未创建（待 H-03 发布时生成，合规）")

        # welfare_platforms.json 若存在 → 逐项隔离校验
        wp = sources_root / "welfare_platforms.json"
        if wp.is_file():
            data = json.loads(wp.read_text(encoding="utf-8"))
            platforms = data.get("platforms", [])
            viol = [p for p in platforms if violation_for(p) is not None]
            if viol:
                fail(f"welfare_platforms.json 含 {len(viol)} 个违规平台: "
                     f"{[p.get('platformKey') for p in viol]}")
            else:
                ok(f"welfare_platforms.json {len(platforms)} 平台全部合规")
        else:
            ok("welfare_platforms.json 未生成（发布时生成，跳过）")

        # 普通源清单不得混入福利平台键
        welfare_keys = set()
        if wp.is_file():
            welfare_keys = {str(p.get("platformKey", ""))
                            for p in json.loads(wp.read_text(encoding="utf-8"))
                            .get("platforms", [])}
        for name in SOURCE_LISTS:
            sf = sources_root / name
            if not sf.is_file():
                continue
            data = json.loads(sf.read_text(encoding="utf-8"))
            sites = data.get("sites", [])
            leaked = []
            for s in sites:
                key = str(s.get("key", ""))
                if key in welfare_keys or key.startswith("welfare_"):
                    leaked.append(key)
            if leaked:
                fail(f"{name} 混入福利平台: {leaked}")
            else:
                ok(f"{name} 无福利平台（{len(sites)} 站点）")

        # manifest.json 若声明 welfarePlatforms 文件 → 必须存在
        mf = sources_root / "manifest.json"
        if mf.is_file():
            files = json.loads(mf.read_text(encoding="utf-8")).get("files", {})
            if "welfarePlatforms" in files:
                if (sources_root / str(files["welfarePlatforms"])).is_file():
                    ok("manifest 声明 welfarePlatforms 且文件存在")
                else:
                    fail("manifest 声明 welfarePlatforms 但文件缺失")
            else:
                ok("manifest 未声明 welfarePlatforms（H-01 前不要求）")

    # 6. 代码层：普通 Spider 链路不得引用福利脚本路径
    print("== 6. 普通 Spider 链路引用检查 ==")
    leaked_refs = []
    for d in SPIDER_DIRS:
        if not d.is_dir():
            continue
        for f in d.rglob("*.dart"):
            text = f.read_text(encoding="utf-8", errors="ignore")
            if WELFARE_MARK in text:
                leaked_refs.append(str(f.relative_to(ROOT)))
    if leaked_refs:
        fail(f"普通 Spider 链路引用福利脚本路径: {leaked_refs}")
    else:
        ok("lib/platform/spider + lib/domain/spider 无 welfare-js 引用")

    print()
    print("福利三重隔离守卫:", "通过 ✅" if errors == 0 else f"{errors} 项失败")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
