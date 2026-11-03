/// 数据层：播放历史仓储实现（SQLite）。
///
/// 契约：`contract/schema/schema_v1.sql` 的 `history` 表。
/// 去重键为 `detailurl`（`upsert` 命中即更新，未命中即插入）。
///
/// 边界约定：内层异常统一用 [Failure.from] 归一，方法只返回 `Result`。
library;

import '../../core/errors/failures.dart';
import '../../core/utils/result.dart';
import '../../domain/entities/library/library.dart';
import '../../domain/repositories/history_repository.dart';
import '../datasources/local/database_manager.dart';

/// 播放历史仓储实现。
class HistoryRepositoryImpl implements HistoryRepository {
  /// 构造（[database] 便于单测注入）。
  HistoryRepositoryImpl({DatabaseManager? database})
      : _db = database ?? DatabaseManager.instance;

  final DatabaseManager _db;

  static const String _table = HistoryItem.table;

  /// 去重键列名（与契约 `history.detailurl` 对齐）。
  static const String dedupColumn = 'detailurl';

  @override
  Future<Result<List<HistoryItem>>> list({int? limit}) async {
    try {
      final List<Map<String, Object?>> rows = await _db.queryAll(
        _table,
        orderBy: 'lastPlayedAt DESC',
        limit: limit,
      );
      return Success<List<HistoryItem>>(
        rows.map(HistoryItem.fromRow).toList(growable: false),
      );
    } catch (e) {
      return Err<List<HistoryItem>>(Failure.from(e));
    }
  }

  @override
  Future<Result<HistoryItem?>> findByDetailUrl(String detailurl) async {
    try {
      return Success<HistoryItem?>(await _findByDetailUrl(detailurl));
    } catch (e) {
      return Err<HistoryItem?>(Failure.from(e));
    }
  }

  @override
  Future<Result<int>> upsert(HistoryItem item) async {
    try {
      final HistoryItem? existing = await _findByDetailUrl(item.detailurl);
      if (existing != null) {
        final int id = existing.id!;
        final Map<String, Object?> values = item.toRow()..remove('id');
        await _db.update(
          _table,
          values,
          where: 'id = ?',
          whereArgs: <Object?>[id],
        );
        return Success<int>(id);
      }
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
  Future<Result<int>> trim(int keep) async {
    try {
      final int deleted = await _db.delete(
        _table,
        where:
            'id NOT IN (SELECT id FROM $_table ORDER BY lastPlayedAt DESC LIMIT ?)',
        whereArgs: <Object?>[keep],
      );
      return Success<int>(deleted);
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

  Future<HistoryItem?> _findByDetailUrl(String detailurl) async {
    final List<Map<String, Object?>> rows = await _db.queryAll(
      _table,
      where: '$dedupColumn = ?',
      whereArgs: <Object?>[detailurl],
      limit: 1,
    );
    return rows.isEmpty ? null : HistoryItem.fromRow(rows.first);
  }
}