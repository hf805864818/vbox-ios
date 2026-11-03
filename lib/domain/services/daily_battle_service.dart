/// 领域层：每日大乱斗 / 每日大赛福利平台服务（UI-C1b，原生专用页）。
///
/// 唯一真相源：iOS `vbox/Services/DailyBattleService.swift`（L1-L721）
///   · 站点配置（L12-L34）：`battle`（每日大乱斗，`border/blood.bshzjjgq.cc`）
///     与 `dailyContest`（每日大赛，`www.ercwvciks.cc` / `www.nzmknoycm.cc`），
///     `domainPatterns` 为外链广告白名单；
///   · 站点存活探测（L256-L327）：入口 → JS 跳转页跟进 → 导航页提取线路域名
///     （含 base64 内嵌块解码）→ 逐线路测试 `/category/mrds/`；
///   · 首页（L372-L431）：导航栏分类（跳过站点功能项）+ `article` 推荐视频；
///   · 分类列表（L435-L462）：`/<cid>/[page/]` 分页，`/mrdg` 目录标记；
///   · 详情（L466-L564）：`.dplayer` 的 `data-config.video.url` 提取 → 回退
///     正文关键词链接；`name$url` 以 `#` 连接；标签 `keywords`；
///   · 搜索（L568-L581）：`/search/<kw>/[page/]`；封面 `extractCover`（L671-L711）
///     5 策略（`loadBannerDirect` / `data:` / 直链 / `url()` / `img`）。
///
/// 移植口径与差异登记：
///   · 域名就绪：覆写 [probeHosts]（JS 跳转 / 导航页 / 线路域名三段链路），
///     全部失败保持未就绪（对齐 iOS `isReady = false`）；
///   · HTTP 桥未暴露「跟随重定向后的最终 URL」（iOS 读 `httpResp.url`）→
///     以请求入口为基准推导 `scheme://host`，**如实登记为差异**；
///   · 抓取契约：把 iOS 的 `fetchHome` / `fetchCategoryList` / `fetchDetail` /
///     `search` 映射为 [FuliBaseService] 的 `fetchHomeContent` /
///     `fetchCategoryContent` / `fetchDetail` / `fetchSearch`，
///     `fetchDetail` 把 iOS 的 `name$url#name$url` 还原为 [FuliEpisode] 列表，
///     使通用 `WelfareVideoBridgePage` 可直接播放（有意的接口适配）；
///   · `vodId` 保留 iOS 的 `@folder` 目录后缀语义（详情时剥离）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/api.dart' as pc;
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/cbc.dart';
import 'package:pointycastle/block/modes/ecb.dart';
import 'package:pointycastle/padded_block_cipher/padded_block_cipher_impl.dart';
import 'package:pointycastle/paddings/pkcs7.dart';

import '../../platform/spider/spider_http_bridge.dart';
import '../entities/welfare/fuli_models.dart';
import 'fuli_base_service.dart';
import 'native_fuli_services.dart';

/// 每日大乱斗站点配置（对齐 iOS `DailyBattleSiteConfig`）。
class DailyBattleSiteConfig {
  /// 构造。
  const DailyBattleSiteConfig({
    required this.name,
    required this.hosts,
    required this.domainPatterns,
  });

  /// 站点名。
  final String name;

  /// 入口域名列表。
  final List<String> hosts;

  /// 外链广告过滤白名单（域名片段）。
  final List<String> domainPatterns;

  /// 每日大乱斗（默认站点）。
  static const DailyBattleSiteConfig battle = DailyBattleSiteConfig(
    name: '每日大乱斗',
    hosts: <String>[
      'https://border.bshzjjgq.cc',
      'https://blood.bshzjjgq.cc',
    ],
    domainPatterns: <String>['bshzjjgq.cc', 'mrdld.com'],
  );

  /// 每日大赛。
  static const DailyBattleSiteConfig dailyContest = DailyBattleSiteConfig(
    name: '每日大赛',
    hosts: <String>[
      'https://www.ercwvciks.cc',
      'https://www.nzmknoycm.cc',
    ],
    domainPatterns: <String>[
      'tvayhvuab', 'rvvnvvuk', 'nzmknoycm', 'miqmpuln',
      'synvmodz', 'ercwvciks', 'mrds', 'mrdsk',
    ],
  );

