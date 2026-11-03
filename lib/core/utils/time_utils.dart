/// 核心层：时间工具。
///
/// 约定（契约 §5）：数据库时间字段统一为 **Unix 秒**（int）。
library;

import 'package:intl/intl.dart';

/// 时间工具。
abstract final class TimeUtils {
  /// 当前 Unix 秒。
  static int nowUnixSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  /// Unix 秒 → 本地 [DateTime]。
  static DateTime fromUnixSeconds(int seconds) =>
      DateTime.fromMillisecondsSinceEpoch(seconds * 1000);

  /// [DateTime] → Unix 秒。
  static int toUnixSeconds(DateTime time) =>
      time.millisecondsSinceEpoch ~/ 1000;

  /// 格式化（默认 `yyyy-MM-dd HH:mm:ss`）。
  static String formatDateTime(
    DateTime time, {
    String pattern = 'yyyy-MM-dd HH:mm:ss',
  }) =>
      DateFormat(pattern).format(time);

  /// Unix 秒格式化。
  static String formatUnixSeconds(
    int seconds, {
    String pattern = 'yyyy-MM-dd HH:mm:ss',
  }) =>
      formatDateTime(fromUnixSeconds(seconds), pattern: pattern);

  /// 相对时间（中文，用于列表展示）。
  static String relative(DateTime time, {DateTime? now}) {
    final DateTime base = now ?? DateTime.now();
    final Duration diff = base.difference(time);
    if (diff.isNegative) return formatDateTime(time);
    if (diff.inSeconds < 60) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
    if (diff.inHours < 24) return '${diff.inHours} 小时前';
    if (diff.inDays < 30) return '${diff.inDays} 天前';
    return formatDateTime(time, pattern: 'yyyy-MM-dd');
  }

  /// 时长 → `mm:ss` / `h:mm:ss`。
  static String duration(Duration d) {
    final bool negative = d.isNegative;
    final Duration abs = negative ? -d : d;
    final int hours = abs.inHours;
    final String mm = (abs.inMinutes % 60).toString().padLeft(2, '0');
    final String ss = (abs.inSeconds % 60).toString().padLeft(2, '0');
    final String body = hours > 0 ? '$hours:$mm:$ss' : '$mm:$ss';
    return negative ? '-$body' : body;
  }

  /// 秒 → `mm:ss` / `h:mm:ss`（播放进度用）。
  static String durationFromSeconds(int seconds) =>
      duration(Duration(seconds: seconds));
}
