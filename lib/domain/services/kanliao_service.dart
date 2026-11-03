/// 领域层：今日看料福利平台服务（UI-C1e，原生专用页）。
///
/// 唯一真相源：iOS `vbox/Services/KanliaoService.swift`（L1-L924）
///   · 候选域名矩阵（L28-L33）：`kanliao2.one` / `kanliao7.org` / `kanliao7.net`
///     / `kanliao14.com`，探测命中「页面含 `article`」即就绪（L145-L169）；
///   · 分类获取（L173-L191）：HTML 双策略解析（导航栏 / 侧边栏），
///     解析失败回退 11 个内置分类（L58-L70）；
///   · 分类视频列表（L206-L224）：`/<cid>/[page/]` 分页 + 多容器模式解析
///     （`article` / `div.class` / `li` / `figure`）+ 通用 `<a><img></a>` 兜底；
///   · 播放地址（L228-L265）：页面 7 策略提取 → iframe 三层递归；
///   · 搜索（L269-L281）：`/tag/<kw>/` 优先，回退 `/search/<kw>/`；
///   · 广告过滤（L693-L705）与分页解析（L709-L730）逐条对齐。
///
/// 移植口径与差异登记：
///   · 域名就绪：覆写 [probeHosts]，在 2xx 基础上加「正文含 `article`」判定
///     （对齐 iOS `probeDomain`）；全部失败保持未就绪，`currentHost` 回落首个默认域名
///     （等价 iOS `_activeBaseURL = candidateDomains[0]`）；
///   · 抓取契约：把 iOS 的 `fetchCategories` / `fetchVideos(cid:page:)` /
///     `fetchPlayURL(pageUrl:)` 映射为 [FuliBaseService] 的
///     `fetchHomeContent` / `fetchCategoryContent` / `fetchDetail`，
///     使通用 [WelfareVideoBridgePage] 可直接播放（判为**有意的接口适配**）；
///   · `vodId` 采用**绝对页面地址**（iOS 用相对 `href`）——播放中转页按 vodId
///     直取详情，绝对地址更利于跨域名切换后仍可重放（**有意的行为改进**）；
///   · 正则引擎换为 Dart [RegExp]（ICU：`dotAll` 等价 iOS `.dotMatchesLineSeparators`）；
///     未匹配的可选分组 Dart 返回 `null` 而保留下标（iOS 会移位），属**修正**。
library;

import 'dart:async';

import '../../platform/spider/spider_http_bridge.dart';
import '../entities/welfare/fuli_models.dart';
import 'fuli_base_service.dart';
import 'native_fuli_services.dart';

/// 今日看料福利平台服务（`kanliao` 原生专用页驱动）。
class KanliaoFuliService extends ProbedFuliService {
  /// 构造（[bridge] 供测试注入假传输）。
  KanliaoFuliService({super.bridge})
      : super(
          platformKey: 'kanliao',
          platformName: '今日看料',
          defaultHosts: const <String>[
            'https://kanliao2.one',
            'https://kanliao7.org',
            'https://kanliao7.net',
            'https://kanliao14.com',
          ],
        );

  /// 按 `platformKey` 的实例缓存（对齐 iOS `KanliaoService.shared` 单例语义）。
  static final Map<String, KanliaoFuliService> _cache =
      <String, KanliaoFuliService>{};

  /// 取（或创建）服务实例。
  static KanliaoFuliService serviceFor({SpiderHttpBridge? bridge}) =>
      _cache.putIfAbsent(
        'kanliao',
        () => KanliaoFuliService(bridge: bridge),
      );

  /// 清空实例缓存（装配重置 / 测试隔离用）。
  static void clearCache() => _cache.clear();

  /// 内置回退分类（对齐 iOS `fallbackCategories`）。
  static const List<FuliCategory> _fallbackCategories = <FuliCategory>[
    FuliCategory(typeId: '/category/rdgz/', typeName: '热点关注'),
    FuliCategory(typeId: '/category/dy/', typeName: '抖音'),
    FuliCategory(typeId: '/category/ks/', typeName: '快手'),
    FuliCategory(typeId: '/category/douyu/', typeName: '斗鱼'),
    FuliCategory(typeId: '/category/hy/', typeName: '虎牙'),
    FuliCategory(typeId: '/category/hj/', typeName: '花椒'),
    FuliCategory(typeId: '/category/tt/', typeName: '推特'),
    FuliCategory(typeId: '/category/wh/', typeName: '网红'),
    FuliCategory(typeId: '/category/asmr/', typeName: 'ASMR'),
    FuliCategory(typeId: '/category/xb/', typeName: 'X播'),
    FuliCategory(typeId: '/category/xsp/', typeName: '小视频'),
  ];

