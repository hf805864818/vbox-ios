/// 领域层：源治理用例（兜底切片源搜索 / 合成站点 / 远程源列表）。
///
/// 唯一真相源：iOS `SpiderManager`
///   · `allFallbackSites`（L264-L284）——兜底源 = 内置（兼容模式）+ 自定义；
///   · `searchStream`（L2229-L2247）——`fallbackEnabled` 开启时才把兜底源并入搜索；
///   · `nativeSearch`（L2743-L2757）——同一开关语义的兜底合并；
///   · `customParsers` + `loadCustomParsers`（L45、L286-L319）——解析器清单；
///   · `PlayerViewsV2` L5552-L5581 —— 播放前用解析器把页面地址换成媒体直链。
///
/// Flutter 侧 landing 口径：
/// - iOS `builtinFallbackSites` 已废弃（远程 `api_sources.json` 替代），故本端
///   兜底源 = **用户自定义切片源**（`custom_fallback_sites`）；
/// - 远程默认源列表仅供切片资源配置页只读展示（来自 allSources 的 API 端点站点）；
/// - 自定义切片源合成稳定 `key`（`fallback_<host>`）供搜索结果路由详情；
/// - 站源（zhanyuan）启停状态以 SQLite `zhanyuan.isActive` 为权威，
///   订阅配置站点作内存补齐（对齐 iOS「DB 优先 → 内存回退」）。
library;

import '../../core/network/http_client.dart';
import '../../core/utils/result.dart';
import '../../data/datasources/local/source_governance_store.dart';
import '../../data/datasources/remote/cms_v10_datasource.dart';
import '../../data/datasources/remote/cms_v10_models.dart';
import '../../data/models/zhanyuan.dart';
import '../entities/remote_source/remote_source.dart';
import '../entities/source/source_governance.dart';
import '../entities/spider/engine_type.dart';
import '../entities/spider/site_config.dart';
import '../entities/spider/spider_models.dart';

/// 兜底切片源（参与搜索的合成源）。
class FallbackSearchSource {
  /// 构造。
  const FallbackSearchSource({
    required this.key,
    required this.name,
    required this.api,
  });

  /// 合成站点 key（`fallback_<host>`；远程源沿用其 allSources key）。
  final String key;

  /// 源名称。
  final String name;

  /// CMS V10 API 地址。
  final String api;
}

/// 源治理用例。
class SourceGovernanceUseCases {
  /// 构造。
  ///
  /// [loadAllSources] 注入站点聚合加载（供「远程默认源」只读列表 + 合成站点）；
  /// [loadAllZhanyuanSites] 注入订阅配置站源加载（站源管理页内存补齐；可空）；
  /// [httpClient] 注入自定义解析器请求客户端（可空 → 解析器链路禁用）；
  /// [store] 注入源治理存储（缺省用全局单例）。
  SourceGovernanceUseCases({
    required this.loadAllSources,
    this.loadAllZhanyuanSites,
    CmsV10Datasource? cmsDatasource,
    HttpClient? httpClient,
    SourceGovernanceStore? store,
  })  : _cms = cmsDatasource,
        _http = httpClient,
        _store = store ?? SourceGovernanceStore.instance;

  /// 站点聚合加载器。
  final Future<Result<AllSourcesContainer>> Function() loadAllSources;

  /// 订阅配置站源加载器（全部 type==2 站点，不做启用过滤；可空）。
  final Future<List<Zhanyuan>> Function()? loadAllZhanyuanSites;

  final CmsV10Datasource? _cms;
  final HttpClient? _http;
  final SourceGovernanceStore _store;

  /// 远程默认 API 源（只读展示；来自 allSources 的 `apiEndpoint` 站点）。
  Future<List<FallbackSearchSource>> remoteApiSites() async {
    final Result<AllSourcesContainer> result = await loadAllSources();
    final AllSourcesContainer? container = result.valueOrNull;
    if (container == null) return const <FallbackSearchSource>[];
    final List<FallbackSearchSource> out = <FallbackSearchSource>[];
    for (final Map<String, Object?> raw in container.sites) {
      final SiteConfig site = SiteConfig.fromJson(raw);
      final String api = site.api ?? '';
      if (site.key.isEmpty || api.isEmpty) continue;
      if (site.resolveSiteMode() != SiteMode.apiEndpoint) continue;
      out.add(FallbackSearchSource(key: site.key, name: site.name, api: api));
    }
    return out;
  }

