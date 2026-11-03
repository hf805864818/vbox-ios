/// 表现层：长按倍速设置面板（UI-F6 → S-07）。
///
/// 对齐 iOS `LongPressSpeedSettingsPanel`
/// （[PlayerViewsV2.swift](../../../../vbox/Views/PlayerViewsV2.swift#L9770)）：
///  - 标题「长按倍速设置」+ 速度表图标；
///  - 说明文案「长按屏幕时以此倍速播放，松手后恢复原速」；
///  - 4 档档位 `1.5 / 2.0 / 2.5 / 3.0`，当前档位蓝底白字高亮。
///
/// 纯受控：当前档位与选择回调经参数注入；点选后由调用方关闭面板并持久化。
library;

import 'package:flutter/material.dart';

import '../../../theme/tokens/radii.dart';
import '../../../theme/tokens/spacing.dart';
import '../../../theme/tokens/typography.dart';
import 'player_panel_container.dart';

/// 长按倍速可选档位（对齐 iOS `LongPressSpeedSettingsPanel.speeds`）。
const List<double> kLongPressSpeedOptions = <double>[1.5, 2.0, 2.5, 3.0];

/// 长按倍速设置面板（含壳）。
class LongPressSpeedSettingsPanel extends StatelessWidget {
  /// 构造。
  const LongPressSpeedSettingsPanel({
    super.key,
    required this.current,
    this.onSelect,
    this.onClose,
  });

  /// 当前长按目标倍速。
  final double current;

  /// 选择回调（null 表示只读）。
  final ValueChanged<double>? onSelect;

  /// 关闭回调。
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return PlayerPanelContainer(
      title: '长按倍速设置',
      onClose: onClose,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            '长按屏幕时以此倍速播放，松手后恢复原速',
            style: TextStyle(
              fontSize: VboxTypography.s12,
              color: Colors.white54,
            ),
          ),
          const SizedBox(height: VboxSpacing.lg),
          Row(
            children: <Widget>[
              for (int i = 0; i < kLongPressSpeedOptions.length; i++) ...<Widget>[
                if (i > 0) const SizedBox(width: VboxSpacing.sm),
                Expanded(
                  child: _SpeedOption(
                    label: formatSpeed(kLongPressSpeedOptions[i]),
                    selected:
                        (kLongPressSpeedOptions[i] - current).abs() < 0.001,
                    onTap: onSelect == null
                        ? null
                        : () => onSelect!(kLongPressSpeedOptions[i]),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  /// 档位文案（整数不带小数：`2x`；半档带一位：`1.5x`）。对齐 iOS `speedText`。
  static String formatSpeed(double s) {
    final String text = s == s.floorToDouble()
        ? s.toStringAsFixed(0)
        : s.toStringAsFixed(1);
    return '${text}x';
  }
}

/// 单个档位按钮（选中蓝底白字，未选半透明白底）。
class _SpeedOption extends StatelessWidget {
  const _SpeedOption({
    required this.label,
    required this.selected,
    this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: VboxRadii.card,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: VboxSpacing.lg),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? playerPanelAccent : Colors.white.withValues(alpha: 0.1),
          borderRadius: VboxRadii.card,
          border: Border.all(
            color: selected ? Colors.transparent : Colors.white24,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: VboxTypography.s16,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? Colors.white : Colors.white70,
          ),
        ),
      ),
    );
  }
}
