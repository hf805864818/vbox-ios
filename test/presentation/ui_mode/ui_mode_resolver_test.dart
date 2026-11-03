/// 呈现层单测：UiFormResolver（批次 A · A-05 形态模型改造）。
///
/// 覆盖：判定优先级 ①–④（方案 §3.2 `resolveForm`）、输入模态推导（§3.4）、
/// `UiFormController` 接线（`resolveAt` 响应式 / `applyBase` 通知 /
/// `resolveWithBridge` 平台分支）。无 IO、无原生依赖。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/platform/system/system_bridge.dart';
import 'package:vbox/presentation/ui_mode/ui_mode_resolver.dart';

// ─────────────── 测试替身 ───────────────

/// 假系统桥：按注入值返回三通道结果（记录调用）。
class _FakeSystemBridge implements SystemBridge {
  _FakeSystemBridge({this.isTelevision = false});

  bool isTelevision;
  bool hasLeanback = false;
  bool hasTouch = true;
  final List<String> calls = <String>[];

  @override
  Future<bool> getUiModeType() async {
    calls.add('getUiModeType');
    return isTelevision;
  }

  @override
  Future<bool> hasLeanbackFeature() async {
    calls.add('hasLeanbackFeature');
    return hasLeanback;
  }

  @override
  Future<bool> hasTouchscreen() async {
    calls.add('hasTouchscreen');
    return hasTouch;
  }
}

/// 桌面平台探测（不触碰通道）。
const UiFormPlatform _desktop = UiFormPlatform(isDesktop: true, isAndroid: false);

/// Android 平台探测（走通道）。
const UiFormPlatform _android =
    UiFormPlatform(isDesktop: false, isAndroid: true);

/// 其余平台（iOS 等；触屏手机）。
const UiFormPlatform _ios = UiFormPlatform(isDesktop: false, isAndroid: false);