  /// 命名 HTML 实体（对齐 iOS `decodeHTMLEntities` 的 `namedEntities`）。
  static const Map<String, String> _namedEntities = <String, String>{
    '&amp;': '&',
    '&lt;': '<',
    '&gt;': '>',
    '&quot;': '"',
    '&#39;': "'",
    '&apos;': "'",
    '&nbsp;': ' ',
    '&copy;': '©',
    '&reg;': '®',
    '&ldquo;': '"',
    '&rdquo;': '"',
    '&lsquo;': "'",
    '&rsquo;': "'",
    '&mdash;': '—',
    '&ndash;': '–',
    '&hellip;': '…',
  };

  // 域名就绪（覆写：在 2xx 基础上加「含 article」判定，对齐 iOS `probeDomain`）。
  String _probedHost = '';
  bool _ready = false;

  /// 分类缓存（对齐 iOS `cachedCategories`）。
  List<FuliCategory>? _cachedCategories;

  @override
  String get currentHost => _probedHost.isEmpty ? primaryHost : _probedHost;

  @override
  bool get isHostReady => _ready;

  /// 逐个探测候选域名；命中「2xx 且正文含 `article`」即就绪。
  @override
  Future<void> probeHosts() async {
    for (final String host in allHosts) {
      if (host.trim().isEmpty) continue;
      if (await _probeCandidate(host)) {
        _probedHost = host;
        _ready = true;
        return;
      }
    }
    _probedHost = '';
    _ready = false;
  }

  Future<bool> _probeCandidate(String host) async {
    final String base =
        host.endsWith('/') ? host.substring(0, host.length - 1) : host;
    try {
      final SpiderHttpResult res = await bridge.request(
        applyProxyIfNeeded(base),
        options: const SpiderHttpOptions(timeout: Duration(seconds: 10)),
      );
      return res.ok && res.content.contains('article');
    } catch (_) {
      return false;
    }
  }

  /// 确保域名已探测（未就绪时探测一次；对齐 iOS `probeDomain` 前置）。
  Future<void> ensureHostReady() async {
    if (isHostReady) return;
    await probeHosts();
  }

  /// 清空分类缓存并重新探测（对齐 iOS `reprobe`）。
  @override
  void reprobe() {
    _cachedCategories = null;
    _probedHost = '';
    _ready = false;
    unawaited(probeHosts());
  }

  /// 清空自定义域名 + 缓存并重新探测（对齐 iOS `resetDomain`）。
  @override
  void resetDomain() {
    _cachedCategories = null;
    _probedHost = '';
    _ready = false;
    super.resetDomain();
  }

  // ─────────────── 分类 ───────────────

  /// 获取分类（缓存 + 解析失败回退内置分类；对齐 iOS `fetchCategories`）。
  Future<List<FuliCategory>> fetchCategories() async {
    final List<FuliCategory>? cached = _cachedCategories;
    if (cached != null) return cached;

    await ensureHostReady();
    final String base = currentHost;
    final String? html = await _fetchHtml(base, referer: base);
    if (html == null) return _fallbackCategories;

    final List<FuliCategory> parsed = _parseCategories(html, base);
    if (parsed.isEmpty) return _fallbackCategories;

    _cachedCategories = parsed;
    return parsed;
  }

  // ─────────────── 抓取契约（映射到 iOS fetchVideos / fetchPlayURL）───────────────

  @override
  Future<FuliHomeResult> fetchHomeContent() async {
    final List<FuliCategory> categories = await fetchCategories();
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
    final String base = currentHost;
    final String rawCid = (subCategory ?? category).typeId;
    final String cleanCid =
        rawCid.replaceAll(RegExp(r'^/+'), '').replaceAll(RegExp(r'/+$'), '');
    final String url = page > 1 ? '$base/$cleanCid/$page/' : '$base/$cleanCid/';

    final String? html = await _fetchHtml(url, referer: base);
    if (html == null) {
      return FuliCategoryResult(
        videos: const <FuliVideo>[],
        page: page,
        hasMore: false,
      );
    }
    final List<FuliVideo> videos = _parseVideoList(html, base);
    final int pageCount = _parsePageCount(html);
    return FuliCategoryResult(
      videos: videos,
      page: page,
      hasMore: page < pageCount,
    );
  }

