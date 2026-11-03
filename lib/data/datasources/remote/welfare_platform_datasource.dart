/// 数据层：福利平台配置数据源（批次 H · H-01）。
///
/// 唯一真相源：iOS `vbox/WelfareRemote/WelfarePlatformConfigStore.swift`
///   · `fetchFromDirectURL()`（L221-257）：拉 manifest → 取
///     `files.welfarePlatforms` → 拉 `welfare_platforms.json` → 解码；
///   · `proxyCandidateURLs(for:)`（L295-313）：仅 GitHub 域名走代理降级链。
///
/// 复用既有远程源基建：manifest 拉取走 [RemoteManifestDatasource]，
/// 福利配置拉取复用 `RemoteSourceStrategy.candidates` 的代理链口径
/// （主代理 → 备用代理 → 直连，仅 GitHub 域名套代理）。
///
/// 校验链：HTTP 2xx → JSON 对象 → 契约必需项（`contract/schema/welfare_v1.json`）。
library;

import '../../../core/errors/exceptions.dart';
import '../../../core/errors/failures.dart';
import '../../../core/network/http_client.dart';
import '../../../core/utils/json_utils.dart';
import '../../../core/utils/result.dart';
import '../../../domain/entities/remote_source/remote_source.dart';
import '../../../domain/entities/welfare/welfare.dart';
import 'remote_manifest_datasource.dart';

/// 福利平台配置数据源。
class WelfarePlatformDatasource {
  /// 构造。
  ///
  /// [manifestDatasource] 便于单测注入；缺省用同一 [client] 构造。
  WelfarePlatformDatasource({
    required HttpClient client,
    RemoteManifestDatasource? manifestDatasource,
    List<ProxyHost> proxies = RemoteSourceStrategy.proxyHosts,
  })  : _client = client,
        _manifest = manifestDatasource ??
            RemoteManifestDatasource(client: client),
        _proxies = proxies;

  final HttpClient _client;
  final RemoteManifestDatasource _manifest;
  final List<ProxyHost> _proxies;

  /// 清单中福利平台配置文件键（契约 `manifest_v1.json` 已知文件键）。
  static const String manifestFileKey = 'welfarePlatforms';

  /// 由 [manifestUrl] 加载福利平台配置。
  ///
  /// 失败返回对应 [Failure]（地址缺失 / 网络 / 解析）。
  Future<Result<WelfarePlatformConfig>> fetch(
    String manifestUrl, {
    bool forceRefresh = false,
  }) async {
    // ① 拉 manifest（仅 GitHub 域名套代理降级链，数据源内部自带候选遍历）
    RemoteManifest? manifest;
    Failure? lastFailure;
    for (final String candidate
        in RemoteSourceStrategy.candidates(manifestUrl, proxies: _proxies)) {
      final Result<RemoteManifest> r =
          await _manifest.fetch(candidate, forceRefresh: forceRefresh);
      final Failure? f = r.failureOrNull;
      if (f == null) {
        manifest = r.valueOrNull;
        break;
      }
      lastFailure = f;
    }
    if (manifest == null) {
      return Err<WelfarePlatformConfig>(
        lastFailure ?? const UnknownFailure('福利 manifest 拉取失败'),
      );
    }

    // ② 取 profile 地址
    final String url = (manifest.files[manifestFileKey] ?? '').trim();
    if (url.isEmpty) {
      return const Err<WelfarePlatformConfig>(
        ValidationFailure(
          '清单未配置 welfarePlatforms 地址（files.$manifestFileKey）',
        ),
      );
    }

    // ③ 拉 welfare_platforms.json（同样走代理降级链）
    for (final String candidate
        in RemoteSourceStrategy.candidates(url, proxies: _proxies)) {
      final Result<WelfarePlatformConfig> r =
          await _fetchConfig(candidate, forceRefresh: forceRefresh);
      final Failure? f = r.failureOrNull;
      if (f == null) return r;
      lastFailure = f;
    }
    return Err<WelfarePlatformConfig>(
      lastFailure ?? const UnknownFailure('福利平台配置拉取失败'),
    );
  }

  Future<Result<WelfarePlatformConfig>> _fetchConfig(
    String candidate, {
    required bool forceRefresh,
  }) async {
    final Uri? uri = Uri.tryParse(candidate);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      return const Err<WelfarePlatformConfig>(
        ValidationFailure('福利平台配置地址非法（需 http/https 绝对地址）'),
      );
    }
    try {
      final HttpClientResponse res = await _client.get(
        uri,
        headers: <String, String>{
          if (forceRefresh) 'cache-control': 'no-cache',
        },
      );
      if (!res.isOk) {
        return Err<WelfarePlatformConfig>(
          NetworkFailure(
            'HTTP ${res.statusCode}：$uri',
            code: ErrorCode.httpStatus,
          ),
        );
      }
      final Map<String, Object?>? json = JsonUtils.tryDecodeMap(res.text);
      if (json == null) {
        return const Err<WelfarePlatformConfig>(
          ParseFailure('福利平台配置不是 JSON 对象'),
        );
      }
      final WelfarePlatformConfig? config = WelfarePlatformConfig.tryParse(json);
      if (config == null) {
        return const Err<WelfarePlatformConfig>(
          ParseFailure('福利平台配置不满足契约 welfare_v1.json 必需结构'),
        );
      }
      return Success<WelfarePlatformConfig>(config);
    } catch (e) {
      return Err<WelfarePlatformConfig>(Failure.from(e));
    }
  }
}