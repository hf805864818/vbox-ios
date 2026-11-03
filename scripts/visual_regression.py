#!/usr/bin/env python3
"""视觉回归比对（批次 A · A-12 · 批次 C · C1）。

依据：docs/第2轮开发计划_功能补全_v2.6.md §3.6「保真度 ≥95% 的可度量定义」——
逐页 SSIM ≥ 0.95（或像素差 ≤5%）为主要指标；§3.7 视觉回归与守卫。

两种模式：
1. **目录模式**（A-12 原用法）：`--ref <目录> --cmp <目录>`，按**同名** PNG 配对。
2. **清单模式**（C1 新增）：`--pairs <清单.json>`，按页面族逐条配对
   Flutter golden ↔ iOS 基准图，并以「基线 − 容差」做门禁。

**门禁口径（C1 决策 A · 相对门禁）**：计划 §3.6 的**绝对** SSIM ≥ 0.95 是
**跨设备不可达**的 —— iOS 真机截图 vs Flutter 测试渲染，在分辨率（2556×1179
vs 390×844）/ 字体光栅化 / 内容（真实海报 vs 占位图）三重差异下实测仅
0.25~0.45，即布局完全一致也不可能达标。故 CI 采用**相对门禁**：
逐页登记实测**基线分**，分数跌破 `baseline − tolerance` 即失败（防回归）；
绝对 0.95 留待 J.3「UI 还原度逐页终检」重定口径。

用法：
    python3 scripts/visual_regression.py --pairs docs/ui_baseline/visual_pairs.json [--gate]
    python3 scripts/visual_regression.py --pairs docs/ui_baseline/visual_pairs.json --update-baseline
    python3 scripts/visual_regression.py --ref docs/ui_baseline --cmp <截图目录> [--threshold 0.95] [--gate]

产出：逐页 SSIM（对比基线 / 容差）+ 均值 + 不达标清单。
退出码：0 通过 / 1 不达标（仅 `--gate` 时）。
"""
from __future__ import annotations

import argparse
import json
import pathlib
import sys

import cv2
import numpy as np

ROOT = pathlib.Path(__file__).resolve().parent.parent


def ssim(a: np.ndarray, b: np.ndarray) -> float:
    """结构相似度（灰度，0–1）。"""
    a = cv2.cvtColor(a, cv2.COLOR_RGB2GRAY).astype(np.float64)
    b = cv2.cvtColor(b, cv2.COLOR_RGB2GRAY).astype(np.float64)
    return _ssim_impl(a, b)


def _ssim_impl(a: np.ndarray, b: np.ndarray) -> float:
    """标准 SSIM（窗口 11×11 高斯，σ=1.5）。"""
    c1 = (0.01 * 255.0) ** 2
    c2 = (0.03 * 255.0) ** 2
    kernel = cv2.getGaussianKernel(11, 1.5)
    window = kernel @ kernel.T
    mu_a = cv2.filter2D(a, -1, window)
    mu_b = cv2.filter2D(b, -1, window)
    mu_a2, mu_b2, mu_ab = mu_a * mu_a, mu_b * mu_b, mu_a * mu_b
    sigma_a2 = cv2.filter2D(a * a, -1, window) - mu_a2
    sigma_b2 = cv2.filter2D(b * b, -1, window) - mu_b2
    sigma_ab = cv2.filter2D(a * b, -1, window) - mu_ab
    ssim_map = ((2 * mu_ab + c1) * (2 * sigma_ab + c2)) / (
        (mu_a2 + mu_b2 + c1) * (sigma_a2 + sigma_b2 + c2)
    )
    return float(ssim_map.mean())


def _load(path: pathlib.Path) -> np.ndarray:
    img = cv2.imread(str(path), cv2.IMREAD_COLOR)
    if img is None:
        raise ValueError(f"无法读取图片：{path}")
    return cv2.cvtColor(img, cv2.COLOR_BGR2RGB)


def score_pair(ref_path: pathlib.Path, cmp_path: pathlib.Path) -> float:
    """两张图先对齐到较小尺寸（保持宽高比），再算 SSIM。"""
    a = _load(ref_path)
    b = _load(cmp_path)
    if a.shape != b.shape:
        h = min(a.shape[0], b.shape[0])
        w = min(a.shape[1], b.shape[1])
        a = cv2.resize(a, (w, h))
        b = cv2.resize(b, (w, h))
    return ssim(a, b)


def _resolve(p: str) -> pathlib.Path:
    """清单内路径：绝对路径原样，相对路径按仓库根解析。"""
    q = pathlib.Path(p)
    return q if q.is_absolute() else ROOT / q


def _rel(p: pathlib.Path) -> str:
    """仓库内路径显示为相对路径；仓库外原样显示。"""
    try:
        return str(p.relative_to(ROOT))
    except ValueError:
        return str(p)


def _report(scores: dict[str, float], threshold: float) -> None:
    for name in scores:
        mark = "✅" if scores[name] >= threshold else "❌"
        print(f"  {mark} {name:<24} SSIM = {scores[name]:.3f}")


