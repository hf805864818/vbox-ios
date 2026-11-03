/// G-02-A：ChannelPlayer 平台通道转发 + 事件分发（注入假桥，纯 Dart）。
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/player/player.dart';
import 'package:vbox/platform/player/channel_player.dart';
import 'package:vbox/platform/player/player_channel_bridge.dart';

/// 一次通道调用记录。
class _Call {
  const _Call(this.method, this.arguments);

  final String method;
  final Object? arguments;
}

/// 假桥：记录全部调用，可配置「open 指定后端失败」与 open 返回值（纹理句柄）。
class _FakeBridge implements PlayerChannelBridge {
  _FakeBridge({this.failBackends = const <String>{}, this.openResult});

  final Set<String> failBackends;

  /// open 成功时的原生返回值（如 `{'textureId': 7}`）。
  final Object? openResult;

  final List<_Call> calls = <_Call>[];
  final StreamController<Map<String, Object?>> _ctrl =
      StreamController<Map<String, Object?>>.broadcast();

  @override
  Future<Object?> invoke(String method, [Object? arguments]) async {
    calls.add(_Call(method, arguments));
    if (method == 'open') {
      final Map<String, Object?> args = (arguments as Map).cast<String, Object?>();
      final String backend = (args['backend'] as String?) ?? 'media3';
      if (failBackends.contains(backend)) {
        throw PlatformException(
          code: 'E_BACKEND_UNAVAILABLE',
          message: 'fake: $backend 不可用',
        );
      }
      return openResult;
    }
    return null;
  }

  @override
  Stream<Map<String, Object?>> events() => _ctrl.stream;

  void emit(Map<String, Object?> e) => _ctrl.add(e);

  @override
  Future<void> dispose() async => _ctrl.close();
}

Map<String, Object?> _args(_Call c) =>
    (c.arguments as Map).cast<String, Object?>();

