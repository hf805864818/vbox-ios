/// 数据层：TMDB 远程数据源（批次 G · G-06）。
///
/// 唯一真相源：iOS `vbox/Services/TMDBService.swift`
///   · 常量（L9-L10）：`apiKey` / `imageBaseURL`；
///   · `proxiedURL`（L42-L54）—— 把整体 URL 作为代理 `url` query 参数编码，
///     allowed 保留 URL 结构与已编码的 `%XX`，但把 `&` `=` 等**编码**，避免代理
///     把被代理 URL 内部参数解析成自身参数；`useProxyToken && token 非空` 时附
///     `token=`；
///   · `originalImageURL`（L75-L77）—— `{imageBase}/{size}{path}`；
///   · `searchMovie`（L82-L106）—— `/search/multi` + `api_key` + `language=zh-CN`
///     + `query`（+ 数字年份 `year`），仅取 `movie`/`tv` 首个候选；
///   · `fetchImages`（L111-L126）—— `/{movie|tv}/{id}/images`
///     + `include_image_language=zh,en,null`；
///   · `fetchCredits`（L131-L146）—— `/{movie|tv}/{id}/credits` + `language=zh-CN`；
///   · 非 200 / 解码失败 / 网络异常一律返回 `null`（iOS 各方法返回 `nil`）。
///
/// 差异登记：
///   · iOS `updateProxy` / `updateToken` 把配置缓存进单例；Flutter 侧改为每次请求
///     从注入的 [TmdbConfigStore] 实时读取（配置可在设置页热改，无需手动同步）；
///   · iOS 用 `URLSession`（15s/30s 超时）；Flutter 复用核心层 [HttpClient]；
///   · 批次 B：新增直连图床常量（BunnyCDN `images.tmdb.org`）、`imageUrl()` 与
///     `probeDirectImage()`；线路判定见 `tmdb_image_route.dart`（对齐 iOS
///     `TMDBService.resolveImageRoute`）。上游统一用 Bunny 域名，代理端同样受益。
library;

import 'dart:convert' show utf8;
import 'dart:io' as io;

import '../../../core/network/http_client.dart';
import '../../../core/utils/json_utils.dart';
import '../../../core/utils/logger.dart';
import '../../../domain/entities/tmdb/tmdb_models.dart';
import '../local/tmdb_config_store.dart';

/// TMDB 远程数据源。
class TmdbDatasource {
  /// 构造（[client] 便于测试注入 MockClient；[config] 缺省取共享实例）。
  TmdbDatasource({HttpClient? client, TmdbConfigStore? config})
      : _client = client ?? HttpClient(),
        _config = config;

  /// TMDB API Key（对齐 iOS `TMDBService.apiKey`，公开只读 Key）。
  static const String apiKey = 'eea47c6a97dbc2b7cfad319971719cec';

  /// TMDB API 基址（对齐 iOS `apiURL` 的 `https://api.themoviedb.org/3`）。
  static const String apiBase = 'https://api.themoviedb.org/3';

  /// TMDB 图片基址（对齐 iOS `TMDBService.imageBaseURL`）。
  static const String imageBaseUrl = kTmdbImageBaseUrl;

  /// TMDB 直连图床基址（BunnyCDN 拉流域，B 方案直连时使用）。
  static const String directImageBase = kTmdbImageDirectBaseUrl;

  /// TMDB 官方图床基址（CloudFront；直连不可用 / 历史行为）。
  static const String legacyImageBase = kTmdbImageBaseUrl;

  /// 直连探测超时（`w92` 小图正常 < 1s，留 3s 余量）。
  static const Duration probeTimeout = Duration(seconds: 3);

  /// 代理 query 编码的**保留字符集**（对齐 iOS `allowed`）：
  /// 字母数字 + `:/?+$,;-.~_#[]!%`。其中 `%` 保留以兼容已编码的 `%XX`；
  /// `&` `=` 不在集合内 → 会被编码，隔离被代理 URL 的内部参数。
  static const String _proxyAllowedExtra = ':/?+\$,;-.~_#[]!%';

  final HttpClient _client;
  final TmdbConfigStore? _config;

  TmdbConfigStore? get _cfg {
    final TmdbConfigStore? injected = _config;
    if (injected != null) return injected;
    try {
      return TmdbConfigStore.shared;
    } catch (_) {
      return null;
    }
  }

  // ─────────────── 代理 URL（对齐 iOS `proxiedURL`）───────────────

  /// 生成代理 URL。
  ///
  /// [useToken] 且 [token] 非空时附 `&token=`（对齐 iOS）。`proxyBaseUrl` 为空时
  /// 调用方应避免发起请求（见 [TmdbConfigStore.isReady]）。
  static String proxiedUrl(
    String originalUrl, {
    required String proxyBaseUrl,
    required bool useToken,
    required String token,
  }) {
    final String encoded = encodeForProxyQuery(originalUrl);
    if (useToken && token.isNotEmpty) {
      return '$proxyBaseUrl?token=$token&url=$encoded';
    }
    return '$proxyBaseUrl?url=$encoded';
  }

  /// 按 iOS `allowed` 集做整体 URL 的 query 编码（[proxiedUrl] 内部使用，公开供单测）。
  static String encodeForProxyQuery(String input) {
    final StringBuffer out = StringBuffer();
    for (final int rune in input.runes) {
      final String ch = String.fromCharCode(rune);
      if (_isProxyAllowed(ch)) {
        out.write(ch);
      } else {
        for (final int b in utf8.encode(ch)) {
          out.write('%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}');
        }
      }
    }
    return out.toString();
  }

