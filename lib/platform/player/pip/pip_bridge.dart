/// 平台层：系统级画中画平台桥（批次 C · C-05）。
///
/// 承载 [PipStrategy.mdk] / [PipStrategy.vt] / [PipStrategy.avPlayer] 三类
/// 系统级画中画：原生侧调用系统 PiP API（Android `enterPictureInPictureMode`
/// / macOS AVKit 系统画中画），事件面经 EventChannel 上抛 `pipChanged`。
///
/// 与 [FloatingWindowBridge]（C-09）同模式：抽象注入点，测试注入 fake；
/// 未接线/不可用 → [MethodChannelPipBridge] 返回 false / 事件流为空。
library;

import 'dart:async';

import 'package:flutter/services.dart';

/// 系统画中画事件。
class PipSystemEvent {
  /// 构造。
  const PipSystemEvent({required this.inPip});

  /// 是否已进入系统画中画。
  final bool inPip;
}

/// 系统画中画平台桥（可注入；测试注入 fake）。
abstract class PipPlatformBridge {
  /// 是否支持系统级画中画（平台查询；结果可缓存）。
  Future<bool> isSupported();

  /// 进入系统画中画（[width]/[height] 为宽高比基准，可缺省走平台默认 16:9）。
  Future<bool> enterPip({int? width, int? height});

  /// 退出系统画中画。
  Future<void> exitPip();

  /// 当前是否处于系统画中画。
  bool get isInPip;

  /// 系统画中画进入/退出事件流（`pipChanged`）。
  Stream<PipSystemEvent> events();

  /// 释放桥资源。
  Future<void> dispose();
}

/// 真实平台通道实现（Android `PipPlugin.kt` / macOS 系统画中画 ↔ Dart）。
class MethodChannelPipBridge implements PipPlatformBridge {
  /// 构造。
  MethodChannelPipBridge({
    MethodChannel? channel,
    EventChannel? events,
  })  : _channel = channel ?? const MethodChannel('com.vbox.player/pip'),
        _events = events ?? const EventChannel('com.vbox.player/pip/events');

  final MethodChannel _channel;
  final EventChannel _events;

  bool _inPip = false;
  bool? _supported;

  @override
  Future<bool> isSupported() async {
    final bool? cached = _supported;
    if (cached != null) return cached;
    try {
      final bool? ok = await _channel.invokeMethod<bool>('isSupported');
      _supported = ok ?? false;
      return _supported!;
    } on PlatformException {
      _supported = false;
      return false;
    }
  }

  @override
  Future<bool> enterPip({int? width, int? height}) async {
    try {
      final bool? ok = await _channel.invokeMethod<bool>('enterPip', <String, Object?>{
        if (width != null) 'width': width,
        if (height != null) 'height': height,
      });
      _inPip = ok ?? false;
      return _inPip;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<void> exitPip() async {
    try {
      await _channel.invokeMethod<void>('exitPip');
    } on PlatformException {
      // 忽略：系统可能已自行退出
    }
    _inPip = false;
  }

  @override
  bool get isInPip => _inPip;

  @override
  Stream<PipSystemEvent> events() => _events
      .receiveBroadcastStream()
      .map((Object? e) {
        final Map<Object?, Object?> m = (e as Map?) ?? const <Object?, Object?>{};
        return PipSystemEvent(inPip: (m['value'] as bool?) ?? _inPip);
      });

  @override
  Future<void> dispose() async {}
}

/// 不可用降级桥（`isSupported=false`，事件流恒空）。
class NoopPipBridge implements PipPlatformBridge {
  /// 构造。
  NoopPipBridge();

  @override
  Future<bool> isSupported() async => false;

  @override
  Future<bool> enterPip({int? width, int? height}) async => false;

  @override
  Future<void> exitPip() async {}

  @override
  bool get isInPip => false;

  @override
  Stream<PipSystemEvent> events() => const Stream<PipSystemEvent>.empty();

  @override
  Future<void> dispose() async {}
}