  /// 平台显示名 → 站点配置（对齐 iOS `DailyBattleService.from(platform:)`）。
  static DailyBattleSiteConfig forPlatformName(String name) =>
      name == '每日大赛' ? dailyContest : battle;
}

/// 每日大乱斗福利平台服务（`daily_battle` 原生专用页驱动）。
class DailyBattleFuliService extends ProbedFuliService {
  /// 构造（[config] 站点配置；[bridge] 供测试注入假传输）。
  DailyBattleFuliService({DailyBattleSiteConfig? config, super.bridge})
      : config = config ?? DailyBattleSiteConfig.battle,
        super(
          platformKey: 'daily_battle',
          platformName: (config ?? DailyBattleSiteConfig.battle).name,
          defaultHosts: (config ?? DailyBattleSiteConfig.battle).hosts,
        );

  /// 站点配置。
  final DailyBattleSiteConfig config;

  /// 按 `platformKey` 的实例缓存（对齐 iOS `DailyBattleService.shared`）。
  static final Map<String, DailyBattleFuliService> _cache =
      <String, DailyBattleFuliService>{};

  /// 取（或创建）服务实例；站点按平台名区分（每日大乱斗 / 每日大赛）。
  static DailyBattleFuliService serviceFor({
    required String platformKey,
    required String platformName,
    SpiderHttpBridge? bridge,
  }) =>
      _cache.putIfAbsent(
        '$platformKey|$platformName',
        () => DailyBattleFuliService(
          config: DailyBattleSiteConfig.forPlatformName(platformName),
          bridge: bridge,
        ),
      );

  /// 清空实例缓存（装配重置 / 测试隔离用）。
  static void clearCache() => _cache.clear();

  /// 站点名（对齐 iOS `siteName`）。
  String get siteName => config.name;

  /// 桌面 Chrome UA（对齐 iOS `headers`）。
  static const String _ua =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  // 域名就绪（覆写：JS 跳转 / 导航页 / 线路域名三段链路）。
  String _probedHost = '';
  bool _ready = false;

  @override
  String get currentHost => _probedHost.isEmpty ? primaryHost : _probedHost;

  @override
  bool get isHostReady => _ready;

  /// 逐个入口探测，命中即就绪（对齐 iOS `probeHost`）。
  @override
  Future<void> probeHosts() async {
    for (final String host in allHosts) {
      final String base = _stripSlash(host);
      if (base.isEmpty) continue;
      final String? html = await _get(base);
      if (html == null) continue;

      // 情况 1：JS 跳转页 → 跟进目标页取线路域名。
      if (_isJsRedirectPage(html)) {
        final String? target = _extractJSHref(html);
        if (target != null) {
          final String? found = await _tryLineDomains(target, _scheme(base));
          if (found != null) {
            _probedHost = found;
            _ready = true;
            return;
          }
        }
        continue;
      }

      // 情况 2：当前页即导航页 → 提取线路域名并逐条测试。
      final List<String> lineDomains = _extractLineDomains(html);
      if (lineDomains.isNotEmpty) {
        for (final String d in lineDomains) {
          final String testHost = '${_scheme(base)}://www.$d';
          if (await _testCategoryPage(testHost)) {
            _probedHost = testHost;
            _ready = true;
            return;
          }
        }
        continue;
      }

      // 情况 2b：导航页但未提取到域名 → 跳过。
      if (_isNavigationPage(html)) continue;

      // 情况 3：普通内容页 → 直接使用。
      _probedHost = base;
      _ready = true;
      return;
    }
    _probedHost = '';
    _ready = false;
  }

  /// 从 URL 页提取线路域名并逐条测试（对齐 iOS `tryLineDomains`）。
  Future<String?> _tryLineDomains(String url, String scheme) async {
    final String? html = await _get(url);
    if (html == null) return null;
    for (final String d in _extractLineDomains(html)) {
      final String testHost = '$scheme://www.$d';
      if (await _testCategoryPage(testHost)) return testHost;
    }
    return null;
  }

