/// 数据层：远程源仓储实现。
///
/// 组成：清单数据源（HTTP 拉取 + 校验）+ 本地缓存文件 + 契约同步键。
/// - 缓存清单落盘于 `StoragePaths.cacheDir/remote_manifest.json`（原子写）；
/// - 同时镜像写入契约键 `remote_default_last_config_version`（string）
///   与 `remote_default_last_sync_time`（long，Unix 秒）；
/// - manifest 地址取自契约键 `remote_default_manifest_url`（用户可覆盖）。
///
/// 边界约定：内层异常统一用 [Failure.from] 归一，方法只返回 `Result`。
library;

import '../../core/errors/failures.dart';
import '../../core/storage/file_store.dart';
import '../../core/storage/storage_paths.dart';
import '../../core/utils/result.dart';
import '../../core/utils/time_utils.dart';
import '../../domain/entities/remote_source/remote_source.dart';
import '../../domain/repositories/remote_source_repository.dart';
import '../datasources/local/prefs_manager.dart';
import '../datasources/remote/all_sources_datasource.dart';
import '../datasources/remote/remote_manifest_datasource.dart';

/// 远程源仓储实现。
class RemoteSourceRepositoryImpl implements RemoteSourceRepository {
  /// 构造（[prefs] / [cacheFilePath] 便于单测注入）。
  RemoteSourceRepositoryImpl({
    required RemoteManifestDatasource datasource,
    PrefsManager? prefs,
    String? cacheFilePath,
  })  : _datasource = datasource,
        _prefs = prefs,
        _cacheFilePath = cacheFilePath;

  final RemoteManifestDatasource _datasource;
  final PrefsManager? _prefs;
  final String? _cacheFilePath;

  /// 缓存清单文件名。
  static const String cacheFileName = 'remote_manifest.json';

  /// 缓存包裹内的时间戳键。
  static const String cachedAtKey = 'cachedAtSeconds';

  /// 缓存包裹内的清单键。
  static const String manifestKey = 'manifest';

  /// Node bundle 远端地址契约键（对齐 iOS `RemoteSourceConfigKeys.nodeBundleURL`）。
  static const String _keyNodeBundleUrl = 'remote_node_bundle_url';

  /// Node bundle 版本契约键（对齐 iOS `RemoteSourceConfigKeys.nodeBundleVer`）。
  static const String _keyNodeBundleVer = 'remote_node_bundle_ver';

  /// 远程默认源开关契约键（对齐 iOS `RemoteSourceConfigKeys.enabled`）。
  static const String _keyEnabled = 'remote_default_source_enabled';

  /// manifest 地址契约键（对齐 iOS `RemoteSourceConfigKeys.manifestURL`）。
  static const String _keyManifestUrl = 'remote_default_manifest_url';

  /// 上次同步 configVersion 契约键。
  static const String _keyLastVersion = 'remote_default_last_config_version';

  /// 上次同步时间契约键。
  static const String _keyLastSyncTime = 'remote_default_last_sync_time';

  /// 上次同步错误契约键。
  static const String _keyLastError = 'remote_default_last_sync_error';

  /// 上次同步时的 App 版本契约键。
  static const String _keyLastAppVersion = 'remote_default_last_sync_app_version';

  PrefsManager get _p => _prefs ?? PrefsManager.instance;

  String get _cachePath =>
      _cacheFilePath ?? FileStore.join(StoragePaths.cacheDir, cacheFileName);

  @override
  Future<Result<RemoteManifest>> fetchManifest({bool forceRefresh = false}) async {
    try {
      final String url = (await _p.remoteManifestUrl()).trim();
      if (url.isEmpty) {
        return const Err<RemoteManifest>(
          ValidationFailure('未配置 manifest 地址（remote_default_manifest_url）'),
        );
      }
      return await _datasource.fetch(url, forceRefresh: forceRefresh);
    } catch (e) {
      return Err<RemoteManifest>(Failure.from(e));
    }
  }

  @override
  Future<Result<RemoteManifest?>> cachedManifest() async {
    try {
      final Map<String, Object?>? box = await FileStore.readJsonMap(_cachePath);
      final Object? raw = box?[manifestKey];
      if (raw is! Map) return const Success<RemoteManifest?>(null);
      return Success<RemoteManifest?>(
        RemoteManifest.fromJson(raw.cast<String, Object?>()),
      );
    } catch (e) {
      return Err<RemoteManifest?>(Failure.from(e));
    }
  }

