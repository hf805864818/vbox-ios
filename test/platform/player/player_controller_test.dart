/// G-02-A：PlayerController 后端降级链 + 状态转发（注入假桥，纯 Dart）。
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/player/player.dart';
import 'package:vbox/platform/player/channel_player.dart';
import 'package:vbox/platform/player/playback_route.dart';
import 'package:vbox/platform/player/player_channel_bridge.dart';
import 'package:vbox/platform/player/player_controller.dart';

/// 假桥：记录全部调用，可配置「open 指定后端失败」。
class _FakeBridge implements PlayerChannelBridge {
  _FakeBridge({this.failBackends = const <String>{}});

  final Set<String> failBackends;
  final List<String> calls = <String>[];
  final StreamController<Map<String, Object?>> _ctrl =
      StreamController<Map<String, Object?>>.broadcast();

  @override
  Future<Object?> invoke(String method, [Object? arguments]) async {
    calls.add(method);
    if (method == 'open') {
      final Map<String, Object?> args = (arguments as Map).cast<String, Object?>();
      final String backend = (args['backend'] as String?) ?? 'media3';
      if (failBackends.contains(backend)) {
        throw PlatformException(
          code: 'E_BACKEND_UNAVAILABLE',
          message: 'fake: $backend 不可用',
        );
      }
    }
    return null;
  }

  @override
  Stream<Map<String, Object?>> events() => _ctrl.stream;

  void emit(Map<String, Object?> e) => _ctrl.add(e);

  @override
  Future<void> dispose() async => _ctrl.close();
}

