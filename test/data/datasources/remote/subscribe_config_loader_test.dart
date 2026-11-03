/// 数据层单测：订阅配置加载器（批次 G · G-07）。
///
/// 对齐基准（唯一真相源）：iOS `vbox/Services/SubscriptionManager.swift`
///   · `loadConfig(from:)`：桌面 UA → HTML 兜底 App UA 重试 → 注释清洗 →
///     JSON 解析 → 站点合成 → 无站点报错；
///   · `SpiderManager.loadSubscribeConfig` → `persistToDatabase`：
///     subscription / zhanyuan / apiyuan / jiexisetting 落库。
///
/// 真库落库用 `sqflite_common_ffi`（与 `database_manager_test.dart` 同源约定）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:vbox/core/network/http_client.dart';
import 'package:vbox/core/storage/storage_paths.dart';
import 'package:vbox/data/datasources/local/database_manager.dart';
import 'package:vbox/data/datasources/local/prefs_manager.dart';
import 'package:vbox/data/datasources/local/subscribe_config_store.dart';
import 'package:vbox/data/datasources/remote/subscribe_config_loader.dart';
import 'package:vbox/data/models/apiyuan.dart';
import 'package:vbox/data/models/jiexisetting.dart';
import 'package:vbox/data/models/zhanyuan.dart';
import 'package:vbox/domain/entities/library/library.dart';

/// 构造返回固定响应的加载器。
SubscribeConfigLoader _loader(http.Response Function(http.Request) handler) =>
    SubscribeConfigLoader(
      client: HttpClient(
        inner: MockClient((http.Request r) async => handler(r)),
        maxRetries: 0,
      ),
      store: SubscribeConfigStore(prefs: PrefsManager.instance),
      nowSeconds: () => 1000000,
    );

/// 以固定状态码与体构造响应。
http.Response _resp(String body, [int status = 200]) => http.Response(
      body,
      status,
      headers: <String, String>{'content-type': 'application/json; charset=utf-8'},
    );

/// 完整订阅源 JSON（覆盖四张落库表）。
Map<String, Object?> _fullSource() => <String, Object?>{
      'dyname': '测试订阅',
      'dyzuozhe': '作者甲',
      'sites': <Object?>[
        <String, Object?>{'key': 'k1', 'name': '站一', 'type': 3, 'api': 'https://a.js'},
      ],
      'zhanyuan': <Object?>[
        <String, Object?>{'name': '站源甲', 'searchUrl': 'https://z/search'},
      ],
      'apiyuan': <Object?>[
        <String, Object?>{'name': 'API甲', 'searchurl': 'https://api/search'},
      ],
      'jiexisetting': <Object?>[
        <String, Object?>{'bianma': 'utf-8', 'zhuurl': 'https://main', 'beiurl': 'https://back'},
      ],
      'parses': <Object?>[
        <String, Object?>{'name': '解析A', 'url': 'https://p/jx', 'type': 1},
      ],
    };

