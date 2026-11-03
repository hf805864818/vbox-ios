/// 领域层单测：源治理用例（Wave D · O-源1/O-源2/O-源3）。
///
/// 唯一真相源：iOS `vbox/Services/SpiderManager.swift`
///   · `allFallbackSites` / `searchStream`（兜底源开关语义）；
///   · `customParsers` + `PlayerViewsV2` L5552-L5581（解析器 → 直链）；
///   · `queryAllZhanyuanSites` / `updateZhanyuanActive`（站源启停）。
///
/// 全部离线：CMS 走假数据源、解析器请求走 MockClient、契约键走内存 mock。
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vbox/core/network/http_client.dart';
import 'package:vbox/core/utils/result.dart';
import 'package:vbox/data/datasources/local/prefs_manager.dart';
import 'package:vbox/data/datasources/local/source_governance_store.dart';
import 'package:vbox/data/datasources/remote/cms_v10_datasource.dart';
import 'package:vbox/data/datasources/remote/cms_v10_models.dart';
import 'package:vbox/data/models/zhanyuan.dart';
import 'package:vbox/domain/entities/remote_source/remote_source.dart';
import 'package:vbox/domain/entities/source/source_governance.dart';
import 'package:vbox/domain/entities/spider/site_config.dart';
import 'package:vbox/domain/entities/spider/spider_models.dart';
import 'package:vbox/domain/usecases/source_governance_usecases.dart';

/// 假 CMS 数据源：按 baseUrl 命中注入结果（未命中返回空列表）。
class _FakeCms extends CmsV10Datasource {
  _FakeCms(this.byUrl) : super(client: HttpClient());

  final Map<String, List<CmsV10Video>> byUrl;
  final List<String> requested = <String>[];

  @override
  Future<Result<List<CmsV10Video>>> fetchSearchVideos(
    String baseUrl, {
    required String keyword,
    int page = 1,
  }) async {
    requested.add(baseUrl);
    return Success<List<CmsV10Video>>(
      byUrl[baseUrl] ?? const <CmsV10Video>[],
    );
  }
}

CmsV10Video _video(String id, String name) => CmsV10Video(
      vodId: id,
      name: name,
    );

FallbackSite _fallback(String name, String api) =>
    FallbackSite(name: name, api: api);

ParserEntry _parser(String name, String url) =>
    ParserEntry(name: name, url: url);

Zhanyuan _zhanyuan(String name, {bool isActive = true, String key = ''}) =>
    Zhanyuan(
      key: key,
      name: name,
      searchUrl: 'https://$name.example.com',
      isActive: isActive,
      updatedAt: 0,
    );

