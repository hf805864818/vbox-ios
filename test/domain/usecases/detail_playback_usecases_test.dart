/// 领域层单测：DetailPlaybackUseCases（站点→引擎/API→详情→剧集/播放地址）。
///
/// 引擎路径注入 FakeSpiderEngineFactory（记录引擎类型与调用）；CMS 路径注入
/// MockClient（真实 CmsV10Datasource）；无 IO、无原生依赖。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vbox/core/errors/failures.dart';
import 'package:vbox/core/network/http_client.dart';
import 'package:vbox/core/utils/result.dart';
import 'package:vbox/data/datasources/remote/remote.dart';
import 'package:vbox/domain/entities/playback/playback.dart';
import 'package:vbox/domain/entities/remote_source/remote_source.dart';
import 'package:vbox/domain/entities/spider/spider.dart';
import 'package:vbox/domain/usecases/usecases.dart';
import 'package:vbox/platform/runtime/jsc_ffi.dart';
import 'package:vbox/platform/runtime/quickjs_ffi.dart';
import 'package:vbox/platform/spider/node_http_client.dart';
import 'package:vbox/platform/spider/spider_engine_factory.dart';
import 'package:vbox/platform/spider/tencent_video_spider.dart';

// ─────────────── 测试替身 ───────────────

/// 假蜘蛛引擎：记录调用、按注入结果返回。
class _FakeSpiderEngine implements SpiderEngine {
  _FakeSpiderEngine(this.engineType, {this.detailResult, this.playerResult});

  @override
  SpiderEngineType engineType;
  DetailContentResult? detailResult;
  final PlayerContentResult? playerResult;
  final List<String> calls = <String>[];
  String? loadedUrl;
  bool ready = true;

  @override
  set onLog(void Function(String)? handler) {}

  @override
  Future<void> loadScript(String script) async => calls.add('loadScript');

  @override
  Future<void> loadLibrary(String script) async => calls.add('loadLibrary');

  @override
  Future<void> loadScriptFromURL(String urlString) async {
    calls.add('loadScriptFromURL');
    loadedUrl = urlString;
  }

  @override
  Future<void> registerSpider() async {
    calls.add('registerSpider');
  }

  @override
  bool get isSpiderReady => ready;

  @override
  Future<HomeContentResult> callHomeContent() async =>
      const HomeContentResult();

  @override
  Future<SearchContentResult> callSearchContent(String keyword, int pg) async =>
      const SearchContentResult();

  @override
  Future<CategoryContentResult> callCategoryContent(
          String tid, int pg, String extend) async =>
      const CategoryContentResult();

  @override
  Future<DetailContentResult> callDetailContent(String ids) async {
    calls.add('detailContent:$ids');
    return detailResult ?? const DetailContentResult();
  }

  @override
  Future<PlayerContentResult> callPlayerContent(
      String vodId, String flag, String url) async {
    calls.add('playerContent:$vodId:$flag');
    return playerResult ?? PlayerContentResult();
  }

  @override
  Future<void> dispose() async => calls.add('dispose');
}

/// 假工厂：返回 [engine]（记录 create 的引擎类型）。
class _FakeSpiderEngineFactory extends SpiderEngineFactory {
  _FakeSpiderEngineFactory(this.engine);

  final _FakeSpiderEngine engine;
  final List<SpiderEngineType> createdTypes = <SpiderEngineType>[];

  @override
  SpiderEngine create(
    SpiderEngineType type, {
    NodeHttpClient? nodeClient,
    QuickJsNativeBridge? quickJsBridge,
    JsCoreNativeBridge? jsCoreBridge,
    String? siteKey,
    String? baseUrl,
    String? requestId,
    void Function(String)? onLog,
  }) {
    createdTypes.add(type);
    return engine;
  }
}

/// 构造 allSources 容器（apiSources.sites + spiderSources.sites）。
AllSourcesContainer buildContainer(List<Map<String, Object?>> sites) =>
    AllSourcesContainer.fromJson(<String, Object?>{
      'apiSources': <String, Object?>{
        'sites': sites.where((Map<String, Object?> s) =>
            ((s['type'] as num?) ?? 0) < 2).toList(),
      },
      'spiderSources': <String, Object?>{
        'sites': sites.where((Map<String, Object?> s) =>
            ((s['type'] as num?) ?? 0) == 3).toList(),
      },
    });

Map<String, Object?> siteJson({
  required String key,
  int type = 3,
  String? api,
  String? group,
}) =>
    <String, Object?>{
      'key': key,
      'name': key,
      'type': type,
      if (api != null) 'api': api,
      if (group != null) 'group': group,
    };

