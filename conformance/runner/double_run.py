#!/usr/bin/env python3
"""VBox 双引擎双跑运行器（批次 Q · Q-06，conformance double-run）。

消费 conformance/fixtures/cross_engine_v1.json，把**同一组**跨引擎语义探针 +
一个五操作蜘蛛脚本，分别经 QuickJS（vq_*）与 JavaScriptCore（vj_*）的 C
wrapper 真实执行，逐条比对契约 golden（exact / prefix 两种口径），验证
JSC 主引擎 / QuickJS 降级引擎「结果一致」。

运行策略（平台自适应）：
  · QuickJS：三端均可 —— 用 cc/gcc 编译 quickjs/wrapper.c（vendored 源码全量），
    真机执行全部探针。
  · JSC：Darwin（macOS）本机用 clang 链系统 JavaScriptCore.framework 真机执行；
    非 Darwin（Linux CI/开发机）无法运行 JSC 运行时，退化为
    `-fsyntax-only` 编译校验（jsc/include 头文件 + wrapper.c + harness 语法完备），
    并标记「运行时校验回退至 build-jsc.yml build-macos / flutter-check build-macos」。

退出码
------
0 = 可用引擎全部通过且无失败项；1 = 存在失败项（编译失败 / 探针不符）。

结果写入 conformance/runner/double_run_results.json，供 CI 归档。
"""
from __future__ import annotations

import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
from typing import Any

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
FIX = ROOT / "conformance" / "fixtures"
RUNNER = ROOT / "conformance" / "runner"
QJS_DIR = ROOT / "quickjs" / "quickjs-2024-01-13"
QUICKJS_WRAPPER = ROOT / "quickjs" / "wrapper.c"
JSC_WRAPPER = ROOT / "jsc" / "wrapper.c"
JSC_INCLUDE = ROOT / "jsc" / "include"

RESULTS: list[dict[str, Any]] = []


def check(name: str, ok: bool, detail: str = "") -> bool:
    RESULTS.append({"suite": "engine.double", "name": name, "ok": ok,
                    "detail": detail})
    mark = "✅" if ok else "❌"
    line = f"  {mark} {name}"
    if detail and not ok:
        line += f"  —— {detail}"
    print(line)
    return ok


def cc() -> str:
    return shutil.which("cc") or shutil.which("gcc") or shutil.which("clang") or "cc"


def _qjs_sources() -> list[str]:
    return [str(QJS_DIR / f) for f in
            ("quickjs.c", "cutils.c", "libbf.c", "libregexp.c", "libunicode.c")]


def build_quickjs(work: str) -> str | None:
    exe = os.path.join(work, "double_qjs")
    version = (QJS_DIR / "VERSION").read_text(encoding="utf-8").strip()
    cmd = [cc(), "-O2", f"-DAPI_PREFIX=vq_", f'-DCONFIG_VERSION="{version}"',
           str(RUNNER / "double_run.c"), str(QUICKJS_WRAPPER),
           *[str(QJS_DIR / f) for f in
             ("quickjs.c", "cutils.c", "libbf.c", "libregexp.c", "libunicode.c")],
           "-I", str(QJS_DIR), "-I", str(ROOT / "quickjs")]
    if sys.platform != "win32":
        cmd += ["-lm"]
    cmd += ["-o", exe]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        check("QuickJS harness 编译", False, r.stderr.strip()[-400:])
        return None
    check("QuickJS harness 编译", True)
    return exe


def build_jsc_darwin(work: str) -> str | None:
    """macOS：clang + 系统 JavaScriptCore.framework 真机执行。"""
    exe = os.path.join(work, "double_jsc")
    clang = shutil.which("clang") or cc()
    cmd = [clang, "-O2", f"-DAPI_PREFIX=vj_",
           str(RUNNER / "double_run.c"), str(JSC_WRAPPER),
           "-I", str(ROOT / "jsc"), "-I", str(JSC_INCLUDE),
           "-framework", "JavaScriptCore", "-o", exe]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        check("JSC harness 编译（darwin）", False, r.stderr.strip()[-400:])
        return None
    check("JSC harness 编译（darwin）", True)
    return exe