  /// 测试域名是否返回分类页（`/category/mrds/` 且正文 > 2000 字）。
  Future<bool> _testCategoryPage(String host) async {
    final String? html = await _get('$host/category/mrds/');
    return html != null && html.length > 2000;
  }

  /// 清空缓存并重新探测（对齐 iOS `reprobe`）。
  @override
  void reprobe() {
    _probedHost = '';
    _ready = false;
    unawaited(probeHosts());
  }

  /// 清空自定义域名 + 缓存并重新探测（对齐 iOS `resetDomain`）。
  @override
  void resetDomain() {
    _probedHost = '';
    _ready = false;
    super.resetDomain();
  }

  /// 确保域名已探测。
  Future<void> ensureHostReady() async {
    if (isHostReady) return;
    await probeHosts();
  }

  // ─────────────── 抓取契约 ───────────────

  /// 首页：分类 + 首个分类视频（对齐 iOS `fetchHome`）。
  @override
  Future<FuliHomeResult> fetchHomeContent() async {
    await ensureHostReady();
    final String base = currentHost;
    final String? html = await _fetchHtml(base);
    if (html == null) {
      return FuliHomeResult(categories: _fallbackCategories, videos: const <FuliVideo>[]);
    }

    List<FuliCategory> categories = _parseCategories(html);
    if (categories.isEmpty) categories = _fallbackCategories;

    final List<FuliVideo> videos = _parseVideos(_extractArticles(html));
    return FuliHomeResult(categories: categories, videos: videos);
  }

  /// 分类列表（分页；对齐 iOS `fetchCategoryList`）。
  @override
  Future<FuliCategoryResult> fetchCategoryContent({
    required FuliCategory category,
    FuliCategory? subCategory,
    required int page,
  }) async {
    await ensureHostReady();
    final String rawCid = (subCategory ?? category).typeId;
    final String fullUrl = _buildCategoryUrl(rawCid, page);
    final String? html = await _fetchHtml(fullUrl);
    if (html == null) {
      return FuliCategoryResult(videos: const <FuliVideo>[], page: page, hasMore: false);
    }
    final bool isFolder = rawCid.contains('/mrdg');
    final List<FuliVideo> videos = _parseVideos(
      _extractArticles(html),
      tag: isFolder ? 'folder' : '',
    );
    return FuliCategoryResult(
      videos: videos,
      page: page,
      // 对齐 iOS：结果数 ≥ 10 视为可能还有下一页。
      hasMore: videos.length >= 10,
    );
  }

  /// 搜索（对齐 iOS `search`）。
  @override
  Future<FuliSearchResult> fetchSearch({
    required String keyword,
    required int page,
  }) async {
    await ensureHostReady();
    final String base = currentHost;
    final String enc = Uri.encodeComponent(keyword);
    final String url =
        page <= 1 ? '$base/search/$enc/' : '$base/search/$enc/$page/';
    final String? html = await _fetchHtml(url);
    final List<FuliVideo> videos =
        html == null ? const <FuliVideo>[] : _parseVideos(_extractArticles(html));
    return FuliSearchResult(
      videos: videos,
      page: page,
      hasMore: videos.length >= 10,
    );
  }

  /// 详情：`name$url#name$url…` → [FuliEpisode] 列表（对齐 iOS `fetchDetail`）。
  @override
  Future<FuliDetail> fetchDetail(String vodId) async {
    await ensureHostReady();
    final String base = currentHost;
    final String id = vodId.endsWith('@folder')
        ? vodId.substring(0, vodId.length - '@folder'.length)
        : vodId;
    final String url = id.startsWith('http')
        ? id
        : (id.startsWith('/') ? '$base$id' : '$base/$id');

    final String? html = await _fetchHtml(url, referer: base);
    if (html == null) {
      return _emptyDetail(vodId);
    }

    final List<FuliEpisode> episodes = _parseEpisodes(html);
    final List<String> keywords = _parseKeywords(html);
    return FuliDetail(
      vodId: vodId,
      vodName: keywords.isEmpty ? config.name : keywords.join(' · '),
      vodPic: '',
      vodContent: null,
      playFrom: config.name,
      episodes: episodes,
    );
  }

