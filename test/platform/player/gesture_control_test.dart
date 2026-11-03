/// 第 3 批 · UI-F1：视频区手势状态机 + 屏幕控制桥（亮度 / 音量 / 快进快退）。
library;

import 'dart:ui' show Offset, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/platform/player/gesture/gesture_control.dart';
import 'package:vbox/platform/player/gesture/screen_controls.dart';

/// 记录调用的假桥。
class _FakeScreen implements ScreenControlsBridge {
  _FakeScreen({this.brightness = 0.5, this.volume = 0.5});

  double brightness;
  double volume;
  int brightnessWrites = 0;
  int volumeWrites = 0;

  @override
  Future<double> getBrightness() async => brightness;

  @override
  Future<void> setBrightness(double value) async {
    brightness = value;
    brightnessWrites++;
  }

  @override
  Future<double> getVolume() async => volume;

  @override
  Future<void> setVolume(double value) async {
    volume = value;
    volumeWrites++;
  }
}

void main() {
  group('ScreenControlsBridge（UI-F1）', () {
    test('clamp01 钳制到 0 ~ 1', () {
      expect(clamp01(-1), 0);
      expect(clamp01(0.42), 0.42);
      expect(clamp01(3), 1);
    });

    test('Session 实现维持内存值并钳制', () async {
      final SessionScreenControlsBridge b = SessionScreenControlsBridge();
      expect(await b.getBrightness(), 0.5);
      await b.setBrightness(0.8);
      expect(await b.getBrightness(), 0.8);
      await b.setVolume(2);
      expect(await b.getVolume(), 1);
    });
  });

  group('PlayerGestureController 模式判定（UI-F1）', () {
    test('位移不足最小距离不激活', () async {
      final PlayerGestureController g =
          PlayerGestureController(screen: _FakeScreen());
      g.begin(
        localPosition: const Offset(10, 10),
        viewport: const Size(400, 800),
        landscape: false,
        positionMs: 0,
        durationMs: 100000,
      );
      expect(await g.update(const Offset(5, 5)), isNull);
      expect(g.isActive, isFalse);
    });

    test('左半屏纵滑 → 亮度；上滑增大', () async {
      final _FakeScreen screen = _FakeScreen(brightness: 0.5);
      final PlayerGestureController g =
          PlayerGestureController(screen: screen);
      g.begin(
        localPosition: const Offset(100, 400),
        viewport: const Size(400, 800),
        landscape: false,
        positionMs: 0,
        durationMs: 100000,
      );
      final GestureAdjustment? adj = await g.update(const Offset(0, -100));
      expect(adj, isNotNull);
      expect(adj!.mode, GestureMode.brightness);
      // sensitivity = clamp(800/700, 0.45, 0.9) = 0.9 → delta = 100/800*0.9 = 0.1125
      expect(adj.brightness, closeTo(0.6125, 1e-9));
      expect(screen.brightness, closeTo(0.6125, 1e-9));
      expect(screen.brightnessWrites, 1);
    });

    test('右半屏纵滑 → 音量；下滑减小并钳制 0', () async {
      final _FakeScreen screen = _FakeScreen(volume: 0.2);
      final PlayerGestureController g =
          PlayerGestureController(screen: screen);
      g.begin(
        localPosition: const Offset(300, 400),
        viewport: const Size(400, 800),
        landscape: false,
        positionMs: 0,
        durationMs: 100000,
      );
      final GestureAdjustment? adj = await g.update(const Offset(0, 500));
      expect(adj, isNotNull);
      expect(adj!.mode, GestureMode.volume);
      expect(adj.volume, 0);
      expect(screen.volume, 0);
    });

    test('横屏横滑 → seek；按 duration×0.12 换算', () async {
      final PlayerGestureController g =
          PlayerGestureController(screen: _FakeScreen());
      g.begin(
        localPosition: const Offset(400, 200),
        viewport: const Size(800, 400),
        landscape: true,
        positionMs: 100000,
        durationMs: 1000000,
      );
      final GestureAdjustment? adj = await g.update(const Offset(400, 20));
      expect(adj, isNotNull);
      expect(adj!.mode, GestureMode.seek);
      // max = clamp(1000×0.12, 60, 300) = 120s；delta = 400/800×120 = 60s
      expect(adj.seekSeconds, closeTo(160, 1e-6));
      expect(g.seekTargetMs, 160000);
      expect(adj.label, '02:40 / 16:40');
    });

    test('竖屏横滑不 seek，回落半屏亮/音分派', () async {
      final PlayerGestureController g =
          PlayerGestureController(screen: _FakeScreen());
      g.begin(
        localPosition: const Offset(100, 400),
        viewport: const Size(400, 800),
        landscape: false,
        positionMs: 0,
        durationMs: 100000,
      );
      final GestureAdjustment? adj = await g.update(const Offset(200, 5));
      expect(adj, isNotNull);
      expect(adj!.mode, GestureMode.brightness);
    });

    test('零视口（面板打开守卫）→ 全程 no-op', () async {
      final PlayerGestureController g =
          PlayerGestureController(screen: _FakeScreen());
      g.begin(
        localPosition: const Offset(100, 400),
        viewport: Size.zero,
        landscape: false,
        positionMs: 0,
        durationMs: 100000,
      );
      expect(await g.update(const Offset(0, -200)), isNull);
    });

    test('end：seek 提交目标；亮度/音量返回 null', () async {
      final PlayerGestureController g =
          PlayerGestureController(screen: _FakeScreen());
      g.begin(
        localPosition: const Offset(400, 200),
        viewport: const Size(800, 400),
        landscape: true,
        positionMs: 100000,
        durationMs: 1000000,
      );
      await g.update(const Offset(-200, 10));
      // delta = -200/800×120 = -30s → 70s
      expect(g.end(), 70000);
      // 手势结束已复位
      expect(g.mode, GestureMode.ignored);

      g.begin(
        localPosition: const Offset(100, 400),
        viewport: const Size(400, 800),
        landscape: false,
        positionMs: 0,
        durationMs: 100000,
      );
      await g.update(const Offset(0, -50));
      expect(g.end(), isNull);
    });

    test('load 读取初值', () async {
      final PlayerGestureController g = PlayerGestureController(
        screen: _FakeScreen(brightness: 0.33, volume: 0.66),
      );
      await g.load();
      expect(g.brightness, closeTo(0.33, 1e-9));
      expect(g.volume, closeTo(0.66, 1e-9));
    });
  });
}
