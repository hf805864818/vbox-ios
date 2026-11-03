/// 数据层单测：#10 —— `database_manager.dart`（建库 / 迁移链 / CRUD）。
///
/// 用 `sqflite_common_ffi`（桌面端真实 SQLite）在**真库**上跑：
///   ① 从零建库 → v4 / 9 表 / 索引 / 可空列；
///   ② 旧库（v1）升级 → v2 重建 + v3 索引 + v4 列，**数据不丢**；
///   ③ 通用 CRUD 与唯一约束、upsert 语义。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:vbox/contract/schema/schema.dart';
import 'package:vbox/core/storage/storage_paths.dart';
import 'package:vbox/data/datasources/local/database_manager.dart';
import 'package:vbox/data/models/models.dart';

Future<void> _deleteDbFiles(String path) async {
  for (final String suffix in <String>['', '-wal', '-shm', '-journal']) {
    final File f = File('$path$suffix');
    if (f.existsSync()) await f.delete();
  }
}

Future<Set<String>> _tables(Database db) async {
  final List<Map<String, Object?>> rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'");
  return rows.map((Map<String, Object?> r) => r['name']! as String).toSet();
}

Future<Set<String>> _columns(Database db, String table) async {
  final List<Map<String, Object?>> rows =
      await db.rawQuery('PRAGMA table_info($table)');
  return rows.map((Map<String, Object?> r) => r['name']! as String).toSet();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final DatabaseManager dbm = DatabaseManager.instance;
  late String dbPath;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    // 路径单一真相源：由核心层 StoragePaths 提供（与生产代码同源）
    final Directory tmp = await Directory.systemTemp.createTemp('vbox_db_test');
    StoragePaths.configure(tmp.path);
    await StoragePaths.ensureLayout();
    dbPath = StoragePaths.databaseFile;
  });

  setUp(() async {
    await dbm.close();
    await _deleteDbFiles(dbPath);
  });

  tearDownAll(() async {
    await dbm.close();
    await _deleteDbFiles(dbPath);
  });

  group('从零建库（onCreate 全链）', () {
    test('版本 = kSchemaVersion，恰好 9 张业务表', () async {
      final Database db = await dbm.database;
      expect(await db.getVersion(), kSchemaVersion);
      expect(await _tables(db), kAllTables.toSet());
      expect(DatabaseManager.migrationNames.length, kSchemaVersion);
    });

    test('download 表含 4 个可空列（NOT NULL 约束为 0）', () async {
      final Database db = await dbm.database;
      final List<Map<String, Object?>> info =
          await db.rawQuery('PRAGMA table_info(download)');
      final Map<String, Map<String, Object?>> byName = <String, Map<String, Object?>>{
        for (final Map<String, Object?> r in info) r['name']! as String: r,
      };
      for (final String c in kDownloadV4NullableColumns) {
        expect(byName.containsKey(c), isTrue, reason: 'download 缺列 $c');
        expect(byName[c]!['notnull'], 0, reason: '$c 必须可空');
      }
    });

    test('v3 三个降序索引存在', () async {
      final Database db = await dbm.database;
      final List<Map<String, Object?>> rows = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='index'");
      final Set<String> idx =
          rows.map((Map<String, Object?> r) => r['name']! as String).toSet();
      expect(idx.containsAll(<String>[
        'idx_search_history_time',
        'idx_history_time',
        'idx_favorite_time',
      ]), isTrue);
    });

    test('PRAGMA foreign_keys 已开启（onConfigure）', () async {
      final Database db = await dbm.database;
      final List<Map<String, Object?>> r = await db.rawQuery('PRAGMA foreign_keys');
      expect(r.first.values.first, 1);
    });
  });

  group('旧库 v1 → v4 升级（迁移链 + 数据保留）', () {
    test('v1 库升级后：版本 4、数据保留、v2 唯一约束生效、v4 列存在', () async {
      // 手工建造一个「旧版本 App 留下的 v1 库」
      final Database v1 = await databaseFactory.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (Database db, int version) async {
            for (final String s in migrationFor(1)) {
              await db.execute(s);
            }
          },
        ),
      );
      final int oldId = await v1.insert('zhanyuan', <String, Object?>{
        'name': '旧源',
        'searchUrl': 'http://old/s',
        'searchUA': '',
        'playUA': '',
        'websearchurl': '',
        'searchname': '',
        'searchid': '',
        'searchpic': '',
        'searchstarr': '',
        'detaillist': '',
        'detailxl': '',
        'detailjs': '',
        'detailjsurl': '',
        'isActive': 1,
        'updatedAt': 1600000000,
        'dyurl': 'dy-old',
      });
      await v1.close();

      // 新版本 App 打开 → 触发 onUpgrade(1 → 4)
      final Database db = await dbm.database;
      expect(await db.getVersion(), kSchemaVersion);

      final Map<String, Object?> row =
          (await db.query('zhanyuan', where: 'id = ?', whereArgs: <Object?>[oldId]))
              .single;
      expect(row['name'], '旧源');
      expect(row['dyurl'], 'dy-old');
      expect(row['updatedAt'], 1600000000);

      // v2：唯一约束已改为 (name, dyurl) —— 同 name 不同 dyurl 可共存
      await db.insert('zhanyuan', <String, Object?>{
        'name': '旧源',
        'searchUrl': 'http://old/s2',
        'updatedAt': 1600000001,
        'dyurl': 'dy-2',
      });
      expect(await dbm.count('zhanyuan'), 2);

      // v4：download 已有 4 个可空列
      expect((await _columns(db, 'download')).containsAll(kDownloadV4NullableColumns),
          isTrue);
    });
  });

  group('通用 CRUD', () {
    test('收藏：insert + allFavorites（addedAt DESC）', () async {
      await dbm.insertFavorite(const Favorite(name: 'A', addedAt: 100));
      await dbm.insertFavorite(const Favorite(name: 'B', addedAt: 300));
      await dbm.insertFavorite(const Favorite(name: 'C', addedAt: 200));
      final List<Favorite> all = await dbm.allFavorites();
      expect(all.map((Favorite f) => f.name).toList(), <String>['B', 'C', 'A']);
      expect(all.first.id, isNotNull);
    });

    test('历史：allHistory 按 lastPlayedAt DESC 且受 limit 约束', () async {
      for (final int t in <int>[10, 30, 20]) {
        await dbm.insertHistory(History(name: 'h$t', lastPlayedAt: t));
      }
      final List<History> top2 = await dbm.allHistory(limit: 2);
      expect(top2.map((History h) => h.name).toList(), <String>['h30', 'h20']);
    });

    test('下载：insertDownload 的 v4 可空列读回 NULL', () async {
      await dbm.insertDownload(const Download(name: 'd1', addedAt: 5));
      final Download d = (await dbm.allDownloads()).single;
      expect(d.sourceType, isNull);
      expect(d.engineKey, isNull);
      expect(d.vodId, isNull);
      expect(d.headers, isNull);
    });

    test('搜索历史：recentSearches 降序 + limit + fromMap 保真', () async {
      for (final int t in <int>[1, 3, 2]) {
        await dbm.insertSearchHistory(SearchHistory(keyword: 'k$t', searchedAt: t));
      }
      final List<SearchHistory> r = await dbm.recentSearches(limit: 2);
      expect(r.map((SearchHistory s) => s.keyword).toList(), <String>['k3', 'k2']);
    });

    test('count 支持 where 过滤', () async {
      await dbm.insertFavorite(const Favorite(name: 'A', xianlu: 1, addedAt: 1));
      await dbm.insertFavorite(const Favorite(name: 'B', xianlu: 2, addedAt: 2));
      expect(await dbm.count('favorite'), 2);
      expect(await dbm.count('favorite', where: 'xianlu = ?', whereArgs: <Object?>[1]), 1);
    });

    test('update / delete 生效', () async {
      final int id = await dbm.insertFavorite(const Favorite(name: 'A', addedAt: 1));
      final int n = await dbm.update(
        'favorite',
        <String, Object?>{'name': 'A2'},
        where: 'id = ?',
        whereArgs: <Object?>[id],
      );
      expect(n, 1);
      expect((await dbm.allFavorites()).single.name, 'A2');

      await dbm.delete('favorite', where: 'id = ?', whereArgs: <Object?>[id]);
      expect(await dbm.count('favorite'), 0);
    });

    test('upsert 以 replace 语义覆盖（settings.key 主键）', () async {
      await dbm.upsert('settings',
          <String, Object?>{'key': 'k', 'value': 'v1', 'updatedAt': 1},
          primaryKey: 'key');
      await dbm.upsert('settings',
          <String, Object?>{'key': 'k', 'value': 'v2', 'updatedAt': 2},
          primaryKey: 'key');
      expect(await dbm.count('settings'), 1);
      final Map<String, Object?> row =
          (await dbm.queryAll('settings')).single;
      expect(row['value'], 'v2');
    });

    test('insert 冲突（abort）→ 抛 DatabaseException', () async {
      await dbm.insert('zhanyuan', <String, Object?>{
        'name': 'n',
        'searchUrl': 'u',
        'updatedAt': 1,
        'dyurl': 'y',
      });
      await expectLater(
        dbm.insert('zhanyuan', <String, Object?>{
          'name': 'n',
          'searchUrl': 'u2',
          'updatedAt': 2,
          'dyurl': 'y',
        }),
        throwsA(isA<DatabaseException>()),
      );
    });

    test('queryAll 支持 orderBy + limit', () async {
      for (final int t in <int>[1, 2, 3]) {
        await dbm.insertSearchHistory(SearchHistory(keyword: 'k$t', searchedAt: t));
      }
      final List<Map<String, Object?>> rows =
          await dbm.queryAll('search_history', orderBy: 'searchedAt DESC', limit: 1);
      expect(rows.single['keyword'], 'k3');
    });
  });
}