  static bool _isProxyAllowed(String ch) {
    if (ch.length == 1) {
      final int c = ch.codeUnitAt(0);
      // A-Z / a-z / 0-9
      if ((c >= 0x41 && c <= 0x5A) ||
          (c >= 0x61 && c <= 0x7A) ||
          (c >= 0x30 && c <= 0x39)) {
        return true;
      }
    }
    return _proxyAllowedExtra.contains(ch);
  }

  /// 生成 TMDB API 代理 URL（对齐 iOS `apiURL`）。
  String apiUrl(String path) => proxiedUrl(
        '$apiBase$path',
        proxyBaseUrl: _cfg?.proxyUrl.trim() ?? '',
        useToken: _cfg?.useToken ?? false,
        token: _cfg?.proxyToken.trim() ?? '',
      );

  /// 远程图片 URL 转代理（对齐 iOS `proxiedImageURL`；Flutter 无本地图片代理，
  /// 直接走云端代理，语义等同 iOS 的兜底分支）。
  String proxiedImageUrl(String originalUrl) => proxiedUrl(
        originalUrl,
        proxyBaseUrl: _cfg?.proxyUrl.trim() ?? '',
        useToken: _cfg?.useToken ?? false,
        token: _cfg?.proxyToken.trim() ?? '',
      );

  /// 生成 TMDB 图片原始 URL（对齐 iOS `originalImageURL`）。
  static String originalImageUrl(String path, {String size = 'w500'}) =>
      '$imageBaseUrl/$size$path';

  /// 按线路拼图片 URL（[direct] 为真取 BunnyCDN，否则取官方 CloudFront）。
  ///
  /// 只拼「上游原始地址」；是否再套代理由调用方决定（见 [proxiedImageUrl]）。
  static String imageUrl(String path, String size, {required bool direct}) =>
      '${direct ? directImageBase : legacyImageBase}/$size$path';

  /// 直连图床可用性探测（`w92` 小图，3 秒超时，不重试）。
  ///
  /// [posterPath] 来自搜索命中项（一定存在），避免用固定路径被删导致误判。
  /// 返回 false 覆盖：非 200 / 超时 / TLS 失败 / 空路径。
  Future<bool> probeDirectImage(String posterPath) async {
    if (posterPath.trim().isEmpty) return false;
    final String url = '$directImageBase/w92$posterPath';
    try {
      return await _probeByHttp(url)
          .timeout(probeTimeout, onTimeout: () => false);
    } catch (e) {
      AppLog.warn('tmdb', '直连图床探测失败：$e', category: LogCategory.network);
      return false;
    }
  }

  /// 用 `dart:io` 直接探 HTTP 状态，不解析图片字节。
  static Future<bool> _probeByHttp(String url) async {
    final io.HttpClient client = io.HttpClient()
      ..connectionTimeout = probeTimeout;
    try {
      final io.HttpClientRequest request = await client.getUrl(Uri.parse(url));
      final io.HttpClientResponse response =
          await request.close().timeout(probeTimeout);
      await response.drain<void>();
      return response.statusCode == 200;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  // ─────────────── 接口 ───────────────

  /// 按片名（+ 可选年份）搜索，返回最佳匹配（对齐 iOS `searchMovie`）。
  Future<TmdbSearchResult?> searchMovie(String name, {String? year}) async {
    final String encodedName = Uri.encodeComponent(name);
    String path =
        '/search/multi?api_key=$apiKey&language=zh-CN&query=$encodedName&page=1';
    final int? y = int.tryParse((year ?? '').trim());
    if (y != null) path += '&year=$y';

    final Map<String, Object?>? json = await _getJson(apiUrl(path));
    if (json == null) return null;
    final Iterable<TmdbSearchResult> hits =
        JsonUtils.asMapList(json['results'])
            .map(TmdbSearchResult.fromJson)
            .where((TmdbSearchResult r) => r.isMovieOrTv);
    return hits.isEmpty ? null : hits.first;
  }

  /// 拉取影片图片（对齐 iOS `fetchImages`）。
  Future<TmdbImages?> fetchImages(int id, {String mediaType = 'movie'}) async {
    final String endpoint = mediaType == 'tv' ? 'tv' : 'movie';
    final Map<String, Object?>? json = await _getJson(
      apiUrl('/$endpoint/$id/images?api_key=$apiKey'
          '&include_image_language=zh,en,null'),
    );
    if (json == null) return null;
    return TmdbImages.fromJson(json);
  }

  /// 拉取演职人员（对齐 iOS `fetchCredits`）。
  Future<TmdbCredits?> fetchCredits(int id, {String mediaType = 'movie'}) async {
    final String endpoint = mediaType == 'tv' ? 'tv' : 'movie';
    final Map<String, Object?>? json = await _getJson(
      apiUrl('/$endpoint/$id/credits?api_key=$apiKey&language=zh-CN'),
    );
    if (json == null) return null;
    return TmdbCredits.fromJson(json);
  }

  // ─────────────── 内部 ───────────────

  /// 发起 GET 并解码 JSON 对象；非 2xx / 异常 / 非 JSON → null（对齐 iOS 容错）。
  Future<Map<String, Object?>?> _getJson(String url) async {
    try {
      final HttpClientResponse res = await _client.get(Uri.parse(url));
      if (!res.isOk) return null;
      return JsonUtils.tryDecodeMap(res.text);
    } catch (_) {
      return null;
    }
  }
}