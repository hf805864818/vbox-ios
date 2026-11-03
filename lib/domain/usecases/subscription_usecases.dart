/// 领域层：订阅用例。
///
/// 业务规则：
/// - 唯一键为 `dyurl`（契约 `subscription.dyurl UNIQUE`，地址全局唯一），重复订阅直接拒绝；
/// - 「到期同步」由调用方传入当前 Unix 秒（便于单测与时钟注入）。
library;

import '../../core/errors/failures.dart';
import '../../core/utils/result.dart';
import '../../core/utils/string_utils.dart';
import '../entities/library/library.dart';
import '../repositories/subscription_repository.dart';

/// 订阅用例。
class SubscriptionUseCases {
  /// 构造。
  const SubscriptionUseCases(
    this._repo, {
    this.syncIntervalSeconds = defaultSyncIntervalSeconds,
  });

  /// 默认同步间隔（6 小时，对齐 iOS 订阅检查节奏）。
  static const int defaultSyncIntervalSeconds = 6 * 3600;

  final SubscriptionRepository _repo;

  /// 同步间隔（秒）。
  final int syncIntervalSeconds;

  /// 订阅列表（按名称排序）。
  Future<Result<List<SubscriptionItem>>> list() async {
    final Result<List<SubscriptionItem>> result = await _repo.list();
    final Failure? failure = result.failureOrNull;
    if (failure != null) return Err<List<SubscriptionItem>>(failure);
    final List<SubscriptionItem> items = <SubscriptionItem>[
      ...?result.valueOrNull,
    ]..sort((SubscriptionItem a, SubscriptionItem b) =>
        a.dyname.compareTo(b.dyname));
    return Success<List<SubscriptionItem>>(items);
  }

  /// 新增订阅（地址重复则拒绝，与 DDL 唯一约束一致）。
  Future<Result<int>> add(SubscriptionItem item) async {
    if (StringUtils.isBlank(item.dyname)) {
      return const Err<int>(ValidationFailure('订阅缺少名称'));
    }
    if (StringUtils.isBlank(item.dyurl)) {
      return const Err<int>(ValidationFailure('订阅缺少地址'));
    }
    final Result<SubscriptionItem?> existing = await _repo.findByUrl(item.dyurl);
    final Failure? failure = existing.failureOrNull;
    if (failure != null) return Err<int>(failure);
    if (existing.valueOrNull != null) {
      return const Err<int>(ValidationFailure('订阅已存在（地址重复）'));
    }
    return _repo.add(item);
  }

  /// 删除订阅。
  Future<Result<bool>> remove(int id) async {
    if (id <= 0) return Err<bool>(ValidationFailure('主键非法：$id'));
    return _repo.remove(id);
  }

  /// 到期需同步的订阅（从未同步的视为到期），按最后同步时间升序。
  Future<Result<List<SubscriptionItem>>> dueForSync(int nowSeconds) async {
    final Result<List<SubscriptionItem>> result = await _repo.list();
    final Failure? failure = result.failureOrNull;
    if (failure != null) return Err<List<SubscriptionItem>>(failure);
    final List<SubscriptionItem> items = <SubscriptionItem>[
      ...?result.valueOrNull,
    ].where((SubscriptionItem s) => s.isDue(nowSeconds, syncIntervalSeconds)).toList()
      ..sort((SubscriptionItem a, SubscriptionItem b) =>
          a.lastSyncAt.compareTo(b.lastSyncAt));
    return Success<List<SubscriptionItem>>(items);
  }

  /// 标记已同步。
  Future<Result<bool>> markSynced(int id, int atSeconds) async {
    if (id <= 0) return Err<bool>(ValidationFailure('主键非法：$id'));
    if (atSeconds <= 0) {
      return Err<bool>(ValidationFailure('同步时间非法：$atSeconds'));
    }
    return _repo.touchSync(id, atSeconds);
  }
}
