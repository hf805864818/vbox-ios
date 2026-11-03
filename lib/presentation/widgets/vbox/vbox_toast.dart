/// 统一组件库 · Toast（批次 A · A-04）。
///
/// 唯一真相源：`docs/UI对齐基准_v1.0.md` §2.5（Toast）。
/// 规格：背景黑 85% + 圆角 12 + 白字。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../theme/tokens/radii.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';

/// 轻提示（Overlay 实现，不依赖 ScaffoldMessenger）。
class VboxToast {
  const VboxToast._();

  /// 展示一条提示。
  ///
  /// [duration] 后自动移除；返回一个可手动关闭的句柄。
  static VoidCallback show(
    BuildContext context,
    String message, {
    Duration duration = const Duration(seconds: 2),
  }) {
    final OverlayState overlay = Overlay.of(context);
    late final OverlayEntry entry;
    entry = OverlayEntry(builder: (_) => _VboxToastView(message: message));
    overlay.insert(entry);

    final Timer timer = Timer(duration, entry.remove);
    return () {
      timer.cancel();
      if (entry.mounted) entry.remove();
    };
  }
}

class _VboxToastView extends StatelessWidget {
  const _VboxToastView({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: VboxSpacing.xxl,
      right: VboxSpacing.xxl,
      bottom: VboxSpacing.xxl * 2,
      child: IgnorePointer(
        child: Center(
          child: Material(
            color: Colors.black.withValues(alpha: 0.85),
            borderRadius: VboxRadii.card,
            child: Padding(
              padding: VboxSpacing.symmetric(
                horizontal: VboxSpacing.lg,
                vertical: VboxSpacing.md,
              ),
              child: Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: VboxTypography.s13,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}