/// 构造用例（默认无站点清单、无 CMS、无解析器客户端）。
SourceGovernanceUseCases _useCases({
  AllSourcesContainer? sources,
  CmsV10Datasource? cms,
  HttpClient? httpClient,
  List<Zhanyuan>? zhanyuanSites,
  SourceGovernanceStore? store,
}) =>
    SourceGovernanceUseCases(
      loadAllSources: () async => Success<AllSourcesContainer>(
        sources ?? const AllSourcesContainer(),
      ),
      loadAllZhanyuanSites:
          zhanyuanSites == null ? null : () async => zhanyuanSites,
      cmsDatasource: cms,
      httpClient: httpClient,
      store: store ?? SourceGovernanceStore.instance,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final PrefsManager prefs = PrefsManager.instance;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    await prefs.init();
  });

  setUp(() async {
    await prefs.clearAll();
    SourceGovernanceStore.instance.resetForTest();
  });

  group('O-源3 · 兜底切片源', () {
    test('合成 key 取地址 host（`fallback_<host>`）', () {
      expect(
        SourceGovernanceUseCases.fallbackKeyFor('https://a.example.com/api.php'),
        'fallback_a.example.com',
      );
      // host 缺失时退回哈希，保证稳定。
      final String k = SourceGovernanceUseCases.fallbackKeyFor('not a url');
      expect(k.startsWith('fallback_'), isTrue);
    });

    test('兜底源搜索：开关关闭 → 直接返回且不请求', () async {
      final _FakeCms cms = _FakeCms(<String, List<CmsV10Video>>{
        'https://a.example.com/api.php': <CmsV10Video>[_video('1', '甲')],
      });
      final SourceGovernanceUseCases uc = _useCases(cms: cms);
      await SourceGovernanceStore.instance
          .addCustomFallbackSite(_fallback('甲源', 'https://a.example.com/api.php'));
      await SourceGovernanceStore.instance.setFallbackEnabled(false);

      final List<List<VodItem>> batches = <List<VodItem>>[];
      await uc.searchFallback('功夫', onBatch: batches.add);

      expect(batches, isEmpty);
      expect(cms.requested, isEmpty);
    });

    test('兜底源搜索：开关开启 → 逐源回调并回填合成 key', () async {
      final _FakeCms cms = _FakeCms(<String, List<CmsV10Video>>{
        'https://a.example.com/api.php': <CmsV10Video>[_video('1', '甲')],
        'https://b.example.com/api.php': <CmsV10Video>[_video('2', '乙')],
      });
      final SourceGovernanceUseCases uc = _useCases(cms: cms);
      await SourceGovernanceStore.instance
          .addCustomFallbackSite(_fallback('甲源', 'https://a.example.com/api.php'));
      await SourceGovernanceStore.instance
          .addCustomFallbackSite(_fallback('乙源', 'https://b.example.com/api.php'));

      final List<List<VodItem>> batches = <List<VodItem>>[];
      await uc.searchFallback('功夫', onBatch: batches.add);

      expect(batches, hasLength(2));
      final Set<String> keys = batches
          .expand((List<VodItem> b) => b)
          .map((VodItem v) => v.engineKey ?? '')
          .toSet();
      expect(
        keys,
        <String>{'fallback_a.example.com', 'fallback_b.example.com'},
      );
    });

    test('空结果源不回调（对齐 iOS 空集合跳过）', () async {
      final _FakeCms cms = _FakeCms(<String, List<CmsV10Video>>{
        'https://a.example.com/api.php': <CmsV10Video>[_video('1', '甲')],
      });
      final SourceGovernanceUseCases uc = _useCases(cms: cms);
      await SourceGovernanceStore.instance
          .addCustomFallbackSite(_fallback('甲源', 'https://a.example.com/api.php'));
      await SourceGovernanceStore.instance
          .addCustomFallbackSite(_fallback('空源', 'https://empty.example.com/api.php'));

      final List<List<VodItem>> batches = <List<VodItem>>[];
      await uc.searchFallback('功夫', onBatch: batches.add);

      expect(batches, hasLength(1));
    });

    test('按合成 key 还原兜底站点配置（详情路由回退）', () async {
      final SourceGovernanceUseCases uc = _useCases();
      await SourceGovernanceStore.instance.addCustomFallbackSite(
        _fallback('甲源', 'https://a.example.com/api.php'),
      );

      final SiteConfig? found =
          await uc.findFallbackSite('fallback_a.example.com');
      expect(found, isNotNull);
      expect(found!.name, '甲源');
      expect(found.api, 'https://a.example.com/api.php');
      // 未知 key → null。
      expect(await uc.findFallbackSite('fallback_unknown'), isNull);
    });

    test('远程默认源只列 apiEndpoint 站点', () async {
      final SourceGovernanceUseCases uc = _useCases(
        sources: const AllSourcesContainer(
          apiSources: <String, Object?>{
            'sites': <Map<String, Object?>>[
              <String, Object?>{
                'key': 'api_1',
                'name': '接口源',
                'type': 0,
                'api': 'https://api.example.com/api.php',
              },
              <String, Object?>{
                'key': 'js_1',
                'name': '脚本源',
                'type': 3,
                'api': 'https://x.example.com/a.js',
              },
            ],
          },
        ),
      );

      final List<FallbackSearchSource> remote = await uc.remoteApiSites();
      expect(remote, hasLength(1));
      expect(remote.single.key, 'api_1');
      expect(remote.single.name, '接口源');
    });
  });

  group('O-源2 · 自定义解析器', () {
    test('解析器把页面地址换成媒体直链（命中 m3u8）', () async {
      final List<String> requested = <String>[];
      final HttpClient client = HttpClient(
        inner: MockClient((http.Request req) async {
          requested.add(req.url.toString());
          return http.Response(
            '<script>var url = "https://cdn.example.com/a.m3u8?t=1";</script>',
            200,
          );
        }),
      );
      final SourceGovernanceUseCases uc = _useCases(httpClient: client);
      await SourceGovernanceStore.instance.addUserParser(
        _parser('777 解析', 'https://jx.example.com/player/?url='),
      );

      expect(
        await uc.resolveWithParsers('https://v.qq.com/x'),
        'https://cdn.example.com/a.m3u8?t=1',
      );
      // 请求地址 = 解析器地址 + 原始地址（保留 URL 保留字符，对齐 iOS
      // `urlQueryAllowed`；`Uri.parse` 往返后保留字符以百分号形式呈现）。
      expect(requested.single, contains('jx.example.com/player/'));
      expect(
        Uri.parse(requested.single).query,
        contains('https://v.qq.com/x'),
      );
    });

    test('无解析器 / 空地址 → null（链路禁用）', () async {
      final SourceGovernanceUseCases uc = _useCases(httpClient: HttpClient());
      expect(await uc.resolveWithParsers('https://v.qq.com/x'), isNull);
      await SourceGovernanceStore.instance.addUserParser(
        _parser('777 解析', 'https://jx.example.com/player/?url='),
      );
      expect(await uc.resolveWithParsers('  '), isNull);
    });

    test('未命中媒体直链 → null', () async {
      final HttpClient client = HttpClient(
        inner: MockClient((http.Request req) async =>
            http.Response('<html>无直链</html>', 200)),
      );
      final SourceGovernanceUseCases uc = _useCases(httpClient: client);
      await SourceGovernanceStore.instance.addUserParser(
        _parser('777 解析', 'https://jx.example.com/player/?url='),
      );
      expect(await uc.resolveWithParsers('https://v.qq.com/x'), isNull);
    });

    test('单个解析器失败 → 继续下一个（对齐 iOS catch continue）', () async {
      final HttpClient client = HttpClient(
        inner: MockClient((http.Request req) async {
          if (req.url.host == 'bad.example.com') {
            return http.Response('boom', 500);
          }
          return http.Response('https://cdn.example.com/b.mp4', 200);
        }),
      );
      final SourceGovernanceUseCases uc = _useCases(httpClient: client);
      await SourceGovernanceStore.instance
          .addUserParser(_parser('坏解析', 'https://bad.example.com/?url='));
      await SourceGovernanceStore.instance
          .addUserParser(_parser('好解析', 'https://good.example.com/?url='));

      expect(
        await uc.resolveWithParsers('https://v.qq.com/x'),
        'https://cdn.example.com/b.mp4',
      );
    });

    test('远程默认解析器也参与解析（对齐 iOS `subManager.parses + customParsers`）',
        () async {
      final HttpClient client = HttpClient(
        inner: MockClient((http.Request req) async =>
            http.Response('https://cdn.example.com/c.m3u8', 200)),
      );
      // 无用户解析器，仅远程默认解析器。
      final SourceGovernanceUseCases uc = _useCases(
        sources: const AllSourcesContainer(
          parsers: <String, Object?>{
            'parses': <Object?>[
              <String, Object?>{
                'name': '远程解析',
                'url': 'https://remote.example.com/?url=',
              },
            ],
          },
        ),
        httpClient: client,
      );

      expect(
        await uc.resolveWithParsers('https://v.qq.com/x'),
        'https://cdn.example.com/c.m3u8',
      );
    });

    test('全部解析器 = 远程默认 + 用户自定义（按地址去重，用户优先）', () async {
      final SourceGovernanceUseCases uc = _useCases(
        sources: const AllSourcesContainer(
          parsers: <String, Object?>{
            'parses': <Object?>[
              <String, Object?>{
                'name': '远程解析',
                'url': 'https://remote.example.com/?url=',
              },
              <String, Object?>{
                'name': '重复解析',
                'url': 'https://dup.example.com/?url=',
              },
            ],
          },
        ),
      );
      await SourceGovernanceStore.instance
          .addUserParser(_parser('我的解析', 'https://dup.example.com/?url='));
      await SourceGovernanceStore.instance
          .addUserParser(_parser('新增解析', 'https://mine.example.com/?url='));

      final List<ParserEntry> all = await uc.allParsers();
      expect(all.map((ParserEntry p) => p.url), <String>[
        'https://remote.example.com/?url=',
        'https://dup.example.com/?url=',
        'https://mine.example.com/?url=',
      ]);
      // 重复地址保留用户项（名称取自用户）。
      expect(
        all.firstWhere((ParserEntry p) => p.url == 'https://dup.example.com/?url=').name,
        '我的解析',
      );
    });
  });

  group('O-源3 · 站源启停', () {
    test('站源清单：合并订阅配置站点并按站名升序', () async {
      final SourceGovernanceUseCases uc = _useCases(
        zhanyuanSites: <Zhanyuan>[
          _zhanyuan('站源甲', key: 'zhan_1'),
          _zhanyuan('站源乙', isActive: false),
        ],
      );

      final List<Zhanyuan> sites = await uc.listZhanyuanSites();
      // 按站名升序（`String.compareTo`，UTF-16 码点序：乙 U+4E59 < 甲 U+7532）。
      expect(sites.map((Zhanyuan z) => z.name), <String>['站源乙', '站源甲']);
      // 订阅配置行的 key 保留（供详情路由）。
      expect(
        sites.firstWhere((Zhanyuan z) => z.name == '站源甲').key,
        'zhan_1',
      );
      // 无 SQLite 时 DB 侧为空 → 启用状态直接取订阅配置行。
      expect(await uc.activeZhanyuanCount(), 1);
    });

    test('未注入订阅配置加载器 → 空清单（不抛异常）', () async {
      final SourceGovernanceUseCases uc = _useCases();
      expect(await uc.listZhanyuanSites(), isEmpty);
      expect(await uc.activeZhanyuanCount(), 0);
    });

    test('批量启用（全选）语义：内存禁用集合同步收敛', () async {
      final SourceGovernanceStore store = SourceGovernanceStore.instance;
      await store.setZhanyuanActiveAll(
        <(String, String)>[('站源甲', 'https://a.example.com')],
        false,
      );
      expect(store.disabledZhanyuanNames, contains('站源甲'));

      await store.setZhanyuanActiveAll(
        <(String, String)>[('站源甲', 'https://a.example.com')],
        true,
      );
      expect(store.disabledZhanyuanNames, isNot(contains('站源甲')));
    });
  });
}
