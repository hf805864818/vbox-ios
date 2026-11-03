/// 表现层：清晰度面板（批次 C · C-04）。
///
/// 对齐 iOS 清晰度选择（`标清 / 高清 / 蓝光` 列表，当前项高亮）。
/// 纯受控：选项 / 当前索引 / 回调经参数注入。
library;

import 'package:flutter/material.dart';

import '../../../theme/tokens/spacing.dart';
import '../../../theme/tokens/typography.dart';
import 'player_panel_container.dart';

/// 清晰度面板（含壳）。
class QualityPickerPanel extends StatelessWidget {
  /// 构造。
  const QualityPickerPanel({
    super.key,
    required this.qualities,
    required this.selectedIndex,
    this.onSelect,
    this.onClose,
  });

  /// 清晰度文案列表。
  final List<String> qualities;

  /// 当前索引。
  final int selectedIndex;

  /// 选择回调（索引）。
  final void Function(int index)? onSelect;

  /// 关闭回调。
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return PlayerPanelContainer(
      title: '清晰度',
      onClose: onClose,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (int i = 0; i < qualities.length; i++)
            _QualityRow(
              label: qualities[i],
              selected: i == selectedIndex,
              onTap: onSelect == null ? null : () => onSelect!(i),
            ),
        ],
      ),
    );
  }
}

/// 单行清晰度项。
class _QualityRow extends StatelessWidget {
  const _QualityRow({
    required this.label,
    required this.selected,
    this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final Color fg = selected ? playerPanelAccent : Colors.white70;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: VboxSpacing.md,
          vertical: VboxSpacing.md,
        ),
        child: Row(
          children: <Widget>[
            Text(
              label,
              style: TextStyle(
                fontSize: VboxTypography.s14,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: fg,
              ),
            ),
            const Spacer(),
            if (selected)
              const Icon(Icons.check_rounded, size: 18, color: playerPanelAccent),
          ],
        ),
      ),
    );
  }
}