void main() {
  group('PlayerController.open 回退链', () {
    test('初始后端失败 → 链上下一个后端接管', () async {
      final _FakeBridge bridge = _FakeBridge(failBackends: <String>{'media3'});
      final PlayerController ctrl = PlayerController(
        bridge: bridge,
        backendChain: const <PlayerBackend>[
          PlayerBackend.media3,
          PlayerBackend.libVLC,
        ],
        selectInitialBackend: (PlayerSource source, PlaybackRoute route) =>
            PlayerBackendSelector.needsFallback(source.url)
                ? PlayerBackend.libVLC
                : PlayerBackend.media3,
      );
      await ctrl.open(const PlayerSource(url: 'https://x/a.mp4'));
      expect(ctrl.backend, PlayerBackend.libVLC);
      expect(ctrl.state, PlayerState.opening);
      expect(bridge.calls, contains('open'));
      await ctrl.dispose();
    });

    test('全部后端失败 → PlayerOpenException(E_NO_BACKEND)', () async {
      final _FakeBridge bridge = _FakeBridge(
        failBackends: const <String>{'media3', 'libVLC'},
      );
      final PlayerController ctrl = PlayerController(
        bridge: bridge,
        backendChain: const <PlayerBackend>[
          PlayerBackend.media3,
          PlayerBackend.libVLC,
        ],
        selectInitialBackend: (PlayerSource source, PlaybackRoute route) =>
            PlayerBackendSelector.needsFallback(source.url)
                ? PlayerBackend.libVLC
                : PlayerBackend.media3,
      );
      await expectLater(
        ctrl.open(const PlayerSource(url: 'https://x/a.mp4')),
        throwsA(isA<PlayerOpenException>()
            .having((e) => e.code, 'code', 'E_BACKEND_UNAVAILABLE')),
      );
      expect(ctrl.backend, isNull);
      await ctrl.dispose();
    });

    test('复杂封装（.mkv）→ 初始后端直接选 libVLC', () async {
      final _FakeBridge bridge = _FakeBridge(failBackends: const <String>{});
      final PlayerController ctrl = PlayerController(
        bridge: bridge,
        backendChain: const <PlayerBackend>[
          PlayerBackend.media3,
          PlayerBackend.libVLC,
        ],
        selectInitialBackend: (PlayerSource source, PlaybackRoute route) =>
            PlayerBackendSelector.needsFallback(source.url)
                ? PlayerBackend.libVLC
                : PlayerBackend.media3,
      );
      await ctrl.open(const PlayerSource(url: 'https://x/a.mkv'));
      expect(ctrl.backend, PlayerBackend.libVLC);
      await ctrl.dispose();
    });
  });

  group('PlayerController 状态与切换', () {
    test('open 成功后 state=opening；事件流 state 事件同步转发', () async {
      final _FakeBridge bridge = _FakeBridge();
      final PlayerController ctrl = PlayerController(
        bridge: bridge,
        backendChain: const <PlayerBackend>[PlayerBackend.media3],
        selectInitialBackend: (PlayerSource source, PlaybackRoute route) => PlayerBackend.media3,
      );
      final List<PlayerState> states = <PlayerState>[];
      ctrl.onStateChanged = states.add;
      await ctrl.open(const PlayerSource(url: 'https://x/a.mp4'));
      bridge.emit(<String, Object?>{'type': 'state', 'value': 'playing'});
      bridge.emit(<String, Object?>{'type': 'state', 'value': 'paused'});
      await Future<void>.delayed(Duration.zero);
      expect(ctrl.state, PlayerState.paused);
      expect(states, <PlayerState>[PlayerState.opening, PlayerState.playing, PlayerState.paused]);
      await ctrl.dispose();
    });

    test('togglePlay：非播放态 → play；playing 态 → pause', () async {
      final _FakeBridge bridge = _FakeBridge();
      final PlayerController ctrl = PlayerController(
        bridge: bridge,
        backendChain: const <PlayerBackend>[PlayerBackend.media3],
        selectInitialBackend: (PlayerSource source, PlaybackRoute route) => PlayerBackend.media3,
      );
      await ctrl.open(const PlayerSource(url: 'https://x/a.mp4'));
      await ctrl.togglePlay(); // state=opening → play
      bridge.emit(<String, Object?>{'type': 'state', 'value': 'playing'});
      await Future<void>.delayed(Duration.zero);
      await ctrl.togglePlay(); // state=playing → pause
      expect(bridge.calls.where((String m) => m == 'play').length, 1);
      expect(bridge.calls.where((String m) => m == 'pause').length, 1);
      await ctrl.dispose();
    });

    test('未 open 时控制方法为空操作（不调通道）', () async {
      final _FakeBridge bridge = _FakeBridge();
      final PlayerController ctrl = PlayerController(
        bridge: bridge,
        backendChain: const <PlayerBackend>[PlayerBackend.media3],
        selectInitialBackend: (PlayerSource source, PlaybackRoute route) => PlayerBackend.media3,
      );
      await ctrl.play();
      await ctrl.pause();
      await ctrl.seekTo(1000);
      await ctrl.setVolume(0.5);
      await ctrl.setSpeed(1.0);
      expect(bridge.calls, isEmpty);
      await ctrl.dispose();
    });
  });

  group('PlayerController 错误转发', () {
    test('open 失败按链回退时逐级上报 onError', () async {
      final _FakeBridge bridge = _FakeBridge(failBackends: <String>{'media3'});
      final PlayerController ctrl = PlayerController(
        bridge: bridge,
        backendChain: const <PlayerBackend>[
          PlayerBackend.media3,
          PlayerBackend.libVLC,
        ],
        selectInitialBackend: (PlayerSource source, PlaybackRoute route) => PlayerBackend.media3,
      );
      final List<String> errors = <String>[];
      ctrl.onError = (String message, {required bool fatal}) {
        errors.add(message);
      };
      await ctrl.open(const PlayerSource(url: 'https://x/a.mp4'));
      expect(errors, hasLength(1));
      expect(errors.single, contains('media3'));
      await ctrl.dispose();
    });

    test('error 事件 → onError（fatal 透传）', () async {
      final _FakeBridge bridge = _FakeBridge();
      final PlayerController ctrl = PlayerController(
        bridge: bridge,
        backendChain: const <PlayerBackend>[PlayerBackend.media3],
        selectInitialBackend: (PlayerSource source, PlaybackRoute route) => PlayerBackend.media3,
      );
      await ctrl.open(const PlayerSource(url: 'https://x/a.mp4'));
      String? message;
      bool? wasFatal;
      ctrl.onError = (String m, {required bool fatal}) {
        message = m;
        wasFatal = fatal;
      };
      bridge.emit(<String, Object?>{'type': 'error', 'message': '解码失败', 'fatal': true});
      await Future<void>.delayed(Duration.zero);
      expect(message, '解码失败');
      expect(wasFatal, true);
      await ctrl.dispose();
    });
  });

  group('C-01 路由 + C-06 降级可观测', () {
    test('open 解析路由：mp4 → detail，route 对外可见', () async {
      final _FakeBridge bridge = _FakeBridge();
      final PlayerController ctrl = PlayerController(
        bridge: bridge,
        backendChain: const <PlayerBackend>[PlayerBackend.media3],
        selectInitialBackend: (PlayerSource source, PlaybackRoute route) => PlayerBackend.media3,
      );
      expect(ctrl.route, isNull);
      await ctrl.open(const PlayerSource(url: 'https://x/a.mp4'));
      expect(ctrl.route, PlaybackRoute.detail);
      await ctrl.dispose();
      expect(ctrl.route, isNull);
    });

    test('直播 FLV → 路由 live', () async {
      final _FakeBridge bridge = _FakeBridge();
      final PlayerController ctrl = PlayerController(
        bridge: bridge,
        backendChain: const <PlayerBackend>[PlayerBackend.media3],
        selectInitialBackend: (PlayerSource source, PlaybackRoute route) => PlayerBackend.media3,
      );
      await ctrl.open(const PlayerSource(url: 'https://x/stream.flv', isLive: true));
      expect(ctrl.route, PlaybackRoute.live);
      await ctrl.dispose();
    });

    test('后端回退 → onBackendFallback（from/to/reason）', () async {
      final _FakeBridge bridge = _FakeBridge(failBackends: <String>{'media3'});
      final PlayerController ctrl = PlayerController(
        bridge: bridge,
        backendChain: const <PlayerBackend>[
          PlayerBackend.media3,
          PlayerBackend.libVLC,
        ],
        selectInitialBackend: (PlayerSource source, PlaybackRoute route) => PlayerBackend.media3,
      );
      final List<(PlayerBackend, PlayerBackend, String)> falls = <(PlayerBackend, PlayerBackend, String)>[];
      ctrl.onBackendFallback = (PlayerBackend from, PlayerBackend to, String reason) {
        falls.add((from, to, reason));
      };
      await ctrl.open(const PlayerSource(url: 'https://x/a.mp4'));
      expect(falls, hasLength(1));
      expect(falls.single.$1, PlayerBackend.media3);
      expect(falls.single.$2, PlayerBackend.libVLC);
      expect(falls.single.$3, contains('media3'));
      expect(ctrl.backend, PlayerBackend.libVLC);
      await ctrl.dispose();
    });

    test('全部后端失败 → 抛 E_NO_BACKEND 且 route 清空', () async {
      final _FakeBridge bridge =
          _FakeBridge(failBackends: <String>{'media3', 'libVLC'});
      final PlayerController ctrl = PlayerController(
        bridge: bridge,
        backendChain: const <PlayerBackend>[
          PlayerBackend.media3,
          PlayerBackend.libVLC,
        ],
        selectInitialBackend: (PlayerSource source, PlaybackRoute route) => PlayerBackend.media3,
      );
      await expectLater(
        ctrl.open(const PlayerSource(url: 'https://x/a.mp4')),
        throwsA(isA<PlayerOpenException>()),
      );
      expect(ctrl.route, isNull);
      await ctrl.dispose();
    });
  });

  group('P-芯2 内核切换 / 候选线路', () {
    test('switchBackend → 以当前源在指定后端重开', () async {
      final _FakeBridge bridge = _FakeBridge();
      final PlayerController ctrl = PlayerController(
        bridge: bridge,
        backendChain: const <PlayerBackend>[
          PlayerBackend.media3,
          PlayerBackend.libVLC,
        ],
        selectInitialBackend: (PlayerSource source, PlaybackRoute route) =>
            PlayerBackend.media3,
      );
      await ctrl.open(const PlayerSource(url: 'https://x/a.mp4'));
      expect(ctrl.backend, PlayerBackend.media3);
      await ctrl.switchBackend(PlayerBackend.libVLC);
      expect(ctrl.backend, PlayerBackend.libVLC);
      expect(bridge.calls.where((String m) => m == 'open').length, 2);
      await ctrl.dispose();
    });

    test('未 open 时 switchBackend 为空操作', () async {
      final _FakeBridge bridge = _FakeBridge();
      final PlayerController ctrl = PlayerController(
        bridge: bridge,
        backendChain: const <PlayerBackend>[PlayerBackend.media3],
        selectInitialBackend: (PlayerSource source, PlaybackRoute route) =>
            PlayerBackend.media3,
      );
      await ctrl.switchBackend(PlayerBackend.libVLC);
      expect(bridge.calls, isEmpty);
      await ctrl.dispose();
    });

    test('availableBackends 暴露后端链', () {
      final PlayerController ctrl = PlayerController(
        bridge: _FakeBridge(),
        backendChain: const <PlayerBackend>[
          PlayerBackend.media3,
          PlayerBackend.libVLC,
        ],
        selectInitialBackend: (PlayerSource source, PlaybackRoute route) =>
            PlayerBackend.media3,
      );
      expect(ctrl.availableBackends,
          <PlayerBackend>[PlayerBackend.media3, PlayerBackend.libVLC]);
    });

    test('openCandidates 空 → E_NO_CANDIDATE', () async {
      final PlayerController ctrl = PlayerController(
        bridge: _FakeBridge(),
        backendChain: const <PlayerBackend>[PlayerBackend.media3],
        selectInitialBackend: (PlayerSource source, PlaybackRoute route) =>
            PlayerBackend.media3,
      );
      await expectLater(
        ctrl.openCandidates(const <PlaybackRouteCandidate>[]),
        throwsA(isA<PlayerOpenException>()
            .having((e) => e.code, 'code', 'E_NO_CANDIDATE')),
      );
      await ctrl.dispose();
    });

    test('openCandidates 取优先级最高候选打开', () async {
      final PlayerController ctrl = PlayerController(
        bridge: _FakeBridge(),
        backendChain: const <PlayerBackend>[PlayerBackend.media3],
        selectInitialBackend: (PlayerSource source, PlaybackRoute route) =>
            PlayerBackend.media3,
      );
      await ctrl.openCandidates(const <PlaybackRouteCandidate>[
        PlaybackRouteCandidate(
            route: PlaybackRoute.detail, url: 'https://x/low.mp4', priority: 0),
        PlaybackRouteCandidate(
            route: PlaybackRoute.detail, url: 'https://x/high.mp4', priority: 10),
      ]);
      expect(ctrl.route, PlaybackRoute.detail);
      expect(ctrl.lastSource?.url, 'https://x/high.mp4');
      await ctrl.dispose();
    });
  });
}