  @override
  Future<FuliSearchResult> fetchSearch({
    required String keyword,
    required int page,
  }) async {
    await ensureHostReady();
    final String base = currentHost;
    final String encoded = Uri.encodeComponent(keyword);

    final String? tagHtml = await _fetchHtml('$base/tag/$encoded/', referer: base);
    if (tagHtml != null) {
      final List<FuliVideo> videos = _parseVideoList(tagHtml, base);
      if (videos.isNotEmpty) {
        return FuliSearchResult(videos: videos, page: page, hasMore: false);
      }
    }
    final String? searchHtml =
        await _fetchHtml('$base/search/$encoded/', referer: base);
    final List<FuliVideo> videos =
        searchHtml == null ? const <FuliVideo>[] : _parseVideoList(searchHtml, base);
    return FuliSearchResult(videos: videos, page: page, hasMore: false);
  }

  /// 详情：`vodId` 即页面绝对地址 → 提取播放地址（对齐 iOS `fetchPlayURL`）。
  @override
  Future<FuliDetail> fetchDetail(String vodId) async {
    await ensureHostReady();
    final String base = currentHost;
    final String pageUrl = vodId.startsWith('http')
        ? vodId
        : (vodId.startsWith('/') ? '$base$vodId' : '$base/$vodId');

    final String? html = await _fetchHtml(pageUrl, referer: base);
    if (html == null) return _emptyDetail(vodId);

    final String? playUrl = await _extractPlayUrl(html, pageUrl, base);
    final String title = _parseTitle(html);
    return FuliDetail(
      vodId: vodId,
      vodName: title,
      vodPic: '',
      vodContent: null,
      playFrom: platformName,
      episodes: playUrl == null || playUrl.isEmpty
          ? const <FuliEpisode>[]
          : <FuliEpisode>[FuliEpisode(name: '高清', url: playUrl)],
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
      headers: const <String, String>{},
      parse: direct ? 0 : 1,
    );
  }

  // ─────────────── 网络请求（对齐 iOS `fetchHTML` 含代理）───────────────

  Future<String?> _fetchHtml(String url, {required String referer}) async {
    final bool proxy = isProxyEnabled;
    final String finalUrl = proxy ? applyProxyIfNeeded(url) : url;
    final String finalReferer = proxy ? applyProxyIfNeeded('') : referer;
    try {
      final SpiderHttpResult res = await bridge.request(
        finalUrl,
        options: SpiderHttpOptions(
          timeout: const Duration(seconds: 20),
          referer: finalReferer.isEmpty ? referer : finalReferer,
          headers: const <String, String>{
            'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,'
                'image/avif,image/webp,image/apng,*/*;q=0.8',
            'Accept-Language': 'zh-CN,zh;q=0.9',
          },
        ),
      );
      return res.ok ? res.content : null;
    } catch (_) {
      return null;
    }
  }

  // ─────────────── 正则工具（对齐 iOS `firstMatch` / `allMatches`）───────────────

  List<String?>? _firstMatch(String pattern, String text) {
    final RegExpMatch? m = RegExp(pattern, dotAll: true).firstMatch(text);
    if (m == null) return null;
    return <String?>[
      for (int i = 0; i <= m.groupCount; i++) m.group(i),
    ];
  }

  List<List<String?>> _allMatches(String pattern, String text) => RegExp(
        pattern,
        dotAll: true,
      )
          .allMatches(text)
          .map((RegExpMatch m) => <String?>[
                for (int i = 0; i <= m.groupCount; i++) m.group(i),
              ])
          .toList(growable: false);

  // ─────────────── HTML 实体解码（对齐 iOS `decodeHTMLEntities`）───────────────

  String _decodeHtmlEntities(String string) {
    String result = string;
    _namedEntities.forEach((String entity, String ch) {
      result = result.replaceAll(entity, ch);
    });
    result = result.replaceAllMapped(
      RegExp(r'&#(\d+);'),
      (Match m) {
        final int? n = int.tryParse(m.group(1) ?? '');
        return n == null ? m.group(0)! : String.fromCharCode(n);
      },
    );
    result = result.replaceAllMapped(
      RegExp(r'&#x([0-9a-fA-F]+);'),
      (Match m) {
        final int? n = int.tryParse(m.group(1) ?? '', radix: 16);
        return n == null ? m.group(0)! : String.fromCharCode(n);
      },
    );
    return result;
  }

  // ─────────────── 分类解析（双策略：导航栏 + 侧边栏；对齐 iOS `parseCategories`）───

