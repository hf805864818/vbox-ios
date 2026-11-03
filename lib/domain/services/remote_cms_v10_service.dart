/// 领域层：远程可配置 CMS V10 福利源服务（UI-C1c）。
///
/// 唯一真相源：iOS `vbox/Services/RemoteCMSV10Service.swift`（L1-L562）
///   · `service(for:)`（L9-L15）：按 `platformKey` 实例缓存（对齐 `NSCache`）；
///   · 内容类型 / 图片防盗链覆写（L26-L36）：`contentType` / `category`
///     判 `comic`；`imageReferer` / `imageSSLBypass` 取平台配置；
///   · `defaultHeaders(host:)`（L43-L61）：JSON 模式 Android UA，
///     图文 HTML 模式 Safari UA + 仅白名单键的站点自定义头；
///   · `apiBase`（L63-L68）：`apiPath`（缺省 `/api.php/provide/vod/`）拼当前域名；
///   · 抓取契约（L70-L162）：`ac=list` 分类 / `ac=detail&t=&pg=` 列表 /
///     `ac=detail&ids=` 详情 / `ac=detail&wd=&pg=` 搜索；
///   · 子分类发现（L232-L290）：`childDiscovery == type_id_1` 时按 `type_id_1`
///     归属筛选；父级分类无数据时聚合子分类（L105-L116）；
///   · 列表项过滤（L300-L317）：`rootTypeId` 归属 + `itemRule.vodPlayUrl`
///     （`required` / `empty`，缺省按内容类型）；
///   · 剧集解析（L363-L379）：`$$$` 线路组 # `$` 名称/地址对；
///   · 漫画套图（L381-L400 + L341-L350）：`comic` / `detailMode == comic_images`
///     → 从 `vod_content` 提取 `<img>`；
///   · 图文 HTML 模式（L164-L212 / L402-L514）：`detailMode == article_html`
///     或 `apiKind == mac_art_html` → 列表 / 详情走 HTML + 正则解析。
///
/// 移植口径与差异登记：
///   · 域名就绪：复用 [ProbedFuliService]（自定义域名在前 + 默认域名逐个探测，
///     对齐 iOS `ensureHostReady()`），首个请求前 `probeHosts()`；
///   · 子分类发现：iOS 用 `TaskGroup` 并发探测，Flutter 顺序探测（请求数更少、
///     结果等价；慢站点耗时略高，属**有意的实现差异**）；
///   · 剧集地址解析：iOS 按 `$` 全量分段取 `parts[1]`（地址内含 `$` 会被截断），
///     Flutter 取首个 `$` 之后全部（更正确，属**有意的行为改进**）；
///   · 请求头：`referer` 由站点默认头携带（`SpiderHttpBridge` 的自定义头优先于默认 UA）。
library;

import 'dart:async';

import '../../core/utils/json_utils.dart';
import '../../platform/spider/spider_http_bridge.dart';
import '../entities/welfare/welfare.dart';
import 'fuli_base_service.dart';
import 'native_fuli_services.dart';

/// 远程可配置 CMS V10 福利源服务（`remote_cms_v10` 路由驱动）。
class RemoteCmsV10FuliService extends ProbedFuliService {
  /// 构造（[bridge] 供测试注入假传输）。
  RemoteCmsV10FuliService({
    required WelfarePlatform platform,
    SpiderHttpBridge? bridge,
  })  : _platform = platform,
        super(
          platformKey: platform.platformKey,
          platformName: platform.name,
          defaultHosts: platform.defaultHosts,
          bridge: bridge ??
              SpiderHttpBridge(
                sslBypass: platform.sslBypass || platform.imageSSLBypass,
              ),
        );

  /// 按 `platformKey` 的实例缓存（对齐 iOS `service(for:)`）。
  static final Map<String, RemoteCmsV10FuliService> _cache =
      <String, RemoteCmsV10FuliService>{};

  /// 按平台取（或创建）服务实例。
  static RemoteCmsV10FuliService serviceFor(
    WelfarePlatform platform, {
    SpiderHttpBridge? bridge,
  }) =>
      _cache.putIfAbsent(
        platform.platformKey,
        () => RemoteCmsV10FuliService(platform: platform, bridge: bridge),
      );