  /// 目录 / 普通资源统一按 URL 后缀判定 parse（对齐基类口径）。
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

  // ─────────────── 网络请求 ───────────────

  /// 带站点头（+ 可选 Referer/Origin）的抓取（对齐 iOS `request`）。
  Future<String?> _fetchHtml(String url, {String? referer}) async {
    final String origin = currentHost;
    final String finalUrl = isProxyEnabled ? applyProxyIfNeeded(url) : url;
    try {
      final SpiderHttpResult res = await bridge.request(
        finalUrl,
        options: SpiderHttpOptions(
          timeout: const Duration(seconds: 20),
          referer: referer ?? '$origin/',
          headers: <String, String>{
            'User-Agent': _ua,
            'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,'
                'image/avif,image/webp,*/*;q=0.8',
            'Accept-Language': 'zh-CN,zh;q=0.9',
            'Origin': origin,
          },
        ),
      );
      return res.ok ? res.content : null;
    } catch (_) {
      return null;
    }
  }

  /// 探测期抓取（不带 Referer/Origin，对齐 iOS `requestPlain`）。
  Future<String?> _get(String url) async {
    final String finalUrl = isProxyEnabled ? applyProxyIfNeeded(url) : url;
    try {
      final SpiderHttpResult res = await bridge.request(
        finalUrl,
        options: const SpiderHttpOptions(
          timeout: Duration(seconds: 15),
          headers: <String, String>{'User-Agent': _ua},
        ),
      );
      return res.ok ? res.content : null;
    } catch (_) {
      return null;
    }
  }

  // ─────────────── 探测辅助（对齐 iOS 同名方法）───────────────

  bool _isJsRedirectPage(String html) {
    final String stripped = html.trim();
    if (stripped.length >= 800) return false;
    return stripped.contains('window.location.replace') ||
        stripped.contains('window.location.href') ||
        stripped.contains('_5v9MXQT1Kq.click');
  }

  bool _isNavigationPage(String html) {
    final bool hasArticle = html.contains('<article') ||
        html.contains('<main') ||
        html.contains('class="post"');
    final bool hasB64 =
        html.contains('base64') || html.contains('atob') || html.contains('btoa');
    final bool hasNavKeywords =
        html.contains('导航') || html.contains('发布页') || html.contains('回家的路');
    final bool isLarge = html.length > 5000;
    if (isLarge && !hasArticle) return true;
    if (hasNavKeywords) return true;
    if (hasB64 && !hasArticle) return true;
    return false;
  }

  String? _extractJSHref(String html) {
    final RegExpMatch? m =
        RegExp(r'<a[^>]+href="([^"]+)"').firstMatch(html);
    return m?.group(1);
  }

  /// 从导航页提取线路域名（含 base64 内嵌块解码；对齐 iOS `extractLineDomains`）。
  List<String> _extractLineDomains(String html) {
    final List<String> domains = <String>[];
    String searchText = html;

    // 方式 1：提取内嵌的 base64 块并解码。
    final RegExpMatch? b64 =
        RegExp("[\"']([A-Za-z0-9+/=]{500,})[\"']").firstMatch(html);
    if (b64 != null) {
      final String? decoded = _tryBase64(b64.group(1) ?? '');
      if (decoded != null) searchText = decoded;
    }

    // 方式 2：整体解码。
    if (identical(searchText, html)) {
      final String cleaned =
          html.replaceAll('\n', '').replaceAll(' ', '');
      final String? decoded = _tryBase64(cleaned);
      if (decoded != null && decoded.length > 1000) searchText = decoded;
    }

    void collect(String pattern) {
      for (final RegExpMatch m in RegExp(pattern).allMatches(searchText)) {
        final String? d = m.group(1);
        if (d != null && d.isNotEmpty && !domains.contains(d)) domains.add(d);
      }
    }

    // `words.random() + '.domain.cc'`
    collect(r'''words\.random\(\)\s*\+\s*['"]\.([a-z0-9-]+\.[a-z]{2,})['"]''');
    // `'.domain.cc'`
    collect(r"'\.([a-z0-9-]+\.[a-z]{2,})'");

    // 方式 3：兜底 — 在原始 HTML 与解码文本中搜索已知域名模式。
    if (domains.isEmpty) {
      for (final String text in <String>[searchText, html]) {
        for (final String pattern in config.domainPatterns) {
          final String p = 'https?://[a-zA-Z0-9-]*\\.${RegExp.escape(pattern)}';
          if (RegExp(p).hasMatch(text)) {
            if (!domains.contains(pattern)) domains.add(pattern);
          }
        }
        if (domains.isNotEmpty) break;
      }
    }
    return domains;
  }

