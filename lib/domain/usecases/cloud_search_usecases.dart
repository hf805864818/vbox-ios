/// 领域层：网盘源搜索（对齐 iOS `SpiderManager.cloudSearch` 及六种站型的
/// `searchOne*Site` / `extract*Items` 解析）。
///
/// 语义（对齐 iOS）：
/// - 网盘源是与 api/spider 同级的独立源类别（`cloudSources.cloudSites`）；
/// - 全部网盘站并发发起、命中即回调（`withTaskGroup` + `onBatch`）；
/// - 结果 `vodRemarks` 统一打 ☁️ 来源标记（对齐 iOS 的 "☁️" + siteName）。
library;

import 'dart:convert';

import '../../core/errors/failures.dart';
import '../../core/network/http_client.dart';
import '../../core/utils/result.dart';
import '../entities/remote_source/remote_source.dart';
import '../entities/spider/spider_models.dart';

/// PC 浏览器 UA（对齐 iOS `cloudPcUA`）。
const String kCloudPcUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

/// 移动端 UA（对齐 iOS `cloudMobileUA`）。
const String kCloudMobileUserAgent =
    'Mozilla/5.0 (Linux; Android 12; Pixel 6) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

/// 单站请求超时（对齐 iOS `URLRequest.timeoutInterval = 8`）。
const Duration kCloudRequestTimeout = Duration(seconds: 8);

/// 网盘源搜索用例。
class CloudSearchUseCases {
  /// 构造。
  CloudSearchUseCases({
    required HttpClient client,
    required Future<Result<AllSourcesContainer>> Function() loadAllSources,
  })  : _client = client,
        _loadAllSources = loadAllSources;

  final HttpClient _client;
  final Future<Result<AllSourcesContainer>> Function() _loadAllSources;

  /// 取当前网盘站列表（供源列表/诊断展示）。
  Future<List<CloudSiteConfig>> listCloudSites() async {
    final Result<AllSourcesContainer> r = await _loadAllSources();
    return r.valueOrNull?.cloudSites ?? const <CloudSiteConfig>[];
  }

  /// 并发搜索全部网盘站；单站返回即 [onBatch] 回调。
  Future<Result<List<VodItem>>> searchCloud(
    String keyword, {
    void Function(List<VodItem> items)? onBatch,
  }) async {
    final String kw = keyword.trim();
    if (kw.isEmpty) return const Success<List<VodItem>>(<VodItem>[]);

    final Result<AllSourcesContainer> r = await _loadAllSources();
    final Failure? failure = r.failureOrNull;
    if (failure != null) return Err<List<VodItem>>(failure);

    final List<CloudSiteConfig> sites =
        r.valueOrNull?.cloudSites ?? const <CloudSiteConfig>[];
    if (sites.isEmpty) return const Success<List<VodItem>>(<VodItem>[]);

    final List<VodItem> all = <VodItem>[];
    await Future.wait<void>(sites.map((CloudSiteConfig site) async {
      final List<VodItem> items = await searchOneCloudSite(kw, site);
      if (items.isEmpty) return;
      onBatch?.call(items);
      all.addAll(items);
    }));
    return Success<List<VodItem>>(all);
  }

  /// 按站点类型分发（对齐 iOS `searchOneCloudSite2`）。
  Future<List<VodItem>> searchOneCloudSite(
    String keyword,
    CloudSiteConfig site,
  ) {
    switch (site.type) {
      case CloudSiteType.cms:
        return _searchCms(keyword, site);
      case CloudSiteType.forum:
        return _searchForum(keyword, site);
      case CloudSiteType.spa:
        return _searchSpa(keyword, site);
      case CloudSiteType.wordpress:
        return _searchWordPress(keyword, site);
      case CloudSiteType.dedecms:
        return _searchDedeCms(keyword, site);
      case CloudSiteType.binhd:
        return _searchBinhd(keyword, site);
    }
  }

