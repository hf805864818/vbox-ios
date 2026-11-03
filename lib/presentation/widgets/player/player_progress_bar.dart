/// 表现层：播放器进度条（批次 C · C-02）。
///
/// 对齐 iOS `PlayerProgressBar`（[PlayerViewsV2.swift](../../../../vbox/Views/PlayerViewsV2.swift#L7948)）：
/// 当前时间 + 可拖拽进度条 + 总时长；直播流禁用拖拽（仍显示时间）。
/// 纯受控：数值来自 [PlayerControlsController]，拖拽结束经 [onSeek] 上抛。
library;

import 'package:flutter/material.dart';

import '../../theme/tokens/colors.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';
import '../../ui_mode/ui_mode.dart';

/// 播放器进度条。
class PlayerProgressBar extends StatelessWidget {
  /// 构造。
  const PlayerProgressBar({
    super.key,
    required this.positionMs,
    required this.durationMs,
    this.bufferedMs = 0,
    this.isLive = false,
    this.form = UiForm.portrait,
    this.onSeek,
  });

  /// 显示形态（决定轨道粗细 / 滑块大小；对齐 iOS 竖 3pt / 横 4pt）。
  final UiForm form;

  /// 当前进度（毫秒）。
  final int positionMs;

  /// 总时长（毫秒；直播或未知为 0）。
  final int durationMs;

  /// 缓冲进度（毫秒）。
  final int bufferedMs;

  /// 是否直播流。
  final bool isLive;

  /// 拖拽结束回调（毫秒）。
  final void Function(int positionMs)? onSeek;

  @override
  Widget build(BuildContext context) {
    final bool seekable = !isLive && durationMs > 0;
    final bool landscape = form.isLandscape;
    final double max = seekable ? durationMs.toDouble() : 1.0;
    final double value =
        seekable ? positionMs.toDouble().clamp(0.0, max) : 0.0;
    final double buffered =
        seekable ? (bufferedMs / max).clamp(0.0, 1.0) : 0.0;

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: landscape ? VboxSpacing.lg : VboxSpacing.md,
        vertical: landscape ? VboxSpacing.sm : VboxSpacing.xs,
      ),
      child: Row(
        children: <Widget>[
          _TimeLabel(
            text: _fmt(positionMs),
            landscape: landscape,
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                // 轨道粗细 / 滑块大小对齐 iOS（竖 3pt·10pt，横 4pt·14pt）。
                trackHeight: landscape ? 4.0 : 3.0,
                thumbShape: RoundSliderThumbShape(
                  enabledThumbRadius: landscape ? 7.0 : 5.0,
                ),
                activeTrackColor: VboxColors.playerAccentCyan,
                inactiveTrackColor: Colors.white30,
                secondaryActiveTrackColor:
                    VboxColors.playerAccentCyan.withValues(alpha: 0.28),
                thumbColor: VboxColors.playerAccentCyan,
                overlayShape: RoundSliderOverlayShape(
                  overlayRadius: landscape ? 16.0 : 14.0,
                ),
              ),
              child: Slider(
                value: value,
                max: max,
                secondaryTrackValue: seekable ? buffered : null,
                onChanged: seekable ? (double v) {} : null,
                onChangeEnd: seekable && onSeek != null
                    ? (double v) => onSeek!(v.round())
                    : null,
              ),
            ),
          ),
          _TimeLabel(
            text: isLive ? '直播' : _fmt(durationMs),
            secondary: true,
            landscape: landscape,
          ),
        ],
      ),
    );
  }

  static String _fmt(int ms) {
    final int totalSec = ms ~/ 1000;
    final int h = totalSec ~/ 3600;
    final int m = (totalSec % 3600) ~/ 60;
    final int s = totalSec % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    return h > 0 ? '${two(h)}:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }
}

/// 时间标签。
class _TimeLabel extends StatelessWidget {
  const _TimeLabel({
    required this.text,
    this.secondary = false,
    this.landscape = false,
  });

  final String text;
  final bool secondary;
  final bool landscape;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 52,
      child: Text(
        text,
        textAlign: secondary ? TextAlign.right : TextAlign.left,
        style: TextStyle(
          // 对齐 iOS：竖屏 10pt / 横屏 12pt。
          fontSize: landscape ? VboxTypography.s12 : VboxTypography.s10,
          color: secondary ? Colors.white70 : Colors.white,
          fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}