  String? _tryBase64(String value) {
    try {
      final List<int> bytes = base64.decode(value);
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      return null;
    }
  }

  // ─────────────── 分类解析（对齐 iOS `fetchHome` 导航栏）───────────────

  List<FuliCategory> _parseCategories(String html) {
    const Set<String> skipNames = <String>{
      '首页', '更多', '官方QQ群', '商务合作', '求瓜投稿', '往期内容',
      '吃瓜电报群', '官方推特', '常见问题', '世界杯直播', '吃瓜首页',
      '吃瓜QQ群', '回家的路', '51AV',
    };
    const List<String> navSelectors = <String>[
      r'<[^>]*class="[^"]*category-list[^"]*"[^>]*>(.*?)</',
      r'<[^>]*class="[^"]*nav-menu[^"]*"[^>]*>(.*?)</ul>',
      r'<[^>]*class="[^"]*menu[^"]*"[^>]*>(.*?)</ul>',
      r'<nav[^>]*>(.*?)</nav>',
      r'<[^>]*class="[^"]*mobile-nav-categories[^"]*"[^>]*>(.*?)</',
      r'<[^>]*class="[^"]*nav-categories[^"]*"[^>]*>(.*?)</',
    ];
    final List<FuliCategory> cats = <FuliCategory>[];
    final Set<String> seen = <String>{};
    final RegExp linkPattern = RegExp(r'<a[^>]*href="([^"]+)"[^>]*>([^<]*)</a>');

    for (final String sel in navSelectors) {
      final List<String?> groups = _firstMatch(sel, html) ?? const <String?>[];
      if (groups.length < 2 || (groups[1] ?? '').isEmpty) continue;
      for (final RegExpMatch m in linkPattern.allMatches(groups[1]!)) {
        final String href = (m.group(1) ?? '').trim();
        final String name = _decodeHtmlEntities((m.group(2) ?? '').trim());
        if (href.isEmpty || href == '#' || name.isEmpty) continue;
        if (skipNames.contains(name) || name.length > 8) continue;
        final String url = href.startsWith('/') ? href : '/$href';
        if (cats.any((FuliCategory c) => c.typeId == url)) continue;
        cats.add(FuliCategory(typeId: url, typeName: name));
        seen.add(url);
      }
      if (cats.isNotEmpty) break;
    }
    return cats;
  }

  /// 回退分类（对齐 iOS `fetchHome` 的 fallback 分支）。
  List<FuliCategory> get _fallbackCategories => config.name == '每日大赛'
      ? const <FuliCategory>[
          FuliCategory(typeId: '/category/mrds/', typeName: '每日大赛'),
        ]
      : const <FuliCategory>[
          FuliCategory(typeId: '/category/mrld/', typeName: '今日乱斗'),
          FuliCategory(typeId: '/category/bkdg/', typeName: '必看大瓜'),
        ];

  // ─────────────── 视频列表解析（对齐 iOS `parseVideos` / `extractCover`）───

  /// 提取 `article` 块（对齐 iOS `//*[@id='index']//article | //article`）。
  List<String> _extractArticles(String html) {
    final List<String> out = <String>[];
    for (final RegExpMatch m
        in RegExp(r'<article[^>]*>([\s\S]*?)</article>').allMatches(html)) {
      out.add(m.group(1) ?? '');
    }
    return out;
  }