  /// 清空实例缓存（装配重置 / 测试隔离用）。
  static void clearCache() => _cache.clear();

  final WelfarePlatform _platform;

  /// 子分类缓存（对齐 iOS `childCategoryCache`）。
  List<FuliCategory>? _childCategoryCache;

  /// 白名单请求头键（对齐 iOS `isAllowedHeader`）。
  static const Set<String> _allowedHeaderKeys = <String>{
    'user-agent',
    'referer',
    'accept',
    'accept-language',
    'origin',
  };

  // ─────────────── 内容类型 / 图片防盗链（对齐 iOS L26-L36）───────────────

  /// 内容类型：`contentType`（缺省落 `category`）为 `comic` → 漫画套图。
  @override
  FuliContentCategory get contentCategory =>
      (_platform.contentType ?? _platform.category.key).trim().toLowerCase() ==
              'comic'
          ? FuliContentCategory.comic
          : FuliContentCategory.video;

  @override
  String? get imageReferer => _platform.imageReferer;

  @override
  bool get imageSSLBypass => _platform.imageSSLBypass;

  /// 是否图文 HTML 模式（`detailMode == article_html` 或 `apiKind == mac_art_html`）。
  bool get _isArticleHtmlMode {
    final String mode = (_platform.detailMode ?? '').trim().toLowerCase();
    final String kind = (_platform.apiKind ?? '').trim().toLowerCase();
    return mode == 'article_html' || kind == 'mac_art_html';
  }

  /// CMS 接口基地址（`apiPath` 缺省 `/api.php/provide/vod/`；对齐 iOS `apiBase`）。
  String get _apiBase {
    final String path = (_platform.apiPath ?? '').trim();
    final String effective = path.isEmpty ? '/api.php/provide/vod/' : path;
    if (effective.startsWith('http://') || effective.startsWith('https://')) {
      return effective;
    }
    final String normalized = effective.startsWith('/') ? effective : '/$effective';
    return '$currentHost$normalized';
  }

  /// 确保域名已探测（未就绪时探测一次；对齐 iOS `ensureHostReady`）。
  Future<void> ensureHostReady() async {
    if (isHostReady) return;
    await probeHosts();
  }

  // ─────────────── 抓取契约（对齐 iOS L70-L162）───────────────

  @override
  Future<FuliHomeResult> fetchHomeContent() async {
    await ensureHostReady();
    if (_isArticleHtmlMode) return _fetchArticleHome();

    final Map<String, Object?>? json = await _fetchJson('$_apiBase?ac=list');
    if (json == null) return FuliHomeResult.empty;
    final List<FuliCategory> categories = await _parseCategories(json);
    List<FuliVideo> videos = const <FuliVideo>[];
    if (categories.isNotEmpty) {
      videos = (await fetchCategoryContent(category: categories.first, page: 1))
          .videos;
    }
    return FuliHomeResult(categories: categories, videos: videos);
  }

  @override
  Future<FuliCategoryResult> fetchCategoryContent({
    required FuliCategory category,
    FuliCategory? subCategory,
    required int page,
  }) async {
    await ensureHostReady();
    if (_isArticleHtmlMode) {
      return _fetchArticleCategory(
        category: category,
        subCategory: subCategory,
        page: page,
      );
    }

    final String tid = subCategory?.typeId ?? category.typeId;
    final Map<String, Object?>? json =
        await _fetchJson('$_apiBase?ac=detail&t=$tid&pg=$page');
    if (json == null) {
      return FuliCategoryResult(
        videos: const <FuliVideo>[],
        page: page,
        hasMore: false,
      );
    }
    final List<FuliVideo> videos = _parseList(json);
    final String rootId = (_platform.rootTypeId ?? '').trim();
    if (videos.isNotEmpty || subCategory != null || tid != rootId) {
      return FuliCategoryResult(
        videos: videos,
        page: page,
        hasMore: _hasMore(json, videos.length, page),
      );
    }

    // 父级分类本身不返回数据（如艾旦福利图片 t=33）→ 聚合自动发现的子分类。
    final List<FuliCategory> children =
        _childCategoryCache ?? await _ensureChildCategories();
    final List<FuliVideo> merged = <FuliVideo>[];
    bool more = false;
    for (final FuliCategory child in children) {
      final Map<String, Object?>? childJson =
          await _fetchJson('$_apiBase?ac=detail&t=${child.typeId}&pg=$page');
      if (childJson == null) continue;
      final List<FuliVideo> childVideos = _parseList(childJson);
      merged.addAll(childVideos);
      more = more || _hasMore(childJson, childVideos.length, page);
      if (merged.length >= 80) break;
    }
    return FuliCategoryResult(videos: merged, page: page, hasMore: more);
  }

