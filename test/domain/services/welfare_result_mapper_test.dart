/// 领域层单测：福利 Spider 结果映射（批次 H · H-03）。
///
/// 覆盖：home / category / detail / search / player 映射、剧集智能解析
/// （标准多线路 / 非标准直接分集）、漫画 `manga://` 协议解析。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/spider/spider_models.dart';
import 'package:vbox/domain/entities/welfare/fuli_models.dart';
import 'package:vbox/domain/services/welfare_result_mapper.dart';

const WelfareResultMapper mapper = WelfareResultMapper();

VodItem _vod({
  String id = '1',
  String name = '测试视频',
  String pic = 'https://cdn/p.jpg',
  String? remarks,
  String? playFrom,
  String? playUrl,
  String? content,
}) =>
    VodItem(
      vodId: id,
      vodName: name,
      vodPic: pic,
      vodRemarks: remarks,
      vodPlayFrom: playFrom,
      vodPlayUrl: playUrl,
      vodContent: content,
    );

void main() {
  group('mapHome', () {
    test('分类 + 视频映射为 FuliHomeResult', () {
      final FuliHomeResult result = mapper.mapHome(HomeContentResult(
        classes: const <VodCategory>[
          VodCategory(typeId: '1', typeName: '分类一'),
          VodCategory(typeId: '2', typeName: '分类二'),
        ],
        list: <VodItem>[
          _vod(id: 'a', name: '视频A'),
          _vod(id: 'b', name: '视频B', remarks: '更新至 12 集'),
        ],
      ));

      expect(result.categories, hasLength(2));
      expect(result.categories.first.typeId, '1');
      expect(result.categories.first.typeName, '分类一');
      expect(result.videos, hasLength(2));
      expect(result.videos.first.vodName, '视频A');
      expect(result.videos.last.vodRemarks, '更新至 12 集');
    });

    test('空 list / 空 class → 空结果', () {
      final FuliHomeResult result = mapper.mapHome(const HomeContentResult());
      expect(result.categories, isEmpty);
      expect(result.videos, isEmpty);
    });

    test('vodId 为空的条目被丢弃（对齐 iOS mapVideo）', () {
      final FuliHomeResult result = mapper.mapHome(HomeContentResult(
        list: <VodItem>[
          _vod(id: '', name: '无ID'),
          _vod(id: 'ok', name: '正常'),
        ],
      ));
      expect(result.videos, hasLength(1));
      expect(result.videos.single.vodName, '正常');
    });
  });

  group('mapCategory', () {
    test('page < pagecount → hasMore true', () {
      final FuliCategoryResult result = mapper.mapCategory(CategoryContentResult(
        page: 1,
        pagecount: 3,
        list: <VodItem>[_vod()],
      ));
      expect(result.page, 1);
      expect(result.videos, hasLength(1));
      expect(result.hasMore, isTrue);
    });

    test('page 缺省补 1、pagecount 缺省补 1 → hasMore false', () {
      final FuliCategoryResult result =
          mapper.mapCategory(const CategoryContentResult());
      expect(result.page, 1);
      expect(result.hasMore, isFalse);
    });
  });

  group('mapDetail', () {
    test('首个条目 → 详情 + 标准多线路剧集', () {
      final FuliDetail detail = mapper.mapDetail(DetailContentResult(
        list: <VodItem>[
          _vod(
            id: 'd1',
            name: '详情视频',
            content: '简介文本',
            playFrom: r'线路1$$$线路2',
            playUrl: '第1集\u0024u1#第2集\u0024u2\$\$\$第1集\u0024v1#第2集\u0024v2',
          ),
        ],
      ));

      expect(detail.vodId, 'd1');
      expect(detail.vodName, '详情视频');
      expect(detail.vodContent, '简介文本');
      expect(detail.playFrom, r'线路1$$$线路2');
      expect(detail.episodes, hasLength(4));
      expect(detail.episodes.first.name, '[线路1] 第1集');
      expect(detail.episodes.first.url, 'u1');
      expect(detail.episodes.last.name, '[线路2] 第2集');
    });

    test('空 list → 空详情兜底', () {
      final FuliDetail detail = mapper.mapDetail(const DetailContentResult());
      expect(detail.vodId, isEmpty);
      expect(detail.episodes, isEmpty);
    });
  });

  group('mapSearch', () {
    test('映射搜索结果', () {
      final FuliSearchResult result = mapper.mapSearch(SearchContentResult(
        page: 2,
        pagecount: 2,
        list: <VodItem>[_vod(id: 's1', name: '搜索命中')],
      ));
      expect(result.page, 2);
      expect(result.videos.single.vodName, '搜索命中');
      expect(result.hasMore, isFalse);
    });
  });

  group('mapPlayer', () {
    test('playUrl 优先于 url', () {
      final FuliPlayerResult r = mapper.mapPlayer(PlayerContentResult(
        playUrl: 'https://a/play.m3u8',
        url: 'https://b/x.m3u8',
        header: const <String, String>{'Referer': 'https://r/'},
        parse: 1,
      ));
      expect(r.url, 'https://a/play.m3u8');
      expect(r.headers['Referer'], 'https://r/');
      expect(r.parse, 1);
    });

    test('playUrl 为空 → url 回退', () {
      final FuliPlayerResult r =
          mapper.mapPlayer(PlayerContentResult(url: 'https://b/x.m3u8'));
      expect(r.url, 'https://b/x.m3u8');
      expect(r.headers, isEmpty);
      expect(r.parse, 0);
    });
  });

  group('parseEpisodes（智能判定）', () {
    test(r'标准格式：$$$ 分线路、# 分集、$ 分隔名与 URL', () {
      final List<FuliEpisode> eps = mapper.parseEpisodes(
        playFrom: '线路1',
        playUrl: '第1集\u0024u1#第2集\u0024u2',
      );
      expect(eps, hasLength(2));
      expect(eps[0].name, '第1集');
      expect(eps[0].url, 'u1');
      expect(eps[1].name, '第2集');
    });

    test(r'非标准格式：$$$ 直接分集（黄豆短剧）→ 智能命中非标准', () {
      final List<FuliEpisode> eps = mapper.parseEpisodes(
        playFrom: 'hd',
        playUrl: '第1集\u0024https://a/1.m3u8\$\$\$第2集\u0024https://a/2.m3u8'
            '\$\$\$第3集\u0024https://a/3.m3u8',
      );
      expect(eps, hasLength(3));
      expect(eps.first.name, '第1集');
      expect(eps.first.url, 'https://a/1.m3u8');
      expect(eps.last.name, '第3集');
    });

    test('空 playUrl → 空列表', () {
      expect(mapper.parseEpisodes(playFrom: 'x', playUrl: ''), isEmpty);
    });

    test('多线路标准格式 → 名称带 [线路] 前缀', () {
      final List<FuliEpisode> eps = mapper.parseEpisodes(
        playFrom: r'线路1$$$线路2',
        playUrl: '第1集\u0024u1#第2集\u0024u2\$\$\$第1集\u0024v1',
      );
      expect(eps, hasLength(3));
      expect(eps.first.name, '[线路1] 第1集');
      expect(eps.last.name, '[线路2] 第1集');
    });

    test('混合 http / 非 http 块：智能判定回落标准格式（对齐 iOS，不过滤）', () {
      // iOS `parseEpisodes`：非标准块 http 过滤只在 parseNonStandardFormat 内部，
      // 本输入智能判定回落标准格式（标准格式不做 http 过滤）→ 两个条目都保留。
      final List<FuliEpisode> eps = mapper.parseEpisodes(
        playFrom: 'x',
        playUrl: '第1集\u0024ftp://bad/1.m3u8\$\$\$第2集\u0024https://ok/2.m3u8',
      );
      expect(eps, hasLength(2));
      expect(eps.first.name, '第1集');
      expect(eps.first.url, 'ftp://bad/1.m3u8');
      expect(eps.last.name, '第2集');
      expect(eps.last.url, 'https://ok/2.m3u8');
    });
  });

  group('漫画协议解析', () {
    test('manga:// 协议 → 图片列表', () {
      final List<String> images =
          mapper.parseMangaURL('manga://https://a/1.jpg&&https://a/2.jpg');
      expect(images, hasLength(2));
      expect(images.first, 'https://a/1.jpg');
    });

    test('pics:// 协议 → 图片列表（去空白 + http 过滤）', () {
      final List<String> images =
          mapper.parseMangaURL('pics:// https://a/1.jpg &&bogus&&https://a/2.jpg ');
      expect(images, hasLength(2));
      expect(images[1], 'https://a/2.jpg');
    });

    test('非漫画协议 / 空内容 → 空列表', () {
      expect(mapper.parseMangaURL('https://plain/x.jpg'), isEmpty);
      expect(mapper.isMangaProtocol('https://plain/x.jpg'), isFalse);
      expect(mapper.isMangaProtocol('manga://x'), isTrue);
      expect(mapper.isMangaProtocol('pics://x'), isTrue);
    });
  });
}
