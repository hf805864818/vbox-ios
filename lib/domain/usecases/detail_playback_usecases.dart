/// 领域层：详情页·播放入口用例。
///
/// 链路：站点（allSources 按 key 解析）→ 模式判定 → 引擎/API → 详情内容 → 剧集/播放地址。
/// 对齐契约 §1.1（引擎选择规则）+ §3（`vod_play_from` / `vod_play_url` 解析）。
///
/// 模式分支（对齐 iOS `resolveSiteMode`）：
/// - apiEndpoint / zhanyuan → CMS V10 详情（`?ac=detail&ids=`），播放地址即直链；
/// - node / jsSpider / pythonSpider → Spider 引擎 `detailContent` / `playerContent`；
/// - jsSpider 由 QuickJS 顶替（G-03-B 决策：JSC 为 iOS 原生保留）。
library;

import 'dart:convert';

import '../../core/errors/exceptions.dart';
import '../../core/errors/failures.dart';
import '../../core/network/http_client.dart';
import '../../core/utils/logger.dart';
import '../../core/utils/result.dart';
import '../../data/datasources/local/tg_search_config_store.dart';
import '../../data/datasources/remote/all_sources_datasource.dart';
import '../../data/datasources/remote/cms_v10_datasource.dart';
import '../../data/datasources/remote/cms_v10_models.dart';
import '../../data/datasources/remote/spider_script_cache.dart';
import '../../data/models/zhanyuan.dart';
import '../../platform/runtime/quickjs_ffi.dart';
import '../../platform/spider/node_http_client.dart';
import '../../platform/spider/spider_engine_factory.dart';
import '../../platform/spider/tencent_video_spider.dart';
import '../../platform/spider/zhanyuan_search_service.dart';
import '../entities/playback/playback.dart';
import '../entities/remote_source/remote_source.dart';
import '../entities/spider/spider.dart';
import 'zhanyuan_search_usecases.dart';

/// 详情页·播放入口用例。
class DetailPlaybackUseCases {
  /// 构造。
  ///
  /// [loadAllSources] 注入站点聚合加载（清单 → allSources URL → 拉取解析），
  /// 便于表现层组装缓存/TTL 逻辑；引擎相关依赖均可注入（测试用 fake）。
  /// [customParser] 注入自定义解析器（用户 `user_parsers`）：非直链播放地址在
  /// 返回前先尝试解析为媒体直链（对齐 iOS `PlayerViewsV2` 解析器链路）。
  DetailPlaybackUseCases({
    required this.loadAllSources,
    SpiderEngineFactory engineFactory = const SpiderEngineFactory(),
    CmsV10Datasource? cmsDatasource,
    HttpClient? cloudHttpClient,
    QuickJsNativeBridge? quickJsBridge,
    NodeHttpClient? nodeClient,
    this.scriptBaseUrl,
    TencentVideoNativeSpider? tencentSpider,
    ZhanyuanSearchService? zhanyuanService,
    Future<String?> Function(String rawUrl)? customParser,
    Future<SiteConfig?> Function(String key)? fallbackSiteResolver,
    Future<String?> Function(String pageUrl)? webPageSniffer,
    SpiderScriptCache? spiderScriptCache,
  })  : _engineFactory = engineFactory,
        _cmsDatasource = cmsDatasource,
        _cloudHttpClient = cloudHttpClient,
        _quickJsBridge = quickJsBridge,
        _nodeClient = nodeClient,
        _tencentSpider = tencentSpider,
        _zhanyuanService = zhanyuanService ?? ZhanyuanSearchService(),
        _customParser = customParser,
        _fallbackSiteResolver = fallbackSiteResolver,
        _webPageSniffer = webPageSniffer,
        _scriptCache = spiderScriptCache;

  /// 日志标签。
  static const String logTag = 'playback';

  /// 站点聚合加载器（`Future<Result<AllSourcesContainer>>`）。
  final Future<Result<AllSourcesContainer>> Function() loadAllSources;

  /// 脚本相对路径基址（`allSources` 清单 URL），对齐 iOS `subBaseURL`。
  ///
  /// 站源 `api` 为 `./x.js` / `x.js` / `x.py` 等相对路径时，以其为 base 解析。
  final String? Function()? scriptBaseUrl;

  final SpiderEngineFactory _engineFactory;
  final CmsV10Datasource? _cmsDatasource;

  /// 网盘详情页解析用 HTTP 客户端（对齐 iOS `resolveCloudPlay` 的 URLSession）。
  final HttpClient? _cloudHttpClient;

  /// 网盘解析结果缓存（对齐 iOS `SpiderManager.cloudPlayCache`：30min TTL，
  /// 超 100 条时清理过期项）。
  final Map<String, _CloudPlayResult> _cloudPlayCache =
      <String, _CloudPlayResult>{};

  final QuickJsNativeBridge? _quickJsBridge;
  final NodeHttpClient? _nodeClient;
  final TencentVideoNativeSpider? _tencentSpider;
  final ZhanyuanSearchService _zhanyuanService;
  final Future<String?> Function(String rawUrl)? _customParser;
  final Future<SiteConfig?> Function(String key)? _fallbackSiteResolver;

  /// 内置网页嗅探（对齐 iOS「网页播放 URL → WebView 嗅探提取直链」；
  /// 在 customParser 未命中后兜底，见 [_applyWebPageSniff]）。
  final Future<String?> Function(String pageUrl)? _webPageSniffer;

  /// JS/Python 蜘蛛脚本本地缓存（对齐 iOS `cachedSpiderJSContent(forKey:)`）：
  /// 远程同步已把脚本落盘，详情/播放链路 cache-first 读取，避免每次进入详情都
  /// 现场联网拉脚本（离线/超时即详情失败），与 [ContentBrowseUseCases] 同口径。
  final SpiderScriptCache? _scriptCache;

  /// TG 搜索蜘蛛站点 key（对齐 iOS `SpiderManager` L1394 的注入判定）。
  static const String _tgSearchSiteKey = 'js_TG搜索';

  /// 腾讯站点合成配置（仅用于承载详情结果；不走 CMS/引擎路由）。
  static const SiteConfig _tencentSite = SiteConfig(
    key: TencentVideoNativeSpider.siteKey,
    name: '腾讯视频',
    type: 3,
    api: 'https://v.qq.com',
  );

