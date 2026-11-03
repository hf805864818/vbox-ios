/// 契约层单测：`schema.dart`（DDL 移植）与迁移链。
///
/// 两层验证：
///   1. 结构断言：与 `contract/schema/schema_v1.sql`（唯一真相源）对齐；
///   2. **真机行为**：用 `sqflite_common_ffi` 内存库实跑完整迁移链，
///      验证 9 表 / v2 唯一约束 / v4 可空列（旧数据 NULL 容忍）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:vbox/contract/schema/schema.dart';

Set<String> _ddlTableNames() {
  final File f = File('contract/schema/schema_v1.sql');
  expect(f.existsSync(), isTrue, reason: 'DDL 不存在: ${f.path}');
  return RegExp(r'CREATE TABLE IF NOT EXISTS (\w+)')
      .allMatches(f.readAsStringSync())
      .map((RegExpMatch m) => m.group(1)!)
      .toSet();
}

void main() {
  setUpAll(sqfliteFfiInit);

  group('结构断言（对照 DDL 真相源）', () {
    test('kSchemaVersion = 4', () => expect(kSchemaVersion, 4));

    test('9 张表名与 DDL 一致', () {
      expect(kAllTables.toSet(), _ddlTableNames());
      expect(kAllTables.length, 9);
      expect(kAllTables.toSet().length, 9, reason: '表名重复');
    });

    test('migrationFor 覆盖 1..kSchemaVersion，越界抛 ArgumentError', () {
      for (int v = 1; v <= kSchemaVersion; v++) {
        expect(migrationFor(v), isNotEmpty, reason: 'v$v');
      }
      expect(() => migrationFor(0), throwsArgumentError);
      expect(() => migrationFor(kSchemaVersion + 1), throwsArgumentError);
    });

    test('fullMigrationChain == 各版本语句串联', () {
      final List<String> expected = <String>[
        for (int v = 1; v <= kSchemaVersion; v++) ...migrationFor(v),
      ];
      expect(fullMigrationChain(), expected);
    });

    test('v4 可空列清单与 v4 迁移语句一致', () {
      expect(kDownloadV4NullableColumns,
          <String>['sourceType', 'engineKey', 'vodId', 'headers']);
      final String v4 = migrationFor(4).join('\n');
      for (final String c in kDownloadV4NullableColumns) {
        expect(v4, contains('ADD COLUMN $c'),
            reason: 'v4 迁移应含 $c（可空，无 NOT NULL）');
      }
      expect(v4.contains('NOT NULL'), isFalse,
          reason: 'v4 新增列必须可空（旧行这些列为 NULL）');
    });
  });

  group('真机行为（内存 SQLite 实跑迁移链）', () {
    late Database db;

    setUp(() async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      for (final String stmt in fullMigrationChain()) {
        await db.execute(stmt);
      }
    });

    tearDown(() => db.close());

    test('迁移链后恰好 9 张业务表', () async {
      final List<Map<String, Object?>> rows = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name NOT LIKE 'sqlite_%' ORDER BY name",
      );
      final Set<String> names =
          rows.map((Map<String, Object?> r) => r['name']! as String).toSet();
      expect(names, kAllTables.toSet());
    });

    test('v3 三个降序索引存在', () async {
      final List<Map<String, Object?>> rows = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='index' AND name LIKE 'idx_%'",
      );
      final Set<String> idx =
          rows.map((Map<String, Object?> r) => r['name']! as String).toSet();
      expect(idx, <String>{
        'idx_search_history_time',
        'idx_history_time',
        'idx_favorite_time',
      });
    });

    test('v2：zhanyuan 唯一约束为 (name, dyurl)', () async {
      final List<Map<String, Object?>> r = await db.rawQuery(
        "SELECT sql FROM sqlite_master WHERE type='table' AND name='zhanyuan'",
      );
      expect((r.first['sql']! as String).replaceAll(RegExp(r'\s+'), ' '),
          contains('UNIQUE(name, dyurl)'));

      Future<int> ins(String name, String dyurl) => db.insert('zhanyuan', <String, Object?>{
            'name': name,
            'searchUrl': 'https://x',
            'updatedAt': 1,
            'dyurl': dyurl,
          });

      // 同 name 不同 dyurl → 允许（v2 的核心动机）
      await ins('站点A', 'sub1');
      await ins('站点A', 'sub2');
      expect(await db.query('zhanyuan'), hasLength(2));
      // 同 (name, dyurl) → 冲突
      await expectLater(ins('站点A', 'sub1'), throwsA(isA<DatabaseException>()));
    });

    test('v4：download 4 个可空列可缺省写入并读回 NULL', () async {
      // 模拟旧版本写入（不含 v4 列）
      final int id = await db.insert('download', <String, Object?>{
        'name': 'old.mp4',
        'addedAt': 1,
      });
      final Map<String, Object?> row =
          (await db.query('download', where: 'id = ?', whereArgs: <Object?>[id]))
              .single;
      for (final String c in kDownloadV4NullableColumns) {
        expect(row.containsKey(c), isTrue, reason: '$c 列应存在');
        expect(row[c], isNull, reason: '$c 旧数据应为 NULL');
      }
      // DDL 默认值生效
      expect(row['status'], 'pending');
      expect(row['progress'], 0.0);
      expect(row['jishu'], 0);
    });

    test('v1 建表语句：9 条 CREATE TABLE，且 zhanyuan 为 UNIQUE(name)', () {
      // v1 是「从零建库」的起点，其 zhanyuan 仅按 name 唯一；
      // v2 才改判为 UNIQUE(name, dyurl)——两条语句都需可独立执行。
      final List<String> v1 = migrationFor(1);
      final int creates = v1
          .where((String s) => s.trimLeft().toUpperCase().startsWith('CREATE TABLE'))
          .length;
      expect(creates, 9);

      final String zhanyuan =
          v1.firstWhere((String s) => s.contains('CREATE TABLE zhanyuan'));
      final String flat = zhanyuan.replaceAll(RegExp(r'\s+'), ' ');
      expect(flat, contains('UNIQUE(name)'));
      expect(flat, isNot(contains('UNIQUE(name, dyurl)')));
    });
  });
}