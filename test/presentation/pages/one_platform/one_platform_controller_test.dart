/// One 平台控制器单测：初始化 / 加密请求 / 解密响应 / 密钥持久化 / 手动配置。
///
/// 无真实网络：注入 `MockClient`（`package:http/testing`）返回预加密响应；
/// 持久化走 `SharedPreferences.setMockInitialValues` + `FlutterSecureStorage`。
///
/// 协议：响应体 = `base64(AES-128-CBC(json))`，明文含 `code`（0/200 为成功）。
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vbox/core/network/http_client.dart';
import 'package:vbox/data/datasources/local/prefs_manager.dart';
import 'package:vbox/domain/entities/one_platform/one_platform.dart';
import 'package:vbox/presentation/pages/one_platform/one_platform_controller.dart';

List<int> _key(int idx) =>
    OnePlatformCrypto.hexToBytes(OnePlatformCrypto.keyCandidates[idx])!;
List<int> _iv(int idx) =>
    OnePlatformCrypto.hexToBytes(OnePlatformCrypto.ivCandidates[idx])!;

/// 用指定 key/iv 加密 [payload] 并 base64，作为原始响应体。
String _cipher(Object payload, {int keyIdx = 0, int ivIdx = 0}) =>
    base64Encode(
      OnePlatformCrypto.cbcEncrypt(
        _key(keyIdx),
        _iv(ivIdx),
        utf8.encode(jsonEncode(payload)),
      )!,
    );

