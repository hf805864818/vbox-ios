/// 表现层：播放器底部控制栏（批次 C · C-02，横竖双态）。
///
/// 对齐 iOS `PortraitBottomBar` / `LandscapeBottomBar`
/// （[PlayerViewsV2.swift](../../../../vbox/Views/PlayerViewsV2.swift#L8024)）：
///  - 竖屏：左 [播放/暂停 · 下一集 · 弹幕开关 · 弹幕设置] ＋ 右 [倍速 · 清晰度 · 选集]
///  - 横屏：左同上 ＋ 中间弹幕输入框 ＋ 右 [倍速 · 清晰度 · 选集 · 内核]
///
/// 纯受控：直接消费 [PlayerControlsController]（动作经其回调字段上抛）。
library;

import 'package:flutter/material.dart';

import '../../../domain/entities/player/player.dart';
import '../../theme/tokens/colors.dart';
import '../../theme/tokens/radii.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';
import 'player_controls_controller.dart';

/// 播放器底部控制栏。
class PlayerBottomBar extends StatelessWidget {
  /// 构造。
  const PlayerBottomBar({super.key, required this.controller});

  /// 控制层视图状态。
  final PlayerControlsController controller;

  @override
  Widget build(BuildContext context) {
    final bool landscape = controller.form.isLandscape;
    final List<Widget> left = <Widget>[
      _PlayButton(controller: controller),
      _NextButton(controller: controller),
      if (controller.hasDanmaku) ...<Widget>[
        _DanmakuButton(controller: controller),
        _DanmakuSettingsButton(controller: controller),
      ],
    ];
    final List<Widget> right = <Widget>[
      _SpeedButton(controller: controller),
      if (controller.hasQuality) _QualityButton(controller: controller),
      _EpisodeButton(controller: controller),
      if (landscape) _EngineButton(controller: controller),
    ];

    return Padding(
      padding: EdgeInsets.only(
        left: landscape ? VboxSpacing.lg : VboxSpacing.sm,
        right: landscape ? VboxSpacing.lg : VboxSpacing.sm,
        bottom: landscape ? VboxSpacing.xl : VboxSpacing.md,
      ),
      child: Row(
        children: <Widget>[
          ...left,
          if (landscape) ...<Widget>[
            const Spacer(),
            _DanmakuInputPill(onTap: controller.onSendDanmaku),
          ],
          const Spacer(),
          ...right,
        ],
      ),
    );
  }
}

// ─────────── 左侧按钮 ───────────

class _PlayButton extends StatelessWidget {
  const _PlayButton({required this.controller});

  final PlayerControlsController controller;

  @override
  Widget build(BuildContext context) {
    final bool enabled = controller.onTogglePlay != null;
    return _BarButton(
      tooltip: controller.isPlaying ? '暂停' : '播放',
      onTap: enabled ? controller.togglePlay : null,
      child: Icon(
        controller.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
        size: 26,
        color: enabled ? Colors.white : Colors.white38,
      ),
    );
  }
}

class _NextButton extends StatelessWidget {
  const _NextButton({required this.controller});

  final PlayerControlsController controller;

  @override
  Widget build(BuildContext context) {
    final bool enabled = controller.onNextEpisode != null;
    return _BarButton(
      tooltip: '下一集',
      onTap: enabled ? controller.goNextEpisode : null,
      child: Icon(
        Icons.skip_next_rounded,
        size: 26,
        color: enabled ? Colors.white : Colors.white38,
      ),
    );
  }
}

class _DanmakuButton extends StatelessWidget {
  const _DanmakuButton({required this.controller});

  final PlayerControlsController controller;

