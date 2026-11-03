/// 表现层：播放器错误态 / 重试视图（第 2 批 · UI-F10）。
///
/// 对齐 iOS 三件套（[PlayerViewsV2.swift](../../../../vbox/Views/PlayerViewsV2.swift)）：
///  - [PlayerErrorView]：`ErrorView`（L7557）—— 错误图标 + 「加载失败」+ 原因 +
///    重试 / 返回；
///  - [PlayerErrorWithLogsView]：`ErrorViewWithLogs`（L7614）—— 在错误态基础上
///    附带可展开的调试日志；
///  - [PlayerUnsupportedView]：`CompatibilityUnavailableView`（L8907）—— 内核
///    不支持 / 编码不兼容提示（纯展示，无按钮）。
///
/// 「重试」仅对可重试错误显示（对齐 iOS `ErrorView.isRetryable`：地址失效 /
/// 内容和谐 / 禁止播放 / 转存占位类错误不可重试）。
library;

import 'package:flutter/material.dart';

import '../../theme/tokens/radii.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';

/// 不可重试错误的特征子串（对齐 iOS `ErrorView.isRetryable` 的 4 个判据）。
const List<String> kNonRetryableErrorMarkers = <String>[
  '已失效',
  '已被和谐',
  '禁止播放',
  '转存返回占位',
];

/// 判定错误是否可重试（对齐 iOS `isRetryable`：不含特征子串即可重试）。
bool isPlayerErrorRetryable(String error) {
  for (final String marker in kNonRetryableErrorMarkers) {
    if (error.contains(marker)) return false;
  }
  return true;
}

/// 错误态 / 重试视图（对齐 iOS `ErrorView`）。
class PlayerErrorView extends StatelessWidget {
  /// 构造。
  const PlayerErrorView({
    super.key,
    required this.message,
    this.onRetry,
    this.onBack,
  });

  /// 错误原因文案。
  final String message;

  /// 重试回调；为 null 或错误不可重试时不显示「重试」。
  final VoidCallback? onRetry;

  /// 返回回调；为 null 时不显示「返回」。
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    return _ErrorScaffold(
      message: message,
      bodyFontSize: VboxTypography.s14,
      bodyOpacity: 0.7,
      retryable: onRetry != null && isPlayerErrorRetryable(message),
      onRetry: onRetry,
      onBack: onBack,
    );
  }
}

/// 错误态 / 重试视图（含调试日志；对齐 iOS `ErrorViewWithLogs`）。
class PlayerErrorWithLogsView extends StatelessWidget {
  /// 构造。
  const PlayerErrorWithLogsView({
    super.key,
    required this.message,
    this.logs = const <String>[],
    this.onRetry,
    this.onBack,
  });

  /// 错误原因文案。
  final String message;

  /// 调试日志（按时间顺序；空表则隐藏日志区）。
  final List<String> logs;

  /// 重试回调；为 null 或错误不可重试时不显示「重试」。
  final VoidCallback? onRetry;

  /// 返回回调；为 null 时不显示「返回」。
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    return _ErrorScaffold(
      message: message,
      bodyFontSize: VboxTypography.s14,
      bodyOpacity: 0.9,
      retryable: onRetry != null && isPlayerErrorRetryable(message),
      onRetry: onRetry,
      onBack: onBack,
      logs: logs,
    );
  }
}

/// 兼容内核不可用视图（对齐 iOS `CompatibilityUnavailableView`）。
///
/// 纯展示（无按钮）：用于「当前资源需指定兼容内核」的提示，覆盖于画面之上。
class PlayerUnsupportedView extends StatelessWidget {
  /// 构造。
  const PlayerUnsupportedView({
    super.key,
    required this.engineName,
    this.message = '',
  });

  /// 所需内核名（如 `MPV` / `MDK`）。
  final String engineName;

  /// 补充说明文案（可为空）。
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.play_disabled_rounded,
            size: 42,
            color: Colors.white.withValues(alpha: 0.85),
          ),
          const SizedBox(height: VboxSpacing.md),
          Text(
            '当前资源需要$engineName兼容内核',
            style: const TextStyle(
              color: Colors.white,
              fontSize: VboxTypography.s16,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (message.isNotEmpty) ...<Widget>[
            const SizedBox(height: VboxSpacing.sm),
            Padding(
              padding: VboxSpacing.symmetric(horizontal: VboxSpacing.xl),
              child: Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7),
                  fontSize: VboxTypography.s13,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 错误态公共骨架（图标 + 标题 + 原因 + 可选日志 + 按钮行）。
class _ErrorScaffold extends StatelessWidget {
  const _ErrorScaffold({
    required this.message,
    required this.bodyFontSize,
    required this.bodyOpacity,
    required this.retryable,
    this.onRetry,
    this.onBack,
    this.logs = const <String>[],
  });

  final String message;
  final double bodyFontSize;
  final double bodyOpacity;
  final bool retryable;
  final VoidCallback? onRetry;
  final VoidCallback? onBack;
  final List<String> logs;

  @override
  Widget build(BuildContext context) {
    final bool hasLogs = logs.isNotEmpty;
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.82),
      child: Center(
        child: SingleChildScrollView(
          padding: VboxSpacing.symmetric(horizontal: VboxSpacing.xxl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(
                Icons.warning_amber_rounded,
                size: 50,
                color: Colors.orange,
              ),
              const SizedBox(height: VboxSpacing.xl),
              const Text(
                '加载失败',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: VboxTypography.s24,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: VboxSpacing.lg),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: bodyOpacity),
                  fontSize: bodyFontSize,
                ),
              ),
              if (hasLogs) ...<Widget>[
                const SizedBox(height: VboxSpacing.lg),
                _DebugLogs(logs: logs),
              ],
              const SizedBox(height: VboxSpacing.xxl),
              Wrap(
                spacing: VboxSpacing.lg,
                runSpacing: VboxSpacing.md,
                alignment: WrapAlignment.center,
                children: <Widget>[
                  if (retryable)
                    _ErrorActionButton(
                      label: '重试',
                      color: Colors.blue,
                      onTap: onRetry,
                    ),
                  if (onBack != null)
                    _ErrorActionButton(
                      label: '返回',
                      color: Colors.grey,
                      onTap: onBack,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 可展开的调试日志区（对齐 iOS 绿色浮层里的日志查看）。
class _DebugLogs extends StatelessWidget {
  const _DebugLogs({required this.logs});

  final List<String> logs;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520, maxHeight: 160),
      child: Container(
        width: double.infinity,
        padding: VboxSpacing.all(VboxSpacing.md),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: VboxRadii.card,
          border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (final String line in logs)
                Padding(
                  padding: VboxSpacing.symmetric(vertical: 1),
                  child: Text(
                    line,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.8),
                      fontSize: VboxTypography.s11,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 错误态动作按钮（对齐 iOS `Text + padding + background + cornerRadius(8)`）。
class _ErrorActionButton extends StatelessWidget {
  const _ErrorActionButton({
    required this.label,
    required this.color,
    this.onTap,
  });

  final String label;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: VboxSpacing.symmetric(
          horizontal: VboxSpacing.xxxl,
          vertical: VboxSpacing.md,
        ),
        decoration: BoxDecoration(
          color: color,
          borderRadius: VboxRadii.button,
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: VboxTypography.s14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
