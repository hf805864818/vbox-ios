/// 统一组件库 · 剧集项（批次 A · A-04）。
///
/// 唯一真相源：`docs/UI对齐基准_v1.0.md` §2.5（播放器剧集项）。
/// 规格：当前项文字 `#2196F3`、底色 `#2196F3` @20%、带边框；非当前项跟随正文色。
library;

import 'package:flutter/material.dart';

import '../../theme/tokens/colors.dart';
import '../../theme/tokens/radii.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';

/// 剧集 / 选集网格项。
class VboxEpisodeChip extends StatelessWidget {
  /// 构造。
  const VboxEpisodeChip({
    super.key,
    required this.label,
    this.selected = false,
    this.onTap,
    this.width,
    this.accent = VboxColors.selected,
  });

  /// 文案（集号 / 线路名）。
  final String label;

  /// 是否当前项。
  final bool selected;

  /// 点击回调。
  final VoidCallback? onTap;

  /// 固定宽度（null 时自适应）。
  final double? width;

  /// 强调色（默认对齐 UI 基准的 `#2196F3`）。
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color foreground = selected ? accent : scheme.onSurface;
    final Color background =
        selected ? accent.withValues(alpha: 0.20) : scheme.surfaceContainerHighest;
    final Color? stroke = selected ? accent : null;

    return SizedBox(
      width: width,
      child: Material(
        color: background,
        shape: RoundedRectangleBorder(
          borderRadius: VboxRadii.button,
          side: stroke == null ? BorderSide.none : BorderSide(color: stroke),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: VboxSpacing.symmetric(
              horizontal: VboxSpacing.md,
              vertical: VboxSpacing.sm,
            ),
            child: Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: VboxTypography.s13,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: foreground,
              ),
            ),
          ),
        ),
      ),
    );
  }
}