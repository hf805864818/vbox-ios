/// 平台层：播放器通道桥（MethodChannel + EventChannel 适配）。
///
/// 对齐契约 §2.5 播放器能力矩阵 + iOS `PlayerEngine` 协议（type/state/event）。
/// 抽象注入点：测试注入 fake 桥，避免依赖真实平台通道（纯 Dart 可测）。
library;

import 'dart:async';

import 'package:flutter/services.dart';

import '../../domain/entities/player/player.dart';

/// 后端 → 通道字符串（与原生 `PlayerPlugin.kt` 的 `backend` 参数对齐）。
String backendWireValue(PlayerBackend backend) => switch (backend) {
      PlayerBackend.media3 => 'media3',
      PlayerBackend.libVLC => 'libVLC',
      PlayerBackend.libmpv => 'libmpv',
      PlayerBackend.mediaKit => 'media_kit',
      PlayerBackend.mdk => 'mdk',
      PlayerBackend.nativeiOS => 'nativeiOS',
    };

/// 播放器通道桥（可注入）。
abstract class PlayerChannelBridge {
  /// 调用原生方法（`open` / `play` / `pause` / `seekTo` / `setVolume` /
  /// `setSpeed` / `dispose`），失败时原生抛 [PlatformException]。
  Future<Object?> invoke(String method, [Object? arguments]);

  /// 原生事件流：`state` / `progress` / `error`（见 `ChannelPlayer` 解析）。
  Stream<Map<String, Object?>> events();

  /// 释放桥资源（Dart 侧；原生播放器释放走 `invoke('dispose')`）。
  Future<void> dispose();
}

/// 真实平台通道实现（Android `PlayerPlugin.kt` ↔ Dart）。
class MethodChannelPlayerBridge implements PlayerChannelBridge {
  MethodChannelPlayerBridge()
      : _channel = const MethodChannel('com.vbox.player/player'),
        _events = const EventChannel('com.vbox.player/player/events');

  final MethodChannel _channel;
  final EventChannel _events;

  @override
  Future<Object?> invoke(String method, [Object? arguments]) =>
      _channel.invokeMethod(method, arguments);

  @override
  Stream<Map<String, Object?>> events() => _events
      .receiveBroadcastStream()
      .map((Object? e) => (e as Map).cast<String, Object?>());

  @override
  Future<void> dispose() async {}
}
