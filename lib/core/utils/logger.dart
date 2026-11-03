/// 核心层：日志。
///
/// 设计对齐 iOS `vbox/Services/AppLogStore.swift`：
/// - 内存环形缓冲（容量见 `LogConstants.ringBufferSize`），供「日志查看」页面读取；
/// - 广播流，供实时订阅（调试面板）；
/// - **不落盘**：落盘由平台层/数据层负责，核心层保持纯 Dart、可单测。
library;

import 'dart:async';

import '../constants/app_constants.dart';

/// 日志级别。
///
/// 序号与 iOS `LogLevel`（verbose=0 / info=1 / warn=2 / error=3）逐位对齐，
/// 供契约键 `app_log_min_level` 的整数值直接映射。
enum LogLevel {
  /// 调试（对应 iOS `verbose`）。
  debug,

  /// 常规信息。
  info,

  /// 警告。
  warn,

  /// 错误。
  error;

  /// 由契约 `app_log_min_level` 的整数值解析（越界钳制到最近端点）。
  static LogLevel fromValue(int value) {
    if (value <= 0) return LogLevel.debug;
    if (value >= LogLevel.values.length - 1) return LogLevel.error;
    return LogLevel.values[value];
  }
}

/// 日志模块分类（对齐 iOS `LogCategory`，序号与 `codeName` 逐位一致）。
///
/// 用于日志查看页的「模块筛选」与落盘行的 `[category]` 段；
/// 调用方未显式传分类时，由 [fromTag] 按标签推断（如 `network` → 网络）。
enum LogCategory {
  /// 应用（默认分类）。
  app('应用', 'app'),

  /// 爬虫 / 站源。
  spider('爬虫', 'spider'),

  /// 播放器。
  player('播放器', 'player'),

  /// 网盘。
  cloud('网盘', 'cloud'),

  /// 代理。
  proxy('代理', 'proxy'),

  /// 网络。
  network('网络', 'network'),

  /// 数据库。
  db('数据库', 'db'),

  /// 下载。
  download('下载', 'download'),

  /// 福利区。
  welfare('福利区', 'welfare'),

  /// Node 常驻系统。
  node('Node 常驻系统', 'node'),

  /// 音乐。
  music('音乐', 'music');

  const LogCategory(this.displayName, this.codeName);

  /// 中文显示名（筛选菜单展示）。
  final String displayName;

  /// 代码名（日志行 / 落盘文本）。
  final String codeName;

  /// 由标签推断分类（未显式传 [LogCategory] 时的兜底）。
  static LogCategory fromTag(String tag) {
    final String t = tag.toLowerCase();
    if (t.contains('network') || t.contains('http')) return LogCategory.network;
    if (t.contains('spider') || t.contains('zhanyuan')) return LogCategory.spider;
    if (t.contains('play')) return LogCategory.player;
    if (t.contains('cloud') ||
        t.contains('drive') ||
        t.contains('pan')) {
      return LogCategory.cloud;
    }
    if (t.contains('proxy')) return LogCategory.proxy;
    if (t.contains('download')) return LogCategory.download;
    if (t.contains('welfare')) return LogCategory.welfare;
    if (t.contains('node')) return LogCategory.node;
    if (t.contains('music')) return LogCategory.music;
    if (t.contains('db') || t.contains('sqlite') || t.contains('database')) {
      return LogCategory.db;
    }
    return LogCategory.app;
  }
}

/// 单条日志。
class LogEntry {
  /// 构造。
  const LogEntry({
    required this.time,
    required this.level,
    required this.tag,
    required this.message,
    this.category = LogCategory.app,
    this.error,
  });

  /// 发生时间。
  final DateTime time;

  /// 级别。
  final LogLevel level;

  /// 模块分类（默认 [LogCategory.app]）。
  final LogCategory category;

  /// 标签（一般传类名/模块名）。
  final String tag;

  /// 正文。
  final String message;

  /// 关联错误（可空）。
  final Object? error;

