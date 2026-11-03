/// 表现层：弹幕设置面板（批次 C · C-03）。
///
/// 会话级参数：开关 / 不透明度 / 字号 / 显示区域；自定义弹幕源仅展示
/// 开关与地址（配置入口在设置页，契约键见 `DanmakuSettings`）。
/// 纯受控组件：变更经 [onChanged] 回抛，不做内部状态。
library;

import 'package:flutter/material.dart';

import '../../../../platform/player/danmaku/danmaku_settings.dart';

/// 弹幕设置面板。
class DanmakuSettingsPanel extends StatelessWidget {
  /// 颜色档标签（对齐 iOS `colorLabels`：原始/白色/黄色/绿色/蓝色/红色/粉色/随机）。
  static const List<String> colorLabels = <String>[
    '原始', '白色', '黄色', '绿色', '蓝色', '红色', '粉色', '随机',
  ];

  /// 构造。
  const DanmakuSettingsPanel({
    super.key,
    required this.settings,
    required this.onChanged,
  });

  /// 当前设置。
  final DanmakuSettings settings;

  /// 变更回调。
  final ValueChanged<DanmakuSettings> onChanged;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SwitchListTile(
            dense: true,
            title: const Text('弹幕开关'),
            value: settings.enabled,
            onChanged: (bool v) => onChanged(settings.copyWith(enabled: v)),
          ),
          if (settings.enabled) ..._displaySliders(context),
          const Divider(height: 1),
          SwitchListTile(
            dense: true,
            title: const Text('自定义弹幕源'),
            subtitle: settings.customSourceEnabled
                ? Text(
                    settings.customSourceUrl.isEmpty
                        ? '已开启（地址为空）'
                        : settings.customSourceUrl,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  )
                : null,
            value: settings.customSourceEnabled,
            onChanged: (bool v) =>
                onChanged(settings.copyWith(customSourceEnabled: v)),
          ),
        ],
      ),
    );
  }

  List<Widget> _displaySliders(BuildContext context) => <Widget>[
        _sliderTile(
          context,
          label: '不透明度 ${(settings.opacity * 100).round()}%',
          value: settings.opacity,
          min: 0.1,
          max: 1.0,
          divisions: 9,
          onChanged: (double v) => onChanged(settings.copyWith(opacity: v)),
        ),
        _sliderTile(
          context,
          label: '字号 ${settings.fontSize.round()}px',
          value: settings.fontSize,
          min: 10,
          max: 32,
          divisions: 22,
          onChanged: (double v) => onChanged(settings.copyWith(fontSize: v)),
        ),
        _sliderTile(
          context,
          label: '显示区域 ${(settings.area * 100).round()}%',
          value: settings.area,
          min: 0.25,
          max: 1.0,
          divisions: 7,
          onChanged: (double v) => onChanged(settings.copyWith(area: v)),
        ),
        // 弹幕显示速度（对齐 iOS「显示速度」Section：segmented 5 档）。
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('弹幕显示速度'),
          subtitle: SegmentedButton<int>(
            segments: <ButtonSegment<int>>[
              for (final (int idx, String label)
                  in DanmakuSettings.speedLabels.indexed)
                ButtonSegment<int>(
                  value: idx,
                  label: Text(
                    label,
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
            ],
            selected: <int>{
              DanmakuSettings.speedValues.indexOf(
                DanmakuSettings.speedValues.reduce(
                  (double a, double b) =>
                      (a - settings.speed).abs() <= (b - settings.speed).abs()
                          ? a
                          : b,
                ),
              ),
            },
            showSelectedIcon: false,
            onSelectionChanged: (Set<int> selection) => onChanged(
              settings.copyWith(
                speed: DanmakuSettings.speedValues[selection.first],
              ),
            ),
          ),
        ),
        // 弹幕颜色（对齐 iOS「弹幕颜色」Section：segmented 8 档）。
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('弹幕颜色'),
          subtitle: SegmentedButton<int>(
            segments: <ButtonSegment<int>>[
              for (final (int idx, String label) in colorLabels.indexed)
                ButtonSegment<int>(
                  value: idx,
                  label: Text(
                    label,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
            ],
            selected: <int>{settings.colorMode},
            showSelectedIcon: false,
            onSelectionChanged: (Set<int> selection) =>
                onChanged(settings.copyWith(colorMode: selection.first)),
          ),
        ),
      ];

  Widget _sliderTile(
    BuildContext context, {
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required ValueChanged<double> onChanged,
  }) =>
      ListTile(
        dense: true,
        title: Text(label),
        subtitle: Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          onChanged: onChanged,
        ),
      );
}
