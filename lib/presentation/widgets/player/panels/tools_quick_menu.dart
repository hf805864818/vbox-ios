/// 表现层：播放器工具快捷菜单（UI-F6）。
///
/// 对齐 iOS `ToolsQuickMenuV2`
/// （[PlayerViewsV2.swift](../../../../vbox/Views/PlayerViewsV2.swift#L10600)）
/// 的 8 项结构：
///  - **4 个跳转项**（右侧 chevron）：长按倍速 / 搜索弹幕 / 加载字幕 / 片头片尾；
///  - **4 个开关项**：自动播放 / 后台播放 / 画中画 / 调试浮层。
///
/// 纯受控：开关当前值 + 各跳转 / 切换回调全部经 [PlayerControlsController]
/// 注入，本组件不含任何状态。
library;

import 'package:flutter/material.dart';

import '../../../theme/tokens/colors.dart';
import '../../../theme/tokens/spacing.dart';
import '../../../theme/tokens/typography.dart';
import '../player_controls_controller.dart';
import 'player_panel_container.dart';

/// 工具快捷菜单面板（含壳）。
class ToolsQuickMenuPanel extends StatelessWidget {
  /// 构造。
  const ToolsQuickMenuPanel({
    super.key,
    required this.controller,
    this.danmakuSearchAvailable = false,
    this.onClose,
  });

  /// 控制层视图状态（开关当前值 + 回调来源）。
  final PlayerControlsController controller;

  /// 弹幕搜索入口是否可用（数据源由播放页注入；无则置灰）。
  final bool danmakuSearchAvailable;

  /// 关闭回调。
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return PlayerPanelContainer(
      title: '更多',
      onClose: onClose,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // ── 4 个跳转项（对齐 iOS 同序：长按倍速 → 搜索弹幕 → 加载字幕 → 片头片尾）──
          _MenuJumpRow(
            icon: Icons.speed_rounded,
            label: '长按倍速',
            onTap: controller.openLongPressSpeedSettings,
          ),
          _MenuJumpRow(
            icon: Icons.search_rounded,
            label: '搜索弹幕',
            onTap: danmakuSearchAvailable ? controller.openDanmakuSearch : null,
          ),
          _MenuJumpRow(
            icon: Icons.subtitles_outlined,
            label: '加载字幕',
            onTap: controller.openSubtitleSettings,
          ),
          _MenuJumpRow(
            icon: Icons.movie_outlined,
            label: '片头片尾',
            onTap: controller.openSkipSettings,
          ),
          // ── 4 个开关项（对齐 iOS 同序：自动播放 → 后台播放 → 画中画 → 调试浮层）──
          _MenuToggleRow(
            icon: Icons.play_circle_fill_rounded,
            label: '自动播放',
            value: controller.autoPlayNext,
            onChanged: controller.onToggleAutoPlayNext == null
                ? null
                : controller.setAutoPlayNext,
          ),
          _MenuToggleRow(
            icon: Icons.volume_up_rounded,
            label: '后台播放',
            value: controller.backgroundPlay,
            onChanged: controller.onToggleBackgroundPlay == null
                ? null
                : controller.setBackgroundPlay,
          ),
          _MenuToggleRow(
            icon: Icons.picture_in_picture_alt_rounded,
            label: '画中画',
            value: controller.pipEnabled,
            onChanged: controller.onTogglePipEnabled == null
                ? null
                : controller.setPipEnabled,
          ),
          _MenuToggleRow(
            icon: Icons.bug_report_rounded,
            label: '调试浮层',
            value: controller.debugOverlay,
            onChanged: controller.onToggleDebugOverlay == null
                ? null
                : controller.setDebugOverlay,
          ),
        ],
      ),
    );
  }
}

/// 菜单跳转行（图标 + 文案 + 右侧 chevron；对齐 iOS 跳转按钮）。
class _MenuJumpRow extends StatelessWidget {
  const _MenuJumpRow({
    required this.icon,
    required this.label,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final bool enabled = onTap != null;
    final Color color = enabled ? Colors.white : Colors.white38;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: VboxSpacing.sm,
          vertical: VboxSpacing.md,
        ),
        child: Row(
          children: <Widget>[
            Icon(icon, size: 20, color: color),
            const SizedBox(width: VboxSpacing.md),
            Text(
              label,
              style: TextStyle(fontSize: VboxTypography.s14, color: color),
            ),
            const Spacer(),
            Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: color.withValues(alpha: 0.6),
            ),
          ],
        ),
      ),
    );
  }
}

/// 菜单开关行（图标 + 文案 + 紧凑开关；对齐 iOS `ToolsToggleRow`）。
class _MenuToggleRow extends StatelessWidget {
  const _MenuToggleRow({
    required this.icon,
    required this.label,
    required this.value,
    this.onChanged,
  });

  final IconData icon;
  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final bool enabled = onChanged != null;
    final Color color = enabled ? Colors.white : Colors.white38;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: VboxSpacing.sm,
        vertical: VboxSpacing.xs,
      ),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 20, color: color),
          const SizedBox(width: VboxSpacing.md),
          Expanded(
            child: Text(
              label,
              style: TextStyle(fontSize: VboxTypography.s14, color: color),
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: VboxColors.playerAccentGreen,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ],
      ),
    );
  }
}