  /// 加载详情播放数据。
  ///
  /// [siteKey] 即收藏/历史条目的 laiyuan；[initialIndex] 为续播入口传入的剧集索引。
  Future<Result<PlaybackDetail>> loadDetail({
    required String siteKey,
    required String vodId,
    int initialIndex = 0,
  }) async {
    // step 0（对齐 iOS `SpiderManager.getDetail`）：`ids` 为 HTTP(S) 详情页 URL
    // （网盘搜索结果 / 云盘 CMS 页 / 站源详情页）时，不走站点解析：
    //   ① 命中站源（type=2）域名 → 站源详情解析；
    //   ② 否则按网盘详情页解析（抓页 → 提取网盘分享链接 → 合成「☁️网盘」条目）。
    // 此前该分支直接落到 CMS V10 的 `?ac=detail&ids=<URL>`，导致
    // `ParseFailure(详情为空：ids=…)`（问题 3）。该分支先于站点 key 校验，
    // 对齐 iOS「URL 详情不依赖站点配置」。
    final String trimmedId = vodId.trim();
    if (trimmedId.startsWith('http://') || trimmedId.startsWith('https://')) {
      return _loadViaUrl(trimmedId, initialIndex);
    }

    if (siteKey.trim().isEmpty) {
      return const Err<PlaybackDetail>(ValidationFailure('站点 key 为空'));
    }
    if (trimmedId.isEmpty) {
      return const Err<PlaybackDetail>(ValidationFailure('影片 ID 为空'));
    }

    // S-设3：腾讯视频原生详情（对齐 iOS `SpiderManager.getDetail` step 0，
    // 对非 http id 先走 `TencentVideoNativeSpider.detail`，不走站点解析）。
    if (siteKey == TencentVideoNativeSpider.siteKey) {
      return _loadViaTencentNative(vodId, initialIndex);
    }

    final Result<AllSourcesContainer> sourcesResult = await loadAllSources();
    final Failure? sourcesFailure = sourcesResult.failureOrNull;
    if (sourcesFailure != null) return Err<PlaybackDetail>(sourcesFailure);
    final AllSourcesContainer? container = sourcesResult.valueOrNull;
    if (container == null) {
      return const Err<PlaybackDetail>(UnknownFailure('站点聚合为空'));
    }

    final SiteConfig? site = await _resolveSite(container, siteKey);
    if (site == null) {
      return Err<PlaybackDetail>(ValidationFailure('未找到站点：$siteKey'));
    }

    switch (site.resolveSiteMode()) {
      case SiteMode.apiEndpoint:
        return _loadViaCms(site, vodId, initialIndex);
      case SiteMode.zhanyuan:
        return _loadViaZhanyuan(site, vodId, initialIndex);
      case SiteMode.node:
      case SiteMode.jsSpider:
      case SiteMode.pythonSpider:
        return _loadViaSpider(site, vodId, initialIndex);
      case SiteMode.unsupported:
        return Err<PlaybackDetail>(
          UnsupportedFailure('站点「${site.name}」模式不支持（.jar / 未知类型）'),
        );
    }
  }

  /// 站点解析：allSources 优先；未命中时回退兜底切片源（`fallback_<host>` 合成
  /// key，Wave D），对齐 iOS「兜底源结果可直接进详情」。
  Future<SiteConfig?> _resolveSite(
    AllSourcesContainer container,
    String siteKey,
  ) async {
    final SiteConfig? found = AllSourcesDatasource.findSite(container, siteKey);
    if (found != null) return found;
    final Future<SiteConfig?> Function(String key)? resolver = _fallbackSiteResolver;
    if (resolver == null) return null;
    return resolver(siteKey);
  }

  /// 解析单集实际播放地址。
  ///
  /// - 直链媒体 → 原地址返回（免二次解析）；
  /// - API/站源站点 → 地址即播放地址（CMS 已归一）；
  /// - 脚本引擎站点 → `playerContent` 二次解析（对齐契约 §3.5）；
  /// - 兜底：结果仍为**非直链**时，依次尝试用户自定义解析器
  ///   （对齐 iOS `PlayerViewsV2` L5552-L5581）。
  Future<Result<PlayerContentResult>> resolvePlayUrl({
    required PlaybackDetail detail,
    required PlaybackEpisode episode,
  }) async {
    final Result<PlayerContentResult> primary =
        await _resolvePlayUrlCore(detail: detail, episode: episode);
    // 解析链顺序（对齐 iOS「解析器优先，WebView 嗅探兜底」）：
    //   ① 用户/远程自定义解析器（O-源2）→ ② 内置网页嗅探（本次接入）。
    final Result<PlayerContentResult> parsed = await _applyCustomParser(primary);
    return _applyWebPageSniff(parsed);
  }

  /// 内置网页嗅探兜底：customParser 未命中且地址仍为网页播放页时，
  /// 抓取/渲染页面提取真实媒体直链（对齐 iOS WKWebView 嗅探语义，
  /// 修复「网页 URL 直喂内核报 PARSING_CONTAINER_UNSUPPORTED」）。
  /// 未命中回落原地址（保留原有错误展示，不掩盖真实失败）。
  Future<Result<PlayerContentResult>> _applyWebPageSniff(
    Result<PlayerContentResult> result,
  ) async {
    final Future<String?> Function(String pageUrl)? sniff = _webPageSniffer;
    final PlayerContentResult? value = result.valueOrNull;
    if (sniff == null || value == null) return result;
    // 与播放器实际打开口径一致（detail_page._firstUrl：url > urls > playUrl），
    // 否则会出现「嗅探了 A、播放器打开的是 B」的错位。
    final String candidate = <String?>[
      value.url,
      (value.urls != null && value.urls!.isNotEmpty) ? value.urls!.first : null,
      value.playUrl,
    ].firstWhere((String? s) => s != null && s.trim().isNotEmpty,
        orElse: () => null)?.trim() ??
        '';
    if (candidate.isEmpty) return result;
    // 直链 / 解析器已标记 jx=1 的地址 → 免嗅探（对齐 iOS「直链优先」）。
    if (PlaybackUrlParser.looksDirectMedia(candidate)) return result;
    try {
      final String? direct = await sniff(candidate);
      if (direct == null || direct.trim().isEmpty) return result;
      AppLog.debug(logTag, '网页嗅探命中直链：${_short(direct)}');
      return Success<PlayerContentResult>(PlayerContentResult(
        parse: 0,
        playUrl: value.playUrl,
        url: direct.trim(),
        header: value.header,
      ));
    } catch (e) {
      AppLog.warn(logTag, '网页嗅探失败，回落原地址', error: e);
      return result;
    }
  }