  List<FuliVideo> _parseVideos(List<String> articles, {String tag = ''}) {
    final List<FuliVideo> videos = <FuliVideo>[];
    for (final String item in articles) {
      String title = _textOf(item, r'<h2[^>]*>([\s\S]*?)</h2>');
      if (title.isEmpty) {
        title = _textOf(item, r'class="[^"]*entry-title[^"]*"[^>]*>([\s\S]*?)<');
      }
      if (title.isEmpty) {
        title = _textOf(item, r'class="[^"]*post-title[^"]*"[^>]*>([\s\S]*?)<');
      }
      if (title.isEmpty) continue;

      final RegExpMatch? link =
          RegExp(r'<a[^>]*href="([^"]+)"').firstMatch(item);
      final String href = link?.group(1)?.trim() ?? '';
      if (href.isEmpty) continue;

      // 跳过广告外链（对齐 iOS：http 开头且非白名单域名）。
      if (href.startsWith('http') &&
          !config.domainPatterns.any((String p) => href.contains(p))) {
        continue;
      }

      final String cover = _extractCover(item);
      final String remarks = _textOf(item, r'<time[^>]*>([\s\S]*?)</time>');

      videos.add(FuliVideo(
        vodId: tag.isEmpty ? href : '$href@folder',
        vodName: title.trim(),
        vodPic: cover,
        vodRemarks: remarks.isEmpty ? null : remarks,
      ));
    }
    return videos;
  }

  /// 封面提取（5 策略；对齐 iOS `extractCover`）。
  String _extractCover(String item) {
    final List<String> patterns = <String>[
      r'''loadBannerDirect\('([^']+)'\)''',
      r'''(data:image/[a-zA-Z0-9+/=;,]+)''',
      r'''(https?://[^"'\s)]+\.(?:jpg|png|jpeg|webp))''',
      r'''url\s*\(\s*['"]?([^"'\)]+)['"]?\s*\)''',
      r'<img[^>]*(?:src|data-src|data-original)="([^"]+)"',
    ];
    for (final String pat in patterns) {
      final String? raw = _firstGroup(pat, item, caseInsensitive: true);
      if (raw != null && raw.trim().isNotEmpty) {
        return _normalizeImageUrl(raw.trim());
      }
    }
    return '';
  }

  String _normalizeImageUrl(String url) {
    String v = url;
    if (v.startsWith('http') || v.startsWith('data:')) return v;
    final String base = currentHost;
    if (v.startsWith('/')) return '$base$v';
    return '$base/$v';
  }

  // ─────────────── 详情解析（对齐 iOS `fetchDetail`）───────────────

  List<FuliEpisode> _parseEpisodes(String html) {
    final List<FuliEpisode> out = <FuliEpisode>[];
    final Set<String> usedNames = <String>{};

    // 1. `.dplayer` 的 `data-config.video.url`。
    int idx = 0;
    for (final RegExpMatch m
        in RegExp(r'<div[^>]*class="[^"]*dplayer[^"]*"[^>]*data-config="([^"]+)"')
            .allMatches(html)) {
      idx++;
      final String cfg = _decodeHtmlEntities(m.group(1) ?? '');
      final String? url = _extractVideoUrlFromJson(cfg);
      if (url == null || url.isEmpty) continue;
      String name = '视频$idx';
      String unique = name;
      int count = 2;
      while (usedNames.contains(unique)) {
        unique = '$name $count';
        count++;
      }
      usedNames.add(unique);
      out.add(FuliEpisode(name: unique, url: url));
    }

    // 2. 回退：正文关键词链接。
    if (out.isEmpty) {
      const List<String> kw = <String>[
        '点击观看', '观看', '播放', '视频', '第一弹', '第二弹', '第三弹',
        '第四弹', '第五弹', '第六弹', '第七弹', '第八弹', '第九弹', '第十弹',
      ];
      final RegExp contentLink =
          RegExp(r'<a[^>]*href="([^"]+)"[^>]*>([^<]*)</a>');
      int i = 0;
      for (final RegExpMatch m in contentLink.allMatches(html)) {
        final String href = m.group(1) ?? '';
        final String text = _decodeHtmlEntities((m.group(2) ?? '').trim());
        if (!kw.any((String k) => text.contains(k))) continue;
        i++;
        String name = text
            .replaceAll('点击观看：', '')
            .replaceAll('点击观看', '')
            .trim();
        if (name.isEmpty) name = '视频$i';
        final String full = href.startsWith('http')
            ? href
            : (href.startsWith('/') ? '$currentHost$href' : '$currentHost/$href');
        out.add(FuliEpisode(name: name, url: full));
      }
    }
    return out;
  }