VodItem vodFromDetail(Map<String, Object?> extra) => VodItem.fromJson(
      <String, Object?>{
        'vod_id': '123',
        'vod_name': '示例片',
        'vod_pic': '',
        'vod_play_from': '线路1',
        'vod_play_url': '第1集\$https://v.com/1.m3u8#第2集\$https://v.com/2.m3u8',
        ...extra,
      },
    );

void main() {
  group('loadDetail：参数校验', () {
    test('空 siteKey / vodId → ValidationFailure', () async {
      final DetailPlaybackUseCases uc = DetailPlaybackUseCases(
        loadAllSources: () async => Success<AllSourcesContainer>(
          buildContainer(<Map<String, Object?>>[]),
        ),
      );
      expect(
        (await uc.loadDetail(siteKey: '  ', vodId: '1')).failureOrNull,
        isA<ValidationFailure>(),
      );
      expect(
        (await uc.loadDetail(siteKey: 'k', vodId: '')).failureOrNull,
        isA<ValidationFailure>(),
      );
    });
  });

  group('loadDetail：腾讯原生（S-设3）', () {
    test('腾讯站点未注入原生蜘蛛 → UnsupportedFailure（不走站点解析）', () async {
      final DetailPlaybackUseCases uc = DetailPlaybackUseCases(
        loadAllSources: () async =>
            const Success<AllSourcesContainer>(AllSourcesContainer()),
      );
      final Result<PlaybackDetail> r = await uc.loadDetail(
        siteKey: TencentVideoNativeSpider.siteKey,
        vodId: 'abc123',
      );
      expect(r.failureOrNull, isA<UnsupportedFailure>());
    });
  });

  group('loadDetail：站点解析', () {
    test('allSources 拉取失败 → 透传 Failure', () async {
      final DetailPlaybackUseCases uc = DetailPlaybackUseCases(
        loadAllSources: () async =>
            const Err<AllSourcesContainer>(NetworkFailure('断网')),
      );
      final Result<PlaybackDetail> r =
          await uc.loadDetail(siteKey: 'k', vodId: '1');
      expect(r.failureOrNull, isA<NetworkFailure>());
    });

    test('未找到站点 → ValidationFailure', () async {
      final DetailPlaybackUseCases uc = DetailPlaybackUseCases(
        loadAllSources: () async => Success<AllSourcesContainer>(
          buildContainer(<Map<String, Object?>>[
            siteJson(key: 'other'),
          ]),
        ),
      );
      final Result<PlaybackDetail> r =
          await uc.loadDetail(siteKey: 'missing', vodId: '1');
      expect(r.failureOrNull, isA<ValidationFailure>());
      expect(r.failureOrNull?.message, contains('missing'));
    });

    test('.jar 站点 → UnsupportedFailure', () async {
      final DetailPlaybackUseCases uc = DetailPlaybackUseCases(
        loadAllSources: () async => Success<AllSourcesContainer>(
          buildContainer(<Map<String, Object?>>[
            siteJson(key: 'j1', type: 3, api: 'http://x/a.jar'),
          ]),
        ),
      );
      final Result<PlaybackDetail> r =
          await uc.loadDetail(siteKey: 'j1', vodId: '1');
      expect(r.failureOrNull, isA<UnsupportedFailure>());
    });
  });

  group('loadDetail：CMS 路径（apiEndpoint）', () {
    test('拉取详情并解析剧集', () async {
      final CmsV10Datasource cms = CmsV10Datasource(
        client: HttpClient(
          inner: MockClient((http.Request req) async {
            if (!req.url.queryParameters.containsKey('ac') ||
                req.url.queryParameters['ac'] != 'detail') {
              return http.Response('{}', 400);
            }
            return http.Response(
              jsonEncode(<String, Object?>{
                'code': 1,
                'list': <Map<String, Object?>>[
                  <String, Object?>{
                    'vod_id': '123',
                    'vod_name': '示例片',
                    'vod_pic': '',
                    'vod_play_url':
                        '第1集\$https://v.com/1.m3u8#第2集\$https://v.com/2.m3u8',
                  },
                ],
              }),
              200,
              headers: <String, String>{
                'content-type': 'application/json; charset=utf-8',
              },
            );
          }),
          retryBaseDelay: Duration.zero,
        ),
      );
      final DetailPlaybackUseCases uc = DetailPlaybackUseCases(
        loadAllSources: () async => Success<AllSourcesContainer>(
          buildContainer(<Map<String, Object?>>[
            siteJson(key: 'cms1', type: 0, api: 'https://cms.example.com/vod'),
          ]),
        ),
        cmsDatasource: cms,
      );

      final Result<PlaybackDetail> r =
          await uc.loadDetail(siteKey: 'cms1', vodId: '123');
      expect(r.isSuccess, isTrue, reason: '${r.failureOrNull}');
      final PlaybackDetail d = r.valueOrNull!;
      expect(d.vod.vodName, '示例片');
      expect(d.episodes.length, 2);
      expect(d.episodes.first.url, 'https://v.com/1.m3u8');
    });

    test('未注入 CMS 数据源 → UnsupportedFailure', () async {
      final DetailPlaybackUseCases uc = DetailPlaybackUseCases(
        loadAllSources: () async => Success<AllSourcesContainer>(
          buildContainer(<Map<String, Object?>>[
            siteJson(key: 'cms2', type: 1, api: 'https://cms.example.com'),
          ]),
        ),
      );
      final Result<PlaybackDetail> r =
          await uc.loadDetail(siteKey: 'cms2', vodId: '1');
      expect(r.failureOrNull, isA<UnsupportedFailure>());
    });
  });

  group('loadDetail：蜘蛛路径', () {
    late _FakeSpiderEngine engine;
    late _FakeSpiderEngineFactory factory;

    setUp(() {
      engine = _FakeSpiderEngine(
        SpiderEngineType.node,
        detailResult: DetailContentResult(
          list: <VodItem>[vodFromDetail(const <String, Object?>{})],
        ),
      );
      factory = _FakeSpiderEngineFactory(engine);
    });

    test('node 站点：register 即 ready，不加载脚本', () async {
      final DetailPlaybackUseCases uc = DetailPlaybackUseCases(
        loadAllSources: () async => Success<AllSourcesContainer>(
          buildContainer(<Map<String, Object?>>[
            siteJson(key: 'nodejs_x', type: 3),
          ]),
        ),
        engineFactory: factory,
      );
      final Result<PlaybackDetail> r =
          await uc.loadDetail(siteKey: 'nodejs_x', vodId: '123');
      expect(r.isSuccess, isTrue, reason: '${r.failureOrNull}');
      expect(factory.createdTypes.single, SpiderEngineType.node);
      expect(engine.calls, isNot(contains('loadScriptFromURL')));
      expect(engine.calls, contains('registerSpider'));
      expect(engine.calls, contains('detailContent:123'));
      expect(engine.calls.last, 'dispose');
      expect(r.valueOrNull!.episodes.length, 2);
    });

    test('jsSpider 站点：QuickJS 顶替 JSC，加载脚本后注册', () async {
      engine.engineType = SpiderEngineType.quickJS; // 工厂按需覆盖
      final DetailPlaybackUseCases uc = DetailPlaybackUseCases(
        loadAllSources: () async => Success<AllSourcesContainer>(
          buildContainer(<Map<String, Object?>>[
            siteJson(key: 'y_csp', type: 3, api: 'https://cdn.example.com/x.js'),
          ]),
        ),
        engineFactory: factory,
      );
      final Result<PlaybackDetail> r =
          await uc.loadDetail(siteKey: 'y_csp', vodId: '123');
      expect(r.isSuccess, isTrue, reason: '${r.failureOrNull}');
      expect(factory.createdTypes.single, SpiderEngineType.quickJS);
      expect(engine.loadedUrl, 'https://cdn.example.com/x.js');
      expect(engine.calls, contains('loadScriptFromURL'));
      expect(engine.calls, contains('registerSpider'));
    });

    test('python 站点：加载脚本 + 注册', () async {
      engine.engineType = SpiderEngineType.python;
      final DetailPlaybackUseCases uc = DetailPlaybackUseCases(
        loadAllSources: () async => Success<AllSourcesContainer>(
          buildContainer(<Map<String, Object?>>[
            siteJson(key: 'y_py', type: 3, api: 'https://cdn.example.com/x.py'),
          ]),
        ),
        engineFactory: factory,
      );
      final Result<PlaybackDetail> r =
          await uc.loadDetail(siteKey: 'y_py', vodId: '123');
      expect(r.isSuccess, isTrue, reason: '${r.failureOrNull}');
      expect(factory.createdTypes.single, SpiderEngineType.python);
      expect(engine.loadedUrl, 'https://cdn.example.com/x.py');
    });

    test('蜘蛛脚本地址为空 / 本地非 URL 脚本 → 失败', () async {
      for (final Map<String, Object?> site in <Map<String, Object?>>[
        siteJson(key: 'a1', type: 3), // 无 api → unsupported 模式
        siteJson(key: 'a3', type: 3, api: './local.js'), // 本地插件脚本（非 http(s) URL）
      ]) {
        final DetailPlaybackUseCases uc = DetailPlaybackUseCases(
          loadAllSources: () async => Success<AllSourcesContainer>(
            buildContainer(<Map<String, Object?>>[site]),
          ),
          engineFactory: factory,
        );
        final Result<PlaybackDetail> r =
            await uc.loadDetail(siteKey: (site['key']! as String), vodId: '1');
        expect(r.isSuccess, isFalse, reason: '${site['key']}');
      }
    });

    test('相对路径插件脚本 → 以订阅源基址解析为绝对地址加载', () async {
      final DetailPlaybackUseCases uc = DetailPlaybackUseCases(
        loadAllSources: () async => Success<AllSourcesContainer>(
          buildContainer(<Map<String, Object?>>[
            siteJson(key: 'a3', type: 3, api: './local.js'),
          ]),
        ),
        engineFactory: factory,
        scriptBaseUrl: () => 'https://cdn.example.com/repo/all_sources.json',
      );
      final Result<PlaybackDetail> r =
          await uc.loadDetail(siteKey: 'a3', vodId: '1');
      expect(r.isSuccess, isTrue);
      expect(engine.loadedUrl, 'https://cdn.example.com/repo/local.js');
    });

    test('蜘蛛注册失败 → SpiderFailure', () async {
      engine.ready = false;
      final DetailPlaybackUseCases uc = DetailPlaybackUseCases(
        loadAllSources: () async => Success<AllSourcesContainer>(
          buildContainer(<Map<String, Object?>>[
            siteJson(key: 'nodejs_x', type: 3),
          ]),
        ),
        engineFactory: factory,
      );
      final Result<PlaybackDetail> r =
          await uc.loadDetail(siteKey: 'nodejs_x', vodId: '1');
      expect(r.failureOrNull, isA<SpiderFailure>());
    });

    test('详情为空 → ParseFailure', () async {
      engine.detailResult = const DetailContentResult();
      final DetailPlaybackUseCases uc = DetailPlaybackUseCases(
        loadAllSources: () async => Success<AllSourcesContainer>(
          buildContainer(<Map<String, Object?>>[
            siteJson(key: 'nodejs_x', type: 3),
          ]),
        ),
        engineFactory: factory,
      );
      final Result<PlaybackDetail> r =
          await uc.loadDetail(siteKey: 'nodejs_x', vodId: '1');
      expect(r.failureOrNull, isA<ParseFailure>());
    });
  });

  group('resolvePlayUrl', () {
    late _FakeSpiderEngine engine;
    late _FakeSpiderEngineFactory factory;

    setUp(() {
      engine = _FakeSpiderEngine(
        SpiderEngineType.node,
        playerResult: PlayerContentResult.fromJson(<String, Object?>{
          'url': 'https://real.com/play.m3u8',
          'header': <String, String>{'Referer': 'https://src.com'},
        }),
      );
      factory = _FakeSpiderEngineFactory(engine);
    });

    PlaybackDetail buildDetail({required String playUrl, int type = 3, String? api}) {
      final SiteConfig site = SiteConfig.fromJson(siteJson(
        key: 's1',
        type: type,
        api: api,
      ));
      return PlaybackDetail.fromVod(
        site: site,
        vod: VodItem.fromJson(<String, Object?>{
          'vod_id': '123',
          'vod_name': '示例片',
          'vod_pic': '',
          'vod_play_from': '线路1',
          'vod_play_url': playUrl,
        }),
      );
    }

    test('直链媒体 → 原地址返回，不触达引擎', () async {
      final DetailPlaybackUseCases uc = DetailPlaybackUseCases(
        loadAllSources: () async => const Success<AllSourcesContainer>(
          AllSourcesContainer(),
        ),
        engineFactory: factory,
      );
      final PlaybackDetail d =
          buildDetail(playUrl: '第1集\$https://v.com/1.m3u8');
      final Result<PlayerContentResult> r = await uc.resolvePlayUrl(
        detail: d,
        episode: d.episodes.first,
      );
      expect(r.valueOrNull?.url, 'https://v.com/1.m3u8');
      expect(engine.calls, isEmpty);
    });

    test('API 站点非直链 → 地址即播放地址（无引擎）', () async {
      final DetailPlaybackUseCases uc = DetailPlaybackUseCases(
        loadAllSources: () async => const Success<AllSourcesContainer>(
          AllSourcesContainer(),
        ),
        engineFactory: factory,
      );
      final PlaybackDetail d = buildDetail(
        playUrl: '第1集\$https://v.com/play/1',
        type: 0,
        api: 'https://cms.example.com',
      );
      final Result<PlayerContentResult> r = await uc.resolvePlayUrl(
        detail: d,
        episode: d.episodes.first,
      );
      expect(r.valueOrNull?.url, 'https://v.com/play/1');
      expect(engine.calls, isEmpty);
    });

    test('蜘蛛站点非直链 → playerContent 二次解析（flag=线路）', () async {
      final DetailPlaybackUseCases uc = DetailPlaybackUseCases(
        loadAllSources: () async => const Success<AllSourcesContainer>(
          AllSourcesContainer(),
        ),
        engineFactory: factory,
      );
      final PlaybackDetail d = buildDetail(
        playUrl: '第1集\$https://v.com/play/1',
        api: 'https://127.0.0.1:58080/spider/x',
      );
      final Result<PlayerContentResult> r = await uc.resolvePlayUrl(
        detail: d,
        episode: d.episodes.first,
      );
      expect(r.valueOrNull?.url, 'https://real.com/play.m3u8');
      expect(r.valueOrNull?.header, <String, String>{'Referer': 'https://src.com'});
      expect(engine.calls, contains('playerContent:123:线路1'));
      expect(engine.calls.last, 'dispose');
    });

    test('内置网页嗅探兜底：playerContent 仍返回网页地址 → 嗅探命中替换', () async {
      // playerContent 返回网页播放页（未直链）→ customParser 未注入 →
      // 内置嗅探（fake）命中直链（A3：修复网页 URL 直喂内核容器不支持）。
      final _FakeSpiderEngine webEngine = _FakeSpiderEngine(
        SpiderEngineType.quickJS,
        playerResult: PlayerContentResult.fromJson(<String, Object?>{
          'url': 'https://v.com/play/aADmylPe',
        }),
      );
      final DetailPlaybackUseCases uc = DetailPlaybackUseCases(
        loadAllSources: () async => const Success<AllSourcesContainer>(
          AllSourcesContainer(),
        ),
        engineFactory: _FakeSpiderEngineFactory(webEngine),
        webPageSniffer: (String pageUrl) async =>
            'https://real.cdn.com/vod/index.m3u8',
      );
      final PlaybackDetail d = buildDetail(
        playUrl: '第1集\$https://v.com/play/aADmylPe',
        api: 'https://127.0.0.1:58080/spider/x',
      );
      final Result<PlayerContentResult> r = await uc.resolvePlayUrl(
        detail: d,
        episode: d.episodes.first,
      );
      expect(r.valueOrNull?.url, 'https://real.cdn.com/vod/index.m3u8');
    });

    test('内置网页嗅探未命中 → 回落原地址（不掩盖失败）', () async {
      final _FakeSpiderEngine webEngine = _FakeSpiderEngine(
        SpiderEngineType.quickJS,
        playerResult: PlayerContentResult.fromJson(<String, Object?>{
          'url': 'https://v.com/play/noHit',
        }),
      );
      final DetailPlaybackUseCases uc = DetailPlaybackUseCases(
        loadAllSources: () async => const Success<AllSourcesContainer>(
          AllSourcesContainer(),
        ),
        engineFactory: _FakeSpiderEngineFactory(webEngine),
        webPageSniffer: (String pageUrl) async => null,
      );
      final PlaybackDetail d = buildDetail(
        playUrl: '第1集\$https://v.com/play/noHit',
        api: 'https://127.0.0.1:58080/spider/x',
      );
      final Result<PlayerContentResult> r = await uc.resolvePlayUrl(
        detail: d,
        episode: d.episodes.first,
      );
      expect(r.valueOrNull?.url, 'https://v.com/play/noHit');
    });

    test('直链地址不触达内置嗅探（直链优先，对齐 iOS）', () async {
      int sniffCalls = 0;
      final DetailPlaybackUseCases uc = DetailPlaybackUseCases(
        loadAllSources: () async => const Success<AllSourcesContainer>(
          AllSourcesContainer(),
        ),
        engineFactory: factory,
        webPageSniffer: (String pageUrl) async {
          sniffCalls++;
          return 'https://should-not-use.com/x.m3u8';
        },
      );
      final PlaybackDetail d =
          buildDetail(playUrl: '第1集\$https://v.com/1.m3u8');
      final Result<PlayerContentResult> r = await uc.resolvePlayUrl(
        detail: d,
        episode: d.episodes.first,
      );
      expect(r.valueOrNull?.url, 'https://v.com/1.m3u8');
      expect(sniffCalls, 0);
    });
  });
}
