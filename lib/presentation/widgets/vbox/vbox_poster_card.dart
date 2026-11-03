/// 统一组件库 · 海报卡（批次 A · A-04）。
///
/// 唯一真相源：`docs/UI对齐基准_v1.0.md` §2.4（圆角 12 · 分组卡片/中号卡）
/// 与 §3-02 / §3-07（海报墙）。
///
/// 封面加载自 A-10 起收敛至 `PlatformAsyncImage`（平台封面分支 + 占位/失败态）。
library;

import 'package:flutter/material.dart';

import '../../theme/tokens/radii.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';
import '../platform_async_image.dart';

/// 海报卡（2:3 封面 + 标题）。
class VboxPosterCard extends StatelessWidget {
  /// 构造。
  const VboxPosterCard({
    super.key,
    required this.title,
    this.imageUrl,
    this.subtitle,
    this.width = 120,
    this.onTap,
    this.badge,
    this.rating,
  });

  /// 标题。
  final String title;

  /// 封面地址（空 → 占位态）。
  final String? imageUrl;

  /// 副标题（年份 / 类型）。
  final String? subtitle;

  /// 卡片宽度（高度按 2:3 推导）。
  final double width;

  /// 点击回调。
  final VoidCallback? onTap;

  /// 封面角标（左上）。
  final Widget? badge;

  /// 评分（右上角小标签）。
  final String? rating;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    const double aspect = 2 / 3;

    return SizedBox(
      width: width,
      // 整卡可点（对齐 iOS 海报卡整卡点击，含标题/副标题区）。
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            AspectRatio(
              aspectRatio: aspect,
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  ClipRRect(
                    borderRadius: VboxRadii.card,
                    child: _Poster(
                      imageUrl: imageUrl,
                      placeholder: scheme.surfaceContainerHighest,
                    ),
                  ),
                  if (badge != null)
                    Positioned(
                      left: VboxSpacing.sm,
                      top: VboxSpacing.sm,
                      child: badge!,
                    ),
                  if (rating != null)
                    Positioned(
                      right: VboxSpacing.sm,
                      top: VboxSpacing.sm,
                      child: Container(
                        padding: VboxSpacing.symmetric(
                          horizontal: VboxSpacing.sm,
                          vertical: VboxSpacing.xs,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.60),
                          borderRadius: VboxRadii.badge,
                        ),
                        child: Text(
                          rating!,
                          style: const TextStyle(
                            fontSize: VboxTypography.s11,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: VboxSpacing.sm),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: VboxTypography.s13,
                fontWeight: FontWeight.w500,
                color: scheme.onSurface,
              ),
            ),
            if (subtitle != null)
              Text(
                subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: VboxTypography.s11,
                  color: scheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Poster extends StatelessWidget {
  const _Poster({required this.imageUrl, required this.placeholder});

  final String? imageUrl;
  final Color placeholder;

  @override
  Widget build(BuildContext context) {
    // A-10：图片加载收敛至 PlatformAsyncImage（平台封面分支 + 占位/失败兜底）。
    return PlatformAsyncImage(
      url: imageUrl,
      fit: BoxFit.cover,
      placeholderColor: placeholder,
    );
  }
}