  /// 单行格式化（含 `[category]` 段，对齐 iOS `logLine`）。
  String format() {
    final StringBuffer sb = StringBuffer()
      ..write(_timestamp(time))
      ..write(' [')
      ..write(level.name.toUpperCase().padRight(5))
      ..write('] [')
      ..write(category.codeName)
      ..write('] ')
      ..write(tag)
      ..write(': ')
      ..write(message);
    if (error != null) {
      sb.write(' ← ');
      sb.write(error);
    }
    return sb.toString();
  }

  @override
  String toString() => format();

  static String _timestamp(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }
}

/// 全局日志器（无第三方依赖，可单测）。
///
/// 闸门（对齐 iOS `AppLogStore`）：
/// - 总开关 [enabled] ← 契约键 `app_log_enabled`（iOS 缺省 false）
/// - 最低级别 [minLevel] ← 契约键 `app_log_min_level`（整数值，缺省 verbose/0）
///
/// 闸门由**数据层在启动时**按契约键配置（核心层不依赖 prefs 插件）；
/// 未配置时默认「开启 + debug 级」，使核心层作为纯工具保持可用（单测直接记录）。
/// 生产环境启动时按契约键配置，iOS 缺省为关闭，故生产默认不产生日志。
abstract final class AppLog {
  static final List<LogEntry> _entries = <LogEntry>[];
  static final StreamController<LogEntry> _controller =
      StreamController<LogEntry>.broadcast();

  static bool _enabled = true;
  static LogLevel _minLevel = LogLevel.debug;

  /// 是否启用记录。
  static bool get enabled => _enabled;

  /// 最低记录级别（低于此级别直接丢弃）。
  static LogLevel get minLevel => _minLevel;

  /// 配置闸门（启动时由数据层按契约键调用；参数为空则保持现值）。
  static void configure({bool? enabled, LogLevel? minLevel}) {
    if (enabled != null) _enabled = enabled;
    if (minLevel != null) _minLevel = minLevel;
  }

  /// 当前缓冲条数。
  static int get length => _entries.length;

  /// 缓冲快照（只读）。
  static List<LogEntry> get entries => List<LogEntry>.unmodifiable(_entries);

  /// 实时订阅。
  static Stream<LogEntry> get stream => _controller.stream;

  /// 写入一条日志。
  ///
  /// [category] 未显式传入时按 [tag] 推断（[LogCategory.fromTag]）。
  static void log(
    LogLevel level,
    String tag,
    String message, {
    LogCategory? category,
    Object? error,
  }) {
    if (!_enabled || level.index < _minLevel.index) return;
    final LogEntry entry = LogEntry(
      time: DateTime.now(),
      level: level,
      category: category ?? LogCategory.fromTag(tag),
      tag: tag,
      message: message,
      error: error,
    );
    _entries.add(entry);
    final int overflow = _entries.length - LogConstants.ringBufferSize;
    if (overflow > 0) {
      _entries.removeRange(0, overflow);
    }
    if (!_controller.isClosed) {
      _controller.add(entry);
    }
  }

  /// debug 级。
  static void debug(
    String tag,
    String message, {
    LogCategory? category,
    Object? error,
  }) =>
      log(LogLevel.debug, tag, message, category: category, error: error);

  /// info 级。
  static void info(
    String tag,
    String message, {
    LogCategory? category,
    Object? error,
  }) =>
      log(LogLevel.info, tag, message, category: category, error: error);

  /// warn 级。
  static void warn(
    String tag,
    String message, {
    LogCategory? category,
    Object? error,
  }) =>
      log(LogLevel.warn, tag, message, category: category, error: error);

  /// error 级。
  static void error(
    String tag,
    String message, {
    LogCategory? category,
    Object? error,
  }) =>
      log(LogLevel.error, tag, message, category: category, error: error);

  /// 清空缓冲（不影响订阅者）。
  static void clear() => _entries.clear();

  /// 导出文本（`limit` 为最大条数，取**最新**若干条）。
  static String dump({LogLevel? minLevel, LogCategory? category, int? limit}) {
    Iterable<LogEntry> list = _entries;
    if (minLevel != null) {
      list = list.where((LogEntry e) => e.level.index >= minLevel.index);
    }
    if (category != null) {
      list = list.where((LogEntry e) => e.category == category);
    }
    if (limit != null && list.length > limit) {
      list = list.skip(list.length - limit);
    }
    return list.map((LogEntry e) => e.format()).join('\n');
  }
}
