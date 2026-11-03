/// 数据层：搜索历史仓储实现（SQLite）。
///
/// 契约：`contract/schema/schema_v1.sql` 的 `search_history` 表。
library;

import '../../core/errors/failures.dart';
import '../../core/utils/result.dart';
import '../../core/utils/time_utils.dart';
import '../../domain/repositories/search_history_repository.dart';
import '../datasources/local/database_manager.dart';
import '../models/models.dart';

/// 搜索历史仓储实现。
class SearchHistoryRepositoryImpl implements SearchHistoryRepository {
  /// 构造（[database] 便于单测注入）。
  SearchHistoryRepositoryImpl({DatabaseManager? database})
      : _db = database ?? DatabaseManager.instance;

  final DatabaseManager _db;

  static const String _table = SearchHistory.table;

  @override
  Future<Result<List<String>>> recent({int limit = 20}) async {
    try {
      final List<SearchHistory> rows = await _db.recentSearches(limit: limit);
      final List<String> seen = <String>[];
      final List<String> out = <String>[];
      for (final SearchHistory s in rows) {
        final String kw = s.keyword.trim();
        if (kw.isEmpty || seen.contains(kw)) continue;
        seen.add(kw);
        out.add(kw);
      }
      return Success<List<String>>(out);
    } catch (e) {
      return Err<List<String>>(Failure.from(e));
    }
  }

  @override
  Future<Result<int>> add(String keyword) async {
    try {
      final SearchHistory entry = SearchHistory(
        keyword: keyword.trim(),
        searchedAt: TimeUtils.nowUnixSeconds(),
      );
      return Success<int>(await _db.insertSearchHistory(entry));
    } catch (e) {
      return Err<int>(Failure.from(e));
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
}