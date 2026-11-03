/// 领域层单测：今日看料服务（UI-C1e）。
///
/// 覆盖：域名探测（含「正文含 article」判定）/ 分类解析（导航栏 + 内置回退）/
/// 分类视频列表（article 容器 + 绝对页面地址）/ 搜索（tag 优先）/
/// 播放地址提取（video 标签 + m3u8 文本）/ `parse` 标记（直链 0 / 网页 1）。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/welfare/fuli_models.dart';
import 'package:vbox/domain/services/kanliao_service.dart';
import 'package:vbox/platform/spider/spider_http_bridge.dart';

/// 假传输：按 URL 关键字返回既定 HTML（未命中 → 404）。
class _FakeTransport implements SpiderHttpTransport {
  _FakeTransport(this.routes);

  /// `url 关键字 → HTML`。
  final Map<String, String> routes;

  @override
  Future<SpiderTransportResponse> send(SpiderTransportRequest request) async {
    final String url = request.url.toString();
    for (final MapEntry<String, String> e in routes.entries) {
      if (url.contains(e.key)) {
        return SpiderTransportResponse(
          status: 200,
          headers: <String, String>{'content-type': 'text/html; charset=utf-8'},
          bodyBytes: utf8.encode(e.value),
        );
      }
    }
    return const SpiderTransportResponse(
      status: 404,
      headers: <String, String>{},
      bodyBytes: <int>[],
    );
  }
}

SpiderHttpBridge _bridge(Map<String, String> routes) =>
    SpiderHttpBridge(transport: _FakeTransport(routes));

/// 首页 HTML：导航分类 + 两个 article 视频（含 `article` 供探测判定）。
const String _homeHtml = '''
<html><body>
<nav class="navbar"><ul>
<a href="/category/dy/">抖音</a>
<a href="/category/ks/">快手</a>
<a href="/category/hy/">虎牙</a>
<a href="/category/wh/">网红</a>
</ul></nav>
<article class="post-card"><a href="/post/1.html">
<img data-src="/img/1.jpg"><h2>视频一</h2></a></article>
<article class="post-card"><a href="/post/2.html">
<img data-src="/img/2.jpg"><h2>视频二</h2></a></article>
</body></html>
''';

/// 分类页 HTML：两个 article（绝对/相对链接混合）。
const String _categoryHtml = '''
<html><body>
<article class="post-card"><a href="/post/11.html">
<img data-src="/img/11.jpg"><h2>分类视频甲</h2></a></article>
<article class="post-card"><a href="https://kanliao7.org/post/12.html">
<img src="/img/12.jpg"><h2>分类视频乙</h2></a></article>
</body></html>
''';

/// 详情页 HTML：直接给出 m3u8（走到文本提取路径）。
const String _detailHtml = '''
<html><head><title>详情标题 - 今日看料</title></head><body>
<video src="https://cdn.example.com/v/1.m3u8"></video>
</body></html>
''';

