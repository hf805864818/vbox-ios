/// 领域层单测：通用福利 JS Spider 服务（批次 H · H-03）。
///
/// 对齐 iOS `WelfareJSSpiderService.swift`：
/// 覆盖引擎初始化（成功 / 失败 / 幂等）、`serviceFor` 实例缓存、
/// home / category / detail / search / player 抓取（引擎就绪与未就绪）、
/// `reprobe` 重建引擎、播放结果 UA 合并。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/data/datasources/welfare/welfare_spider_loader.dart';
import 'package:vbox/domain/entities/spider/spider.dart';
import 'package:vbox/domain/entities/welfare/welfare.dart';
import 'package:vbox/domain/services/welfare_js_spider_service.dart';

/// 构造一个合规的 JS 福利 Spider 平台。
WelfarePlatform _platform() => const WelfarePlatform(
      platformKey: 'js-demo',
      name: 'JS演示',
      category: WelfarePlatformCategory.video,
      serviceType: 'welfare_spider',
      scriptType: 'javascript',
      api: './sources/welfare-js/js_demo.js',
      defaultHosts: <String>['https://a.example.com'],
    );

WelfareSpiderScript _script() => WelfareSpiderScript(
      platformKey: 'js-demo',
      remoteURL: Uri.parse(
          'https://vbox-ai.github.io/api/sources/welfare-js/js_demo.js'),
      localURL: '/cache/welfare_spider/js_demo.js',
      content: 'console.log("demo");',
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

/// 假 JS 引擎：记录全部调用，可按需返回各操作结果。
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
  SpiderEngineType get engineType => SpiderEngineType.javaScriptCore;

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

WelfareJSSpiderService _service(
  _FakeSpiderEngine engine, {
  _FakeLoader? loader,
}) =>
    WelfareJSSpiderService(
      platform: _platform(),
      loader: loader ?? _FakeLoader(script: _script()),
      engineProvider: () => engine,
      logSink: (_) {},
    );

void main() {
  group('ensureEngine', () {
    test('成功：loadScript + registerSpider，引擎就绪', () async {
      final _FakeSpiderEngine engine = _FakeSpiderEngine();
      final _FakeLoader loader = _FakeLoader(script: _script());
      final WelfareJSSpiderService service = _service(engine, loader: loader);

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
      final WelfareJSSpiderService service = _service(engine, loader: loader);

      await service.ensureEngine();
      expect(service.isEngineReady, isFalse);
      expect(service.engineInitError, isNotNull);
      expect(loader.loadCount, 1);

      await service.ensureEngine();
      expect(loader.loadCount, 1, reason: '失败态幂等，不重复下载');
      expect(engine.calls, isEmpty);
    });

    test('初始化成功后再调用幂等，不重建引擎', () async {
      final _FakeSpiderEngine engine = _FakeSpiderEngine();
      final _FakeLoader loader = _FakeLoader(script: _script());
      final WelfareJSSpiderService service = _service(engine, loader: loader);

      await service.ensureEngine();
      await service.ensureEngine();
      expect(loader.loadCount, 1);
      expect(engine.calls.where((String c) => c == 'loadScript'), hasLength(1));
    });
  });

  group('serviceFor 实例缓存（对齐 iOS `service(for:)`）', () {
    test('同 platformKey 复用同一实例；clearCache 后重建', () {
      WelfareJSSpiderService.clearCache();
      final WelfareJSSpiderService a = WelfareJSSpiderService.serviceFor(
        _platform(),
        loader: _FakeLoader(script: _script()),
        logSink: (_) {},
      );
      final WelfareJSSpiderService b = WelfareJSSpiderService.serviceFor(
        _platform(),
        loader: _FakeLoader(script: _script()),
        logSink: (_) {},
      );
      expect(identical(a, b), isTrue);

      WelfareJSSpiderService.clearCache();
      final WelfareJSSpiderService c = WelfareJSSpiderService.serviceFor(
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
      final FuliHomeResult result =
          await _service(engine).fetchHomeContent();
      expect(result.videos.single.vodName, '首页视频');
      expect(engine.calls, contains('homeContent'));
    });

    test('fetchHomeContent：引擎未就绪 → 空结果兜底', () async {
      final WelfareJSSpiderService service = WelfareJSSpiderService(
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
      expect(result.page, 1);
      expect(result.hasMore, isTrue);
      expect(engine.calls, contains('categoryContent:s:1'));
    });

    test('fetchCategoryContent：无子分类回落一级分类 typeId', () async {
      final _FakeSpiderEngine engine = _FakeSpiderEngine();
      await _service(engine).fetchCategoryContent(
        category: const FuliCategory(typeId: 'p', typeName: '父分类'),
        page: 2,
      );
      expect(engine.calls, contains('categoryContent:p:2'));
    });

    test('fetchDetail：映射详情与剧集', () async {
      final _FakeSpiderEngine engine = _FakeSpiderEngine(
        detailResult: DetailContentResult(
          list: <VodItem>[
            _vod(
              id: 'd',
              name: '详情',
              playFrom: '线路1',
              playUrl: '第1集\u0024u1#第2集\u0024u2',
            ),
          ],
        ),
      );
      final FuliDetail detail = await _service(engine).fetchDetail('d');
      expect(detail.vodId, 'd');
      expect(detail.vodName, '详情');
      expect(detail.episodes, hasLength(2));
      expect(engine.calls, contains('detailContent:d'));
    });

    test('fetchDetail：引擎未就绪 → 空详情兜底', () async {
      final WelfareJSSpiderService service = WelfareJSSpiderService(
        platform: _platform(),
        loader: _FakeLoader(failWith: WelfareSpiderLoaderError.emptyScript),
        engineProvider: () => _FakeSpiderEngine(),
        logSink: (_) {},
      );
      final FuliDetail detail = await service.fetchDetail('d');
      expect(detail.vodId, 'd');
      expect(detail.episodes, isEmpty);
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
  });

  group('fetchPlayerURL', () {
    test('引擎就绪：采用 playerContent 结果并合并默认 UA', () async {
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
      expect(engine.calls, contains('playerContent::JS演示:https://src/1.m3u8'));
    });

    test('playerContent 返回空 → 回退原地址 + UA', () async {
      final FuliPlayerResult r = await _service(_FakeSpiderEngine())
          .fetchPlayerURL(
        const FuliEpisode(name: '第1集', url: 'https://src/1.m3u8'),
      );
      expect(r.url, 'https://src/1.m3u8');
      expect(r.parse, 0);
      expect(r.headers, hasLength(1));
      expect(r.headers['User-Agent'], isNotEmpty);
    });
  });

  group('reprobe / 域名', () {
    test('reprobe 重建引擎（对齐 iOS 重新探测）', () async {
      final _FakeSpiderEngine engine = _FakeSpiderEngine();
      final WelfareJSSpiderService service = _service(engine);

      await service.ensureEngine();
      expect(service.isEngineReady, isTrue);

      service.reprobe();
      expect(service.isEngineReady, isFalse);
      await pumpEventQueue();
      expect(service.isEngineReady, isTrue);
    });

    test('currentHost / isHostReady 与引擎就绪同步', () async {
      final WelfareJSSpiderService service = _service(_FakeSpiderEngine());
      expect(service.currentHost, isEmpty);
      expect(service.isHostReady, isFalse);

      await service.ensureEngine();
      expect(service.currentHost, 'https://a.example.com');
      expect(service.isHostReady, isTrue);
    });
  });
}
