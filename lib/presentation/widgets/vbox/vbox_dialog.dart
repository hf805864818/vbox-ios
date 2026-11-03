/// 统一组件库 · 对话框（批次 A · A-04）。
///
/// 唯一真相源：`docs/UI对齐基准_v1.0.md` §2.3（18 · 弹窗标题/semibold）
/// 与 §2.5（大面板：圆角 20 + 渐变描边）。
///
/// 自适应（竖/横、手机/大屏）由 A-07 `AdaptiveDialog` 在其上封装。
library;

import 'package:flutter/material.dart';

import '../../theme/tokens/radii.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';

/// 统一对话框外壳。
class VboxDialog extends StatelessWidget {
  /// 构造。
  const VboxDialog({
    super.key,
    required this.title,
    required this.child,
    this.actions = const <Widget>[],
    this.maxWidth = 420,
  });

  /// 标题。
  final String title;

  /// 内容。
  final Widget child;

  /// 底部操作（右对齐）。
  final List<Widget> actions;

  /// 最大宽度（大屏约束）。
  final double maxWidth;

  /// 以路由方式弹出。
  static Future<T?> show<T>(
    BuildContext context, {
    required String title,
    required Widget child,
    List<Widget> actions = const <Widget>[],
    bool barrierDismissible = true,
  }) {
    return showDialog<T>(
      context: context,
      barrierDismissible: barrierDismissible,
      builder: (_) => VboxDialog(title: title, actions: actions, child: child),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(VboxSpacing.xxl),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Material(
          color: scheme.surface,
          shape: const RoundedRectangleBorder(borderRadius: VboxRadii.panel),
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.all(VboxSpacing.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
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
                Flexible(child: child),
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