/// 领域层：播放历史仓储契约。
///
/// 契约：`contract/schema/schema_v1.sql` 的 `history` 表。
library;

import '../../core/utils/result.dart';
import '../entities/library/library.dart';

/// 播放历史仓储。
abstract interface class HistoryRepository {
  /// 列表（按最后播放时间倒序）。
  Future<Result<List<HistoryItem>>> list({int? limit});

  /// 按详情地址查（历史去重依据）。
  Future<Result<HistoryItem?>> findByDetailUrl(String detailurl);

  /// 写入或更新（去重键 `detailurl`），返回主键。
  Future<Result<int>> upsert(HistoryItem item);

  /// 按主键删除。
  Future<Result<bool>> remove(int id);

  /// 清空，返回删除条数。
  Future<Result<int>> clear();

  /// 仅保留最新 [keep] 条，返回删除条数。
  Future<Result<int>> trim(int keep);

  /// 总数。
  Future<Result<int>> count();
}
