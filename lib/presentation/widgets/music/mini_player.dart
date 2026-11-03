/// 表现层：音乐迷你播放器（批次 G · G-01 首段）。
///
/// 对齐基准（唯一真相源）：iOS `MiniPlayerBar`
/// （`vbox/Views/MusicPlayerViews.swift:11`）。
///
/// 交互：
///  - 左滑 → 浮现红色关闭钮，点击关闭浮层并停播；
///  - 右滑 → 折叠为左边缘小胶囊，点击胶囊展开；
///  - 上下拖动 → 在顶部余量 ↔ 底部基准之间移动；
///  - 点击主体 → 展开全屏播放器（[onExpand]，全屏页后续批次交付）。
///
/// 用法：置于 `Stack` 的 `Positioned.fill` 覆盖层内（对齐 iOS `.overlay(alignment: .bottom)`）。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../domain/entities/music/music.dart';
import '../../../platform/player/music_player.dart';
import '../../theme/tokens/colors.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';
import '../platform_async_image.dart';

/// 音乐迷你播放器浮层。
class MiniPlayerBar extends StatefulWidget {
  /// 构造。
  const MiniPlayerBar({super.key, this.controller, this.onExpand});

  /// 播放控制器（缺省取全局单例）。
  final MusicPlayerController? controller;

  /// 点击主体（展开全屏播放器）。
  final VoidCallback? onExpand;

  /// 展开态横条宽度。
  static const double barWidth = 320;

  /// 折叠态小胶囊宽度。
  static const double collapsedWidth = 52;

  /// 展开态高度。
  static const double expandedHeight = 60;

  /// 折叠态高度。
  static const double collapsedHeight = 52;

  /// 左右留白。
  static const double horizontalMargin = 12;

  /// 底部基准留白（抬升到悬浮底栏之上）。
  static const double bottomMargin = 66;

  /// 顶部安全余量。
  static const double topReserve = 100;

  /// 折叠 / 左滑判定阈值（水平）。
  static const double collapseThreshold = 60;

  /// 左滑显示关闭钮阈值。
  static const double closeRevealThreshold = 50;

  @override
  State<MiniPlayerBar> createState() => _MiniPlayerBarState();
}

class _MiniPlayerBarState extends State<MiniPlayerBar> {
  late final MusicPlayerController _player =
      widget.controller ?? MusicPlayerController.instance;

  double _positionY = 0;
  bool _isCollapsed = false;
  bool _isDragging = false;
  Offset _dragOffset = Offset.zero;
  bool _showClose = false;

  void _finalizeDrag(double containerHeight) {
    final double dx = _dragOffset.dx;
    final double dy = _dragOffset.dy;

    if (_isCollapsed) {
      if (dy.abs() > math.max(dx.abs(), 20)) {
        _moveVertically(-dy, containerHeight);
      }
      return;
    }

    if (dx.abs() > dy.abs()) {
      if (dx < -MiniPlayerBar.closeRevealThreshold) {
        setState(() => _showClose = true);
      } else if (dx > MiniPlayerBar.collapseThreshold) {
        setState(() {
          _showClose = false;
          _isCollapsed = true;
        });
      } else {
        setState(() => _showClose = false);
      }
      return;
    }

    _moveVertically(-dy, containerHeight);
  }

  void _moveVertically(double delta, double containerHeight) {
    final double barHeight =
        _isCollapsed ? MiniPlayerBar.collapsedHeight : MiniPlayerBar.expandedHeight;
    final double maxUp = math.max(
      containerHeight -
          barHeight -
          MiniPlayerBar.bottomMargin -
          MiniPlayerBar.topReserve,
      0,
    );
    setState(() {
      _positionY = (_positionY + delta).clamp(0, maxUp);
      _showClose = false;
    });
  }

  Future<void> _close() async {
    setState(() {
      _showClose = false;
      _isCollapsed = false;
      _positionY = 0;
    });
    await _player.stop();
  }