  @override
  Widget build(BuildContext context) {
    final bool on = controller.showDanmaku;
    return _BarButton(
      tooltip: '弹幕',
      onTap: controller.onToggleDanmaku,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Text(
            '弹',
            style: TextStyle(
              fontSize: VboxTypography.s16,
              fontWeight: FontWeight.w700,
              color: on ? VboxColors.playerAccentGreen : Colors.white60,
            ),
          ),
          if (on)
            Positioned(
              right: -6,
              top: -2,
              child: Container(
                width: 10,
                height: 10,
                decoration: const BoxDecoration(
                  color: VboxColors.playerAccentGreen,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.check,
                  size: 8,
                  color: Colors.white,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _DanmakuSettingsButton extends StatelessWidget {
  const _DanmakuSettingsButton({required this.controller});

  final PlayerControlsController controller;

  @override
  Widget build(BuildContext context) {
    return _BarButton(
      tooltip: '弹幕设置',
      onTap: controller.onToggleDanmakuSettings,
      child: const Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Text(
            '弹',
            style: TextStyle(
              fontSize: VboxTypography.s16,
              fontWeight: FontWeight.w700,
              color: Colors.white60,
            ),
          ),
          Positioned(
            right: -8,
            top: -2,
            child: Icon(
              Icons.settings_rounded,
              size: 10,
              color: Colors.white70,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────── 中间弹幕输入（仅横屏）───────────

class _DanmakuInputPill extends StatelessWidget {
  const _DanmakuInputPill({this.onTap});

  /// 点击回调（弹出弹幕输入框；null 表示不可用）。
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(VboxRadii.r20),
      child: Container(
        height: 36,
        constraints: const BoxConstraints(maxWidth: 200),
        padding: const EdgeInsets.symmetric(horizontal: VboxSpacing.lg),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          color: Colors.white12,
          borderRadius: BorderRadius.circular(VboxRadii.r20),
        ),
        child: const Text(
          '请文明发送弹幕',
          style: TextStyle(
            fontSize: VboxTypography.s13,
            color: VboxColors.playerAccentGreen,
          ),
        ),
      ),
    );
  }
}

// ─────────── 右侧按钮 ───────────

class _SpeedButton extends StatelessWidget {
  const _SpeedButton({required this.controller});

  final PlayerControlsController controller;

  @override
  Widget build(BuildContext context) {
    final bool active = controller.showSpeedPicker;
    return _BarButton(
      tooltip: '倍速',
      onTap: controller.onSelectSpeed != null
          ? controller.openSpeedPicker
          : null,
      child: Text(
        controller.speedDisplayText,
        style: TextStyle(
          fontSize: VboxTypography.s14,
          fontWeight: FontWeight.w500,
          color: active ? VboxColors.playerAccentGreen : Colors.white,
        ),
      ),
    );
  }
}

class _QualityButton extends StatelessWidget {
  const _QualityButton({required this.controller});

  final PlayerControlsController controller;

  @override
  Widget build(BuildContext context) {
    // 对齐 iOS：清晰度按钮恒白，无激活高亮。
    return _BarButton(
      tooltip: '清晰度',
      onTap: controller.onSelectQuality != null
          ? controller.openQualityPicker
          : null,
      child: Text(
        controller.qualityDisplayText,
        style: const TextStyle(
          fontSize: VboxTypography.s14,
          fontWeight: FontWeight.w500,
          color: Colors.white,
        ),
      ),
    );
  }
}

class _EpisodeButton extends StatelessWidget {
  const _EpisodeButton({required this.controller});

  final PlayerControlsController controller;

  @override
  Widget build(BuildContext context) {
    // 对齐 iOS：选集按钮恒白，无激活高亮。
    return _BarButton(
      tooltip: '选集',
      onTap: controller.onSelectEpisode != null
          ? controller.openEpisodePicker
          : null,
      child: const Text(
        '选集',
        style: TextStyle(
          fontSize: VboxTypography.s14,
          fontWeight: FontWeight.w500,
          color: Colors.white,
        ),
      ),
    );
  }
}

class _EngineButton extends StatelessWidget {
  const _EngineButton({required this.controller});

  final PlayerControlsController controller;

  @override
  Widget build(BuildContext context) {
    final bool enabled = controller.onSelectBackend != null;
    // 对齐 iOS：兼容（回退）内核文字用青色标识，其余白；不可用灰。
    final bool compatibility = controller.currentBackend == PlayerBackend.libVLC ||
        controller.currentBackend == PlayerBackend.libmpv;
    final Color color = !enabled
        ? Colors.white38
        : (compatibility ? VboxColors.playerAccentCyan : Colors.white);
    return _BarButton(
      tooltip: '内核',
      onTap: enabled ? controller.openEnginePicker : null,
      child: Text(
        controller.backendDisplayText,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: VboxTypography.s14,
          fontWeight: FontWeight.w500,
          color: color,
        ),
      ),
    );
  }
}

// ─────────── 通用按钮 ───────────

/// 底栏按钮（48×44 热区，对齐 iOS 触控规格）。
class _BarButton extends StatelessWidget {
  const _BarButton({
    required this.child,
    this.tooltip,
    this.onTap,
  });

  final Widget child;
  final String? tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip ?? '',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: 48,
          height: 44,
          child: Center(child: child),
        ),
      ),
    );
  }
}
