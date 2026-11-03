/// 呈现层：更新弹窗（批次 K · K-更1 UI）。
///
/// 唯一真相源：iOS `vbox/Views/UpdateSheet.swift`（UpdateSheet + FloatingDownloadBubble）。
///
/// 对齐口径：
/// - 弹窗宽 320、圆角 20、状态图标（发现新版本 `send` 斜置 / 下载中 `arrow.down.circle`
///   / 下载完成 `checkmark`）、标题 + 版本号、下载进度条 + 百分比 + 「点击取消」、
///   错误红字、「未检测到安装能力」引导、更新说明逐条编号、主按钮（马上升级 / 取消下载 /
///   安装更新）、「浏览器下载」降级入口、底部当前版本；
/// - 关闭时若在下载则先取消（对齐 iOS `close()`）；
/// - 缩小为右下角悬浮进度气泡（`FloatingDownloadBubble`），点击恢复弹窗。
///
/// 落地差异（如实登记）：悬浮气泡已实现拖拽 + 贴边吸附（批次 E · E1-2，对齐
/// iOS `UpdateSheet.swift:289-294`）。字号按本仓库令牌档位就近取（22→24、26→28、17→18）。
library;

import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../platform/update/update.dart';
import '../../theme/theme.dart';

/// 悬浮气泡全局单例（同一时刻最多一个）。
OverlayEntry? _bubbleEntry;

/// 打开更新弹窗。
Future<void> showUpdateSheet(BuildContext context, {Updater? updater}) {
  final Updater u = updater ?? Updater.instance;
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.4),
    builder: (BuildContext ctx) => UpdateSheet(updater: u),
  );
}

/// 缩小后显示右下角悬浮进度气泡（点击恢复弹窗）。
void showUpdateBubble(BuildContext context, {Updater? updater}) {
  final Updater u = updater ?? Updater.instance;
  final OverlayState overlay = Overlay.of(context, rootOverlay: true);
  final BuildContext overlayContext = overlay.context;
  _bubbleEntry?.remove();
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => FloatingUpdateBubble(
      updater: u,
      onTap: () {
        entry.remove();
        if (identical(_bubbleEntry, entry)) _bubbleEntry = null;
        u.restore();
        showUpdateSheet(overlayContext, updater: u);
      },
    ),
  );
  _bubbleEntry = entry;
  overlay.insert(entry);
}

/// 更新弹窗（监听 [Updater] 状态自动刷新）。
class UpdateSheet extends StatelessWidget {
  /// 构造。
  const UpdateSheet({super.key, required this.updater});

