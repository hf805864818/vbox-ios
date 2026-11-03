/// 品牌组件 · 品牌 Logo（批次 A · A-13）。
///
/// 启动页字母图（[VboxBrand.splashLogoAsset]）+ 品牌字标（[VboxBrand.fontFamily]），
/// 供启动页 / 关于页 / 空态等品牌露出位使用。
library;

import 'package:flutter/material.dart';

import '../../theme/brand.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';

/// 品牌 Logo（字母图 + 字标）。
class BrandLogo extends StatelessWidget {
  /// 构造。
  const BrandLogo({
    super.key,
    this.size = 96,
    this.showWordmark = true,
    this.wordmarkColor,
  });

  /// 字母图边长。
  final double size;

  /// 是否展示字标。
  final bool showWordmark;

  /// 字标颜色（缺省取主题主色）。
  final Color? wordmarkColor;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Image.asset(
          VboxBrand.splashLogoAsset,
          width: size,
          height: size,
          fit: BoxFit.contain,
          errorBuilder: (BuildContext context, Object error, StackTrace? stack) =>
              const SizedBox.shrink(),
        ),
        if (showWordmark) ...<Widget>[
          const SizedBox(height: VboxSpacing.sm),
          Text(
            VboxBrand.wordmark,
            style: TextStyle(
              fontFamily: VboxBrand.fontFamily,
              fontSize: VboxTypography.s24,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.5,
              color: wordmarkColor ?? scheme.primary,
            ),
          ),
        ],
      ],
    );
  }
}