  List<FuliCategory> _parseCategories(String html, String base) {
    final List<FuliCategory> categories = <FuliCategory>[];
    final Set<String> seen = <String>{};

    const List<String> skipWords = <String>[
      'about', 'contact', 'tags', 'tag', 'top', 'start', 'time',
      '首页', 'home', 'search', '搜索', '关于', '联系',
      'register', 'login', '注册', '登录', 'vip', '会员',
    ];
    const List<String> knownPaths = <String>[
      '/category/', '/dy/', '/ks/', '/douyu/', '/hy/', '/hj/',
      '/tt/', '/wh/', '/asmr/', '/xb/', '/xsp/', '/rdgz/',
    ];

    // 策略一：导航栏解析。
    const List<String> navBlockPatterns = <String>[
      r'<nav[^>]*class="[^"]*navbar[^"]*"[^>]*>(.*?)</nav>',
      r'<ul[^>]*class="[^"]*(?:navbar-nav|nav-menu|menu|main-nav|nav-list)[^"]*"[^>]*>(.*?)</ul>',
      r'<div[^>]*class="[^"]*(?:header-menu|nav-wrap|top-nav)[^"]*"[^>]*>(.*?)</div>',
    ];

    String navHtml = '';
    for (final String pat in navBlockPatterns) {
      final List<String?>? groups = _firstMatch(pat, html);
      if (groups != null && groups.length >= 2) {
        navHtml = groups[1] ?? '';
        break;
      }
    }
    if (navHtml.isEmpty) navHtml = html;

    const String linkPattern = r'<a[^>]*href="([^"]+)"[^>]*>([^<]+)</a>';

    void collect(String source, {required int maxNameLen, bool httpOnlySameBase = false}) {
      for (final List<String?> groups in _allMatches(linkPattern, source)) {
        if (groups.length < 3) continue;
        final String href = (groups[1] ?? '').trim();
        final String name = (groups[2] ?? '').trim();
        if (href.isEmpty || name.isEmpty) continue;
        if (href == '#' || href == '/') continue;
        if (name.length < 2 || name.length > maxNameLen) continue;
        if (httpOnlySameBase && href.startsWith('http') && !href.contains(base)) {
          continue;
        }
        final String lowerHref = href.toLowerCase();
        final String lowerName = name.toLowerCase();
        if (skipWords.any((String w) =>
            lowerHref.contains(w) || lowerName.contains(w))) {
          continue;
        }
        final String cid = _normalizeCategoryId(href);
        if (seen.add(cid)) {
          categories.add(FuliCategory(typeId: cid, typeName: name));
        }
      }
    }

    // 策略一限定：仅采纳已知分类路径 / 短路径。
    for (final List<String?> groups in _allMatches(linkPattern, navHtml)) {
      if (groups.length < 3) continue;
      final String href = (groups[1] ?? '').trim();
      final String name = (groups[2] ?? '').trim();
      if (href.isEmpty || name.isEmpty || href == '#' || href == '/') continue;
      if (name.length < 2 || name.length > 8) continue;
      final String lowerHref = href.toLowerCase();
      final String lowerName = name.toLowerCase();
      if (skipWords.any((String w) =>
          lowerHref.contains(w) || lowerName.contains(w))) {
        continue;
      }
      final int segments = href.split('/').where((String s) => s.isNotEmpty).length;
      final bool isCat = knownPaths.any(href.contains) ||
          href.contains('/category/') ||
          (href.startsWith('/') && segments <= 3 && !href.contains('.'));
      if (isCat) {
        final String cid = _normalizeCategoryId(href);
        if (seen.add(cid)) {
          categories.add(FuliCategory(typeId: cid, typeName: name));
        }
      }
    }

    // 策略二：导航栏结果不足 → 侧边栏解析。
    if (categories.length < 3) {
      const List<String> sidebarPatterns = <String>[
        r'<div[^>]*class="[^"]*(?:sidebar|side-nav|widget|category-list|cat-list)[^"]*"[^>]*>(.*?)</div>',
        r'<aside[^>]*>(.*?)</aside>',
        r'<ul[^>]*class="[^"]*(?:cat|category|sidebar)[^"]*"[^>]*>(.*?)</ul>',
      ];
      for (final String pat in sidebarPatterns) {
        for (final List<String?> groups in _allMatches(pat, html)) {
          if (groups.length < 2) continue;
          collect(
            groups[1] ?? '',
            maxNameLen: 10,
            httpOnlySameBase: true,
          );
        }
        if (categories.length >= 5) break;
      }
    }

    return categories;
  }

  /// 分类 ID 规范化（对齐 iOS `normalizeCategoryID`）。
  String _normalizeCategoryId(String href) {
    String cid = href.trim();
    if (cid.startsWith('http')) {
      final Uri? uri = Uri.tryParse(cid);
      if (uri != null) cid = uri.path;
    }
    if (!cid.startsWith('/')) cid = '/$cid';
    if (!cid.endsWith('/')) cid = '$cid/';
    return cid;
  }

