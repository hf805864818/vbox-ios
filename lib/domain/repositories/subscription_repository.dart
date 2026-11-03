/// 领域层：订阅仓储契约。
///
/// 契约：`contract/schema/schema_v1.sql` 的 `subscription` 表
/// （唯一约束为 **`dyurl UNIQUE`**，即地址全局唯一，故按「地址」判重）。
library;

import '../../core/utils/result.dart';
import '../entities/library/library.dart';

/// 订阅仓储。
abstract interface class SubscriptionRepository {
  /// 列表（按名称排序）。
  Future<Result<List<SubscriptionItem>>> list();

  /// 按唯一键查（`dyurl`，地址全局唯一）。
  Future<Result<SubscriptionItem?>> findByUrl(String dyurl);

  /// 按主键查。
  Future<Result<SubscriptionItem?>> findById(int id);

  /// 新增，返回自增主键。
  Future<Result<int>> add(SubscriptionItem item);

  /// 按主键删除。
  Future<Result<bool>> remove(int id);

  /// 更新最后同步时间。
  Future<Result<bool>> touchSync(int id, int atSeconds);
}
