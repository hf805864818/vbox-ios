/// 表现层：远程源加载状态胶囊（UI-D1）。
///
/// 唯一真相源：iOS `vbox/Views/RemoteSourceStatusBar.swift`（配合
/// `RemoteSourceConfigManager.loadState` 驱动）。位置对齐 iOS `ContentView`
/// L88-L91：底栏正上方居中，位于下载胶囊之上（同为底栏区浮层）。
///
/// 行为（逐条对齐 iOS）：
///   · `idle` → 隐藏；
///   · `loading` → 显示且**不自动消失**（直到同步完成 / 失败切换状态）；
///   · `loadedRemote` / `loadedCache` → 显示，**4s** 后自动消失；
///   · `failed` → 显示，**8s** 后自动消失；
///   · 文字超长自动跑马灯滚动（[MarqueeText]），进出场为「上移 + 淡入 + 缩放」。
///
/// 差异登记：
///   · SF Symbols → Material 图标映射（[_statusIcon]）；
///   · iOS 用 `MarqueeText` 的「停留 → 循环滚动 → 回位」三段式，Flutter 侧
///     简化为单程匀速循环（不改变「超长即滚动」的用户可感知语义）；
///   · 浮层底部间距取 55（对齐 iOS `VStack(spacing: 0)` 紧贴排列：底栏
///     `bottomGap 8` + 底栏胶囊高 ~47 → 顶边距屏底 ~55，胶囊零间距贴底栏
///     顶边；下载胶囊通知 bottom:90 在其上方，并集时 3px 缝相邻不重叠）。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../data/datasources/remote/remote_source_config_manager.dart';
import '../../../domain/entities/remote_source/remote_source.dart';
import '../../theme/tokens/colors.dart';
import '../../theme/tokens/radii.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';

/// 状态 → (图标, 文案, 主色)。
({IconData icon, String message, Color color}) _statusInfo(
  RemoteLoadStatus status,
  String lastConfigVersion,
) {
  switch (status.state) {
    case RemoteLoadState.idle:
      return (
        icon: Icons.settings_input_antenna,
        message: '远程源待同步',
        color: VboxColors.systemGray2Light,
      );
    case RemoteLoadState.loading:
      return (
        icon: Icons.sync,
        message: '远程源同步中...请同步完成后再使用',
        color: VboxColors.remoteSourceAccent,
      );
    case RemoteLoadState.loadedRemote:
      return (
        icon: Icons.cloud_done,
        message: '远程源已更新 v${status.version ?? ''}',
        color: VboxColors.success,
      );
    case RemoteLoadState.loadedCache:
      return (
        icon: Icons.cloud_download,
        message: '远程暂无更新资源，已用缓存 v${status.version ?? ''}',
        color: VboxColors.warning,
      );
    case RemoteLoadState.failed:
      return (
        icon: Icons.warning_amber_rounded,
        message: '远程源失败请手动更新，已用缓存 v$lastConfigVersion',
        color: VboxColors.danger,
      );
  }
}

/// 远程源加载状态胶囊 — 悬浮在底栏上方居中显示，文字超长自动滚动。
class RemoteSourceStatusBar extends StatefulWidget {
  /// 构造。
  const RemoteSourceStatusBar({super.key});

  @override
  State<RemoteSourceStatusBar> createState() => _RemoteSourceStatusBarState();
}

class _RemoteSourceStatusBarState extends State<RemoteSourceStatusBar> {
  RemoteSourceConfigManager? _manager;
  bool _visible = false;
  RemoteLoadStatus _status = const RemoteLoadStatus.idle();
  Timer? _dismissTimer;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final RemoteSourceConfigManager manager = RemoteSourceConfigManager.shared;
    if (identical(manager, _manager)) return;
    _manager?.loadState.removeListener(_onStateChanged);
    _manager = manager;
    manager.loadState.addListener(_onStateChanged);
    // 首帧对齐 iOS `.onAppear`：非 idle 时按当前状态立即处理（不发 setState，
    // 紧接着就会 build）。
    _status = manager.loadState.value;
    _visible = _status.state != RemoteLoadState.idle;
    _scheduleDismissIfNeeded(_status);
  }

  @override
  void dispose() {
    _manager?.loadState.removeListener(_onStateChanged);
    _dismissTimer?.cancel();
    super.dispose();
  }

  void _onStateChanged() {
    final RemoteLoadStatus? status = _manager?.loadState.value;
    if (status != null) _handleStateChange(status);
  }

  void _handleStateChange(RemoteLoadStatus status) {
    _dismissTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _status = status;
      _visible = status.state != RemoteLoadState.idle;
    });
    _scheduleDismissIfNeeded(status);
  }

  /// 按状态调度自动消失（loading / idle 不消失，对齐 iOS）。
  void _scheduleDismissIfNeeded(RemoteLoadStatus status) {
    final Duration? delay = switch (status.state) {
      RemoteLoadState.loadedRemote || RemoteLoadState.loadedCache =>
        const Duration(seconds: 4),
      RemoteLoadState.failed => const Duration(seconds: 8),
      RemoteLoadState.idle || RemoteLoadState.loading => null,
    };
    if (delay == null) return;
    _dismissTimer = Timer(delay, () {
      if (mounted) setState(() => _visible = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final String lastVersion = _manager?.lastConfigVersion ?? '';
    final ({IconData icon, String message, Color color}) info =
        _statusInfo(_status, lastVersion);

    return IgnorePointer(
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          // 对齐 iOS `VStack(spacing: 0)`：胶囊底边紧贴底栏顶边（底栏
          // bottomGap 8 + 胶囊高 ~47 ≈ 55）。不可再加大——此前 132 会让
          // 胶囊悬空 75pt，日常态（下载通知空）下明显脱离底栏。
          padding: const EdgeInsets.only(bottom: 55),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeOut,
            transitionBuilder: (Widget child, Animation<double> animation) {
              return FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, 0.5),
                    end: Offset.zero,
                  ).animate(animation),
                  child: ScaleTransition(
                    scale: Tween<double>(begin: 0.9, end: 1).animate(animation),
                    child: child,
                  ),
                ),
              );
            },
            child: _visible
                ? _CapsuleBody(
                    key: ValueKey<String>(
                      '${_status.state}-${_status.version}-${_status.message}',
                    ),
                    icon: info.icon,
                    message: info.message,
                    color: info.color,
                  )
                : const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }
}

