/// 核心层单测：日志（环形缓冲 + 过滤导出 + 广播流）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/core/constants/app_constants.dart';
import 'package:vbox/core/utils/logger.dart';

void main() {
  // 闸门在测试间必须复位（闸门是全局静态状态）
  void resetGate() {
    AppLog.clear();
    AppLog.configure(enabled: true, minLevel: LogLevel.debug);
  }

  setUp(resetGate);
  tearDown(resetGate);

  test('基础写入与级别', () {
    AppLog.info('T', 'hello');
    AppLog.error('T', 'boom', error: StateError('e'));
    expect(AppLog.length, 2);
    expect(AppLog.entries.first.level, LogLevel.info);
    expect(AppLog.entries.last.message, 'boom');
    expect(AppLog.entries.last.error, isA<StateError>());
  });

  test('format 含级别与标签', () {
    AppLog.warn('DbMgr', '慢查询');
    final String line = AppLog.entries.single.format();
    expect(line.contains('WARN'), isTrue);
    expect(line.contains('DbMgr: 慢查询'), isTrue);
    // 时间戳格式 yyyy-MM-dd HH:mm:ss
    expect(RegExp(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} ').hasMatch(line), isTrue);
  });

  test('环形缓冲按容量淘汰最旧', () {
    const int cap = LogConstants.ringBufferSize;
    for (int i = 0; i < cap + 5; i++) {
      AppLog.debug('T', 'line$i');
    }
    expect(AppLog.length, cap);
    expect(AppLog.entries.first.message, 'line5');
    expect(AppLog.entries.last.message, 'line${cap + 4}');
  });

  test('dump 支持级别过滤与条数限制', () {
    AppLog.debug('T', 'd1');
    AppLog.info('T', 'i1');
    AppLog.warn('T', 'w1');
    AppLog.error('T', 'e1');

    expect(AppLog.dump().split('\n').length, 4);

    final String warnOnly = AppLog.dump(minLevel: LogLevel.warn);
    expect(warnOnly.contains('w1'), isTrue);
    expect(warnOnly.contains('e1'), isTrue);
    expect(warnOnly.contains('i1'), isFalse);

    final List<String> lastTwo = AppLog.dump(limit: 2).split('\n');
    expect(lastTwo.length, 2);
    expect(lastTwo.first.contains('w1'), isTrue);
  });

  test('广播流可订阅', () async {
    final Future<LogEntry> first = AppLog.stream.first;
    AppLog.info('T', 'streamed');
    final LogEntry e = await first;
    expect(e.message, 'streamed');
  });

  test('clear 后缓冲为空', () {
    AppLog.info('T', 'x');
    AppLog.clear();
    expect(AppLog.length, 0);
    expect(AppLog.dump(), '');
  });

  test('闸门：关闭时不记录', () {
    AppLog.configure(enabled: false);
    AppLog.error('T', 'x');
    expect(AppLog.length, 0);
    expect(AppLog.enabled, isFalse);
  });

  test('闸门：低于最低级别直接丢弃', () {
    AppLog.configure(minLevel: LogLevel.warn);
    AppLog.debug('T', 'd');
    AppLog.info('T', 'i');
    AppLog.warn('T', 'w');
    AppLog.error('T', 'e');
    expect(AppLog.minLevel, LogLevel.warn);
    expect(AppLog.length, 2);
    expect(AppLog.entries.first.level, LogLevel.warn);
  });

  test('LogLevel.fromValue 映射与越界钳制', () {
    expect(LogLevel.fromValue(0), LogLevel.debug);
    expect(LogLevel.fromValue(1), LogLevel.info);
    expect(LogLevel.fromValue(2), LogLevel.warn);
    expect(LogLevel.fromValue(3), LogLevel.error);
    expect(LogLevel.fromValue(-1), LogLevel.debug);
    expect(LogLevel.fromValue(99), LogLevel.error);
  });

  test('LogCategory.fromTag：按标签推断模块（S-设4，对齐 iOS LogCategory）', () {
    expect(LogCategory.fromTag('network'), LogCategory.network);
    expect(LogCategory.fromTag('HttpClient'), LogCategory.network);
    expect(LogCategory.fromTag('SpiderManager'), LogCategory.spider);
    expect(LogCategory.fromTag('zhanyuan'), LogCategory.spider);
    expect(LogCategory.fromTag('PlayerPage'), LogCategory.player);
    expect(LogCategory.fromTag('CloudDrive'), LogCategory.cloud);
    expect(LogCategory.fromTag('pan'), LogCategory.cloud);
    expect(LogCategory.fromTag('ProxyHost'), LogCategory.proxy);
    expect(LogCategory.fromTag('DownloadMgr'), LogCategory.download);
    expect(LogCategory.fromTag('Welfare'), LogCategory.welfare);
    expect(LogCategory.fromTag('NodeRuntime'), LogCategory.node);
    expect(LogCategory.fromTag('MusicHome'), LogCategory.music);
    expect(LogCategory.fromTag('DbMgr'), LogCategory.db);
    expect(LogCategory.fromTag('sqlite'), LogCategory.db);
    expect(LogCategory.fromTag('Whatever'), LogCategory.app);
  });

  test('写入：未传分类按 tag 推断；显式分类优先', () {
    AppLog.info('network', 'req');
    expect(AppLog.entries.last.category, LogCategory.network);

    AppLog.info('Whatever', 'x', category: LogCategory.welfare);
    expect(AppLog.entries.last.category, LogCategory.welfare);
  });

  test('format 含 [category] 段；dump 支持分类过滤', () {
    AppLog.info('network', 'net-line');
    AppLog.info('music', 'music-line');

    expect(AppLog.entries.first.format().contains('[network]'), isTrue);

    final String netOnly = AppLog.dump(category: LogCategory.network);
    expect(netOnly.contains('net-line'), isTrue);
    expect(netOnly.contains('music-line'), isFalse);
  });
}
