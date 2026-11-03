/// 外壳：启动页门控（批次 L · L-壳1 + L-壳2 落点）。
///
/// 唯一真相源：iOS `ContentView.swift` L11-L15 / L149-L190 / L228-L235 /
/// L247-L254（动态启动页：数据门控 + 3.5s 最短展示 + 10s 兜底 + 0.4s 淡出）。
///
/// 行为（逐条对齐 iOS）：
///   1. 进入 `onAppear`：记录启动页出现时间，**并行**触发一次启动编排 [onStartup]；
///   2. 最短展示 [minHold]（3.5s）到达：数据已就绪则立即淡出；
///   3. 数据就绪（[SplashGateMonitor.homeDataReady]）变化瞬间：立即淡出（受 minHold 约束）；
///   4. [fallback]（10s）兜底：数据迟迟未就绪时强制退出启动页，避免卡启动页。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../widgets/brand/vbox_splash_view.dart';
import 'splash_gate_monitor.dart';

/// 启动页门控：包裹首页外壳，叠加品牌启动页直至门控条件满足。
class StartupGate extends StatefulWidget {
  /// 构造。
  const StartupGate({
    super.key,
    required this.child,
    required this.onStartup,
    this.minHold = const Duration(milliseconds: 3500),
    this.fallback = const Duration(seconds: 10),
    this.fadeDuration = const Duration(milliseconds: 400),
    this.splash = const VboxSplashView(),
  });

  /// 首页外壳（启动页覆盖其上，对齐 iOS 层级）。
  final Widget child;

  /// 启动页视图（缺省品牌闪屏；单测注入占位以隔离动画）。
  final Widget splash;

  /// 启动编排（会话恢复 → 远程源同步 → 引擎就绪）；失败已由编排器降级收敛。
  final Future<void> Function() onStartup;

  /// 启动页最短展示时长（对齐 iOS `splashMinHold = 3.5`）。
  final Duration minHold;

  /// 兜底强制退出时长（对齐 iOS 10s）。
  final Duration fallback;

  /// 淡出时长（对齐 iOS `easeInOut(0.4)`）。
  final Duration fadeDuration;

  @override
  State<StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<StartupGate> {
  bool _showSplash = true;

  /// 最短展示时长是否已到达（由定时器置位；不依赖墙钟，便于单测）。
  bool _minHoldElapsed = false;

  final List<Timer> _timers = <Timer>[];

  @override
  void initState() {
    super.initState();
    // 数据门控：首页数据就绪信号（幂等）。
    SplashGateMonitor.instance.addListener(_onDataReady);
    // 并行触发启动编排（不阻塞门控；完成与否都不影响 3.5s/10s 时序）。
    unawaited(widget.onStartup());
    // ① 最短展示时长到达：数据已就绪则立即淡出。
    _timers.add(Timer(widget.minHold, () {
      _minHoldElapsed = true;
      if (!mounted) return;
      if (SplashGateMonitor.instance.homeDataReady) {
        _dismissIfNeeded();
      }
    }));
    // ② 10 秒兜底：数据迟迟未就绪时强制退出启动页。
    _timers.add(Timer(widget.fallback, () {
      if (mounted) _dismissIfNeeded(force: true);
    }));
  }

  @override
  void dispose() {
    SplashGateMonitor.instance.removeListener(_onDataReady);
    for (final Timer t in _timers) {
      t.cancel();
    }
    super.dispose();
  }

  void _onDataReady() => _dismissIfNeeded();

  /// 淡出启动页：同时满足「最短展示时长」与「数据就绪 / 兜底」才执行。
  ///
  /// [force] 为 true 时（10s 兜底）跳过数据就绪判定，仍受最短展示时长约束
  /// （兜底 10s > 最短 3.5s，正常必然满足）。
  void _dismissIfNeeded({bool force = false}) {
    if (!_showSplash) return;
    if (!force && !_minHoldElapsed) return;
    setState(() => _showSplash = false);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        // 首页外壳必须拿到「铺满」的紧约束：Stack 对非定位子项下发的是松约束，
        // 而 [HomeShellPage] 根节点是「全 Positioned 子项」的 Stack，
        // RenderStack 在无有效非定位子项时会取 constraints.constrain(Size(0,0))，
        // 松约束下即塌缩为 0×0 → 启动页淡出后整屏只剩底层黑窗（黑屏）。
        Positioned.fill(child: widget.child),
        // 启动页覆盖层（最高层级，覆盖底栏与浮层）。
        IgnorePointer(
          ignoring: !_showSplash,
          child: AnimatedOpacity(
            opacity: _showSplash ? 1 : 0,
            duration: widget.fadeDuration,
            curve: Curves.easeInOut,
            child: widget.splash,
          ),
        ),
      ],
    );
  }
}