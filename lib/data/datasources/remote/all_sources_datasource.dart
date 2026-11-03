/// 数据层：远程站点聚合（all_sources.json）数据源。
///
/// 契约：`contract/schema/manifest_v1.json` §`$defs.allSources`
/// 逆向来源：iOS `vbox/Services/RemoteSourceConfigManager.swift`
///   - 拉取地址：清单 `files.allSources`；
///   - 代理降级链：ghfast → gh-proxy → 直连（对齐 iOS `proxyHosts`）；
///   - 校验链：HTTP 2xx → JSON 对象 → 顶层对象（7 键均可选）；
///   - **本地缓存**：同步成功后把原始 JSON 落盘到 `StoragePaths.cacheDir/all_sources.json`
///     （对齐 iOS `syncNow` 步骤 3 写 `remote_sources/all_sources.json`），
///     运行时 cache-first 本地加载（对齐 iOS `SpiderManager` 读 `cachedAllSources()`），
///     离线/弱网下仍可展示站点与分类资源。
library;

import '../../../core/errors/exceptions.dart';
import '../../../core/errors/failures.dart';
import '../../../core/network/http_client.dart';
import '../../../core/storage/file_store.dart';
import '../../../core/storage/storage_paths.dart';
import '../../../core/utils/json_utils.dart';
import '../../../core/utils/result.dart';
import '../../../domain/entities/remote_source/remote_source.dart';
import '../../../domain/entities/spider/spider.dart';

/// 远程站点聚合数据源。
class AllSourcesDatasource {
  /// 构造。
  ///
  /// [cacheFilePath] 本地缓存路径（缺省 `StoragePaths.cacheDir/all_sources.json`，
  /// 便于单测注入临时文件）。
  AllSourcesDatasource({
    required HttpClient client,
    Map<String, String> headers = const <String, String>{},
    String? cacheFilePath,
  })  : _client = client,
        _headers = headers,
        _cacheFilePath = cacheFilePath;

  final HttpClient _client;
  final Map<String, String> _headers;
  final String? _cacheFilePath;

  /// 本地缓存文件名（对齐 iOS `CacheFile.allSources`）。
  static const String cacheFileName = 'all_sources.json';

  String get _cachePath =>
      _cacheFilePath ?? FileStore.join(StoragePaths.cacheDir, cacheFileName);

  /// 拉取并解析 allSources。
  ///
  /// cache-first（对齐 iOS `SpiderManager` 读本地 `cachedAllSources()`）：
  /// - `forceRefresh == false` 且本地有缓存 → 直接本地加载，不联网；
  /// - 否则走代理降级链拉取，成功即写本地缓存；
  /// - 非强制刷新时网络全部失败 → 回退本地缓存（iOS cache 兜底语义）；
  ///   `forceRefresh == true`（同步链路）失败则如实上报，不掩盖网络错误。
  Future<Result<AllSourcesContainer>> fetch(
    String url, {
    bool forceRefresh = false,
  }) async {
    final String raw = url.trim();
    final Uri? uri = Uri.tryParse(raw);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      return const Err<AllSourcesContainer>(
        ValidationFailure('allSources 地址非法（需 http/https 绝对地址）'),
      );
    }

    // ① cache-first：非强制刷新且有本地缓存 → 直接本地加载。
    if (!forceRefresh) {
      final AllSourcesContainer? cached = await _readCache();
      if (cached != null) return Success<AllSourcesContainer>(cached);
    }

    // ② 代理降级链拉取（成功即写缓存，见 [_fetchOne]）。
    Failure? lastFailure;
    for (final String candidate in RemoteSourceStrategy.candidates(raw)) {
      final Result<AllSourcesContainer> r =
          await _fetchOne(candidate, forceRefresh: forceRefresh);
      final Failure? f = r.failureOrNull;
      if (f == null) return r;
      lastFailure = f;
    }

    // ③ 网络失败 → 回退本地缓存（对齐 iOS cache 兜底）。
    //    仅非强制刷新时回退：`forceRefresh` 用于同步链路，此时网络失败必须如实
    //    上报（对齐 iOS `syncNow` 的 updateFailure），否则会把网络失败误判为同步成功。
    if (!forceRefresh) {
      final AllSourcesContainer? cached = await _readCache();
      if (cached != null) return Success<AllSourcesContainer>(cached);
    }

    return Err<AllSourcesContainer>(
      lastFailure ?? const UnknownFailure('allSources 拉取失败'),
    );
  }

  /// 读取本地缓存的 allSources（不存在/非法/越权返回 null）。
  Future<AllSourcesContainer?> _readCache() async {
    try {
      final Map<String, Object?>? json = await FileStore.readJsonMap(_cachePath);
      if (json == null) return null;
      return AllSourcesContainer.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  /// 写本地缓存（失败不抛错：缓存缺失由调用方回退网络/静默）。
  Future<void> _writeCache(String rawJson) async {
    try {
      await FileStore.writeString(_cachePath, rawJson);
    } catch (_) {}
  }

  /// 按站点 key（契约字段 `key`，详情页 laiyuan 即此值）查找站点配置。
  static SiteConfig? findSite(AllSourcesContainer container, String key) {
    final String k = key.trim();
    if (k.isEmpty) return null;
    for (final Map<String, Object?> raw in container.sites) {
      if ((raw['key'] ?? '').toString() == k) {
        return SiteConfig.fromJson(raw);
      }
    }
    return null;
  }

  Future<Result<AllSourcesContainer>> _fetchOne(
    String candidate, {
    required bool forceRefresh,
  }) async {
    try {
      final HttpClientResponse res = await _client.get(
        Uri.parse(candidate),
        headers: <String, String>{
          ..._headers,
          if (forceRefresh) 'cache-control': 'no-cache',
        },
      );
      if (!res.isOk) {
        return Err<AllSourcesContainer>(
          NetworkFailure(
            'HTTP ${res.statusCode}：$candidate',
            code: ErrorCode.httpStatus,
          ),
        );
      }

      final Map<String, Object?>? json = JsonUtils.tryDecodeMap(res.text);
      if (json == null) {
        return const Err<AllSourcesContainer>(
          ParseFailure('allSources 不是 JSON 对象'),
        );
      }
      // 落盘原始 JSON（对齐 iOS `syncNow` 步骤 3：allSourcesData.write(.allSources)），
      // 供运行时 cache-first 本地加载。
      await _writeCache(res.text);
      return Success<AllSourcesContainer>(AllSourcesContainer.fromJson(json));
    } catch (e) {
      return Err<AllSourcesContainer>(Failure.from(e));
    }
  }
}
