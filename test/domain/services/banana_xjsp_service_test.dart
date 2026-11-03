/// 领域层单测：香蕉秀 XJSP 服务（UI-C1a）。
///
/// 覆盖：域名探测（分类接口 `retcode == 0`）/ 分类解析与硬编码回退 /
/// 分类视频列表（`vodrows` + 分页阈值 16）/ 短视频列表（`mini:` 前缀）/
/// 演员导航（`actorrows`）/ 专题视频（`/special/detail`）/
/// 播放地址（`httpurl` → `httpurls[0]`、HTTP 升级 HTTPS、VIP `preview_url`
/// 重建）/ 详情单集占位 / 实例复用。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/welfare/banana_mini_video.dart';
import 'package:vbox/domain/entities/welfare/fuli_models.dart';
import 'package:vbox/domain/services/banana_xjsp_service.dart';
import 'package:vbox/platform/spider/spider_http_bridge.dart';

/// 假传输：按 URL 关键字返回既定响应（未命中 → 404）。
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
          headers: <String, String>{
            'content-type': 'application/json; charset=utf-8',
          },
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

/// 分类接口路径（兼作域名探测探针）。
const String _categoriesPath = '/vod/listing-0-0-0-0-0-0-0-0-0-1';

/// 分类接口响应（2 类）。
const String _categoriesJson = '{"retcode":0,"errmsg":"ok","data":{"categories":['
    '{"cateid":"9","catename":"国产精品"},'
    '{"cateid":"16","catename":"香蕉原创"}]}}';

/// 分类视频列表（含 `preview_url`，供 VIP 回退用例）。
const String _videosJson = '{"retcode":0,"data":{"vodrows":['
    '{"vodid":"vod1","title":"视频一","coverpic":"https://img.1.jpg",'
    '"duration":"12:34","scorenum":"8.5","areaname":"国产",'
    '"preview_url":"https://tscdn.example.com/preview.m3u8"},'
    '{"vodid":"vod2","title":"视频二","coverpic":"https://img.2.jpg",'
    '"duration":"01:02"}]}}';

/// 短视频列表（`vodrow` 内嵌视频体 + `user` 内嵌作者）。
const String _miniJson = '{"retcode":0,"data":{"rows":['
    '{"vodrow":{"vodid":"mv1","title":"短视频一",'
    '"coverpic":"https://img.m1.jpg","duration":"00:15"},'
    '"user":{"nickname":"作者甲"}},'
    '{"vodid":"mv2","title":"短视频二","coverpic":"https://img.m2.jpg"}]}}';

/// 演员导航（`actorrows`）。
const String _actorsJson = '{"retcode":0,"data":{"rows":[],"actorrows":['
    '{"spid":"sp1","spname":"演员甲","coverpic":"https://img.sp1.jpg",'
    '"itemcount":"12"}]}}';

/// 专题内视频列表（`vodrows`）。
const String _specialVideosJson = '{"retcode":0,"data":{"vodrows":['
    '{"vodid":"sv1","title":"专题视频一","coverpic":"https://img.sv1.jpg",'
    '"duration":"03:00","scorenum":"9.0"}]}}';

/// 预览 m3u8（VIP 重建用：KEY host + TS 目录）。
const String _previewM3U8 = '#EXTM3U\n'
    '#EXT-X-KEY:METHOD=AES-128,URI="https://keycdn.example.com/key"\n'
    '#EXTINF:10,\n'
    'https://tscdn.example.com/hls/abc/seg1.ts\n';