  /// 自定义解析器兜底：仅当结果地址非直链媒体时尝试；命中替换，未命中原样返回。
  Future<Result<PlayerContentResult>> _applyCustomParser(
    Result<PlayerContentResult> result,
  ) async {
    final Future<String?> Function(String rawUrl)? parse = _customParser;
    final PlayerContentResult? value = result.valueOrNull;
    if (parse == null || value == null) return result;
    final String candidate = (value.playUrl?.trim().isNotEmpty ?? false)
        ? value.playUrl!.trim()
        : (value.url ?? '').trim();
    if (candidate.isEmpty) return result;
    // 已是媒体直链 → 免解析（对齐 iOS「直链优先」）。
    if (PlaybackUrlParser.looksDirectMedia(candidate)) return result;
    try {
      final String? parsed = await parse(candidate);
      if (parsed == null || parsed.trim().isEmpty) return result;
      AppLog.debug(logTag, '自定义解析器命中：${_short(parsed)}');
      return Success<PlayerContentResult>(PlayerContentResult(
        parse: 0,
        playUrl: value.playUrl,
        url: parsed.trim(),
        header: value.header,
      ));
    } catch (e) {
      AppLog.warn(logTag, '自定义解析器解析失败，回落原地址', error: e);
      return result;
    }
  }

  /// 日志用短地址。
  static String _short(String url) =>
      url.length <= 60 ? url : '${url.substring(0, 60)}…';

  /// 主解析链路（不含自定义解析器兜底）。
  Future<Result<PlayerContentResult>> _resolvePlayUrlCore({
    required PlaybackDetail detail,
    required PlaybackEpisode episode,
  }) async {
    if (episode.isDirectMedia) {
      return Success<PlayerContentResult>(PlayerContentResult(url: episode.url));
    }

    final SiteMode mode = detail.site.resolveSiteMode();
    if (mode == SiteMode.apiEndpoint || mode == SiteMode.zhanyuan) {
      return Success<PlayerContentResult>(PlayerContentResult(url: episode.url));
    }

    final SpiderEngineType engineType = _effectiveEngineType(detail.site);
    final SpiderEngine engine;
    try {
      engine = _createEngine(detail.site, engineType);
    } catch (e) {
      return Err<PlayerContentResult>(_asFailure(e));
    }

    try {
      await _prepareEngine(engine, detail.site, engineType);
      final String flag =
          episode.from ?? (detail.froms.isNotEmpty ? detail.froms.first : '');
      final PlayerContentResult playerResult =
          await engine.callPlayerContent(detail.vod.vodId, flag, episode.url);
      return Success<PlayerContentResult>(playerResult);
    } catch (e) {
      return Err<PlayerContentResult>(_asFailure(e));
    } finally {
      await engine.dispose();
    }
  }

  // ─────────────── 内部：URL 详情（网盘 / 站源详情页） ───────────────

  /// `ids` 为 HTTP(S) URL 的详情解析（对齐 iOS `SpiderManager.getDetail` step 0）。
  Future<Result<PlaybackDetail>> _loadViaUrl(String url, int initialIndex) async {
    // ① 命中站源（type=2）域名 → 站源详情（对齐 iOS `findZhanyuanSiteForURL`）。
    final Result<AllSourcesContainer> sourcesResult = await loadAllSources();
    final AllSourcesContainer? container = sourcesResult.valueOrNull;
    if (container != null) {
      final SiteConfig? zhanyuanSite = _matchZhanyuanSite(container, url);
      if (zhanyuanSite != null) {
        return _loadViaZhanyuan(zhanyuanSite, url, initialIndex);
      }
    }
    // ② 否则按网盘详情页解析（对齐 iOS `resolveCloudPlay`）。
    return _loadViaCloudPage(url, initialIndex, container);
  }

  /// 按 URL host 匹配站源（type=2）站点（对齐 iOS `findZhanyuanSiteForURL`）。
  SiteConfig? _matchZhanyuanSite(AllSourcesContainer container, String url) {
    final String host = Uri.tryParse(url)?.host ?? '';
    if (host.isEmpty) return null;
    for (final Map<String, Object?> raw in container.sites) {
      final SiteConfig site = SiteConfig.fromJson(raw);
      if (site.type != 2) continue;
      final String api = site.api ?? '';
      if (api.isEmpty) continue;
      final String apiHost = Uri.tryParse(api)?.host ?? '';
      if (apiHost.isNotEmpty && apiHost == host) return site;
    }
    return null;
  }

  /// 网盘详情页解析（对齐 iOS `SpiderManager.resolveCloudPlay` L3761-L3816 +
  /// `parseCloudHTML` L4089-L4170）：
  ///   ① 30min 解析缓存（`cloudPlayCache`）；
  ///   ② 匹配网盘站（`detailBase` 前缀）取追加域名白名单；
  ///   ③ 直通：URL 本身即网盘分享链接（**抓页之前**判定，对齐 L3775）；
  ///   ④ binhd 专线（L3783 → `resolveBinhdCloudPlay`）；
  ///   ⑤ 抓页 → 提取网盘分享链接 → 合成「☁️网盘」详情条目。
  Future<Result<PlaybackDetail>> _loadViaCloudPage(
    String url,
    int initialIndex,
    AllSourcesContainer? container,
  ) async {
    final HttpClient? client = _cloudHttpClient;
    if (client == null) {
      return const Err<PlaybackDetail>(
        UnsupportedFailure('网盘详情页解析未接线（需注入 HttpClient）'),
      );
    }
    final Uri? uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) {
      return Err<PlaybackDetail>(ValidationFailure('详情页地址非法：$url'));
    }

    // ① 命中缓存直接返回（对齐 iOS L3763-3766）。
    final _CloudPlayResult? cached = _cachedCloudPlay(url);
    if (cached != null) {
      return _buildCloudDetail(
        url: url,
        host: uri.host,
        name: cached.siteName,
        links: cached.links,
        initialIndex: initialIndex,
      );
    }

    // ② 匹配网盘站（对齐 iOS L3769-3772：`detailURL.hasPrefix(detailBase)`）。
    CloudSiteConfig? cloudSite;
    for (final CloudSiteConfig s
        in container?.cloudSites ?? const <CloudSiteConfig>[]) {
      if (url.startsWith(s.detailBase)) {
        cloudSite = s;
        break;
      }
    }