  /// 从 JSON 串提取 `video.url`（对齐 iOS `data-config` 解析）。
  String? _extractVideoUrlFromJson(String jsonString) {
    final Object? decoded = _tryJson(jsonString);
    if (decoded is Map) {
      final Object? video = decoded['video'];
      if (video is Map) {
        final Object? url = video['url'];
        if (url is String && url.isNotEmpty) return url;
      }
      final Object? url = decoded['url'];
      if (url is String && url.isNotEmpty) return url;
    }
    // 回退：正则。
    final String? m = _firstGroup(r'''"url"\s*:\s*"([^"]+)"''', jsonString);
    return (m != null && m.isNotEmpty) ? m : null;
  }

  Object? _tryJson(String s) {
    try {
      return jsonDecode(s);
    } catch (_) {
      return null;
    }
  }

  List<String> _parseKeywords(String html) {
    final List<String> out = <String>[];
    final Set<String> seen = <String>{};
    for (final RegExpMatch m in RegExp(
            r'<(?:a|span)[^>]*class="[^"]*(?:tags|keywords|post-tags)[^"]*"[^>]*>([^<]*)<')
        .allMatches(html)) {
      final String name = _decodeHtmlEntities((m.group(1) ?? '').trim());
      if (name.isNotEmpty && seen.add(name)) out.add(name);
    }
    return out;
  }

  FuliDetail _emptyDetail(String vodId) => FuliDetail(
        vodId: vodId,
        vodName: '',
        vodPic: '',
        vodContent: null,
        playFrom: config.name,
        episodes: const <FuliEpisode>[],
      );

  // ─────────────── 通用工具 ───────────────

  String _buildCategoryUrl(String base, int page) {
    final String path = base.startsWith('http')
        ? base
        : '$currentHost${base.startsWith('/') ? base : '/$base'}';
    final String trimmed = path.endsWith('/')
        ? path.substring(0, path.length - 1)
        : path;
    return page <= 1 ? '$trimmed/' : '$trimmed/$page/';
  }

  String _scheme(String url) => url.startsWith('http://') ? 'http' : 'https';

  String _stripSlash(String url) =>
      url.endsWith('/') ? url.substring(0, url.length - 1) : url;

  String? _firstGroup(String pattern, String text,
      {bool caseInsensitive = false}) {
    final RegExp re = caseInsensitive
        ? RegExp(pattern, caseSensitive: false)
        : RegExp(pattern);
    return re.firstMatch(text)?.group(1);
  }

  List<String?>? _firstMatch(String pattern, String text) {
    final RegExpMatch? m = RegExp(pattern, dotAll: true).firstMatch(text);
    if (m == null) return null;
    return <String?>[for (int i = 0; i <= m.groupCount; i++) m.group(i)];
  }

  String _textOf(String html, String pattern) {
    final List<String?>? groups = _firstMatch(pattern, html);
    if (groups == null || groups.length < 2) return '';
    final String v = groups[1] ?? '';
    return _decodeHtmlEntities(v.replaceAll(RegExp('<[^>]+>'), '').trim());
  }

  String _decodeHtmlEntities(String string) {
    String result = string
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'")
        .replaceAll('&nbsp;', ' ');
    result = result.replaceAllMapped(RegExp(r'&#(\d+);'), (Match m) {
      final int? n = int.tryParse(m.group(1) ?? '');
      return n == null ? m.group(0)! : String.fromCharCode(n);
    });
    return result;
  }
}

