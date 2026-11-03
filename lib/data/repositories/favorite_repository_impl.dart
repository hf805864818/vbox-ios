/// 数据层：收藏仓储实现（SQLite）。
///
/// 契约：`contract/schema/schema_v1.sql` 的 `favorite` 表。
/// 行 ↔ 实体由 [FavoriteItem.fromRow] / [FavoriteItem.toRow] 负责（列名逐位对齐）。
///
/// 边界约定：内层异常统一用 [Failure.from] 归一，方法只返回 `Result`，不向领域层抛异常。
library;

import '../../core/errors/failures.dart';
import '../../core/utils/result.dart';
import '../../domain/entities/library/library.dart';
import '../../domain/repositories/favorite_repository.dart';
import '../datasources/local/database_manager.dart';

/// 收藏仓储实现。
class FavoriteRepositoryImpl implements FavoriteRepository {
  /// 构造（[database] 便于单测注入）。
  FavoriteRepositoryImpl({DatabaseManager? database})
      : _db = database ?? DatabaseManager.instance;

  final DatabaseManager _db;

  static const String _table = FavoriteItem.table;

  @override
  Future<Result<List<FavoriteItem>>> list({int? limit, int? offset}) async {
    try {
      final List<Map<String, Object?>> rows = await _db.queryAll(
        _table,
        orderBy: 'addedAt DESC',
        limit: limit,
        offset: offset,
      );
      return Success<List<FavoriteItem>>(
        rows.map(FavoriteItem.fromRow).toList(growable: false),
      );
    } catch (e) {
      return Err<List<FavoriteItem>>(Failure.from(e));
    }
  }

  @override
  Future<Result<FavoriteItem?>> findByDetailUrl(String detailurl) async {
    try {
      final List<Map<String, Object?>> rows = await _db.queryAll(
        _table,
        where: 'detailurl = ?',
        whereArgs: <Object?>[detailurl],
        limit: 1,
      );
      return Success<FavoriteItem?>(
        rows.isEmpty ? null : FavoriteItem.fromRow(rows.first),
      );
    } catch (e) {
      return Err<FavoriteItem?>(Failure.from(e));
    }
  }

  @override
  Future<Result<FavoriteItem?>> findById(int id) async {
    try {
      final List<Map<String, Object?>> rows = await _db.queryAll(
        _table,
        where: 'id = ?',
        whereArgs: <Object?>[id],
        limit: 1,
      );
      return Success<FavoriteItem?>(
        rows.isEmpty ? null : FavoriteItem.fromRow(rows.first),
      );
    } catch (e) {
      return Err<FavoriteItem?>(Failure.from(e));
    }
  }

  @override
  Future<Result<int>> add(FavoriteItem item) async {
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
  Future<Result<int>> clear() async {
    try {
      return Success<int>(await _db.delete(
        _table,
        where: '1 = 1',
        whereArgs: const <Object?>[],
      ));
    } catch (e) {
      return Err<int>(Failure.from(e));
    }
  }

  @override
  Future<Result<int>> count() async {
    try {
      return Success<int>(await _db.count(_table));
    } catch (e) {
      return Err<int>(Failure.from(e));
    }
  }
}