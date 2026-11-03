/// 数据层：本地设置键值存储（SQLite `settings` 表）。
///
/// 唯一真相源：iOS `DatabaseManager.getSetting(key:)` / `setSetting(key:value:)`
/// （表结构见 `contract/schema/schema_v1.sql` L78-L83：
/// `settings(key TEXT PRIMARY KEY, value TEXT, updatedAt INTEGER)`，时间字段 Unix 秒）。
///
/// 用途（批次 I · I-02）：承载 iOS 本地账号体系的落盘键 ——
/// `account` / `username` / `isLoggedIn` / `password_<账号>`，
/// 与 iOS `ProfileView.swift` L1072-L1125（`isRegistered` / `performLogin` /
/// `loginSuccess` / `performLogout`）完全一致：**纯本地账号，无服务端**。
///
/// 与 [PrefsManager] 的分工：契约键走 `SharedPreferences`（对齐 iOS `UserDefaults`）；
/// 本表是 SQLite 侧的通用 KV（对齐 iOS `settings` 表），账号态属后者。
library;

import 'dart:async';

import '../../models/models.dart';
import 'database_manager.dart';

/// 设置键值存储契约（便于单测注入内存实现）。
abstract class SettingsStore {
  /// 读取（不存在返回 `null`）。
  Future<String?> get(String key);

  /// 写入（存在则覆盖）。
  Future<void> set(String key, String value);

  /// 删除。
  Future<void> remove(String key);
}

/// SQLite `settings` 表实现（对齐 iOS `DatabaseManager` 的 KV 接口）。
class DatabaseSettingsStore implements SettingsStore {
  /// 构造（可注入 [DatabaseManager] 以隔离单测）。
  DatabaseSettingsStore({DatabaseManager? database})
      : _db = database ?? DatabaseManager.instance;

  final DatabaseManager _db;

  @override
  Future<String?> get(String key) async {
    final List<Map<String, Object?>> rows = await _db.queryAll(
      Setting.table,
      where: 'key = ?',
      whereArgs: <Object?>[key],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Setting.fromMap(rows.first).value;
  }

  @override
  Future<void> set(String key, String value) async {
    await _db.upsert(
      Setting.table,
      Setting(
        key: key,
        value: value,
        updatedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      ).toMap(),
      primaryKey: 'key',
    );
  }

  @override
  Future<void> remove(String key) async {
    await _db.delete(
      Setting.table,
      where: 'key = ?',
      whereArgs: <Object?>[key],
    );
  }
}