  /// 更新器（状态源）。
  final Updater updater;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: VboxSpacing.symmetric(horizontal: VboxSpacing.xxl, vertical: VboxSpacing.xxl),
      child: ListenableBuilder(
        listenable: updater,
        builder: (BuildContext context, Widget? _) {
          final bool downloading = updater.isDownloading;
          final bool done = updater.hasDownloaded;
          final List<String> notes = updater.releaseNotes;
          final double notesHeight =
              (notes.length * 36 + 24).clamp(180, 280).toDouble();

          return ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320, maxHeight: 560),
            child: Material(
              color: scheme.surface,
              borderRadius: VboxRadii.panel,
              clipBehavior: Clip.antiAlias,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  _TopBar(
                    downloading: downloading,
                    onMinimize: () => _minimize(context),
                    onClose: () => _close(context),
                  ),
                  _statusIcon(downloading, done),
                  const SizedBox(height: VboxSpacing.xs),
                  Text(
                    downloading ? '正在下载' : (done ? '下载完成' : '发现新版本'),
                    style: TextStyle(
                      fontSize: VboxTypography.s24,
                      fontWeight: FontWeight.bold,
                      color: scheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: VboxSpacing.xs / 2),
                  Text(
                    updater.latestVersion,
                    style: TextStyle(
                      fontSize: VboxTypography.s28,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface,
                    ),
                  ),
                  if (downloading) _progressBlock(context),
                  if (updater.downloadError != null) ...<Widget>[
                    const SizedBox(height: VboxSpacing.md),
                    Padding(
                      padding: VboxSpacing.symmetric(horizontal: VboxSpacing.xxl + VboxSpacing.lg),
                      child: Text(
                        updater.downloadError!,
                        style: const TextStyle(
                          fontSize: VboxTypography.s13,
                          color: VboxColors.danger,
                        ),
                      ),
                    ),
                  ],
                  if (updater.installMessage != null) ...<Widget>[
                    const SizedBox(height: VboxSpacing.md),
                    Padding(
                      padding: VboxSpacing.symmetric(horizontal: VboxSpacing.xxl),
                      child: Text(
                        updater.installMessage!,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: VboxTypography.s12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                  if (done && updater.installMessage == null) ...<Widget>[
                    const SizedBox(height: VboxSpacing.md),
                    Padding(
                      padding: VboxSpacing.symmetric(horizontal: VboxSpacing.xxl),
                      child: Text(
                        '点「安装更新」拉起系统安装；无法安装时可用浏览器下载',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: VboxTypography.s12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                  if (!downloading && notes.isNotEmpty) ...<Widget>[
                    const SizedBox(height: VboxSpacing.md),
                    Flexible(
                      child: Padding(
                        padding: VboxSpacing.symmetric(horizontal: VboxSpacing.lg),
                        child: SizedBox(
                          height: notesHeight,
                          child: ListView.builder(
                            shrinkWrap: true,
                            itemCount: notes.length,
                            itemBuilder: (BuildContext context, int index) {
                              return Padding(
                                padding: VboxSpacing.symmetric(
                                  vertical: VboxSpacing.sm / 2,
                                ),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    Text(
                                      '${index + 1}、',
                                      style: TextStyle(
                                        fontSize: VboxTypography.s15,
                                        color: scheme.onSurface,
                                      ),
                                    ),
                                    Expanded(
                                      child: Text(
                                        notes[index],
                                        style: TextStyle(
                                          fontSize: VboxTypography.s15,
                                          color: scheme.onSurface,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: VboxSpacing.lg),
                  Padding(
                    padding: VboxSpacing.symmetric(horizontal: VboxSpacing.xxl),
                    child: _mainButton(context, downloading, done),
                  ),
                  if (!downloading) ...[
                    const SizedBox(height: VboxSpacing.sm),
                    TextButton(
                      onPressed: () async {
                        await updater.openReleasePage();
                        if (context.mounted) _close(context);
                      },
                      child: Text(
                        '用浏览器下载',
                        style: TextStyle(
                          fontSize: VboxTypography.s13,
                          color: scheme.onSurfaceVariant,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ),
                  ] else
                    const SizedBox(height: VboxSpacing.sm),
                  Text(
                    '当前版本 ${AppInfo.version}',
                    style: TextStyle(
                      fontSize: VboxTypography.s13,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: VboxSpacing.xl),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// 状态大图标（发现新版本 / 下载中 / 下载完成）。
  Widget _statusIcon(bool downloading, bool done) {
    if (downloading) {
      return const Icon(
        Icons.arrow_circle_down,
        size: 70,
        color: VboxColors.downloadActive,
      );
    }
    if (done) {
      return const Icon(
        Icons.check_circle,
        size: 70,
        color: VboxColors.downloadCompleted,
      );
    }
    return Transform.rotate(
      angle: -0.52,
      child: const Icon(
        Icons.send,
        size: 70,
        color: VboxColors.downloadActive,
      ),
    );
  }

  /// 下载进度条 + 百分比 + 「点击取消」。
  Widget _progressBlock(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: VboxSpacing.symmetric(horizontal: VboxSpacing.xxxl + VboxSpacing.sm),
      child: Column(
        children: <Widget>[
          const SizedBox(height: VboxSpacing.lg),
          ClipRRect(
            borderRadius: VboxRadii.badge,
            child: LinearProgressIndicator(
              value: updater.downloadProgress,
              minHeight: 4,
              color: VboxColors.downloadActive,
              backgroundColor: scheme.onSurface.withValues(alpha: 0.12),
            ),
          ),
          const SizedBox(height: VboxSpacing.compact),
          Row(
            children: <Widget>[
              Text(
                '${(updater.downloadProgress * 100).floor()}%',
                style: TextStyle(
                  fontSize: VboxTypography.s13,
                  fontWeight: FontWeight.w500,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              Text(
                '点击取消',
                style: TextStyle(
                  fontSize: VboxTypography.s12,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 主操作按钮（马上升级 / 取消下载 / 安装更新）。
  Widget _mainButton(BuildContext context, bool downloading, bool done) {
    final String title = downloading
        ? '取消下载'
        : (done ? '安装更新' : '马上升级');
    return Material(
      color: downloading
          ? VboxColors.danger.withValues(alpha: 0.8)
          : VboxColors.downloadActive,
      borderRadius: VboxRadii.card,
      child: InkWell(
        borderRadius: VboxRadii.card,
        onTap: () => _handleAction(context),
        child: Padding(
          padding: VboxSpacing.symmetric(vertical: VboxSpacing.rowVertical),
          child: Center(
            child: Text(
              title,
              style: const TextStyle(
                fontSize: VboxTypography.s18,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 主按钮动作分派。
  Future<void> _handleAction(BuildContext context) async {
    if (updater.isDownloading) {
      updater.cancelDownload();
      return;
    }
    if (updater.hasDownloaded) {
      final String status = await updater.install();
      if (status == UpdateInstallStatus.needPermission ||
          status == UpdateInstallStatus.failed) {
        return; // 保留弹窗显示引导文案
      }
      if (context.mounted) _close(context);
      return;
    }
    await updater.download();
  }

  /// 关闭（下载中先取消，对齐 iOS `close()`）。
  void _close(BuildContext context) {
    if (updater.isDownloading) updater.cancelDownload();
    Navigator.of(context).maybePop();
  }

  /// 缩小为悬浮气泡。
  void _minimize(BuildContext context) {
    final BuildContext rootContext =
        Overlay.of(context, rootOverlay: true).context;
    updater.minimize();
    Navigator.of(context).maybePop();
    showUpdateBubble(rootContext, updater: updater);
  }
}

/// 顶部栏（下载中显示缩小按钮 + 关闭按钮）。
class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.downloading,
    required this.onMinimize,
    required this.onClose,
  });

  final bool downloading;
  final VoidCallback onMinimize;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(
        left: VboxSpacing.lg,
        right: VboxSpacing.lg,
        top: VboxSpacing.sm,
      ),
      child: Row(
        children: <Widget>[
          if (downloading)
            GestureDetector(
              onTap: onMinimize,
              child: Icon(
                Icons.close_fullscreen,
                size: VboxTypography.s16,
                color: scheme.onSurfaceVariant,
              ),
            ),
          const Spacer(),
          GestureDetector(
            onTap: onClose,
            child: Container(
              width: VboxSpacing.xxl,
              height: VboxSpacing.xxl,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.12),
              ),
              child: Icon(
                Icons.close,
                size: VboxTypography.s16,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 悬浮下载气泡（缩小后显示，可拖拽并吸附左右边缘；点击恢复弹窗）。
///
/// 对齐 iOS `UpdateSheet.swift:289-294`：默认位右下，拖拽手势（`onPanUpdate`
/// 跟手 / `onPanEnd` 吸附最近左右边缘 + Y 轴范围限制），吸附逻辑复用悬浮下载
/// 按键（`FloatingVideoDownloadButton`）现成 snapToEdge 口径。
class FloatingUpdateBubble extends StatefulWidget {
  /// 构造。
  const FloatingUpdateBubble({
    super.key,
    required this.updater,
    required this.onTap,
  });

  /// 更新器（读取下载进度）。
  final Updater updater;

  /// 点击回调（非拖动点击触发；恢复弹窗）。
  final VoidCallback onTap;

  @override
  State<FloatingUpdateBubble> createState() => _FloatingUpdateBubbleState();
}

class _FloatingUpdateBubbleState extends State<FloatingUpdateBubble> {
  static const double _size = 44;
  static const double _margin = 16;

  /// 相对默认位置（右下）的拖动偏移。
  Offset _offset = Offset.zero;
  bool _hasMoved = false;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // 结构对齐 FloatingVideoDownloadButton：LayoutBuilder 外层取可用尺寸，
    // Positioned 必须为 Stack 直接子级（嵌在 LayoutBuilder 内会破坏 ParentData）。
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double w = constraints.maxWidth;
        final double h = constraints.maxHeight;
        final Offset base = Offset(w - _size - _margin, h - _size - _margin);
        final Offset pos = base + _offset;
        return Stack(
          children: <Widget>[
            AnimatedPositioned(
              duration: _hasMoved
                  ? Duration.zero
                  : const Duration(milliseconds: 300),
              curve: Curves.easeOut,
              left: pos.dx,
              top: pos.dy,
              width: _size,
              height: _size,
              child: ListenableBuilder(
                listenable: widget.updater,
                builder: (BuildContext context, Widget? _) {
                  final bool active = widget.updater.isDownloading;
                  final double value = widget.updater.downloadProgress
                      .clamp(0.05, 1.0)
                      .toDouble();
                  return GestureDetector(
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
                      // 吸附最近左右边缘 + Y 轴范围限制（对齐 iOS dragGesture
                      // onEnded / 下载按键 snapToEdge 口径）。
                      final double newX = base.dx + _offset.dx;
                      final double snapLeft =
                          newX > w / 2 ? w - _size - _margin : _margin;
                      final double newY = base.dy + _offset.dy;
                      final double clampedY =
                          newY.clamp(_size / 2 + 60, h - _size - 100);
                      setState(() {
                        _offset = Offset(snapLeft - base.dx, clampedY - base.dy);
                      });
                    },
                    child: SizedBox(
                      width: _size,
                      height: _size,
                      child: Stack(
                        alignment: Alignment.center,
                        children: <Widget>[
                          SizedBox(
                            width: _size,
                            height: _size,
                            child: CircularProgressIndicator(
                              value: 1,
                              strokeWidth: 2.5,
                              color:
                                  scheme.onSurface.withValues(alpha: 0.15),
                            ),
                          ),
                          SizedBox(
                            width: _size,
                            height: _size,
                            child: CircularProgressIndicator(
                              value: value,
                              strokeWidth: 2.5,
                              strokeCap: StrokeCap.round,
                              color: VboxColors.downloadActive,
                            ),
                          ),
                          Container(
                            width: VboxSpacing.xxxl + 2,
                            height: VboxSpacing.xxxl + 2,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: scheme.surface,
                              boxShadow: <BoxShadow>[
                                BoxShadow(
                                  color:
                                      Colors.black.withValues(alpha: 0.25),
                                  blurRadius: VboxSpacing.sm,
                                  offset: const Offset(0, 3),
                                ),
                              ],
                            ),
                            child: Icon(
                              active
                                  ? Icons.arrow_circle_down
                                  : Icons.download_done,
                              size: VboxSpacing.xxl,
                              color: active
                                  ? VboxColors.downloadActive
                                  : VboxColors.downloadCompleted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}