    // ③ 直通：URL 本身就是网盘分享链接（论坛搜索结果；对齐 iOS L3775-3780，
    //    在抓页**之前**判定，免去对分享页的无效抓取）。
    if (_isCloudDriveLink(url, cloudSite?.extraPanHosts)) {
      final List<(String, String)> links = <(String, String)>[
        (url, _cloudDriveName(url, cloudSite?.extraPanNames)),
      ];
      _cacheCloudPlay(url, links, '云盘直链');
      return _buildCloudDetail(
        url: url,
        host: uri.host,
        name: '云盘直链',
        links: links,
        initialIndex: initialIndex,
      );
    }

    // ④ binhd 专线（对齐 iOS L3783-3787 → `resolveBinhdCloudPlay`）。
    if (url.contains('binhd.com')) {
      final ({List<(String, String)> links, String siteName})? binhd =
          await _resolveBinhdCloudPage(url, client);
      if (binhd != null) {
        _cacheCloudPlay(url, binhd.links, binhd.siteName);
        return _buildCloudDetail(
          url: url,
          host: uri.host,
          name: binhd.siteName,
          links: binhd.links,
          initialIndex: initialIndex,
        );
      }
      return Err<PlaybackDetail>(ParseFailure('网盘详情页解析失败：$url'));
    }

    // ⑤ 抓页（对齐 iOS L3789-L3811：10s 超时、PC UA，失败即终止）。
    final String html;
    try {
      final HttpClientResponse res = await client.get(
        uri,
        headers: <String, String>{
          'User-Agent': _cloudPcUserAgent,
          'Accept-Encoding': 'gzip, deflate',
        },
      );
      if (!res.isOk) {
        return Err<PlaybackDetail>(
          NetworkFailure(
            'HTTP ${res.statusCode}：$url',
            code: ErrorCode.httpStatus,
          ),
        );
      }
      html = res.text;
    } catch (e) {
      return Err<PlaybackDetail>(Failure.from(e));
    }

    if (html.trim().isEmpty) {
      return Err<PlaybackDetail>(ParseFailure('详情页内容为空：$url'));
    }

    final List<(String, String)> links = _extractCloudLinks(html, cloudSite);
    if (links.isEmpty) {
      return Err<PlaybackDetail>(ParseFailure('未在该页面找到网盘链接：$url'));
    }

