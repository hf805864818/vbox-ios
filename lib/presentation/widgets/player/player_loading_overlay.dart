/// 表现层：播放器中央加载层（第 5 批 · UI-F18）。
///
/// 对齐 iOS `PlayerViewsV2` 加载层（[L6936-L6952](../../../../vbox/Views/PlayerViewsV2.swift#L6936-L6952)）：
/// `ProgressView`（白色，放大 1.5 倍）+ `loadingMessage` 文案，置于黑底 45%、
/// 圆角 14 的胶囊内；覆盖于画面之上、**不拦截手势**。
library;

import 'package:flutter/material.dart';

import '../../theme/tokens/radii.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';

/// 播放器中央加载层。
class PlayerLoadingOverlay extends StatelessWidget {
  /// 构造。
  const PlayerLoadingOverlay({super.key, required this.message});

  /// 加载文案（对齐 iOS `PlayerState.loadingMessage`）。
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: IgnorePointer(
        child: Container(
          // 内边距对齐 iOS 的 h28 / v20。
          padding: const EdgeInsets.symmetric(
            horizontal: 28,
            vertical: VboxSpacing.xl,
          ),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(VboxRadii.r14),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const SizedBox(
                width: 30,
                height: 30,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              ),
              const SizedBox(height: VboxSpacing.lg),
              Text(
                message,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.8),
                  fontSize: VboxTypography.s15,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