/// 胶囊本体（实色填充 + 同色描边 + 阴影，对齐 iOS `statusInfo`）。
class _CapsuleBody extends StatelessWidget {
  const _CapsuleBody({
    super.key,
    required this.icon,
    required this.message,
    required this.color,
  });

  final IconData icon;
  final String message;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: VboxSpacing.md + 2,
        vertical: VboxSpacing.xs + 3,
      ),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(VboxRadii.capsule),
        border: Border.all(color: color.withValues(alpha: 0.6), width: 0.5),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 12, color: Colors.white),
          const SizedBox(width: VboxSpacing.xs + 2),
          MarqueeText(text: message, maxWidth: 200),
        ],
      ),
    );
  }
}

/// 跑马灯文字（对齐 iOS `MarqueeText`；超长即循环横滚）。
class MarqueeText extends StatefulWidget {
  /// 构造。
  const MarqueeText({
    super.key,
    required this.text,
    this.maxWidth = 200,
    this.fontSize = VboxTypography.s12,
    this.color = Colors.white,
    this.fontWeight = FontWeight.w500,
  });

  /// 文本。
  final String text;

  /// 可视最大宽度（超出即滚动）。
  final double maxWidth;

  /// 字号。
  final double fontSize;

  /// 文字色。
  final Color color;

  /// 字重（顶栏标题等复用位可调；缺省 w500 保持既有观感）。
  final FontWeight fontWeight;

  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<MarqueeText>
    with SingleTickerProviderStateMixin {
  /// 单程滚动控制器（0 → 1 对应「文本右端滑出可视区」）。
  late final AnimationController _controller = AnimationController(vsync: this);

  double _textWidth = 0;

  bool get _needsScroll => _textWidth > widget.maxWidth;

  @override
  void didUpdateWidget(covariant MarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _restart();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 重启滚动（按文本宽度自适应时长；不需滚动则停在原位）。
  void _restart() {
    _controller.stop();
    _controller.value = 0;
    if (!_needsScroll) return;
    final double distance = _textWidth + widget.maxWidth;
    _controller.duration = Duration(
      milliseconds: (distance / 40 * 1000).round().clamp(1000, 60000),
    );
    _controller.repeat();
  }

  @override
  Widget build(BuildContext context) {
    final TextStyle style = TextStyle(
      fontSize: widget.fontSize,
      fontWeight: widget.fontWeight,
      color: widget.color,
    );
    final TextPainter painter = TextPainter(
      text: TextSpan(text: widget.text, style: style),
      maxLines: 1,
      textDirection: Directionality.of(context),
    )..layout();
    final double measured = painter.width;
    if (measured != _textWidth) {
      _textWidth = measured;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _restart();
      });
    }

    return SizedBox(
      width: widget.maxWidth,
      child: ClipRect(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (BuildContext context, Widget? child) {
            final double offset =
                _needsScroll ? -_controller.value * (_textWidth + 12) : 0;
            return Transform.translate(
              offset: Offset(offset, 0),
              child: child,
            );
          },
          child: Align(
            alignment: Alignment.centerLeft,
            // widthFactor / heightFactor 必须同时为 1：只设 widthFactor 时
            // Align 在有界高度约束下会**撑满全部可用高度**（Align 缺省
            // expand 行为），把整颗胶囊拉成近全屏色块；heightFactor: 1
            // 使 Align 收缩为单行文本固有高度，对齐 iOS `Text` 的固有尺寸。
            widthFactor: 1,
            heightFactor: 1,
            child: Text(
              widget.text,
              style: style,
              maxLines: 1,
              softWrap: false,
            ),
          ),
        ),
      ),
    );
  }
}