/// 自适应框架 · 自适应弹窗（批次 A · A-07）。
///
/// 唯一真相源：`docs/第2轮开发计划_功能补全_v2.6.md` §3.3（浮层）：
///   竖屏 → 底部/居中弹窗（复用 A-04 [VboxDialog]）；
///   横屏 → 右侧抽屉（同内容改锚点，从右滑入）。
///
/// 同组件、同内容，只改锚点，满足「四端同 UI」。
library;

import 'package:flutter/material.dart';

import '../../theme/tokens/radii.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';
import '../../ui_mode/ui_mode.dart';
import '../vbox/vbox_dialog.dart';

/// 自适应弹窗：内容层复用统一弹窗规格，锚点随形态切换。
class AdaptiveDialog extends StatelessWidget {
  /// 构造。
  const AdaptiveDialog({
    super.key,
    required this.form,
    required this.title,
    required this.child,
    this.actions = const <Widget>[],
    this.maxWidth = 420,
    this.sideWidth = 420,
  });

  /// 当前形态。
  final UiForm form;

  /// 标题。
  final String title;

  /// 内容。
  final Widget child;

  /// 底部操作（右对齐）。
  final List<Widget> actions;

  /// 竖屏居中弹窗最大宽度。
  final double maxWidth;

  /// 横屏右侧抽屉宽度。
  final double sideWidth;

  /// 横屏滑入动画时长。
  static const Duration slideDuration = Duration(milliseconds: 220);

  /// 以路由方式弹出（按形态选择锚点）。
  static Future<T?> show<T>(
    BuildContext context, {
    required UiForm form,
    required String title,
    required Widget child,
    List<Widget> actions = const <Widget>[],
    bool barrierDismissible = true,
  }) {
    if (form.isPortrait) {
      return VboxDialog.show<T>(
        context,
        title: title,
        child: child,
        actions: actions,
        barrierDismissible: barrierDismissible,
      );
    }
    return showGeneralDialog<T>(
      context: context,
      barrierDismissible: barrierDismissible,
      barrierLabel: title,
      barrierColor: Colors.black54,
      transitionDuration: slideDuration,
      pageBuilder: (_, __, ___) => AdaptiveDialog(
        form: form,
        title: title,
        actions: actions,
        child: child,
      ),
      transitionBuilder: (_, Animation<double> animation, __, Widget dialog) {
        final Animation<Offset> slide = Tween<Offset>(
          begin: const Offset(1, 0),
          end: Offset.zero,
        ).animate(
          CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
        );
        return SlideTransition(position: slide, child: dialog);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (form.isPortrait) {
      return VboxDialog(
        title: title,
        actions: actions,
        maxWidth: maxWidth,
        child: child,
      );
    }
    return _SideSheet(
      title: title,
      width: sideWidth,
      actions: actions,
      child: child,
    );
  }
}

/// 右侧抽屉外壳（内容规格与 [VboxDialog] 一致，仅锚点改为右侧）。
class _SideSheet extends StatelessWidget {
  const _SideSheet({
    required this.title,
    required this.child,
    required this.actions,
    required this.width,
  });

  final String title;
  final Widget child;
  final List<Widget> actions;
  final double width;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerRight,
      child: SizedBox(
        width: width,
        height: double.infinity,
        child: Material(
          color: scheme.surface,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(VboxRadii.r20),
              bottomLeft: Radius.circular(VboxRadii.r20),
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.all(VboxSpacing.xl),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  title,
                  style: TextStyle(
                    fontSize: VboxTypography.s18,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: VboxSpacing.lg),
                Expanded(child: child),
                if (actions.isNotEmpty) ...<Widget>[
                  const SizedBox(height: VboxSpacing.xl),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: <Widget>[
                      for (int i = 0; i < actions.length; i++) ...<Widget>[
                        if (i > 0) const SizedBox(width: VboxSpacing.sm),
                        actions[i],
                      ],
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}