/// 数据层单测：`subscription_repository_impl.dart`（真库 CRUD + DDL 约束）。
///
/// 覆盖 add / list（按名称升序）/ findByUrl / findById / remove / touchSync，
/// 并固化契约 DDL 的真相：`subscription.dyurl UNIQUE`（地址全局唯一）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:vbox/core/storage/storage_paths.dart';
import 'package:vbox/core/utils/result.dart';
import 'package:vbox/data/datasources/local/database_manager.dart';
import 'package:vbox/data/repositories/repositories.dart';
import 'package:vbox/domain/entities/library/library.dart';

Future<void> _deleteDbFiles(String path) async {
  for (final String suffix in <String>['', '-wal', '-shm', '-journal']) {
    final File f = File('$path$suffix');
    if (f.existsSync()) await f.delete();
  }
}

SubscriptionItem _s({String name = 'A', String url = 'u/a', int at = 0}) =>
    SubscriptionItem(dyname: name, dyurl: url, lastSyncAt: at);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final DatabaseManager dbm = DatabaseManager.instance;
  final SubscriptionRepositoryImpl repo =
      SubscriptionRepositoryImpl(database: dbm);
  late String dbPath;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final Directory tmp = await Directory.systemTemp.createTemp('vbox_repo_test');
    StoragePaths.configure(tmp.path);
    await StoragePaths.ensureLayout();
    dbPath = StoragePaths.databaseFile;
  });

  setUp(() async {
    await dbm.close();
    await _deleteDbFiles(dbPath);
  });

  tearDown(() async {
    await dbm.close();
    await _deleteDbFiles(dbPath);
  });

  test('add → list 按 dyname 升序 / findByUrl / findById', () async {
    await repo.add(_s(name: 'B', url: 'u/b'));
    final int id = (await repo.add(_s(name: 'A', url: 'u/a'))).valueOrNull!;

    final List<SubscriptionItem> all = (await repo.list()).valueOrNull!;
    expect(all.map((SubscriptionItem e) => e.dyname).toList(),
        <String>['A', 'B']);

    final SubscriptionItem? found = (await repo.findByUrl('u/a')).valueOrNull;
    expect(found!.id, id);
    expect((await repo.findByUrl('u/x')).valueOrNull, isNull);

    expect((await repo.findById(id)).valueOrNull!.dyurl, 'u/a');
  });

  test('touchSync 更新最后同步时间', () async {
    final int id = (await repo.add(_s(at: 0))).valueOrNull!;
    expect((await repo.touchSync(id, 1700000000)).valueOrNull, isTrue);

    final SubscriptionItem it = (await repo.findById(id)).valueOrNull!;
    expect(it.lastSyncAt, 1700000000);
    expect(it.neverSynced, isFalse);

    expect((await repo.touchSync(9999, 1)).valueOrNull, isFalse);
  });

  test('DDL 真相：dyurl 全局唯一（同址不同名第二次插入失败）', () async {
    final Result<int> first =
        await repo.add(_s(name: 'A', url: 'u/same'));
    expect(first.isSuccess, isTrue);

    final Result<int> second = await repo.add(_s(name: 'B', url: 'u/same'));
    expect(second.isSuccess, isFalse,
        reason: '契约 contract/schema/schema_v1.sql：subscription.dyurl UNIQUE');
    expect((await repo.list()).valueOrNull!.length, 1);
  });

  test('remove 命中 / 未命中', () async {
    final int id = (await repo.add(_s())).valueOrNull!;
    expect((await repo.remove(id)).valueOrNull, isTrue);
    expect((await repo.remove(id)).valueOrNull, isFalse);
    expect((await repo.list()).valueOrNull, isEmpty);
  });
}