  @override
  Future<FuliDetail> fetchDetail(String vodId) async {
    await ensureHostReady();
    if (_isArticleHtmlMode) return _fetchArticleDetail(vodId);

    final Map<String, Object?>? json =
        await _fetchJson('$_apiBase?ac=detail&ids=$vodId');
    if (json == null) return _emptyDetail(vodId);
    final List<Map<String, Object?>> list = JsonUtils.asMapList(json['list']);
    if (list.isEmpty) return _emptyDetail(vodId);
    return _parseDetail(list.first) ?? _emptyDetail(vodId);
  }

  @override
  Future<FuliSearchResult> fetchSearch({
    required String keyword,
    required int page,
  }) async {
    await ensureHostReady();
    if (_isArticleHtmlMode) {
      return FuliSearchResult(
        videos: const <FuliVideo>[],
        page: page,
        hasMore: false,
      );
    }
    final String encoded = Uri.encodeQueryComponent(keyword);
    final Map<String, Object?>? json =
        await _fetchJson('$_apiBase?ac=detail&wd=$encoded&pg=$page');
    if (json == null) {
      return FuliSearchResult(
        videos: const <FuliVideo>[],
        page: page,
        hasMore: false,
      );
    }
    final List<FuliVideo> videos = _parseList(json);
    return FuliSearchResult(
      videos: videos,
      page: page,
      hasMore: _hasMore(json, videos.length, page),
    );
  }

  @override
  Future<FuliPlayerResult> fetchPlayerURL(FuliEpisode episode) async {
    final String url = episode.url;
    final bool direct = url.contains('.m3u8') ||
        url.contains('.mp4') ||
        url.contains('.ts');
    return FuliPlayerResult(
      url: url,
      headers: _defaultHeaders(),
      parse: direct ? 0 : 1,
    );
  }

  // ─────────────── 请求（对齐 iOS `fetchJSON` / `fetchHTML` + `defaultHeaders`）───

  /// 站点默认请求头（JSON：Android UA；图文：Safari UA + 白名单自定义头）。
  Map<String, String> _defaultHeaders() {
    final bool article = _isArticleHtmlMode;
    final String host = currentHost;
    final Map<String, String> headers = <String, String>{
      'User-Agent': article
          ? 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
              'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 '
              'Mobile/15E148 Safari/604.1'
          : 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
              'Chrome/104.0.5112.97 Mobile Safari/537.36',
      'Accept': article
          ? 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
          : 'application/json,text/plain,*/*',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      'Referer': host.isEmpty
          ? ''
          : (host.endsWith('/') ? host : '$host/'),
    }..removeWhere((String key, String v) => v.isEmpty);

    _platform.headers.forEach((String k, String v) {
      final String key = k.trim();
      if (key.isEmpty || v.isEmpty) return;
      if (_allowedHeaderKeys.contains(key.toLowerCase())) headers[key] = v;
    });
    return headers;
  }

  Future<SpiderHttpResult> _request(String url) => bridge.request(
        applyProxyIfNeeded(url),
        options: SpiderHttpOptions(headers: _defaultHeaders()),
      );

  /// 请求并解析 JSON 对象（失败返回 `null`，不抛异常）。
  Future<Map<String, Object?>?> _fetchJson(String url) async {
    final SpiderHttpResult res = await _request(url);
    if (!res.ok) return null;
    return JsonUtils.tryDecodeMap(res.content);
  }