void main() {
  test('域名探测：首个「正文含 article」的域名即就绪', () async {
    final KanliaoFuliService service = KanliaoFuliService(
      bridge: _bridge(<String, String>{'kanliao7.org': _homeHtml}),
    );
    expect(service.isHostReady, isFalse);

    await service.probeHosts();

    expect(service.isHostReady, isTrue);
    expect(service.currentHost, contains('kanliao7.org'));
  });

  test('域名探测：仅 2xx 但正文不含 article → 不就绪，回落首个默认域名', () async {
    final KanliaoFuliService service = KanliaoFuliService(
      bridge: _bridge(<String, String>{'kanliao2.one': '<html>无关键字</html>'}),
    );

    await service.probeHosts();

    expect(service.isHostReady, isFalse);
    expect(service.currentHost, 'https://kanliao2.one');
  });

  test('分类：导航栏解析命中 4 个分类', () async {
    final KanliaoFuliService service = KanliaoFuliService(
      bridge: _bridge(<String, String>{'kanliao2.one': _homeHtml}),
    );

    final List<FuliCategory> categories = await service.fetchCategories();

    expect(categories.map((FuliCategory c) => c.typeName), <String>[
      '抖音',
      '快手',
      '虎牙',
      '网红',
    ]);
    expect(categories.first.typeId, '/category/dy/');
  });

  test('分类：解析不到 → 回退 11 个内置分类', () async {
    final KanliaoFuliService service = KanliaoFuliService(
      bridge: _bridge(<String, String>{
        'kanliao2.one': '<html><body>article 但无导航</body></html>',
      }),
    );

    final List<FuliCategory> categories = await service.fetchCategories();

    expect(categories.length, 11);
    expect(categories.first.typeName, '热点关注');
  });

  test('分类视频列表：解析 article 容器 + vodId 采用绝对页面地址', () async {
    final KanliaoFuliService service = KanliaoFuliService(
      bridge: _bridge(<String, String>{
        'kanliao2.one/category/dy/': _categoryHtml,
        'kanliao2.one': _homeHtml,
      }),
    );
    await service.probeHosts();

    final FuliCategoryResult result = await service.fetchCategoryContent(
      category: const FuliCategory(typeId: '/category/dy/', typeName: '抖音'),
      page: 1,
    );

    expect(result.videos.length, 2);
    expect(result.videos.first.vodName, '分类视频甲');
    expect(
      result.videos.first.vodId,
      'https://kanliao2.one/post/11.html',
    );
    expect(result.videos.first.vodPic, 'https://kanliao2.one/img/11.jpg');
    expect(result.videos[1].vodId, 'https://kanliao7.org/post/12.html');
    expect(result.hasMore, isFalse);
  });

  test('搜索：tag 页面命中即返回', () async {
    final KanliaoFuliService service = KanliaoFuliService(
      bridge: _bridge(<String, String>{
        '/tag/': _categoryHtml,
        'kanliao2.one': _homeHtml,
      }),
    );
    await service.probeHosts();

    final FuliSearchResult result =
        await service.fetchSearch(keyword: '测试', page: 1);

    expect(result.videos.length, 2);
    expect(result.videos.first.vodName, '分类视频甲');
  });

  test('详情：从 video 标签提取 m3u8 播放地址', () async {
    final KanliaoFuliService service = KanliaoFuliService(
      bridge: _bridge(<String, String>{
        'kanliao2.one/post/1.html': _detailHtml,
        'kanliao2.one': _homeHtml,
      }),
    );
    await service.probeHosts();

    final FuliDetail detail =
        await service.fetchDetail('https://kanliao2.one/post/1.html');

    expect(detail.episodes, hasLength(1));
    expect(detail.episodes.first.url, 'https://cdn.example.com/v/1.m3u8');
    expect(detail.vodName, '详情标题');
  });

  test('parse 标记：直链 m3u8 → 0；网页地址 → 1', () async {
    final KanliaoFuliService service = KanliaoFuliService(
      bridge: _bridge(<String, String>{'kanliao2.one': _homeHtml}),
    );

    final FuliPlayerResult direct = await service.fetchPlayerURL(
      const FuliEpisode(name: '高清', url: 'https://cdn.example.com/a.m3u8'),
    );
    final FuliPlayerResult page = await service.fetchPlayerURL(
      const FuliEpisode(name: '高清', url: 'https://kanliao2.one/post/1.html'),
    );

    expect(direct.parse, 0);
    expect(page.parse, 1);
  });

  test('fetchHomeContent：分类 + 首个分类视频', () async {
    final KanliaoFuliService service = KanliaoFuliService(
      bridge: _bridge(<String, String>{
        'kanliao2.one/category/dy/': _categoryHtml,
        'kanliao2.one': _homeHtml,
      }),
    );

    final FuliHomeResult home = await service.fetchHomeContent();

    expect(home.categories, isNotEmpty);
    expect(home.videos, isNotEmpty);
  });

  test('serviceFor：同 platformKey 复用实例；clearCache 后重建', () {
    KanliaoFuliService.clearCache();
    final KanliaoFuliService a = KanliaoFuliService.serviceFor();
    final KanliaoFuliService b = KanliaoFuliService.serviceFor();
    expect(identical(a, b), isTrue);

    KanliaoFuliService.clearCache();
    expect(identical(KanliaoFuliService.serviceFor(), a), isFalse);
  });
}