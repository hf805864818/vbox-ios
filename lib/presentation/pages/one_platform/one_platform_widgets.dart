/// One 平台（YBox）共享组件（批次 G · G-05）。
///
/// 对齐 iOS `OnePlatformViews.swift` 组件规格：
/// - [OneVideoCard]（`OneVideoCard`）：3:4 封面 + 时长角标 + 标题 + 播放量/评分；
/// - [OneAlbumCard]（`OneAlbumCard`）：2:3 封面 + 章数角标 + 标题；
/// - [OneVideoGrid] / [OneAlbumGrid]：2 列视频网格 / 3 列专辑网格 + 加载更多脚标；
/// - [OneCategoryChips] / [OneLineChips] / [OneTagChips]：胶囊横滚芯片 / 标签；
/// - [OneEmptyHint] / [OneErrorRetry]：空态 / 错误重试（含密钥探测提示）。
///
/// 全部组件只消费令牌层 + `ColorScheme`，与 MDTV / 直播 / 豆瓣页共用同一套视觉语言。
library;

import 'package:flutter/material.dart';

import '../../../domain/entities/one_platform/one_platform.dart';
import '../../theme/tokens/radii.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';
import '../../widgets/platform_async_image.dart';
import '../../widgets/skeleton_shimmer.dart';

/// 播放量格式化（对齐 iOS `formatCount`：≥1 万 → 保留 1 位「万」）。
String formatOneCount(int count) {
  if (count >= 10000) {
    return '${(count / 10000).toStringAsFixed(1)}万';
  }
  return '$count';
}

/// 视频卡片（对齐 iOS `OneVideoCard`：3:4 封面 + 时长角标 + 标题 + 播放量 + 评分）。
class OneVideoCard extends StatelessWidget {
  /// 构造。
  const OneVideoCard({
    super.key,
    required this.title,
    required this.coverUrl,
    required this.duration,
    this.views = 0,
    this.rating,
    this.placeholder = false,
    this.onTap,
  });

  /// 标题。
  final String title;

  /// 已拼接 CDN 域名的封面地址（空 → 占位块）。
  final String coverUrl;

  /// 时长文案（空 → 不显示角标）。
  final String duration;

  /// 播放量。
  final int views;

  /// 评分（空 → 不显示）。
  final String? rating;

  /// 占位态（骨架屏）。
  final bool placeholder;

