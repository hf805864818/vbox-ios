/// 领域层单测：远程可配置 CMS V10 福利源服务（UI-C1c）。
///
/// 对齐 iOS `vbox/Services/RemoteCMSV10Service.swift`：
///   · `service(for:)` 实例缓存；内容类型 / 图片防盗链覆写；
///   · JSON 模式抓取契约（`ac=list` 分类 / `ac=detail` 列表 / 详情 / 搜索）；
///   · `$$$` 线路组 + `$` 名称/地址对剧集解析；
///   · 漫画套图（`vod_content` 提取 `<img>`，无则回退封面）；
///   · 根分类收敛 + `childDiscovery == type_id_1` 子分类归属 / 聚合；
///   · 请求头：JSON 模式 Android UA、图文 HTML 模式 Safari UA + 白名单自定义头；
///   · 图文 HTML 模式（`apiKind == mac_art_html`）列表 / 详情正则解析。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/welfare/fuli_models.dart';
import 'package:vbox/domain/entities/welfare/welfare_platform_config.dart';
import 'package:vbox/domain/services/fuli_base_service.dart';
import 'package:vbox/domain/services/remote_cms_v10_service.dart';
import 'package:vbox/platform/spider/spider_http_bridge.dart';

/// 假传输：按 URL 关键字（插入顺序，首个命中生效）返回既定正文；未命中 → 404。
class _FakeTransport implements SpiderHttpTransport {
  _FakeTransport(this.routes);

  final Map<String, String> routes;

  /// 依次收到的请求（断言请求头 / 探测链用）。
  final List<SpiderTransportRequest> requests = <SpiderTransportRequest>[];