  /// 参与搜索的自定义切片源（合成 key；空列表表示无自定义源）。
  List<FallbackSearchSource> customFallbackSources() => _store.customFallbackSites
      .map((FallbackSite s) => FallbackSearchSource(
            key: fallbackKeyFor(s.api),
            name: s.name,
            api: s.api,
          ))
      .toList(growable: false);

  /// 远程默认解析器（只读展示；来自 allSources `parsers.parses`，对齐 iOS
  /// `RemoteSourceConfigManager.cachedParsers()`）。
  Future<List<ParserEntry>> remoteParsers() async {
    final Result<AllSourcesContainer> result = await loadAllSources();
    final AllSourcesContainer? container = result.valueOrNull;
    final List<Object?> raw = container?.parses ?? const <Object?>[];
    if (raw.isEmpty) return const <ParserEntry>[];
    return raw
        .whereType<Map<Object?, Object?>>()
        .map((Map<Object?, Object?> m) =>
            ParserEntry.fromJson(m.cast<String, Object?>()))
        .where((ParserEntry p) => p.isValid)
        .toList(growable: false);
  }

  /// 全部解析器 = 远程默认 + 用户自定义（按地址去重，用户项优先）。
  ///
  /// 对齐 iOS `loadCustomParsers`：远程先行、用户追加且不覆盖已有地址。
  Future<List<ParserEntry>> allParsers() async {
    final List<ParserEntry> remote = await remoteParsers();
    final List<ParserEntry> user = _store.userParsers;
    final Set<String> userUrls = user.map((ParserEntry p) => p.url).toSet();
    return <ParserEntry>[
      ...remote.where((ParserEntry p) => !userUrls.contains(p.url)),
      ...user,
    ];
  }

  /// 用**全部解析器**（远程默认 + 用户自定义）把页面地址解析为媒体直链
  /// （对齐 iOS `PlayerViewsV2` L5552-L5581：`subManager.parses + customParsers`
  /// 逐个尝试，`parser.url + 编码后的原始地址` → 响应体正则提取 `m3u8` / `mp4`）。
  /// 命中返回直链，未命中返回 null。
  Future<String?> resolveWithParsers(String rawUrl) async {
    final HttpClient? client = _http;
    final String target = rawUrl.trim();
    if (client == null || target.isEmpty) return null;
    final List<ParserEntry> parsers = await allParsers();
    if (parsers.isEmpty) return null;
    for (final ParserEntry parser in parsers) {
      final String? candidate = _joinParserUrl(parser.url, target);
      if (candidate == null) continue;
      try {
        final HttpClientResponse res = await client.get(Uri.parse(candidate));
        if (!res.isOk) continue;
        final String? media = _extractMediaUrl(res.text);
        if (media != null) return media;
      } catch (_) {
        // 单解析器失败 → 继续下一个（对齐 iOS `catch { continue }`）。
        continue;
      }
    }
    return null;
  }

  /// 站源（zhanyuan）清单：SQLite `isActive` 为权威，订阅配置站点作内存补齐。
  ///
  /// 对齐 iOS `ZhanyuanSiteManageView`（读 `queryAllZhanyuanSites()`）；Flutter
  /// 侧订阅配置站点可能尚未落库，故按站点名合并，避免「DB 空 → 列表空」。
  Future<List<Zhanyuan>> listZhanyuanSites() async {
    final Map<String, Zhanyuan> byName = <String, Zhanyuan>{};
    for (final Zhanyuan z in await loadAllZhanyuanSites?.call() ??
        const <Zhanyuan>[]) {
      byName[z.name] = z;
    }
    for (final Zhanyuan z in await _store.allZhanyuanSites()) {
      final Zhanyuan? existing = byName[z.name];
      // DB 覆盖启用状态；配置行保留 key（`zhan_N`，供详情路由）。
      byName[z.name] =
          existing == null ? z : existing.copyWith(isActive: z.isActive);
    }
    final List<Zhanyuan> list = byName.values.toList(growable: false);
    list.sort((Zhanyuan a, Zhanyuan b) => a.name.compareTo(b.name));
    return list;
  }

