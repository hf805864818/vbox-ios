/// 数据层单测：`search_history_repository_impl.dart`（真库 CRUD + 去重）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:vbox/core/storage/storage_paths.dart';
import 'package:vbox/data/datasources/local/database_manager.dart';
import 'package:vbox/data/repositories/repositories.dart';

Future<void> _deleteDbFiles(String path) async {
  for (final String suffix in <String>['', '-wal', '-shm', '-journal']) {
    final File f = File('$path$suffix');
    if (f.existsSync()) await f.delete();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final DatabaseManager dbm = DatabaseManager.instance;
  final SearchHistoryRepositoryImpl repo =
      SearchHistoryRepositoryImpl(database: dbm);
  late String dbPath;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final Directory tmp =
        await Directory.systemTemp.createTemp('vbox_search_history_test');
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

  test('add → recent：按时间倒序 + 同词去重保留最新', () async {
    await repo.add('三体');
    await repo.add('流浪地球');
    // 跨秒写入确保最后一条「三体」搜索时间严格更新（searchedAt 为 Unix 秒）
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    await repo.add('三体');

    final List<String> recent = (await repo.recent()).valueOrNull!;
    expect(recent, <String>['三体', '流浪地球']);
  });

  test('add：关键词去空白', () async {
    await repo.add('  变形金刚  ');
    final List<String> recent = (await repo.recent()).valueOrNull!;
    expect(recent, <String>['变形金刚']);
  });

  test('recent：limit 截取条数', () async {
    await repo.add('a');
    await repo.add('b');
    await repo.add('c');

    final List<String> top = (await repo.recent(limit: 2)).valueOrNull!;
    expect(top.length, 2);
  });

  test('clear：清空后 recent 为空', () async {
    await repo.add('a');
    await repo.add('b');

    final int deleted = (await repo.clear()).valueOrNull!;
    expect(deleted, 2);
    expect((await repo.recent()).valueOrNull, isEmpty);
  });
}