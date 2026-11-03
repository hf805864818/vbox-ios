/// 表现层：播放队列弹层（批次 G · G-音1）。
///
/// 唯一真相源：iOS `MusicQueueSheet`
/// （`vbox/Views/MusicPlayerViews.swift:723`）。
///
/// 对齐口径：
///  - 标题「播放队列 (n)」+ 左上关闭；列表 `.plain` 样式；
///  - 行 = 封面 44×44 圆角 8 + 歌名（当前项主色加粗）+ 歌手（次要色）；
///  - 当前项尾随喇叭图标；其余项尾随红色减号（点击移出队列）；
///  - 点击任意行 → 以该下标为起点重播整个队列（对齐 iOS `playQueue(startIndex:)`）。
library;

import 'package:flutter/material.dart';

import '../../../domain/entities/music/music.dart';
import '../../../platform/player/music_player.dart';
import '../../theme/tokens/radii.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';
import '../platform_async_image.dart';

/// 播放队列弹层。
class MusicQueueSheet extends StatelessWidget {
  /// 构造。
  const MusicQueueSheet({super.key, this.controller});

  /// 播放控制器（缺省取全局单例）。
  final MusicPlayerController? controller;

  @override
  Widget build(BuildContext context) {
    final MusicPlayerController player =
        controller ?? MusicPlayerController.instance;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return ListenableBuilder(
      listenable: player,
      builder: (BuildContext context, Widget? _) {
        final List<MusicQueueItem> items = player.queue.items;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _header(context, scheme, items.length),
              const Divider(height: 1),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: VboxSpacing.xs),
                  itemCount: items.length,
                  itemBuilder: (BuildContext context, int index) {
                    return _row(context, scheme, player, items[index], index);
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _header(BuildContext context, ColorScheme scheme, int count) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        VboxSpacing.sm,
        VboxSpacing.xs,
        VboxSpacing.lg,
        VboxSpacing.xs,
      ),
      child: Row(
        children: <Widget>[
          IconButton(
            key: const ValueKey<String>('music_queue_close'),
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.close, size: 18),
          ),
          const Spacer(),
          Text(
            '播放队列 ($count)',
            style: const TextStyle(
              fontSize: VboxTypography.s15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          // 与左侧图标等宽的占位，保证标题居中。
          const SizedBox(width: 48),
        ],
      ),
    );
  }

  Widget _row(
    BuildContext context,
    ColorScheme scheme,
    MusicPlayerController player,
    MusicQueueItem item,
    int index,
  ) {
    final bool isCurrent = index == player.currentIndex;
    return InkWell(
      key: ValueKey<String>('music_queue_row_$index'),
      onTap: () => player.setQueue(player.queue.items, startIndex: index),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: VboxSpacing.lg,
          vertical: VboxSpacing.xs,
        ),
        child: Row(
          children: <Widget>[
            ClipRRect(
              borderRadius: BorderRadius.circular(VboxRadii.r8),
              child: SizedBox(
                width: 44,
                height: 44,
                child: item.coverURL.trim().isEmpty
                    ? ColoredBox(
                        color: scheme.surfaceContainerHighest,
                        child: Icon(Icons.music_note, color: scheme.outline, size: 20),
                      )
                    : PlatformAsyncImage(url: item.coverURL, fit: BoxFit.cover),
              ),
            ),
            const SizedBox(width: VboxSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: VboxTypography.s15,
                      fontWeight: isCurrent ? FontWeight.w600 : FontWeight.normal,
                      color: isCurrent ? scheme.primary : scheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    item.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: VboxTypography.s12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: VboxSpacing.sm),
            if (isCurrent)
              Icon(Icons.volume_up, size: 16, color: scheme.primary)
            else
              IconButton(
                key: ValueKey<String>('music_queue_remove_$index'),
                onPressed: () => player.removeFromQueue(index),
                icon: Icon(
                  Icons.remove_circle_outline,
                  size: 20,
                  color: scheme.error.withValues(alpha: 0.8),
                ),
              ),
          ],
        ),
      ),
    );
  }
}