def syntax_check_jsc() -> bool:
    """非 Darwin：仅编译校验（jsc/wrapper + harness 语法完备）。"""
    cmd = [cc(), "-std=c99", "-fsyntax-only",
           str(RUNNER / "double_run.c"), str(JSC_WRAPPER),
           "-I", str(ROOT / "jsc"), "-I", str(JSC_INCLUDE)]
    r = subprocess.run(cmd, capture_output=True, text=True)
    ok = r.returncode == 0
    check("JSC harness 语法校验（非 darwin 降级）", ok,
          "" if ok else r.stderr.strip()[-300:])
    return ok


def execute(exe: str, scripts: list[str]) -> list[str] | None:
    payload = ("\n".join(scripts) + "\n").encode("utf-8")
    r = subprocess.run([exe], input=payload, capture_output=True)
    if r.returncode != 0:
        check(f"harness 执行 {os.path.basename(exe)}", False,
              r.stderr.decode("utf-8", "replace").strip()[-300:])
        return None
    out = r.stdout.decode("utf-8", "replace")
    lines = out.splitlines()
    results: list[str] = []
    for ln in lines:
        _, _, val = ln.partition("=")
        results.append(val)
    return results


def compare(engine: str, results: list[str] | None, probes: list[dict]) -> int:
    label = "JSC" if engine == "jsc" else "QuickJS"
    if results is None:
        return 0
    if len(results) != len(probes):
        check(f"{label} 探针输出条目数", False,
              f"期望 {len(probes)} 实为 {len(results)}")
        return -1
    fails = 0
    for i, p in enumerate(probes):
        got = results[i]
        kind = p.get("kind")
        if kind == "ignore":
            continue
        exp = p["expected"]
        if kind == "exact":
            ok = got == exp
        elif kind == "prefix":
            ok = got.startswith(exp)
        else:
            ok = True
        if not ok:
            fails += 1
            check(f"{label}[{p['id']}] {kind}", False,
                  f"期望 {exp!r} 实为 {got!r}")
    if fails == 0:
        check(f"{label} 全部探针通过（{len([p for p in probes if p['kind'] != 'ignore'])} 项）",
              True)
    return fails


def main() -> int:
    d = json.loads((FIX / "cross_engine_v1.json").read_text(encoding="utf-8"))
    probes = d["probes"]
    print("=" * 62)
    print("VBox 双引擎双跑运行器 (cross-engine double-run)")
    print(f"fixture: {FIX.name}  ·  engines: {', '.join(d['engines'])}")
    print("=" * 62)

    with tempfile.TemporaryDirectory(prefix="vbox_double_") as tmp:
        qjs_exe = build_quickjs(tmp)
        qjs_res = execute(qjs_exe, [p["script"] for p in probes]) if qjs_exe else None
        qjs_fail = compare("quickjs", qjs_res, probes)
        check("QuickJS 运行时可用", qjs_res is not None)

        if sys.platform == "darwin":
            jsc_exe = build_jsc_darwin(tmp)
            jsc_res = execute(jsc_exe, [p["script"] for p in probes]) if jsc_exe else None
            jsc_fail = compare("jsc", jsc_res, probes)
            check("JSC 运行时可用（darwin 真机）", jsc_res is not None)
            # 双跑一致性：两引擎输出逐字节一致（仅当双方均真机执行）
            if qjs_res is not None and jsc_res is not None and qjs_res == jsc_res:
                check("双引擎输出逐字节一致（双跑）", True)
            elif qjs_res is not None and jsc_res is not None:
                check("双引擎输出逐字节一致（双跑）", False, "两引擎输出存在差异")
        else:
            jsc_fail = 0
            syntax_check_jsc()
            check("JSC 运行时（非 darwin 降级）", True,
                  "本机无 JavaScriptCore；运行时校验回退 macOS CI（build-jsc.yml）")

    failed = sum(1 for r in RESULTS if not r["ok"])
    print("\n" + "=" * 62)
    print(f"合计 {len(RESULTS)} 项：通过 {len(RESULTS) - failed} · 失败 {failed}")
    print("=" * 62)

    out = RUNNER / "double_run_results.json"
    out.write_text(json.dumps(
        {"total": len(RESULTS), "passed": len(RESULTS) - failed,
         "failed": failed, "engines": d["engines"], "results": RESULTS},
        ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"结果已写入 {out.relative_to(ROOT)}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())