  @override
  Future<SpiderTransportResponse> send(SpiderTransportRequest request) async {
    requests.add(request);
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

const String _host = 'https://cms.example.com';

/// 末位兜底路由：任何请求都回 200（供域名探测判定可达）。
const String _hostKey = 'cms.example.com';

SpiderHttpBridge _bridge(_FakeTransport transport) =>
    SpiderHttpBridge(transport: transport);

/// 组装路由（具体键在前，宿主兜底键在末位）。
_FakeTransport _transport(Map<String, String> routes) => _FakeTransport(
      <String, String>{...routes, _hostKey: '<html>ok</html>'},
    );

WelfarePlatform _platform({
  String platformKey = 'cms-1',
  String name = '远程CMS',
  WelfarePlatformCategory category = WelfarePlatformCategory.video,
  String? contentType,
  String? apiPath,
  String? rootTypeId,
  String? rootTypeName,
  String? childDiscovery,
  String? itemPlayUrlRule,
  String? detailMode,
  String? apiKind,
  String? imageReferer,
  bool imageSSLBypass = false,
  Map<String, String> headers = const <String, String>{},
  List<String> hosts = const <String>[_host],
}) =>
    WelfarePlatform(
      platformKey: platformKey,
      name: name,
      category: category,
      serviceType: 'remote_cms_v10',
      defaultHosts: hosts,
      contentType: contentType,
      apiPath: apiPath,
      rootTypeId: rootTypeId,
      rootTypeName: rootTypeName,
      childDiscovery: childDiscovery,
      itemPlayUrlRule: itemPlayUrlRule,
      detailMode: detailMode,
      apiKind: apiKind,
      imageReferer: imageReferer,
      imageSSLBypass: imageSSLBypass,
      headers: headers,
    );

// ─────────────── 固定响应体 ───────────────

const String _classJson =
    '{"code":1,"class":[{"type_id":"1","type_name":"电影"},'
    '{"type_id":"2","type_name":"剧集"}]}';

const String _listJson =
    '{"code":1,"page":1,"pagecount":5,"limit":2,"list":['
    '{"vod_id":"101","vod_name":"视频甲","vod_pic":"/pic/1.jpg",'
    '"vod_remarks":"更新至2集","vod_play_url":"第1集\$https://cdn.example.com/a.m3u8"},'
    '{"vod_id":"102","vod_name":"视频乙",'
    '"vod_pic":"https://cdn.example.com/pic/2.jpg",'
    '"vod_play_url":"第1集\$https://cdn.example.com/b.mp4"}]}';

const String _detailJson =
    '{"list":[{"vod_id":"101","vod_name":"视频甲","vod_pic":"/pic/1.jpg",'
    '"vod_content":"<p>剧情简介</p>","vod_play_from":"线路A",'
    '"vod_play_url":"第1集\$https://cdn.example.com/a.m3u8#第2集\$https://cdn.example.com/a2.m3u8"}]}';

const String _searchJson =
    '{"page":1,"pagecount":1,"limit":20,"list":['
    '{"vod_id":"201","vod_name":"搜索结果","vod_pic":"/pic/3.jpg",'
    '"vod_play_url":"第1集\$https://cdn.example.com/c.m3u8"}]}';

/// 漫画列表：无 `vod_play_url`（`empty` 规则下才允许）。
const String _comicListJson =
    '{"class":[{"type_id":"5","type_name":"套图"}],"list":['
    '{"vod_id":"301","vod_name":"套图A","vod_pic":"/pic/3.jpg"}]}';

/// 漫画详情：`vod_content` 内嵌 `<img>`。
const String _comicDetailJson =
    '{"list":[{"vod_id":"301","vod_name":"套图A","vod_pic":"/pic/3.jpg",'
    '"vod_content":"<img src=\\"/img/1.jpg\\"><img data-src=\\"/img/2.jpg\\">"}]}';

const String _articleListHtml = '''
<html><body>
<a href="/arttype/34.html">性感美女</a>
<a href="/artdetail-101.html"><img data-src="/img/101.jpg">套图标题一</a>
<a href="/artdetail-102.html"><img data-src="/img/102.jpg">套图标题二</a>
</body></html>
''';

const String _articleDetailHtml = '''
<html><body><h1>套图标题一</h1>
<img src="/img/101.jpg"><img data-original="/img/101b.jpg">
</body></html>
''';

void main() {
  setUp(RemoteCmsV10FuliService.clearCache);

  test('serviceFor：同 platformKey 复用实例；clearCache 后重建', () {
    final WelfarePlatform platform = _platform();
    final RemoteCmsV10FuliService a =
        RemoteCmsV10FuliService.serviceFor(platform);
    final RemoteCmsV10FuliService b =
        RemoteCmsV10FuliService.serviceFor(platform);
    expect(identical(a, b), isTrue);

    RemoteCmsV10FuliService.clearCache();
    final RemoteCmsV10FuliService c =
        RemoteCmsV10FuliService.serviceFor(platform);
    expect(identical(a, c), isFalse);
  });

  test('内容类型：category == comic 或 contentType == comic → 漫画；否则视频', () {
    expect(
      RemoteCmsV10FuliService(
        platform: _platform(category: WelfarePlatformCategory.comic),
      ).contentCategory,
      FuliContentCategory.comic,
    );
    expect(
      RemoteCmsV10FuliService(
        platform: _platform(contentType: 'comic'),
      ).contentCategory,
      FuliContentCategory.comic,
    );
    expect(
      RemoteCmsV10FuliService(platform: _platform()).contentCategory,
      FuliContentCategory.video,
    );
  });

  test('图片防盗链：imageReferer / imageSSLBypass 取平台配置', () {
    final RemoteCmsV10FuliService service = RemoteCmsV10FuliService(
      platform: _platform(
        imageReferer: 'https://img.example.com/',
        imageSSLBypass: true,
      ),
    );
    expect(service.imageReferer, 'https://img.example.com/');
    expect(service.imageSSLBypass, isTrue);
  });

  test('域名探测：首个可达域名（2xx）即就绪', () async {
    final RemoteCmsV10FuliService service = RemoteCmsV10FuliService(
      platform: _platform(),
      bridge: _bridge(_transport(<String, String>{})),
    );
    expect(service.isHostReady, isFalse);

    await service.probeHosts();

    expect(service.isHostReady, isTrue);
    expect(service.currentHost, _host);
  });

  test('首页 JSON 模式：ac=list 解析分类 + 首个分类列表', () async {
    final RemoteCmsV10FuliService service = RemoteCmsV10FuliService(
      platform: _platform(),
      bridge: _bridge(_transport(<String, String>{
        'ac=list': _classJson,
        'ac=detail&t=1&pg=1': _listJson,
      })),
    );

    final FuliHomeResult home = await service.fetchHomeContent();

    expect(
      home.categories.map((FuliCategory c) => c.typeName),
      <String>['电影', '剧集'],
    );
    expect(home.categories.first.typeId, '1');
    expect(home.videos.map((FuliVideo v) => v.vodName), <String>['视频甲', '视频乙']);
  });

  test('分类列表：ac=detail&t=&pg= 解析（封面归一 / 备注 / hasMore）', () async {
    final RemoteCmsV10FuliService service = RemoteCmsV10FuliService(
      platform: _platform(),
      bridge: _bridge(_transport(<String, String>{
        'ac=detail&t=1&pg=1': _listJson,
      })),
    );

    final FuliCategoryResult result = await service.fetchCategoryContent(
      category: const FuliCategory(typeId: '1', typeName: '电影'),
      page: 1,
    );

    expect(result.videos.length, 2);
    expect(result.videos.first.vodId, '101');
    // 相对封面补全当前域名。
    expect(result.videos.first.vodPic, 'https://cms.example.com/pic/1.jpg');
    expect(result.videos.first.vodRemarks, '更新至2集');
    // pagecount(5) > page(1) → 还有下一页。
    expect(result.hasMore, isTrue);
    expect(result.page, 1);
  });

  test('详情：\$\$\$ 线路组 + \$ 名称/地址对 → 剧集', () async {
    final RemoteCmsV10FuliService service = RemoteCmsV10FuliService(
      platform: _platform(),
      bridge: _bridge(_transport(<String, String>{
        'ac=detail&ids=101': _detailJson,
      })),
    );

    final FuliDetail detail = await service.fetchDetail('101');

    expect(detail.vodName, '视频甲');
    expect(detail.playFrom, '线路A');
    expect(detail.episodes.map((FuliEpisode e) => e.name), <String>['第1集', '第2集']);
    expect(
      detail.episodes.map((FuliEpisode e) => e.url),
      <String>[
        'https://cdn.example.com/a.m3u8',
        'https://cdn.example.com/a2.m3u8',
      ],
    );
  });

  test('搜索：ac=detail&wd=&pg= → 结果 + hasMore', () async {
    final RemoteCmsV10FuliService service = RemoteCmsV10FuliService(
      platform: _platform(),
      bridge: _bridge(_transport(<String, String>{
        'ac=detail&wd=abc&pg=1': _searchJson,
      })),
    );

    final FuliSearchResult result =
        await service.fetchSearch(keyword: 'abc', page: 1);

    expect(result.videos.map((FuliVideo v) => v.vodName), <String>['搜索结果']);
    expect(result.hasMore, isFalse);
  });

  test('fetchPlayerURL：直链 m3u8/mp4 → parse 0；网页地址 → parse 1', () async {
    final RemoteCmsV10FuliService service = RemoteCmsV10FuliService(
      platform: _platform(),
    );

    final FuliPlayerResult direct = await service.fetchPlayerURL(
      const FuliEpisode(name: '第1集', url: 'https://cdn.example.com/a.m3u8'),
    );
    expect(direct.parse, 0);
    expect(direct.url, 'https://cdn.example.com/a.m3u8');
    expect(direct.headers['User-Agent'], contains('Android'));

    final FuliPlayerResult page = await service.fetchPlayerURL(
      const FuliEpisode(name: '第1集', url: 'https://site.example.com/play/1'),
    );
    expect(page.parse, 1);
  });

  test('漫画套图：detailMode == comic_images → 从 vod_content 提取 <img>', () async {
    final RemoteCmsV10FuliService service = RemoteCmsV10FuliService(
      platform: _platform(
        category: WelfarePlatformCategory.comic,
        detailMode: 'comic_images',
      ),
      bridge: _bridge(_transport(<String, String>{
        'ac=detail&ids=301': _comicDetailJson,
      })),
    );

    final FuliDetail detail = await service.fetchDetail('301');

    expect(detail.episodes.single.name, '浏览套图');
    expect(detail.episodes.single.images, <String>[
      'https://cms.example.com/img/1.jpg',
      'https://cms.example.com/img/2.jpg',
    ]);
  });

  test('漫画列表：缺省规则 empty → 保留无播放入口项（有播放地址项被过滤）', () async {
    final RemoteCmsV10FuliService service = RemoteCmsV10FuliService(
      platform: _platform(category: WelfarePlatformCategory.comic),
      bridge: _bridge(_transport(<String, String>{
        'ac=list': _comicListJson,
        'ac=detail&t=5&pg=1': _listJson,
      })),
    );

    final FuliHomeResult home = await service.fetchHomeContent();

    // `_listJson` 两项都带 `vod_play_url` → 漫画 empty 规则全部过滤。
    expect(home.videos, isEmpty);
  });

  test('根分类：rootTypeId 收敛 + childDiscovery == type_id_1 归属筛选 + 父级聚合', () async {
    const String t9 =
        '{"list":[{"type_id_1":"33","vod_id":"901","vod_name":"子分类视频",'
        '"vod_pic":"/p/9.jpg","vod_play_url":"1\$https://cdn.example.com/9.m3u8"}]}';
    const String t10 =
        '{"list":[{"type_id_1":"33","vod_id":"1001","vod_name":"日韩视频",'
        '"vod_pic":"/p/10.jpg","vod_play_url":"1\$https://cdn.example.com/10.m3u8"}]}';

    final RemoteCmsV10FuliService service = RemoteCmsV10FuliService(
      platform: _platform(
        rootTypeId: '33',
        rootTypeName: '福利图',
        childDiscovery: 'type_id_1',
      ),
      bridge: _bridge(_transport(<String, String>{
        'ac=list': '{"class":[{"type_id":"33","type_name":"福利图"},'
            '{"type_id":"9","type_name":"国产"},{"type_id":"10","type_name":"日韩"}]}',
        'ac=detail&t=9&pg=1': t9,
        'ac=detail&t=10&pg=1': t10,
        'ac=detail&t=33&pg=1': '{"list":[]}',
      })),
    );

    final FuliHomeResult home = await service.fetchHomeContent();

    expect(home.categories.length, 1);
    expect(home.categories.single.typeId, '33');
    expect(home.categories.single.typeName, '福利图');
    expect(
      home.categories.single.subCategories?.map((FuliCategory c) => c.typeId),
      <String>['9', '10'],
    );
    // 父级 t=33 无数据 → 聚合子分类视频。
    expect(home.videos.map((FuliVideo v) => v.vodId), <String>['901', '1001']);
  });

  test('请求头：JSON 模式 Android UA + 白名单自定义头；非白名单键不透传', () async {
    final _FakeTransport transport = _transport(<String, String>{
      'ac=detail&wd=x&pg=1': _searchJson,
    });
    final RemoteCmsV10FuliService service = RemoteCmsV10FuliService(
      platform: _platform(headers: <String, String>{
        'Referer': 'https://site.example.com/',
        'X-Custom': 'secret',
      }),
      bridge: _bridge(transport),
    );

    await service.fetchSearch(keyword: 'x', page: 1);

    final Map<String, String> headers = transport.requests.last.headers;
    expect(headers['User-Agent'], contains('Android'));
    expect(headers['Referer'], 'https://site.example.com/');
    // 非白名单键（X-Custom）不透传。
    expect(headers.containsKey('X-Custom'), isFalse);
  });

  test('图文 HTML 模式：分类 / 列表 / 详情 + Safari UA', () async {
    final _FakeTransport transport = _transport(<String, String>{
      '/arttype/33.html': _articleListHtml,
      '/artdetail-101.html': _articleDetailHtml,
    });
    final RemoteCmsV10FuliService service = RemoteCmsV10FuliService(
      platform: _platform(apiKind: 'mac_art_html'),
      bridge: _bridge(transport),
    );

    final FuliHomeResult home = await service.fetchHomeContent();

    expect(home.categories.single.typeId, '33');
    expect(
      home.categories.single.subCategories?.map((FuliCategory c) => c.typeName),
      <String>['性感美女'],
    );
    expect(
      home.videos.map((FuliVideo v) => v.vodName),
      <String>['套图标题一', '套图标题二'],
    );
    // 图文模式 Safari UA（取实际列表页请求；首条为域名探测，UA 由桥默认注入）。
    final SpiderTransportRequest listRequest = transport.requests.firstWhere(
      (SpiderTransportRequest r) => r.url.toString().contains('/arttype/'),
    );
    expect(listRequest.headers['User-Agent'], contains('Safari'));

    final FuliDetail detail = await service.fetchDetail('101');
    expect(detail.vodName, '套图标题一');
    expect(detail.episodes.single.images, <String>[
      'https://cms.example.com/img/101.jpg',
      'https://cms.example.com/img/101b.jpg',
    ]);
  });
}