  // ─────────────── 视频列表解析（对齐 iOS `parseVideoList` / `parseVideoItem`）───

  List<FuliVideo> _parseVideoList(String html, String base) {
    final List<FuliVideo> videos = <FuliVideo>[];
    final Set<String> seenIds = <String>{};

    const List<String> containerPatterns = <String>[
      r'<article[^>]*>(.*?)</article>',
      r'<div[^>]*class="[^"]*(?:post-card|video-card|video-item|item-wrap|entry-card|list-item)[^"]*"[^>]*>(.*?)(?:</div>\s*</div>|</div>)',
      r'<li[^>]*class="[^"]*(?:video-item|post-item|list-item|item)[^"]*"[^>]*>(.*?)</li>',
      r'<figure[^>]*>(.*?)</figure>',
    ];

    for (final String pattern in containerPatterns) {
      for (final List<String?> groups in _allMatches(pattern, html)) {
        if (groups.length < 2) continue;
        final String itemHtml = groups[1] ?? '';
        if (_isAdvertisement(itemHtml)) continue;
        final FuliVideo? vod = _parseVideoItem(itemHtml, base);
        if (vod == null) continue;
        if (!seenIds.add(vod.vodId)) continue;
        videos.add(vod);
      }
      if (videos.isNotEmpty) break;
    }

    if (videos.isEmpty) {
      const String genericPattern =
          r'<a[^>]*href="([^"]+)"[^>]*>[\s\S]*?<img[^>]*>[\s\S]*?</a>';
      for (final List<String?> groups in _allMatches(genericPattern, html)) {
        if (groups.isEmpty) continue;
        final String itemHtml = groups[0] ?? '';
        if (_isAdvertisement(itemHtml)) continue;
        final FuliVideo? vod = _parseVideoItem(itemHtml, base);
        if (vod == null || vod.vodName.isEmpty || vod.vodPic.isEmpty) continue;
        if (!seenIds.add(vod.vodId)) continue;
        videos.add(vod);
      }
    }

    return videos;
  }

  FuliVideo? _parseVideoItem(String item, String base) {
    final List<String?>? linkGroups =
        _firstMatch(r'<a[^>]*href="([^"]+)"[^>]*>', item);
    if (linkGroups == null || linkGroups.length < 2) return null;
    final String href = linkGroups[1] ?? '';
    if (href.isEmpty) return null;

    // UI-C1e：vodId 采用绝对页面地址（差异登记见文件头）。
    final String pageUrl = href.startsWith('http')
        ? href
        : (href.startsWith('/') ? '$base$href' : '$base/$href');

    String title = '';
    const List<String> titlePatterns = <String>[
      r'<h2[^>]*>(.*?)</h2>',
      r'<h3[^>]*>(.*?)</h3>',
      r'<h4[^>]*>(.*?)</h4>',
      r'(?:post-card-title|entry-title|video-title|item-title)[^>]*>(.*?)<',
      r'title="([^"]+)"',
      r'alt="([^"]+)"',
    ];
    for (final String pat in titlePatterns) {
      final List<String?>? groups = _firstMatch(pat, item);
      if (groups != null && groups.length >= 2) {
        final String t = (groups[1] ?? '')
            .replaceAll(RegExp('<[^>]+>'), '')
            .replaceAll('\n', ' ')
            .trim();
        if (t.isNotEmpty && t.length >= 2) {
          title = t;
          break;
        }
      }
    }
    if (title.isEmpty) return null;

    final String cover = _extractImage(item, base);

    String remarks = '';
    final List<String?>? dateGroups =
        _firstMatch(r'<time[^>]*datetime="([^"]+)"[^>]*>', item);
    if (dateGroups != null && dateGroups.length >= 2) {
      remarks = dateGroups[1] ?? '';
    } else {
      final List<String?>? metaGroups = _firstMatch(
        r'(?:post-meta|entry-meta|post-card-info|video-meta)[^>]*>(.*?)<',
        item,
      );
      if (metaGroups != null && metaGroups.length >= 2) {
        remarks = (metaGroups[1] ?? '').trim();
      }
    }

    return FuliVideo(
      vodId: pageUrl,
      vodName: _decodeHtmlEntities(title),
      vodPic: cover,
      vodRemarks: remarks.isEmpty ? null : remarks,
    );
  }

  // ─────────────── 封面图提取（7 策略；对齐 iOS `extractImage`）───────────────