  // ───────────────────────── 各站型搜索 ─────────────────────────

  /// CMS 型：主 URL 优先，备用 URL 轮询（对齐 iOS `searchOneCMSSite`）。
  Future<List<VodItem>> _searchCms(
    String keyword,
    CloudSiteConfig site,
  ) async {
    final String kw = _encodeKeyword(keyword);
    final List<String> candidates = <String>[site.searchUrlFor(kw)];
    for (final String backup in site.searchurls) {
      final String full = backup + kw;
      if (!candidates.contains(full)) candidates.add(full);
    }
    final String ua = site.usesPcUserAgent ? kCloudPcUserAgent : kCloudMobileUserAgent;
    for (final String url in candidates) {
      final String? html = await _fetchText(url, ua: ua);
      if (html == null || html.isEmpty) continue;
      final List<VodItem> items = _extractCmsItems(html, site);
      if (items.isNotEmpty) return items;
    }
    return const <VodItem>[];
  }

  /// WordPress 型（对齐 iOS `searchOneWordPressSite`）。
  Future<List<VodItem>> _searchWordPress(
    String keyword,
    CloudSiteConfig site,
  ) async {
    final String html = await _fetchText(
      site.searchUrlFor(_encodeKeyword(keyword)),
      ua: site.usesPcUserAgent ? kCloudPcUserAgent : kCloudMobileUserAgent,
    ) ?? '';
    if (html.isEmpty) return const <VodItem>[];
    return _extractWordPressItems(html, site);
  }

  /// DedeCMS 型（对齐 iOS `searchOneDedeCMSSite`）。
  Future<List<VodItem>> _searchDedeCms(
    String keyword,
    CloudSiteConfig site,
  ) async {
    final String html = await _fetchText(
      site.searchUrlFor(_encodeKeyword(keyword)),
      ua: site.usesPcUserAgent ? kCloudPcUserAgent : kCloudMobileUserAgent,
    ) ?? '';
    if (html.isEmpty) return const <VodItem>[];
    return _extractDedeCmsItems(html, site);
  }

  /// binhd 型（对齐 iOS `searchOneBinhdSite`）。
  Future<List<VodItem>> _searchBinhd(
    String keyword,
    CloudSiteConfig site,
  ) async {
    final String html = await _fetchText(
      site.searchUrlFor(_encodeKeyword(keyword)),
      ua: kCloudPcUserAgent,
      extraHeaders: <String, String>{
        'Accept': 'text/html,application/xhtml+xml',
      },
    ) ?? '';
    if (html.isEmpty) return const <VodItem>[];
    return _extractBinhdItems(html, site);
  }

  /// 论坛型：策略 A 直链 → 策略 B 主题列表 → 策略 C 兜底
  /// （对齐 iOS `searchOneForumSite`）。
  Future<List<VodItem>> _searchForum(
    String keyword,
    CloudSiteConfig site,
  ) async {
    final String html = await _fetchText(
      site.searchUrlFor(_encodeKeyword(keyword)),
      ua: kCloudPcUserAgent,
    ) ?? '';
    if (html.isEmpty) return const <VodItem>[];

    // 策略 A：搜索结果页直接含网盘链接（最常见）。
    final List<VodItem> direct = _parseCloudLinks(html, site);
    if (direct.isNotEmpty) return direct;

    // 策略 B：主题列表（threadPattern 捕获组按 "-" 拼接为 id）。
    final String threadPattern = site.threadPattern ?? '';
    final String threadUrl = site.threadURL ?? '';
    if (threadPattern.isNotEmpty && threadUrl.isNotEmpty) {
      final RegExp? re = _safeRegex(threadPattern);
      if (re != null) {
        final List<VodItem> items = <VodItem>[];
        for (final RegExpMatch m in re.allMatches(html)) {
          if (items.length >= 10) break;
          final List<String> parts = <String>[];
          for (int i = 1; i <= m.groupCount; i++) {
            final String? g = m.group(i);
            if (g != null) parts.add(g);
          }
          final String resolved = threadUrl.replaceAll('{id}', parts.join('-'));
          final String fullVodId =
              resolved.startsWith('http') ? resolved : site.detailBase + resolved;
          String title = site.name;
          final String ctx = _snippet(html, m.start - 200, m.start + 200);
          final String? t = _safeRegex(r'title="([^"]+)"')?.firstMatch(ctx)?.group(1);
          if (t != null && t.isNotEmpty) title = t;
          items.add(VodItem(
            vodId: fullVodId,
            vodName: title,
            vodPic: '',
            vodRemarks: site.name,
          ));
        }
        if (items.isNotEmpty) return items;
      }
    }

    // 策略 C：全页扫描兜底。
    return _parseCloudLinks(html, site);
  }

