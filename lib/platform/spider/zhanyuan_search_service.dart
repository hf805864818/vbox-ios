/// 平台层：站源原生搜索服务（第 2 轮批次 B · B-11）。
///
/// 逆向来源：iOS `vbox/Services/ZhanyuanSearchService.swift` —— 原方案用 JS
/// 引擎跑站源搜索，iOS 侧已改为原生 Swift（Kanna HTML/XPath）实现，本文件
/// 为其 Dart 移植：**复用 B-09 HTTP 桥**做请求/解码（契约 §4.2 探测链唯一
/// 实现 `decodeResponseBody`），**复用 `core/html/xpath_engine.dart` **做
/// 最小 XPath 子集求值，本层只做 URL 构建、`&&&` 语法归一、两种解析模式
/// （XPath 规则 / 详情页 URL 模板）与播放列表解析。
///
/// 与 iOS 的对齐偏差（登记）：
/// - HTTP 解码：iOS `detectAndDecodeHTML` 自实现探测链，Dart 侧由
///   [SpiderHttpBridge]（B-09）统一接入契约 §4.2，**不重复实现**；
/// - 关键词 URL 编码：iOS `.urlQueryAllowed` 允许 `&?/=+` 等 query 保留字符
///   原样透传（几乎不编码），Dart 侧 [encodeKeyword] 手动对齐（空格→`%20`）；
/// - 播放列表 `detailxl`（线路名）在 iOS `parsePlayListByXPath` 中被提取但
///   未参与返回值（空逻辑），Dart 侧不提取，结果零差异。
library;

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' show parse;

import '../../core/html/xpath_engine.dart';
import '../../data/models/zhanyuan.dart';
import '../../domain/entities/spider/spider_models.dart';
import 'spider_http_bridge.dart';

/// 站源原生搜索服务（单站搜索 + 详情解析；并发编排见领域层 usecase）。
class ZhanyuanSearchService {
  /// 构造。
  ///
  /// [bridge] 注入用于离线单测（传 fake transport）；默认走 B-09 `IoSpiderHttpTransport`。
  ZhanyuanSearchService({SpiderHttpBridge? bridge, this.timeout = const Duration(seconds: 5)})
      : _bridge = bridge ?? SpiderHttpBridge();

  final SpiderHttpBridge _bridge;

  /// 单站/详情请求超时（iOS `timeoutInterval = 5`）。
  final Duration timeout;

  // ─────────────── 邮箱简短辅助（对齐 iOS static helpers） ───────────────

  /// 关键词 URL 编码（对齐 iOS `.urlQueryAllowed`：query 允许字符原样透传，
  /// 其余按 UTF-8 percent 编码，空格 → `%20`）。
  static String encodeKeyword(String keyword) {
    const String allowed = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
        'abcdefghijklmnopqrstuvwxyz'
        '0123456789'
        r"!$&'()*+,-./:;=?@_~";
    final StringBuffer out = StringBuffer();
    for (final int rune in keyword.runes) {
      final String ch = String.fromCharCode(rune);
      if (rune < 128 && allowed.contains(ch)) {
        out.write(ch);
      } else {
        out.write(Uri.encodeComponent(ch));
      }
    }
    return out.toString();
  }

  /// 将站源配置的 `&&&class-name&&&` 语法归一为标准 XPath（对齐 iOS `normalizeXPath`）。
  static String normalizeXPath(String xpath) {
    if (xpath.isEmpty) return xpath;
    String result = xpath;
    // [@class=&&&xxx&&&] -> [contains(@class, 'xxx')]
    result = result.replaceAllMapped(
      RegExp(r'\[@class=&&&([^&]*)&&&\]'),
      (Match m) => "[contains(@class, '${m.group(1)}')]",
    );
    // 其它属性 [@attr=&&&xxx&&&] -> [@attr='xxx']
    result = result.replaceAllMapped(
      RegExp(r'\[@(\w+)=&&&([^&]*)&&&\]'),
      (Match m) => "[@${m.group(1)}='${m.group(2)}']",
    );
    return result;
  }