void main() {
  group('ChannelPlayer.open', () {
    test('open：组装参数（含 backend wire 值）转发到通道', () async {
      final _FakeBridge bridge = _FakeBridge();
      final ChannelPlayer p = ChannelPlayer(
        backend: PlayerBackend.media3,
        bridge: bridge,
      );
      await p.open(const PlayerSource(
        url: 'https://cdn.example.com/a.mp4',
        headers: <String, String>{'Referer': 'https://example.com'},
        title: '测试影片',
        isLive: false,
        mimeType: 'video/mp4',
      ));
      expect(bridge.calls.first.method, 'open');
      final Map<String, Object?> args = _args(bridge.calls.first);
      expect(args['url'], 'https://cdn.example.com/a.mp4');
      expect(args['backend'], 'media3');
      expect(args['headers'], <String, String>{'Referer': 'https://example.com'});
      expect(args['title'], '测试影片');
      expect(args['isLive'], false);
      expect(args['mimeType'], 'video/mp4');
      await p.dispose();
    });

    test('open：原生抛 PlatformException → PlayerOpenException（code 透传）', () async {
      final _FakeBridge bridge =
          _FakeBridge(failBackends: <String>{'libVLC'});
      final ChannelPlayer p = ChannelPlayer(
        backend: PlayerBackend.libVLC,
        bridge: bridge,
      );
      await expectLater(
        p.open(const PlayerSource(url: 'https://x/a.mkv')),
        throwsA(isA<PlayerOpenException>()
            .having((e) => e.code, 'code', 'E_BACKEND_UNAVAILABLE')
            .having((e) => e.message, 'message', contains('libVLC'))),
      );
      await p.dispose();
    });

    test('open：解析原生返回的 textureId（R-渲1）', () async {
      final _FakeBridge bridge =
          _FakeBridge(openResult: <String, Object?>{'textureId': 7});
      final ChannelPlayer p = ChannelPlayer(
        backend: PlayerBackend.media3,
        bridge: bridge,
      );
      expect(p.textureId, isNull); // 未开播
      await p.open(const PlayerSource(url: 'https://x/a.mp4'));
      expect(p.textureId, 7);
      await p.dispose();
      expect(p.textureId, isNull); // 释放后清空
    });

    test('open：原生返回 null → textureId 保持 null（无纹理输出后端）', () async {
      final _FakeBridge bridge = _FakeBridge();
      final ChannelPlayer p = ChannelPlayer(
        backend: PlayerBackend.libmpv,
        bridge: bridge,
      );
      await p.open(const PlayerSource(url: 'https://x/a.mp4'));
      expect(p.textureId, isNull);
      await p.dispose();
    });
  });

  group('ChannelPlayer 控制转发', () {
    test('play / pause / seekTo / setVolume / setSpeed / dispose 依次转发', () async {
      final _FakeBridge bridge = _FakeBridge();
      final ChannelPlayer p = ChannelPlayer(
        backend: PlayerBackend.media3,
        bridge: bridge,
      );
      await p.play();
      await p.pause();
      await p.seekTo(120000);
      await p.setVolume(0.5);
      await p.setSpeed(1.5);
      await p.dispose();
      expect(
        bridge.calls.map((_Call c) => c.method).toList(),
        <String>['play', 'pause', 'seekTo', 'setVolume', 'setSpeed', 'dispose'],
      );
    });

    test('seekTo 传毫秒整数、setVolume/setSpeed 传浮点', () async {
      final _FakeBridge bridge = _FakeBridge();
      final ChannelPlayer p = ChannelPlayer(
        backend: PlayerBackend.media3,
        bridge: bridge,
      );
      await p.seekTo(120000);
      await p.setVolume(0.5);
      await p.setSpeed(1.5);
      expect(bridge.calls[0].arguments, 120000);
      expect(bridge.calls[1].arguments, 0.5);
      expect(bridge.calls[2].arguments, 1.5);
      await p.dispose();
    });
  });

  group('ChannelPlayer 事件分发', () {
    test('state 事件 → onStateChanged 映射', () async {
      final _FakeBridge bridge = _FakeBridge();
      final ChannelPlayer p = ChannelPlayer(
        backend: PlayerBackend.media3,
        bridge: bridge,
      );
      final List<PlayerState> states = <PlayerState>[];
      p.onStateChanged = states.add;
      bridge.emit(<String, Object?>{'type': 'state', 'value': 'buffering'});
      bridge.emit(<String, Object?>{'type': 'state', 'value': 'playing'});
      bridge.emit(<String, Object?>{'type': 'state', 'value': 'paused'});
      bridge.emit(<String, Object?>{'type': 'state', 'value': 'ended'});
      bridge.emit(<String, Object?>{'type': 'state', 'value': 'error'});
      await Future<void>.delayed(Duration.zero);
      expect(states, <PlayerState>[
        PlayerState.buffering,
        PlayerState.playing,
        PlayerState.paused,
        PlayerState.ended,
        PlayerState.error,
      ]);
      await p.dispose();
    });

    test('progress 事件 → onProgress（含 isLive）', () async {
      final _FakeBridge bridge = _FakeBridge();
      final ChannelPlayer p = ChannelPlayer(
        backend: PlayerBackend.media3,
        bridge: bridge,
      );
      final List<PlaybackProgress> progress = <PlaybackProgress>[];
      p.onProgress = progress.add;
      bridge.emit(<String, Object?>{
        'type': 'progress',
        'positionMs': 3000,
        'durationMs': 60000,
        'bufferedMs': 45000,
        'isLive': false,
      });
      await Future<void>.delayed(Duration.zero);
      expect(progress, hasLength(1));
      expect(progress.single.positionMs, 3000);
      expect(progress.single.durationMs, 60000);
      expect(progress.single.bufferedMs, 45000);
      expect(progress.single.isLive, false);
      await p.dispose();
    });

    test('error 事件 → onError（fatal 透传）', () async {
      final _FakeBridge bridge = _FakeBridge();
      final ChannelPlayer p = ChannelPlayer(
        backend: PlayerBackend.media3,
        bridge: bridge,
      );
      String? message;
      bool? wasFatal;
      p.onError = (String m, {required bool fatal}) {
        message = m;
        wasFatal = fatal;
      };
      bridge.emit(<String, Object?>{
        'type': 'error',
        'message': '解码失败',
        'fatal': true,
      });
      await Future<void>.delayed(Duration.zero);
      expect(message, '解码失败');
      expect(wasFatal, true);
      await p.dispose();
    });
  });
}
