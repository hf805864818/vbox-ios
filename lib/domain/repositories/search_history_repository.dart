/// 领域层：搜索历史仓储契约。
///
/// 契约：`contract/schema/schema_v1.sql` 的 `search_history` 表。
library;

import '../../core/utils/result.dart';

/// 搜索历史仓储。
abstract interface class SearchHistoryRepository {
  /// 最近搜索关键词（按搜索时间倒序，去重保留最新）。
  Future<Result<List<String>>> recent({int limit = 20});

  /// 写入一条搜索历史，返回主键。
  Future<Result<int>> add(String keyword);

  /// 清空，返回删除条数。
  Future<Result<int>> clear();
}