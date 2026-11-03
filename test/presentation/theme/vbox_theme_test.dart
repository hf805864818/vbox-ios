/// 呈现层单测：主题工厂（批次 A · A-03）。
///
/// 验收：① `preferredBrightness` 逐条对齐 iOS `AppSettings.preferredColorScheme`；
/// ② 四皮肤构建的 [ThemeData] 主色与枚举一致（R-1）。纯逻辑，无 IO。
library;

import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/presentation/theme/theme.dart';

void main() {
  group('VboxTheme.preferredBrightness（对齐 iOS AppSettings）', () {
    test('跟随系统：仅 liquid 强制 dark，其余返回 null', () {
      expect(VboxTheme.preferredBrightness(VboxSkin.light, true), isNull);
      expect(VboxTheme.preferredBrightness(VboxSkin.dark, true), isNull);
      expect(VboxTheme.preferredBrightness(VboxSkin.frosted, true), isNull);
      expect(VboxTheme.preferredBrightness(VboxSkin.liquid, true), Brightness.dark);
    });

    test('不跟随系统：light→light / dark→dark / frosted→null / liquid→dark', () {
      expect(VboxTheme.preferredBrightness(VboxSkin.light, false), Brightness.light);
      expect(VboxTheme.preferredBrightness(VboxSkin.dark, false), Brightness.dark);
      expect(VboxTheme.preferredBrightness(VboxSkin.frosted, false), isNull);
      expect(VboxTheme.preferredBrightness(VboxSkin.liquid, false), Brightness.dark);
    });
  });

  group('VboxTheme.resolveBrightness', () {
    test('固定值优先；null 回退系统亮度', () {
      expect(
        VboxTheme.resolveBrightness(
          skin: VboxSkin.light,
          followsSystem: false,
          systemBrightness: Brightness.dark,
        ),
        Brightness.light,
      );
      expect(
        VboxTheme.resolveBrightness(
          skin: VboxSkin.frosted,
          followsSystem: false,
          systemBrightness: Brightness.dark,
        ),
        Brightness.dark,
      );
    });
  });

  group('VboxTheme.build（四皮肤主色 R-1）', () {
    test('四皮肤 × 明暗两态，主色与枚举一致', () {
      for (final VboxSkin skin in VboxSkin.values) {
        for (final Brightness b in Brightness.values) {
          final ThemeData theme = VboxTheme.build(skin: skin, brightness: b);
          expect(theme.useMaterial3, isTrue);
          expect(theme.brightness, b);
          expect(theme.colorScheme.brightness, b);
          expect(theme.colorScheme.primary, skin.primary);
        }
      }
    });

    test('页面底色取分组底；画布层取系统底', () {
      final ThemeData light = VboxTheme.build(
        skin: VboxSkin.light,
        brightness: Brightness.light,
      );
      expect(light.scaffoldBackgroundColor, VboxColors.secondarySystemBackgroundLight);
      expect(light.colorScheme.surface, VboxColors.systemBackgroundLight);

      final ThemeData dark = VboxTheme.build(
        skin: VboxSkin.dark,
        brightness: Brightness.dark,
      );
      expect(dark.scaffoldBackgroundColor, VboxColors.secondarySystemBackgroundDark);
      expect(dark.colorScheme.surface, VboxColors.systemBackgroundDark);
    });

    test('字体主题注入当前配色（字号档位受控）', () {
      final ThemeData theme = VboxTheme.build(
        skin: VboxSkin.light,
        brightness: Brightness.light,
      );
      expect(theme.textTheme.titleMedium?.fontSize, VboxTypography.s16);
      expect(theme.textTheme.bodyLarge?.fontSize, VboxTypography.s14);
    });
  });

  group('A2 页面转场（全端 iOS 推入）', () {
    test('六个 TargetPlatform 均采用 Cupertino 推入', () {
      final ThemeData theme = VboxTheme.build(
        skin: VboxSkin.light,
        brightness: Brightness.light,
      );
      for (final TargetPlatform p in TargetPlatform.values) {
        expect(
          theme.pageTransitionsTheme.builders[p],
          isA<CupertinoPageTransitionsBuilder>(),
          reason: '$p 应使用 Cupertino 推入（全端统一）',
        );
      }
    });
  });

  group('A3 去涟漪', () {
    test('splashFactory 为 NoSplash（无 Material 水波）', () {
      final ThemeData theme = VboxTheme.build(
        skin: VboxSkin.light,
        brightness: Brightness.light,
      );
      expect(theme.splashFactory, NoSplash.splashFactory);
    });
  });

  group('A4 开关主题（对齐 iOS UISwitch）', () {
    test('滑块恒白；轨道选中 = 皮肤主色 / 未选中 = systemGray4；描边透明', () {
      for (final VboxSkin skin in VboxSkin.values) {
        for (final Brightness b in Brightness.values) {
          final ThemeData theme = VboxTheme.build(skin: skin, brightness: b);
          final SwitchThemeData sw = theme.switchTheme;
          final bool isDark = b == Brightness.dark;

          expect(
            sw.thumbColor?.resolve(<WidgetState>{}),
            VboxColors.systemBackgroundLight,
            reason: '$skin/$b 滑块应为白',
          );
          expect(
            sw.trackColor?.resolve(<WidgetState>{WidgetState.selected}),
            skin.primary,
            reason: '$skin/$b 选中轨道应为主色',
          );
          expect(
            sw.trackColor?.resolve(<WidgetState>{}),
            isDark
                ? VboxColors.systemGray4Dark
                : VboxColors.systemGray4Light,
            reason: '$skin/$b 未选中轨道应为 systemGray4',
          );
          expect(
            sw.trackOutlineColor?.resolve(<WidgetState>{}),
            Colors.transparent,
            reason: '$skin/$b 轨道无描边（iOS 实心胶囊）',
          );
        }
      }
    });
  });

  group('A5 滚动行为（iOS 回弹）', () {
    testWidgets('物理统一 Bouncing；过卷指示器不包裹 child', (WidgetTester tester) async {
      const VboxScrollBehavior behavior = VboxScrollBehavior();
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          scrollBehavior: behavior,
          home: Builder(
            builder: (BuildContext context) {
              ctx = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      expect(behavior.getScrollPhysics(ctx), isA<BouncingScrollPhysics>());

      const Widget child = SizedBox.shrink();
      expect(
        behavior.buildOverscrollIndicator(
          ctx,
          child,
          const ScrollableDetails(direction: AxisDirection.down),
        ),
        same(child),
      );
    });
  });
}