  String _extractImage(String html, String base) {
    final List<String?>? bg = _firstMatch(
      r'''background-image:\s*url\(["']?([^"')]+)["']?\)''',
      html,
    );
    if (bg != null && bg.length >= 2) {
      final String url = (bg[1] ?? '').trim();
      if (!url.startsWith('data:') && url.isNotEmpty) {
        return _normalizeImageUrl(url, base);
      }
    }

    final List<String?>? styleBg = _firstMatch(
      r'''style="[^"]*background-image:\s*url\(["']?([^"')]+)["']?\)''',
      html,
    );
    if (styleBg != null && styleBg.length >= 2) {
      final String url = (styleBg[1] ?? '').trim();
      if (!url.startsWith('data:') && url.isNotEmpty) {
        return _normalizeImageUrl(url, base);
      }
    }

    const List<String> lazyAttrs = <String>[
      'data-src', 'data-original', 'data-lazy-src', 'data-lazy',
      'data-srcset', 'data-cover', 'data-url', 'data-image', 'data-thumb',
    ];
    for (final String attr in lazyAttrs) {
      final List<String?>? groups =
          _firstMatch('<img[^>]*$attr="([^"]+)"[^>]*>', html);
      if (groups != null && groups.length >= 2) {
        final String url = (groups[1] ?? '').trim();
        if (!url.startsWith('data:') && url.isNotEmpty) {
          return _normalizeImageUrl(url, base);
        }
      }
    }

    final List<String?>? srcset = _firstMatch(
      r'<img[^>]*srcset="([^"]+)"[^>]*>',
      html,
    );
    if (srcset != null && srcset.length >= 2) {
      final String value = srcset[1] ?? '';
      final String firstUrl = value
          .split(',')
          .first
          .trim()
          .split(' ')
          .first
          .trim();
      if (!firstUrl.startsWith('data:') && firstUrl.isNotEmpty) {
        return _normalizeImageUrl(firstUrl, base);
      }
    }

    final List<String?>? figure = _firstMatch(
      r'<figure[^>]*>[\s\S]*?<img[^>]*src="([^"]+)"[^>]*>[\s\S]*?</figure>',
      html,
    );
    if (figure != null && figure.length >= 2) {
      final String url = (figure[1] ?? '').trim();
      if (!url.startsWith('data:') && url.isNotEmpty) {
        return _normalizeImageUrl(url, base);
      }
    }

    final List<String?>? noscript = _firstMatch(
      r'<noscript>[\s\S]*?<img[^>]*src="([^"]+)"[^>]*>[\s\S]*?</noscript>',
      html,
    );
    if (noscript != null && noscript.length >= 2) {
      final String url = (noscript[1] ?? '').trim();
      if (!url.startsWith('data:') && url.isNotEmpty) {
        return _normalizeImageUrl(url, base);
      }
    }

    final List<String?>? img = _firstMatch(r'<img[^>]*src="([^"]+)"[^>]*>', html);
    if (img != null && img.length >= 2) {
      final String url = (img[1] ?? '').trim();
      if (!url.startsWith('data:') && url.isNotEmpty) {
        return _normalizeImageUrl(url, base);
      }
    }

    return '';
  }

  String _normalizeImageUrl(String url, String base) {
    String trimmed = url.trim();
    if (trimmed.isEmpty) return '';
    trimmed = _decodeHtmlEntities(trimmed).replaceAll(r'\/', '/');
    if (trimmed.startsWith('http')) return trimmed;
    if (trimmed.startsWith('//')) return 'https:$trimmed';
    final String cleanBase =
        base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    if (trimmed.startsWith('/')) return '$cleanBase$trimmed';
    return '$cleanBase/$trimmed';
  }

  // ─────────────── 广告过滤（对齐 iOS `isAdvertisement`）───────────────

  bool _isAdvertisement(String html) {
    const List<String> adKeywords = <String>[
      '热搜HOT', '手机链接', 'DNS设置', '修改DNS', 'WIFI设置',
      '广告', '推广', 'ad-', 'ad_', 'advertisement', 'sponsor',
      '广告位', '赞助商', '推荐', '点击进入', '立即查看',
      ' telegram', 'Telegram', '电报群',
    ];
    final String lower = html.toLowerCase();
    for (final String keyword in adKeywords) {
      if (lower.contains(keyword.toLowerCase())) return true;
    }
    return false;
  }

  // ─────────────── 分页解析（对齐 iOS `parsePageCount`）───────────────

