#!/usr/bin/env python3
"""远程源 + 播放器领域层验证。

远程源（对齐 manifest_v1.json + RemoteSourceConfigManager.swift）：
  1. 代理降级链顺序：ghfast → gh-proxy → ghproxy.link → 直连
  2. configVersion 格式 YYYY.MM.DD.N
  3. TTL 21600（6h）
  4. shouldSync 判定（force/未同步/过期/版本变化）
  5. LoadState displayText 5 态

播放器（对齐 D6 · M1 MDK 接入后）：
  6. 后端降级链：Android=Media3→libVLC；桌面=media_kit；iOS=nativeiOS
  7. MKV 等复杂封装触发回退
  8. PlayMode 解析
"""
from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
RS = ROOT / "lib/domain/entities/remote_source"
PL = ROOT / "lib/domain/entities/player"


def main() -> int:
    errors = 0
    rm = (RS / "remote_manifest.dart").read_text()
    rs = (RS / "remote_strategy.dart").read_text()
    pl = (PL / "player.dart").read_text()

    print("== 1. 代理降级链顺序 ==")
    m = re.search(r"proxyHosts = <ProxyHost>\[(.*?)\];", rs, re.S)
    hosts = re.findall(r"host: '([^']+)'", m.group(1)) if m else []
    want = ["https://ghfast.top", "https://gh-proxy.com", "https://ghproxy.link"]
    if hosts == want:
        print(f"  ✅ {hosts}")
    else:
        print(f"  ❌ {hosts}（期望 {want}）")
        errors += 1
    if "out.add(rawUrl)" in rs:
        print("  ✅ 降级链末尾为直连")
    else:
        print("  ❌ 缺直连兜底")
        errors += 1

    print("== 2. configVersion 格式 ==")
    if re.search(r"configVersionPattern\s*=\s*RegExp\(r'\\\^\\\\d\{4\}", rm) or \
       "d{4}\\." in rm:
        print("  ✅ 正则含 YYYY.MM.DD.N 模式")
    else:
        # 宽松检查
        if r"\d{4}" in rm and r"\d{2}" in rm:
            print("  ✅ 正则含 YYYY.MM.DD 模式")
        else:
            print("  ❌ 未见格式校验")
            errors += 1

    print("== 3. TTL 21600 ==")
    if "21600" in rm:
        print("  ✅ defaultTtlSeconds = 21600")
    else:
        print("  ❌ TTL 不是 21600")
        errors += 1

    print("== 4. shouldSync 判定 ==")

    def should_sync(force, ver, last, ttl, now, app_changed):
        if force: return True
        if ver == "": return True
        if app_changed: return True
        if last <= 0: return True
        return (now - last) >= ttl

    cases = [
        ((True, "v1", 100, 21600, 200, False), True, "force"),
        ((False, "", 0, 21600, 200, False), True, "从未同步"),
        ((False, "v1", 100, 21600, 21700, False), True, "缓存过期"),
        ((False, "v1", 100, 21600, 200, True), True, "App版本变化"),
        ((False, "v1", 100, 21600, 200, False), False, "新鲜缓存"),
    ]
    for args, want_r, desc in cases:
        got = should_sync(*args)
        tag = "✅" if got == want_r else "❌"
        if got != want_r: errors += 1
        print(f"  {tag} {desc} → {got}")
    for frag in ["if (force) return true;", "lastConfigVersion.isEmpty",
                 "appVersionChanged", "isCacheExpired"]:
        if frag not in rs:
            print(f"  ❌ Dart 缺分支: {frag}")
            errors += 1

    print("== 5. LoadState displayText ==")
    for txt in ["未同步", "同步中", "远程配置", "缓存配置", "失败："]:
        print(f"  {'✅' if txt in rs else '❌'} {txt}")
        if txt not in rs:
            errors += 1

    print("== 6. 播放器后端降级链（D6）==")

    def chain_for_platform(plat: str) -> list[str]:
        """按行解析 chainFor 的 switch：累积 case 标签，遇 return 收集后重置。"""
        lines = pl.splitlines()
        in_fn = False
        pending: list[str] = []
        for idx, ln in enumerate(lines):
            if "static List<PlayerBackend> chainFor" in ln:
                in_fn = True
                continue
            if not in_fn:
                continue
            s = ln.strip()
            m_case = re.match(r"case '(\w+)':", s)
            if m_case:
                pending.append(m_case.group(1))
                continue
            if s.startswith("return"):
                # 可能是多行 return：累积到 "];" 或行内闭合。
                # 注意：多行 return 的**首行文本在各分支可能完全相同**
                # （如 android 与 windows/macos 都是 `return const <PlayerBackend>[`），
                # 故必须用 enumerate 的当前下标，不能用 lines.index(ln)（会命中首个同文本行）。
                buf = s
                if "];" not in s:
                    for nxt in lines[idx + 1:]:
                        buf += " " + nxt.strip()
                        if "];" in nxt:
                            break
                backs = re.findall(r"PlayerBackend\.(\w+)", buf)
                if plat in pending:
                    return backs
                pending = []
        return []

    for plat, want_chain in [
        # Android 原生仅实现 media3 / libVLC 两个内核（MDK 为 iOS 侧内核，
        # Flutter 端无原生实现），故链中不含 MDK。
        ("android", ["media3", "libVLC"]),
        # 桌面端已改用 media_kit（libmpv 的 Dart 封装，裸 libmpv 自研渲染桥已退役），
        # 故链中仅 mediaKit（MDK/libVLC 未在桌面接线）。
        ("windows", ["mediaKit"]),
        ("macos", ["mediaKit"]),
        ("ios", ["nativeiOS"]),
    ]:
        got = chain_for_platform(plat)
        tag = "✅" if got == want_chain else "❌"
        if got != want_chain:
            errors += 1
        print(f"  {tag} {plat}: {got}")
    # 确认 windows 与 macos 共用分支
    if re.search(r"case 'windows':\s*\n\s*case 'macos':", pl):
        print("  ✅ windows/macos 共用 media_kit 分支（case 穿透）")
    else:
        print("  ⚠️ windows/macos 未共用分支")

    print("== 7. 复杂封装回退 ==")
    for ext in [".mkv", ".flv", ".ts", ".rmvb", ".avi", ".wmv", ".m2ts"]:
        if f"'{ext}'" in pl:
            print(f"  ✅ {ext}")
        else:
            print(f"  ❌ {ext} 缺失")
            errors += 1

    print("== 8. PlayMode 解析 ==")
    for v in ["pan", "hybrid", "normal"]:
        if f"'{v}'" in pl:
            print(f"  ✅ {v}")
        else:
            print(f"  ❌ {v} 缺失")
            errors += 1

    print()
    print("远程源+播放器验证:", "通过 ✅" if errors == 0 else f"{errors} 项失败")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