  void _onTap() {
    if (_isCollapsed) {
      setState(() => _isCollapsed = false);
      return;
    }
    if (_showClose) {
      setState(() => _showClose = false);
      return;
    }
    widget.onExpand?.call();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _player,
      builder: (BuildContext context, Widget? _) {
        final MusicQueueItem? song = _player.currentSong;
        if (song == null) return const SizedBox.shrink();
        return LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final double width = constraints.maxWidth;
            final double height = constraints.maxHeight;
            final double barHeight = _isCollapsed
                ? MiniPlayerBar.collapsedHeight
                : MiniPlayerBar.expandedHeight;
            final double baseBottom =
                math.max(height - barHeight - MiniPlayerBar.bottomMargin, 0);
            final double liveUp =
                _isDragging ? _positionY - _dragOffset.dy : _positionY;
            final double reveal = _showClose
                ? 1
                : (_isDragging && _dragOffset.dx < 0
                    ? math.min(1, -_dragOffset.dx / 80)
                    : 0);
            final double left = _isCollapsed
                ? MiniPlayerBar.horizontalMargin
                : (width - MiniPlayerBar.barWidth) / 2;

            return Stack(
              children: <Widget>[
                Positioned(
                  left: left,
                  top: baseBottom - liveUp,
                  child: GestureDetector(
                    key: const ValueKey<String>('mini_player_bar'),
                    behavior: HitTestBehavior.opaque,
                    onTap: _onTap,
                    onPanStart: (_) => setState(() => _isDragging = true),
                    onPanUpdate: (DragUpdateDetails d) =>
                        setState(() => _dragOffset += d.delta),
                    onPanEnd: (_) {
                      _finalizeDrag(height);
                      setState(() {
                        _isDragging = false;
                        _dragOffset = Offset.zero;
                      });
                    },
                    child: _buildBar(context, song, barHeight, reveal),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildBar(
    BuildContext context,
    MusicQueueItem song,
    double barHeight,
    double reveal,
  ) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color accent = scheme.primary;

    final double targetWidth =
        _isCollapsed ? MiniPlayerBar.collapsedWidth : MiniPlayerBar.barWidth;
    final double padLeft = _isCollapsed ? VboxSpacing.sm : VboxSpacing.lg;
    final double padRight = _isCollapsed
        ? VboxSpacing.sm
        : (reveal > 0.1 ? VboxSpacing.xxl + VboxSpacing.md : VboxSpacing.lg);
    // 内容按目标宽度定尺，宽度动画期间由 OverflowBox + ClipRect 裁剪，
    // 避免收缩 / 展开过渡中 Row 被压窄而溢出（对齐 iOS 的裁剪行为）。
    final double contentWidth = targetWidth - padLeft - padRight;

    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: targetWidth,
          height: barHeight,
          padding: EdgeInsets.only(left: padLeft, right: padRight),
          clipBehavior: Clip.hardEdge,
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.94),
            borderRadius: BorderRadius.circular(_isCollapsed ? 22 : VboxSpacing.md),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.15),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: OverflowBox(
            alignment: Alignment.center,
            minWidth: contentWidth,
            maxWidth: contentWidth,
            minHeight: 0,
            maxHeight: barHeight,
            child: SizedBox(
              width: contentWidth,
              child: _isCollapsed
                  ? _collapsedContent(song)
                  : _expandedContent(scheme, accent, song),
            ),
          ),
        ),
        if (!_isCollapsed)
          Positioned(
            right: VboxSpacing.sm,
            top: 0,
            bottom: 0,
            child: IgnorePointer(
              ignoring: reveal <= 0.1,
              child: Center(
                child: MiniPlayerCloseButton(
                  opacity: reveal,
                  onPressed: _close,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _collapsedContent(MusicQueueItem song) {
    return Center(child: _cover(song, MiniPlayerBar.collapsedWidth - VboxSpacing.lg));
  }

  Widget _expandedContent(ColorScheme scheme, Color accent, MusicQueueItem song) {
    final double progress = _player.duration.inMilliseconds <= 0
        ? 0
        : (_player.position.inMilliseconds / _player.duration.inMilliseconds)
            .clamp(0.0, 1.0);

    return Row(
      children: <Widget>[
        _cover(song, 44),
        const SizedBox(width: VboxSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Text(
                song.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: VboxTypography.s13,
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (_player.duration.inMilliseconds > 0) ...<Widget>[
                const SizedBox(height: VboxSpacing.xs),
                LinearProgressIndicator(
                  value: progress,
                  minHeight: 3,
                  backgroundColor: scheme.outlineVariant.withValues(alpha: 0.4),
                  valueColor: AlwaysStoppedAnimation<Color>(accent),
                ),
              ],
            ],
          ),
        ),
        IconButton(
          key: const ValueKey<String>('mini_player_play_pause'),
          onPressed: _player.togglePlayPause,
          icon: Icon(
            _player.isPlaying ? Icons.pause_circle_filled : Icons.play_circle_fill,
            size: 30,
            color: accent,
          ),
        ),
        IconButton(
          key: const ValueKey<String>('mini_player_next'),
          onPressed: _player.canSkip ? _player.playNext : null,
          icon: const Icon(Icons.skip_next, size: 22),
        ),
      ],
    );
  }

  Widget _cover(MusicQueueItem song, double size) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(VboxSpacing.sm),
      child: SizedBox(
        width: size,
        height: size,
        child: PlatformAsyncImage(url: song.coverURL, fit: BoxFit.cover),
      ),
    );
  }
}

/// 左滑后浮现的关闭钮（红色圆钮）。
class MiniPlayerCloseButton extends StatelessWidget {
  /// 构造。
  const MiniPlayerCloseButton({super.key, required this.onPressed, this.opacity = 1});

  /// 点击回调。
  final VoidCallback onPressed;

  /// 浮现程度（0–1）。
  final double opacity;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: opacity,
      child: IconButton(
        key: const ValueKey<String>('mini_player_close'),
        onPressed: onPressed,
        iconSize: VboxTypography.s16,
        style: IconButton.styleFrom(
          backgroundColor: VboxColors.danger,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.all(VboxSpacing.xs),
          minimumSize: const Size(28, 28),
        ),
        icon: const Icon(Icons.close),
      ),
    );
  }
}
