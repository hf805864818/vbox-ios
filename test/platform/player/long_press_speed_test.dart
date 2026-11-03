/// 批次 C · C-05：LongPressSpeedController 长按倍速（纯 Dart）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/platform/player/pip/long_press_speed.dart';

void main() {
  group('LongPressSpeedController', () {
    test('begin → 记录当前倍速并切到长按倍速', () async {
      double current = 1.0;
      double? sent;
      final LongPressSpeedController c = LongPressSpeedController(
        longPressSpeed: 2.0,
        currentSpeed: () => current,
        setSpeed: (double s) async => sent = s,
      );
      await c.begin();
      expect(sent, 2.0);
      expect(c.isActive, isTrue);
    });

    test('end → 恢复按下前的倍速', () async {
      double current = 1.5;
      double? sent;
      final LongPressSpeedController c = LongPressSpeedController(
        longPressSpeed: 2.0,
        currentSpeed: () => current,
        setSpeed: (double s) async => sent = s,
      );
      await c.begin();
      expect(sent, 2.0);
      current = 1.0;
      await c.end();
      expect(sent, 1.5); // 恢复 begin 时刻的 1.5，而非 end 时刻的 current
      expect(c.isActive, isFalse);
    });

    test('enabled 判定：≤1.0 视为未启用', () {
      final LongPressSpeedController disabled = LongPressSpeedController(
        longPressSpeed: 1.0,
        currentSpeed: () => 1.0,
        setSpeed: (double s) async {},
      );
      final LongPressSpeedController normal = LongPressSpeedController(
        longPressSpeed: 2.0,
        currentSpeed: () => 1.0,
        setSpeed: (double s) async {},
      );
      expect(disabled.enabled, isFalse);
      expect(normal.enabled, isTrue);
    });

    test('未启用 → begin/end 均 no-op', () async {
      double? sent;
      final LongPressSpeedController c = LongPressSpeedController(
        longPressSpeed: 1.0,
        currentSpeed: () => 1.0,
        setSpeed: (double s) async => sent = s,
      );
      await c.begin();
      await c.end();
      expect(sent, isNull);
      expect(c.isActive, isFalse);
    });

    test('重复 begin 幂等（不重复下发）', () async {
      int sentCount = 0;
      final LongPressSpeedController c = LongPressSpeedController(
        longPressSpeed: 2.0,
        currentSpeed: () => 1.0,
        setSpeed: (double s) async => sentCount++,
      );
      await c.begin();
      await c.begin();
      expect(sentCount, 1);
      expect(c.isActive, isTrue);
    });

    test('未激活时 end no-op', () async {
      double? sent;
      final LongPressSpeedController c = LongPressSpeedController(
        longPressSpeed: 2.0,
        currentSpeed: () => 1.0,
        setSpeed: (double s) async => sent = s,
      );
      await c.end();
      expect(sent, isNull);
    });
  });
}