  /// 请求 HTML 文本（失败返回 `null`）。
  Future<String?> _fetchHtml(String url) async {
    final SpiderHttpResult res = await _request(url);
    return res.ok ? res.content : null;
  }

  // ─────────────── JSON 解析（对齐 iOS `parseCategories` / `parseList` / `parseDetail`）───

  /// 解析分类列表；配置 `rootTypeId` 时收敛为「根分类 + 自动发现子分类」。
  Future<List<FuliCategory>> _parseCategories(Map<String, Object?> json) async {
    final List<FuliCategory> all = <FuliCategory>[];
    for (final Map<String, Object?> item in JsonUtils.asMapList(json['class'])) {
      final String id = JsonUtils.pickStringOr(item, 'type_id', '');
      final String name = JsonUtils.pickStringOr(item, 'type_name', '');
      if (id.isEmpty || name.isEmpty) continue;
      all.add(FuliCategory(typeId: id, typeName: name));
    }

    final String rootId = (_platform.rootTypeId ?? '').trim();
    if (rootId.isEmpty) return all;

    String rootName = (_platform.rootTypeName ?? '').trim();
    if (rootName.isEmpty) {
      for (final FuliCategory c in all) {
        if (c.typeId == rootId) {
          rootName = c.typeName;
          break;
        }
      }
    }
    if (rootName.isEmpty) rootName = platformName;

    final List<FuliCategory> children =
        await _discoverChildCategories(all, rootId);
    _childCategoryCache = children;
    return <FuliCategory>[
      FuliCategory(typeId: rootId, typeName: rootName, subCategories: children),
    ];
  }

  /// `childDiscovery == type_id_1` 时，筛选 `type_id_1 == rootId` 的分类。
  Future<List<FuliCategory>> _discoverChildCategories(
    List<FuliCategory> all,
    String rootId,
  ) async {
    final String mode =
        (_platform.childDiscovery ?? 'type_id_1').trim().toLowerCase();
    if (mode != 'type_id_1') return const <FuliCategory>[];

    final List<FuliCategory> out = <FuliCategory>[];
    for (final FuliCategory c in all) {
      if (c.typeId == rootId) continue;
      if (await _categoryBelongsToRoot(c, rootId)) out.add(c);
    }
    return out;
  }

  /// 该分类的列表项中是否存在 `type_id_1 == rootId`（判定归属）。
  Future<bool> _categoryBelongsToRoot(FuliCategory category, String rootId) async {
    final Map<String, Object?>? json =
        await _fetchJson('$_apiBase?ac=detail&t=${category.typeId}&pg=1');
    if (json == null) return false;
    for (final Map<String, Object?> item in JsonUtils.asMapList(json['list'])) {
      if (JsonUtils.pickStringOr(item, 'type_id_1', '') == rootId) return true;
    }
    return false;
  }

  /// 惰性加载子分类（父级聚合路径）。
  Future<List<FuliCategory>> _ensureChildCategories() async {
    if (_childCategoryCache != null) return _childCategoryCache!;
    final Map<String, Object?>? json = await _fetchJson('$_apiBase?ac=list');
    if (json != null) await _parseCategories(json);
    return _childCategoryCache ?? const <FuliCategory>[];
  }

  List<FuliVideo> _parseList(Map<String, Object?> json) {
    final List<FuliVideo> out = <FuliVideo>[];
    for (final Map<String, Object?> item in JsonUtils.asMapList(json['list'])) {
      if (!_isItemAllowed(item)) continue;
      final FuliVideo? video = _parseVideoItem(item);
      if (video != null) out.add(video);
    }
    return out;
  }

  /// 列表项过滤（`rootTypeId` 归属 + `itemRule.vodPlayUrl`）。
  bool _isItemAllowed(Map<String, Object?> item) {
    final String rootId = (_platform.rootTypeId ?? '').trim();
    if (rootId.isNotEmpty) {
      final String parent = JsonUtils.pickStringOr(item, 'type_id_1', '');
      if (parent.isNotEmpty && parent != rootId) return false;
    }

    final String playUrl =
        JsonUtils.pickStringOr(item, 'vod_play_url', '').trim();
    final String configured = (_platform.itemPlayUrlRule ?? '').trim();
    final String rule = configured.isNotEmpty
        ? configured.toLowerCase()
        : (contentCategory == FuliContentCategory.comic ? 'empty' : 'required');
    switch (rule) {
      case 'required':
        return playUrl.isNotEmpty;
      case 'empty':
        return playUrl.isEmpty;
      default:
        return true;
    }
  }