  @override
  Future<Result<bool>> saveManifest(RemoteManifest manifest) async {
    try {
      final int now = TimeUtils.nowUnixSeconds();
      await FileStore.writeJson(_cachePath, <String, Object?>{
        cachedAtKey: now,
        manifestKey: manifest.toJson(),
      });
      await _p.set(_keyLastVersion, manifest.configVersion);
      await _p.set(_keyLastSyncTime, now);
      // ND-02：同步成功后镜像 Node bundle 远端地址/版本（对齐 iOS
      // `RemoteSourceConfigManager.syncNow` 的 `remote_node_bundle_url` /
      // `remote_node_bundle_ver` 写入/清除），供启动时 NodeRuntimeManager 做
      // 可选的远端增量刷新；未下发则清除，回退本地内置资源。
      await _mirrorNodeBundleKeys(manifest);
      return const Success<bool>(true);
    } catch (e) {
      return Err<bool>(Failure.from(e));
    }
  }

  /// Node bundle 键镜像（对齐 iOS `syncNow` 的 `remote_node_bundle_url` /
  /// `remote_node_bundle_ver`：下发了就写入，未下发就清除）。
  Future<void> _mirrorNodeBundleKeys(RemoteManifest manifest) async {
    final String? bundleUrl =
        _nonEmpty(manifest.files[RemoteManifest.keyNodeRuntimeBundle]);
    if (bundleUrl != null) {
      await _p.set(_keyNodeBundleUrl, bundleUrl);
    } else {
      await _p.remove(_keyNodeBundleUrl);
    }
    final String? bundleVer =
        _nonEmpty(manifest.files[RemoteManifest.keyNodeRuntimeBundleVer]);
    if (bundleVer != null) {
      await _p.set(_keyNodeBundleVer, bundleVer);
    } else {
      await _p.remove(_keyNodeBundleVer);
    }
  }

  static String? _nonEmpty(String? v) => (v == null || v.isEmpty) ? null : v;

  @override
  Future<Result<bool>> needsRefresh(int nowSeconds) async {
    final Result<int> atResult = await cachedAtSeconds();
    final Failure? failure = atResult.failureOrNull;
    if (failure != null) return Err<bool>(failure);

    final int cachedAt = atResult.valueOrNull ?? 0;
    // 无缓存：恒需要刷新
    if (cachedAt <= 0) return const Success<bool>(true);

    final Result<RemoteManifest?> cachedResult = await cachedManifest();
    final Failure? cacheFailure = cachedResult.failureOrNull;
    if (cacheFailure != null) return Err<bool>(cacheFailure);

    final int ttl =
        cachedResult.valueOrNull?.ttlSeconds ?? RemoteManifest.defaultTtlSeconds;
    return Success<bool>(nowSeconds - cachedAt >= ttl);
  }

  @override
  Future<Result<int>> cachedAtSeconds() async {
    try {
      final Map<String, Object?>? box = await FileStore.readJsonMap(_cachePath);
      final Object? raw = box?[cachedAtKey];
      return Success<int>(raw is num ? raw.toInt() : 0);
    } catch (e) {
      return Err<int>(Failure.from(e));
    }
  }

  @override
  Future<Result<RemoteSourceSettings>> settings() async {
    try {
      final Object? enabled = await _p.get(_keyEnabled);
      final Object? url = await _p.get(_keyManifestUrl);
      final Object? version = await _p.get(_keyLastVersion);
      final Object? syncTime = await _p.get(_keyLastSyncTime);
      return Success<RemoteSourceSettings>(
        RemoteSourceSettings(
          enabled: enabled is bool ? enabled : true,
          manifestUrl: url is String && url.trim().isNotEmpty
              ? url.trim()
              : RemoteSourceStrategy.defaultManifestUrl,
          lastConfigVersion: version is String ? version : '',
          lastSyncTimeSeconds: syncTime is num ? syncTime.toInt() : 0,
        ),
      );
    } catch (e) {
      return Err<RemoteSourceSettings>(Failure.from(e));
    }
  }

  @override
  Future<Result<bool>> setEnabled(bool enabled) async {
    try {
      await _p.set(_keyEnabled, enabled);
      return const Success<bool>(true);
    } catch (e) {
      return Err<bool>(Failure.from(e));
    }
  }

  @override
  Future<Result<bool>> setManifestUrl(String url) async {
    try {
      await _p.set(_keyManifestUrl, url.trim());
      return const Success<bool>(true);
    } catch (e) {
      return Err<bool>(Failure.from(e));
    }
  }

  @override
  Future<Result<bool>> clearCache() async {
    try {
      await FileStore.delete(_cachePath);
      // 一并清除 all_sources.json 本地缓存（对齐 iOS `clearCache` 删除整个
      // `remote_sources` 目录）：否则 cache-first 会继续命中旧站点列表。
      await FileStore.delete(
        FileStore.join(StoragePaths.cacheDir, AllSourcesDatasource.cacheFileName),
      );
      await _p.remove(_keyLastVersion);
      await _p.remove(_keyLastSyncTime);
      await _p.remove(_keyLastError);
      await _p.remove(_keyLastAppVersion);
      await _p.remove(_keyNodeBundleUrl);
      await _p.remove(_keyNodeBundleVer);
      return const Success<bool>(true);
    } catch (e) {
      return Err<bool>(Failure.from(e));
    }
  }
}