  /// SPA 型：JSON 搜索接口（对齐 iOS `searchOneSpaSite`）。
  Future<List<VodItem>> _searchSpa(
    String keyword,
    CloudSiteConfig site,
  ) async {
    final String template = site.apiSearch ?? '';
    if (template.isEmpty) return const <VodItem>[];
    final String url = template.replaceAll('{kw}', _encodeKeyword(keyword));
    final String text = await _fetchText(
      url,
      ua: kCloudPcUserAgent,
      extraHeaders: <String, String>{'Accept': 'application/json'},
    ) ?? '';
    if (text.isEmpty) return const <VodItem>[];

    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      return const <VodItem>[];
    }

    final List<Map<String, Object?>> list =
        _spaResultList(decoded, site.resultField);
    final String titleField =
        (site.titleField?.isNotEmpty ?? false) ? site.titleField! : 'title';
    final String urlField =
        (site.urlField?.isNotEmpty ?? false) ? site.urlField! : 'url';

    final List<VodItem> items = <VodItem>[];
    for (final Map<String, Object?> entry in list.take(20)) {
      final Object? rawTitle = entry[titleField];
      if (rawTitle is! String || rawTitle.isEmpty) continue;
      final String? detailValue = _asUrlValue(entry[urlField]);
      if (detailValue == null) continue;

      final String templateUrl = site.urlTemplate ?? '';
      final String fullUrl;
      if (templateUrl.isNotEmpty) {
        final String templated = templateUrl.replaceAll('{id}', detailValue);
        fullUrl = templated.startsWith('http')
            ? templated
            : site.detailBase + templated;
      } else {
        fullUrl = detailValue.startsWith('http')
            ? detailValue
            : site.detailBase + detailValue;
      }
      items.add(VodItem(
        vodId: _enrichTianyiAccessCode(fullUrl, rawTitle),
        vodName: rawTitle,
        vodPic: '',
        vodRemarks: site.name,
      ));
    }
    return items;
  }

  // ───────────────────────── HTML / JSON 解析 ─────────────────────────

  /// CMS 搜索结果解析（对齐 iOS `extractCMSSearchItems`）。
  List<VodItem> _extractCmsItems(String html, CloudSiteConfig site) {
    final String? custom = site.detailPattern;
    final String pattern = (custom != null && custom.isNotEmpty)
        ? custom
        : r'<a[^>]*href="((?:/index\.php/vod/detail/id/|/voddetail/|/detail/|/vod/)(\d+)\.html)[^"]*"[^>]*>(.+?)</a>';
    final RegExp? re = _safeRegex(pattern, dotAll: true);
    if (re == null) return const <VodItem>[];

    const List<String> episodeMarks = <String>[
      '更新到',
      '更新至',
      '连载至',
      '已完结',
      '更新中',
    ];
    final List<VodItem> items = <VodItem>[];
    for (final RegExpMatch m in re.allMatches(html)) {
      final String? detailPath = m.group(1);
      final String? inner = m.group(3);
      if (detailPath == null || inner == null) continue;

      String title = _stripTags(inner);
      final bool looksLikeEpisode =
          episodeMarks.any((String s) => title.contains(s));
      if (looksLikeEpisode || title.length < 4) {
        bool found = false;
        final String? attrTitle =
            _safeRegex(r'<a[^>]*title="([^"]+)"')?.firstMatch(inner)?.group(1)?.trim();
        if (attrTitle != null && attrTitle.length > 2) {
          title = attrTitle;
          found = true;
        }
        if (!found) {
          final String ctx = _snippet(html, m.start - 300, m.start + 300);
          for (final String p in const <String>[
            r'<img[^>]+alt="([^"]{2,80})"',
            r'<h[2-4][^>]*>([^<]{2,80})</h[2-4]>',
            r'<span[^>]*class="[^"]*title[^"]*"[^>]*>([^<]{2,80})</span>',
            r'<div[^>]*class="[^"]*title[^"]*"[^>]*>([^<]{2,80})</div>',
            r'<a[^>]*class="[^"]*title[^"]*"[^>]*>([^<]{2,80})</a>',
          ]) {
            final String? t =
                _safeRegex(p, caseInsensitive: true)?.firstMatch(ctx)?.group(1)?.trim();
            if (t != null &&
                t.length > 2 &&
                !episodeMarks.any((String s) => t.contains(s))) {
              title = t;
              break;
            }
          }
        }
        if (!found && looksLikeEpisode) {
          final String cleaned = title
              .replaceAll(RegExp(r'更新到第?\d+集'), '')
              .replaceAll(RegExp(r'更新至第?\d+集'), '')
              .trim();
          if (cleaned.length > 2) title = cleaned;
        }
      }

      if (title.length < 2 ||
          title.startsWith('首页') ||
          title.startsWith('网址') ||
          title.startsWith('APP')) {
        continue;
      }

      // 缩略图：对齐 iOS（全页首个 data-original，其次 lazy data-src）。
      String pic =
          _safeRegex(r'data-original="([^"]+)"')?.firstMatch(html)?.group(1) ?? '';
      if (pic.isEmpty) {
        pic = _safeRegex(
              r'<img[^>]*class="[^"]*lazy[^"]*"[^>]*data-src="([^"]+)"',
            )?.firstMatch(html)?.group(1) ??
            '';
      }

      items.add(VodItem(
        vodId: site.detailBase + detailPath,
        vodName: title,
        vodPic: pic,
        vodRemarks: '☁️${site.name}',
      ));
    }
    return _dedupeById(items);
  }

  /// WordPress 搜索结果解析（对齐 iOS `extractWordPressSearchItems`）。
  List<VodItem> _extractWordPressItems(String html, CloudSiteConfig site) {
    final RegExp? re = _safeRegex(
      r'<a[^>]*href="((?:https?://[^/]+)?/(?:[\d]{4}/[\d]{2}/[\d]{2}/)?(\d+)\.html)"[^>]*>(.+?)</a>',
      dotAll: true,
    );
    if (re == null) return const <VodItem>[];
    final List<VodItem> items = <VodItem>[];
    final Set<String> seen = <String>{};
    for (final RegExpMatch m in re.allMatches(html)) {
      final String? href = m.group(1);
      final String? inner = m.group(3);
      if (href == null || inner == null) continue;
      final String title = _stripTags(inner);
      if (title.length < 4) continue;
      if (title.startsWith('首页') ||
          title.startsWith('网址') ||
          title.startsWith('APP')) {
        continue;
      }
      final String lower = href.toLowerCase();
      if (lower.contains('/page/') ||
          lower.contains('/wp-') ||
          lower.contains('/author/') ||
          lower.contains('/tag/')) {
        continue;
      }
      final String detailUrl =
          href.startsWith('http') ? href : site.detailBase + href;
      if (!seen.add(detailUrl)) continue;

      String pic = '';
      final String window = _snippet(html, m.start, m.start + 500);
      final String? near = _safeRegex(
        r'<img[^>]+(?:data-original|data-src|src)="([^"]+)"',
        caseInsensitive: true,
      )?.firstMatch(window)?.group(1);
      if (near != null && near.isNotEmpty) pic = near;
      if (pic.isEmpty) {
        pic = _safeRegex(r'<img[^>]+src="([^"]+)"')?.firstMatch(html)?.group(1) ?? '';
      }
      items.add(VodItem(
        vodId: detailUrl,
        vodName: title,
        vodPic: pic,
        vodRemarks: '☁️${site.name}',
      ));
    }
    return items;
  }

  /// DedeCMS 搜索结果解析（对齐 iOS `extractDedeCMSSearchItems`）。
  List<VodItem> _extractDedeCmsItems(String html, CloudSiteConfig site) {
    final RegExp? re = _safeRegex(
      r'<a[^>]*href="(/(?:[a-z]+/)?\d{4}/(?:\d{2}/\d{2}/|\d{4}/)(\d+)\.html)"[^>]*>(.+?)</a>',
      dotAll: true,
    );
    if (re == null) return const <VodItem>[];
    final List<VodItem> items = <VodItem>[];
    final Set<String> seen = <String>{};
    for (final RegExpMatch m in re.allMatches(html)) {
      final String? path = m.group(1);
      final String? inner = m.group(3);
      if (path == null || inner == null) continue;
      final String title = _stripTags(inner);
      if (title.length < 4) continue;
      if (title.startsWith('首页') ||
          title.startsWith('网址') ||
          title.startsWith('APP')) {
        continue;
      }
      final String detailUrl = site.detailBase + path;
      if (!seen.add(detailUrl)) continue;

      String pic = '';
      final String window = _snippet(html, m.start, m.start + 500);
      final String? near = _safeRegex(
        r'<img[^>]+(?:data-original|data-src|src)="([^"]+)"',
        caseInsensitive: true,
      )?.firstMatch(window)?.group(1);
      if (near != null && near.isNotEmpty) pic = near;
      if (pic.isEmpty) {
        pic = _safeRegex(r'<img[^>]+src="([^"]+)"')?.firstMatch(html)?.group(1) ?? '';
      }
      items.add(VodItem(
        vodId: detailUrl,
        vodName: title,
        vodPic: pic,
        vodRemarks: '☁️${site.name}',
      ));
    }
    return items;
  }

  /// binhd 搜索结果解析（对齐 iOS `extractBinhdSearchItems`）。
  List<VodItem> _extractBinhdItems(String html, CloudSiteConfig site) {
    final RegExp? re = _safeRegex(
      r'<h2[^>]*>\s*<a[^>]*href="(/resources/[^"]+)"[^>]*>(.+?)</a>',
      dotAll: true,
    );
    if (re == null) return const <VodItem>[];
    final List<VodItem> items = <VodItem>[];
    final Set<String> seen = <String>{};
    for (final RegExpMatch m in re.allMatches(html)) {
      final String? path = m.group(1);
      final String? inner = m.group(2);
      if (path == null || inner == null) continue;
      final String title = _stripTags(inner);
      final String detailUrl =
          path.startsWith('http') ? path : site.detailBase + path;
      if (title.isEmpty || !seen.add(detailUrl)) continue;

      // 封面图在标题之上：向前 500 / 向后 200 窗口内按 alt 含"封面"定位。
      final String window = _snippet(html, m.start - 500, m.start + 200);
      final String pic = _safeRegex(
            r'<img[^>]+src="([^"]+)"[^>]*alt="[^"]*封面"',
            caseInsensitive: true,
          )?.firstMatch(window)?.group(1) ??
          '';
      items.add(VodItem(
        vodId: detailUrl,
        vodName: title,
        vodPic: pic,
        vodRemarks: '☁️${site.name}',
      ));
    }
    return items;
  }

  /// 从 HTML 提取全部网盘分享链接（对齐 iOS `parseCloudLinksFromHTML`）。
  List<VodItem> _parseCloudLinks(String html, CloudSiteConfig site) {
    final List<(String, String)> patterns = <(String, String)>[
      (r'(https?://115cdn\.com/s/[^\s"<>\x27\\]*)', '115网盘'),
      (r'(https?://(?:www\.)?(?:aliyundrive\.com|alipan\.com)/s/[^\s"<>\x27\\]*)',
          '阿里云盘'),
      (r'(https?://pan\.quark\.cn/s/[^\s"<>\x27\\]*)', '夸克网盘'),
      (r'(https?://pan\.baidu\.com/s/[^\s"<>\x27\\]*)', '百度网盘'),
      (r'(https?://(?:drive|pan)\.uc\.cn/s/[^\s"<>\x27\\]*)', 'UC网盘'),
      (r'(https?://cloud\.189\.cn/[^\s"<>\x27\\]*)', '天翼云盘'),
      (r'(https?://yun\.139\.com/[^\s"<>\x27\\]*)', '139云盘'),
      (r'(https?://www\.123[a-z0-9]+\.com/s/[a-zA-Z0-9\-]+)', '123云盘'),
    ];
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

    final List<VodItem> items = <VodItem>[];
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
            _snippet(html, m.start - 800, m.start + 200),
          );
        }
        if (!seen.add(panUrl)) continue;

        String name = '$driveName-${site.name}';
        // 页面标题优先（排除搜索结果页泛标题）。
        final String pageTitle = _safeRegex(
              r'<title>(.+?)</title>',
              caseInsensitive: true,
            )?.firstMatch(_snippet(html, 0, m.start))?.group(1)?.trim() ??
            '';
        if (pageTitle.length > 2 && !pageTitle.contains('搜索')) {
          name = pageTitle;
        }
        // 链接周围上下文里的候选标题。
        final String ctx = _snippet(html, m.start - 800, m.start + 200);
        for (final String np in const <String>[
          r'<a[^>]*title="([^"]+)"[^>]*>\s*(?:</a>)?',
          r'<h[1-4][^>]*>([^<]+)</h[1-4]>',
          r'alt="([^"]{2,40})"',
        ]) {
          final String? cand =
              _safeRegex(np, caseInsensitive: true)?.firstMatch(ctx)?.group(1)?.trim();
          if (cand != null &&
              cand.length > 2 &&
              cand.length < 80 &&
              !cand.contains('pan.quark') &&
              !cand.contains('pan.baidu') &&
              !cand.contains('aliyundrive') &&
              !cand.contains('alipan.com') &&
              cand != site.name) {
            name = cand;
            break;
          }
        }
        items.add(VodItem(
          vodId: panUrl,
          vodName: name,
          vodPic: '',
          vodRemarks: site.name,
        ));
      }
    }
    return items;
  }

  /// 天翼云盘访问码补全（对齐 iOS `enrichTianyiAccessCode`）。
  ///
  /// 缺访问码的有密码分享会让 shareinfo 返回 400，这里把 fragment / 周围文本中的
  /// 访问码并入 `?pwd=`（且必须插到 `#` 之前，否则会被并入 fragment 丢失）。
  String _enrichTianyiAccessCode(String url, String context) {
    if (!url.contains('cloud.189.cn')) return url;
    if (RegExp(r'(访问码|提取码|密码)[:：=\s]*[A-Za-z0-9]{4,}').hasMatch(url) ||
        RegExp(r'[?&]pwd=[A-Za-z0-9]{4,}').hasMatch(url) ||
        RegExp(r'[?&]accessCode=[A-Za-z0-9]{4,}').hasMatch(url)) {
      return url;
    }
    final RegExpMatch? frag = RegExp(r'#([A-Za-z0-9]{4,8})$').firstMatch(url);
    if (frag != null) {
      final String code = frag.group(1) ?? '';
      if (code.isEmpty) return url;
      final String head = url.substring(0, frag.start);
      final String sep = head.contains('?') ? '&' : '?';
      return '$head${sep}pwd=$code';
    }
    final RegExpMatch? m =
        RegExp(r'(访问码|提取码|密码)[:：\s]*([A-Za-z0-9]{4,8})').firstMatch(context);
    if (m == null) return url;
    final String code = m.group(0)!
        .replaceAll(RegExp(r'(访问码|提取码|密码)[:：\s]*'), '')
        .trim();
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

  // ───────────────────────── 基础设施 ─────────────────────────

  Future<String?> _fetchText(
    String url, {
    required String ua,
    Map<String, String>? extraHeaders,
  }) async {
    final Uri? uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }
    try {
      final HttpClientResponse res = await _client
          .get(uri, headers: <String, String>{
            'User-Agent': ua,
            ...?extraHeaders,
          })
          .timeout(kCloudRequestTimeout);
      if (!res.isOk) return null;
      return res.text;
    } catch (_) {
      return null;
    }
  }

  /// SPA 结果列表归一（对齐 iOS `resultField` 点分取值 + PanSou 扁平化）。
  List<Map<String, Object?>> _spaResultList(Object? decoded, String? resultField) {
    Object? current = decoded;
    if (resultField != null && resultField.isNotEmpty) {
      for (final String key in resultField.split('.')) {
        if (current is Map && current.containsKey(key)) {
          current = current[key];
        } else {
          current = null;
          break;
        }
      }
    } else if (decoded is Map) {
      current = decoded.containsKey('data') ? decoded['data'] : decoded;
    }

    if (current is List) {
      return current
          .whereType<Map<Object?, Object?>>()
          .map((Map<Object?, Object?> e) => e.cast<String, Object?>())
          .toList(growable: false);
    }
    if (current is Map) {
      final List<Map<String, Object?>> flat = <Map<String, Object?>>[];
      for (final Object? v in current.values) {
        if (v is List) {
          flat.addAll(v
              .whereType<Map<Object?, Object?>>()
              .map((Map<Object?, Object?> e) => e.cast<String, Object?>()));
        }
      }
      if (flat.isNotEmpty) return flat;
      return <Map<String, Object?>>[current.cast<String, Object?>()];
    }
    return const <Map<String, Object?>>[];
  }

  /// JSON 字段取值（兼容数字型 id，对齐 iOS `NSNumber.stringValue`）。
  String? _asUrlValue(Object? raw) {
    if (raw is String) return raw.isEmpty ? null : raw;
    if (raw is int) return '$raw';
    if (raw is double) {
      return raw == raw.roundToDouble() ? '${raw.toInt()}' : '$raw';
    }
    return null;
  }

  String _encodeKeyword(String keyword) => Uri.encodeQueryComponent(keyword);

  String _stripTags(String s) => s.replaceAll(RegExp(r'<[^>]+>'), '').trim();

  /// 取 [src] 的 `[start, end)` 片段（UTF-16 索引，与 `RegExpMatch.start` 同口径）。
  String _snippet(String src, int start, int end) {
    final int s = start < 0 ? 0 : start;
    final int e = end > src.length ? src.length : end;
    if (s >= e) return '';
    return src.substring(s, e);
  }

  RegExp? _safeRegex(
    String pattern, {
    bool dotAll = false,
    bool caseInsensitive = false,
  }) {
    try {
      return RegExp(
        pattern,
        dotAll: dotAll,
        caseSensitive: !caseInsensitive,
      );
    } catch (_) {
      return null;
    }
  }

  List<VodItem> _dedupeById(List<VodItem> items) {
    final Set<String> seen = <String>{};
    final List<VodItem> out = <VodItem>[];
    for (final VodItem item in items) {
      if (seen.add(item.vodId)) out.add(item);
    }
    return out;
  }
}