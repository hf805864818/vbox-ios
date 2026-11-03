/// 领域层单测：通用福利 Python Spider 服务（批次 H · H-03）。
///
/// 对齐 iOS `WelfarePythonSpiderService.swift`：
/// 覆盖内容类型映射（video / live / comic）、引擎初始化、`serviceFor`
/// 实例缓存、home / category / detail / search / player 抓取、
/// 漫画图片加载（`manga://` 快速路径 + playerContent 慢速路径）、
/// playFrom 提取（剧集名 `[线路X]` 优先 → 详情页首个线路 → 平台名）、
/// 引擎未就绪 / 返回空时回退基类默认实现。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/data/datasources/welfare/welfare_spider_loader.dart';
import 'package:vbox/domain/entities/spider/spider.dart';
import 'package:vbox/domain/entities/welfare/welfare.dart';
import 'package:vbox/domain/services/fuli_base_service.dart';
import 'package:vbox/domain/services/welfare_python_spider_service.dart';

/// 构造一个合规的 Python 福利 Spider 平台。
WelfarePlatform _platform({
  WelfarePlatformCategory category = WelfarePlatformCategory.video,
}) =>
    WelfarePlatform(
      platformKey: 'py-demo',
      name: 'Py演示',
      category: category,
      serviceType: 'python_spider',
      scriptType: 'python',
      api: './sources/welfare-js/py_demo.py',
      defaultHosts: const <String>['https://a.example.com'],
    );

WelfareSpiderScript _script() => WelfareSpiderScript(
      platformKey: 'py-demo',
      remoteURL: Uri.parse(
          'https://vbox-ai.github.io/api/sources/welfare-js/py_demo.py'),
      localURL: '/cache/welfare_spider/py_demo.py',
      content: 'import requests\nprint("demo")',
      loadedAt: DateTime(2026, 1, 1),
    );

/// 内存假加载器（重写 `loadScript`，不做真实 IO）。
class _FakeLoader extends WelfareSpiderLoader {
  _FakeLoader({this.script, this.failWith});

  final WelfareSpiderScript? script;
  final Object? failWith;

  int loadCount = 0;

  @override
  Future<WelfareSpiderScript> loadScript(WelfarePlatform platform) async {
    loadCount++;
    final Object? f = failWith;
    if (f != null) throw f;
    return script!;
  }

  @override
  WelfareSpiderScript? cachedScript(WelfarePlatform platform) => null;
}

/// 假 Python 桥引擎：记录全部调用，可按需返回各操作结果。
class _FakeSpiderEngine implements SpiderEngine {
  _FakeSpiderEngine({
    this.homeResult,
    this.categoryResult,
    this.searchResult,
    this.detailResult,
    this.playerResult,
  });

  final HomeContentResult? homeResult;
  final CategoryContentResult? categoryResult;
  final SearchContentResult? searchResult;
  final DetailContentResult? detailResult;
  final PlayerContentResult? playerResult;

  final List<String> calls = <String>[];
  bool ready = true;

  @override
  SpiderEngineType get engineType => SpiderEngineType.python;

  @override
  set onLog(void Function(String)? handler) {}

  @override
  Future<void> loadScript(String script) async => calls.add('loadScript');

  @override
  Future<void> loadLibrary(String script) async => calls.add('loadLibrary');

  @override
  Future<void> loadScriptFromURL(String urlString) async =>
      calls.add('loadScriptFromURL');

  @override
  Future<void> registerSpider() async => calls.add('registerSpider');

  @override
  bool get isSpiderReady => ready;

  @override
  Future<HomeContentResult> callHomeContent() async {
    calls.add('homeContent');
    return homeResult ?? const HomeContentResult();
  }

  @override
  Future<SearchContentResult> callSearchContent(String keyword, int pg) async {
    calls.add('searchContent:$keyword:$pg');
    return searchResult ?? const SearchContentResult();
  }

  @override
  Future<CategoryContentResult> callCategoryContent(
      String tid, int pg, String extend) async {
    calls.add('categoryContent:$tid:$pg');
    return categoryResult ?? const CategoryContentResult();
  }

  @override
  Future<DetailContentResult> callDetailContent(String ids) async {
    calls.add('detailContent:$ids');
    return detailResult ?? const DetailContentResult();
  }

