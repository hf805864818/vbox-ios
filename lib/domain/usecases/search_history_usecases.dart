/// 领域层：搜索历史用例。
///
/// 业务规则：关键词去空白、去空；读取时去重并保留最近一次出现。
library;

import '../../core/errors/failures.dart';
import '../../core/utils/result.dart';
import '../repositories/search_history_repository.dart';

/// 搜索历史用例。
class SearchHistoryUseCases {
  /// 构造。
  const SearchHistoryUseCases(this._repo);

  final SearchHistoryRepository _repo;

  /// 最近搜索（去重、按时间倒序）。
  Future<Result<List<String>>> recent({int limit = 20}) => _repo.recent(limit: limit);

  /// 记录一条搜索历史（空关键词拒绝）。
  Future<Result<int>> add(String keyword) {
    if (keyword.trim().isEmpty) {
      return Future<Result<int>>.value(
        const Err<int>(ValidationFailure('搜索关键词为空')),
      );
    }
    return _repo.add(keyword.trim());
  }

  /// 清空搜索历史。
  Future<Result<int>> clear() => _repo.clear();
}