/// 表现层：选集面板（批次 C · C-04）。
///
/// 对齐 iOS 选集面板（竖屏底部抽屉 / 横屏右侧滑出，见
/// [PlayerViewsV2.swift](../../../../../vbox/Views/PlayerViewsV2.swift#L8664)）：
/// 标题「选集」+「共 N 集」，网格陈列 [VboxEpisodeChip]，当前集高亮。
/// 纯受控：当前集 / 回调经参数注入。
library;

import 'package:flutter/material.dart';

import '../../../../domain/entities/playback/playback_detail.dart';
import '../../../theme/tokens/colors.dart';
import '../../../theme/tokens/spacing.dart';
import '../../../theme/tokens/typography.dart';
import '../../vbox/vbox_episode_chip.dart';
import 'player_panel_container.dart';

/// 选集面板内容（供 [PlayerPanelContainer] 使用）。
class EpisodePickerPanel extends StatelessWidget {
  /// 构造。
  const EpisodePickerPanel({
    super.key,
    required this.episodes,
    required this.currentIndex,
    this.onSelect,
  });

  /// 剧集列表。
  final List<PlaybackEpisode> episodes;

  /// 当前剧集索引。
  final int currentIndex;

  /// 选择回调（索引）。
  final void Function(int index)? onSelect;

  @override
  Widget build(BuildContext context) {
    if (episodes.isEmpty) {
      return const Text(
        '暂无剧集',
        style: TextStyle(fontSize: VboxTypography.s14, color: Colors.white60),
      );
    }
    final int n = episodes.length;
    final int cols = n > 60 ? 8 : n > 24 ? 6 : 4;
    final List<Widget> cells = <Widget>[
      for (int i = 0; i < n; i++)
        SizedBox(
          width: double.infinity,
          child: VboxEpisodeChip(
            label: episodes[i].name.isEmpty
                ? '${i + 1}'
                : episodes[i].name,
            selected: i == currentIndex,
            onTap: onSelect == null ? null : () => onSelect!(i),
          ),
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        GridView.count(
          crossAxisCount: cols,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: VboxSpacing.sm,
          crossAxisSpacing: VboxSpacing.sm,
          childAspectRatio: 2.2,
          children: cells,
        ),
      ],
    );
  }
}

/// 选集面板（含壳）。
class EpisodePickerPanelShell extends StatelessWidget {
  /// 构造。
  const EpisodePickerPanelShell({
    super.key,
    required this.episodes,
    required this.currentIndex,
    this.onSelect,
    this.onClose,
  });

  /// 剧集列表。
  final List<PlaybackEpisode> episodes;

  /// 当前剧集索引。
  final int currentIndex;

  /// 选择回调（索引）。
  final void Function(int index)? onSelect;

  /// 关闭回调。
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return PlayerPanelContainer(
      title: '选集',
      trailing: Text(
        '共 ${episodes.length} 集',
        style: const TextStyle(
          fontSize: VboxTypography.s12,
          color: Colors.white54,
        ),
      ),
      onClose: onClose,
      child: EpisodePickerPanel(
        episodes: episodes,
        currentIndex: currentIndex,
        onSelect: onSelect,
      ),
    );
  }
}

/// 选集网格强调色（当前集高亮，对齐 UI 基准 `#2196F3`）。
const Color episodeAccent = VboxColors.selected;