  FuliVideo? _parseVideoItem(Map<String, Object?> item) {
    final String id = JsonUtils.pickStringOr(item, 'vod_id', '');
    final String name = JsonUtils.pickStringOr(item, 'vod_name', '');
    if (id.isEmpty || name.isEmpty) return null;

    String pic = JsonUtils.pickStringOr(item, 'vod_pic', '');
    if (pic.isEmpty) pic = JsonUtils.pickStringOr(item, 'vod_pic_thumb', '');
    if (pic.isEmpty) pic = JsonUtils.pickStringOr(item, 'vod_pic_slide', '');
    final String remarks = JsonUtils.pickStringOr(item, 'vod_remarks', '');

    return FuliVideo(
      vodId: id,
      vodName: name,
      vodPic: _normalizeUrl(pic),
      vodRemarks: remarks.isEmpty ? null : remarks,
    );
  }

  FuliDetail? _parseDetail(Map<String, Object?> item) {
    final String id = JsonUtils.pickStringOr(item, 'vod_id', '');
    if (id.isEmpty) return null;
    final String name = JsonUtils.pickStringOr(item, 'vod_name', '');
    final String pic = _normalizeUrl(JsonUtils.pickStringOr(item, 'vod_pic', ''));
    final String content = JsonUtils.pickStringOr(item, 'vod_content', '');

    if (contentCategory == FuliContentCategory.comic ||
        (_platform.detailMode ?? '').trim().toLowerCase() == 'comic_images') {
      final List<String> images = _parseImages(item);
      return FuliDetail(
        vodId: id,
        vodName: name,
        vodPic: pic,
        vodContent: content.isEmpty ? null : content,
        playFrom: platformName,
        episodes: <FuliEpisode>[
          FuliEpisode(name: '浏览套图', url: pic, images: images),
        ],
      );
    }

    final String playFrom = JsonUtils.pickStringOr(item, 'vod_play_from', '');
    return FuliDetail(
      vodId: id,
      vodName: name,
      vodPic: pic,
      vodContent: content.isEmpty ? null : content,
      playFrom: playFrom.isEmpty ? platformName : playFrom,
      episodes: _parseEpisodes(item),
    );
  }

  /// 解析 `vod_play_url`：`$$$` 线路组 # `$` 名称/地址对。
  List<FuliEpisode> _parseEpisodes(Map<String, Object?> item) {
    final String playUrl = JsonUtils.pickStringOr(item, 'vod_play_url', '');
    if (playUrl.isEmpty) return const <FuliEpisode>[];

    final List<FuliEpisode> out = <FuliEpisode>[];
    final List<String> groups = playUrl.split(r'$$$');
    for (int gi = 0; gi < groups.length; gi++) {
      for (final String pair in groups[gi].split('#')) {
        final int sep = pair.indexOf(r'$');
        if (sep < 0) continue;
        final String name = pair.substring(0, sep).trim();
        final String url = _normalizeUrl(pair.substring(sep + 1).trim());
        if (url.isEmpty) continue;
        out.add(FuliEpisode(
          name: name.isEmpty ? '线路${gi + 1}' : name,
          url: url,
        ));
      }
    }
    return out;
  }

  /// 从 `vod_content` 提取 `<img>` 图片；无则回退封面（对齐 iOS `parseImages`）。
  List<String> _parseImages(Map<String, Object?> item) {
    final List<String> images = <String>[];
    final String content = JsonUtils.pickStringOr(item, 'vod_content', '');
    final RegExp re = RegExp(
      '''<img[^>]+src=["']([^"']+)["']''',
      caseSensitive: false,
    );
    for (final RegExpMatch m in re.allMatches(content)) {
      final String url = _normalizeUrl(m.group(1) ?? '');
      if (url.isNotEmpty) images.add(url);
    }
    if (images.isEmpty) {
      final String pic = _normalizeUrl(JsonUtils.pickStringOr(item, 'vod_pic', ''));
      if (pic.isNotEmpty) images.add(pic);
    }
    return images;
  }

