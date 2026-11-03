/// 平台层：通道播放器（实现 [Player]，经 [PlayerChannelBridge] 驱动原生端）。
///
/// 对齐 iOS `AVPlayerEngine` 等内核的宿主侧语义：控制面（open/play/pause/
/// seek/setRate/setVolume/dispose）+ 事件面（state/progress/error）。
library;

import 'dart:async';

import 'package:flutter/services.dart';

import '../../core/utils/logger.dart';
import '../../domain/entities/player/player.dart';
import 'player_channel_bridge.dart';

/// 打开媒体失败（原生错误码 + 消息，供 [PlayerController] 后端链回退）。
class PlayerOpenException implements Exception {
  const PlayerOpenException(this.code, this.message);

  /// 原生错误码（如 `E_BACKEND_UNAVAILABLE`）。
  final String code;

  /// 错误描述。
  final String message;

  @override
  String toString() => 'PlayerOpenException($code): $message';
}

/// 经平台通道调原生播放器（单后端实例）。
///
/// 一个 [ChannelPlayer] 绑定一个 [PlayerBackend]；回退链由
/// [PlayerController] 按后端逐个创建并重试。
class ChannelPlayer implements Player {
  ChannelPlayer({
    required this.backend,
    required PlayerChannelBridge bridge,
  }) : _bridge = bridge {
    _sub = _bridge.events().listen(_onEvent);
  }

  final PlayerChannelBridge _bridge;
  late final StreamSubscription<Map<String, Object?>> _sub;

  @override
  final PlayerBackend backend;

  /// 视频纹理输出面（R-渲1）：`open` 后由原生返回；`null` = 该后端无纹理输出。
  int? _textureId;

  @override
  int? get textureId => _textureId;

  @override
  List<PlayerBackend> get availableBackends => <PlayerBackend>[backend];

  @override
  void Function(PlayerState)? onStateChanged;

  @override
  void Function(PlaybackProgress)? onProgress;

  @override
  void Function(int width, int height)? onVideoSize;

  /// 纹理注册就绪（R-渲1 补发）：原生渲染线程懒注册纹理，`open` 返回时通常
  /// 尚未就绪，句柄随后经 `textureReady` 事件补发，宿主据此挂载输出面。
  @override
  void Function(int textureId)? onTextureReady;

  @override
  void Function(String message, {required bool fatal})? onError;

  // ─────────────── 控制面 ───────────────

  @override
  Future<void> open(PlayerSource source) async {
    try {
      final Object? r = await _bridge.invoke('open', <String, Object?>{
        ...source.toJson(),
        'backend': backendWireValue(backend),
      });
      // 仅在解析出句柄时写入：纹理懒注册时 open 多返回空 map，而 `textureReady`
      // 事件可能已先于 open 返回并设好 _textureId，此处不得用 null 覆盖。
      final int? id = _parseTextureId(r);
      if (id != null) {
        _textureId = id;
      }
    } on PlatformException catch (e) {
      throw PlayerOpenException(
        e.code,
        e.message ?? '播放器打开失败（${backend.name}）',
      );
    } on MissingPluginException {
      throw PlayerOpenException(
        'E_BACKEND_UNAVAILABLE',
        '平台通道未注册（${backend.name}）',
      );
    } catch (e) {
      // 原生通道异常/解码（ArgumentError 等）统一收敛为可回退的打开失败，
      // 避免上抛裸异常中断后端链并连带崩溃上层。
      throw PlayerOpenException('E_OPEN', '播放器打开失败（${backend.name}）：$e');
    }
  }

  /// 解析原生 `open` 返回值中的纹理句柄（R-渲1）。
  ///
  /// 兼容旧原生实现（返回 null → 无纹理输出）与未来扩展（`textureId` 为 int）。
  static int? _parseTextureId(Object? result) {
    if (result is Map) {
      final Object? id = result['textureId'];
      if (id is num) return id.toInt();
    }
    return null;
  }

  @override
  Future<void> play() => _invoke('play');

  @override
  Future<void> pause() => _invoke('pause');

  @override
  Future<void> seekTo(int positionMs) =>
      _invoke('seekTo', positionMs);

  @override
  Future<void> setVolume(double volume) => _invoke('setVolume', volume);

  @override
  Future<void> setSpeed(double speed) => _invoke('setSpeed', speed);

  @override
  Future<void> dispose() async {
    await _sub.cancel();
    _textureId = null;
    try {
      await _bridge.invoke('dispose');
    } on PlatformException {
      // 原生侧已随引擎销毁，忽略
    }
  }

  // ─────────────── 事件面 ───────────────

  Future<void> _invoke(String method, [Object? arguments]) async {
    try {
      await _bridge.invoke(method, arguments);
    } on PlatformException {
      // 控制类方法失败不阻断（状态由 error 事件上报）
    }
  }

  void _onEvent(Map<String, Object?> e) {
    switch ((e['type'] ?? '').toString()) {
      case 'state':
        onStateChanged?.call(_parseState((e['value'] ?? '').toString()));
        break;
      case 'progress':
        onProgress?.call(PlaybackProgress(
          positionMs: (e['positionMs'] as num?)?.toInt() ?? 0,
          durationMs: (e['durationMs'] as num?)?.toInt() ?? 0,
          bufferedMs: (e['bufferedMs'] as num?)?.toInt() ?? 0,
          isLive: e['isLive'] as bool? ?? false,
        ));
        break;
      case 'error':
        onError?.call(
          (e['message'] ?? '').toString(),
          fatal: e['fatal'] as bool? ?? true,
        );
        break;
      case 'videoSize':
        onVideoSize?.call(
          (e['width'] as num?)?.toInt() ?? 0,
          (e['height'] as num?)?.toInt() ?? 0,
        );
        break;
      case 'textureReady':
        final int? id = (e['textureId'] as num?)?.toInt();
        if (id != null && id >= 0) {
          _textureId = id;
          onTextureReady?.call(id);
        }
        break;
      case 'log':
        // 原生播放器日志（mpv / 渲染 / GL 上下文）转入应用日志，对齐 iOS
        // 排查详细度：无画面类问题可直接从日志看出失败在哪一环。
        _logNative(
          (e['level'] ?? 'info').toString(),
          (e['message'] ?? '').toString(),
        );
        break;
    }
  }

  void _logNative(String level, String message) {
    if (message.isEmpty) {
      return;
    }
    switch (level) {
      case 'error':
        AppLog.error('player-native', message, category: LogCategory.player);
        return;
      case 'warn':
        AppLog.warn('player-native', message, category: LogCategory.player);
        return;
      case 'debug':
        AppLog.debug('player-native', message, category: LogCategory.player);
        return;
      default:
        AppLog.info('player-native', message, category: LogCategory.player);
    }
  }

  static PlayerState _parseState(String value) => switch (value) {
        'idle' => PlayerState.idle,
        'opening' => PlayerState.opening,
        'playing' => PlayerState.playing,
        'paused' => PlayerState.paused,
        'buffering' => PlayerState.buffering,
        'ended' => PlayerState.ended,
        'error' => PlayerState.error,
        _ => PlayerState.idle,
      };
}
