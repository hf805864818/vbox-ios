/// 平台层：后台播放（批次 C · C-05）。
///
/// 对齐 iOS `UIBackgroundModes: audio` + `AVAudioSession .playback` 语义：
/// App 退后台且播放中 → 启动前台媒体服务（Android `MediaPlaybackService`，
/// Media3 `MediaSessionService` 宿主，见 manifest `foregroundServiceType=
/// mediaPlayback`）；回前台 → 停止服务交还应用内播放。
///
/// 桌面端（Windows/macOS）无系统限制，桥实现为 no-op（后台自然续播）。
library;

import 'package:flutter/services.dart';

import 'pip_lifecycle.dart';

/// 后台播放平台桥（可注入；测试注入 fake）。
abstract class BackgroundPlayBridge {
  /// 启动后台播放承载（Android 前台服务；桌面 no-op）。
  Future<void> start();

  /// 停止后台播放承载。
  Future<void> stop();

  /// 是否处于后台播放承载中。
  bool get isActive;

  /// 释放桥资源。
  Future<void> dispose();
}

/// 真实平台通道实现（Android `BackgroundPlayPlugin.kt` ↔ Dart）。
class MethodChannelBackgroundPlayBridge implements BackgroundPlayBridge {
  /// 构造。
  MethodChannelBackgroundPlayBridge({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('com.vbox.player/background');

  final MethodChannel _channel;

  bool _active = false;

  @override
  bool get isActive => _active;

  @override
  Future<void> start() async {
    try {
      await _channel.invokeMethod<void>('start');
      _active = true;
    } on PlatformException {
      // 原生侧失败：保持非激活（调用方按前台播放兜底）
      _active = false;
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } on PlatformException {
      // 忽略
    }
    _active = false;
  }

  @override
  Future<void> dispose() async {}
}

/// 桌面端 no-op 桥（Windows/macOS 无系统后台限制）。
class NoopBackgroundPlayBridge implements BackgroundPlayBridge {
  /// 构造。
  NoopBackgroundPlayBridge();

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  bool get isActive => false;

  @override
  Future<void> dispose() async {}
}

/// 后台播放控制器。
///
/// 监听生命周期：后台 + 开启 + 播放中 → 启动承载；回前台 → 停止。
/// 纯编排逻辑，可注入桥，便于单测。
class BackgroundPlayController {
  /// 构造。
  BackgroundPlayController({
    required this.enabled,
    required BackgroundPlayBridge bridge,
  }) : _bridge = bridge;

  /// 后台播放开关（契约 `player_background_play`，默认 false）。
  bool enabled;

  final BackgroundPlayBridge _bridge;

  /// 是否处于后台播放承载中。
  bool get isActive => _bridge.isActive;

  /// 生命周期联动。
  ///
  /// [isPlaying] 为当前播放状态（仅播放中退后台才启动承载，
  /// 暂停态退后台不驻留——对齐 iOS 语义）。
  Future<void> handleLifecycle(
    PlaybackLifecycle lifecycle, {
    required bool isPlaying,
  }) async {
    if (lifecycle == PlaybackLifecycle.background) {
      if (enabled && isPlaying && !_bridge.isActive) {
        await _bridge.start();
      }
    } else if (lifecycle == PlaybackLifecycle.foreground) {
      if (_bridge.isActive) await _bridge.stop();
    }
  }

  /// 释放桥资源。
  Future<void> dispose() => _bridge.dispose();
}
