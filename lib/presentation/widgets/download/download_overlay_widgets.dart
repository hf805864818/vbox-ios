/// 表现层：下载管理浮层 UI（G-02 UI）。
///
/// 唯一真相源：iOS `vbox/Views/DownloadOverlayViews.swift`，四件套：
///   ① [DownloadCapsuleNotification]  —— 全局胶囊通知（底部居中，5s 自动消失）
///   ② [PlayerCapsuleNotification]    —— 播放器内胶囊通知（顶部居中，5s 自动消失）
///   ③ [FloatingVideoDownloadButton] —— 悬浮下载按键（进度环/角标/拖动吸附）
///   ④ [DownloadManagementPopup]      —— 下载管理弹窗（分组列表 + 底部操作栏）
///
/// 差异登记：
///   · SF Symbols 图标名 → Material 图标映射（[_sfIcon]，名字段由平台层透传）；
///   · iOS 完成行「播放 / 保存到文件 / 保存到相册」三动作 → Flutter 实现
///     播放（对齐 iOS `createLocalVodItem`，DownloadOverlayViews.swift
///     L1001-L1016）、保存到文件（share 系统面板导出，对齐 iOS
///     `UIDocumentPicker` 语义）与保存到相册（E1-1，仅 Android：
///     原生 `MediaExtractor`+`MediaMuxer` 转封装 + MediaStore 入库；
///     桌面保持 share 导出 `.ts`，登记）；
///   · iOS 用 Timer 1s 轮询弹窗列表，Flutter 走 [DownloadManager] ChangeNotifier
///     自动刷新，无需轮询。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../data/models/download.dart';
import '../../../domain/entities/player/player.dart';
import '../../../platform/download/download.dart';
import '../../../platform/gallery/gallery_save.dart';
import '../../pages/player/player_page.dart';
import '../../theme/tokens/colors.dart';
import '../../theme/tokens/radii.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';
import '../vbox/vbox_toast.dart';

/// SF Symbol → Material 图标（由 [DownloadCapsuleMessage.icon] 名字段映射）。
IconData _sfIcon(String sf) => switch (sf) {
      'arrow.down.circle.fill' => Icons.arrow_circle_down,
      'checkmark.circle.fill' => Icons.check_circle,
      'wifi.slash' => Icons.wifi_off,
      'xmark.circle.fill' => Icons.cancel,
      'pause.circle.fill' => Icons.pause_circle_filled,
      'play.circle.fill' => Icons.play_circle_filled,
      'arrow.clockwise.circle' => Icons.refresh,
      'trash.circle' => Icons.delete,
      'tray.full.fill' => Icons.download_done,
      'tray' => Icons.inbox,
      'xmark.circle' => Icons.close,
      _ => Icons.info_outline,
    };

/// 胶囊类型 → 主题色（对齐 iOS `DownloadCapsuleMessage.color`）。
Color _capsuleColor(DownloadCapsuleType type) => switch (type) {
      DownloadCapsuleType.info => Colors.blue,
      DownloadCapsuleType.success => Colors.green,
      DownloadCapsuleType.failure => Colors.red,
      DownloadCapsuleType.network => Colors.orange,
    };

/// 字节格式化（对齐 iOS `formatBytes`）。
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

// ─────────────────────── ① 胶囊通知 ───────────────────────

/// 下载状态胶囊通知 — 悬浮在底栏上方居中显示，5s 自动消失。
///
/// 对齐 iOS `DownloadCapsuleNotification`：自管理可见性，不阻挡交互
/// （[IgnorePointer]），由 [DownloadManager.capsuleMessage] 驱动。
class DownloadCapsuleNotification extends StatefulWidget {
  /// 构造。
  const DownloadCapsuleNotification({super.key});

  @override
  State<DownloadCapsuleNotification> createState() =>
      _DownloadCapsuleNotificationState();
}