void main() {
  test('域名探测：分类接口 retcode == 0 → 就绪', () async {
    final BananaXjspFuliService service = BananaXjspFuliService(
      bridge: _bridge(<String, String>{_categoriesPath: _categoriesJson}),
    );
    expect(service.isHostReady, isFalse);

    await service.probeHosts();

    expect(service.isHostReady, isTrue);
    expect(service.currentHost, 'https://zfvwi8.ipajx0.cc');
  });

  test('域名探测：retcode != 0 → 未就绪', () async {
    final BananaXjspFuliService service = BananaXjspFuliService(
      bridge: _bridge(<String, String>{
        _categoriesPath: '{"retcode":1,"errmsg":"denied"}',
      }),
    );

    await service.probeHosts();

    expect(service.isHostReady, isFalse);
  });

  test('首页：分类解析（cateid + catename）', () async {
    final BananaXjspFuliService service = BananaXjspFuliService(
      bridge: _bridge(<String, String>{_categoriesPath: _categoriesJson}),
    );

    final FuliHomeResult home = await service.fetchHomeContent();

    expect(home.categories.map((FuliCategory c) => c.typeName), <String>[
      '国产精品',
      '香蕉原创',
    ]);
    expect(home.categories.first.typeId, '9');
    // 首页视频由分类网格独立分页（与大乱斗同口径）。
    expect(home.videos, isEmpty);
  });

  test('首页：分类接口失败 → 回退 9 个硬编码分类', () async {
    final BananaXjspFuliService service = BananaXjspFuliService(
      bridge: _bridge(<String, String>{}),
    );

    final FuliHomeResult home = await service.fetchHomeContent();

    expect(
      home.categories.map((FuliCategory c) => c.typeName),
      <String>[
        '推荐',
        '国产精品',
        '辣妹大奶',
        '日本无码',
        '情欲女同',
        '日韩专区',
        '香蕉原创',
        '中文字幕',
        '动漫专区',
      ],
    );
  });

  test('分类列表：vodrows → FuliVideo（评分 / 地区 / 时长）+ 记录 preview_url',
      () async {
    final BananaXjspFuliService service = BananaXjspFuliService(
      bridge: _bridge(<String, String>{
        '/vod/listing-9-0-0-0-0-0-0-0-0-1': _videosJson,
        _categoriesPath: _categoriesJson,
      }),
    );

    final FuliCategoryResult result = await service.fetchCategoryContent(
      category: const FuliCategory(typeId: '9', typeName: '国产精品'),
      page: 1,
    );

    expect(result.videos, hasLength(2));
    expect(result.videos.first.vodId, 'vod1');
    expect(result.videos.first.vodName, '视频一');
    expect(result.videos.first.vodPic, 'https://img.1.jpg');
    expect(result.videos.first.score, '8.5');
    expect(result.videos.first.areaName, '国产');
    expect(result.videos.first.duration, '12:34');
    // 对齐 iOS `hasMore = count >= 16`。
    expect(result.hasMore, isFalse);
    expect(
      service.previewUrls['vod1'],
      'https://tscdn.example.com/preview.m3u8',
    );
  });

  test('分类列表：满 16 条 → hasMore', () async {
    final String rows = List<String>.generate(
      16,
      (int i) =>
          '{"vodid":"v$i","title":"t$i","coverpic":"https://img/$i.jpg"}',
    ).join(',');
    final BananaXjspFuliService service = BananaXjspFuliService(
      bridge: _bridge(<String, String>{
        '/vod/listing-9-0-0-0-0-0-0-0-0-1':
            '{"retcode":0,"data":{"vodrows":[$rows]}}',
        _categoriesPath: _categoriesJson,
      }),
    );

    final FuliCategoryResult result = await service.fetchCategoryContent(
      category: const FuliCategory(typeId: '9', typeName: '国产精品'),
      page: 1,
    );

    expect(result.videos, hasLength(16));
    expect(result.hasMore, isTrue);
  });

  test('短视频列表：vodrow + user 解析（裸 vodId，作者昵称 / 头像）', () async {
    final BananaXjspFuliService service = BananaXjspFuliService(
      bridge: _bridge(<String, String>{
        '/minivod/reqlist': _miniJson,
        _categoriesPath: _categoriesJson,
      }),
    );

    final List<BananaMiniVideo> videos =
        await service.fetchMiniVideos(page: 1);

    expect(videos, hasLength(2));
    expect(videos.first.vodId, 'mv1');
    expect(videos.first.title, '短视频一');
    expect(videos.first.userName, '作者甲');
    // 端点由 mini: 前缀在播放链路补足（服务返回裸 id）。
    expect(BananaXjspFuliService.miniVodPrefix, 'mini:');
    // 无 vodrow 包装时回落到行本身。
    expect(videos[1].title, '短视频二');
  });

  test('演员导航：actorrows → BananaXjspSpecial', () async {
    final BananaXjspFuliService service = BananaXjspFuliService(
      bridge: _bridge(<String, String>{
        '/special/listing-0-0-1': _actorsJson,
        _categoriesPath: _categoriesJson,
      }),
    );

    final List<BananaXjspSpecial> actors = await service.fetchActors(page: 1);

    expect(actors, hasLength(1));
    expect(actors.first.spId, 'sp1');
    expect(actors.first.name, '演员甲');
    expect(actors.first.cover, 'https://img.sp1.jpg');
    expect(actors.first.itemCount, 12);
  });

  test('专题视频：/special/detail/{spId}-{page} → vodrows', () async {
    final BananaXjspFuliService service = BananaXjspFuliService(
      bridge: _bridge(<String, String>{
        '/special/detail/sp1-1': _specialVideosJson,
        _categoriesPath: _categoriesJson,
      }),
    );

    final List<FuliVideo> videos =
        await service.fetchSpecialVideos(spId: 'sp1', page: 1);

    expect(videos, hasLength(1));
    expect(videos.first.vodId, 'sv1');
    expect(videos.first.score, '9.0');
  });

  test('详情：单集占位（播放地址在 fetchPlayerURL 现取）', () async {
    final BananaXjspFuliService service = BananaXjspFuliService(
      bridge: _bridge(<String, String>{_categoriesPath: _categoriesJson}),
    );

    final FuliDetail detail = await service.fetchDetail('vod1');

    expect(detail.episodes, hasLength(1));
    expect(detail.episodes.first.name, '正片');
    expect(detail.episodes.first.url, 'vod1');
    expect(detail.playFrom, '香蕉秀');
  });

  test('播放地址：httpurl → parse 0 + HTTP 升级 HTTPS', () async {
    final BananaXjspFuliService service = BananaXjspFuliService(
      bridge: _bridge(<String, String>{
        '/vod/reqplay/vod1':
            '{"retcode":0,"data":{"httpurl":"http://cdn.example.com/a.m3u8"}}',
        _categoriesPath: _categoriesJson,
      }),
    );

    final FuliPlayerResult result = await service.fetchPlayerURL(
      const FuliEpisode(name: '正片', url: 'vod1'),
    );

    expect(result.url, 'https://cdn.example.com/a.m3u8');
    expect(result.parse, 0);
    // 长视频不额外注入请求头（对齐 iOS `VodItem` 路径）。
    expect(result.headers, isEmpty);
  });

  test('播放地址：httpurl 缺失 → 回退 httpurls[0].httpurl', () async {
    final BananaXjspFuliService service = BananaXjspFuliService(
      bridge: _bridge(<String, String>{
        '/vod/reqplay/vod1': '{"retcode":0,"data":{"httpurl":"","httpurls":['
            '{"httpurl":"https://cdn.example.com/b.m3u8"}]}}',
        _categoriesPath: _categoriesJson,
      }),
    );

    expect(await service.fetchPlayUrl('vod1'), 'https://cdn.example.com/b.m3u8');
  });

  test('播放地址：短视频（mini:）→ /minivod/reqplay + Referer/UA 头', () async {
    final BananaXjspFuliService service = BananaXjspFuliService(
      bridge: _bridge(<String, String>{
        '/minivod/reqplay/mv1':
            '{"retcode":0,"data":{"httpurl":"https://cdn.example.com/m.m3u8"}}',
        _categoriesPath: _categoriesJson,
      }),
    );

    final FuliPlayerResult result = await service.fetchPlayerURL(
      const FuliEpisode(
        name: '正片',
        url: '${BananaXjspFuliService.miniVodPrefix}mv1',
      ),
    );

    expect(result.url, 'https://cdn.example.com/m.m3u8');
    expect(result.headers['Referer'], 'https://zfvwi8.ipajx0.cc/');
    expect(result.headers['User-Agent'], isNotNull);
  });

  test('播放地址：retcode 5（VIP）→ preview_url 重建完整 m3u8', () async {
    final BananaXjspFuliService service = BananaXjspFuliService(
      bridge: _bridge(<String, String>{
        '/vod/listing-9-0-0-0-0-0-0-0-0-1': _videosJson,
        '/vod/reqplay/vod1': '{"retcode":5,"errmsg":"vip"}',
        '/preview.m3u8': _previewM3U8,
        _categoriesPath: _categoriesJson,
      }),
    );
    // 先经列表页登记 preview_url。
    await service.fetchVideos(cateId: '9', page: 1);

    expect(
      await service.fetchPlayUrl('vod1'),
      'https://keycdn.example.com/hls/abc/index.m3u8',
    );
  });

  test('播放地址：retcode != 0 且无 preview → 空结果（播放器提示）', () async {
    final BananaXjspFuliService service = BananaXjspFuliService(
      bridge: _bridge(<String, String>{
        '/vod/reqplay/vod1': '{"retcode":1,"errmsg":"no url"}',
        _categoriesPath: _categoriesJson,
      }),
    );

    final FuliPlayerResult result = await service.fetchPlayerURL(
      const FuliEpisode(name: '正片', url: 'vod1'),
    );

    expect(result.url, isEmpty);
  });

  test('serviceFor：复用实例；clearCache 后重建', () {
    BananaXjspFuliService.clearCache();
    final BananaXjspFuliService a = BananaXjspFuliService.serviceFor();
    expect(identical(a, BananaXjspFuliService.serviceFor()), isTrue);
    expect(a.siteName, '香蕉秀');
    expect(a.platformKey, 'ybox_xiangjiao');

    BananaXjspFuliService.clearCache();
    expect(identical(a, BananaXjspFuliService.serviceFor()), isFalse);
  });
}