  /// 根据站源配置构建搜索 URL（对齐 iOS `buildSearchURL`）。
  static String? buildSearchURL(Zhanyuan site, String keyword) {
    final String encoded = encodeKeyword(keyword);

    // 1. 优先 websearchurl
    if (site.websearchurl.isNotEmpty) {
      final String url = site.websearchurl;
      final bool hasPlaceholder =
          url.contains('wd=') || url.contains('keyword') || url.contains('searchword');

      if (hasPlaceholder) {
        String searchURL = url.replaceAll('**', encoded);
        final int wdIdx = searchURL.indexOf('wd=');
        if (wdIdx >= 0) {
          final String afterWd = searchURL.substring(wdIdx + 3);
          if (afterWd.isEmpty || afterWd == '**' || afterWd.startsWith('&')) {
            searchURL = searchURL.substring(0, wdIdx + 3) + encoded;
          }
        }
        return searchURL;
      }
      // 不带 wd=/keyword/searchword，替换 ** 后追加 wd=
      final String searchURL = url.replaceAll('**', encoded);
      final String separator = searchURL.contains('?') ? '&' : '?';
      return '$searchURL${separator}wd=$encoded';
    }

    // 2. websearchurl 为空 → 标准 Apple CMS 搜索 URL
    //    （searchid 在此场景是详情页 URL 模板，不能直接用作搜索）
    final String baseURL = site.searchUrl.replaceAll(RegExp(r'^/+|/+$'), '');
    return '$baseURL/vodsearch/-------------.html?wd=$encoded';
  }

  // ─────────────── 搜索 ───────────────

