/// 数据层：数据库管理器（建库 / 迁移 / CRUD）。
///
/// 唯一真相源：`contract/schema/schema_v1.sql` + iOS `vbox/Services/DatabaseManager.swift`
///
/// 与 iOS 端对齐的要点：
/// - 文件名：`vbox.sqlite3`
/// - 迁移链名与顺序：v1_createTables → v2_add_dyurl → v3_add_download → v4_add_download_columns
/// - v2 采用「重建表」方式（CREATE _v2 → INSERT → DROP → RENAME），与 iOS 完全一致
/// - 时间字段为 Unix 秒；布尔存 0/1
library;

import 'dart:io';

import 'package:sqflite/sqflite.dart';

import '../../../contract/schema/schema.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/storage/storage_paths.dart';
import '../../models/models.dart';

class DatabaseManager {
  DatabaseManager._();

  static final DatabaseManager instance = DatabaseManager._();

  static Database? _db;

  /// 数据库文件名（与 iOS 端一致；唯一真相源为 [DbConstants.fileName]）。
  static const String dbFileName = DbConstants.fileName;

  /// 迁移链名称（与 iOS `registerMigration` 一致，供审计用）。
  static const List<String> migrationNames = <String>[
    'v1_createTables',
    'v2_add_dyurl',
    'v3_add_download',
    'v4_add_download_columns',
  ];

  Future<Database> get database async => _db ??= await _open();

  Future<Database> _open() async {
    // 单一真相源：数据库路径统一由核心层 [StoragePaths] 提供，
    // 不再使用 sqflite `getDatabasesPath()`，消除桌面 FFI 下的双真相源分叉。
    final String path = StoragePaths.databaseFile;
    await Directory(StoragePaths.dbDir).create(recursive: true);
    return openDatabase(
      path,
      version: kSchemaVersion,
      onConfigure: (Database db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: (Database db, int version) async {
        for (int v = 1; v <= kSchemaVersion; v++) {
          await _applyMigration(db, v);
        }
      },
      onUpgrade: (Database db, int oldVersion, int newVersion) async {
        for (int v = oldVersion + 1; v <= newVersion; v++) {
          await _applyMigration(db, v);
        }
      },
      onDowngrade: onDatabaseDowngradeDelete,
    );
  }

  /// 应用单个版本的迁移（对应 iOS 的一个 registerMigration）。
  Future<void> _applyMigration(Database db, int version) async {
    for (final String stmt in migrationFor(version)) {
      await db.execute(stmt);
    }
  }

  /// 关闭数据库（测试/退出用）。
  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  // ─────────────────────────────────────────────────────────
  // 通用 CRUD
  // ─────────────────────────────────────────────────────────

  Future<int> insert(String table, Map<String, Object?> values) async {
    final Database db = await database;
    return db.insert(table, values,
        conflictAlgorithm: ConflictAlgorithm.abort);
  }

  Future<int> upsert(String table, Map<String, Object?> values,
      {required String primaryKey}) async {
    final Database db = await database;
    return db.insert(table, values,
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Map<String, Object?>>> queryAll(
    String table, {
    String? orderBy,
    int? limit,
    int? offset,
    String? where,
    List<Object?>? whereArgs,
  }) async {
    final Database db = await database;
    return db.query(
      table,
      orderBy: orderBy,
      limit: limit,
      offset: offset,
      where: where,
      whereArgs: whereArgs,
    );
  }

  Future<int> update(String table, Map<String, Object?> values,
      {required String where, required List<Object?> whereArgs}) async {
    final Database db = await database;
    return db.update(table, values, where: where, whereArgs: whereArgs);
  }

  Future<int> delete(String table,
      {required String where, required List<Object?> whereArgs}) async {
    final Database db = await database;
    return db.delete(table, where: where, whereArgs: whereArgs);
  }

  Future<int> count(String table, {String? where, List<Object?>? whereArgs}) async {
    final Database db = await database;
    final List<Map<String, Object?>> r = await db.rawQuery(
        'SELECT COUNT(*) AS c FROM $table'
        '${where != null ? ' WHERE $where' : ''}',
        whereArgs);
    return (r.first['c'] as int?) ?? 0;
  }

  // ─────────────────────────────────────────────────────────
  // 各表便捷方法（示例：类型安全入口）
  // ─────────────────────────────────────────────────────────

  Future<int> insertFavorite(Favorite f) => insert(Favorite.table, f.toMap());

  Future<List<Favorite>> allFavorites() async {
    final rows = await queryAll(Favorite.table, orderBy: 'addedAt DESC');
    return rows.map(Favorite.fromMap).toList();
  }

  Future<int> insertHistory(History h) => insert(History.table, h.toMap());

  Future<List<History>> allHistory({int limit = 100}) async {
    final rows =
        await queryAll(History.table, orderBy: 'lastPlayedAt DESC', limit: limit);
    return rows.map(History.fromMap).toList();
  }

  Future<int> insertDownload(Download d) => insert(Download.table, d.toMap());

  Future<List<Download>> allDownloads() async {
    final rows = await queryAll(Download.table, orderBy: 'addedAt DESC');
    return rows.map(Download.fromMap).toList();
  }

  /// 更新下载进度（对齐 iOS `updateDownloadProgress`；下载中逐条写回）。
  Future<void> updateDownloadProgress(
    int id,
    double progress,
    int downloadedSize,
    String status,
  ) async {
    await update(
      Download.table,
      <String, Object?>{
        'progress': progress,
        'downloadedSize': downloadedSize,
        'status': status,
      },
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  /// 更新下载完成路径（对齐 iOS `updateDownloadPath`；进度收敛为 1.0）。
  Future<void> updateDownloadPath(
    int id,
    String path,
    int fileSize,
    String status,
  ) async {
    await update(
      Download.table,
      <String, Object?>{
        'filePath': path,
        'fileSize': fileSize,
        'status': status,
        'progress': 1.0,
      },
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  /// 更新下载状态（对齐 iOS `updateDownloadStatus`）。
  Future<void> updateDownloadStatus(int id, String status) async {
    await update(
      Download.table,
      <String, Object?>{'status': status},
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  /// 删除下载记录（对齐 iOS `deleteDownload`）。
  Future<void> deleteDownload(int id) async {
    await delete(Download.table, where: 'id = ?', whereArgs: <Object?>[id]);
  }

  /// 清空下载表（对齐 iOS `clearDownloads`）。
  Future<void> clearDownloads() async {
    final Database db = await database;
    await db.delete(Download.table);
  }

  Future<int> insertSearchHistory(SearchHistory s) =>
      insert(SearchHistory.table, s.toMap());

  /// 最近 N 条搜索关键词（走 v3 建的降序索引）。
  Future<List<SearchHistory>> recentSearches({int limit = 20}) async {
    final rows = await queryAll(SearchHistory.table,
        orderBy: 'searchedAt DESC', limit: limit);
    return rows.map(SearchHistory.fromMap).toList();
  }
}
