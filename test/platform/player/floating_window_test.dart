/// C-09 浮窗抽象单测：快照流转 / 降级 / 通道桥。
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/platform/player/floating/floating_window.dart';

/// 内存假桥：记录调用、可注入返回与事件流。
class FakeFloatingBridge implements FloatingWindowBridge {
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
  group('FloatingWindowInfo', () {
    test('isVisible 判定', () {
      const FloatingWindowInfo hidden = FloatingWindowInfo();
      const FloatingWindowInfo visible = FloatingWindowInfo(state: FloatingWindowState.playing);
      expect(hidden.isVisible, isFalse);
      expect(visible.isVisible, isTrue);
    });

    test('fromJson 宽松', () {
      final FloatingWindowInfo i = FloatingWindowInfo.fromJson(<String, Object?>{
        'state': 'playing',
        'title': '直播',
        'positionMs': 999,
        'isLive': true,
      });
      expect(i.state, FloatingWindowState.playing);
      expect(i.title, '直播');
      expect(i.positionMs, 999);
      expect(i.isLive, isTrue);
    });
  });

  group('NoopFloatingWindow', () {
    test('不可用且全降级', () async {
      final NoopFloatingWindow w = NoopFloatingWindow();
      expect(w.isAvailable, isFalse);
      expect(w.info.isVisible, isFalse);
      expect(await w.show(), isFalse);
      await w.hide();
      await w.setMedia(title: 'x');
      await w.updateProgress(1, 2);
      await w.dispose();
    });
  });

  group('MethodChannelFloatingWindow', () {
    test('show 成功 → visible + 置可用', () async {
      final FakeFloatingBridge bridge = FakeFloatingBridge();
      final MethodChannelFloatingWindow w =
          MethodChannelFloatingWindow(bridge: bridge);
      FloatingWindowInfo? last;
      w.onChanged = (FloatingWindowInfo i) => last = i;

      expect(await w.show(width: 320, height: 180), isTrue);
      expect(w.isAvailable, isTrue);
      expect(w.info.isVisible, isTrue);
      expect(last?.state, FloatingWindowState.visible);
      expect(
        bridge.calls.map(((String, Object?) c) => c.$1).toList(),
        contains('show'),
      );
    });

    test('show 抛 PlatformException → 不可用', () async {
      final FakeFloatingBridge bridge = FakeFloatingBridge();
      bridge.onInvoke = (String method, Object? _) {
        throw PlatformException(code: 'E_UNAVAILABLE', message: 'no pip');
      };
      final MethodChannelFloatingWindow w =
          MethodChannelFloatingWindow(bridge: bridge);
      expect(await w.show(), isFalse);
      expect(w.isAvailable, isFalse);
    });

    test('setMedia / updateProgress 本地同步 + 事件上报', () async {
      final FakeFloatingBridge bridge = FakeFloatingBridge();
      final MethodChannelFloatingWindow w =
          MethodChannelFloatingWindow(bridge: bridge);
      final List<FloatingWindowInfo> infos = <FloatingWindowInfo>[];
      w.onChanged = infos.add;

      await w.setMedia(title: '直播', isLive: true);
      await w.updateProgress(5000, 0);
      expect(w.info.title, '直播');
      expect(w.info.isLive, isTrue);
      expect(w.info.positionMs, 5000);
      expect(infos.length, 2);

      await w.hide();
      expect(w.info.isVisible, isFalse);
    });

    test('原生 info 事件驱动更新', () async {
      final FakeFloatingBridge bridge = FakeFloatingBridge();
      final MethodChannelFloatingWindow w =
          MethodChannelFloatingWindow(bridge: bridge);
      final List<FloatingWindowInfo> infos = <FloatingWindowInfo>[];
      w.onChanged = infos.add;

      bridge.push(<String, Object?>{
        'type': 'info',
        'value': <String, Object?>{'state': 'paused', 'positionMs': 1200},
      });
      await Future<void>.delayed(Duration.zero);
      expect(infos.length, 1);
      expect(infos[0].state, FloatingWindowState.paused);
      expect(w.info.positionMs, 1200);
    });

    test('dispose 幂等释放', () async {
      final FakeFloatingBridge bridge = FakeFloatingBridge();
      final MethodChannelFloatingWindow w =
          MethodChannelFloatingWindow(bridge: bridge);
      await w.show();
      await w.dispose();
      expect(w.info.isVisible, isFalse);
      expect(
        bridge.calls.map(((String, Object?) c) => c.$1).toList(),
        contains('dispose'),
      );
    });
  });
}
