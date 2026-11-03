/// 形态模型单测：`ui_mode_resolver.dart` 的枚举与输入结构（批次 A · A-05）。
///
/// 覆盖：`UiForm` 便捷谓词、`UiFormOverride` 契约字符串解析（含未知值兜底）、
/// `UiFormEnv.withViewport` 的视口注入语义。纯数据，无 IO。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/presentation/ui_mode/ui_mode_resolver.dart';

void main() {
  group('UiForm 便捷谓词', () {
    test('isPortrait / isLandscape 互斥且完备', () {
      expect(UiForm.portrait.isPortrait, isTrue);
      expect(UiForm.portrait.isLandscape, isFalse);
      expect(UiForm.landscape.isLandscape, isTrue);
      expect(UiForm.landscape.isPortrait, isFalse);
      expect(UiForm.values.length, 2, reason: '本轮收敛为双形态');
    });
  });

  group('InputModality 取值', () {
    test('三模态齐备（触摸 / 遥控 / 鼠标键盘）', () {
      expect(InputModality.values, <InputModality>[
        InputModality.touch,
        InputModality.remote,
        InputModality.mouseKeyboard,
      ]);
    });
  });

  group('UiFormOverride.fromId（契约键 app_ui_form_override 解析）', () {
    test('三个合法档位逐一解析', () {
      expect(UiFormOverride.fromId('auto'), UiFormOverride.auto);
      expect(UiFormOverride.fromId('portrait'), UiFormOverride.portrait);
      expect(UiFormOverride.fromId('landscape'), UiFormOverride.landscape);
    });

    test('未知值 / null / 空串 → 回退 auto（契约默认）', () {
      expect(UiFormOverride.fromId('tablet'), UiFormOverride.auto);
      expect(UiFormOverride.fromId(''), UiFormOverride.auto);
      expect(UiFormOverride.fromId(null), UiFormOverride.auto);
      expect(UiFormOverride.fallback, UiFormOverride.auto);
    });

    test('id 与 title 齐备（设置项显示名）', () {
      for (final UiFormOverride o in UiFormOverride.values) {
        expect(o.id, isNotEmpty);
        expect(o.title, isNotEmpty);
      }
      expect(UiFormOverride.portrait.title, '手机（竖屏）');
      expect(UiFormOverride.landscape.title, '大屏（横屏）');
    });
  });

  group('UiFormEnv.withViewport（视口注入语义）', () {
    test('更新最短边与方向，保留设备能力与用户覆盖', () {
      const UiFormEnv base = UiFormEnv(
        override: UiFormOverride.landscape,
        isTv: true,
        isDesktop: false,
        hasTouch: false,
        hasDpad: true,
        hasPointer: false,
        shortestSide: 0,
        orientation: Orientation.portrait,
      );

      final UiFormEnv v = base.withViewport(
        size: const Size(1920, 1080),
        orientation: Orientation.landscape,
      );

      expect(v.shortestSide, 1080);
      expect(v.orientation, Orientation.landscape);
      // 基底字段保持不变
      expect(v.override, UiFormOverride.landscape);
      expect(v.isTv, isTrue);
      expect(v.hasDpad, isTrue);
      expect(v.hasTouch, isFalse);
    });

    test('默认基底最短边为 0、方向竖屏（未注入视口）', () {
      const UiFormEnv e = UiFormEnv();
      expect(e.shortestSide, 0);
      expect(e.orientation, Orientation.portrait);
      expect(e.override, UiFormOverride.auto);
      expect(e.hasTouch, isTrue);
    });
  });
}