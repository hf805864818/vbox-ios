/// 网盘清理队列存储单测（批次 F · F-07）。
///
/// 对齐基准（唯一真相源）：iOS `CloudDriveManager` 的
/// `loadCleanupQueue` / `saveCleanupQueue` / `enqueueCleanup` /
/// `flushCleanupQueue`（`vbox/Services/CloudDriveManager.swift:1226-1315`）。
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vbox/data/datasources/local/cloud_drive_cleanup_queue_store.dart';
import 'package:vbox/data/datasources/local/prefs_manager.dart';
import 'package:vbox/domain/entities/cloud/cloud_drive_files.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final PrefsManager pm = PrefsManager.instance;
  late CloudDriveCleanupQueueStore store;
  final DateTime t0 = DateTime.utc(2026, 10, 3, 12);

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    await pm.init();
  });

  setUp(() async {
    await pm.clearAll();
    store = CloudDriveCleanupQueueStore(pm);
  });

  test('空存储 load() = []，count = 0', () async {
    expect(await store.load(), isEmpty);
    expect(await store.count(), 0);
  });

  test('enqueue 写入并可跨实例读回（持久化）', () async {
    await store.enqueue(
      drive: 'quark',
      tokenName: '夸克主号',
      fileIds: <String>['f1', 'f2'],
      delay: const Duration(seconds: 180),
      now: t0,
    );
    final CloudDriveCleanupQueueStore next = CloudDriveCleanupQueueStore(pm);
    final List<CloudDriveCleanupItem> items = await next.load();
    expect(items.length, 2);
    expect(
      items.map((CloudDriveCleanupItem e) => e.fileId).toSet(),
      <String>{'f1', 'f2'},
    );
    expect(items.first.createdAt, t0);
    expect(
      items.first.eligibleAt,
      t0.add(const Duration(seconds: 180)),
    );
  });

  test('enqueue 去重：重复 fileId 不新增（验收项「去重正确」）', () async {
    final List<CloudDriveCleanupItem> first = await store.enqueue(
      drive: 'baidu',
      tokenName: 'n',
      fileIds: <String>['a', 'b', 'a'],
      delay: Duration.zero,
      now: t0,
    );
    expect(first.length, 2);
    final List<CloudDriveCleanupItem> second = await store.enqueue(
      drive: 'baidu',
      tokenName: 'n',
      fileIds: <String>['b', 'c'],
      delay: Duration.zero,
      now: t0.add(const Duration(seconds: 5)),
    );
    expect(second.length, 3);
    expect(await store.count(), 3);
  });

  test('due 只返回到期条目，removeDue 收缩队列', () async {
    await store.enqueue(
      drive: 'quark',
      tokenName: 'n',
      fileIds: <String>['a'],
      delay: Duration.zero,
      now: t0,
    );
    await store.enqueue(
      drive: 'quark',
      tokenName: 'n',
      fileIds: <String>['b'],
      delay: const Duration(minutes: 10),
      now: t0,
    );

    final DateTime probe = t0.add(const Duration(seconds: 1));
    final List<CloudDriveCleanupItem> due = await store.due(now: probe);
    expect(due.map((CloudDriveCleanupItem e) => e.fileId), <String>['a']);

    final List<CloudDriveCleanupItem> remaining =
        await store.removeDue(now: probe);
    expect(remaining.map((CloudDriveCleanupItem e) => e.fileId), <String>['b']);
    expect(await store.count(), 1);
  });

  test('removeDue 无到期项时不写入（保持原队列）', () async {
    await store.enqueue(
      drive: 'quark',
      tokenName: 'n',
      fileIds: <String>['a'],
      delay: const Duration(hours: 1),
      now: t0,
    );
    final List<CloudDriveCleanupItem> remaining = await store.removeDue(now: t0);
    expect(remaining.length, 1);
    expect(await store.count(), 1);
  });

  test('clear 清空队列', () async {
    await store.enqueue(
      drive: 'quark',
      tokenName: 'n',
      fileIds: <String>['a'],
      delay: Duration.zero,
      now: t0,
    );
    await store.clear();
    expect(await store.count(), 0);
  });

  test('非法 JSON / 非数组 / 缺 fileId 容忍为空', () async {
    await pm.set(CloudDriveCleanupQueueStore.storageKey, '{not-json');
    expect(await store.load(), isEmpty);
    await pm.set(CloudDriveCleanupQueueStore.storageKey, '{"a":1}');
    expect(await store.load(), isEmpty);
    await pm.set(
      CloudDriveCleanupQueueStore.storageKey,
      '[{"drive":"quark","tokenName":"n","fileId":""}]',
    );
    expect(await store.load(), isEmpty);
  });

  test('落 userdefaults 契约键（明文 SharedPreferences 可见）', () async {
    await store.enqueue(
      drive: 'quark',
      tokenName: 'n',
      fileIds: <String>['f1'],
      delay: Duration.zero,
      now: t0,
    );
    final SharedPreferences raw = await SharedPreferences.getInstance();
    expect(
      raw.getString(CloudDriveCleanupQueueStore.storageKey),
      contains('f1'),
    );
  });
}
