/// 麻豆平台（MDTV）共享组件（批次 E · E-05）。
///
/// 对齐 iOS `MDTVViews.swift` 的组件规格：
/// - [MdtvVideoCard]（`MDTVVideoCard`）：3:4 封面 + 时长角标 + 标题 + 播放量；
/// - [MdtvCategoryCard]（`MDTVCategoryCard`）：1:1 圆角块 + 播放图标 + 名称；
/// - [MdtvTagCloud]（`FlexibleView`）：标签云（Flutter 用 `Wrap` 原生承接）；
/// - [MdtvEmptyHint] / [MdtvErrorRetry]：空态 / 错误重试（含密钥探测提示）。
///
/// 全部组件只消费令牌层 + `ColorScheme`，与直播/豆瓣页共用同一套视觉语言。
library;

import 'package:flutter/material.dart';

import '../../../domain/entities/mdtv/mdtv.dart';
import '../../theme/tokens/radii.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';
import '../../widgets/platform_async_image.dart';

/// 视频卡片（对齐 iOS `MDTVVideoCard`：3:4 封面 + 时长角标 + 标题 + 播放量）。
class MdtvVideoCard extends StatelessWidget {
  /// 构造。
  const MdtvVideoCard({
    super.key,
    required this.title,
    required this.coverUrl,
    required this.duration,
    this.views = 0,
    this.placeholder = false,
    this.onTap,
  });

  /// 标题。
  final String title;

  /// 已拼接 CDN 域名的封面地址（空 → 占位块）。
  final String coverUrl;

  /// 时长文案。
  final String duration;

  /// 播放量。
  final int views;

  /// 占位态（骨架屏）。
  final bool placeholder;

