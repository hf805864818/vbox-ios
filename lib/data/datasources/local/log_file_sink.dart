/// 数据层：日志落盘 sink。
///
/// 对齐 iOS `AppLogStore` 的持久化行为：
/// - 按天分文件 `yyyy-MM-dd.log`（目录取核心层 [StoragePaths.logDir]）
/// - 订阅 [AppLog.stream] 追加写入（闸门已在核心层过滤，本层不再判级别）
/// - 启动时清理超过保留时长（3 小时，对齐 iOS `persistDays = 0.125`）的旧文件
///
/// 分层约束：核心层 [AppLog] 只做内存环形缓冲、**不落盘**（见 logger.dart 注释），
/// 落盘职责在本层；任何 IO 失败一律吞掉，绝不影响主流程。
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/storage/storage_paths.dart';
import '../../../core/utils/logger.dart';

/// 日志文件 sink。
class LogFileSink {
  /// 构造（[directory] 便于单测注入临时目录）。
  LogFileSink({String? directory, this.retention = defaultRetention})
      : _directoryOverride = directory;

  /// 日志保留时长（对齐 iOS `persistDays = 0.125` 天 = 3 小时）。
  static const Duration defaultRetention = Duration(hours: 3);

  final String? _directoryOverride;

  /// 保留时长。
  final Duration retention;

  StreamSubscription<LogEntry>? _sub;

  /// 是否已开始订阅。
  bool get isRunning => _sub != null;

  /// 日志目录（未注入则取核心层目录布局）。
  String get directory => _directoryOverride ?? StoragePaths.logDir;

  /// 指定日期对应的日志文件绝对路径。
  String fileFor(DateTime date) {
    String two(int v) => v.toString().padLeft(2, '0');
    return p.join(
      directory,
      '${date.year}-${two(date.month)}-${two(date.day)}.log',
    );
  }

  /// 开始订阅（幂等）；顺带清理过期文件。
  void start() {
    if (_sub != null) return;
    _sub = AppLog.stream.listen(handle);
    unawaited(prune());
  }

  /// 停止订阅。
  Future<void> stop() async {
    final StreamSubscription<LogEntry>? sub = _sub;
    _sub = null;
    await sub?.cancel();
  }

  /// 写入单条日志（供订阅回调与单测直接调用）。
  Future<void> handle(LogEntry entry) async {
    try {
      await Directory(directory).create(recursive: true);
      await File(fileFor(entry.time))
          .writeAsString('${entry.format()}\n', mode: FileMode.append);
    } catch (_) {
      // 落盘失败不得影响主流程
    }
  }

  /// 清理超过 [retention] 未更新的 `.log` 文件。
  Future<void> prune({DateTime? now}) async {
    try {
      final Directory dir = Directory(directory);
      if (!dir.existsSync()) return;
      final DateTime cutoff = (now ?? DateTime.now()).subtract(retention);
      await for (final FileSystemEntity entity in dir.list()) {
        if (entity is! File || !entity.path.endsWith('.log')) continue;
        if (entity.statSync().modified.isBefore(cutoff)) {
          try {
            await entity.delete();
          } catch (_) {
            // 单个文件删除失败忽略
          }
        }
      }
    } catch (_) {
      // 目录不存在等异常忽略
    }
  }
}