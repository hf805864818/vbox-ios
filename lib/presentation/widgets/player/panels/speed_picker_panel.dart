/// 表现层：倍速面板（批次 C · C-04）。
///
/// 对齐 iOS 倍速选择（常用档位列表，当前倍速高亮；点选后切换并关闭）。
/// 纯受控：档位 / 当前值 / 回调经参数注入。
library;

import 'package:flutter/material.dart';

import '../../../theme/tokens/spacing.dart';
import '../../../theme/tokens/typography.dart';
import 'player_panel_container.dart';

/// 倍速面板（含壳）。
class SpeedPickerPanel extends StatelessWidget {
  /// 构造。
  const SpeedPickerPanel({
    super.key,
    this.speeds = defaultSpeeds,
    required this.current,
    this.onSelect,
    this.onClose,
  });

  /// 常用倍速档位。
  static const List<double> defaultSpeeds = <double>[
    0.5, 0.75, 1.0, 1.25, 1.5, 2.0,
  ];

  /// 可选档位。
  final List<double> speeds;

  /// 当前倍速。
  final double current;

  /// 选择回调。
  final void Function(double speed)? onSelect;

  /// 关闭回调。
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final List<double> list = speeds.toSet().toList()
      ..sort((double a, double b) => a.compareTo(b));
    return PlayerPanelContainer(
      title: '倍速',
      onClose: onClose,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (final double s in list)
            _SpeedRow(
              label: _fmt(s),
              selected: (s - current).abs() < 0.001,
              onTap: onSelect == null ? null : () => onSelect!(s),
            ),
        ],
      ),
    );
  }

  static String _fmt(double s) {
    final String raw = s.toStringAsFixed(2);
    final String trimmed = raw.endsWith('.00')
        ? raw.substring(0, raw.length - 3)
        : raw.endsWith('0')
            ? raw.substring(0, raw.length - 1)
            : raw;
    return '${trimmed}x';
  }
}

/// 单行倍速项。
class _SpeedRow extends StatelessWidget {
  const _SpeedRow({
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
