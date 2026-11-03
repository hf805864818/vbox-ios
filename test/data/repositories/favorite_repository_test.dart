/// 数据层单测：`favorite_repository_impl.dart`（真库 CRUD）。
///
/// 用 `sqflite_common_ffi`（桌面端真实 SQLite）在真库上跑，
/// 覆盖 add / list（倒序 + 分页）/ findByDetailUrl / findById / remove / clear / count，
/// 以及契约外列缺失时的 fromRow 容错。
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

FavoriteItem _item({
  String name = '片名',
  String detailurl = 'https://x/d/1',
  int addedAt = 1000,
}) =>
    FavoriteItem(name: name, detailurl: detailurl, addedAt: addedAt);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final DatabaseManager dbm = DatabaseManager.instance;
  final FavoriteRepositoryImpl repo = FavoriteRepositoryImpl(database: dbm);
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

  test('add → count / findById / findByDetailUrl 往返', () async {
    final Result<int> added = await repo.add(_item());
    expect(added.isSuccess, isTrue);
    final int id = added.valueOrNull!;
    expect(id, greaterThan(0));

    expect((await repo.count()).valueOrNull, 1);

    final FavoriteItem? byId = (await repo.findById(id)).valueOrNull;
    expect(byId, isNotNull);
    expect(byId!.name, '片名');
    expect(byId.detailurl, 'https://x/d/1');

    final FavoriteItem? byUrl =
        (await repo.findByDetailUrl('https://x/d/1')).valueOrNull;
    expect(byUrl!.id, id);

    expect((await repo.findByDetailUrl('https://x/none')).valueOrNull, isNull);
    expect((await repo.findById(9999)).valueOrNull, isNull);
  });

  test('list 按 addedAt 倒序 + limit/offset 分页', () async {
    await repo.add(_item(name: 'A', detailurl: 'u/A', addedAt: 100));
    await repo.add(_item(name: 'B', detailurl: 'u/B', addedAt: 300));
    await repo.add(_item(name: 'C', detailurl: 'u/C', addedAt: 200));

    final List<FavoriteItem> all = (await repo.list()).valueOrNull!;
    expect(all.map((FavoriteItem e) => e.name).toList(), <String>['B', 'C', 'A']);

    final List<FavoriteItem> page =
        (await repo.list(limit: 1, offset: 1)).valueOrNull!;
    expect(page.map((FavoriteItem e) => e.name).toList(), <String>['C']);
  });

  test('remove 命中返回 true，未命中返回 false', () async {
    final int id = (await repo.add(_item())).valueOrNull!;
    expect((await repo.remove(id)).valueOrNull, isTrue);
    expect((await repo.remove(id)).valueOrNull, isFalse);
    expect((await repo.count()).valueOrNull, 0);
  });

  test('clear 返回删除条数', () async {
    await repo.add(_item(detailurl: 'u/1'));
    await repo.add(_item(detailurl: 'u/2'));
    expect((await repo.clear()).valueOrNull, 2);
    expect((await repo.count()).valueOrNull, 0);
  });

  test('缺省列走 DDL 默认值（fromRow 容错，不抛异常）', () async {
    final Database db = await dbm.database;
    await db.insert(FavoriteItem.table, <String, Object?>{
      'name': 'minimal',
      'addedAt': 5,
    });
    final List<FavoriteItem> items = (await repo.list()).valueOrNull!;
    expect(items.single.name, 'minimal');
    expect(items.single.laiyuan, '');
    expect(items.single.xianlu, 0);
    expect(items.single.jishu, 0);
  });
}