/// 惰性 MockClient：按路径返回加密响应。
MockClient _mock(Map<String, Object> dataByPath) => MockClient(
      (http.Request req) async {
        final Object payload = dataByPath[req.url.path] ??
            <String, Object?>{'code': 0, 'data': <Object?>[]};
        return http.Response(_cipher(payload), 200);
      },
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final PrefsManager pm = PrefsManager.instance;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    await pm.init();
  });

  setUp(() async {
    await pm.clearAll();
  });

  group('初始化与默认值', () {
    test('init 前 isInitialized=false；init 后生成 32 位 UUID', () async {
      final OnePlatformController c = OnePlatformController();
      addTearDown(c.dispose);
      expect(c.isInitialized, isFalse);
      await c.init();
      expect(c.isInitialized, isTrue);
      expect(c.uuid.length, 32);
      expect(c.isRegistered, isFalse);
      expect(c.isKeyFound, isFalse);
      expect(c.keyIndex, 0);
      expect(c.ivIndex, 0);
    });

    test('UUID 跨实例复用（持久化）', () async {
      final OnePlatformController c1 = OnePlatformController();
      addTearDown(c1.dispose);
      await c1.init();
      final String uuid = c1.uuid;

      final OnePlatformController c2 = OnePlatformController();
      addTearDown(c2.dispose);
      await c2.init();
      expect(c2.uuid, uuid);
    });

    test('baseUrl 缺省回退 / 构造参数覆盖', () {
      expect(OnePlatformController().baseUrl,
          OnePlatformController.fallbackBaseUrl);
      expect(
        OnePlatformController(baseUrl: 'https://api.example.com').baseUrl,
        'https://api.example.com',
      );
    });

    test('imageURL：相对路径拼 CDN，绝对地址透传', () {
      final OnePlatformController c = OnePlatformController();
      addTearDown(c.dispose);
      expect(c.imageURL('/a.jpg'), '${OnePlatformController.imageCdn}/a.jpg');
      expect(c.imageURL('a.jpg'), '${OnePlatformController.imageCdn}/a.jpg');
      expect(c.imageURL('https://x.com/a.jpg'), 'https://x.com/a.jpg');
      expect(c.imageURL('  '), '');
    });
  });

  group('加密请求 / 解密响应', () {
    test('fetchCategories 解密并解析分类', () async {
      final MockClient mock = _mock(<String, Object>{
        '/v2.5/article/category': <String, Object?>{
          'code': 0,
          'data': <Map<String, Object?>>[
            <String, Object?>{'cateid': '1', 'name': '国产'},
            <String, Object?>{'cateid': '2', 'name': '日韩'},
          ],
        },
      });
      final OnePlatformController c =
          OnePlatformController(client: HttpClient(inner: mock, maxRetries: 0));
      addTearDown(c.dispose);
      await c.init();
      await c.saveToken(token: 'tk', userKey: 'uk', uuid: c.uuid);

      final List<OneCategory> cats = await c.fetchCategories();
      expect(cats.map((OneCategory e) => e.name).toList(), <String>['国产', '日韩']);
      expect(cats.first.cateId, '1');
    });

    test('fetchCategories 失败回退默认分类（业务错误码）', () async {
      final MockClient mock = _mock(<String, Object>{
        '/v2.5/article/category':
            <String, Object?>{'code': 500, 'message': '服务异常'},
      });
      final OnePlatformController c =
          OnePlatformController(client: HttpClient(inner: mock, maxRetries: 0));
      addTearDown(c.dispose);
      await c.init();
      await c.saveToken(token: 'tk', userKey: 'uk', uuid: c.uuid);

      final List<OneCategory> cats = await c.fetchCategories();
      expect(cats, OnePlatformController.defaultCategories);
    });

    test('fetchVideos 解密并解析列表（封面补 CDN、评分、分页）', () async {
      final MockClient mock = _mock(<String, Object>{
        '/v2.5/article/list': <String, Object?>{
          'code': 200,
          'data': <String, Object?>{
            'rows': <Map<String, Object?>>[
              <String, Object?>{
                'id': 'a1',
                'title': '测试视频',
                'cover': '/c/1.jpg',
                'duration': '12:00',
                'views': 12345,
                'likes': 3,
                'cateid': '1',
                'score': '8.5',
              },
            ],
            'total': 1,
            'totalpage': 1,
          },
        },
      });
      final OnePlatformController c =
          OnePlatformController(client: HttpClient(inner: mock, maxRetries: 0));
      addTearDown(c.dispose);
      await c.init();
      await c.saveToken(token: 'tk', userKey: 'uk', uuid: c.uuid);

      final OneVideoPage page = await c.fetchVideos(categoryId: '1');
      expect(page.items.length, 1);
      expect(page.items.first.articleId, 'a1');
      expect(page.items.first.title, '测试视频');
      expect(page.items.first.cover,
          '${OnePlatformController.imageCdn}/c/1.jpg');
      expect(page.items.first.rating, '8.5');
      expect(page.items.first.views, 12345);
      expect(page.hasMore, isFalse);
    });

    test('fetchDailyRecommend 解密并解析列表', () async {
      final MockClient mock = _mock(<String, Object>{
        '/v2.5/article/day': <String, Object?>{
          'code': 0,
          'data': <Map<String, Object?>>[
            <String, Object?>{'id': 'd1', 'title': '每日推荐'},
          ],
        },
      });
      final OnePlatformController c =
          OnePlatformController(client: HttpClient(inner: mock, maxRetries: 0));
      addTearDown(c.dispose);
      await c.init();
      await c.saveToken(token: 'tk', userKey: 'uk', uuid: c.uuid);

      final List<OneVideoItem> items = await c.fetchDailyRecommend();
      expect(items.map((OneVideoItem e) => e.articleId).toList(), <String>['d1']);
    });

    test('HTTP 非 2xx 时 request 抛 OnePlatformException', () async {
      final MockClient mock =
          MockClient((http.Request _) async => http.Response('', 404));
      final OnePlatformController c =
          OnePlatformController(client: HttpClient(inner: mock, maxRetries: 0));
      addTearDown(c.dispose);
      await c.init();
      await c.saveToken(token: 'tk', userKey: 'uk', uuid: c.uuid);

      await expectLater(
        c.request('/v2.5/article/category'),
        throwsA(isA<OnePlatformException>()),
      );
    });
  });

  group('密钥配置持久化', () {
    test('响应命中非默认密钥组合 → 持久化索引，跨实例恢复', () async {
      // 用 key[1] + iv[1]（零 IV）加密，默认组合（0,0）解不开，触发遍历探测。
      final String body = jsonEncode(<String, Object?>{
        'code': 0,
        'data': <Object?>[],
      });
      final String cipher = base64Encode(OnePlatformCrypto.cbcEncrypt(
        _key(1),
        _iv(1),
        utf8.encode(body),
      )!);
      final MockClient mock =
          MockClient((http.Request _) async => http.Response(cipher, 200));

      final OnePlatformController c =
          OnePlatformController(client: HttpClient(inner: mock, maxRetries: 0));
      addTearDown(c.dispose);
      await c.init();
      await c.saveToken(token: 'tk', userKey: 'uk', uuid: c.uuid);

      final Map<String, dynamic> json =
          await c.request('/v2.5/article/category');
      expect(json['code'], 0);
      expect(c.isKeyFound, isTrue);
      expect(c.keyIndex, 1);
      expect(c.ivIndex, 1);

      final OnePlatformController c2 =
          OnePlatformController(client: HttpClient(inner: mock, maxRetries: 0));
      addTearDown(c2.dispose);
      await c2.init();
      expect(c2.isKeyFound, isTrue);
      expect(c2.keyIndex, 1);
      expect(c2.ivIndex, 1);

      await c2.resetKeyConfig();
      expect(c2.isKeyFound, isFalse);
      expect(c2.keyIndex, 0);
      expect(c2.ivIndex, 0);

      final OnePlatformController c3 =
          OnePlatformController(client: HttpClient(inner: mock, maxRetries: 0));
      addTearDown(c3.dispose);
      await c3.init();
      expect(c3.isKeyFound, isFalse);
    });
  });

  group('手动配置', () {
    test('saveToken 持久化 token/user-key/isRegistered', () async {
      final OnePlatformController c = OnePlatformController();
      addTearDown(c.dispose);
      await c.init();
      await c.saveToken(token: '  tk  ', userKey: ' uk ', uuid: 'u1');
      expect(c.token, 'tk');
      expect(c.userKey, 'uk');
      expect(c.uuid, 'u1');
      expect(c.isRegistered, isTrue);
      expect(c.isConfigured, isTrue);

      final OnePlatformController c2 = OnePlatformController();
      addTearDown(c2.dispose);
      await c2.init();
      expect(c2.token, 'tk');
      expect(c2.userKey, 'uk');
      expect(c2.uuid, 'u1');
      expect(c2.isRegistered, isTrue);
    });
  });
}