// ─────────────── 封面对称解密（对齐 iOS `AESImageDecryptor`）───────────────

/// 每日大乱斗 / 每日大赛封面的 AES 密钥对（KEY + IV，各 16 字节；对齐 iOS
/// `AESImageDecryptor.keyPairs`）。
const List<List<int>> _dailyBattleKeyPairs = <List<int>>[
  <int>[
    0x66, 0x35, 0x64, 0x39, 0x36, 0x35, 0x64, 0x66, // f5d965df
    0x37, 0x35, 0x33, 0x33, 0x36, 0x32, 0x37, 0x30, // 75336270
    0x39, 0x37, 0x62, 0x36, 0x30, 0x33, 0x39, 0x34, // 97b60394
    0x61, 0x62, 0x63, 0x32, 0x66, 0x62, 0x65, 0x31, // abc2fbe1
  ],
  <int>[
    0x37, 0x35, 0x33, 0x33, 0x36, 0x32, 0x37, 0x30, // 75336270
    0x66, 0x35, 0x64, 0x39, 0x36, 0x35, 0x64, 0x66, // f5d965df
    0x61, 0x62, 0x63, 0x32, 0x66, 0x62, 0x65, 0x31, // abc2fbe1
    0x39, 0x37, 0x62, 0x36, 0x30, 0x33, 0x39, 0x34, // 97b60394
  ],
];

/// 是否已是可识别的图片格式（JPEG / PNG / GIF）。
bool _looksLikeImage(Uint8List data) {
  if (data.length < 4) return false;
  if (data[0] == 0xFF && data[1] == 0xD8) return true; // JPEG
  if (data[0] == 0x89 && data[1] == 0x50 && data[2] == 0x4E && data[3] == 0x47) {
    return true; // PNG
  }
  if (data[0] == 0x47 && data[1] == 0x49 && data[2] == 0x46 && data[3] == 0x38) {
    return true; // GIF8
  }
  return false;
}

/// 解密每日大乱斗 / 每日大赛封面字节（对齐 iOS `AESImageDecryptor.decrypt`）。
///
/// 已是 JPEG / PNG / GIF 的字节原样返回；否则依次尝试两组 CBC 密钥对与两组
/// ECB 密钥，命中「解密后是合法图片」即返回；全部失败保持原样（由图片解码器
/// 兜底为占位态）。
Uint8List decodeDailyBattleImageBytes(Uint8List data) {
  if (data.length < 16 || data.length % 16 != 0) return data;
  if (_looksLikeImage(data)) return data;

  for (final List<int> pair in _dailyBattleKeyPairs) {
    final Uint8List key = Uint8List.fromList(pair.sublist(0, 16));
    final Uint8List iv = Uint8List.fromList(pair.sublist(16, 32));
    final Uint8List? out = _aesDecrypt(data, key: key, iv: iv);
    if (out != null && _looksLikeImage(out)) return out;
  }
  for (final List<int> pair in _dailyBattleKeyPairs) {
    final Uint8List key = Uint8List.fromList(pair.sublist(0, 16));
    final Uint8List? out = _aesDecrypt(data, key: key);
    if (out != null && _looksLikeImage(out)) return out;
  }
  return data;
}

/// AES-128 解密（[iv] 为空走 ECB，否则 CBC；PKCS7 去填充）。
Uint8List? _aesDecrypt(Uint8List data, {required Uint8List key, Uint8List? iv}) {
  final PaddedBlockCipherImpl cipher = PaddedBlockCipherImpl(
    PKCS7Padding(),
    iv == null ? ECBBlockCipher(AESEngine()) : CBCBlockCipher(AESEngine()),
  );
  cipher.init(
    false,
    pc.PaddedBlockCipherParameters<pc.CipherParameters?, pc.CipherParameters?>(
      iv == null
          ? pc.KeyParameter(key)
          : pc.ParametersWithIV<pc.KeyParameter>(pc.KeyParameter(key), iv),
      null,
    ),
  );
  try {
    final Uint8List out = cipher.process(data);
    return out.isEmpty ? null : out;
  } catch (_) {
    return null;
  }
}