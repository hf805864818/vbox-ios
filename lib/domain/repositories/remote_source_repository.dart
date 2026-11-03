/// 领域层：远程源仓储契约。
///
/// 契约：`contract/schema/manifest_v1.json`
/// 逆向来源：iOS `vbox/Services/RemoteSourceConfigManager.swift`。
library;

import '../../core/utils/result.dart';
import '../entities/remote_source/remote_source.dart';

/// 远程源仓储。
abstract interface class RemoteSourceRepository {
  /// 拉取清单（[forceRefresh] 为 true 时忽略缓存与 TTL）。
  Future<Result<RemoteManifest>> fetchManifest({bool forceRefresh = false});

  /// 读取本地缓存清单（无缓存返回 null）。
  Future<Result<RemoteManifest?>> cachedManifest();

  /// 落盘缓存清单。
  Future<Result<bool>> saveManifest(RemoteManifest manifest);

  /// 是否需要刷新（按清单 `ttlSeconds` 判定；无缓存恒为 true）。
  Future<Result<bool>> needsRefresh(int nowSeconds);

  /// 缓存清单的写入时间（Unix 秒；无缓存返回 0）。
  Future<Result<int>> cachedAtSeconds();

  /// 读取远程源设置（开关 / manifest 地址 / 上次版本 / 上次同步时间）。
  Future<Result<RemoteSourceSettings>> settings();

  /// 写入「启用远程默认源」开关（`remote_default_source_enabled`）。
  Future<Result<bool>> setEnabled(bool enabled);

  /// 写入 manifest 地址（`remote_default_manifest_url`，用户覆盖）。
  Future<Result<bool>> setManifestUrl(String url);

  /// 清空远程源缓存（清单文件 + 版本 / 时间 / 错误 / Node bundle 镜像键）。
  Future<Result<bool>> clearCache();
}
