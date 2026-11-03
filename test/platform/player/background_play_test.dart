/// 批次 C · C-05：BackgroundPlayController 后台播放（纯 Dart）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/platform/player/pip/background_play.dart';
import 'package:vbox/platform/player/pip/pip_lifecycle.dart';

/// 内存假桥：记录调用与激活态。
class FakeBackgroundBridge implements BackgroundPlayBridge {
  final List<String> calls = <String>[];
  bool active = false;

  @override
  bool get isActive => active;

  @override
  Future<void> start() async {
    calls.add('start');
    active = true;
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
    active = false;
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  group('PlaybackLifecycle.fromAppStateName', () {
    test('后台态归一 background', () {
      for (final String n in <String>['inactive', 'hidden', 'paused', 'detached']) {
        expect(PlaybackLifecycle.fromAppStateName(n), PlaybackLifecycle.background);
      }
    });

    test('前台态（含未知）归一 foreground', () {
      expect(PlaybackLifecycle.fromAppStateName('resumed'), PlaybackLifecycle.foreground);
      expect(PlaybackLifecycle.fromAppStateName('unknown'), PlaybackLifecycle.foreground);
    });
  });

  group('BackgroundPlayController.handleLifecycle', () {
    test('后台 + 开启 + 播放中 → 启动承载', () async {
      final FakeBackgroundBridge bridge = FakeBackgroundBridge();
      final BackgroundPlayController c = BackgroundPlayController(
        enabled: true,
        bridge: bridge,
      );
      await c.handleLifecycle(PlaybackLifecycle.background, isPlaying: true);
      expect(bridge.calls, contains('start'));
      expect(c.isActive, isTrue);
    });

    test('后台 + 关闭 → 不启动', () async {
      final FakeBackgroundBridge bridge = FakeBackgroundBridge();
      final BackgroundPlayController c = BackgroundPlayController(
        enabled: false,
        bridge: bridge,
      );
      await c.handleLifecycle(PlaybackLifecycle.background, isPlaying: true);
      expect(bridge.calls, isEmpty);
    });

    test('后台 + 暂停中 → 不启动（防后台驻留）', () async {
      final FakeBackgroundBridge bridge = FakeBackgroundBridge();
      final BackgroundPlayController c = BackgroundPlayController(
        enabled: true,
        bridge: bridge,
      );
      await c.handleLifecycle(PlaybackLifecycle.background, isPlaying: false);
      expect(bridge.calls, isEmpty);
    });

    test('已激活时重复后台 → 幂等不重复启动', () async {
      final FakeBackgroundBridge bridge = FakeBackgroundBridge();
      final BackgroundPlayController c = BackgroundPlayController(
        enabled: true,
        bridge: bridge,
      );
      await c.handleLifecycle(PlaybackLifecycle.background, isPlaying: true);
      await c.handleLifecycle(PlaybackLifecycle.background, isPlaying: true);
      expect(bridge.calls.where((String x) => x == 'start').length, 1);
    });

    test('回前台 → 停止承载', () async {
      final FakeBackgroundBridge bridge = FakeBackgroundBridge();
      final BackgroundPlayController c = BackgroundPlayController(
        enabled: true,
        bridge: bridge,
      );
      await c.handleLifecycle(PlaybackLifecycle.background, isPlaying: true);
      expect(c.isActive, isTrue);
      await c.handleLifecycle(PlaybackLifecycle.foreground, isPlaying: true);
      expect(bridge.calls, contains('stop'));
      expect(c.isActive, isFalse);
    });

    test('运行中可动态开关', () async {
      final FakeBackgroundBridge bridge = FakeBackgroundBridge();
      final BackgroundPlayController c = BackgroundPlayController(
        enabled: false,
        bridge: bridge,
      );
      await c.handleLifecycle(PlaybackLifecycle.background, isPlaying: true);
      expect(bridge.calls, isEmpty);
      c.enabled = true;
      await c.handleLifecycle(PlaybackLifecycle.background, isPlaying: true);
      expect(bridge.calls, contains('start'));
    });
  });

  group('NoopBackgroundPlayBridge', () {
    test('恒非激活且 start/stop no-op', () async {
      final NoopBackgroundPlayBridge bridge = NoopBackgroundPlayBridge();
      await bridge.start();
      expect(bridge.isActive, isFalse);
      await bridge.stop();
      expect(bridge.isActive, isFalse);
    });
  });
}
