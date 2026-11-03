/// 表现层：字幕设置面板（UI-F5）。
///
/// 对齐 iOS `SubtitleSettingsPanel`
/// （[PlayerViewsV2.swift](../../../../vbox/Views/PlayerViewsV2.swift#L11002)）：
///  - 当前字幕状态（未加载提示 / 已加载文件名）；
///  - 「上传本地字幕文件」按钮（强调蓝 `2196F3`）+ 支持格式说明；
///  - 已加载时：显示开关 / 字号滑杆（12~32）/ 颜色三选（白·黄·青）/ 清除字幕。
///
/// 纯受控：样式与文件名经参数注入，变更即时上抛（面板内联编辑不关闭）。
library;

import 'package:flutter/material.dart';

import '../../../../platform/player/subtitle_style.dart';
import '../../../theme/tokens/colors.dart';
import '../../../theme/tokens/radii.dart';
import '../../../theme/tokens/spacing.dart';
import '../../../theme/tokens/typography.dart';
import 'player_panel_container.dart';

/// 字幕设置面板（含壳）。
class SubtitleSettingsPanel extends StatelessWidget {
  /// 构造。
  const SubtitleSettingsPanel({
    super.key,
    required this.style,
    this.fileName = '',
    this.onLoadFile,
    this.onStyleChanged,
    this.onClear,
    this.onClose,
  });

  /// 当前字幕样式。
  final SubtitleStyle style;

  /// 当前字幕文件名（空串表示未加载）。
  final String fileName;

  /// 上传本地字幕回调（null 表示不可用）。
  final VoidCallback? onLoadFile;

  /// 样式变更回调（null 表示只读）。
  final ValueChanged<SubtitleStyle>? onStyleChanged;

  /// 清除字幕回调（null 表示不可用）。
  final VoidCallback? onClear;

  /// 关闭回调。
  final VoidCallback? onClose;

  bool get _hasSubtitle => fileName.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    return PlayerPanelContainer(
      title: '字幕设置',
      onClose: onClose,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _buildStatus(),
          const SizedBox(height: VboxSpacing.md),
          _buildLoadButton(),
          const SizedBox(height: VboxSpacing.sm),
          const Text(
            '支持 SRT / VTT / ASS / SSA 格式',
            style: TextStyle(
              fontSize: VboxTypography.s11,
              color: Colors.white38,
            ),
          ),
          if (_hasSubtitle) ...<Widget>[
            const Divider(height: VboxSpacing.xl, color: Colors.white12),
            _buildVisibleSwitch(),
            const SizedBox(height: VboxSpacing.sm),
            _buildFontSize(),
            const SizedBox(height: VboxSpacing.md),
            _buildColors(),
            const SizedBox(height: VboxSpacing.lg),
            _buildClearButton(),
          ],
        ],
      ),
    );
  }

  Widget _buildStatus() {
    if (!_hasSubtitle) {
      return const Row(
        children: <Widget>[
          Icon(Icons.info_outline_rounded, size: 14, color: Colors.white54),
          SizedBox(width: VboxSpacing.sm),
          Text(
            '暂未加载字幕',
            style: TextStyle(
              fontSize: VboxTypography.s12,
              color: Colors.white54,
            ),
          ),
        ],
      );
    }
    return Row(
      children: <Widget>[
        const Icon(Icons.check_circle_rounded, size: 14, color: Colors.green),
        const SizedBox(width: VboxSpacing.sm),
        Expanded(
          child: Text(
            fileName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: VboxTypography.s12,
              fontWeight: FontWeight.w500,
              color: Colors.white,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLoadButton() {
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: onLoadFile,
        style: FilledButton.styleFrom(
          backgroundColor: VboxColors.selected,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: VboxSpacing.md),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(VboxRadii.r10),
          ),
        ),
        icon: const Icon(Icons.create_new_folder_outlined, size: 16),
        label: const Text(
          '上传本地字幕文件',
          style: TextStyle(
            fontSize: VboxTypography.s14,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _buildVisibleSwitch() {
    return Row(
      children: <Widget>[
        const Expanded(
          child: Text(
            '显示字幕',
            style: TextStyle(fontSize: VboxTypography.s14, color: Colors.white),
          ),
        ),
        Switch(
          value: style.visible,
          onChanged: onStyleChanged == null
              ? null
              : (bool v) => onStyleChanged!(style.copyWith(visible: v)),
          activeThumbColor: VboxColors.selected,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ],
    );
  }

  Widget _buildFontSize() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            const Expanded(
              child: Text(
                '字幕字号',
                style:
                    TextStyle(fontSize: VboxTypography.s14, color: Colors.white),
              ),
            ),
            Text(
              '${style.fontSize.round()}',
              style: const TextStyle(
                fontSize: VboxTypography.s14,
                fontWeight: FontWeight.w600,
                color: VboxColors.selected,
              ),
            ),
          ],
        ),
        Slider(
          value: style.fontSize.clamp(
            kSubtitleMinFontSize,
            kSubtitleMaxFontSize,
          ),
          min: kSubtitleMinFontSize,
          max: kSubtitleMaxFontSize,
          divisions: (kSubtitleMaxFontSize - kSubtitleMinFontSize).round(),
          activeColor: VboxColors.selected,
          onChanged: onStyleChanged == null
              ? null
              : (double v) => onStyleChanged!(style.copyWith(fontSize: v)),
        ),
      ],
    );
  }

  Widget _buildColors() {
    return Row(
      children: <Widget>[
        const Text(
          '字幕颜色',
          style: TextStyle(fontSize: VboxTypography.s14, color: Colors.white),
        ),
        const SizedBox(width: VboxSpacing.lg),
        for (int i = 0; i < VboxColors.subtitlePalette.length; i++)
          Padding(
            padding: const EdgeInsets.only(right: VboxSpacing.md),
            child: _ColorDot(
              color: VboxColors.subtitlePalette[i],
              selected: style.colorIndex == i,
              onTap: onStyleChanged == null
                  ? null
                  : () => onStyleChanged!(style.copyWith(colorIndex: i)),
            ),
          ),
      ],
    );
  }

  Widget _buildClearButton() {
    return SizedBox(
      width: double.infinity,
      child: TextButton.icon(
        onPressed: onClear,
        style: TextButton.styleFrom(
          foregroundColor: Colors.redAccent,
          padding: const EdgeInsets.symmetric(vertical: VboxSpacing.md),
        ),
        icon: const Icon(Icons.delete_outline_rounded, size: 16),
        label: const Text(
          '清除字幕',
          style: TextStyle(
            fontSize: VboxTypography.s14,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

/// 字幕颜色圆点（选中描蓝边）。
class _ColorDot extends StatelessWidget {
  const _ColorDot({
    required this.color,
    required this.selected,
    this.onTap,
  });

  final Color color;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? VboxColors.selected : Colors.white24,
            width: selected ? 2.5 : 0.5,
          ),
        ),
      ),
    );
  }
}