  /// 点击回调。
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String? score = rating;
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
              fontWeight: FontWeight.w500,
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
                formatOneCount(views),
                style: TextStyle(
                  fontSize: VboxTypography.s11,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              if (score != null && score.isNotEmpty)
                Text(
                  score,
                  style: TextStyle(
                    fontSize: VboxTypography.s11,
                    fontWeight: FontWeight.w700,
                    color: scheme.tertiary,
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
              // UI-B3 骨架屏动效：静态占位 → 渐变扫光。
              ShimmerBox(color: scheme.surfaceContainerHighest)
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
            if (!placeholder && duration.isNotEmpty)
              Positioned(
                right: VboxSpacing.sm,
                bottom: VboxSpacing.sm,
                child: Container(
                  padding: VboxSpacing.symmetric(
                      horizontal: VboxSpacing.compact, vertical: 2),
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

/// 专辑卡片（对齐 iOS `OneAlbumCard`：2:3 封面 + 章数角标 + 标题）。
class OneAlbumCard extends StatelessWidget {
  /// 构造。
  const OneAlbumCard({
    super.key,
    required this.title,
    required this.coverUrl,
    this.itemCount = 0,
    this.placeholder = false,
    this.onTap,
  });

  /// 标题。
  final String title;

  /// 已拼接 CDN 域名的封面地址（空 → 占位块）。
  final String coverUrl;

  /// 章节数量（>0 → 显示「N P」角标）。
  final int itemCount;

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
          ClipRRect(
            borderRadius: BorderRadius.circular(VboxRadii.r8),
            child: AspectRatio(
              aspectRatio: 2 / 3,
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  if (placeholder || coverUrl.isEmpty)
                    // UI-B3 骨架屏动效：静态占位 → 渐变扫光。
                    ShimmerBox(color: scheme.surfaceContainerHighest)
                  else
                    PlatformAsyncImage(
                      url: coverUrl,
                      fit: BoxFit.cover,
                      placeholderColor: scheme.surfaceContainerHighest,
                      placeholder: Icon(
                        Icons.collections_bookmark_outlined,
                        size: VboxTypography.s24,
                        color: scheme.onSurfaceVariant.withValues(alpha: 0.50),
                      ),
                    ),
                  if (!placeholder && itemCount > 0)
                    Positioned(
                      right: VboxSpacing.sm,
                      bottom: VboxSpacing.sm,
                      child: Container(
                        padding: VboxSpacing.symmetric(
                            horizontal: VboxSpacing.compact, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.60),
                          borderRadius: VboxRadii.badge,
                        ),
                        child: Text(
                          '${itemCount}P',
                          style: const TextStyle(
                            fontSize: VboxTypography.s10,
                            fontWeight: FontWeight.w500,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: VboxSpacing.sm),
          Text(
            placeholder ? '加载中...' : title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: VboxTypography.s12,
              fontWeight: FontWeight.w500,
              height: 1.25,
              color: scheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

/// 视频网格（发现页 / 每日推荐共用；2 列 + 骨架占位 + 加载更多脚标）。
class OneVideoGrid extends StatelessWidget {
  /// 构造。
  const OneVideoGrid({
    super.key,
    required this.videos,
    required this.imageResolver,
    this.placeholder = false,
    this.showFooter = false,
    this.onOpenVideo,
  });

  /// 视频列表。
  final List<OneVideoItem> videos;

  /// 封面路径 → 完整 URL（`OnePlatformController.imageURL`）。
  final String Function(String cover) imageResolver;

  /// 骨架占位态（忽略封面/标题）。
  final bool placeholder;

  /// 是否显示加载更多脚标。
  final bool showFooter;

  /// 点击视频回调。
  final void Function(OneVideoItem video)? onOpenVideo;

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
        final OneVideoItem video = videos[index];
        return OneVideoCard(
          title: video.title,
          coverUrl: imageResolver(video.cover),
          duration: video.duration,
          views: video.views,
          rating: video.rating,
          placeholder: placeholder,
          onTap: onOpenVideo == null ? null : () => onOpenVideo!(video),
        );
      },
    );
  }
}

/// 专辑网格（专辑 Tab；3 列 + 加载更多脚标）。
class OneAlbumGrid extends StatelessWidget {
  /// 构造。
  const OneAlbumGrid({
    super.key,
    required this.albums,
    required this.imageResolver,
    this.placeholder = false,
    this.showFooter = false,
    this.onOpenAlbum,
  });

  /// 专辑列表。
  final List<OneAlbum> albums;

  /// 封面路径 → 完整 URL。
  final String Function(String cover) imageResolver;

  /// 骨架占位态。
  final bool placeholder;

  /// 是否显示加载更多脚标。
  final bool showFooter;

  /// 点击专辑回调。
  final void Function(OneAlbum album)? onOpenAlbum;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(VboxSpacing.md),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: VboxSpacing.md,
        crossAxisSpacing: VboxSpacing.md,
        childAspectRatio: 0.52,
      ),
      itemCount: albums.length + (showFooter ? 1 : 0),
      itemBuilder: (BuildContext context, int index) {
        if (index >= albums.length) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(VboxSpacing.lg),
              child: CircularProgressIndicator(),
            ),
          );
        }
        final OneAlbum album = albums[index];
        return OneAlbumCard(
          title: album.title,
          coverUrl: imageResolver(album.cover),
          itemCount: album.itemCount,
          placeholder: placeholder,
          onTap: onOpenAlbum == null ? null : () => onOpenAlbum!(album),
        );
      },
    );
  }
}

/// 分类胶囊横滚（对齐 iOS `OneDiscoveryTab` 分类横滚条）。
class OneCategoryChips extends StatelessWidget {
  /// 构造。
  const OneCategoryChips({
    super.key,
    required this.categories,
    required this.selectedIndex,
    this.onTap,
  });

  /// 分类列表。
  final List<OneCategory> categories;

  /// 当前选中索引。
  final int selectedIndex;

  /// 点击回调（返回索引）。
  final void Function(int index)? onTap;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: VboxSpacing.symmetric(
          horizontal: VboxSpacing.lg, vertical: VboxSpacing.segmentVertical),
      child: Row(
        children: <Widget>[
          for (int i = 0; i < categories.length; i++)
            Padding(
              padding: EdgeInsets.only(right: i == categories.length - 1 ? 0 : VboxSpacing.sm),
              child: _Chip(
                label: categories[i].name,
                selected: i == selectedIndex,
                onTap: onTap == null ? null : () => onTap!(i),
              ),
            ),
        ],
      ),
    );
  }
}

/// 播放线路胶囊横滚（对齐 iOS `OneVideoDetailView` 线路选择）。
class OneLineChips extends StatelessWidget {
  /// 构造。
  const OneLineChips({
    super.key,
    required this.sources,
    required this.selectedIndex,
    this.onTap,
  });

