/// 数据层：订阅仓储实现（SQLite）。
///
/// 契约：`contract/schema/schema_v1.sql` 的 `subscription` 表。
/// ⚠️ DDL 真相：唯一约束为 **`dyurl UNIQUE`**（地址全局唯一）；
/// `findByUrl` 供用例层先按地址做友好判重，避免同址异名直撞 DB 约束。
///
/// 边界约定：内层异常统一用 [Failure.from] 归一，方法只返回 `Result`。
library;

import '../../core/errors/failures.dart';
import '../../core/utils/result.dart';
import '../../domain/entities/library/library.dart';
import '../../domain/repositories/subscription_repository.dart';
import '../datasources/local/database_manager.dart';

/// 订阅仓储实现。
class SubscriptionRepositoryImpl implements SubscriptionRepository {
  /// 构造（[database] 便于单测注入）。
  SubscriptionRepositoryImpl({DatabaseManager? database})
      : _db = database ?? DatabaseManager.instance;

  final DatabaseManager _db;

  static const String _table = SubscriptionItem.table;

  @override
  Future<Result<List<SubscriptionItem>>> list() async {
    try {
      final List<Map<String, Object?>> rows =
          await _db.queryAll(_table, orderBy: 'dyname ASC');
      return Success<List<SubscriptionItem>>(
        rows.map(SubscriptionItem.fromRow).toList(growable: false),
      );
    } catch (e) {
      return Err<List<SubscriptionItem>>(Failure.from(e));
    }
  }

  @override
  Future<Result<SubscriptionItem?>> findByUrl(String dyurl) async {
    try {
      final List<Map<String, Object?>> rows = await _db.queryAll(
        _table,
        where: 'dyurl = ?',
        whereArgs: <Object?>[dyurl],
        limit: 1,
      );
      return Success<SubscriptionItem?>(
        rows.isEmpty ? null : SubscriptionItem.fromRow(rows.first),
      );
    } catch (e) {
      return Err<SubscriptionItem?>(Failure.from(e));
    }
  }

  @override
  Future<Result<SubscriptionItem?>> findById(int id) async {
    try {
      final List<Map<String, Object?>> rows = await _db.queryAll(
        _table,
        where: 'id = ?',
        whereArgs: <Object?>[id],
        limit: 1,
      );
      return Success<SubscriptionItem?>(
        rows.isEmpty ? null : SubscriptionItem.fromRow(rows.first),
      );
    } catch (e) {
      return Err<SubscriptionItem?>(Failure.from(e));
    }
  }

  @override
  Future<Result<int>> add(SubscriptionItem item) async {
    try {
      return Success<int>(await _db.insert(_table, item.toRow()));
    } catch (e) {
      return Err<int>(Failure.from(e));
    }
  }

  @override
  Future<Result<bool>> remove(int id) async {
    try {
      final int deleted = await _db.delete(
        _table,
        where: 'id = ?',
        whereArgs: <Object?>[id],
      );
      return Success<bool>(deleted > 0);
    } catch (e) {
      return Err<bool>(Failure.from(e));
    }
  }

  @override
  Future<Result<bool>> touchSync(int id, int atSeconds) async {
    try {
      final int updated = await _db.update(
        _table,
        <String, Object?>{'lastSyncAt': atSeconds},
        where: 'id = ?',
        whereArgs: <Object?>[id],
      );
      return Success<bool>(updated > 0);
    } catch (e) {
      return Err<bool>(Failure.from(e));
    }
  }
}