  int _parsePageCount(String html) {
    final List<int> pageNumbers = <int>[];
    for (final List<String?> groups in _allMatches(r'/(\d+)/?"', html)) {
      if (groups.length < 2) continue;
      final int? num = int.tryParse(groups[1] ?? '');
      if (num != null) pageNumbers.add(num);
    }

    final List<String?>? pages = _firstMatch(r'page-numbers[^>]*>(.*?)</div>', html);
    if (pages != null && pages.length >= 2) {
      for (final List<String?> groups in _allMatches(r'>(\d+)<', pages[1] ?? '')) {
        if (groups.length < 2) continue;
        final int? num = int.tryParse(groups[1] ?? '');
        if (num != null) pageNumbers.add(num);
      }
    }

    if (pageNumbers.isNotEmpty) {
      final int maxPage = pageNumbers.reduce((int a, int b) => a > b ? a : b);
      if (maxPage > 1) return maxPage;
    }
    if (html.contains('next') || html.contains('下一页')) return 9999;
    return 1;
  }

  // ─────────────── 播放地址提取（7 策略 + iframe 三层；对齐 iOS）───────────────

  /// 页面 → 播放地址（先直取，再 iframe 递归三层）。
  Future<String?> _extractPlayUrl(String html, String pageUrl, String base) async {
    final String? direct = _extractPlayUrlFromHtml(html);
    if (direct != null && direct.isNotEmpty) {
      return _normalizePlayUrl(direct, base);
    }

    final String? iframeUrl = _extractIframeUrl(html, base);
    if (iframeUrl == null) return null;

    final String? iframeHtml = await _fetchHtml(iframeUrl, referer: pageUrl);
    if (iframeHtml == null) return null;

    final String? second = _extractPlayUrlFromHtml(iframeHtml);
    if (second != null && second.isNotEmpty) {
      return _normalizePlayUrl(second, base);
    }

    final String? iframeUrl2 = _extractIframeUrl(iframeHtml, iframeUrl);
    if (iframeUrl2 == null) return null;

    final String? iframeHtml2 = await _fetchHtml(iframeUrl2, referer: iframeUrl);
    if (iframeHtml2 == null) return null;

    final String? third = _extractPlayUrlFromHtml(iframeHtml2);
    if (third != null && third.isNotEmpty) {
      return _normalizePlayUrl(third, base);
    }
    return null;
  }

  String? _extractPlayUrlFromHtml(String html) {
    final List<String?>? dplayer = _firstMatch(
      r'<div[^>]*class="[^"]*dplayer[^"]*"[^>]*data-config="([^"]+)"[^>]*>',
      html,
    );
    if (dplayer != null && dplayer.length >= 2) {
      final String? url = _extractUrlFromJsonContent(_decodeHtmlEntities(dplayer[1] ?? ''));
      if (url != null) return url;
    }

    final List<String?>? dplayerConfig = _firstMatch(
      r'<div[^>]*class="[^"]*dplayer[^"]*"[^>]*config="([^"]+)"[^>]*>',
      html,
    );
    if (dplayerConfig != null && dplayerConfig.length >= 2) {
      final String? url =
          _extractUrlFromJsonContent(_decodeHtmlEntities(dplayerConfig[1] ?? ''));
      if (url != null) return url;
    }

    const List<String> jsonConfigPatterns = <String>[
      r'var\s+video\s*=\s*(\{[\s\S]*?\})',
      r'playerConfig\s*=\s*(\{[\s\S]*?\})',
      r'player_data\s*=\s*(\{[\s\S]*?\})',
      r'"video"\s*:\s*(\{[\s\S]*?\})',
      r'window\.playerData\s*=\s*(\{[\s\S]*?\})',
    ];
    for (final String pat in jsonConfigPatterns) {
      final List<String?>? groups = _firstMatch(pat, html);
      if (groups != null && groups.length >= 2) {
        final String? url = _extractUrlFromJsonContent(groups[1] ?? '');
        if (url != null) return url;
      }
    }

    final String? fromText = _extractVideoUrlFromText(html);
    if (fromText != null) return fromText;

    const List<String> videoTagPatterns = <String>[
      r'<video[^>]*src="([^"]+)"[^>]*>',
      r'<video[^>]*data-src="([^"]+)"[^>]*>',
      r'<video[^>]*data-original="([^"]+)"[^>]*>',
    ];
    for (final String pat in videoTagPatterns) {
      final List<String?>? groups = _firstMatch(pat, html);
      if (groups != null && groups.length >= 2) {
        final String url = (groups[1] ?? '').replaceAll(r'\/', '/');
        if (url.isNotEmpty) return _decodeHtmlEntities(url);
      }
    }

    final List<String?>? source =
        _firstMatch(r'<source[^>]*src="([^"]+)"[^>]*>', html);
    if (source != null && source.length >= 2) {
      final String url = (source[1] ?? '').replaceAll(r'\/', '/');
      if (url.isNotEmpty) return _decodeHtmlEntities(url);
    }

    const List<String> jsVarPatterns = <String>[
      '''video_url\\s*[=:]\\s*["']([^"']+)["']''',
      '''videoUrl\\s*[=:]\\s*["']([^"']+)["']''',
      '''play_url\\s*[=:]\\s*["']([^"']+)["']''',
      '''m3u8\\s*[=:]\\s*["']([^"']+)["']''',
      '''mp4\\s*[=:]\\s*["']([^"']+)["']''',
      '''src\\s*[=:]\\s*["']([^"']+\\.(?:m3u8|mp4)[^"']*)["']''',
    ];
    for (final String pat in jsVarPatterns) {
      final List<String?>? groups = _firstMatch(pat, html);
      if (groups != null && groups.length >= 2) {
        final String url = (groups[1] ?? '').replaceAll(r'\/', '/');
        if (url.isNotEmpty && (url.contains('.m3u8') || url.contains('.mp4'))) {
          return _decodeHtmlEntities(url);
        }
      }
    }

    return null;
  }

