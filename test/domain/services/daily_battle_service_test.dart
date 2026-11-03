/// 领域层单测：每日大乱斗 / 每日大赛服务（UI-C1b）。
///
/// 覆盖：域名探测（普通内容页直用）/ 首页分类解析（导航栏）/
/// 分类视频列表（article + `@folder` 目录标记）/ 搜索 / 详情（`.dplayer`
/// `data-config` → `name$url` 模式）/ 封面对称解密（CBC 命中，非图片原样）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/one_platform/one_platform_crypto.dart';
import 'package:vbox/domain/entities/welfare/fuli_models.dart';
import 'package:vbox/domain/services/daily_battle_service.dart';
import 'package:vbox/platform/spider/spider_http_bridge.dart';

/// 假传输：按 URL 关键字返回既定 HTML（未命中 → 404）。
class _FakeTransport implements SpiderHttpTransport {
  _FakeTransport(this.routes);

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

const String _host = 'border.bshzjjgq.cc';

/// 首页 HTML：导航分类 + 一个 article（含 `article` 供探测判定为内容页）。
const String _homeHtml = '''
<html><body>
<nav><a href="/category/mrld/">今日乱斗</a><a href="/category/bkdg/">必看大瓜</a></nav>
<article class="post-card"><a href="/post/1.html">
<img data-src="/img/1.jpg"><h2>首页视频一</h2></a></article>
</body></html>
''';

/// 分类页 HTML：两个 article，第二条为外链（白名单内，应保留）。
const String _categoryHtml = '''
<html><body>
<article class="post-card"><a href="/post/11.html">
<img data-src="/img/11.jpg"><h2>分类视频甲</h2><time>12:34</time></a></article>
<article class="post-card"><a href="https://border.bshzjjgq.cc/post/12.html">
<img src="/img/12.jpg"><h2>分类视频乙</h2></a></article>
</body></html>
''';

/// 详情页 HTML：`.dplayer` 的 `data-config.video.url` + 标签。
const String _detailHtml = '''
<html><body>
<div class="dplayer" data-config="{&quot;video&quot;:{&quot;url&quot;:&quot;https://cdn.example.com/v/1.m3u8&quot;}}"></div>
<a class="tags">标签A</a>
</body></html>
''';

void main() {
  test('域名探测：普通内容页（含 article）→ 首个入口即就绪', () async {
    final DailyBattleFuliService service = DailyBattleFuliService(
      bridge: _bridge(<String, String>{_host: _homeHtml}),
    );
    expect(service.isHostReady, isFalse);

    await service.probeHosts();

    expect(service.isHostReady, isTrue);
    expect(service.currentHost, contains(_host));
  });

  test('首页：导航栏解析分类 + article 推荐视频', () async {
    final DailyBattleFuliService service = DailyBattleFuliService(
      bridge: _bridge(<String, String>{_host: _homeHtml}),
    );

    final FuliHomeResult home = await service.fetchHomeContent();

    expect(home.categories.map((FuliCategory c) => c.typeName), <String>[
      '今日乱斗',
      '必看大瓜',
    ]);
    expect(home.categories.first.typeId, '/category/mrld/');
    expect(home.videos.map((FuliVideo v) => v.vodName), <String>['首页视频一']);
  });

  test('首页：解析不到分类 → 回退内置分类', () async {
    final DailyBattleFuliService service = DailyBattleFuliService(
      bridge: _bridge(<String, String>{_host: '<html>article 但无导航</html>'}),
    );

    final FuliHomeResult home = await service.fetchHomeContent();

    expect(
      home.categories.map((FuliCategory c) => c.typeName),
      <String>['今日乱斗', '必看大瓜'],
    );
  });

  test('分类列表：解析 article + 白名单外链保留 + 时长备注', () async {
    final DailyBattleFuliService service = DailyBattleFuliService(
      bridge: _bridge(<String, String>{
        '$_host/category/mrld/': _categoryHtml,
        _host: _homeHtml,
      }),
    );
    await service.probeHosts();

    final FuliCategoryResult result = await service.fetchCategoryContent(
      category: const FuliCategory(typeId: '/category/mrld/', typeName: '今日乱斗'),
      page: 1,
    );

    expect(result.videos.length, 2);
    expect(result.videos.first.vodName, '分类视频甲');
    expect(result.videos.first.vodId, '/post/11.html');
    expect(result.videos.first.vodPic, 'https://$_host/img/11.jpg');
    expect(result.videos.first.vodRemarks, '12:34');
    expect(result.videos[1].vodId, 'https://$_host/post/12.html');
    expect(result.hasMore, isFalse);
  });

  test('搜索：`/search/<kw>/` 命中即返回', () async {
    final DailyBattleFuliService service = DailyBattleFuliService(
      bridge: _bridge(<String, String>{
        '$_host/search/abc/': _categoryHtml,
        _host: _homeHtml,
      }),
    );
    await service.probeHosts();

    final FuliSearchResult result =
        await service.fetchSearch(keyword: 'abc', page: 1);

    expect(result.videos.length, 2);
    expect(result.videos.first.vodName, '分类视频甲');
  });

  test('详情：`.dplayer` 的 data-config.video.url → 单集 + 标签名', () async {
    final DailyBattleFuliService service = DailyBattleFuliService(
      bridge: _bridge(<String, String>{
        '$_host/post/1.html': _detailHtml,
        _host: _homeHtml,
      }),
    );
    await service.probeHosts();

    final FuliDetail detail = await service.fetchDetail('/post/1.html');

    expect(detail.episodes, hasLength(1));
    expect(detail.episodes.first.url, 'https://cdn.example.com/v/1.m3u8');
    expect(detail.vodName, '标签A');
  });

  test('fetchPlayerURL：直链 → parse 0；网页地址 → parse 1', () async {
    final DailyBattleFuliService service = DailyBattleFuliService(
      bridge: _bridge(<String, String>{_host: _homeHtml}),
    );

    final FuliPlayerResult direct = await service.fetchPlayerURL(
      const FuliEpisode(name: '视频1', url: 'https://cdn.example.com/a.m3u8'),
    );
    final FuliPlayerResult page = await service.fetchPlayerURL(
      const FuliEpisode(name: '视频1', url: 'https://$_host/post/1.html'),
    );

    expect(direct.parse, 0);
    expect(page.parse, 1);
  });

  test('封面解密：已是图片（JPEG 魔数）原样返回', () {
    final Uint8List jpeg = Uint8List.fromList(<int>[
      0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46,
      0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01,
    ]);

    expect(decodeDailyBattleImageBytes(jpeg), same(jpeg));
  });

  test('封面解密：CBC 密文（密钥对 1）解密还原图片魔数', () {
    final List<int> key = utf8.encode('f5d965df75336270');
    final List<int> iv = utf8.encode('97b60394abc2fbe1');
    // 明文字节：JPEG SOI + 少量内容（PKCS7 补齐后加密）。
    final List<int> plain = <int>[0xFF, 0xD8, 0xFF, 0xE0, 0x11, 0x22, 0x33];
    final List<int>? cipher =
        OnePlatformCrypto.cbcEncrypt(key, iv, plain);
    expect(cipher, isNotNull);

    final Uint8List out = decodeDailyBattleImageBytes(
      Uint8List.fromList(cipher!),
    );

    expect(out, plain);
  });

  test('封面解密：非图片且无法解密 → 原样返回', () {
    final Uint8List garbage =
        Uint8List.fromList(List<int>.filled(16, 0x37));

    expect(decodeDailyBattleImageBytes(garbage), same(garbage));
  });

  test('serviceFor：同 platformKey + 平台名复用实例；clearCache 后重建', () {
    DailyBattleFuliService.clearCache();
    final DailyBattleFuliService a = DailyBattleFuliService.serviceFor(
      platformKey: 'daily_battle',
      platformName: '每日大乱斗',
    );
    final DailyBattleFuliService b = DailyBattleFuliService.serviceFor(
      platformKey: 'daily_battle',
      platformName: '每日大乱斗',
    );
    expect(identical(a, b), isTrue);
    expect(a.siteName, '每日大乱斗');

    // 每日大赛 → 站点配置切换。
    final DailyBattleFuliService contest = DailyBattleFuliService.serviceFor(
      platformKey: 'daily_battle',
      platformName: '每日大赛',
    );
    expect(contest.siteName, '每日大赛');

    DailyBattleFuliService.clearCache();
    expect(
      identical(
        DailyBattleFuliService.serviceFor(
          platformKey: 'daily_battle',
          platformName: '每日大乱斗',
        ),
        a,
      ),
      isFalse,
    );
  });
}