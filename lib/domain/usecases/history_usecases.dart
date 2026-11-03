/// 领域层：播放历史用例。
///
/// 业务规则：
/// - 进度写库前钳制到 `[0,1]`（防越界脏数据）；
/// - `lastPlayedAt` 缺省取当前时间；
/// - 「继续观看」= 进度在 1%–95% 之间的记录，按最后播放时间倒序。
library;

import '../../core/errors/failures.dart';
import '../../core/utils/result.dart';
import '../../core/utils/string_utils.dart';
import '../../core/utils/time_utils.dart';
import '../entities/library/library.dart';
import '../repositories/history_repository.dart';

/// 播放历史用例。
class HistoryUseCases {
  /// 构造。
  const HistoryUseCases(this._repo);

  /// 默认列表条数。
  static const int defaultLimit = 20;

  final HistoryRepository _repo;

  /// 记录/更新播放进度。
  Future<Result<int>> record(HistoryItem item) async {
    if (StringUtils.isBlank(item.name)) {
      return const Err<int>(ValidationFailure('历史项缺少名称'));
    }
    if (StringUtils.isBlank(item.detailurl)) {
      return const Err<int>(ValidationFailure('历史项缺少详情地址'));
    }
    final HistoryItem normalized = item.copyWith(
      progress: item.clampedProgress,
      lastPlayedAt: item.lastPlayedAt > 0
          ? item.lastPlayedAt
          : TimeUtils.nowUnixSeconds(),
    );
    return _repo.upsert(normalized);
  }

  /// 最近播放（按最后播放时间倒序）。
  Future<Result<List<HistoryItem>>> recent({int limit = defaultLimit}) async {
    if (limit <= 0) {
      return const Err<List<HistoryItem>>(ValidationFailure('limit 必须为正'));
    }
    final Result<List<HistoryItem>> result = await _repo.list(limit: limit);
    final Failure? failure = result.failureOrNull;
    if (failure != null) return Err<List<HistoryItem>>(failure);
    final List<HistoryItem> items = <HistoryItem>[...?result.valueOrNull]
      ..sort((HistoryItem a, HistoryItem b) =>
          b.lastPlayedAt.compareTo(a.lastPlayedAt));
    return Success<List<HistoryItem>>(items);
  }

  /// 继续观看（可续播项，按最后播放时间倒序）。
  Future<Result<List<HistoryItem>>> resumable({
    int limit = defaultLimit,
  }) async {
    if (limit <= 0) {
      return const Err<List<HistoryItem>>(ValidationFailure('limit 必须为正'));
    }
    final Result<List<HistoryItem>> result = await _repo.list();
    final Failure? failure = result.failureOrNull;
    if (failure != null) return Err<List<HistoryItem>>(failure);
    final List<HistoryItem> items = <HistoryItem>[
      ...?result.valueOrNull,
    ].where((HistoryItem h) => h.isResumable).toList()
      ..sort((HistoryItem a, HistoryItem b) =>
          b.lastPlayedAt.compareTo(a.lastPlayedAt));
    return Success<List<HistoryItem>>(
      items.length > limit ? items.sublist(0, limit) : items,
    );
  }

  /// 按主键移除。
  Future<Result<bool>> remove(int id) async {
    if (id <= 0) return Err<bool>(ValidationFailure('主键非法：$id'));
    return _repo.remove(id);
  }

  /// 清空历史。
  Future<Result<int>> clear() => _repo.clear();

  /// 仅保留最新 [keep] 条。
  Future<Result<int>> trimTo(int keep) async {
    if (keep <= 0) {
      return Err<int>(ValidationFailure('保留条数必须为正：$keep'));
    }
    return _repo.trim(keep);
  }

  /// 历史总数。
  Future<Result<int>> count() => _repo.count();
}