  String? _extractUrlFromJsonContent(String jsonString) {
    final String decoded = _decodeHtmlEntities(jsonString);
    const List<String> urlKeys = <String>[
      'url', 'src', 'video_url', 'videoUrl', 'play_url', 'playUrl',
      'm3u8_url', 'mp4_url', 'video', 'movie', 'source',
    ];
    for (final String key in urlKeys) {
      final List<String?>? groups =
          _firstMatch('"$key"\\s*:\\s*"([^"]+)"', decoded);
      if (groups != null && groups.length >= 2) {
        final String url = (groups[1] ?? '').replaceAll(r'\/', '/').trim();
        if (url.isNotEmpty &&
            (url.contains('.m3u8') ||
                url.contains('.mp4') ||
                url.startsWith('http'))) {
          return url;
        }
      }
    }
    return null;
  }

  String? _extractVideoUrlFromText(String text) {
    final List<String?>? m3u8 =
        _firstMatch(r'''(https?://[^"'\s<>]+\.m3u8[^"'\s<>]*)''', text);
    if (m3u8 != null && m3u8.length >= 2) {
      return _decodeHtmlEntities((m3u8[1] ?? '').replaceAll(r'\/', '/'));
    }
    final List<String?>? mp4 =
        _firstMatch(r'''(https?://[^"'\s<>]+\.mp4[^"'\s<>]*)''', text);
    if (mp4 != null && mp4.length >= 2) {
      return _decodeHtmlEntities((mp4[1] ?? '').replaceAll(r'\/', '/'));
    }
    return null;
  }

  String? _extractIframeUrl(String html, String base) {
    final List<String?>? groups =
        _firstMatch(r'<iframe[^>]*src="([^"]+)"[^>]*>', html);
    if (groups == null || groups.length < 2) return null;

    String src = (groups[1] ?? '').trim();
    if (src.isEmpty) return null;

    const List<String> skipPatterns = <String>[
      'google', 'facebook', 'baidu', 'cnzz', '51.la', 'tongji',
      'ads', 'advert', 'googletag', 'doubleclick',
    ];
    final String lower = src.toLowerCase();
    for (final String skip in skipPatterns) {
      if (lower.contains(skip)) return null;
    }

    if (src.startsWith('//')) {
      src = 'https:$src';
    } else if (src.startsWith('/')) {
      src = '$base$src';
    } else if (!src.startsWith('http')) {
      src = '$base/$src';
    }
    return src;
  }

  String _normalizePlayUrl(String url, String base) {
    String result = url.trim();
    result = _decodeHtmlEntities(result).replaceAll(r'\/', '/');
    if (result.startsWith('http')) return result;
    if (result.startsWith('//')) return 'https:$result';
    final String cleanBase =
        base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    if (result.startsWith('/')) return '$cleanBase$result';
    return '$cleanBase/$result';
  }

  // ─────────────── 详情标题 / 空详情 ───────────────

  String _parseTitle(String html) {
    String title = _textOf(html, r'<h1[^>]*>([\s\S]*?)</h1>');
    if (title.isEmpty) title = _textOf(html, r'<title[^>]*>([\s\S]*?)</title>');
    // 去掉站点后缀（形如「标题 - 站点名」）。
    final int sep = title.indexOf(RegExp(r'\s[-|_]\s'));
    if (sep > 0) title = title.substring(0, sep).trim();
    return title;
  }

  String _textOf(String html, String pattern) {
    final List<String?>? groups = _firstMatch(pattern, html);
    if (groups == null || groups.length < 2) return '';
    return _decodeHtmlEntities(
      (groups[1] ?? '').replaceAll(RegExp('<[^>]+>'), '').trim(),
    );
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