    final String name = _extractCloudPageName(html);
    final String siteName = name.isEmpty ? '网盘资源' : name;
    _cacheCloudPlay(url, links, siteName);
    return _buildCloudDetail(
      url: url,
      host: uri.host,
      name: siteName,
      links: links,
      initialIndex: initialIndex,
    );
  }

  /// 读取网盘解析缓存（对齐 iOS L3763：未过期且非空才命中）。
  _CloudPlayResult? _cachedCloudPlay(String url) {
    final _CloudPlayResult? v = _cloudPlayCache[url];
    if (v == null || !v.expiresAt.isAfter(DateTime.now()) || v.links.isEmpty) {
      return null;
    }
    return v;
  }

  /// 清空网盘解析缓存（对齐 iOS `SpiderManager.clearCloudPlayCache`
  /// L4012-L4015：设置页「清除缓存」确认后调用）。
  void clearCloudPlayCache() => _cloudPlayCache.clear();

  /// 写入网盘解析缓存（对齐 iOS `cacheCloudPlay` L4004-L4010：30min TTL，
  /// 超 100 条时仅清理过期项）。
  void _cacheCloudPlay(String url, List<(String, String)> links, String siteName) {
    _cloudPlayCache[url] = _CloudPlayResult(
      links: links,
      siteName: siteName,
      expiresAt: DateTime.now().add(_cloudPlayCacheTtl),
    );
    if (_cloudPlayCache.length > 100) {
      final DateTime now = DateTime.now();
      _cloudPlayCache.removeWhere(
        (_, _CloudPlayResult v) => !v.expiresAt.isAfter(now),
      );
    }
  }

  /// binhd 详情页解析（对齐 iOS `resolveBinhdCloudPlay` L3820-L3968）：
  /// 详情 HTML（取 csrftoken + 站名）→ 非隐藏下载卡片 → POST copy API →
  /// 从 `copy_text` 提取网盘分享链接。失败（需登录 / 无链接）返回 null。
  Future<({List<(String, String)> links, String siteName})?>
      _resolveBinhdCloudPage(String url, HttpClient client) async {
    final Uri? uri = Uri.tryParse(url);
    if (uri == null) return null;

    // 1. 抓详情页 HTML（对齐 L3825-L3849：10s 超时 / PC UA / Accept html）。
    final HttpClientResponse res;
    try {
      res = await client.get(
        uri,
        headers: <String, String>{
          'User-Agent': _cloudPcUserAgent,
          'Accept': 'text/html',
        },
      );
    } catch (e) {
      AppLog.warn(logTag, 'binhd 详情页抓取失败', error: e);
      return null;
    }
    if (!res.isOk) return null;
    final String html = res.text;
    if (html.trim().isEmpty) return null;

    // csrftoken：Set-Cookie 优先（L3839-L3847），表单兜底（L3863-L3869）。
    String csrfToken =
        _firstMatch(r'csrftoken=([^;,\s]+)', res.headers['set-cookie'] ?? '') ??
            '';
    if (csrfToken.isEmpty) {
      csrfToken = _firstMatch(
            r'csrfmiddlewaretoken[^>]*value="([^"]+)"',
            html,
          ) ??
          '';
    }

    // 站名：<title> 去 ` - 云集…` 后缀（对齐 L3852-L3860）。
    String siteName = '云集';
    final String? title =
        _firstMatch(r'<title>([^<]+)', html, caseInsensitive: true);
    if (title != null && title.trim().isNotEmpty) {
      final String stripped =
          title.trim().replaceFirst(RegExp(r'- 云集.*$'), '').trim();
      if (stripped.isNotEmpty) siteName = stripped;
    }

    // 2. 非隐藏下载卡片（对齐 L3876-L3903；dotAll 对应 dotMatchesLineSeparators）。
    final RegExp? cardRe = _safeRegex(
      r'<article class="resource-download-card[^"]*">(.*?)</article>',
      caseInsensitive: true,
      dotAll: true,
    );
    if (cardRe == null) return null;
    final RegExp? copyRe = _safeRegex(r'data-resource-copy-url="([^"]+)"');
    final RegExp? providerRe =
        _safeRegex(r'resource-download-card__provider">([^<]+)<');
    if (copyRe == null || providerRe == null) return null;

    final List<(String, String)> links = <(String, String)>[];
    for (final RegExpMatch cardMatch in cardRe.allMatches(html)) {
      final String cardHtml = cardMatch.group(0) ?? '';
      // 跳过隐藏卡片（需登录，L3887）。
      if (cardHtml.contains('resource-download-card--hidden') ||
          cardHtml.contains('登录后可见')) {
        continue;
      }
      final String? copyPath = copyRe.firstMatch(cardHtml)?.group(1);
      if (copyPath == null || copyPath.isEmpty) continue;
      final String copyURL =
          copyPath.startsWith('http') ? copyPath : 'https://binhd.com$copyPath';
      final String providerName =
          providerRe.firstMatch(cardHtml)?.group(1)?.trim() ?? '网盘链接';

      // 3. POST copy API 取真实链接（对齐 L3906-L3917 的请求头约定）。
      try {
        final HttpClientResponse copy = await client.send(
          'POST',
          Uri.parse(copyURL),
          headers: <String, String>{
            'User-Agent': _cloudPcUserAgent,
            'Accept': 'application/json',
            'X-Requested-With': 'XMLHttpRequest',
            'Referer': url,
            if (csrfToken.isNotEmpty) 'X-CSRFToken': csrfToken,
            'Cookie': 'csrftoken=$csrfToken',
          },
        );
        if (!copy.isOk) continue;
        final Object? decoded = jsonDecode(copy.text);
        if (decoded is! Map<String, Object?>) continue;
        final Object? copyText = decoded['copy_text'];
        if (copyText is! String || copyText.isEmpty) continue;

        // 从 copy_text 提取网盘链接（对齐 L3927-L3949：首个命中即止；
        // iOS 正则无捕获组，取整段匹配）。
        for (final (String pattern, String driveName) in _binhdPanPatterns) {
          final RegExp? re = _safeRegex(pattern, caseInsensitive: true);
          final String? link = re?.firstMatch(copyText)?.group(0);
          if (link == null || link.isEmpty) continue;
          links.add((
            _enrichTianyiAccessCode(link, copyText),
            providerName.isEmpty ? driveName : providerName,
          ));
          break;
        }
      } catch (e) {
        AppLog.warn(logTag, 'binhd copy API 失败，跳过该卡片', error: e);
      }
    }

    if (links.isEmpty) {
      AppLog.warn(logTag, 'binhd 未找到可用的网盘链接（可能需要登录）');
      return null;
    }
    return (links: links, siteName: siteName);
  }

  /// 合成网盘详情条目（`vod_play_from` = 网盘；剧集 = 各网盘链接）。
  ///
  /// 剧集地址采用 TVBox `name$url#…` 口径，详情页 `_play()` 依据
  /// `CloudDriveType.fromShareUrl` 识别为网盘链接 → 打开网盘文件列表。
  Result<PlaybackDetail> _buildCloudDetail({
    required String url,
    required String host,
    required String name,
    required List<(String url, String name)> links,
    required int initialIndex,
  }) {
    final SiteConfig site = SiteConfig(
      key: 'cloud_$host',
      name: '网盘',
      type: 0,
      api: url,
      group: 'cloud',
    );
    final String playUrl = links
        .map(((String, String) e) => '${e.$2}\$${e.$1}')
        .join('#');
    final VodItem vod = VodItem(
      vodId: url,
      vodName: name,
      vodPic: '',
      vodRemarks: '☁️网盘',
      vodPlayFrom: '网盘',
      vodPlayUrl: playUrl,
    );
    return Success<PlaybackDetail>(
      PlaybackDetail.fromVod(site: site, vod: vod, initialIndex: initialIndex),
    );
  }

  /// PC 浏览器 UA（对齐 iOS `cloudPcUA`）。
  static const String _cloudPcUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

  /// 判定 URL 是否为网盘分享链接（对齐 iOS `isCloudDriveLink` L3971-L3983：
  /// 固定标记 + 远程配置追加域名白名单）。
  bool _isCloudDriveLink(String url, List<String>? extraHosts) {
    for (final String marker in _cloudLinkMarkers) {
      if (url.contains(marker)) return true;
    }
    return extraHosts?.any(url.contains) ?? false;
  }

  /// URL → 网盘显示名（对齐 iOS `cloudDriveName` L3986-L4002）。
  String _cloudDriveName(String url, Map<String, String>? extraNames) {
    if (url.contains('pan.quark.cn')) return '夸克网盘';
    if (url.contains('115cdn.com')) return '115网盘';
    if (url.contains('aliyundrive.com') || url.contains('alipan.com')) {
      return '阿里云盘';
    }
    if (url.contains('pan.baidu.com')) return '百度网盘';
    if (url.contains('drive.uc.cn') || url.contains('pan.uc.cn')) {
      return 'UC网盘';
    }
    if (url.contains('cloud.189.cn')) return '天翼云盘';
    if (url.contains('yun.139.com')) return '139云盘';
    if (url.contains('www.123') && url.contains('/s/')) return '123云盘';
    if (extraNames != null) {
      for (final MapEntry<String, String> e in extraNames.entries) {
        if (url.contains(e.key)) return e.value;
      }
    }
    return '网盘链接';
  }

  /// 网盘分享链接判定标记（对齐 iOS `isCloudDriveLink` 的 `patterns`）。
  static const List<String> _cloudLinkMarkers = <String>[
    'pan.quark.cn/s/',
    '115cdn.com/s/',
    'aliyundrive.com/s/',
    'alipan.com/s/',
    'pan.baidu.com/s/',
    'drive.uc.cn/s/',
    'pan.uc.cn/s/',
    'cloud.189.cn/',
    'yun.139.com/',
    'www.123',
    '.com/s/',
  ];

  /// binhd `copy_text` 网盘链接正则（对齐 iOS `resolveBinhdCloudPlay`
  /// L3927-L3937，含迅雷；首个命中即止）。
  static const List<(String, String)> _binhdPanPatterns = <(String, String)>[
    ("https?://pan\\.quark\\.cn/s/[^\\s\"<>\\x27]+", '夸克网盘'),
    ("https?://pan\\.baidu\\.com/s/[^\\s\"<>\\x27]+", '百度网盘'),
    ("https?://(?:www\\.)?(?:aliyundrive\\.com|alipan\\.com)/s/[^\\s\"<>\\x27]+",
        '阿里云盘'),
    ("https?://pan\\.xunlei\\.com/s/[^\\s\"<>\\x27]+", '迅雷网盘'),
    ("https?://115cdn\\.com/s/[^\\s\"<>\\x27]+", '115网盘'),
    ("https?://(?:drive|pan)\\.uc\\.cn/s/[^\\s\"<>\\x27]+", 'UC网盘'),
    ("https?://cloud\\.189\\.cn/[^\\s\"<>\\x27]+", '天翼云盘'),
    ("https?://yun\\.139\\.com/[^\\s\"<>\\x27]+", '139云盘'),
    ("https?://www\\.123[a-z0-9]+\\.com/s/[a-zA-Z0-9\\-]+", '123云盘'),
  ];

  /// 网盘解析缓存 TTL（对齐 iOS `cacheCloudPlay` 的 30 分钟）。
  static const Duration _cloudPlayCacheTtl = Duration(minutes: 30);

  /// 网盘分享链接正则清单（对齐 iOS `parseCloudHTML` 的 `panPatterns`，
  /// 含 139 分享页模式 L4113）。
  static const List<(String, String)> _cloudLinkPatterns = <(String, String)>[
    (r'(https?://115cdn\.com/s/[^\s"<>\x27\\]*)', '115网盘'),
    (r'(https?://(?:www\.)?(?:aliyundrive\.com|alipan\.com)/s/[^\s"<>\x27\\]*)',
        '阿里云盘'),
    (r'(https?://pan\.quark\.cn/s/[^\s"<>\x27\\]*)', '夸克网盘'),
    (r'(https?://pan\.baidu\.com/s/[^\s"<>\x27\\]*)', '百度网盘'),
    (r'(https?://(?:drive|pan)\.uc\.cn/s/[^\s"<>\x27\\]*)', 'UC网盘'),
    (r'(https?://cloud\.189\.cn/[^\s"<>\x27\\]*)', '天翼云盘'),
    (r'(https?://yun\.139\.com/[^\s"<>\x27\\]*)', '139云盘'),
    (r'(https?://yun\.139\.com/share(?:web|wap)/#/[wm]/i[/?][^\s"<>\x27\\]*)',
        '139云盘分享'),
    (r'(https?://www\.123[a-z0-9]+\.com/s/[a-zA-Z0-9\-]+)', '123云盘'),
  ];

  /// 画质标签（用于网盘链接描述前缀；对齐 iOS `parseCloudHTML`）。
  static final RegExp _qualityRegex = RegExp(
    r'(4K|1080[Pp]|720[Pp]|蓝光|高清|国语|粤语|中字|原盘|REMUX|HDR|60帧|DV)',
  );

  /// 从详情页 HTML 提取网盘分享链接（去重；对齐 iOS `parseCloudHTML`：
  /// 固定 9 模式 + 网盘站 `extraPanHosts` 追加模式，域名 → 显示名取
  /// `extraPanNames`，缺省「网盘链接」，对齐 L4116-L4123）。
  List<(String, String)> _extractCloudLinks(String html, CloudSiteConfig? site) {
    final List<(String, String)> patterns =
        List<(String, String)>.of(_cloudLinkPatterns);
    if (site != null) {
      for (final String host in site.extraPanHosts) {
        String name = '网盘链接';
        for (final MapEntry<String, String> e in site.extraPanNames.entries) {
          if (host.contains(e.key)) {
            name = e.value;
            break;
          }
        }
        patterns.add(
          ('(https?://${RegExp.escape(host)}[^\\s"<>\\x27\\\\]*)', name),
        );
      }
    }
    final List<(String, String)> out = <(String, String)>[];
    final Set<String> seen = <String>{};
    for (final (String pattern, String driveName) in patterns) {
      final RegExp? re = _safeRegex(pattern, caseInsensitive: true);
      if (re == null) continue;
      for (final RegExpMatch m in re.allMatches(html)) {
        String? panUrl = m.group(1);
        if (panUrl == null || panUrl.isEmpty) continue;
        if (panUrl.contains('cloud.189.cn')) {
          panUrl = _enrichTianyiAccessCode(
            panUrl,
            _snippet(html, m.start - 400, m.start + 200),
          );
        }
        if (!seen.add(panUrl)) continue;
        String desc = driveName;
        // 链接周围上下文里的画质标签（对齐 iOS ±60/80 窗口扫描）。
        final String around = _snippet(html, m.start - 60, m.start + 80);
        final String? quality = _qualityRegex.firstMatch(around)?.group(1);
        if (quality != null && quality.isNotEmpty) {
          desc = '$quality·$driveName';
        }
        out.add((panUrl, desc));
      }
    }
    return out;
  }

  /// 详情页视频名（优先 `h1.page-title`，其次 `<title>`；对齐 iOS `parseCloudHTML`）。
  String _extractCloudPageName(String html) {
    final String? h1 = _safeRegex(
      r'<h1[^>]*class="[^"]*page-title[^"]*"[^>]*>([^<]+)',
    )?.firstMatch(html)?.group(1)?.trim();
    if (h1 != null && h1.isNotEmpty) return h1;
    final String? title =
        _safeRegex(r'<title>([^<]+)', caseInsensitive: true)
            ?.firstMatch(html)
            ?.group(1)
            ?.trim();
    if (title == null || title.isEmpty) return '';
    // 去掉 ` - 站点名` 后缀（对齐 iOS `-.*$` 截断）。
    final int dash = title.indexOf(RegExp(r'\s*[-|–]\s*'));
    return dash > 0 ? title.substring(0, dash).trim() : title;
  }

  /// 天翼云盘访问码补全（对齐 iOS `enrichTianyiAccessCode`）。
  String _enrichTianyiAccessCode(String url, String context) {
    if (!url.contains('cloud.189.cn')) return url;
    if (RegExp(r'[?&]pwd=[A-Za-z0-9]{4,}').hasMatch(url) ||
        RegExp(r'[?&]accessCode=[A-Za-z0-9]{4,}').hasMatch(url)) {
      return url;
    }
    final RegExpMatch? m =
        RegExp(r'(访问码|提取码|密码)[:：\s]*([A-Za-z0-9]{4,8})').firstMatch(context);
    if (m == null) return url;
    final String code = (m.group(2) ?? '').trim();
    if (code.isEmpty) return url;
    final int hash = url.indexOf('#');
    if (hash >= 0) {
      final String head = url.substring(0, hash);
      final String tail = url.substring(hash);
      final String sep = head.contains('?') ? '&' : '?';
      return '$head${sep}pwd=$code$tail';
    }
    return url.contains('?') ? '$url&pwd=$code' : '$url?pwd=$code';
  }

  /// 取 [src] 的 `[start, end)` 片段（UTF-16 索引，与 `RegExpMatch.start` 同口径）。
  String _snippet(String src, int start, int end) {
    final int s = start < 0 ? 0 : start;
    final int e = end > src.length ? src.length : end;
    if (s >= e) return '';
    return src.substring(s, e);
  }

  RegExp? _safeRegex(String pattern, {bool caseInsensitive = false, bool dotAll = false}) {
    try {
      return RegExp(
        pattern,
        caseSensitive: !caseInsensitive,
        dotAll: dotAll,
      );
    } catch (_) {
      return null;
    }
  }

  /// 取正则首个匹配的捕获组 1（无匹配返回 null）。
  String? _firstMatch(
    String pattern,
    String input, {
    bool caseInsensitive = false,
  }) =>
      _safeRegex(pattern, caseInsensitive: caseInsensitive)
          ?.firstMatch(input)
          ?.group(1);

  // ─────────────── 内部：Spider 引擎路径 ───────────────

  /// 腾讯视频原生详情（S-设3）。
  Future<Result<PlaybackDetail>> _loadViaTencentNative(
    String vodId,
    int initialIndex,
  ) async {
    final TencentVideoNativeSpider? spider = _tencentSpider;
    if (spider == null) {
      return const Err<PlaybackDetail>(
        UnsupportedFailure('腾讯视频原生蜘蛛未接线（需注入 TencentVideoNativeSpider）'),
      );
    }
    try {
      final VodItem? item = await spider.detail(vodId);
      if (item == null) {
        return Err<PlaybackDetail>(ParseFailure('腾讯原生详情为空：$vodId'));
      }
      return Success<PlaybackDetail>(
        PlaybackDetail.fromVod(
          site: _tencentSite,
          vod: item,
          initialIndex: initialIndex,
        ),
      );
    } catch (e) {
      return Err<PlaybackDetail>(_asFailure(e));
    }
  }

  /// 占源（type=2）详情：走 [ZhanyuanSearchService.fetchDetail]（HTML/XPath），
  /// 对齐 iOS `SpiderManager.getDetail` 的 zhanyuan 分支。
  Future<Result<PlaybackDetail>> _loadViaZhanyuan(
    SiteConfig site,
    String vodId,
    int initialIndex,
  ) async {
    final Zhanyuan? z = zhanyuanFromSiteConfig(site);
    if (z == null) {
      return Err<PlaybackDetail>(
        ValidationFailure('站源「${site.name}」配置不完整（缺少 searchUrl）'),
      );
    }
    try {
      final VodItem item = await _zhanyuanService.fetchDetail(vodId, z);
      return Success<PlaybackDetail>(
        PlaybackDetail.fromVod(
          site: site,
          vod: item,
          initialIndex: initialIndex,
        ),
      );
    } catch (e) {
      return Err<PlaybackDetail>(_asFailure(e));
    }
  }

  Future<Result<PlaybackDetail>> _loadViaSpider(
    SiteConfig site,
    String vodId,
    int initialIndex,
  ) async {
    final SpiderEngineType engineType = _effectiveEngineType(site);
    final SpiderEngine engine;
    try {
      engine = _createEngine(site, engineType);
    } catch (e) {
      return Err<PlaybackDetail>(_asFailure(e));
    }

    try {
      await _prepareEngine(engine, site, engineType);
      final DetailContentResult detail = await engine.callDetailContent(vodId);
      final List<VodItem> list = detail.list ?? const <VodItem>[];
      if (list.isEmpty) {
        return Err<PlaybackDetail>(ParseFailure('详情为空：$vodId'));
      }
      return Success<PlaybackDetail>(
        PlaybackDetail.fromVod(
          site: site,
          vod: list.first,
          initialIndex: initialIndex,
        ),
      );
    } catch (e) {
      return Err<PlaybackDetail>(_asFailure(e));
    } finally {
      await engine.dispose();
    }
  }

  /// 创建引擎（工厂异常 → 上抛由调用方归一）。
  SpiderEngine _createEngine(SiteConfig site, SpiderEngineType engineType) =>
      _engineFactory.create(
        engineType,
        siteKey: site.key,
        baseUrl: site.api,
        nodeClient: _nodeClient,
        quickJsBridge: _quickJsBridge,
      );

  /// 准备引擎：脚本引擎先加载脚本（Node 桥 no-op），再注册蜘蛛。
  ///
  /// ★ cache-first + ext 加载（对齐 iOS `loadSingleRemoteSpider`，SpiderManager.swift
  /// L1362-L1416）：远程同步已把脚本落盘到本地（`downloadAndCacheSpiderJS`），
  /// 此处优先读本地、未命中才回退网络；主脚本后加载 ext 补充 `__JS_SPIDER__`
  /// 注册/请求函数。此前详情链路两者皆缺 → 依赖 ext 的 JS 源详情必然失败。
  Future<void> _prepareEngine(
    SpiderEngine engine,
    SiteConfig site,
    SpiderEngineType engineType,
  ) async {
    if (engineType == SpiderEngineType.quickJS ||
        engineType == SpiderEngineType.python) {
      final String key = site.key.isEmpty ? site.name : site.key;

      // ① 主脚本：cache-first。
      final String? cachedScript = _scriptCache?.read(key);
      if (cachedScript != null) {
        await engine.loadScript(cachedScript);
      } else {
        final String? api = site.api;
        if (api == null || api.trim().isEmpty) {
          throw const ValidationFailure('蜘蛛脚本地址为空');
        }
        final String trimmed = api.trim();
        final bool isUrl =
            trimmed.startsWith('http://') || trimmed.startsWith('https://');
        if (!isUrl) {
          // 相对路径脚本：以 allSources 清单 URL 为 base 解析（对齐 iOS subBaseURL 分支）。
          await engine.loadScriptFromURL(_resolveScriptUrl(trimmed, site));
        } else {
          // G-04：TG 搜索蜘蛛注入用户配置（与 ContentBrowseUseCases 同口径，
          // 对齐 iOS 主脚本前 prepend `var __TG_CONFIG__ = {...};`）。
          if (site.key == _tgSearchSiteKey &&
              engineType == SpiderEngineType.quickJS) {
            final String configJs = TGSearchConfigStore.shared.generateConfigJs();
            if (configJs.isNotEmpty) {
              await engine.loadLibrary(configJs);
            }
          }
          await engine.loadScriptFromURL(trimmed);
        }
      }

      // ② ext 脚本：失败不影响主框架（iOS 同语义）。
      try {
        await _loadSpiderExt(engine, site, key);
      } catch (_) {}
    }
    await engine.registerSpider();
    if (!engine.isSpiderReady) {
      throw const SpiderFailure('蜘蛛注册失败（未找到 __JS_SPIDER__）');
    }
  }

  /// 加载蜘蛛 ext（对齐 iOS `loadSpiderExt`）：本地缓存 → 绝对 URL →
  /// 相对路径（`./x.js` / `x.js`）→ 内联 JS。
  Future<void> _loadSpiderExt(
    SpiderEngine engine,
    SiteConfig site,
    String key,
  ) async {
    final String ext = (site.ext ?? '').trim();
    if (ext.isEmpty) return;

    final String? cachedExt = _scriptCache?.read('${key}_ext');
    if (cachedExt != null) {
      await engine.loadLibrary(cachedExt);
      return;
    }
    if (ext.startsWith('http://') || ext.startsWith('https://')) {
      await engine.loadScriptFromURL(ext);
      return;
    }
    // ★ ext 只认「`./` 前缀」与「`.js` 结尾」——**逐字对齐 iOS**
    //   （SpiderManager.swift L1531）。此前多认的 `.py` 会让 Python 引擎
    //   经 `loadScriptFromURL` 重新 launch，从而顶掉已加载的主蜘蛛脚本
    //   （详见 content_browse_usecases.dart 同处注释），故与 iOS 一致地排除。
    if (ext.startsWith('./') || ext.endsWith('.js')) {
      await engine.loadScriptFromURL(_resolveScriptUrl(ext, site));
      return;
    }
    if (ext.contains('function ') ||
        ext.contains('var ') ||
        ext.contains('let ') ||
        ext.contains('const ')) {
      await engine.loadLibrary(ext);
    }
  }

  /// 解析脚本地址：绝对 http(s) 直接用；相对路径以 [scriptBaseUrl] 为 base。
  String _resolveScriptUrl(String api, SiteConfig site) {
    final String? base = scriptBaseUrl?.call();
    if (base == null || base.trim().isEmpty) {
      throw UnsupportedFailure(
        '本地插件脚本「${site.name}」缺少订阅源基址，无法解析相对路径「$api」',
      );
    }
    final Uri? baseUri = Uri.tryParse(base.trim());
    if (baseUri == null || baseUri.host.isEmpty) {
      throw UnsupportedFailure(
        '本地插件脚本「${site.name}」订阅源基址非法：$base',
      );
    }
    return baseUri.resolve(api).toString();
  }

  /// 引擎类型（jsSpider → QuickJS 顶替 JSC，G-03-B 决策）。
  SpiderEngineType _effectiveEngineType(SiteConfig site) {
    final SpiderEngineType? resolved = site.resolveEngineType();
    if (resolved == null) {
      throw SpiderException(
        SpiderErrorCode.unimplemented,
        '站点「${site.name}」无法解析引擎类型',
      );
    }
    return resolved == SpiderEngineType.javaScriptCore
        ? SpiderEngineType.quickJS
        : resolved;
  }

  // ─────────────── 内部：CMS V10 路径 ───────────────

  Future<Result<PlaybackDetail>> _loadViaCms(
    SiteConfig site,
    String vodId,
    int initialIndex,
  ) async {
    final CmsV10Datasource? cms = _cmsDatasource;
    if (cms == null) {
      return const Err<PlaybackDetail>(
        UnsupportedFailure('API/站源站点需要注入 CMS 数据源'),
      );
    }
    final String? base = site.api;
    if (base == null || base.trim().isEmpty) {
      return Err<PlaybackDetail>(ValidationFailure('站点「${site.name}」缺少 API 地址'));
    }

    final Result<CmsV10Detail> r = await cms.fetchDetail(base, vodId);
    final Failure? failure = r.failureOrNull;
    if (failure != null) return Err<PlaybackDetail>(failure);
    final CmsV10Detail? detail = r.valueOrNull;
    if (detail == null) {
      return const Err<PlaybackDetail>(ParseFailure('CMS 详情为空'));
    }
    return Success<PlaybackDetail>(
      PlaybackDetail.fromVod(
        site: site,
        vod: _toVodItem(detail),
        initialIndex: initialIndex,
      ),
    );
  }

  /// CMS 详情 → Spider `VodItem`（供统一 `PlaybackDetail.fromVod` 复用）。
  VodItem _toVodItem(CmsV10Detail detail) {
    final CmsV10Video v = detail.video;
    return VodItem(
      vodId: v.vodId,
      vodName: v.name,
      vodPic: v.pic,
      vodRemarks: v.remarks.isEmpty ? null : v.remarks,
      vodYear: v.year.isEmpty ? null : v.year,
      vodArea: v.area.isEmpty ? null : v.area,
      vodContent: detail.content.isEmpty ? null : detail.content,
      vodActor: detail.actors.isEmpty ? null : detail.actors,
      vodDirector: detail.director.isEmpty ? null : detail.director,
      vodPlayUrl: v.playUrl.isEmpty ? null : v.playUrl,
    );
  }

  /// 归一失败（`SpiderException` → `SpiderFailure`，其余走 [Failure.from]）。
  Failure _asFailure(Object e) {
    if (e is SpiderException) {
      return SpiderFailure(e.message, cause: e);
    }
    return Failure.from(e);
  }
}

/// 网盘解析缓存条目（对齐 iOS `cloudPlayCache` 的 `(links, siteName, expiresAt)`）。
class _CloudPlayResult {
  _CloudPlayResult({
    required this.links,
    required this.siteName,
    required this.expiresAt,
  });

  /// 分享链接列表（`url`, 显示名）。
  final List<(String, String)> links;

  /// 详情条目名（页面标题 / 「云盘直链」等）。
  final String siteName;

  /// 过期时刻（写入 + 30min）。
  final DateTime expiresAt;
}