class _DownloadCapsuleNotificationState
    extends State<DownloadCapsuleNotification> {
  bool _visible = false;
  DownloadCapsuleMessage? _current;
  Timer? _dismissTimer;

  @override
  void dispose() {
    _dismissTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final DownloadManager manager = context.watch<DownloadManager>();
    final DownloadCapsuleMessage? message = manager.capsuleMessage;

    // 消息变化 → 显示并启动 5s 自动消失（对齐 iOS `handleMessageChange`）。
    if (message != _current) {
      _current = message;
      _dismissTimer?.cancel();
      if (message == null) {
        _visible = false;
      } else {
        _visible = true;
        _dismissTimer = Timer(const Duration(seconds: 5), () {
          if (mounted) setState(() => _visible = false);
        });
      }
    }

    return IgnorePointer(
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 90),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeOut,
            // 对齐 iOS `.transition(.move(edge: .bottom) + .opacity +
            // .scale(0.9))`：从底部滑入 + 淡入 + 缩放。
            transitionBuilder: (Widget child, Animation<double> animation) {
              final Animatable<Offset> slide =
                  Tween<Offset>(begin: const Offset(0, 0.35), end: Offset.zero)
                      .chain(CurveTween(curve: Curves.easeOut));
              return SlideTransition(
                position: slide.animate(animation),
                child: FadeTransition(
                  opacity: animation,
                  child: ScaleTransition(
                    scale: Tween<double>(begin: 0.9, end: 1).animate(animation),
                    child: child,
                  ),
                ),
              );
            },
            child: _visible && _current != null
                ? _CapsuleBody(
                    key: ValueKey<Object?>(_current), message: _current)
                : const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }
}

/// 播放器内胶囊通知 — 显示在播放器顶部，5s 自动消失，不阻挡播放器手势。
///
/// 对齐 iOS `PlayerCapsuleNotification`（DownloadOverlayViews.swift L143-L218）：
/// 顶部安全区下方居中，`.transition(.move(edge: .top) + .opacity +
/// .scale(0.9))` 顶部滑入；[IgnorePointer] 确保不拦截播放器手势与按钮。
class PlayerCapsuleNotification extends StatefulWidget {
  /// 构造。
  const PlayerCapsuleNotification({super.key});

  @override
  State<PlayerCapsuleNotification> createState() =>
      _PlayerCapsuleNotificationState();
}

class _PlayerCapsuleNotificationState extends State<PlayerCapsuleNotification> {
  bool _visible = false;
  DownloadCapsuleMessage? _current;
  Timer? _dismissTimer;

  @override
  void dispose() {
    _dismissTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 播放页可被无 DownloadManager 作用域的宿主直接承载（如独立测试环境），
    // 此时胶囊退化为不可见，不阻断播放器构建（应用根节点始终注入该 Provider）。
    DownloadManager? manager;
    try {
      manager = context.watch<DownloadManager>();
    } on ProviderNotFoundException {
      manager = null;
    }
    final DownloadCapsuleMessage? message = manager?.capsuleMessage;

    // 消息变化 → 显示并重置 5s 自动消失（对齐 iOS `handleMessageChange`）。
    if (message != _current) {
      _current = message;
      _dismissTimer?.cancel();
      if (message == null) {
        _visible = false;
      } else {
        _visible = true;
        _dismissTimer = Timer(const Duration(seconds: 5), () {
          if (mounted) setState(() => _visible = false);
        });
      }
    }

    return IgnorePointer(
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeOut,
            // 对齐 iOS `.transition(.move(edge: .top) + .opacity +
            // .scale(0.9))`：从顶部滑入 + 淡入 + 缩放。
            transitionBuilder: (Widget child, Animation<double> animation) {
              final Animatable<Offset> slide =
                  Tween<Offset>(begin: const Offset(0, -0.35), end: Offset.zero)
                      .chain(CurveTween(curve: Curves.easeOut));
              return SlideTransition(
                position: slide.animate(animation),
                child: FadeTransition(
                  opacity: animation,
                  child: ScaleTransition(
                    scale: Tween<double>(begin: 0.9, end: 1).animate(animation),
                    child: child,
                  ),
                ),
              );
            },
            child: _visible && _current != null
                ? _CapsuleBody(
                    key: ValueKey<Object?>(_current), message: _current)
                : const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }
}

/// 胶囊本体（黑底 + 类型色描边 + 阴影）。
class _CapsuleBody extends StatelessWidget {
  const _CapsuleBody({super.key, required this.message});

