/// UI-B3 骨架屏动效：轻量 shimmer 占位块（内建动画，零第三方依赖）。
///
/// 取代散落的静态占位色块（如 `placeholderColor: scheme.surfaceContainerHighest`），
/// 提供「渐变扫光」加载动效：
///  - 扫光沿水平方向**单次**扫过（[AnimationController.forward] 一次即停），
///    不循环 —— 避免无限动画拖垮 `pumpAndSettle` 类测试与视觉回归基线，
///    扫完后保持静态基色（**像素与静态占位完全一致**）；
///  - 扫光用「渐变对齐平移」实现（`LinearGradient.begin/end` 随动画位移），
///    **不使用 `ShaderMask`** —— 后者会引入额外 saveLayer 合成层、改变圆角
///    边缘抗锯齿，导致 golden 基线出现 1px 级像素漂移；
///  - 遵守系统「减少动态效果」（[MediaQuery.disableAnimationsOf]）：开启时
///    直接渲染静态基色，保证无障碍与像素确定性。
library;

import 'package:flutter/material.dart';

/// 骨架屏 shimmer 占位块。
class ShimmerBox extends StatelessWidget {
  /// 构造。
  const ShimmerBox({
    super.key,
    this.color,
    this.borderRadius,
    this.child,
  });

  /// 基色（缺省取主题 `surfaceContainerHighest`）。
  final Color? color;

  /// 圆角（缺省直角）。
  final BorderRadius? borderRadius;

  /// 叠放内容（如影片图标），可为空。
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
    final Color base =
        color ?? Theme.of(context).colorScheme.surfaceContainerHighest;
    final Widget content = reduceMotion
        ? ColoredBox(color: base, child: child)
        : _ShimmerSweep(base: base, child: child);
    final BorderRadius radius = borderRadius ?? BorderRadius.zero;
    return radius == BorderRadius.zero
        ? content
        : ClipRRect(borderRadius: radius, child: content);
  }
}

/// 扫光动画主体：基色 + 水平平移的渐变高光带（单次播放）。
class _ShimmerSweep extends StatefulWidget {
  const _ShimmerSweep({required this.base, this.child});

  final Color base;
  final Widget? child;

  @override
  State<_ShimmerSweep> createState() => _ShimmerSweepState();
}

class _ShimmerSweepState extends State<_ShimmerSweep>
    with SingleTickerProviderStateMixin {
  /// 单次扫光：0 → 1 后保持，不循环（测试 / 视觉回归可安全 settle）。
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..forward();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Color base = widget.base;
    final Color highlight = _highlight(base);
    return AnimatedBuilder(
      animation: _controller,
      builder: (BuildContext context, Widget? child) {
        // 扫光结束（单次播放完成）→ 回落为纯色块：与静态占位逐像素一致，
        // 既省一次渐变绘制，也保证 golden / 视觉回归基线稳定。
        if (_controller.isCompleted) {
          return ColoredBox(color: base, child: widget.child);
        }
        // 扫光带半宽（对齐空间：-1 左缘 / 1 右缘；0.90 == 屏宽 45%）。
        const double f = 0.90;
        final double t = _controller.value;
        final double center = -1 - f + (2 + 2 * f) * t;
        return DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment(center - f, 0),
              end: Alignment(center + f, 0),
              colors: <Color>[base, highlight, base],
            ),
          ),
          child: widget.child,
        );
      },
    );
  }

  /// 高光色（基色向白提亮 10%）。
  static Color _highlight(Color base) => Color.lerp(base, Colors.white, 0.10)!;
}
