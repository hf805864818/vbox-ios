/// 平台层：画中画控制器（批次 C · C-05 PiP 多策略编排）。
///
/// 把「画中画」这一行为统一为可注入控制面，按解析出的 [PipStrategy] 分派：
///  - 系统级策略（[PipStrategy.isSystemBased]）→ 原生系统桥 [PipPlatformBridge]
///  - 浮窗级策略（[PipStrategy.mpv] / [PipStrategy.viewCapture]）→ 复用 C-09
///    [FloatingWindow]（应用内浮窗承载）
///  - 未启用 / 不可用 → no-op（[enter] 返回 false，调用方隐藏入口）
///
/// 生命周期联动（对齐 iOS `UIBackgroundModes` + PiP 管理器语义）：
/// 后台且播放中 → 自动进入画中画；回到前台 → 自动退出。
library;

import 'dart:async';
import 'dart:typed_data';

import '../../../domain/entities/player/player.dart';
import '../floating/floating_window.dart';
import 'pip_bridge.dart';
import 'pip_lifecycle.dart';
import 'pip_strategy.dart';

/// 画中画状态。
enum PipState {
  /// 隐藏。
  hidden,

  /// 画中画激活中。
  active,
}

/// 画中画控制器。
class PipController {
  /// 构造（[strategy] 由 [resolveAndCreate] 或调用方显式解析注入）。
  ///
  /// [onFloatingTogglePlay] / [onFloatingRestoreFullScreen]：浮窗手势回调
  /// （对齐 iOS `PiPHelper` 通知语义 —— 单击 toggle 播放、双击恢复全屏）；
  /// 关闭手势由控制器内部消化（exit 退出浮窗并同步状态）。
  PipController({
    required this.enabled,
    required PipStrategy strategy,
    required PipPlatformBridge systemBridge,
    required FloatingWindow floating,
    this.onFloatingTogglePlay,
    this.onFloatingRestoreFullScreen,
  })  : _strategy = strategy,
        _system = systemBridge,
        _floating = floating {
    // 缺插件 / 原生异常时事件流会抛错：兜住，避免未处理异步异常。
    _sub = _system.events().listen(_onSystemEvent, onError: (Object _) {});
    // 浮窗手势三件套（批次 D · D2 对齐 iOS PlayerViewsV2.swift:383-451）。
    _floating.onGesture = _onFloatingGesture;
  }

  /// 异步构造：先探测系统 PiP 可用性，再解析策略并创建控制器。
  static Future<PipController> resolveAndCreate({
    required bool enabled,
    required String platform,
    required PlayerBackend? backend,
    required PipPlatformBridge systemBridge,
    required FloatingWindow floating,
    bool backgroundPlayEnabled = false,
    void Function()? onFloatingTogglePlay,
    void Function()? onFloatingRestoreFullScreen,
  }) async {
    final bool systemOk = await systemBridge.isSupported();
    return PipController(
      enabled: enabled,
      strategy: PipStrategyResolver.resolve(
        enabled: enabled,
        platform: platform,
        backend: backend,
        systemPipAvailable: systemOk,
        backgroundPlayEnabled: backgroundPlayEnabled,
      ),
      systemBridge: systemBridge,
      floating: floating,
      onFloatingTogglePlay: onFloatingTogglePlay,
      onFloatingRestoreFullScreen: onFloatingRestoreFullScreen,
    );
  }

  /// 画中画开关（契约 `player_pip_enabled`）。
  bool enabled;

  /// 浮窗手势回调（单击 → toggle 播放；由调用方注入播放编排）。
  final void Function()? onFloatingTogglePlay;

  /// 浮窗手势回调（双击 → 恢复全屏；由调用方注入页面返回编排）。
  final void Function()? onFloatingRestoreFullScreen;

  final PipStrategy _strategy;
  final PipPlatformBridge _system;
  final FloatingWindow _floating;
  late final StreamSubscription<PipSystemEvent> _sub;