  final DownloadCapsuleMessage? message;

  @override
  Widget build(BuildContext context) {
    final DownloadCapsuleMessage? msg = message;
    if (msg == null) return const SizedBox.shrink();
    final Color color = _capsuleColor(msg.type);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: VboxSpacing.md + 2,
        vertical: VboxSpacing.xs + 3,
      ),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(VboxRadii.capsule),
        border: Border.all(color: color.withValues(alpha: 0.5), width: 0.5),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(_sfIcon(msg.icon), size: 12, color: color),
          const SizedBox(width: VboxSpacing.xs + 2),
          Text(
            msg.text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: VboxTypography.s12,
              fontWeight: FontWeight.w500,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────── ② 悬浮下载按键 ───────────────────────

/// 悬浮下载按键 — 有下载记录时显示，可拖动并吸附左右边缘。
///
/// 对齐 iOS `FloatingVideoDownloadButton`：
///   · 40px 圆，进度环为活跃任务平均进度；
///   · 中心图标：有活跃任务 → 蓝色下载；否则 → 绿色完成托盘；
///   · 活跃任务数量红色角标；默认位置右下（距右 16 / 距底 140）。
class FloatingVideoDownloadButton extends StatefulWidget {
  /// 构造（[onTap] 非拖动点击 → 打开管理弹窗）。
  const FloatingVideoDownloadButton({super.key, required this.onTap});

  /// 点击回调。
  final VoidCallback onTap;

  @override
  State<FloatingVideoDownloadButton> createState() =>
      _FloatingVideoDownloadButtonState();
}

class _FloatingVideoDownloadButtonState
    extends State<FloatingVideoDownloadButton> {
  static const double _size = 40;
  static const double _marginRight = 16;
  static const double _bottomGap = 140;

  /// 相对默认位置的拖动偏移。
  Offset _offset = Offset.zero;
  bool _hasMoved = false;

  @override
  Widget build(BuildContext context) {
    // 详情页可被无 DownloadManager 作用域的宿主直接承载（如独立测试环境），
    // 此时按键退化为不可见，不阻断详情页构建（应用根节点始终注入该 Provider）。
    DownloadManager? manager;
    try {
      manager = context.watch<DownloadManager>();
    } on ProviderNotFoundException {
      manager = null;
    }
    if (manager == null || manager.isFloatingButtonManuallyHidden) {
      return const SizedBox.shrink();
    }
    if (manager.activeDownloads.isEmpty) {
      return const SizedBox.shrink();
    }

    final List<Download> active = manager.activeDownloads
        .where((Download d) =>
            d.status == DownloadStatus.downloading ||
            d.status == DownloadStatus.pending)
        .toList();
    final bool hasActive = active.isNotEmpty;
    final double overall = active.isEmpty
        ? 0
        : active.fold<double>(0, (double s, Download d) => s + d.progress) /
            active.length;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double w = constraints.maxWidth;
        final double h = constraints.maxHeight;
        final Offset base =
            Offset(w - _size - _marginRight, h - _size - _bottomGap);
        final Offset pos = base + _offset;
        return Stack(
          children: <Widget>[
            AnimatedPositioned(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
              left: pos.dx,
              top: pos.dy,
              width: _size,
              height: _size,
              child: GestureDetector(
                onTap: () {
                  if (!_hasMoved) widget.onTap();
                  _hasMoved = false;
                },
                onPanUpdate: (DragUpdateDetails details) {
                  setState(() {
                    _offset += details.delta;
                    if (details.delta.distance > 5) _hasMoved = true;
                  });
                },
                onPanEnd: (DragEndDetails details) {
                  // 吸附到最近边缘 + 限制 Y 轴范围（对齐 iOS dragGesture.onEnded）。
                  final double newX = base.dx + _offset.dx;
                  final double snapLeft =
                      newX > w / 2 ? w - _size - _marginRight : _marginRight;
                  final double newY = base.dy + _offset.dy;
                  final double clampedY =
                      newY.clamp(_size / 2 + 60, h - _size - 100);
                  setState(() {
                    _offset = Offset(snapLeft - base.dx, clampedY - base.dy);
                  });
                },
                child: _FloatingBubble(
                  size: _size,
                  hasActive: hasActive,
                  overallProgress: overall,
                  activeCount: active.length,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 悬浮按键气泡（进度环 + 中心图标 + 角标）。
class _FloatingBubble extends StatelessWidget {
  const _FloatingBubble({
    required this.size,
    required this.hasActive,
    required this.overallProgress,
    required this.activeCount,
  });

  final double size;
  final bool hasActive;
  final double overallProgress;
  final int activeCount;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: scheme.surface,
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          // 背景环
          SizedBox(
            width: size,
            height: size,
            child: CircularProgressIndicator(
              value: 1,
              strokeWidth: 2.5,
              color: Colors.white.withValues(alpha: 0.15),
              backgroundColor: Colors.white.withValues(alpha: 0.15),
            ),
          ),
          // 进度环（仅活跃时显示）
          if (hasActive)
            SizedBox(
              width: size,
              height: size,
              child: CircularProgressIndicator(
                value: overallProgress.clamp(0.05, 1.0),
                strokeWidth: 2.5,
                strokeCap: StrokeCap.round,
                color: VboxColors.downloadActive,
              ),
            ),
          // 中心图标
          Icon(
            hasActive ? Icons.arrow_circle_down : Icons.download_done,
            size: 22,
            color: hasActive
                ? VboxColors.downloadActive
                : VboxColors.downloadCompleted,
          ),
          // 活跃数量角标
          if (hasActive)
            Positioned(
              right: 2,
              top: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: VboxSpacing.xs + 1,
                  vertical: 1,
                ),
                decoration: BoxDecoration(
                  color: Colors.red,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '$activeCount',
                  style: const TextStyle(
                    fontSize: VboxTypography.s10,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ─────────────────────── ③ 下载管理弹窗 ───────────────────────

/// 打开下载管理弹窗（对齐 iOS「悬浮按键 → 弹窗」入口）。
Future<void> showDownloadManagementPopup(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.4),
    builder: (BuildContext context) => const DownloadManagementPopup(),
  );
}

/// 下载管理弹窗 — 分组列表（下载中/已暂停/已完成/失败）+ 底部操作栏。
///
/// 对齐 iOS `DownloadManagementPopup`：
///   · 标题栏「下载管理」+ 关闭；
///   · 空态（tray 图标 + 暂无下载内容）；
///   · 底部操作栏：清空已完成 / 关闭悬浮 / 清空全部；
///   · 列表数据直接 watch [DownloadManager]（ChangeNotifier 自动刷新）。
class DownloadManagementPopup extends StatelessWidget {
  /// 构造。
  const DownloadManagementPopup({super.key});

  @override
  Widget build(BuildContext context) {
    final DownloadManager manager = context.watch<DownloadManager>();
    final List<Download> records = manager.activeDownloads;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return FractionallySizedBox(
      heightFactor: 0.7,
      child: Material(
        color: scheme.surface,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(VboxRadii.r20),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            // 标题栏
            Padding(
              padding: const EdgeInsets.fromLTRB(
                VboxSpacing.xl,
                VboxSpacing.xl,
                VboxSpacing.xl,
                VboxSpacing.md,
              ),
              child: Row(
                children: <Widget>[
                  Text(
                    '下载管理',
                    style: TextStyle(
                      fontSize: VboxTypography.s18,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(Icons.cancel, size: 22, color: scheme.outline),
                    tooltip: '关闭',
                  ),
                ],
              ),
            ),
            // 列表 / 空态
            Expanded(
              child: records.isEmpty
                  ? const _EmptyDownloads()
                  : ListView(
                      padding: const EdgeInsets.only(bottom: VboxSpacing.xl),
                      children: <Widget>[
                        ..._sections(manager, records, scheme),
                      ],
                    ),
            ),
            // 底部操作栏
            _BottomActionBar(
              hasRecords: records.isNotEmpty,
              onClearCompleted: () => manager.clearCompleted(),
              onHideFloating: () {
                manager.hideFloatingButton();
                Navigator.of(context).pop();
              },
              onClearAll: () => manager.clearAll(),
            ),
          ],
        ),
      ),
    );
  }

  /// 分组构造（下载中 → 已暂停 → 已完成 → 失败，对齐 iOS 顺序）。
  List<Widget> _sections(
    DownloadManager manager,
    List<Download> records,
    ColorScheme scheme,
  ) {
    final List<Download> downloading = records
        .where((Download d) =>
            d.status == DownloadStatus.downloading ||
            d.status == DownloadStatus.pending)
        .toList();
    final List<Download> paused = records
        .where((Download d) => d.status == DownloadStatus.paused)
        .toList();
    final List<Download> completed = records
        .where((Download d) => d.status == DownloadStatus.completed)
        .toList();
    final List<Download> failed = records
        .where((Download d) => d.status == DownloadStatus.failed)
        .toList();

    final List<Widget> out = <Widget>[];
    void section(String title, List<Download> items, Color color,
        Widget Function(Download) row) {
      if (items.isEmpty) return;
      out.add(_SectionHeader(title: title, count: items.length, color: color));
      for (final Download d in items) {
        out.add(
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: VboxSpacing.xl,
              vertical: VboxSpacing.sm,
            ),
            child: row(d),
          ),
        );
      }
    }

    section(
      '下载中',
      downloading,
      Colors.blue,
      (Download d) => _ProgressRow(record: d, manager: manager),
    );
    section(
      '已暂停',
      paused,
      Colors.orange,
      (Download d) => _ProgressRow(record: d, manager: manager),
    );
    section(
      '已完成',
      completed,
      Colors.green,
      (Download d) => _CompletedRow(record: d, manager: manager),
    );
    section(
      '下载失败',
      failed,
      Colors.red,
      (Download d) => _FailedRow(record: d, manager: manager),
    );
    return out;
  }
}

/// 分组头（对齐 iOS `downloadSectionHeader`）。
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    required this.count,
    required this.color,
  });

  final String title;
  final int count;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        VboxSpacing.xl,
        VboxSpacing.md,
        VboxSpacing.xl,
        VboxSpacing.xs,
      ),
      child: Text(
        '$title ($count)',
        style: TextStyle(
          fontSize: VboxTypography.s13,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

/// 空态（对齐 iOS：tray 图标 + 暂无下载内容）。
class _EmptyDownloads extends StatelessWidget {
  const _EmptyDownloads();

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const SizedBox(height: 60),
          Icon(Icons.inbox, size: 40, color: scheme.outlineVariant),
          const SizedBox(height: VboxSpacing.md),
          Text(
            '暂无下载内容',
            style: TextStyle(
              fontSize: VboxTypography.s14,
              color: scheme.outline,
            ),
          ),
        ],
      ),
    );
  }
}

/// 底部操作栏（清空已完成 / 关闭悬浮 / 清空全部）。
class _BottomActionBar extends StatelessWidget {
  const _BottomActionBar({
    required this.hasRecords,
    required this.onClearCompleted,
    required this.onHideFloating,
    required this.onClearAll,
  });

  final bool hasRecords;
  final VoidCallback onClearCompleted;
  final VoidCallback onHideFloating;
  final VoidCallback onClearAll;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Divider(height: 1, color: scheme.outlineVariant),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: VboxSpacing.xl,
            vertical: VboxSpacing.md,
          ),
          child: Row(
            children: <Widget>[
              TextButton(
                onPressed: hasRecords ? onClearCompleted : null,
                child: const Text(
                  '清空已完成',
                  style: TextStyle(
                    fontSize: VboxTypography.s13,
                    color: Colors.red,
                  ),
                ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: onHideFloating,
                icon: const Icon(Icons.close, size: 12),
                label: const Text(
                  '关闭悬浮',
                  style: TextStyle(
                    fontSize: VboxTypography.s13,
                    color: Colors.grey,
                  ),
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: hasRecords ? onClearAll : null,
                child: const Text(
                  '清空全部',
                  style: TextStyle(
                    fontSize: VboxTypography.s13,
                    color: Colors.red,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ─────────────────────── 行视图 ───────────────────────

/// 进行中 / 已暂停行（进度条 + 暂停/继续按钮）。
class _ProgressRow extends StatelessWidget {
  const _ProgressRow({required this.record, required this.manager});

  final Download record;
  final DownloadManager manager;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool isPaused = record.status == DownloadStatus.paused;
    final bool isDownloading = record.status == DownloadStatus.downloading;
    final Color accent = isPaused ? Colors.orange : Colors.blue;

    return Row(
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                record.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: VboxTypography.s14,
                  fontWeight: FontWeight.w500,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(height: VboxSpacing.xs),
              Row(
                children: <Widget>[
                  Text(
                    record.laiyuan,
                    style: TextStyle(
                      fontSize: VboxTypography.s11,
                      color: scheme.outline,
                    ),
                  ),
                  if (record.sourceType != null &&
                      record.sourceType!.isNotEmpty) ...<Widget>[
                    const SizedBox(width: VboxSpacing.xs),
                    _SourceTag(sourceType: record.sourceType!),
                  ],
                ],
              ),
              const SizedBox(height: VboxSpacing.xs),
              ClipRRect(
                borderRadius:
                    const BorderRadius.all(Radius.circular(VboxRadii.r4)),
                child: LinearProgressIndicator(
                  value: record.progress.clamp(0.0, 1.0),
                  minHeight: 3,
                  color: accent,
                  backgroundColor: accent.withValues(alpha: 0.15),
                ),
              ),
              const SizedBox(height: VboxSpacing.xs),
              Text(
                isDownloading
                    ? '${(record.progress * 100).round()}%'
                        '${record.downloadedSize > 0 ? ' · ${formatBytes(record.downloadedSize)}' : ''}'
                    : isPaused
                        ? '已暂停 · ${(record.progress * 100).round()}%'
                        : '等待下载',
                style: TextStyle(
                  fontSize: VboxTypography.s10,
                  color: accent,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: VboxSpacing.sm),
        // 暂停 / 继续按钮
        if (isDownloading)
          IconButton(
            onPressed: () => manager.pause(record.id ?? 0),
            icon: const Icon(Icons.pause_circle_filled,
                size: 22, color: Colors.orange),
            tooltip: '暂停',
          )
        else if (isPaused)
          IconButton(
            onPressed: () => manager.resume(record.id ?? 0),
            icon: const Icon(Icons.play_circle_filled,
                size: 22, color: Colors.blue),
            tooltip: '继续',
          ),
      ],
    );
  }
}

/// 来源类型标签（网盘 / 普通，对齐 iOS sourceType 标签）。
class _SourceTag extends StatelessWidget {
  const _SourceTag({required this.sourceType});

  final String sourceType;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: VboxSpacing.xs + 1,
        vertical: 1,
      ),
      decoration: BoxDecoration(
        color: Colors.blue.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(VboxRadii.r4),
      ),
      child: Text(
        sourceType == 'cloud' ? '网盘' : '普通',
        style: const TextStyle(
          fontSize: VboxTypography.s10,
          color: Colors.blue,
        ),
      ),
    );
  }
}

/// 已完成行（播放 / 保存到文件 / 删除；对齐 iOS 完成行动作排布）。
class _CompletedRow extends StatelessWidget {
  const _CompletedRow({required this.record, required this.manager});

  final Download record;
  final DownloadManager manager;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool canOpen = record.filePath.isNotEmpty;
    return Row(
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                record.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: VboxTypography.s14,
                  fontWeight: FontWeight.w500,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(height: VboxSpacing.xs),
              Row(
                children: <Widget>[
                  Text(
                    record.laiyuan,
                    style: TextStyle(
                      fontSize: VboxTypography.s11,
                      color: scheme.outline,
                    ),
                  ),
                  if (record.fileSize > 0) ...<Widget>[
                    const SizedBox(width: VboxSpacing.xs),
                    Text(
                      '· ${formatBytes(record.fileSize)}',
                      style: const TextStyle(
                        fontSize: VboxTypography.s10,
                        color: Colors.green,
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
        // 播放（对齐 iOS 完成行首位动作：createLocalVodItem → 原播放器）。
        IconButton(
          onPressed: canOpen ? () => _playLocal(context) : null,
          icon: const Icon(
            Icons.play_circle_fill,
            size: 20,
            color: Colors.green,
          ),
          tooltip: '播放',
        ),
        // 保存到文件（对齐 iOS `UIDocumentPicker` 导出语义，经系统分享面板）。
        IconButton(
          onPressed: canOpen ? () => _exportFile(context) : null,
          icon: Icon(Icons.ios_share_rounded, size: 18, color: scheme.outline),
          tooltip: '保存到文件',
        ),
        // E1-1：保存到相册（仅 Android；对齐 iOS 完成行三动作排布，桌面
        // 无系统相册概念走 share 导出，登记）。
        if (GallerySaver.isSupported)
          IconButton(
            onPressed: canOpen ? () => _saveToGallery(context) : null,
            icon: Icon(Icons.photo_library_outlined,
                size: 20, color: scheme.outline),
            tooltip: '保存到相册',
          ),
        IconButton(
          onPressed: () => manager.deleteRecord(record.id ?? 0),
          icon: Icon(Icons.delete, size: 20, color: scheme.outline),
          tooltip: '删除',
        ),
      ],
    );
  }

  /// 播放本地文件（对齐 iOS `createLocalVodItem(from:)`：
  /// filePath 非空 + 文件存在守卫；vodId 取 `local_<id>` 供片头片尾设置
  /// 按本地记录独立存储；`.ts` 产物由播放内核（libmpv）原生支持）。
  void _playLocal(BuildContext context) {
    if (!File(record.filePath).existsSync()) {
      VboxToast.show(context, '本地文件不存在');
      return;
    }
    unawaited(Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => PlayerPage(
        source: PlayerSource(
          url: record.filePath,
          headers: const <String, String>{},
          provider: 'local',
        ),
        title: record.name,
        subtitle: '本地文件',
        vodId: 'local_${record.id ?? 0}',
      ),
    )));
  }

  /// 保存到文件（系统分享面板导出；对齐 iOS「保存到文件 App」降级语义——
  /// 相册通道未开放前，一切格式均可经此导出）。
  Future<void> _exportFile(BuildContext context) async {
    try {
      await SharePlus.instance.share(
        ShareParams(
            files: <XFile>[XFile(record.filePath)], subject: record.name),
      );
    } catch (_) {
      if (!context.mounted) return;
      VboxToast.show(context, '当前平台不支持导出');
    }
  }

  /// 保存到相册（E1-1；对齐 iOS `performSaveToPhotos`：
  /// mp4/mov/m4v 直接入库，其余原生转封装；失败文案对齐 iOS「视频转换失败」）。
  Future<void> _saveToGallery(BuildContext context) async {
    final String ext = record.filePath.contains('.')
        ? record.filePath.split('.').last.toLowerCase()
        : '';
    final bool needsConvert = ext != 'mp4' && ext != 'mov' && ext != 'm4v';
    try {
      await GallerySaver.save(
        filePath: record.filePath,
        displayName: record.name,
      );
      if (!context.mounted) return;
      VboxToast.show(
        context,
        needsConvert ? '已转换并保存到相册' : '已保存到相册',
      );
    } on GallerySaveException catch (e) {
      if (!context.mounted) return;
      VboxToast.show(
        context,
        e.code == 'PERMISSION_DENIED' ? '请在系统设置中授予存储权限' : '视频转换失败',
      );
    } catch (_) {
      if (!context.mounted) return;
      VboxToast.show(context, '视频转换失败');
    }
  }
}

/// 失败行（名称 / 下载失败 / 重试 + 删除）。
class _FailedRow extends StatelessWidget {
  const _FailedRow({required this.record, required this.manager});

  final Download record;
  final DownloadManager manager;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Row(
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                record.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: VboxTypography.s14,
                  fontWeight: FontWeight.w500,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(height: VboxSpacing.xs),
              const Text(
                '下载失败',
                style:
                    TextStyle(fontSize: VboxTypography.s10, color: Colors.red),
              ),
            ],
          ),
        ),
        IconButton(
          onPressed: () => manager.retry(record.id ?? 0),
          icon: const Icon(Icons.refresh, size: 18, color: Colors.blue),
          tooltip: '重试',
        ),
        IconButton(
          onPressed: () => manager.deleteRecord(record.id ?? 0),
          icon: const Icon(Icons.delete, size: 18, color: Colors.red),
          tooltip: '删除',
        ),
      ],
    );
  }
}
