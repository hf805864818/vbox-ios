/// 表现层：视频区手势提示浮层（第 3 批 · UI-F1）。
///
/// 手势调节过程中在画面中央显示当前值（对齐 iOS 手势 HUD 语义）：
///  - 亮度 / 音量：图标 + 百分比 + 进度条；
///  - 快进 / 快退：`当前 / 总时长` 文案。
library;

import 'package:flutter/material.dart';

import '../../../platform/player/gesture/gesture_control.dart';
import '../../theme/tokens/colors.dart';
import '../../theme/tokens/radii.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';

/// 手势提示浮层（居中；不拦截手势）。
class PlayerGestureHud extends StatelessWidget {
  /// 构造。
  const PlayerGestureHud({super.key, required this.adjustment});

  /// 本次调节结果。
  final GestureAdjustment adjustment;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: IgnorePointer(
        child: Container(
          padding: VboxSpacing.symmetric(
            horizontal: VboxSpacing.xxl,
            vertical: VboxSpacing.lg,
          ),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.72),
            borderRadius: VboxRadii.card,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(_icon, size: 32, color: Colors.white),
              const SizedBox(height: VboxSpacing.sm),
              Text(
                adjustment.label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: VboxTypography.s16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (_barValue != null) ...<Widget>[
                const SizedBox(height: VboxSpacing.md),
                _GestureBar(value: _barValue!),
              ],
            ],
          ),
        ),
      ),
    );
  }

  IconData get _icon => switch (adjustment.mode) {
        GestureMode.brightness => Icons.brightness_6_rounded,
        GestureMode.volume => Icons.volume_up_rounded,
        GestureMode.seek => Icons.fast_forward_rounded,
        GestureMode.ignored => Icons.tune_rounded,
      };

  /// 进度条取值（seek 无进度条；亮度 / 音量取 0.0 ~ 1.0）。
  double? get _barValue => switch (adjustment.mode) {
        GestureMode.brightness => adjustment.brightness,
        GestureMode.volume => adjustment.volume,
        GestureMode.seek || GestureMode.ignored => null,
      };
}

/// 亮度 / 音量进度条。
class _GestureBar extends StatelessWidget {
  const _GestureBar({required this.value});

  final double value;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 140,
      height: 4,
      child: ClipRRect(
        borderRadius: VboxRadii.badge,
        child: LinearProgressIndicator(
          value: value.clamp(0.0, 1.0),
          backgroundColor: Colors.white.withValues(alpha: 0.25),
          valueColor: const AlwaysStoppedAnimation<Color>(
            VboxColors.playerAccentCyan,
          ),
        ),
      ),
    );
  }
}
