/// 表现层：片头片尾设置面板（UI-F2）。
///
/// 对齐 iOS `SkipSettingsPanelV2`
/// （[PlayerViewsV2.swift](../../../../vbox/Views/PlayerViewsV2.swift#L10842)）+
/// `ToolsMenuRow`（[L10909](../../../../vbox/Views/PlayerViewsV2.swift#L10909)）：
///  - 两行：跳过片头 / 跳过片尾（图标 + 名称 + 开关）；
///  - 开关打开时展开时长选择（分 / 秒两档，对齐 iOS 双滚轮语义）。
///
/// 纯受控：设置快照与变更回调经参数注入；每次改动即时上抛（面板内联编辑
/// 不关闭，对齐 iOS `.onChange` 逐次落库）。
library;

import 'package:flutter/material.dart';

import '../../../../platform/player/skip_settings.dart';
import '../../../theme/tokens/colors.dart';
import '../../../theme/tokens/spacing.dart';
import '../../../theme/tokens/typography.dart';
import 'player_panel_container.dart';

/// 片头片尾设置面板（含壳）。
class SkipSettingsPanel extends StatelessWidget {
  /// 构造。
  const SkipSettingsPanel({
    super.key,
    required this.settings,
    this.onChanged,
    this.onClose,
  });

  /// 当前设置。
  final SkipSettings settings;

  /// 变更回调（null 表示只读）。
  final ValueChanged<SkipSettings>? onChanged;

  /// 关闭回调。
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return PlayerPanelContainer(
      title: '片头片尾',
      onClose: onClose,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _SkipRow(
            icon: Icons.fast_forward_rounded,
            title: '跳过片头',
            enabled: settings.introEnabled,
            seconds: settings.introSeconds,
            onToggle: onChanged == null
                ? null
                : (bool v) => _emit(settings.copyWith(introEnabled: v)),
            onSeconds: onChanged == null
                ? null
                : (int s) => _emit(settings.copyWith(introSeconds: s)),
          ),
          const Divider(height: 1, color: Colors.white12),
          _SkipRow(
            icon: Icons.fast_rewind_rounded,
            title: '跳过片尾',
            enabled: settings.outroEnabled,
            seconds: settings.outroSeconds,
            onToggle: onChanged == null
                ? null
                : (bool v) => _emit(settings.copyWith(outroEnabled: v)),
            onSeconds: onChanged == null
                ? null
                : (int s) => _emit(settings.copyWith(outroSeconds: s)),
          ),
        ],
      ),
    );
  }

  void _emit(SkipSettings next) {
    if (next.sameAs(settings)) return;
    onChanged?.call(next);
  }
}

/// 单行：图标 + 名称 + 开关；开启时展开「分 / 秒」时长选择。
class _SkipRow extends StatelessWidget {
  const _SkipRow({
    required this.icon,
    required this.title,
    required this.enabled,
    required this.seconds,
    this.onToggle,
    this.onSeconds,
  });

  final IconData icon;
  final String title;
  final bool enabled;
  final int seconds;
  final ValueChanged<bool>? onToggle;
  final ValueChanged<int>? onSeconds;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(vertical: VboxSpacing.xs),
          child: Row(
            children: <Widget>[
              Icon(
                icon,
                size: 20,
                color: enabled ? VboxColors.playerAccentGreen : Colors.white54,
              ),
              const SizedBox(width: VboxSpacing.md),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: VboxTypography.s14,
                    color: Colors.white,
                  ),
                ),
              ),
              Switch(
                value: enabled,
                onChanged: onToggle,
                activeThumbColor: VboxColors.playerAccentGreen,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ],
          ),
        ),
        if (enabled)
          Padding(
            padding: const EdgeInsets.only(bottom: VboxSpacing.sm),
            child: Row(
              children: <Widget>[
                _MinuteSecondPicker(
                  seconds: seconds,
                  onChanged: onSeconds,
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// 「分 / 秒」两档选择（对齐 iOS 双滚轮语义；用下拉替代滚轮以适配 Flutter 面板）。
class _MinuteSecondPicker extends StatelessWidget {
  const _MinuteSecondPicker({required this.seconds, this.onChanged});

  final int seconds;
  final ValueChanged<int>? onChanged;

  @override
  Widget build(BuildContext context) {
    final int minute = (seconds ~/ 60).clamp(0, 10);
    final int second = (seconds % 60).clamp(0, 59);
    return Row(
      children: <Widget>[
        _Dropdown(
          value: minute,
          max: 10,
          suffix: '分',
          onChanged: onChanged == null
              ? null
              : (int m) => onChanged!(m * 60 + second),
        ),
        const SizedBox(width: VboxSpacing.md),
        _Dropdown(
          value: second,
          max: 59,
          suffix: '秒',
          onChanged: onChanged == null
              ? null
              : (int s) => onChanged!(minute * 60 + s),
        ),
      ],
    );
  }
}

/// 单个下拉（0 ~ max，带单位后缀）。
class _Dropdown extends StatelessWidget {
  const _Dropdown({
    required this.value,
    required this.max,
    required this.suffix,
    this.onChanged,
  });

  final int value;
  final int max;
  final String suffix;
  final ValueChanged<int>? onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButton<int>(
      value: value,
      onChanged: onChanged == null
          ? null
          : (int? v) {
              if (v != null) onChanged!(v);
            },
      dropdownColor: VboxColors.playerPanelBackground,
      style: const TextStyle(fontSize: VboxTypography.s14, color: Colors.white),
      underline: const SizedBox.shrink(),
      items: <DropdownMenuItem<int>>[
        for (int i = 0; i <= max; i++)
          DropdownMenuItem<int>(
            value: i,
            child: Text('$i$suffix'),
          ),
      ],
    );
  }
}