  /// 单个站点搜索（对齐 iOS `searchZhanyuan`）。
  Future<List<VodItem>> searchZhanyuan(Zhanyuan site, String keyword) async {
    final String? urlString = buildSearchURL(site, keyword);
    if (urlString == null || urlString.isEmpty) return <VodItem>[];

    final String ua = site.searchUA.isEmpty ? Zhanyuan.defaultUA : site.searchUA;
    final SpiderHttpResult res = await _bridge.request(
      urlString,
      options: SpiderHttpOptions(
        timeout: timeout,
        headers: <String, String>{
          'User-Agent': ua,
          'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        },
      ),
    );
    if (!res.ok) return <VodItem>[];
    final String html = res.content;
    if (html.isEmpty) return <VodItem>[];

    final dom.Document doc = parse(html);

    final bool searchidIsTemplate = (site.searchid.startsWith('http') ||
            site.searchid.startsWith('/')) &&
        site.searchid.contains('#');

    if (searchidIsTemplate) {
      return parseSearchByTemplate(doc, site);
    }
    return parseSearchByXPath(doc, site);
  }

  // ─────────────── XPath 模式解析 ───────────────

  /// 用 XPath 规则解析搜索结果（对齐 iOS `parseSearchByXPath`）。
  List<VodItem> parseSearchByXPath(dom.Document doc, Zhanyuan site) {
    final List<VodItem> items = <VodItem>[];
    final String host = _trimSlashes(site.searchUrl);

    final List<String> names =
        XPathEngine.extractStrings(doc, normalizeXPath(site.searchname));
    final List<String> ids =
        XPathEngine.extractStrings(doc, normalizeXPath(site.searchid));
    final List<String> pics = site.searchpic.isEmpty
        ? const <String>[]
        : XPathEngine.extractStrings(doc, normalizeXPath(site.searchpic));
    final List<String> stars = site.searchstarr.isEmpty
        ? const <String>[]
        : XPathEngine.extractStrings(doc, normalizeXPath(site.searchstarr));

    final int count = <int>[names.length, ids.length, 50].fold(
      1 << 30,
      (int acc, int n) => n < acc ? n : acc,
    );
    for (int i = 0; i < count; i++) {
      final String name = names[i].trim();
      String id = ids[i].trim();
      if (name.isEmpty || name.length < 2) continue;

      id = completeURL(id, host);

      String pic = '';
      if (i < pics.length) {
        pic = completeImageURL(pics[i].trim(), host);
      }
      final String remarks = i < stars.length ? stars[i].trim() : '';

      // vodRemarks 始终用站点名（按站点分组）；备注拼到 vodName 后
      final String displayName = remarks.isEmpty ? name : '$name $remarks';
      items.add(VodItem(
        vodId: id,
        vodName: displayName,
        vodPic: pic,
        vodRemarks: site.name,
      ));
    }
    return items;
  }

  /// 用详情页 URL 模板解析搜索结果（对齐 iOS `parseSearchByTemplate`）。
  List<VodItem> parseSearchByTemplate(dom.Document doc, Zhanyuan site) {
    final List<VodItem> items = <VodItem>[];
    final String host = _trimSlashes(site.searchUrl);

    const List<String> linkSelectors = <String>[
      "//a[contains(@href, 'detail')]",
      "//a[contains(@href, 'vod')]",
      "//a[contains(@href, '/id/')]",
      "//a[contains(@href, '.html')]",
      "//*[contains(@class, 'module-card-item')]//a",
      "//*[contains(@class, 'search-list-item')]//a",
      "//*[contains(@class, 'stui-vodlist__thumb')]//a",
      "//*[contains(@class, 'vodlist')]//li//a",
      '//li//a',
    ];

    List<dom.Element> links = <dom.Element>[];
    for (final String selector in linkSelectors) {
      final List<dom.Element> results = XPathEngine.queryDocument(doc, selector);
      if (results.isNotEmpty) {
        links = results;
        break;
      }
    }

    final Set<String> seenNames = <String>{};
    for (final dom.Element link in links) {
      if (items.length >= 30) break;
      final String? href = link.attributes['href'];
      if (href == null || href.isEmpty) continue;

      String name = link.text.trim();

      if (name.isEmpty || name.length < 2) {
        const List<String> titleSelectors = <String>[
          './/title',
          ".//*[contains(@class, 'title')]",
          ".//*[contains(@class, 'name')]",
          './/strong',
          './/h3',
          './/h4',
          './/span',
        ];
        for (final String ts in titleSelectors) {
          final List<dom.Element> titleResults =
              XPathEngine.queryContext(link, ts);
          if (titleResults.isNotEmpty) {
            final String t = titleResults.first.text.trim();
            if (t.isNotEmpty) {
              name = t;
              break;
            }
          }
        }
      }

      if (name.isEmpty || name.length < 2) continue;
      if (name == '首页' || name == '分类' || name == 'APP') continue;
      if (seenNames.contains(name)) continue;
      seenNames.add(name);

      String pic = '';
      final List<dom.Element> imgResults =
          XPathEngine.queryContext(link, './/img');
      if (imgResults.isNotEmpty) {
        final dom.Element imgEl = imgResults.first;
        pic = imgEl.attributes['data-original'] ??
            imgEl.attributes['data-src'] ??
            imgEl.attributes['src'] ??
            '';
        pic = completeImageURL(pic, host);
      }

      items.add(VodItem(
        vodId: completeURL(href, host),
        vodName: name,
        vodPic: pic,
        vodRemarks: site.name,
      ));
    }
    return items;
  }

  // ─────────────── 详情页 ───────────────

  /// 解析 zhanyuan 站点详情页，返回含播放列表的 [VodItem]（对齐 iOS `fetchDetail`）。
  Future<VodItem> fetchDetail(String detailUrl, Zhanyuan site) async {
    final String ua = site.playUA.isEmpty ? site.searchUA : site.playUA;
    final String host = _trimSlashes(site.searchUrl);

    final SpiderHttpResult res = await _bridge.request(
      detailUrl,
      options: SpiderHttpOptions(
        timeout: timeout,
        headers: <String, String>{
          'User-Agent': ua,
          'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        },
      ),
    );
    if (!res.ok || res.content.isEmpty) {
      throw const ZhanyuanDetailException('返回空内容或 HTTP 错误');
    }

    final dom.Document doc = parse(res.content);

    // 标题
    String vodName = '';
    List<dom.Element> els = XPathEngine.queryDocument(doc, '//h1');
    if (els.isNotEmpty) vodName = els.first.text.trim();
    if (vodName.isEmpty) {
      els = XPathEngine.queryDocument(doc, '//title');
      if (els.isNotEmpty) vodName = els.first.text.trim();
    }
    if (vodName.isEmpty) {
      const List<String> fallbacks = <String>[
        "//div[contains(@class,'slide-info-title')]",
        "//div[contains(@class,'video-info-header')]//span",
        "//div[contains(@class,'module-heading-title')]",
      ];
      for (final String fb in fallbacks) {
        els = XPathEngine.queryDocument(doc, fb);
        if (els.isNotEmpty) {
          vodName = els.first.text.trim();
          if (vodName.isNotEmpty) break;
        }
      }
    }

    // 图片
    String vodPic = '';
    const List<String> imgSelectors = <String>[
      "//div[contains(@class,'slide-info-cover')]//img",
      "//div[contains(@class,'video-info-cover')]//img",
      "//div[contains(@class,'module-item-pic')]//img",
      '//img[@data-pic]',
      '//img',
    ];
    for (final String isel in imgSelectors) {
      final List<dom.Element> imgs = XPathEngine.queryDocument(doc, isel);
      if (imgs.isNotEmpty) {
        final dom.Element imgEl = imgs.first;
        vodPic = imgEl.attributes['data-original'] ??
            imgEl.attributes['data-src'] ??
            imgEl.attributes['src'] ??
            '';
        if (vodPic.isNotEmpty) {
          vodPic = completeImageURL(vodPic, host);
          break;
        }
      }
    }

    final String playUrl = parsePlayList(doc, site, host);

    return VodItem(
      vodId: detailUrl,
      vodName: vodName,
      vodPic: vodPic,
      vodRemarks: site.name,
      vodPlayFrom: site.name,
      vodPlayUrl: playUrl,
    );
  }

  /// 解析播放列表：优先 XPath 规则，无规则/失败用通用选择器兜底。
  String parsePlayList(dom.Document doc, Zhanyuan site, String host) {
    if (site.detaillist.isNotEmpty) {
      final List<String> urls = parsePlayListByXPath(doc, site, host);
      if (urls.isNotEmpty) {
        return urls.join('#');
      }
    }
    return parsePlayListGeneric(doc, host).join('#');
  }

  /// 用站点的 XPath 规则解析播放列表（对齐 iOS `parsePlayListByXPath`）。
  ///
  /// 注意：iOS 原文提取 `detailxl`（线路名）后未参与返回值，此处不提取。
  List<String> parsePlayListByXPath(dom.Document doc, Zhanyuan site, String host) {
    final String listXPath = normalizeXPath(site.detaillist);
    final List<String> playUrls = <String>[];

    final List<dom.Element> containers =
        XPathEngine.queryDocument(doc, listXPath);
    if (containers.isEmpty) return <String>[];

    final bool hasDetailRules =
        site.detailjs.isNotEmpty && site.detailjsurl.isNotEmpty;

    for (final dom.Element container in containers) {
      if (hasDetailRules) {
        final List<String> episodeNames = XPathEngine.extractStringsFromElement(
          container,
          normalizeXPath(site.detailjs),
        );
        final List<String> episodeUrls = XPathEngine.extractStringsFromElement(
          container,
          normalizeXPath(site.detailjsurl),
        );
        if (episodeNames.isNotEmpty && episodeUrls.isNotEmpty) {
          final int count = <int>[episodeNames.length, episodeUrls.length, 500]
              .fold(1 << 30, (int acc, int n) => n < acc ? n : acc);
          for (int i = 0; i < count; i++) {
            final String epName = episodeNames[i].trim();
            final String epUrl = completeURL(episodeUrls[i].trim(), host);
            if (epName.isEmpty && epUrl.isEmpty) continue;
            playUrls.add('$epName\$$epUrl');
          }
        }
      } else {
        final List<dom.Element> links =
            XPathEngine.queryContext(container, './/a');
        for (final dom.Element linkEl in links) {
          final String epName = linkEl.text.trim();
          final String? href = linkEl.attributes['href'];
          if (epName.isEmpty || href == null || href.isEmpty) continue;
          playUrls.add('$epName\$${completeURL(href, host)}');
        }
      }
    }
    return playUrls;
  }

  /// 通用播放列表提取（无 XPath 规则兜底，对齐 iOS `parsePlayListGeneric`）。
  List<String> parsePlayListGeneric(dom.Document doc, String host) {
    const List<String> selectors = <String>[
      "//*[contains(@class,'playlist')]//a",
      "//*[contains(@class,'play-list')]//a",
      "//*[contains(@class,'stui-content__playlist')]//a",
      "//*[contains(@class,'module-play-list')]//a",
      "//*[@id='y-playList']//a",
      "//*[@id='playlist']//a",
      "//*[contains(@class,'video-list')]//a",
      "//*[contains(@class,'vodlist')]//a",
    ];
    for (final String selector in selectors) {
      final List<dom.Element> results =
          XPathEngine.queryDocument(doc, selector);
      if (results.isEmpty) continue;
      final List<String> playUrls = <String>[];
      for (final dom.Element el in results) {
        final String epName = el.text.trim();
        final String? href = el.attributes['href'];
        if (epName.isEmpty || href == null || href.isEmpty) continue;
        playUrls.add('$epName\$${completeURL(href, host)}');
      }
      if (playUrls.isNotEmpty) return playUrls;
    }
    return const <String>[];
  }

  // ─────────────── URL 补全 ───────────────

  /// 补全 URL（对齐 iOS `completeURL`）。
  static String completeURL(String url, String base) {
    final String trimmed = url.trim();
    if (trimmed.isEmpty) return trimmed;
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return trimmed;
    }
    if (trimmed.startsWith('//')) return 'https:$trimmed';
    if (trimmed.startsWith('/')) return '$base$trimmed';
    return '$base/$trimmed';
  }

  /// 补全图片 URL（对齐 iOS `completeImageURL`）。
  static String completeImageURL(String url, String base) {
    final String trimmed = url.trim();
    if (trimmed.isEmpty) return '';
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return trimmed;
    }
    if (trimmed.startsWith('//')) return 'https:$trimmed';
    if (trimmed.startsWith('/')) return '$base$trimmed';
    return '$base/$trimmed';
  }

  /// trim 首尾 `/` 字符（对齐 iOS `trimmingCharacters(in: "/")`）。
  static String _trimSlashes(String s) => s.replaceAll(RegExp(r'^/+|/+$'), '');
}

/// 站源详情解析异常（对齐 iOS `NSError(domain: "ZhanyuanDetail")`）。
class ZhanyuanDetailException implements Exception {
  const ZhanyuanDetailException(this.message);

  final String message;

  @override
  String toString() => 'ZhanyuanDetailException: $message';
}