  /// 点击回调。
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(VboxRadii.r8),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _cover(scheme),
          const SizedBox(height: VboxSpacing.sm),
          Text(
            placeholder ? '加载中...' : title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: VboxTypography.s13,
              height: 1.25,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: VboxSpacing.xs),
          Row(
            children: <Widget>[
              Icon(Icons.remove_red_eye_outlined,
                  size: VboxTypography.s10, color: scheme.onSurfaceVariant),
              const SizedBox(width: VboxSpacing.xs),
              Text(
                '$views',
                style: TextStyle(
                  fontSize: VboxTypography.s11,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _cover(ColorScheme scheme) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(VboxRadii.r8),
      child: AspectRatio(
        aspectRatio: 3 / 4,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            if (placeholder || coverUrl.isEmpty)
              Container(
                color: scheme.surfaceContainerHighest,
              )
            else
              PlatformAsyncImage(
                url: coverUrl,
                fit: BoxFit.cover,
                placeholderColor: scheme.surfaceContainerHighest,
                placeholder: Icon(
                  Icons.movie_outlined,
                  size: VboxTypography.s24,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.50),
                ),
              ),
            // 时长角标（右下）。
            Positioned(
              right: VboxSpacing.sm,
              bottom: VboxSpacing.sm,
              child: Container(
                padding: VboxSpacing.symmetric(
                    horizontal: VboxSpacing.sm, vertical: VboxSpacing.xs),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.60),
                  borderRadius: VboxRadii.badge,
                ),
                child: Text(
                  duration,
                  style: const TextStyle(
                    fontSize: VboxTypography.s11,
                    fontWeight: FontWeight.w500,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 分类/频道卡片（对齐 iOS `MDTVCategoryCard`：1:1 圆角块 + 图标 + 名称）。
class MdtvCategoryCard extends StatelessWidget {
  /// 构造。
  const MdtvCategoryCard({
    super.key,
    required this.name,
    this.placeholder = false,
    this.onTap,
  });

  /// 名称。
  final String name;

  /// 占位态（骨架屏）。
  final bool placeholder;

  /// 点击回调。
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(VboxRadii.r8),
      onTap: onTap,
      child: Column(
        children: <Widget>[
          AspectRatio(
            aspectRatio: 1,
            child: Container(
              decoration: BoxDecoration(
                color: placeholder
                    ? scheme.surfaceContainerHighest
                    : scheme.primary.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(VboxRadii.r8),
              ),
              alignment: Alignment.center,
              child: placeholder
                  ? null
                  : Icon(
                      Icons.play_circle_fill,
                      size: VboxTypography.s28,
                      color: scheme.primary,
                    ),
            ),
          ),
          const SizedBox(height: VboxSpacing.sm),
          Text(
            placeholder ? '分类...' : name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: VboxTypography.s13,
              fontWeight: FontWeight.w500,
              color: scheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

/// 标签云（对齐 iOS `FlexibleView`；Flutter 用 `Wrap` 承接弹性布局）。
class MdtvTagCloud extends StatelessWidget {
  /// 构造。
  const MdtvTagCloud({
    super.key,
    required this.tags,
    this.onTap,
  });

  /// 标签列表。
  final List<MdtvTag> tags;

  /// 标签点击回调。
  final void Function(MdtvTag tag)? onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: VboxSpacing.sm,
      runSpacing: VboxSpacing.sm,
      children: <Widget>[
        for (final MdtvTag tag in tags)
          Material(
            color: scheme.primary.withValues(alpha: 0.10),
            shape: const StadiumBorder(),
            child: InkWell(
              borderRadius: VboxRadii.chip,
              onTap: onTap == null ? null : () => onTap!(tag),
              child: Padding(
                padding: VboxSpacing.symmetric(
                    horizontal: 14, vertical: VboxSpacing.sm),
                child: Text(
                  tag.name,
                  style: TextStyle(
                    fontSize: VboxTypography.s14,
                    color: scheme.primary,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// 视频网格（推荐页 / 列表页共用；2 列 + 骨架占位 + 加载更多脚标）。
class MdtvVideoGrid extends StatelessWidget {
  /// 构造。
  const MdtvVideoGrid({
    super.key,
    required this.videos,
    required this.imageResolver,
    this.placeholder = false,
    this.showFooter = false,
    this.onOpenVideo,
  });

  /// 视频列表。
  final List<MdtvVideoItem> videos;

  /// 封面路径 → 完整 URL（`MdtvController.imageURL`）。
  final String Function(String cover) imageResolver;

  /// 骨架占位态（忽略封面/标题）。
  final bool placeholder;

  /// 是否显示加载更多脚标。
  final bool showFooter;

  /// 点击视频回调。
  final void Function(MdtvVideoItem video)? onOpenVideo;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(VboxSpacing.md),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: VboxSpacing.md,
        crossAxisSpacing: VboxSpacing.md,
        childAspectRatio: 0.55,
      ),
      itemCount: videos.length + (showFooter ? 1 : 0),
      itemBuilder: (BuildContext context, int index) {
        if (index >= videos.length) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(VboxSpacing.xl),
              child: CircularProgressIndicator(),
            ),
          );
        }
        final MdtvVideoItem video = videos[index];
        return MdtvVideoCard(
          title: video.title,
          coverUrl: imageResolver(video.cover),
          duration: video.duration,
          views: video.views,
          placeholder: placeholder,
          onTap: onOpenVideo == null ? null : () => onOpenVideo!(video),
        );
      },
    );
  }
}

/// 空态提示。
class MdtvEmptyHint extends StatelessWidget {
  /// 构造。
  const MdtvEmptyHint({super.key, required this.text});

  /// 文案。
  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(VboxSpacing.xxxl),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: VboxTypography.s15,
            color: Theme.of(context).colorScheme.outline,
          ),
        ),
      ),
    );
  }
}

/// 加载失败提示 + 重试（对齐 iOS 推荐页错误态，含密钥探测提示）。
class MdtvErrorRetry extends StatelessWidget {
  /// 构造。
  const MdtvErrorRetry({
    super.key,
    required this.message,
    required this.onRetry,
    this.hint,
  });

  /// 错误文案。
  final String message;

  /// 重试回调。
  final VoidCallback onRetry;

  /// 附加快捷提示（如「正在自动探测密钥」）。
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(VboxSpacing.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.wifi_off,
              size: VboxTypography.s28,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: VboxSpacing.md),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: VboxTypography.s15,
                fontWeight: FontWeight.w500,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: VboxSpacing.md),
            FilledButton.tonal(
              onPressed: onRetry,
              child: const Text('重试'),
            ),
            if (hint != null) ...<Widget>[
              const SizedBox(height: VboxSpacing.md),
              Text(
                hint!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: VboxTypography.s13,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}