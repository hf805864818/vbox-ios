/// 表现层：播放内核选择面板（批次 C · C-04）。
///
/// 对齐 iOS 内核选择（`currentEngineButtonTitle` → `showEnginePicker`）：
/// 列出当前端可用后端，当前项高亮；降级语义（当前后端非链首）给出提示行。
/// 纯受控：后端列表 / 当前值 / 回调经参数注入。
library;

import 'package:flutter/material.dart';

import '../../../../domain/entities/player/player.dart';
import '../../../theme/tokens/spacing.dart';
import '../../../theme/tokens/typography.dart';
import 'player_panel_container.dart';

/// 播放内核选择面板（含壳）。
class EnginePickerPanel extends StatelessWidget {
  /// 构造。
  const EnginePickerPanel({
    super.key,
    required this.backends,
    required this.current,
    this.onSelect,
    this.onClose,
  });

  /// 可用后端列表（降级链顺序）。
  final List<PlayerBackend> backends;

  /// 当前后端。
  final PlayerBackend? current;

  /// 选择回调。
  final void Function(PlayerBackend backend)? onSelect;

  /// 关闭回调。
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final List<PlayerBackend> list =
        backends.toSet().toList(growable: false);
    final PlayerBackend? cur = current;
    return PlayerPanelContainer(
      title: '播放内核',
      onClose: onClose,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (final PlayerBackend b in list)
            _EngineRow(
              label: _title(b),
              selected: b == cur,
              onTap: onSelect == null ? null : () => onSelect!(b),
            ),
          if (cur != null && list.isNotEmpty && list.first != cur)
            Padding(
              padding: const EdgeInsets.only(top: VboxSpacing.sm),
              child: Text(
                '当前为降级后端（${_title(list.first)} 不可用）',
                style: const TextStyle(
                  fontSize: VboxTypography.s12,
                  color: Colors.white54,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 后端显示名（P-芯6：读后端元数据，避免本处重复文案表）。
  static String _title(PlayerBackend b) => b.displayName;
}

/// 单行内核项。
class _EngineRow extends StatelessWidget {
  const _EngineRow({
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
