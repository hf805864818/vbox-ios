/// 领域层单测：ContentBrowseUseCases（站点列表 / 首页 / 分类 / 搜索）。
///
/// 引擎路径注入 FakeSpiderEngineFactory；CMS 路径注入 MockClient（真实
/// CmsV10Datasource）；无 IO、无原生依赖。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vbox/core/errors/failures.dart';
import 'package:vbox/core/network/http_client.dart';
import 'package:vbox/core/utils/result.dart';
import 'package:vbox/data/datasources/remote/remote.dart';
import 'package:vbox/domain/entities/remote_source/remote_source.dart';
import 'package:vbox/domain/entities/spider/spider.dart';
import 'package:vbox/domain/usecases/usecases.dart';
import 'package:vbox/platform/runtime/jsc_ffi.dart';
import 'package:vbox/platform/runtime/quickjs_ffi.dart';
import 'package:vbox/platform/spider/node_http_client.dart';
import 'package:vbox/platform/spider/spider_engine_factory.dart';

// ─────────────── 测试替身 ───────────────

class _FakeSpiderEngine implements SpiderEngine {
  _FakeSpiderEngine(this.engineType,
      {this.homeResult, this.categoryResult, this.searchResult});

  @override
  SpiderEngineType engineType;
  HomeContentResult? homeResult;
  CategoryContentResult? categoryResult;
  SearchContentResult? searchResult;
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
    ready = true; // 注册成功即就绪（对齐真实引擎语义）
  }

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
  Future<DetailContentResult> callDetailContent(String ids) async =>
      const DetailContentResult();

  @override
  Future<PlayerContentResult> callPlayerContent(
          String vodId, String flag, String url) async =>
      PlayerContentResult();

  @override
  Future<void> dispose() async => calls.add('dispose');
}

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