  bool _hasMore(Map<String, Object?> json, int count, int page) {
    final int pageCount = JsonUtils.asInt(json['pagecount']) ?? page;
    final int limit = JsonUtils.asInt(json['limit']) ?? 20;
    return page < pageCount || count >= limit;
  }

  // ─────────────── 图文 HTML 模式（对齐 iOS L164-L212 / L402-L514）───────────────

  Future<FuliHomeResult> _fetchArticleHome() async {
    final String rootId = (_platform.rootTypeId ?? '33').trim();
    final String? html = await _fetchHtml(_articleListUrl(rootId, 1));
    if (html == null) return FuliHomeResult.empty;

    final List<FuliCategory> children =
        _parseArticleCategories(html, rootId);
    _childCategoryCache = children;
    final String configuredName = (_platform.rootTypeName ?? '').trim();
    final String rootName = configuredName.isEmpty ? platformName : configuredName;
    return FuliHomeResult(
      categories: <FuliCategory>[
        FuliCategory(typeId: rootId, typeName: rootName, subCategories: children),
      ],
      videos: _parseArticleList(html),
    );
  }

  Future<FuliCategoryResult> _fetchArticleCategory({
    required FuliCategory category,
    FuliCategory? subCategory,
    required int page,
  }) async {
    final String tid = subCategory?.typeId ?? category.typeId;
    final String? html = await _fetchHtml(_articleListUrl(tid, page));
    if (html == null) {
      return FuliCategoryResult(
        videos: const <FuliVideo>[],
        page: page,
        hasMore: false,
      );
    }
    return FuliCategoryResult(
      videos: _parseArticleList(html),
      page: page,
      hasMore: _articleHasMore(html, page),
    );
  }

  Future<FuliDetail> _fetchArticleDetail(String vodId) async {
    final String? html = await _fetchHtml(_articleDetailUrl(vodId));
    if (html == null) return _emptyDetail(vodId);

    String title = _parseFirstText(html, r'<h1[^>]*>([\s\S]*?)</h1>');
    if (title.isEmpty) {
      title = _parseFirstText(html, r'<title[^>]*>([\s\S]*?)</title>');
    }
    final List<String> images = _parseImageUrls(html);
    final String pic = images.isEmpty ? '' : images.first;
    return FuliDetail(
      vodId: vodId,
      vodName: title,
      vodPic: pic,
      vodContent: null,
      playFrom: platformName,
      episodes: <FuliEpisode>[
        FuliEpisode(name: '浏览套图', url: pic, images: images),
      ],
    );
  }

  String _articleListUrl(String typeId, int page) {
    final String pageSuffix = page <= 1 ? '' : '-$page';
    final String configured = (_platform.articleListPath ?? '').trim();
    final String template =
        configured.isEmpty ? '/arttype/{typeId}{pageSuffix}.html' : configured;
    final String path = template
        .replaceAll('{typeId}', typeId)
        .replaceAll('{page}', '$page')
        .replaceAll('{pageSuffix}', pageSuffix);
    return _absoluteUrl(path);
  }

  String _articleDetailUrl(String id) {
    final String configured = (_platform.articleDetailPath ?? '').trim();
    final String template =
        configured.isEmpty ? '/artdetail-{id}.html' : configured;
    return _absoluteUrl(template.replaceAll('{id}', id));
  }

  String _absoluteUrl(String path) {
    if (path.startsWith('http://') || path.startsWith('https://')) return path;
    final String host = currentHost;
    return '$host${path.startsWith('/') ? path : '/$path'}';
  }

