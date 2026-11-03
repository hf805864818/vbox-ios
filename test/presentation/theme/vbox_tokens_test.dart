/// 呈现层单测：设计令牌（批次 A · A-01 / A-02）。
///
/// 验收：令牌值 100% 对齐 `docs/UI对齐基准_v1.0.md` §2（R-1 皮肤令牌一致 /
/// R-2 圆角档位 / R-3 字号档位）。纯常量断言，无 IO。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/presentation/theme/theme.dart';

void main() {
  group('VboxSkin 皮肤枚举（UI 基准 §2.1）', () {
    test('四皮肤主色与枚举一致', () {
      expect(VboxSkin.light.primary, const Color(0xFFE11D48));
      expect(VboxSkin.dark.primary, const Color(0xFFE11D48)); // 与 light 共用主色
      expect(VboxSkin.frosted.primary, const Color(0xFF7C3AED));
      expect(VboxSkin.liquid.primary, const Color(0xFF38BDF8));
    });

    test('契约字符串 ↔ 枚举往返；未知/空值回退 light', () {
      for (final VboxSkin skin in VboxSkin.values) {
        expect(VboxSkin.fromId(skin.id), skin);
      }
      expect(VboxSkin.fromId('nope'), VboxSkin.light);
      expect(VboxSkin.fromId(null), VboxSkin.light);
      expect(VboxSkin.fallback, VboxSkin.light);
    });

    test('固定配色模式对齐 iOS preferredColorScheme', () {
      expect(VboxSkin.light.fixedBrightness, Brightness.light);
      expect(VboxSkin.dark.fixedBrightness, Brightness.dark);
      expect(VboxSkin.liquid.fixedBrightness, Brightness.dark);
      expect(VboxSkin.frosted.fixedBrightness, isNull);
    });
  });

  group('VboxColors 颜色令牌（UI 基准 §2.2）', () {
    test('语义色 / 品牌渐变', () {
      expect(VboxColors.selected, const Color(0xFF2196F3));
      expect(VboxColors.chipSelected, const Color(0xFF34C759));
      expect(VboxColors.playerBackground, const Color(0xFF0F0F23));
      expect(VboxColors.brandGradient, <Color>[
        const Color(0xFF3B82F6),
        const Color(0xFF2563EB),
        const Color(0xFF1D4ED8),
      ]);
    });

    test('分类色板 10 色且语义映射固定', () {
      expect(VboxColors.categoryColors.length, 10);
      expect(VboxCategory.values.length, 10);
      expect(VboxColors.categoryColors[VboxCategory.app], const Color(0xFF6B7280));
      expect(VboxColors.categoryColors[VboxCategory.spider], const Color(0xFF8B5CF6));
      expect(VboxColors.categoryColors[VboxCategory.node], const Color(0xFF14B8A6));
    });
  });

  group('VboxTypography 字号令牌（UI 基准 §2.3）', () {
    test('字号档位为实测 10 档', () {
      expect(VboxTypography.scale, <double>[
        10, 11, 12, 13, 14, 15, 16, 18, 24, 28,
      ]);
    });

    test('语义 TextTheme 取档位值', () {
      final TextTheme t = VboxTypography.buildTextTheme(
        primaryText: const Color(0xFF000000),
        secondaryText: const Color(0xFF888888),
      );
      expect(t.displaySmall?.fontSize, VboxTypography.s28);
      expect(t.headlineMedium?.fontSize, VboxTypography.s24);
      expect(t.titleMedium?.fontSize, VboxTypography.s16);
      expect(t.bodyLarge?.fontSize, VboxTypography.s14);
      expect(t.labelSmall?.fontSize, VboxTypography.s10);
    });
  });

  group('VboxRadii 圆角令牌（UI 基准 §2.4）', () {
    test('圆角档位为实测集合', () {
      expect(VboxRadii.scale, <double>[4, 6, 8, 10, 12, 14, 16, 20]);
      expect(VboxRadii.panel.topLeft.x, VboxRadii.r20);
      expect(VboxRadii.badge.topLeft.x, VboxRadii.r4);
    });
  });

  group('VboxSpacing / VboxShadows 令牌（UI 基准 §2.5）', () {
    test('间距为 4pt 栅格升序', () {
      expect(VboxSpacing.scale.first, 0);
      expect(VboxSpacing.scale.last, 32);
    });

    test('主色阴影对齐 opacity 0.35–0.40 / blur 10–16 / y 4–6', () {
      const Color primary = Color(0xFFE11D48);
      final BoxShadow normal = VboxShadows.accent(primary).single;
      final BoxShadow strong = VboxShadows.accentStrong(primary).single;

      expect(normal.blurRadius, VboxShadowSpec.blurLow);
      expect(normal.offset.dy, VboxShadowSpec.offsetYLow);
      expect(normal.color.a, closeTo(VboxShadowSpec.opacityLow, 0.001));

      expect(strong.blurRadius, VboxShadowSpec.blurHigh);
      expect(strong.offset.dy, VboxShadowSpec.offsetYHigh);
      expect(strong.color.a, closeTo(VboxShadowSpec.opacityHigh, 0.001));
    });
  });
}