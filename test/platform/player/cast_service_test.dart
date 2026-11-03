/// C-09 投屏抽象单测：设备解析 / 会话流转 / 降级 / 通道桥。
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:vbox/platform/player/cast/cast_service.dart';

/// 内存假桥：记录调用、可注入返回与事件流。
class FakeCastBridge implements CastChannelBridge {
  final List<(String, Object?)> calls = <(String, Object?)>[];
  final StreamController<Map<String, Object?>> _events =
      StreamController<Map<String, Object?>>.broadcast();

  Object? Function(String method, Object? arguments)? onInvoke;

  @override
  Future<Object?> invoke(String method, [Object? arguments]) async {
    calls.add((method, arguments));
    final Object? Function(String, Object?)? handler = onInvoke;
    if (handler != null) return handler(method, arguments);
    return true;
  }

  @override
  Stream<Map<String, Object?>> events() => _events.stream;

  void push(Map<String, Object?> e) => _events.add(e);

  @override
  Future<void> dispose() async {}
}

void main() {
  group('CastDevice', () {
    test('wire 往返', () {
      const CastDevice d = CastDevice(
        id: 'dev-1',
        name: '客厅电视',
        kind: CastDeviceKind.dlna,
      );
      final CastDevice parsed = CastDevice.fromJson(d.toJson());
      expect(parsed.id, 'dev-1');
      expect(parsed.name, '客厅电视');
      expect(parsed.kind, CastDeviceKind.dlna);
    });

    test('kind 宽松解码', () {
      expect(
        CastDevice.fromJson(<String, Object?>{
          'id': 'a',
          'name': 'b',
          'kind': 'airplay',
        }).kind,
        CastDeviceKind.airplay,
      );
      expect(
        CastDevice.fromJson(<String, Object?>{'id': 'a', 'name': 'b'}).kind,
        CastDeviceKind.unknown,
      );
    });
  });

  group('CastSession', () {
    test('isActive 判定', () {
      const CastSession idle = CastSession();
      const CastSession playing =
          CastSession(state: CastSessionState.playing, device: CastDevice(id: 'd', name: 'n'));
      expect(idle.isActive, isFalse);
      expect(playing.isActive, isTrue);
    });

    test('copyWith 局部覆盖', () {
      const CastSession s = CastSession(device: CastDevice(id: 'd', name: 'n'));
      final CastSession next = s.copyWith(state: CastSessionState.paused);
      expect(next.state, CastSessionState.paused);
      expect(next.device?.id, 'd');
    });

    test('fromJson 宽松', () {
      final CastSession s = CastSession.fromJson(<String, Object?>{
        'device': <String, Object?>{'id': 'd', 'name': 'n', 'kind': 'dlna'},
        'state': 'playing',
        'title': '我的姐姐',
        'positionMs': 1234,
        'durationMs': 60000,
        'isLive': true,
      });
      expect(s.device?.kind, CastDeviceKind.dlna);
      expect(s.state, CastSessionState.playing);
      expect(s.title, '我的姐姐');
      expect(s.positionMs, 1234);
      expect(s.isLive, isTrue);
    });
  });

  group('NoopCastService', () {
    test('不可用且全降级', () async {
      final NoopCastService s = NoopCastService();
      expect(s.isAvailable, isFalse);
      expect(s.session, isNull);
      expect(await s.discover(), isEmpty);
      expect(await s.connect(const CastDevice(id: 'd', name: 'n')), isFalse);
      expect(await s.cast(const CastMedia(url: 'http://x/1.m3u8')), isFalse);
      await s.play();
      await s.pause();
      await s.seekTo(0);
      await s.setVolume(0.5);
      await s.stop();
      await s.disconnect();
    });
  });

  group('MethodChannelCastService', () {
    test('discover 解析设备列表并置可用', () async {
      final FakeCastBridge bridge = FakeCastBridge();
      bridge.onInvoke = (String method, Object? _) {
        if (method == 'discover') {
          return <Object?>[
            <String, Object?>{'id': '1', 'name': 'A', 'kind': 'dlna'},
            <String, Object?>{'id': '2', 'name': 'B'},
          ];
        }
        return true;
      };
      final MethodChannelCastService s = MethodChannelCastService(bridge: bridge);
      final List<CastDevice> devices = await s.discover();
      expect(devices.length, 2);
      expect(devices[0].kind, CastDeviceKind.dlna);
      expect(devices[1].kind, CastDeviceKind.unknown);
      expect(s.isAvailable, isTrue);
    });

    test('discover 抛 PlatformException → 不可用 + 空列表', () async {
      final FakeCastBridge bridge = FakeCastBridge();
      bridge.onInvoke = (String method, Object? _) {
        throw PlatformException(code: 'E_UNAVAILABLE', message: 'no cast');
      };
      final MethodChannelCastService s = MethodChannelCastService(bridge: bridge);
      expect(await s.discover(), isEmpty);
      expect(s.isAvailable, isFalse);
    });

    test('connect → cast 会话流转', () async {
      final FakeCastBridge bridge = FakeCastBridge();
      final MethodChannelCastService s = MethodChannelCastService(bridge: bridge);
      CastSession? last;
      s.onSessionChanged = (CastSession session) => last = session;

      expect(await s.connect(const CastDevice(id: 'd', name: '电视')), isTrue);
      expect(last?.state, CastSessionState.connecting);
      expect(s.session?.device?.id, 'd');

      expect(
        await s.cast(const CastMedia(url: 'http://x/1.m3u8', title: '片名')),
        isTrue,
      );
      expect(last?.state, CastSessionState.playing);
      expect(last?.title, '片名');

      await s.disconnect();
      expect(s.session, isNull);
      expect(last?.state, CastSessionState.disconnected);

      // 方法调用序列
      expect(
        bridge.calls.map(((String, Object?) c) => c.$1).toList(),
        containsAll(<String>['connect', 'cast', 'disconnect']),
      );
    });

    test('事件流：session / devices 更新', () async {
      final FakeCastBridge bridge = FakeCastBridge();
      final MethodChannelCastService s = MethodChannelCastService(bridge: bridge);
      final List<CastSession> sessions = <CastSession>[];
      s.onSessionChanged = sessions.add;

      bridge.push(<String, Object?>{
        'type': 'session',
        'value': <String, Object?>{
          'device': <String, Object?>{'id': 'd', 'name': 'n'},
          'state': 'paused',
          'positionMs': 500,
        },
      });
      await Future<void>.delayed(Duration.zero);
      expect(sessions.length, 1);
      expect(sessions[0].state, CastSessionState.paused);
      expect(s.session?.positionMs, 500);
    });

    test('控制方法失败不抛异常', () async {
      final FakeCastBridge bridge = FakeCastBridge();
      bridge.onInvoke = (String method, Object? _) {
        throw PlatformException(code: 'E_CTRL', message: 'fail');
      };
      final MethodChannelCastService s = MethodChannelCastService(bridge: bridge);
      await s.play();
      await s.pause();
      await s.seekTo(1000);
      await s.setVolume(0.3);
      await s.stop();
      expect(s.isAvailable, isFalse);
    });
  });
}