Future<void> _deleteDbFiles(String path) async {
  for (final String suffix in <String>['', '-wal', '-shm', '-journal']) {
    final File f = File('$path$suffix');
    if (f.existsSync()) await f.delete();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final DatabaseManager dbm = DatabaseManager.instance;
  final PrefsManager pm = PrefsManager.instance;
  late String dbPath;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    await pm.init();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final Directory tmp = await Directory.systemTemp.createTemp('vbox_sub_test');
    StoragePaths.configure(tmp.path);
    await StoragePaths.ensureLayout();
    dbPath = StoragePaths.databaseFile;
  });

  setUp(() async {
    await pm.clearAll();
    await dbm.close();
    await _deleteDbFiles(dbPath);
  });

  tearDownAll(() async {
    await dbm.close();
    await _deleteDbFiles(dbPath);
  });

  group('失败路径（错误文案逐字对齐 iOS）', () {
    test('无效 URL → 无效的URL', () async {
      final SubscribeConfigLoader loader = _loader((http.Request r) => _resp('{}'));
      expect(await loader.load('not a url'), '无效的URL');
    });

    test('非 2xx → 服务器返回错误: <code>', () async {
      final SubscribeConfigLoader loader =
          _loader((http.Request r) => _resp('nope', 404));
      expect(await loader.load('https://src/x.json'), '服务器返回错误: 404');
    });

    test('两次均返回 HTML → 该地址返回的是网页，不是JSON配置', () async {
      final SubscribeConfigLoader loader =
          _loader((http.Request r) => _resp('<!DOCTYPE html><html></html>'));
      expect(await loader.load('https://src/x.json'), '该地址返回的是网页，不是JSON配置');
    });

    test('无效 JSON → 无效JSON格式', () async {
      final SubscribeConfigLoader loader = _loader((http.Request r) => _resp('not json'));
      expect(await loader.load('https://src/x.json'), '无效JSON格式');
    });

    test('无可用站点 → 该订阅源未包含任何可用站点', () async {
      final SubscribeConfigLoader loader =
          _loader((http.Request r) => _resp('{"sites":[]}'));
      expect(await loader.load('https://src/x.json'), '该订阅源未包含任何可用站点');
    });
  });

  group('请求与清洗', () {
    test('桌面 UA 返回 HTML → App UA 重试成功', () async {
      final List<String> uas = <String>[];
      final SubscribeConfigLoader loader = _loader((http.Request r) {
        final String ua =
            r.headers['user-agent'] ?? r.headers['User-Agent'] ?? '';
        uas.add(ua);
        if (ua == kSubscribeAppUA) {
          return _resp(jsonEncode(_fullSource()));
        }
        return _resp('<html>页面</html>');
      });

      expect(await loader.load('https://src/x.json'), isNull);
      expect(uas, <String>[kSubscribeDesktopUA, kSubscribeAppUA]);
    });

    test('注释行（// 与 #）与 JSON 前缀被清洗', () async {
      final String dirty =
          '// 这是注释\n# 也是注释\n一些说明文字\n${jsonEncode(_fullSource())}';
      final SubscribeConfigLoader loader = _loader((http.Request r) => _resp(dirty));
      expect(await loader.load('https://src/x.json'), isNull);
    });

    test('URL 首尾空白被 trim 后请求并落盘', () async {
      final SubscribeConfigLoader loader =
          _loader((http.Request r) => _resp(jsonEncode(_fullSource())));
      expect(await loader.load('  https://src/x.json  '), isNull);
      final SubscribeConfigStore store =
          SubscribeConfigStore(prefs: pm); // 新一轮 store 从契约键读回
      await store.load();
      expect(store.configUrls, <String>['https://src/x.json']);
    });
  });

  group('成功路径：站点合成 + SQLite 落库', () {
    test('返回 null，store 写入配置与 URL，四表落库', () async {
      final SubscribeConfigStore store = SubscribeConfigStore(prefs: pm);
      final SubscribeConfigLoader loader = SubscribeConfigLoader(
        client: HttpClient(
          inner: MockClient(
            (http.Request r) async => _resp(jsonEncode(_fullSource())),
          ),
          maxRetries: 0,
        ),
        store: store,
        nowSeconds: () => 1000000,
      );

      expect(await loader.load('https://src/x.json'), isNull);

      // store 侧：配置合成（标准站 1 + apiyuan api_2 + zhanyuan zhan_3）。
      expect(store.config, isNotNull);
      expect(store.config!.sites, hasLength(3));
      expect(store.config!.parses.single.name, '解析A');
      expect(store.configUrls, <String>['https://src/x.json']);

      // 落库：subscription。
      final List<Map<String, Object?>> subs =
          await dbm.queryAll(SubscriptionItem.table);
      expect(subs, hasLength(1));
      expect(subs.single['dyname'], '测试订阅');
      expect(subs.single['dyzz'], '作者甲');
      expect(subs.single['lastSyncAt'], 1000000);

      // 落库：zhanyuan / apiyuan / jiexisetting。
      final List<Map<String, Object?>> zhan = await dbm.queryAll(Zhanyuan.table);
      expect(zhan, hasLength(1));
      expect(zhan.single['name'], '站源甲');
      expect(zhan.single['searchUrl'], 'https://z/search');
      expect(zhan.single['dyurl'], 'https://src/x.json');

      final List<Map<String, Object?>> api = await dbm.queryAll(Apiyuan.table);
      expect(api, hasLength(1));
      expect(api.single['name'], 'API甲');

      final List<Map<String, Object?>> jiexi = await dbm.queryAll(Jiexisetting.table);
      expect(jiexi, hasLength(1));
      expect(jiexi.single['bianma'], 'utf-8');
      expect(jiexi.single['zhuurl'], 'https://main');
    });

    test('缺 dyname → 回退「未知订阅」', () async {
      final Map<String, Object?> src = _fullSource()..remove('dyname');
      final SubscribeConfigLoader loader =
          _loader((http.Request r) => _resp(jsonEncode(src)));

      expect(await loader.load('https://src/x.json'), isNull);
      final List<Map<String, Object?>> subs =
          await dbm.queryAll(SubscriptionItem.table);
      expect(subs.single['dyname'], '未知订阅');
    });

    test('无 zhanyuan 字段 → 由 sites type=2 的 ext 兜底落库', () async {
      final Map<String, Object?> src = <String, Object?>{
        'dyname': '站源订阅',
        'sites': <Object?>[
          <String, Object?>{
            'key': 'zhan_1',
            'name': '站源乙',
            'type': 2,
            'api': 'https://z2/search',
            'ext': jsonEncode(<String, Object?>{'searchname': 'wd'}),
          },
        ],
      };
      final SubscribeConfigLoader loader =
          _loader((http.Request r) => _resp(jsonEncode(src)));

      expect(await loader.load('https://src/x.json'), isNull);
      final List<Map<String, Object?>> zhan = await dbm.queryAll(Zhanyuan.table);
      expect(zhan, hasLength(1));
      expect(zhan.single['name'], '站源乙');
      expect(zhan.single['searchUrl'], 'https://z2/search');
    });
  });
}