  /// 线路列表。
  final List<OnePlaySource> sources;

  /// 当前选中索引。
  final int selectedIndex;

  /// 点击回调（返回索引）。
  final void Function(int index)? onTap;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: VboxSpacing.symmetric(horizontal: VboxSpacing.lg),
      child: Row(
        children: <Widget>[
          for (int i = 0; i < sources.length; i++)
            Padding(
              padding: EdgeInsets.only(right: i == sources.length - 1 ? 0 : VboxSpacing.sm),
              child: _Chip(
                label: sources[i].name,
                selected: i == selectedIndex,
                onTap: onTap == null ? null : () => onTap!(i),
              ),
            ),
        ],
      ),
    );
  }
}

/// 胶囊芯片（选中主色实底 + 白字加粗；未选浅底 + 次要字色）。
class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.selected, this.onTap});

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected
          ? scheme.primary
          : scheme.onSurfaceVariant.withValues(alpha: 0.15),
      shape: const StadiumBorder(),
      child: InkWell(
        borderRadius: VboxRadii.chip,
        onTap: onTap,
        child: Padding(
          padding: VboxSpacing.symmetric(
              horizontal: VboxSpacing.inputHorizontal, vertical: VboxSpacing.compact),
          child: Text(
            label,
            style: TextStyle(
              fontSize: VboxTypography.s13,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
              color: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

/// 标签行（对齐 iOS 详情页标签云；Flutter 用 `Wrap` 承接弹性布局）。
class OneTagChips extends StatelessWidget {
  /// 构造。
  const OneTagChips({super.key, required this.tags});

  /// 标签列表。
  final List<String> tags;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: VboxSpacing.sm,
      runSpacing: VboxSpacing.sm,
      children: <Widget>[
        for (final String tag in tags)
          Container(
            padding: VboxSpacing.symmetric(
                horizontal: VboxSpacing.segmentVertical, vertical: VboxSpacing.xs),
            decoration: BoxDecoration(
              color: scheme.onSurfaceVariant.withValues(alpha: 0.15),
              borderRadius: VboxRadii.badge,
            ),
            child: Text(
              tag,
              style: TextStyle(
                fontSize: VboxTypography.s12,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}

/// 空态提示。
class OneEmptyHint extends StatelessWidget {
  /// 构造。
  const OneEmptyHint({super.key, required this.text});

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

/// 加载失败提示 + 重试（对齐 iOS 发现页 / 每日推荐错误态）。
class OneErrorRetry extends StatelessWidget {
  /// 构造。
  const OneErrorRetry({
    super.key,
    required this.message,
    required this.onRetry,
    this.icon = Icons.wifi_off,
    this.hint,
  });

  /// 错误文案。
  final String message;

  /// 重试回调。
  final VoidCallback onRetry;

  /// 顶部图标。
  final IconData icon;

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
            Icon(icon, size: VboxTypography.s28, color: scheme.onSurfaceVariant),
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