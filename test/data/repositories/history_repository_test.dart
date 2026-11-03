/// 数据层单测：`history_repository_impl.dart`（真库 CRUD + 去重 + 裁剪）。
///
/// 覆盖 upsert 按 `detailurl` 去重（命中更新而非新增）、list 倒序、trim 保留最新 N 条、
/// remove / clear / count。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:vbox/core/storage/storage_paths.dart';
import 'package:vbox/data/datasources/local/database_manager.dart';
import 'package:vbox/data/repositories/repositories.dart';
import 'package:vbox/domain/entities/library/library.dart';

Future<void> _deleteDbFiles(String path) async {
  for (final String suffix in <String>['', '-wal', '-shm', '-journal']) {
    final File f = File('$path$suffix');
    if (f.existsSync()) await f.delete();
  }
}

HistoryItem _h({
  String name = '片名',
  String detailurl = 'u/1',
  int jishu = 0,
  int at = 1000,
}) =>
    HistoryItem(name: name, detailurl: detailurl, jishu: jishu, lastPlayedAt: at);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final DatabaseManager dbm = DatabaseManager.instance;
  final HistoryRepositoryImpl repo = HistoryRepositoryImpl(database: dbm);
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

  test('upsert 按 detailurl 去重：重复写入为更新，主键不变', () async {
    final int id1 =
        (await repo.upsert(_h(detailurl: 'u/1', jishu: 1, at: 100))).valueOrNull!;
    final int id2 =
        (await repo.upsert(_h(detailurl: 'u/1', jishu: 5, at: 200))).valueOrNull!;

    expect(id2, id1);
    expect((await repo.count()).valueOrNull, 1);

    final HistoryItem it = (await repo.findByDetailUrl('u/1')).valueOrNull!;
    expect(it.jishu, 5);
    expect(it.lastPlayedAt, 200);
  });

  test('list 按 lastPlayedAt 倒序 + limit', () async {
    await repo.upsert(_h(detailurl: 'u/1', at: 100));
    await repo.upsert(_h(detailurl: 'u/2', at: 300));
    await repo.upsert(_h(detailurl: 'u/3', at: 200));

    final List<HistoryItem> all = (await repo.list()).valueOrNull!;
    expect(all.map((HistoryItem e) => e.lastPlayedAt).toList(),
        <int>[300, 200, 100]);

    final List<HistoryItem> top = (await repo.list(limit: 2)).valueOrNull!;
    expect(top.map((HistoryItem e) => e.lastPlayedAt).toList(), <int>[300, 200]);
  });

  test('trim 仅保留最新 N 条并返回删除条数', () async {
    for (int i = 1; i <= 5; i++) {
      await repo.upsert(_h(detailurl: 'u/$i', at: i * 100));
    }
    expect((await repo.trim(2)).valueOrNull, 3);

    final List<HistoryItem> left = (await repo.list()).valueOrNull!;
    expect(left.map((HistoryItem e) => e.lastPlayedAt).toList(), <int>[500, 400]);
  });

  test('remove / clear / count', () async {
    final int id = (await repo.upsert(_h(detailurl: 'u/1'))).valueOrNull!;
    await repo.upsert(_h(detailurl: 'u/2'));

    expect((await repo.remove(id)).valueOrNull, isTrue);
    expect((await repo.remove(id)).valueOrNull, isFalse);
    expect((await repo.count()).valueOrNull, 1);

    expect((await repo.clear()).valueOrNull, 1);
    expect((await repo.count()).valueOrNull, 0);
  });

  test('progress 往返（REAL 列）', () async {
    await repo.upsert(const HistoryItem(
      name: '片名',
      detailurl: 'u/1',
      progress: 0.42,
      lastPlayedAt: 100,
    ));
    final HistoryItem it = (await repo.findByDetailUrl('u/1')).valueOrNull!;
    expect(it.progress, closeTo(0.42, 1e-9));
    expect(it.isResumable, isTrue);
  });
}