void main() {
  group('UiFormResolver.resolve —— ① 用户功能开关（最高优先）', () {
    test('override=portrait 强制竖屏（即使 TV / 大屏 / 横屏方向）', () {
      expect(
        UiFormResolver.resolve(const UiFormEnv(
          override: UiFormOverride.portrait,
          isTv: true,
          shortestSide: 1920,
          orientation: Orientation.landscape,
        )),
        UiForm.portrait,
      );
    });

    test('override=landscape 强制横屏（即使手机竖握小屏）', () {
      expect(
        UiFormResolver.resolve(const UiFormEnv(
          override: UiFormOverride.landscape,
          shortestSide: 320,
          orientation: Orientation.portrait,
        )),
        UiForm.landscape,
      );
    });

    test('override=auto 落到后续判定（手机竖屏 → portrait）', () {
      expect(
        UiFormResolver.resolve(const UiFormEnv(
          shortestSide: 390,
          orientation: Orientation.portrait,
        )),
        UiForm.portrait,
      );
    });
  });

  group('UiFormResolver.resolve —— ② 平台特征（TV / 桌面恒横屏）', () {
    test('isTv → landscape', () {
      expect(
        UiFormResolver.resolve(const UiFormEnv(
          isTv: true,
          shortestSide: 320,
          orientation: Orientation.portrait,
        )),
        UiForm.landscape,
      );
    });

    test('isDesktop → landscape', () {
      expect(
        UiFormResolver.resolve(const UiFormEnv(
          isDesktop: true,
          shortestSide: 320,
          orientation: Orientation.portrait,
        )),
        UiForm.landscape,
      );
    });
  });

  group('UiFormResolver.resolve —— ③ 窗口最短边（600dp 断点）', () {
    test('≥ 600dp → landscape（平板 / 折叠展开）', () {
      expect(
        UiFormResolver.resolve(const UiFormEnv(
          shortestSide: 600,
          orientation: Orientation.portrait,
        )),
        UiForm.landscape,
        reason: '边界：恰好 600 视为大屏',
      );
      expect(
        UiFormResolver.resolve(const UiFormEnv(
          shortestSide: 834,
          orientation: Orientation.portrait,
        )),
        UiForm.landscape,
      );
    });

    test('< 600dp → 落到方向判定', () {
      expect(
        UiFormResolver.resolve(const UiFormEnv(
          shortestSide: 599,
          orientation: Orientation.portrait,
        )),
        UiForm.portrait,
      );
    });
  });

  group('UiFormResolver.resolve —— ④ 方向（手机随方向）', () {
    test('小屏横握 → landscape；竖握 → portrait', () {
      expect(
        UiFormResolver.resolve(const UiFormEnv(
          shortestSide: 390,
          orientation: Orientation.landscape,
        )),
        UiForm.landscape,
      );
      expect(
        UiFormResolver.resolve(const UiFormEnv(
          shortestSide: 390,
          orientation: Orientation.portrait,
        )),
        UiForm.portrait,
      );
    });

    test('无任何信号 → 兜底 portrait', () {
      expect(UiFormResolver.resolve(const UiFormEnv()), UiForm.portrait);
    });
  });

  group('UiFormResolver.resolveModality —— 输入模态（§3.4）', () {
    test('TV → remote', () {
      expect(
        UiFormResolver.resolveModality(const UiFormEnv(isTv: true, hasDpad: true)),
        InputModality.remote,
      );
    });

    test('D-pad 且非触屏 → remote', () {
      expect(
        UiFormResolver.resolveModality(
            const UiFormEnv(hasDpad: true, hasTouch: false)),
        InputModality.remote,
      );
    });

    test('桌面 → mouseKeyboard', () {
      expect(
        UiFormResolver.resolveModality(const UiFormEnv(isDesktop: true)),
        InputModality.mouseKeyboard,
      );
    });

    test('指针且非触屏 → mouseKeyboard', () {
      expect(
        UiFormResolver.resolveModality(
            const UiFormEnv(hasPointer: true, hasTouch: false)),
        InputModality.mouseKeyboard,
      );
    });

    test('触屏优先（D-pad/指针并存仍为 touch）→ touch', () {
      expect(
        UiFormResolver.resolveModality(
            const UiFormEnv(hasDpad: true, hasPointer: true, hasTouch: true)),
        InputModality.touch,
      );
      expect(
        UiFormResolver.resolveModality(const UiFormEnv()),
        InputModality.touch,
      );
    });
  });

  group('UiFormController —— 基底状态与响应式解析', () {
    test('默认基底：auto / touch / portrait', () {
      final UiFormController c = UiFormController();
      expect(c.override, UiFormOverride.auto);
      expect(c.modality, InputModality.touch);
      expect(
        c.resolveAt(size: const Size(390, 844), orientation: Orientation.portrait),
        UiForm.portrait,
      );
    });

    test('resolveAt 不改控制器状态、不通知监听者', () {
      final UiFormController c = UiFormController();
      int notified = 0;
      c.addListener(() => notified++);

      expect(
        c.resolveAt(size: const Size(1280, 720), orientation: Orientation.landscape),
        UiForm.landscape,
      );
      expect(c.env.shortestSide, 0, reason: '视口不驻留状态');
      expect(notified, 0);
    });

    test('applyBase 更新并通知一次', () {
      final UiFormController c = UiFormController();
      int notified = 0;
      c.addListener(() => notified++);

      c.applyBase(const UiFormEnv(isTv: true, hasDpad: true, hasTouch: false));
      expect(c.modality, InputModality.remote);
      expect(
        c.resolveAt(size: const Size(320, 480), orientation: Orientation.portrait),
        UiForm.landscape,
        reason: 'TV 恒横屏（无视视口）',
      );
      expect(notified, 1);
    });

    test('setOverride 仅改覆盖档，保留设备能力', () {
      final UiFormController c = UiFormController();
      c.applyBase(const UiFormEnv(isTv: true, hasDpad: true, hasTouch: false));
      int notified = 0;
      c.addListener(() => notified++);

      c.setOverride(UiFormOverride.portrait);
      expect(c.override, UiFormOverride.portrait);
      expect(c.env.isTv, isTrue);
      expect(c.modality, InputModality.remote, reason: '设备能力不变');
      expect(
        c.resolveAt(size: const Size(1920, 1080), orientation: Orientation.landscape),
        UiForm.portrait,
        reason: '覆盖档最高优先',
      );
      expect(notified, 1);
    });
  });

  group('UiFormController.resolveWithBridge —— 平台分支', () {
    test('桌面平台 → 不触碰通道；landscape / mouseKeyboard', () async {
      final _FakeSystemBridge bridge = _FakeSystemBridge(isTelevision: true);
      final UiFormController c = UiFormController();

      await c.resolveWithBridge(bridge, platform: _desktop);

      expect(bridge.calls, isEmpty, reason: '桌面端走编译期常量兜底');
      expect(c.env.isDesktop, isTrue);
      expect(c.modality, InputModality.mouseKeyboard);
      expect(
        c.resolveAt(size: const Size(320, 480), orientation: Orientation.portrait),
        UiForm.landscape,
      );
    });

    test('Android TV（系统 UI Mode 命中）→ landscape / remote + 通知一次', () async {
      final _FakeSystemBridge bridge = _FakeSystemBridge(isTelevision: true);
      final UiFormController c = UiFormController();
      int notified = 0;
      c.addListener(() => notified++);

      await c.resolveWithBridge(bridge, platform: _android);

      expect(bridge.calls, contains('getUiModeType'));
      expect(bridge.calls, contains('hasTouchscreen'));
      expect(c.env.isTv, isTrue);
      expect(c.modality, InputModality.remote);
      expect(
        c.resolveAt(size: const Size(1920, 1080), orientation: Orientation.landscape),
        UiForm.landscape,
      );
      expect(notified, 1);
    });

    test('Android TV（Leanback 兜底，getUiModeType 未命中）', () async {
      final _FakeSystemBridge bridge = _FakeSystemBridge()
        ..hasLeanback = true
        ..hasTouch = false;

      final UiFormController c = UiFormController();
      await c.resolveWithBridge(bridge, platform: _android);

      expect(bridge.calls, <String>['getUiModeType', 'hasLeanbackFeature', 'hasTouchscreen']);
      expect(c.env.isTv, isTrue);
      expect(c.modality, InputModality.remote);
    });

    test('Android 触屏手机 → portrait / touch', () async {
      final _FakeSystemBridge bridge = _FakeSystemBridge();
      final UiFormController c = UiFormController();

      await c.resolveWithBridge(bridge, platform: _android);

      expect(c.env.isTv, isFalse);
      expect(c.modality, InputModality.touch);
      expect(
        c.resolveAt(size: const Size(390, 844), orientation: Orientation.portrait),
        UiForm.portrait,
      );
    });

    test('其余平台（iOS）→ 不触碰通道；触屏手机', () async {
      final _FakeSystemBridge bridge = _FakeSystemBridge();
      final UiFormController c = UiFormController();

      await c.resolveWithBridge(bridge, platform: _ios);

      expect(bridge.calls, isEmpty);
      expect(c.env.isTv, isFalse);
      expect(c.modality, InputModality.touch);
    });

    test('注入覆盖档 + 屏幕尺寸（真机接线口径）', () async {
      final _FakeSystemBridge bridge = _FakeSystemBridge();
      final UiFormController c = UiFormController();

      await c.resolveWithBridge(
        bridge,
        platform: _android,
        override: UiFormOverride.landscape,
        screenSize: const Size(390, 844),
      );

      expect(c.override, UiFormOverride.landscape);
      expect(c.env.shortestSide, 390);
      expect(
        c.resolveAt(size: const Size(390, 844), orientation: Orientation.portrait),
        UiForm.landscape,
      );
    });
  });
}