AllSourcesContainer buildContainer(List<Map<String, Object?>> sites) =>
    AllSourcesContainer.fromJson(<String, Object?>{
      'apiSources': <String, Object?>{
        'sites': sites
            .where((Map<String, Object?> s) => ((s['type'] as num?) ?? 0) < 3)
            .toList(),
      },
      'spiderSources': <String, Object?>{
        'sites': sites
            .where((Map<String, Object?> s) => ((s['type'] as num?) ?? 0) == 3)
            .toList(),
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

/// 组装 CMS MockClient：按 `ac` 分流返回分类/列表（对齐新请求形态：
/// 分类/列表 `ac=list`、搜索 `ac=detail&wd`；`ac=home` 返回空触发降级链）。
HttpClient cmsClient({List<Map<String, Object?>> classes = const [], List<Map<String, Object?>> list = const []}) {
  return HttpClient(
    inner: MockClient((http.Request req) async {
      final String ac = req.url.queryParameters['ac'] ?? '';
      Map<String, Object?> body;
      if (ac == 'home') {
        body = <String, Object?>{};
      } else if (ac == 'list') {
        body = <String, Object?>{'class': classes, 'list': list};
      } else if (ac == 'detail') {
        body = <String, Object?>{'list': list};
      } else {
        body = <String, Object?>{};
      }
      return http.Response(
        jsonEncode(body),
        200,
        headers: <String, String>{
          'content-type': 'application/json; charset=utf-8',
        },
      );
    }),
    retryBaseDelay: Duration.zero,
  );
}

void main() {
  group('listSites', () {
    test('空站点 → UnknownFailure', () async {
      final ContentBrowseUseCases uc = ContentBrowseUseCases(
        loadAllSources: () async => Success<AllSourcesContainer>(
          buildContainer(<Map<String, Object?>>[]),
        ),
      );
      final Result<List<SiteConfig>> r = await uc.listSites();
      expect(r.failureOrNull, isA<UnknownFailure>());
    });

    test('返回解析后的站点（含 key）', () async {
      final ContentBrowseUseCases uc = ContentBrowseUseCases(
        loadAllSources: () async => Success<AllSourcesContainer>(
          buildContainer(<Map<String, Object?>>[
            siteJson(key: 'a', type: 0, api: 'https://a.com'),
            siteJson(key: 'b', type: 3, api: 'https://b.com/x.js'),
          ]),
        ),
      );
      final Result<List<SiteConfig>> r = await uc.listSites();
      expect(r.isSuccess, isTrue, reason: '${r.failureOrNull}');
      expect(r.valueOrNull!.map((SiteConfig s) => s.key), <String>['a', 'b']);
    });
  });

  group('homeContent', () {
    test('空 siteKey → ValidationFailure', () async {
      final ContentBrowseUseCases uc = ContentBrowseUseCases(
        loadAllSources: () async => const Success<AllSourcesContainer>(
          AllSourcesContainer(),
        ),
      );
      expect(
        (await uc.homeContent('  ')).failureOrNull,
        isA<ValidationFailure>(),
      );
    });

    test('allSources 失败 → 透传 Failure', () async {
      final ContentBrowseUseCases uc = ContentBrowseUseCases(
        loadAllSources: () async =>
            const Err<AllSourcesContainer>(NetworkFailure('断网')),
      );
      expect(
        (await uc.homeContent('k')).failureOrNull,
        isA<NetworkFailure>(),
      );
    });

    test('未找到站点 → ValidationFailure', () async {
      final ContentBrowseUseCases uc = ContentBrowseUseCases(
        loadAllSources: () async => Success<AllSourcesContainer>(
          buildContainer(<Map<String, Object?>>[siteJson(key: 'other')]),
        ),
      );
      expect(
        (await uc.homeContent('missing')).failureOrNull,
        isA<ValidationFailure>(),
      );
    });

    test('.jar 站点 → UnsupportedFailure', () async {
      final ContentBrowseUseCases uc = ContentBrowseUseCases(
        loadAllSources: () async => Success<AllSourcesContainer>(
          buildContainer(<Map<String, Object?>>[
            siteJson(key: 'j', type: 3, api: 'http://x/a.jar'),
          ]),
        ),
      );
      expect(
        (await uc.homeContent('j')).failureOrNull,
        isA<UnsupportedFailure>(),
      );
    });

    test('CMS 路径：分类 + 列表合并返回', () async {
      final ContentBrowseUseCases uc = ContentBrowseUseCases(
        loadAllSources: () async => Success<AllSourcesContainer>(
          buildContainer(<Map<String, Object?>>[
            siteJson(key: 'cms', type: 0, api: 'https://cms.example.com'),
          ]),
        ),
        cmsDatasource: CmsV10Datasource(
          client: cmsClient(
            classes: <Map<String, Object?>>[
              <String, Object?>{'type_id': '1', 'type_name': '电影'},
            ],
            list: <Map<String, Object?>>[
              <String, Object?>{
                'vod_id': '1',
                'vod_name': '片A',
                'vod_pic': '',
              },
            ],
          ),
        ),
      );
      final Result<HomeContentResult> r = await uc.homeContent('cms');
      expect(r.isSuccess, isTrue, reason: '${r.failureOrNull}');
      expect(r.valueOrNull!.classes!.single.typeName, '电影');
      expect(r.valueOrNull!.list!.single.vodName, '片A');
    });

    test('CMS 未注入数据源 → UnsupportedFailure', () async {
      final ContentBrowseUseCases uc = ContentBrowseUseCases(
        loadAllSources: () async => Success<AllSourcesContainer>(
          buildContainer(<Map<String, Object?>>[
            siteJson(key: 'cms', type: 1, api: 'https://cms.example.com'),
          ]),
        ),
      );
      expect(
        (await uc.homeContent('cms')).failureOrNull,
        isA<UnsupportedFailure>(),
      );
    });

    test('蜘蛛路径：引擎缓存复用（ready 直接调用，不 dispose）', () async {
      final _FakeSpiderEngine engine = _FakeSpiderEngine(
        SpiderEngineType.node,
        homeResult: HomeContentResult(
          list: <VodItem>[
            VodItem.fromJson(
                <String, Object?>{'vod_id': '1', 'vod_name': '片', 'vod_pic': ''}),
          ],
        ),
      );
      final _FakeSpiderEngineFactory factory = _FakeSpiderEngineFactory(engine);
      final ContentBrowseUseCases uc = ContentBrowseUseCases(
        loadAllSources: () async => Success<AllSourcesContainer>(
          buildContainer(<Map<String, Object?>>[
            siteJson(key: 'nodejs_x', type: 3),
          ]),
        ),
        engineFactory: factory,
      );
      final Result<HomeContentResult> r = await uc.homeContent('nodejs_x');
      expect(r.isSuccess, isTrue, reason: '${r.failureOrNull}');
      expect(r.valueOrNull!.list!.single.vodName, '片');
      expect(factory.createdTypes.single, SpiderEngineType.node);
      // ready 引擎跳过重载（isSpiderReady → 幂等），且不 dispose（缓存复用）。
      expect(engine.calls, isNot(contains('dispose')));
      // 第二次调用复用同一引擎实例（对齐 iOS SpiderManager 引擎缓存）。
      await uc.homeContent('nodejs_x');
      expect(factory.createdTypes.length, 1);
      expect(engine.calls.where((String c) => c == 'homeContent').length, 2);
    });
  });

  group('categoryContent', () {
    test('CMS 路径：带 tid 的列表（ac=list，对齐 iOS）', () async {
      final ContentBrowseUseCases uc = ContentBrowseUseCases(
        loadAllSources: () async => Success<AllSourcesContainer>(
          buildContainer(<Map<String, Object?>>[
            siteJson(key: 'cms', type: 0, api: 'https://cms.example.com'),
          ]),
        ),
        cmsDatasource: CmsV10Datasource(
          client: cmsClient(
            list: <Map<String, Object?>>[
              <String, Object?>{
                'vod_id': '2',
                'vod_name': '片B',
                'vod_pic': '',
                'vod_remarks': '更新至8集',
              },
            ],
          ),
        ),
      );
      final Result<CategoryContentResult> r =
          await uc.categoryContent('cms', tid: '1', page: 2);
      expect(r.isSuccess, isTrue, reason: '${r.failureOrNull}');
      expect(r.valueOrNull!.page, 2);
      expect(r.valueOrNull!.list!.single.vodName, '片B');
      expect(r.valueOrNull!.list!.single.vodRemarks, '更新至8集');
    });

    test('蜘蛛路径：callCategoryContent(tid, pg)', () async {
      final _FakeSpiderEngine engine = _FakeSpiderEngine(
        SpiderEngineType.node,
        categoryResult: CategoryContentResult(
          page: 1,
          list: <VodItem>[
            VodItem.fromJson(
                <String, Object?>{'vod_id': '1', 'vod_name': '片', 'vod_pic': ''}),
          ],
        ),
      );
      final _FakeSpiderEngineFactory factory = _FakeSpiderEngineFactory(engine);
      final ContentBrowseUseCases uc = ContentBrowseUseCases(
        loadAllSources: () async => Success<AllSourcesContainer>(
          buildContainer(<Map<String, Object?>>[
            siteJson(key: 'nodejs_x', type: 3),
          ]),
        ),
        engineFactory: factory,
      );
      final Result<CategoryContentResult> r =
          await uc.categoryContent('nodejs_x', tid: '9', page: 2);
      expect(r.isSuccess, isTrue, reason: '${r.failureOrNull}');
      expect(engine.calls, contains('categoryContent:9:2'));
      expect(engine.calls, isNot(contains('dispose')));
    });

    test('jsSpider 站点：按 QuickJS 顶替加载脚本（回归：脚本必须下载）', () async {
      // 回归：`_prepareEngine` 曾用 `site.resolveEngineType()`（jsSpider →
      // javaScriptCore）判定脚本加载分支 → 分支被跳过 → 脚本不下载、
      // __JS_SPIDER__ 未注册 → 切源分类无数据。改用 effective 引擎类型后修复。
      final _FakeSpiderEngine engine = _FakeSpiderEngine(
        SpiderEngineType.quickJS,
        categoryResult: CategoryContentResult(
          page: 1,
          list: <VodItem>[
            VodItem.fromJson(
                <String, Object?>{'vod_id': '1', 'vod_name': '片', 'vod_pic': ''}),
          ],
        ),
      );
      engine.ready = false; // 强制走脚本加载分支
      final _FakeSpiderEngineFactory factory = _FakeSpiderEngineFactory(engine);
      final ContentBrowseUseCases uc = ContentBrowseUseCases(
        loadAllSources: () async => Success<AllSourcesContainer>(
          buildContainer(<Map<String, Object?>>[
            siteJson(key: 'js_x', type: 3, api: 'https://js.example.com/spider.js'),
          ]),
        ),
        engineFactory: factory,
      );
      final Result<CategoryContentResult> r =
          await uc.categoryContent('js_x', tid: '1');
      expect(r.isSuccess, isTrue, reason: '${r.failureOrNull}');
      expect(factory.createdTypes.single, SpiderEngineType.quickJS);
      expect(engine.calls, contains('loadScriptFromURL'));
      expect(engine.loadedUrl, 'https://js.example.com/spider.js');
      expect(engine.calls, contains('registerSpider'));
    });
  });

  group('categories', () {
    test('CMS 路径：fetchCategories → VodCategory 列表', () async {
      final ContentBrowseUseCases uc = ContentBrowseUseCases(
        loadAllSources: () async => Success<AllSourcesContainer>(
          buildContainer(<Map<String, Object?>>[
            siteJson(key: 'cms', type: 0, api: 'https://cms.example.com'),
          ]),
        ),
        cmsDatasource: CmsV10Datasource(
          client: cmsClient(
            classes: <Map<String, Object?>>[
              <String, Object?>{'type_id': '1', 'type_name': '电影'},
              <String, Object?>{'type_id': '2', 'type_name': '剧集'},
            ],
          ),
        ),
      );
      final Result<List<VodCategory>> r = await uc.categories('cms');
      expect(r.isSuccess, isTrue, reason: '${r.failureOrNull}');
      expect(r.valueOrNull!.map((VodCategory c) => c.typeName),
          <String>['电影', '剧集']);
    });

    test('蜘蛛路径：callHomeContent().classes', () async {
      final _FakeSpiderEngine engine = _FakeSpiderEngine(
        SpiderEngineType.node,
        homeResult: HomeContentResult(
          classes: <VodCategory>[
            VodCategory.fromJson(
                <String, Object?>{'type_id': '9', 'type_name': '动漫'}),
          ],
        ),
      );
      final _FakeSpiderEngineFactory factory = _FakeSpiderEngineFactory(engine);
      final ContentBrowseUseCases uc = ContentBrowseUseCases(
        loadAllSources: () async => Success<AllSourcesContainer>(
          buildContainer(<Map<String, Object?>>[
            siteJson(key: 'nodejs_x', type: 3),
          ]),
        ),
        engineFactory: factory,
      );
      final Result<List<VodCategory>> r = await uc.categories('nodejs_x');
      expect(r.isSuccess, isTrue, reason: '${r.failureOrNull}');
      expect(r.valueOrNull!.single.typeName, '动漫');
      expect(engine.calls, contains('homeContent'));
      expect(engine.calls, isNot(contains('dispose')));
    });

    test('空 siteKey → ValidationFailure', () async {
      final ContentBrowseUseCases uc = ContentBrowseUseCases(
        loadAllSources: () async => const Success<AllSourcesContainer>(
          AllSourcesContainer(),
        ),
      );
      expect(
        (await uc.categories('  ')).failureOrNull,
        isA<ValidationFailure>(),
      );
    });
  });

  group('searchContent', () {
    test('空关键词 → ValidationFailure', () async {
      final ContentBrowseUseCases uc = ContentBrowseUseCases(
        loadAllSources: () async => const Success<AllSourcesContainer>(
          AllSourcesContainer(),
        ),
      );
      expect(
        (await uc.searchContent('k', '  ')).failureOrNull,
        isA<ValidationFailure>(),
      );
    });

    test('CMS 路径：带 wd 的搜索（ac=detail，对齐 iOS）', () async {
      final ContentBrowseUseCases uc = ContentBrowseUseCases(
        loadAllSources: () async => Success<AllSourcesContainer>(
          buildContainer(<Map<String, Object?>>[
            siteJson(key: 'cms', type: 0, api: 'https://cms.example.com'),
          ]),
        ),
        cmsDatasource: CmsV10Datasource(
          client: cmsClient(
            list: <Map<String, Object?>>[
              <String, Object?>{
                'vod_id': '3',
                'vod_name': '片C',
                'vod_pic': '',
              },
            ],
          ),
        ),
      );
      final Result<SearchContentResult> r =
          await uc.searchContent('cms', '片C');
      expect(r.isSuccess, isTrue, reason: '${r.failureOrNull}');
      expect(r.valueOrNull!.list!.single.vodName, '片C');
    });

    test('蜘蛛路径：callSearchContent(keyword, pg)', () async {
      final _FakeSpiderEngine engine = _FakeSpiderEngine(
        SpiderEngineType.node,
        searchResult: SearchContentResult(
          page: 1,
          list: <VodItem>[
            VodItem.fromJson(
                <String, Object?>{'vod_id': '1', 'vod_name': '片', 'vod_pic': ''}),
          ],
        ),
      );
      final _FakeSpiderEngineFactory factory = _FakeSpiderEngineFactory(engine);
      final ContentBrowseUseCases uc = ContentBrowseUseCases(
        loadAllSources: () async => Success<AllSourcesContainer>(
          buildContainer(<Map<String, Object?>>[
            siteJson(key: 'nodejs_x', type: 3),
          ]),
        ),
        engineFactory: factory,
      );
      final Result<SearchContentResult> r =
          await uc.searchContent('nodejs_x', '关键词', page: 2);
      expect(r.isSuccess, isTrue, reason: '${r.failureOrNull}');
      expect(engine.calls, contains('searchContent:关键词:2'));
      expect(engine.calls, isNot(contains('dispose')));
    });
  });

  group('CMS 对齐 iOS 新语义', () {
    final List<Map<String, Object?>> classes = <Map<String, Object?>>[
      <String, Object?>{'type_id': '1', 'type_name': '电影'},
    ];
    final List<Map<String, Object?>> list = <Map<String, Object?>>[
      <String, Object?>{'vod_id': '9', 'vod_name': '首页片', 'vod_pic': ''},
    ];

    test('ac=home 一次拿分类 + 列表（对齐 iOS fetchAPIHomeData）', () async {
      final List<String> acs = <String>[];
      final ContentBrowseUseCases uc = ContentBrowseUseCases(
        loadAllSources: () async => Success<AllSourcesContainer>(
          buildContainer(<Map<String, Object?>>[
            siteJson(key: 'cms', type: 0, api: 'https://cms.example.com'),
          ]),
        ),
        cmsDatasource: CmsV10Datasource(
          client: HttpClient(
            inner: MockClient((http.Request r) async {
              acs.add(r.url.queryParameters['ac'] ?? '');
              if ((r.url.queryParameters['ac'] ?? '') == 'home') {
                return http.Response(
                  jsonEncode(<String, Object?>{'class': classes, 'list': list}),
                  200,
                  headers: <String, String>{
                    'content-type': 'application/json; charset=utf-8',
                  },
                );
              }
              return http.Response('{"code":404}', 404);
            }),
            retryBaseDelay: Duration.zero,
            maxRetries: 0,
          ),
        ),
      );
      final Result<HomeContentResult> r = await uc.homeContent('cms');
      expect(r.isSuccess, isTrue, reason: '${r.failureOrNull}');
      expect(r.valueOrNull!.classes!.single.typeName, '电影');
      expect(r.valueOrNull!.list!.single.vodName, '首页片');
      // 首跳即命中 ac=home，不再降级 ac=list。
      expect(acs, <String>['home']);
    });

    test('JSON 全失败 → HTML 首页兜底（对齐 iOS fetchHTMLHomeFallback）',
        () async {
      final ContentBrowseUseCases uc = ContentBrowseUseCases(
        loadAllSources: () async => Success<AllSourcesContainer>(
          buildContainer(<Map<String, Object?>>[
            siteJson(key: 'cms', type: 0, api: 'https://cms.example.com'),
          ]),
        ),
        cmsDatasource: CmsV10Datasource(
          client: HttpClient(
            inner: MockClient((http.Request r) async {
              if (r.url.path == '/' || r.url.path.isEmpty) {
                return http.Response(
                  '<html><body>'
                  '<a href="/index.php/vod/detail/id/11.html">HTML片A</a>'
                  '<a href="/voddetail/12.html"><img src="/p/2.jpg" alt="HTML片B"></a>'
                  '</body></html>',
                  200,
                  // 无 content-type 时 package:http 默认 latin1 编码，
                  // 中文会抛「Contains invalid characters」（真实站点
                  // HTML 均带 charset，此处与真机字节流路径保持一致）。
                  headers: <String, String>{
                    'content-type': 'text/html; charset=utf-8',
                  },
                );
              }
              return http.Response('oops', 500);
            }),
            retryBaseDelay: Duration.zero,
            maxRetries: 0,
          ),
        ),
      );
      final Result<HomeContentResult> r = await uc.homeContent('cms');
      expect(r.isSuccess, isTrue, reason: '${r.failureOrNull}');
      final List<VodItem> items = r.valueOrNull!.list ?? const <VodItem>[];
      expect(items.length, 2);
      expect(items[0].vodId, '11');
      expect(items[0].vodName, 'HTML片A');
      expect(items[1].vodId, '12');
      expect(items[1].vodName, 'HTML片B');
      expect(items[1].vodPic, contains('https://cms.example.com/p/2.jpg'));
    });

    test('父分类空 → 子分类聚合（type_pid）', () async {
      final ContentBrowseUseCases uc = ContentBrowseUseCases(
        loadAllSources: () async => Success<AllSourcesContainer>(
          buildContainer(<Map<String, Object?>>[
            siteJson(key: 'cms', type: 0, api: 'https://cms.example.com'),
          ]),
        ),
        cmsDatasource: CmsV10Datasource(
          client: HttpClient(
            inner: MockClient((http.Request r) async {
              final String t = r.url.queryParameters['t'] ?? '';
              final Map<String, Object?> body;
              if (t.isEmpty) {
                body = <String, Object?>{
                  'class': <Object?>[
                    <String, Object?>{
                      'type_id': '1',
                      'type_name': '综艺',
                      'type_pid': 0,
                    },
                    <String, Object?>{
                      'type_id': '11',
                      'type_name': '综艺A',
                      'type_pid': 1,
                    },
                    <String, Object?>{
                      'type_id': '12',
                      'type_name': '综艺B',
                      'type_pid': 1,
                    },
                  ],
                  'list': <Object?>[],
                };
              } else if (t == '11') {
                body = <String, Object?>{
                  'list': <Object?>[
                    <String, Object?>{'vod_id': '21', 'vod_name': '子片A', 'vod_pic': ''},
                  ],
                };
              } else if (t == '12') {
                body = <String, Object?>{
                  'list': <Object?>[
                    <String, Object?>{'vod_id': '22', 'vod_name': '子片B', 'vod_pic': ''},
                  ],
                };
              } else {
                body = <String, Object?>{'list': <Object?>[]};
              }
              return http.Response(
                jsonEncode(body),
                200,
                headers: <String, String>{
                  'content-type': 'application/json; charset=utf-8',
                },
              );
            }),
            retryBaseDelay: Duration.zero,
            maxRetries: 0,
          ),
        ),
      );
      final Result<CategoryContentResult> r =
          await uc.categoryContent('cms', tid: '1');
      expect(r.isSuccess, isTrue, reason: '${r.failureOrNull}');
      expect(r.valueOrNull!.list!.map((VodItem v) => v.vodName).toList(),
          <String>['子片A', '子片B']);
    });

    test('筛选参数拼 URL（area/year，跳过「全部」）', () async {
      final List<Uri> urls = <Uri>[];
      final ContentBrowseUseCases uc = ContentBrowseUseCases(
        loadAllSources: () async => Success<AllSourcesContainer>(
          buildContainer(<Map<String, Object?>>[
            siteJson(key: 'cms', type: 0, api: 'https://cms.example.com'),
          ]),
        ),
        cmsDatasource: CmsV10Datasource(
          client: HttpClient(
            inner: MockClient((http.Request r) async {
              urls.add(r.url);
              return http.Response(
                jsonEncode(<String, Object?>{'list': list}),
                200,
                headers: <String, String>{
                  'content-type': 'application/json; charset=utf-8',
                },
              );
            }),
            retryBaseDelay: Duration.zero,
            maxRetries: 0,
          ),
        ),
      );
      final Result<CategoryContentResult> r = await uc.categoryContent(
        'cms',
        tid: '1',
        filters: <String, String>{'area': '港台', 'year': '全部'},
      );
      expect(r.isSuccess, isTrue, reason: '${r.failureOrNull}');
      expect(urls.single.queryParameters['area'], '港台');
      expect(urls.single.queryParameters.containsKey('year'), isFalse);
    });

    test('网盘组源分类条目强制 ☁️ 标记（对齐 iOS cloudCMS 组）', () async {
      final ContentBrowseUseCases uc = ContentBrowseUseCases(
        loadAllSources: () async => Success<AllSourcesContainer>(
          buildContainer(<Map<String, Object?>>[
            siteJson(
              key: 'cloud_测试盘',
              type: 0,
              api: 'https://pan.example.com/api.php/provide/vod',
              group: 'cloud',
            ),
          ]),
        ),
        cmsDatasource: CmsV10Datasource(
          client: HttpClient(
            inner: MockClient((http.Request r) async {
              if ((r.url.queryParameters['ac'] ?? '') == 'home') {
                return http.Response('{"code":404}', 404);
              }
              return http.Response(
                jsonEncode(<String, Object?>{
                  'list': <Object?>[
                    <String, Object?>{
                      'vod_id': '3',
                      'vod_name': '网盘片',
                      'vod_pic': '',
                      'vod_remarks': '原备注',
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
            maxRetries: 0,
          ),
        ),
      );
      final Result<CategoryContentResult> r =
          await uc.categoryContent('cloud_测试盘', tid: '1');
      expect(r.isSuccess, isTrue, reason: '${r.failureOrNull}');
      expect(r.valueOrNull!.list!.single.vodRemarks, '☁️cloud_测试盘');
    });
  });
}