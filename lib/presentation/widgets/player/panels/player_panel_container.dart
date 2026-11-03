/// 表现层：播放器面板容器（批次 C · C-04）。
///
/// 半透明深色覆盖层 + 标题栏（标题 / 关闭）＋内容区；横屏右侧滑出、
/// 竖屏底部抽屉由 [PlayerPanelsHost] 统一摆放，本组件只管「壳」。
library;

import 'package:flutter/material.dart';

import '../../../theme/tokens/colors.dart';
import '../../../theme/tokens/radii.dart';
import '../../../theme/tokens/spacing.dart';
import '../../../theme/tokens/typography.dart';

/// 面板容器。
class PlayerPanelContainer extends StatelessWidget {
  /// 构造。
  const PlayerPanelContainer({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
    this.onClose,
    this.backgroundColor,
    this.padding = const EdgeInsets.fromLTRB(
      VboxSpacing.lg,
      VboxSpacing.md,
      VboxSpacing.lg,
      VboxSpacing.lg,
    ),
  });

  /// 标题。
  final String title;

  /// 内容。
  final Widget child;

  /// 标题右侧附加信息（如「共 30 集」）。
  final Widget? trailing;

  /// 关闭回调。
  final VoidCallback? onClose;

  /// 背景（缺省半透明深色，对齐播放器深底）。
  final Color? backgroundColor;

  /// 内容内边距。
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: backgroundColor ?? VboxColors.playerPanelBackground,
      borderRadius: VboxRadii.card,
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              VboxSpacing.lg,
              VboxSpacing.sm,
              VboxSpacing.sm,
              VboxSpacing.xs,
            ),
            child: Row(
              children: <Widget>[
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: VboxTypography.s16,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
                if (trailing != null) ...<Widget>[
                  const SizedBox(width: VboxSpacing.sm),
                  DefaultTextStyle.merge(
                    style: const TextStyle(
                      fontSize: VboxTypography.s12,
                      color: Colors.white54,
                    ),
                    child: trailing!,
                  ),
                ],
                const Spacer(),
                if (onClose != null)
                  IconButton(
                    onPressed: onClose,
                    icon: const Icon(
                      Icons.close_rounded,
                      size: 20,
                      color: Colors.white70,
                    ),
                    constraints: const BoxConstraints(
                      minWidth: 40,
                      minHeight: 40,
                    ),
                    padding: EdgeInsets.zero,
                  ),
              ],
            ),
          ),
          const Divider(height: 1, color: Colors.white12),
          Padding(
            padding: padding,
            child: child,
          ),
        ],
      ),
    );
  }
}

/// 面板内容中「当前值」强调色（选中项高亮）。
const Color playerPanelAccent = VboxColors.selected;