  /// 已启用站源数量（设置页副文本，对齐 iOS `queryActiveZhanyuanSites().count`）。
  Future<int> activeZhanyuanCount() async {
    final List<Zhanyuan> sites = await listZhanyuanSites();
    return sites.where((Zhanyuan z) => z.isActive).length;
  }

  /// 兜底源搜索（`fallback_enabled` 关闭时直接返回，对齐 iOS 开关语义）。
  ///
  /// 分批并发（每批 30），逐批 [onBatch] 回调非空结果；结果回填合成 `engineKey`
  /// 供详情页按 key 路由。
  Future<void> searchFallback(
    String keyword, {
    required void Function(List<VodItem>) onBatch,
    void Function(String)? onLog,
  }) async {
    final void Function(String) log = onLog ?? (_) {};
    if (!_store.fallbackEnabled) {
      log('兜底源开关关闭，跳过兜底切片源搜索');
      return;
    }
    final CmsV10Datasource? cms = _cms;
    if (cms == null) return;

    final List<FallbackSearchSource> sources = customFallbackSources();
    if (sources.isEmpty) {
      log('无自定义切片源，跳过兜底搜索');
      return;
    }

    const int batchSize = 30;
    for (int start = 0; start < sources.length; start += batchSize) {
      final List<FallbackSearchSource> batch = sources.sublist(
        start,
        (start + batchSize).clamp(0, sources.length),
      );
      final List<(FallbackSearchSource, List<CmsV10Video>)> results =
          await Future.wait(
        batch.map((FallbackSearchSource s) async {
          final Result<List<CmsV10Video>> r =
              await cms.fetchSearchVideos(s.api, keyword: keyword);
          return (s, r.valueOrNull ?? const <CmsV10Video>[]);
        }),
      );
      for (final (FallbackSearchSource s, List<CmsV10Video> videos)
          in results) {
        if (videos.isEmpty) continue;
        log('✅ 切片源[${s.name}] +${videos.length}条');
        onBatch(
          videos
              .map((CmsV10Video v) => _toVodItem(v)
                  .withEngineKey(s.key)
                  .withSourceLabel(s.name))
              .toList(growable: false),
        );
      }
    }
  }

  /// 按合成 key 还原兜底站点配置（详情路由回退：allSources 查不到该 key 时使用）。
  Future<SiteConfig?> findFallbackSite(String key) async {
    final String k = key.trim();
    if (k.isEmpty) return null;
    for (final FallbackSearchSource s in customFallbackSources()) {
      if (s.key == k) {
        return SiteConfig(key: s.key, name: s.name, type: 1, api: s.api);
      }
    }
    return null;
  }

  /// 切片源合成 key（`fallback_<host>`；host 缺失时退回地址哈希，保证稳定）。
  static String fallbackKeyFor(String api) {
    final String host = Uri.tryParse(api.trim())?.host ?? '';
    if (host.isEmpty) return 'fallback_${api.hashCode.abs()}';
    return 'fallback_$host';
  }

  /// 拼接解析器地址（`parser.url + 编码后的原始地址`）；非法返回 null。
  ///
  /// 用 [Uri.encodeFull] 保留 URL 保留字符（对齐 iOS `urlQueryAllowed`）。
  static String? _joinParserUrl(String base, String target) {
    final String b = base.trim();
    if (b.isEmpty) return null;
    final String joined = '$b${Uri.encodeFull(target)}';
    final Uri? uri = Uri.tryParse(joined);
    if (uri == null || uri.host.isEmpty) return null;
    return joined;
  }

  /// 解析器响应体 → 媒体直链（`m3u8` / `mp4` 正则，对齐 iOS patterns）。
  static final RegExp _mediaUrlRegex =
      RegExp(r'''https?://[^\s"'<>]+?\.(?:m3u8|mp4)[^\s"'<>]*''');

  static String? _extractMediaUrl(String body) {
    final RegExpMatch? m = _mediaUrlRegex.firstMatch(body);
    return m?.group(0);
  }

  VodItem _toVodItem(CmsV10Video v) => VodItem(
        vodId: v.vodId,
        vodName: v.name,
        vodPic: v.pic,
        vodRemarks: v.remarks.isEmpty ? null : v.remarks,
        vodYear: v.year.isEmpty ? null : v.year,
        vodArea: v.area.isEmpty ? null : v.area,
      );
}
