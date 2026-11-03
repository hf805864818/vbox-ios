/// 领域层：收藏仓储契约。
///
/// 实现位于数据层（`lib/data/repositories/favorite_repository_impl.dart`）；
/// 契约：`contract/schema/schema_v1.sql` 的 `favorite` 表。
library;

import '../../core/utils/result.dart';
import '../entities/library/library.dart';

/// 收藏仓储。
abstract interface class FavoriteRepository {
  /// 列表（按收藏时间倒序）。
  Future<Result<List<FavoriteItem>>> list({int? limit, int? offset});

  /// 按详情地址查（收藏去重依据）。
  Future<Result<FavoriteItem?>> findByDetailUrl(String detailurl);

  /// 按主键查。
  Future<Result<FavoriteItem?>> findById(int id);

  /// 新增，返回自增主键。
  Future<Result<int>> add(FavoriteItem item);

  /// 按主键删除。
  Future<Result<bool>> remove(int id);

  /// 清空，返回删除条数。
  Future<Result<int>> clear();

  /// 总数。
  Future<Result<int>> count();
}