  List<FuliCategory> _parseArticleCategories(String html, String rootId) {
    final RegExp re = RegExp(
      r'''<a[^>]+href=["'][^"']*/arttype/(\d+)(?:-\d+)?\.html["'][^>]*>([\s\S]*?)</a>''',
      caseSensitive: false,
    );
    final List<FuliCategory> out = <FuliCategory>[];
    final Set<String> seen = <String>{};
    for (final RegExpMatch m in re.allMatches(html)) {
      final String id = m.group(1) ?? '';
      final String name = _cleanHtmlText(m.group(2) ?? '');
      if (id.isEmpty || id == rootId || name.isEmpty || seen.contains(id)) {
        continue;
      }
      seen.add(id);
      out.add(FuliCategory(typeId: id, typeName: name));
    }
    return out;
  }

  List<FuliVideo> _parseArticleList(String html) {
    final RegExp re = RegExp(
      r'''<a[^>]+href=["'][^"']*/artdetail-(\d+)\.html["'][^>]*>([\s\S]*?)</a>''',
      caseSensitive: false,
    );
    final List<FuliVideo> out = <FuliVideo>[];
    final Set<String> seen = <String>{};
    for (final RegExpMatch m in re.allMatches(html)) {
      final String id = m.group(1) ?? '';
      final String title = _cleanHtmlText(m.group(2) ?? '');
      if (id.isEmpty || title.isEmpty || seen.contains(id)) continue;
      seen.add(id);
      out.add(FuliVideo(
        vodId: id,
        vodName: title,
        vodPic: _nearbyArticleImage(id, html),
        vodRemarks: '套图',
      ));
    }
    return out;
  }

  /// 详情链接附近 ±1200 字符内的首张内容图（对齐 iOS `nearbyArticleImage`）。
  String _nearbyArticleImage(String id, String html) {
    final int idx = html.indexOf('artdetail-$id.html');
    if (idx < 0) return '';
    final int lower = idx - 1200 < 0 ? 0 : idx - 1200;
    final int upper = idx + 1200 > html.length ? html.length : idx + 1200;
    final List<String> images = _parseImageUrls(html.substring(lower, upper));
    return images.isEmpty ? '' : images.first;
  }

  List<String> _parseImageUrls(String html) {
    final RegExp re = RegExp(
      '''<img[^>]+(?:src|data-src|data-original|data-lazy-src)=["']([^"']+)["']''',
      caseSensitive: false,
    );
    final List<String> out = <String>[];
    final Set<String> seen = <String>{};
    for (final RegExpMatch m in re.allMatches(html)) {
      final String url = _normalizeUrl(m.group(1) ?? '');
      if (url.isEmpty || !_isLikelyContentImage(url) || seen.contains(url)) {
        continue;
      }
      seen.add(url);
      out.add(url);
    }
    return out;
  }

  bool _isLikelyContentImage(String url) {
    final String lower = url.toLowerCase();
    final bool image = lower.contains('.jpg') ||
        lower.contains('.jpeg') ||
        lower.contains('.png') ||
        lower.contains('.webp');
    if (!image) return false;
    return !lower.contains('logo') &&
        !lower.contains('icon') &&
        !lower.contains('avatar');
  }

  bool _articleHasMore(String html, int page) =>
      html.contains('arttype/') && html.contains('-${page + 1}.html');

  String _parseFirstText(String html, String pattern) {
    final RegExpMatch? m = RegExp(pattern, caseSensitive: false).firstMatch(html);
    if (m == null) return '';
    return _cleanHtmlText(m.group(1) ?? '');
  }

  String _cleanHtmlText(String html) {
    String s = html.replaceAll(RegExp('<[^>]+>'), '');
    s = s
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'");
    return s.trim();
  }

  // ─────────────── 小工具 ───────────────

  /// 播放地址 / 封面归一（对齐 iOS `normalizeUrl`）。
  String _normalizeUrl(String raw) {
    final String u = raw.trim();
    if (u.isEmpty) return '';
    if (u.startsWith('http://') || u.startsWith('https://')) return u;
    if (u.startsWith('//')) return 'https:$u';
    if (u.startsWith('/')) return currentHost.isEmpty ? u : '$currentHost$u';
    if (u.contains('://')) return u;
    return 'https://$u';
  }

  FuliDetail _emptyDetail(String vodId) => FuliDetail(
        vodId: vodId,
        vodName: '',
        vodPic: '',
        vodContent: null,
        playFrom: platformName,
        episodes: const <FuliEpisode>[],
      );
}