/// 平台层：音乐媒体会话原生实现（批次 D · D3）。
///
/// 对齐 iOS `AudioPlayerManager.swift:517-583`：
///   - `updateNowPlaying` → 原生锁屏信息写入（Android `MediaSession`
///     setMetadata/setPlaybackState、macOS `MPNowPlayingInfoCenter.nowPlayingInfo`、
///     Windows SMTC `DisplayUpdater`）；
///   - `clear` → 原生清空（对齐 iOS 停止时 `nowPlayingInfo = nil`）；
///   - 原生线控命令（`MPRemoteCommandCenter` / `MediaSession.Callback` /
///     SMTC `ButtonPressed`）→ EventChannel 回派 → [MusicMediaCommand]。
///
/// 通道协议：
///   - MethodChannel `com.vbox.player/music_media`：`update` / `clear`；
///   - EventChannel `com.vbox.player/music_media/events`：
///     `{command: play|pause|toggle|next|previous|seek, positionMs?}`。
///
/// 全部通道调用带 `MissingPluginException` / `PlatformException` 降级
/// （桌面未接线 / 单测环境静默，对齐 D28「编排先行、原生接线后补」口径）。
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import '../media_session.dart';

/// 原生媒体会话后端（Android `MusicMediaSessionPlugin.kt` / macOS
/// `MusicMediaSessionPlugin.swift` / Windows `music_media_plugin` ↔ Dart）。
class NativeMusicMediaSession implements MusicMediaSession {
  /// 构造（[channel] / [events] 可注入；单测用 TestDefaultBinaryMessenger mock）。
  NativeMusicMediaSession({MethodChannel? channel, EventChannel? events})
      : _channel = channel ??
            const MethodChannel('com.vbox.player/music_media'),
        _events =
            events ?? const EventChannel('com.vbox.player/music_media/events');

  final MethodChannel _channel;
  final EventChannel _events;

  StreamSubscription<dynamic>? _sub;

  @override
  MusicMediaCommandHandler? get onCommand => _onCommand;
  MusicMediaCommandHandler? _onCommand;

  @override
  set onCommand(MusicMediaCommandHandler? handler) {
    _onCommand = handler;
    _sub?.cancel();
    _sub = null;
    if (handler == null) return;
    // 测试环境（FLUTTER_TEST）跳过订阅：无原生接线时 EventChannel 激活错误
    // 经 FlutterError.reportError 上报，会污染 flutter_test 用例（与 D28
    // 「编排先行、原生接线后补」静默降级口径一致）。
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    // 事件订阅懒建：仅在有消费方时挂（未接线端事件流抛错静默降级）。
    _sub = _events.receiveBroadcastStream().listen(
          _onNativeEvent,
          onError: (Object _) {},
          cancelOnError: false,
        );
  }

  @override
  Future<void> updateNowPlaying(
    MusicMediaMetadata metadata,
    MusicMediaPlaybackState state,
  ) async {
    try {
      await _channel.invokeMethod<void>('update', <String, Object?>{
        'title': metadata.title,
        'artist': metadata.artist,
        if (metadata.album != null) 'album': metadata.album,
        if (metadata.coverURL != null) 'coverURL': metadata.coverURL,
        'durationMs': metadata.duration.inMilliseconds,
        'playing': state.playing,
        'positionMs': state.position.inMilliseconds,
      });
    } on PlatformException {
      // 忽略：原生侧异常不阻断播放编排。
    } on MissingPluginException {
      // 未接线：静默降级（D28 口径）。
    }
  }

  @override
  Future<void> clear() async {
    try {
      await _channel.invokeMethod<void>('clear');
    } on PlatformException {
      // 忽略。
    } on MissingPluginException {
      // 未接线：静默降级。
    }
  }

  /// 原生命令事件 → [MusicMediaCommand]（对齐 iOS 六命令语义）。
  void _onNativeEvent(Object? event) {
    final MusicMediaCommandHandler? handler = _onCommand;
    if (event is! Map || handler == null) return;
    final String command = event['command']?.toString() ?? '';
    switch (command) {
      case 'play':
        handler(MusicMediaCommand.play);
      case 'pause':
        handler(MusicMediaCommand.pause);
      case 'toggle':
        handler(MusicMediaCommand.toggle);
      case 'next':
        handler(MusicMediaCommand.next);
      case 'previous':
        handler(MusicMediaCommand.previous);
      case 'seek':
        final int ms = (event['positionMs'] as num?)?.toInt() ?? 0;
        handler(MusicMediaSeekCommand(Duration(milliseconds: ms)));
    }
  }

  /// 释放事件订阅（测试 / 页面销毁时调用；会话本身无原生资源需要释放）。
  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
  }
}