  @override
  Future<PlayerContentResult> callPlayerContent(
      String vodId, String flag, String url) async {
    calls.add('playerContent:$vodId:$flag:$url');
    return playerResult ?? PlayerContentResult();
  }

  @override
  Future<void> dispose() async => calls.add('dispose');
}

VodItem _vod({
  String id = '1',
  String name = '视频',
  String? playFrom,
  String? playUrl,
}) =>
    VodItem(
      vodId: id,
      vodName: name,
      vodPic: 'https://cdn/p.jpg',
      vodPlayFrom: playFrom,
      vodPlayUrl: playUrl,
    );

WelfarePythonSpiderService _service(
  _FakeSpiderEngine engine, {
  WelfarePlatformCategory category = WelfarePlatformCategory.video,
  _FakeLoader? loader,
}) =>
    WelfarePythonSpiderService(
      platform: _platform(category: category),
      loader: loader ?? _FakeLoader(script: _script()),
      engineProvider: () => engine,
      logSink: (_) {},
    );

void main() {
  group('contentCategory（对齐 iOS L110-L115）', () {
    test('video / live → video；comic → comic', () {
      expect(
        _service(_FakeSpiderEngine()).contentCategory,
        FuliContentCategory.video,
      );
      expect(
        _service(_FakeSpiderEngine(), category: WelfarePlatformCategory.live)
            .contentCategory,
        FuliContentCategory.video,
      );
      expect(
        _service(_FakeSpiderEngine(), category: WelfarePlatformCategory.comic)
            .contentCategory,
        FuliContentCategory.comic,
      );
    });
  });

  group('ensureEngine', () {
    test('成功：loadScript + registerSpider，引擎就绪', () async {
      final _FakeSpiderEngine engine = _FakeSpiderEngine();
      final _FakeLoader loader = _FakeLoader(script: _script());
      final WelfarePythonSpiderService service =
          _service(engine, loader: loader);

      await service.ensureEngine();
      expect(service.isEngineReady, isTrue);
      expect(service.engineInitError, isNull);
      expect(loader.loadCount, 1);
      expect(engine.calls, containsAll(<String>['loadScript', 'registerSpider']));
    });

    test('失败：initError 记录，引擎不可用；再调用幂等不重试', () async {
      final _FakeSpiderEngine engine = _FakeSpiderEngine();
      final _FakeLoader loader =
          _FakeLoader(failWith: WelfareSpiderLoaderError.emptyScript);
      final WelfarePythonSpiderService service =
          _service(engine, loader: loader);

      await service.ensureEngine();
      expect(service.isEngineReady, isFalse);
      expect(service.engineInitError, isNotNull);
      expect(loader.loadCount, 1);

      await service.ensureEngine();
      expect(loader.loadCount, 1, reason: '失败态幂等，不重复下载');
    });
  });

  group('serviceFor 实例缓存（对齐 iOS `service(for:)`）', () {
    test('同 platformKey 复用同一实例；clearCache 后重建', () {
      WelfarePythonSpiderService.clearCache();
      final WelfarePythonSpiderService a =
          WelfarePythonSpiderService.serviceFor(
        _platform(),
        loader: _FakeLoader(script: _script()),
        logSink: (_) {},
      );
      final WelfarePythonSpiderService b =
          WelfarePythonSpiderService.serviceFor(
        _platform(),
        loader: _FakeLoader(script: _script()),
        logSink: (_) {},
      );
      expect(identical(a, b), isTrue);

      WelfarePythonSpiderService.clearCache();
      final WelfarePythonSpiderService c =
          WelfarePythonSpiderService.serviceFor(
        _platform(),
        loader: _FakeLoader(script: _script()),
        logSink: (_) {},
      );
      expect(identical(a, c), isFalse);
    });
  });

  group('抓取契约', () {
    test('fetchHomeContent：引擎就绪 → 映射首页', () async {
      final _FakeSpiderEngine engine = _FakeSpiderEngine(
        homeResult: HomeContentResult(
          list: <VodItem>[_vod(id: 'a', name: '首页视频')],
        ),
      );
      final FuliHomeResult result = await _service(engine).fetchHomeContent();
      expect(result.videos.single.vodName, '首页视频');
      expect(engine.calls, contains('homeContent'));
    });

    test('fetchHomeContent：引擎未就绪 → 空结果兜底', () async {
      final WelfarePythonSpiderService service = WelfarePythonSpiderService(
        platform: _platform(),
        loader: _FakeLoader(failWith: WelfareSpiderLoaderError.emptyScript),
        engineProvider: () => _FakeSpiderEngine(),
        logSink: (_) {},
      );
      final FuliHomeResult result = await service.fetchHomeContent();
      expect(result.videos, isEmpty);
      expect(result.categories, isEmpty);
    });

    test('fetchCategoryContent：优先子分类 typeId 且映射分页', () async {
      final _FakeSpiderEngine engine = _FakeSpiderEngine(
        categoryResult: CategoryContentResult(
          page: 1,
          pagecount: 2,
          list: <VodItem>[_vod()],
        ),
      );
      final FuliCategoryResult result = await _service(engine)
          .fetchCategoryContent(
        category: const FuliCategory(typeId: 'p', typeName: '父分类'),
        subCategory: const FuliCategory(typeId: 's', typeName: '子分类'),
        page: 1,
      );
      expect(result.videos, hasLength(1));
      expect(result.hasMore, isTrue);
      expect(engine.calls, contains('categoryContent:s:1'));
    });

    test('fetchSearch：映射搜索结果', () async {
      final _FakeSpiderEngine engine = _FakeSpiderEngine(
        searchResult: SearchContentResult(
          page: 1,
          pagecount: 1,
          list: <VodItem>[_vod(id: 's', name: '搜索命中')],
        ),
      );
      final FuliSearchResult result =
          await _service(engine).fetchSearch(keyword: '关键词', page: 1);
      expect(result.videos.single.vodName, '搜索命中');
      expect(result.hasMore, isFalse);
      expect(engine.calls, contains('searchContent:关键词:1'));
    });

    test('fetchDetail：视频类型不加载漫画图片（对齐 iOS L296 分支）', () async {
      final _FakeSpiderEngine engine = _FakeSpiderEngine(
        detailResult: DetailContentResult(
          list: <VodItem>[
            _vod(id: 'd', name: '详情', playFrom: '线路1', playUrl: '第1集\u0024u1'),
          ],
        ),
      );
      final FuliDetail detail = await _service(engine).fetchDetail('d');
      expect(detail.vodId, 'd');
      expect(detail.episodes, hasLength(1));
      expect(detail.episodes.single.images, isNull);
      // 视频类型不触发 playerContent 漫画解析。
      expect(
        engine.calls.where((String c) => c.startsWith('playerContent')),
        isEmpty,
      );
    });

    test('fetchDetail：漫画快速路径 manga:// 直接解析图片', () async {
      final _FakeSpiderEngine engine = _FakeSpiderEngine(
        detailResult: DetailContentResult(
          list: <VodItem>[
            _vod(
              id: 'c',
              name: '漫画',
              playFrom: '漫画',
              playUrl: '第1话\u0024manga://https://a/1.jpg&&https://a/2.jpg',
            ),
          ],
        ),
      );
      final FuliDetail detail = await _service(
        engine,
        category: WelfarePlatformCategory.comic,
      ).fetchDetail('c');
      expect(detail.episodes, hasLength(1));
      expect(detail.episodes.single.images, hasLength(2));
      expect(detail.episodes.single.images!.first, 'https://a/1.jpg');
      expect(
        engine.calls.where((String c) => c.startsWith('playerContent')),
        isEmpty,
        reason: '快速路径不触发 playerContent',
      );
    });

    test('fetchDetail：漫画慢速路径经 playerContent 解析图片', () async {
      final _FakeSpiderEngine engine = _FakeSpiderEngine(
        detailResult: DetailContentResult(
          list: <VodItem>[
            _vod(
              id: 'c',
              name: '漫画',
              playFrom: '漫画',
              playUrl: '第1话\u0024https://a/1.m3u8',
            ),
          ],
        ),
        playerResult: PlayerContentResult(
          playUrl: 'manga://https://b/1.jpg&&https://b/2.jpg',
        ),
      );
      final FuliDetail detail = await _service(
        engine,
        category: WelfarePlatformCategory.comic,
      ).fetchDetail('c');
      expect(detail.episodes, hasLength(1));
      expect(detail.episodes.single.images, hasLength(2));
      expect(detail.episodes.single.images!.first, 'https://b/1.jpg');
      expect(
        engine.calls.where((String c) => c.startsWith('playerContent')),
        hasLength(1),
      );
    });
  });

  group('fetchPlayerURL', () {
    test('就绪：playerContent 结果 + UA 合并', () async {
      final _FakeSpiderEngine engine = _FakeSpiderEngine(
        playerResult: PlayerContentResult(
          playUrl: 'https://a/play.m3u8',
          header: const <String, String>{'Referer': 'https://r/'},
          parse: 1,
        ),
      );
      final FuliPlayerResult r = await _service(engine).fetchPlayerURL(
        const FuliEpisode(name: '第1集', url: 'https://src/1.m3u8'),
      );
      expect(r.url, 'https://a/play.m3u8');
      expect(r.headers['Referer'], 'https://r/');
      expect(r.headers['User-Agent'], isNotEmpty);
      expect(r.parse, 1);
    });

    test('就绪但返回空 → 回退基类默认实现（按 URL 后缀判定 parse）', () async {
      final FuliPlayerResult m3u8 = await _service(_FakeSpiderEngine())
          .fetchPlayerURL(
        const FuliEpisode(name: '第1集', url: 'https://src/1.m3u8'),
      );
      expect(m3u8.url, 'https://src/1.m3u8');
      expect(m3u8.parse, 0, reason: '.m3u8 直接播放');
      expect(m3u8.headers, isEmpty);

      final FuliPlayerResult page = await _service(_FakeSpiderEngine())
          .fetchPlayerURL(
        const FuliEpisode(name: '第1集', url: 'https://src/watch/abc'),
      );
      expect(page.parse, 1, reason: '非直链后缀需 Web 解析');
    });

    test('playFrom：剧集名 [线路X] 优先于详情页线路', () async {
      final _FakeSpiderEngine engine = _FakeSpiderEngine();
      final WelfarePythonSpiderService service = _service(engine);
      await service.ensureEngine();
      await service.fetchPlayerURL(
        const FuliEpisode(name: '[线路A] 第1集', url: 'https://src/1.m3u8'),
      );
      expect(engine.calls, contains('playerContent::线路A:https://src/1.m3u8'));
    });

    test('playFrom：无 [线路] 前缀 → 回落详情页首个线路', () async {
      final _FakeSpiderEngine engine = _FakeSpiderEngine(
        detailResult: DetailContentResult(
          list: <VodItem>[
            _vod(
              id: 'd',
              name: '详情',
              playFrom: r'线路1$$$线路2',
              playUrl: '第1集\u0024u1',
            ),
          ],
        ),
      );
      final WelfarePythonSpiderService service = _service(engine);
      await service.fetchDetail('d');
      await service.fetchPlayerURL(
        const FuliEpisode(name: '第1集', url: 'https://src/1.m3u8'),
      );
      expect(engine.calls, contains('playerContent::线路1:https://src/1.m3u8'));
    });

    test('playFrom：无任何线路信息 → 回落平台名', () async {
      final _FakeSpiderEngine engine = _FakeSpiderEngine();
      final WelfarePythonSpiderService service = _service(engine);
      await service.ensureEngine();
      await service.fetchPlayerURL(
        const FuliEpisode(name: '第1集', url: 'https://src/1.m3u8'),
      );
      expect(engine.calls, contains('playerContent::Py演示:https://src/1.m3u8'));
    });
  });

  group('reprobe（对齐 iOS 域名重新探测）', () {
    test('重建引擎并探测首页', () async {
      final _FakeSpiderEngine engine = _FakeSpiderEngine(
        homeResult: HomeContentResult(
          list: <VodItem>[_vod(id: 'h', name: '探测视频')],
        ),
      );
      final WelfarePythonSpiderService service = _service(engine);
      await service.ensureEngine();
      expect(service.isEngineReady, isTrue);

      service.reprobe();
      expect(service.isEngineReady, isFalse);
      await pumpEventQueue();
      expect(service.isEngineReady, isTrue);
      expect(engine.calls, contains('homeContent'));
    });
  });
}