  PipState _state = PipState.hidden;

  /// 当前策略。
  PipStrategy get strategy => _strategy;

  /// 当前状态。
  PipState get state => _state;

  /// 是否处于画中画。
  bool get isInPip => _state == PipState.active;

  /// 是否「仅后台声音」降级（P-芯7：不进画中画，退后台仅保音频）。
  bool get isAudioOnlyFallback => _strategy.isAudioOnly;

  /// 进入画中画。
  ///
  /// [title]/[isLive] 供浮窗策略展示媒体元信息；[width]/[height] 为
  /// 宽高比基准（系统策略默认 16:9）。返回是否成功进入。
  Future<bool> enter({
    String? title,
    bool? isLive,
    int? width,
    int? height,
  }) async {
    if (!enabled || _strategy == PipStrategy.none) return false;
    // P-芯7：仅后台声音降级不提供可视画中画（音频由后台播放通道保持）。
    if (_strategy.isAudioOnly) return false;
    if (_state == PipState.active) return true;
    if (_strategy.isSystemBased) {
      final bool ok = await _system.enterPip(width: width, height: height);
      if (ok) _setState(PipState.active);
      return ok;
    }
    final bool ok = await _floating.show(
      width: width?.toDouble(),
      height: height?.toDouble(),
    );
    if (ok) {
      await _floating.setMedia(title: title, isLive: isLive);
      _setState(PipState.active);
    }
    return ok;
  }

  /// 退出画中画。
  Future<void> exit() async {
    if (_state != PipState.active) return;
    if (_strategy.isSystemBased) {
      await _system.exitPip();
    } else {
      await _floating.hide();
    }
    _setState(PipState.hidden);
  }

  /// 进度上报（浮窗策略消费；系统画中画自持进度，忽略）。
  Future<void> updateProgress(int positionMs, int durationMs) async {
    if (_state != PipState.active || _strategy.isSystemBased) return;
    await _floating.updateProgress(positionMs, durationMs);
  }

  /// 截图快照上报（浮窗策略消费：RepaintBoundary → PNG → 原生换图，
  /// 对齐 iOS `updateFloatingSnapshot`；系统画中画自持画面，忽略）。
  Future<void> updateSnapshot(Uint8List? png) async {
    if (_state != PipState.active || _strategy.isSystemBased) return;
    await _floating.updateSnapshot(png);
  }

  /// 生命周期联动：后台 + 播放中 → 自动进入；回前台 → 自动退出。
  Future<void> handleLifecycle(
    PlaybackLifecycle lifecycle, {
    required bool isPlaying,
  }) async {
    if (!enabled || _strategy == PipStrategy.none) return;
    if (lifecycle == PlaybackLifecycle.background) {
      if (isPlaying && !isInPip) await enter();
    } else if (lifecycle == PlaybackLifecycle.foreground && isInPip) {
      await exit();
    }
  }

  /// 释放资源（退出画中画 + 取消订阅）。
  Future<void> dispose() async {
    if (_state == PipState.active) await exit();
    await _sub.cancel();
    await _system.dispose();
  }

  void _setState(PipState state) {
    _state = state;
  }

  void _onSystemEvent(PipSystemEvent event) {
    // 用户侧退出系统画中画（如点全屏按钮）→ 同步状态。
    if (!event.inPip && _state == PipState.active) {
      _setState(PipState.hidden);
    }
  }

  /// 浮窗手势分派（对齐 iOS `PiPHelper` 通知语义）：
  /// `tap` → toggle 播放、`doubleTap` → 恢复全屏、`close` → 退出浮窗。
  void _onFloatingGesture(String gesture) {
    switch (gesture) {
      case 'tap':
        onFloatingTogglePlay?.call();
      case 'doubleTap':
        onFloatingRestoreFullScreen?.call();
      case 'close':
        unawaited(exit());
    }
  }
}
