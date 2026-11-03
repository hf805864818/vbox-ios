/// 表现层：播放器顶栏（批次 C · C-02；UI-D3 补画中画入口；UI-E2 补屏幕拉伸）。
///
/// 对齐 iOS `PlayerTopBarView`（[PlayerViewsV2.swift](../../../../vbox/Views/PlayerViewsV2.swift#L7665)）：
/// 左上「返回 + 标题 + 副标题（第 N 集 · 源）」；右上「旋转（切换横竖屏）+
/// 画中画 + 投屏 + 屏幕拉伸 + 更多」。横竖共用同一结构，仅内边距 / 字号差异（表单态由 [form] 驱动）。
///
/// 画中画入口（UI-D3，对齐 iOS L7802-L7812）：`pipEnabled` 为真才显示，
/// **不支持时置灰**（30% 白，按钮仍占位）；处于画中画时切换为「退出」图标。
///
/// 屏幕拉伸入口（UI-E2，对齐 iOS L7785 右上集群「小窗口/投屏/屏幕拉伸/三点菜单」
/// 与 L7820 `videoGravity.icon`）：`onCycleVideoGravity` 非空才显示；
/// 图标随当前模式切换（对齐 iOS 三档 SF Symbols 语义）。
///
/// 注：iOS 的方向锁定按钮固定在**屏幕左缘垂直居中**，不在顶栏内，
/// 由 [PlayerControlsView] 的锁屏覆盖层承载。
library;

import 'package:flutter/material.dart';

import '../../../domain/entities/player/player.dart';
import '../../theme/tokens/radii.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';
import '../../ui_mode/ui_mode.dart';
import '../remote_source/remote_source_status_bar.dart';

/// 播放器顶栏。
class PlayerTopBar extends StatelessWidget {
  /// 构造。
  const PlayerTopBar({
    super.key,
    required this.form,
    this.title,
    this.subtitle,
    this.onBack,
    this.onCast,
    this.showCast = true,
    this.onRotate,
    this.onTogglePip,
    this.showPip = false,
    this.pipActive = false,
    this.videoGravity = VideoGravityMode.aspectFill,
    this.onCycleVideoGravity,
    this.onToolsMenu,
  });

  /// 显示形态。
  final UiForm form;

  /// 主标题（剧名）。
  final String? title;

  /// 副标题（集数 · 源）。
  final String? subtitle;

  /// 返回回调。
  final VoidCallback? onBack;

  /// 投屏回调。
  final VoidCallback? onCast;

  /// 是否显示投屏图标（[CastService.isAvailable]；不可用则隐藏，对齐 iOS 语义）。
  final bool showCast;

  /// 旋转（切换横竖屏）回调。
  final VoidCallback? onRotate;

  /// 画中画回调（进入 / 退出）。
  final VoidCallback? onTogglePip;

  /// 是否显示画中画入口（对齐 iOS `playerState.pipEnabled`）。
  final bool showPip;

  /// 是否处于画中画中（决定图标为「退出」；对齐 iOS `isPiPActive`）。
  final bool pipActive;

  /// 画面拉伸模式（UI-E2；决定屏幕拉伸按钮图标）。
  final VideoGravityMode videoGravity;

  /// 循环切换画面拉伸模式回调（null 隐藏按钮；对齐 iOS 顶栏恒显）。
  final VoidCallback? onCycleVideoGravity;

  /// 更多菜单回调。
  final VoidCallback? onToolsMenu;

  /// 屏幕拉伸按钮图标（对齐 iOS `videoGravity.icon` 的 SF Symbols 语义）。
  static IconData gravityIcon(VideoGravityMode mode) => switch (mode) {
        // iOS `arrow.up.left.and.arrow.down.right`（四向对角展开）。
        VideoGravityMode.aspectFill => Icons.open_in_full_rounded,
        // iOS `aspectratio`（宽高比框）。
        VideoGravityMode.aspectFit => Icons.aspect_ratio_rounded,
        // iOS `arrow.left.and.right`（横向拉伸）。
        VideoGravityMode.resize => Icons.swap_horiz_rounded,
      };