def run_manifest(args: argparse.Namespace) -> int:
    """清单模式：逐页配对 + 相对基线门禁（C1）。"""
    manifest_path = _resolve(args.pairs)
    if not manifest_path.is_file():
        print(f"  ❌ 清单不存在：{manifest_path}")
        return 1
    data = json.loads(manifest_path.read_text(encoding="utf-8"))
    pairs = data.get("pairs", [])
    tolerance = float(data.get("tolerance", 0.02))
    if not pairs:
        print("  ❌ 清单内无 pairs")
        return 1

    print("== 视觉回归比对（SSIM · C1 配对清单）==")
    print(f"  清单：{_rel(manifest_path)} · 容差 {tolerance:.2f}")

    scores: dict[int, float] = {}
    missing: list[str] = []
    for i, pair in enumerate(pairs):
        ref, cmp = _resolve(pair["ref"]), _resolve(pair["cmp"])
        if not ref.is_file() or not cmp.is_file():
            missing.append(f"{pair.get('family', i)}（ref={'ok' if ref.is_file() else '缺失'} cmp={'ok' if cmp.is_file() else '缺失'}）")
            continue
        scores[i] = score_pair(ref, cmp)

    if missing:
        print(f"  ❌ 配对文件缺失 {len(missing)} 条：{', '.join(missing)}")
        return 1

    if args.update_baseline:
        for i, pair in enumerate(pairs):
            pair["baseline"] = round(scores[i], 4)
        manifest_path.write_text(
            json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
        )
        print(f"  📝 已登记 {len(scores)} 条基线分到 {_rel(manifest_path)}")

    below: list[str] = []
    for i, pair in enumerate(pairs):
        family = str(pair.get("family", i))
        score = scores[i]
        baseline = pair.get("baseline")
        if baseline is None:
            print(f"  ⚪ {family:<20} SSIM = {score:.3f} · 基线未登记（跳过门禁）")
            continue
        floor = float(baseline) - tolerance
        delta = score - float(baseline)
        if score < floor:
            mark, below = "❌", below + [family]
            note = f"低于基线-容差（{floor:.3f}）"
        else:
            mark, note = "✅", "达标"
        print(f"  {mark} {family:<20} SSIM = {score:.3f} · 基线 {float(baseline):.3f} · Δ {delta:+.3f} · {note}")

    mean = float(np.mean(list(scores.values())))
    print(f"  配对 {len(scores)} 条 · 均值 SSIM = {mean:.3f}")
    if below:
        print(f"  ⚠️  回归 {len(below)} 条：{', '.join(below)}")
        if args.gate:
            print("视觉回归比对: 失败 ❌")
            return 1
    print("视觉回归比对: 通过 ✅" + ("" if args.gate else "（报告模式，未门禁）"))
    return 0


def run_dirs(args: argparse.Namespace) -> int:
    """目录模式：按同名 PNG 配对（A-12 原用法）。"""
    ref_dir, cmp_dir = args.ref, args.cmp
    print("== 视觉回归比对（SSIM）==")
    if not ref_dir.is_dir() or not cmp_dir.is_dir():
        print("  ❌ --ref / --cmp 需为存在目录")
        return 1

    refs = {p.name: p for p in ref_dir.glob("*.png")}
    cmps = {p.name: p for p in cmp_dir.glob("*.png")}
    if not refs or not cmps:
        print("  ❌ 目录内无 PNG（refs=%d cmps=%d）" % (len(refs), len(cmps)))
        return 1

    names = sorted(refs.keys() & cmps.keys())
    if not names:
        print("  ❌ 无同名 PNG（ref=%s cmp=%s）" % (sorted(refs)[:5], sorted(cmps)[:5]))
        return 1

    scores = {name: score_pair(refs[name], cmps[name]) for name in names}
    _report(scores, args.threshold)

    mean = float(np.mean(list(scores.values())))
    below = [n for n in names if scores[n] < args.threshold]
    print(f"  同名 {len(names)} 张 · 均值 SSIM = {mean:.3f} · 门槛 {args.threshold:.2f}")
    if below:
        print(f"  ⚠️  低于门槛 {len(below)} 张：{', '.join(below)}")
        if args.gate:
            print("视觉回归比对: 失败 ❌")
            return 1
    print("视觉回归比对: 通过 ✅（报告模式）" if not below else "视觉回归比对: 通过 ✅（报告模式，未门禁）")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--pairs", type=str, help="配对清单 JSON（C1 清单模式）")
    ap.add_argument("--ref", type=pathlib.Path, help="参考图目录（目录模式）")
    ap.add_argument("--cmp", type=pathlib.Path, help="Flutter 截图目录（目录模式）")
    ap.add_argument("--threshold", type=float, default=0.95, help="目录模式门槛（默认 0.95）")
    ap.add_argument("--update-baseline", action="store_true", help="把实测分写回清单（清单模式）")
    ap.add_argument("--gate", action="store_true", help="不达标即返回非 0（CI 门禁）")
    args = ap.parse_args()

    if args.pairs:
        return run_manifest(args)
    if args.ref and args.cmp:
        return run_dirs(args)
    ap.error("需提供 --pairs，或同时提供 --ref/--cmp")


if __name__ == "__main__":
    sys.exit(main())