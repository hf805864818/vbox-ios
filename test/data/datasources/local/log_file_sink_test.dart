/// 数据层单测：日志落盘 sink（按天分文件 + 流订阅 + 过期清理）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/core/utils/logger.dart';
import 'package:vbox/data/datasources/local/log_file_sink.dart';

void main() {
  late Directory tmp;
  late LogFileSink sink;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('vbox_log_sink_test');
    sink = LogFileSink(directory: tmp.path);
    AppLog.clear();
    AppLog.configure(enabled: true, minLevel: LogLevel.debug);
  });

  tearDown(() {
    AppLog.clear();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('按天分文件并逐行追加', () async {
    final DateTime t = DateTime(2026, 9, 30, 12, 0, 0);
    expect(sink.fileFor(t).endsWith('2026-09-30.log'), isTrue);

    await sink.handle(
      LogEntry(time: t, level: LogLevel.info, tag: 'T', message: '第一条'),
    );
    await sink.handle(
      LogEntry(time: t, level: LogLevel.warn, tag: 'T', message: '第二条'),
    );

    final File f = File(sink.fileFor(t));
    expect(f.existsSync(), isTrue);
    final List<String> lines = f.readAsLinesSync();
    expect(lines.length, 2);
    expect(lines.first.contains('第一条'), isTrue);
    expect(lines.last.contains('第二条'), isTrue);
  });

  test('订阅 AppLog 流写入并可按需停止', () async {
    sink.start();
    expect(sink.isRunning, isTrue);
    // 幂等
    sink.start();

    AppLog.info('T', 'streamed');
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final File f = File(sink.fileFor(DateTime.now()));
    expect(f.existsSync(), isTrue);
    expect(f.readAsStringSync().contains('streamed'), isTrue);

    await sink.stop();
    expect(sink.isRunning, isFalse);
  });

  test('prune 清理超过保留时长的文件', () async {
    final File stale = File('${tmp.path}/2000-01-01.log')
      ..writeAsStringSync('old');
    stale.setLastModifiedSync(DateTime(2000, 1, 1));

    final File fresh = File('${tmp.path}/2026-09-30.log')
      ..writeAsStringSync('new');
    fresh.setLastModifiedSync(DateTime.now());

    await sink.prune();

    expect(stale.existsSync(), isFalse);
    expect(fresh.existsSync(), isTrue);
  });

  test('目录不存在时 handle 不抛异常', () async {
    final LogFileSink broken =
        LogFileSink(directory: '${tmp.path}/nested/deeper');
    await broken.handle(
      LogEntry(
        time: DateTime(2026, 9, 30),
        level: LogLevel.info,
        tag: 'T',
        message: 'x',
      ),
    );
    // handle 会自行创建目录，故文件应存在
    expect(File(broken.fileFor(DateTime(2026, 9, 30))).existsSync(), isTrue);
  });
}