  @override
  Widget build(BuildContext context) {
    final bool landscape = form.isLandscape;
    const Color foreground = Colors.white;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: landscape ? VboxSpacing.lg : VboxSpacing.md,
          vertical: VboxSpacing.sm,
        ),
        child: Row(
          children: <Widget>[
            _IconButton(
              // UI-D4 辅助功能：返回。
              tooltip: '返回',
              icon: Icons.arrow_back_ios_new_rounded,
              color: foreground,
              onTap: onBack,
            ),
            const SizedBox(width: VboxSpacing.xs),
            // 标题区（可收缩）
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (title != null)
                    // E1-3：标题超宽 → 跑马灯（复用 `MarqueeText`，对齐 iOS
                    // 顶栏 `MarqueeText` 复用位）；未超宽保持静态省略号。
                    LayoutBuilder(
                      builder: (BuildContext context, BoxConstraints c) {
                        const TextStyle style = TextStyle(
                          fontSize: VboxTypography.s16,
                          fontWeight: FontWeight.w600,
                          color: foreground,
                        );
                        final TextPainter painter = TextPainter(
                          text: TextSpan(text: title, style: style),
                          maxLines: 1,
                          textDirection: Directionality.of(context),
                        )..layout();
                        final bool overflows =
                            painter.width > c.maxWidth;
                        painter.dispose();
                        if (!overflows) {
                          return Text(
                            title!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: style,
                          );
                        }
                        return MarqueeText(
                          text: title!,
                          maxWidth: c.maxWidth,
                          fontSize: VboxTypography.s16,
                          color: foreground,
                          fontWeight: FontWeight.w600,
                        );
                      },
                    ),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: VboxTypography.s12,
                        color: Colors.white70,
                        decoration: TextDecoration.underline,
                        decorationColor: Colors.white38,
                      ),
                    ),
                ],
              ),
            ),
            // 旋转（切换横竖屏）：回调为 null（桌面端无方向概念）时隐藏，
            // 同投屏 / 拉伸按钮的 null 语义。
            if (onRotate != null)
              _IconButton(
                // UI-D4 辅助功能：旋转（进入 / 退出全屏）。
                tooltip: landscape ? '退出全屏' : '进入全屏',
                // 对齐 iOS：竖屏「转横屏」，横屏「转竖屏」。
                icon: landscape
                    ? Icons.rotate_left_rounded
                    : Icons.rotate_right_rounded,
                color: foreground,
                onTap: onRotate,
              ),
            if (showPip)
              _IconButton(
                // UI-D4 辅助功能：画中画（进入 / 退出）。
                tooltip: pipActive ? '退出画中画' : '进入画中画',
                // 对齐 iOS：画中画中显示「退出」图标，否则「进入」。
                icon: pipActive
                    ? Icons.picture_in_picture_alt_rounded
                    : Icons.picture_in_picture_alt_outlined,
                // 不支持画中画（无回调）→ 置灰（对齐 iOS `.disabled` 的 30% 白）。
                color: onTogglePip == null
                    ? Colors.white.withValues(alpha: 0.3)
                    : foreground,
                onTap: onTogglePip,
              ),
            if (showCast)
              _IconButton(
                // UI-D4 辅助功能：投屏。
                tooltip: '投屏',
                icon: Icons.cast_rounded,
                color: foreground,
                onTap: onCast,
              ),
            if (onCycleVideoGravity != null)
              _IconButton(
                // UI-D4 辅助功能：屏幕拉伸（UI-E2，循环 填充→适应→拉伸）。
                tooltip: '屏幕拉伸模式：${videoGravity.displayName}',
                icon: PlayerTopBar.gravityIcon(videoGravity),
                color: foreground,
                onTap: onCycleVideoGravity,
              ),
            _IconButton(
              // UI-D4 辅助功能：更多。
              tooltip: '更多',
              icon: Icons.more_vert_rounded,
              color: foreground,
              onTap: onToolsMenu,
            ),
          ],
        ),
      ),
    );
  }
}

/// 顶栏图标按钮（统一热区 44×44，避免散落魔数）。
class _IconButton extends StatelessWidget {
  const _IconButton({
    required this.icon,
    required this.color,
    this.onTap,
    this.tooltip,
  });

  final IconData icon;
  final Color color;
  final VoidCallback? onTap;

  /// 无障碍 / 长按提示文案（[Tooltip] 同时贡献语义标签，见 UI-D4）。
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onTap,
      tooltip: tooltip,
      icon: Icon(icon, size: 22, color: color),
      constraints: const BoxConstraints(
        minWidth: 44,
        minHeight: 44,
      ),
      padding: EdgeInsets.zero,
      style: IconButton.styleFrom(
        shape: const RoundedRectangleBorder(borderRadius: VboxRadii.button),
      ),
    );
  }
}
