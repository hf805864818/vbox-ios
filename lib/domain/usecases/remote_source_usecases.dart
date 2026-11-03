/// 领域层：远程源用例。
///
/// 业务规则（对齐 iOS `RemoteSourceConfigManager`）：
/// - 非强制刷新时，先按 `ttlSeconds` 判定是否需要刷新；不需要则直接用缓存；
/// - 拉取成功后落盘缓存（落盘失败不阻断本次返回）；
/// - 时间由调用方注入，便于单测。
library;

import '../../core/errors/failures.dart';
import '../../core/utils/result.dart';
import '../../core/utils/time_utils.dart';
import '../entities/remote_source/remote_source.dart';
import '../repositories/remote_source_repository.dart';

/// 远程源用例。
class RemoteSourceUseCases {
  /// 构造。
  const RemoteSourceUseCases(this._repo);

  final RemoteSourceRepository _repo;

  /// 读取缓存清单。
  Future<Result<RemoteManifest?>> cached() => _repo.cachedManifest();

  /// 是否需要刷新。
  Future<Result<bool>> needsRefresh({int? nowSeconds}) =>
      _repo.needsRefresh(nowSeconds ?? TimeUtils.nowUnixSeconds());

  /// 获取清单。
  ///
  /// [forceRefresh] 为 true 时跳过 TTL 与缓存，直接拉取。
  Future<Result<RemoteManifest>> refresh({
    bool forceRefresh = false,
    int? nowSeconds,
  }) async {
    final int now = nowSeconds ?? TimeUtils.nowUnixSeconds();

    if (!forceRefresh) {
      final Result<bool> need = await _repo.needsRefresh(now);
      final Failure? needFailure = need.failureOrNull;
      if (needFailure != null) return Err<RemoteManifest>(needFailure);

      if (need.valueOrNull == false) {
        final Result<RemoteManifest?> cachedResult = await _repo.cachedManifest();
        final Failure? cacheFailure = cachedResult.failureOrNull;
        if (cacheFailure != null) return Err<RemoteManifest>(cacheFailure);
        final RemoteManifest? cached = cachedResult.valueOrNull;
        if (cached != null) {
          return Success<RemoteManifest>(cached);
        }
      }
    }

    final Result<RemoteManifest> fetched =
        await _repo.fetchManifest(forceRefresh: forceRefresh);
    final Failure? fetchFailure = fetched.failureOrNull;
    if (fetchFailure != null) return Err<RemoteManifest>(fetchFailure);

    final RemoteManifest? manifest = fetched.valueOrNull;
    if (manifest == null) {
      return const Err<RemoteManifest>(UnknownFailure('清单为空'));
    }
    // 缓存落盘失败不影响本次结果（下次仍可重试），故忽略其返回值
    await _repo.saveManifest(manifest);
    return Success<RemoteManifest>(manifest);
  }

  /// 当前加载状态（供 UI 展示）。
  Future<RemoteLoadStatus> status({int? nowSeconds}) async {
    final Result<RemoteManifest?> cachedResult = await _repo.cachedManifest();
    final RemoteManifest? cached = cachedResult.valueOrNull;
    if (cached == null) return const RemoteLoadStatus.idle();
    if (!cached.hasRequiredFiles) {
      return const RemoteLoadStatus.failed('缓存清单缺少必需文件条目');
    }
    return RemoteLoadStatus.loadedCache(cached.configVersion);
  }

  /// 缓存写入时间（Unix 秒）。
  Future<Result<int>> cachedAt() => _repo.cachedAtSeconds();

  /// 读取远程源设置（开关 / manifest 地址 / 上次版本 / 上次同步时间）。
  Future<Result<RemoteSourceSettings>> settings() => _repo.settings();

  /// 写入「启用远程默认源」开关。
  Future<Result<bool>> setEnabled(bool enabled) => _repo.setEnabled(enabled);

  /// 写入 manifest 地址。
  Future<Result<bool>> setManifestUrl(String url) => _repo.setManifestUrl(url);

  /// 清空远程源缓存（清单文件 + 版本 / 时间 / 错误镜像键）。
  Future<Result<bool>> clearCache() => _repo.clearCache();
}
