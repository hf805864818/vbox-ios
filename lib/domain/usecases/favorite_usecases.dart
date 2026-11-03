/// 领域层：收藏用例。
///
/// 职责：入参校验 + 业务规则（按详情地址去重、切换收藏），
/// 数据访问全部委托 [FavoriteRepository]；返回值统一为 `Result`。
library;

import '../../core/errors/failures.dart';
import '../../core/utils/result.dart';
import '../../core/utils/string_utils.dart';
import '../entities/library/library.dart';
import '../repositories/favorite_repository.dart';

/// 收藏用例。
class FavoriteUseCases {
  /// 构造（注入仓储实现）。
  const FavoriteUseCases(this._repo);

  final FavoriteRepository _repo;

  /// 收藏列表。
  Future<Result<List<FavoriteItem>>> list({int? limit, int? offset}) =>
      _repo.list(limit: limit, offset: offset);

  /// 收藏总数。
  Future<Result<int>> count() => _repo.count();

  /// 是否已收藏（按详情地址判定）。
  Future<Result<bool>> isFavorite(String detailurl) async {
    if (StringUtils.isBlank(detailurl)) {
      return const Err<bool>(ValidationFailure('详情地址为空'));
    }
    final Result<FavoriteItem?> found = await _repo.findByDetailUrl(detailurl);
    final Failure? failure = found.failureOrNull;
    if (failure != null) return Err<bool>(failure);
    return Success<bool>(found.valueOrNull != null);
  }

  /// 切换收藏：未收藏则新增，已收藏则移除。
  ///
  /// 返回**切换后的收藏状态**（true = 现在已收藏）。
  Future<Result<bool>> toggle(FavoriteItem item) async {
    final String? invalid = _validate(item);
    if (invalid != null) return Err<bool>(ValidationFailure(invalid));

    final Result<FavoriteItem?> found =
        await _repo.findByDetailUrl(item.detailurl);
    final Failure? failure = found.failureOrNull;
    if (failure != null) return Err<bool>(failure);

    final FavoriteItem? existing = found.valueOrNull;
    if (existing == null) {
      final Result<int> added = await _repo.add(item);
      final Failure? addFailure = added.failureOrNull;
      if (addFailure != null) return Err<bool>(addFailure);
      return const Success<bool>(true);
    }

    final int? id = existing.id;
    if (id == null) {
      return const Err<bool>(ValidationFailure('收藏项缺少主键，无法取消收藏'));
    }
    final Result<bool> removed = await _repo.remove(id);
    final Failure? removeFailure = removed.failureOrNull;
    if (removeFailure != null) return Err<bool>(removeFailure);
    return const Success<bool>(false);
  }

  /// 按主键移除。
  Future<Result<bool>> remove(int id) async {
    if (id <= 0) return Err<bool>(ValidationFailure('主键非法：$id'));
    return _repo.remove(id);
  }

  /// 清空收藏，返回删除条数。
  Future<Result<int>> clear() => _repo.clear();

  static String? _validate(FavoriteItem item) {
    if (StringUtils.isBlank(item.name)) return '收藏项缺少名称';
    if (StringUtils.isBlank(item.detailurl)) return '收藏项缺少详情地址';
    return null;
  }
}
