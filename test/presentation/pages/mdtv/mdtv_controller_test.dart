/// 麻豆平台控制器单测：密钥/Tab 持久化 + 加密请求/解密响应 + 数据解析。
///
/// 无真实网络：注入 `MockClient`（`package:http/testing`）返回预加密响应；
/// 持久化走 `SharedPreferences.setMockInitialValues` + `FlutterSecureStorage`。
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vbox/core/network/http_client.dart';
import 'package:vbox/data/datasources/local/prefs_manager.dart';
import 'package:vbox/domain/entities/mdtv/mdtv.dart';
import 'package:vbox/presentation/pages/mdtv/mdtv_controller.dart';

/// 取首个「合法长度密钥字节」（可指定起始候选索引，避免命中默认 index 0）。
List<int> _validKey(int minIndex) {
  for (int i = minIndex; i < MdtvCrypto.keyCandidates.length; i++) {
    final List<int>? b = MdtvCrypto.hexToBytes(MdtvCrypto.keyCandidates[i]);
    if (b != null && (b.length == 16 || b.length == 24 || b.length == 32)) {
      return b;
    }
  }
  throw StateError('keyCandidates 中无合法长度密钥');
}

/// 用固定 key/iv/CFB 加密 [payload]，返回 base64 密文（对齐 iOS `{"data": ...}`）。
String _cipherBase64(Object payload, List<int> key, List<int> iv) {
  final List<int> cipher =
      MdtvAes.cfbEncrypt(key, iv, utf8.encode(jsonEncode(payload)))!;
  return base64Encode(cipher);
}

/// 生成完整响应体：`{"data": "<base64 密文>"}`。
String _encryptedResponse(Object payload, List<int> key, List<int> iv) =>
    jsonEncode(<String, Object?>{'data': _cipherBase64(payload, key, iv)});

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
    test('init 前 isInitialized=false；init 后默认 Tab + 未校验密钥', () async {
      final MdtvController c = MdtvController();
      addTearDown(c.dispose);
      expect(c.isInitialized, isFalse);
      await c.init();
      expect(c.isInitialized, isTrue);
      expect(c.isKeyFound, isFalse);
      expect(c.homeTabs, MdtvController.defaultTabs);
    });

    test('baseUrl 缺省回退 / 构造参数覆盖', () {
      expect(MdtvController().baseUrl, MdtvController.fallbackBaseUrl);
      expect(
        MdtvController(baseUrl: 'https://api.example.com').baseUrl,
        'https://api.example.com',
      );
    });

    test('imageURL：相对路径拼 CDN，绝对地址透传', () {
      final MdtvController c = MdtvController();
      addTearDown(c.dispose);
      expect(c.imageURL('/a.jpg'), '${MdtvController.imageCdn}/a.jpg');
      expect(c.imageURL('a.jpg'), '${MdtvController.imageCdn}/a.jpg');
      expect(c.imageURL('https://x.com/a.jpg'), 'https://x.com/a.jpg');
      expect(c.imageURL('  '), '');
    });
  });

  group('加密请求 / 解密响应', () {
    test('fetchTabConfig 解密并持久化 Tab 与密钥配置，跨实例恢复', () async {
      final List<int> key = _validKey(1);
      final List<int> iv = MdtvCrypto.hexToBytes(MdtvCrypto.ivCandidates.first)!;
      final String body =
          _encryptedResponse(<String, Object?>{'data': <String>['推荐', '分类', '我的']}, key, iv);
      final MockClient client =
          MockClient((http.Request _) async => http.Response(body, 200));
      final MdtvController c =
          MdtvController(client: HttpClient(inner: client));
      addTearDown(c.dispose);

      await c.init();
      final List<String> tabs = await c.fetchTabConfig();
      expect(tabs, <String>['推荐', '分类', '我的']);
      expect(c.homeTabs, <String>['推荐', '分类', '我的']);
      expect(c.isKeyFound, isTrue);

      final MdtvController c2 =
          MdtvController(client: HttpClient(inner: client));
      addTearDown(c2.dispose);
      await c2.init();
      expect(c2.homeTabs, <String>['推荐', '分类', '我的']);
      expect(c2.isKeyFound, isTrue);
    });

    test('fetchVideos 解密并解析视频列表（验证 _unwrapList 与模型映射）', () async {
      final List<int> key = _validKey(1);
      final List<int> iv = MdtvCrypto.hexToBytes(MdtvCrypto.ivCandidates.first)!;
      final String body = _encryptedResponse(<String, Object?>{
        'data': <Map<String, Object?>>[
          <String, Object?>{
            'videoId': 'v1',
            'title': '测试视频',
            'cover': '/c/1.jpg',
            'duration': '12:00',
            'views': 9,
            'likes': 1,
            'categoryId': 'c1',
          },
        ],
      }, key, iv);
      final MockClient client =
          MockClient((http.Request _) async => http.Response(body, 200));
      final MdtvController c =
          MdtvController(client: HttpClient(inner: client));
      addTearDown(c.dispose);

      final List<MdtvVideoItem> videos = await c.fetchVideos(categoryId: 'c1');
      expect(videos.length, 1);
      expect(videos.first.videoId, 'v1');
      expect(videos.first.title, '测试视频');
      expect(videos.first.categoryId, 'c1');
    });

    test('HTTP 非 2xx 抛 MdtvException', () async {
      final MockClient client =
          MockClient((http.Request _) async => http.Response('', 500));
      final MdtvController c =
          MdtvController(client: HttpClient(inner: client));
      addTearDown(c.dispose);
      await expectLater(c.fetchCategories(), throwsA(isA<MdtvException>()));
    });
  });

  group('密钥配置持久化', () {
    test('bruteForceDecrypt 命中后持久化；resetKeyConfig 清除', () async {
      final List<int> key = _validKey(1);
      final List<int> iv = MdtvCrypto.hexToBytes(MdtvCrypto.ivCandidates.first)!;
      final String b64 = _cipherBase64(<String, Object?>{'code': 200}, key, iv);

      final MdtvController c = MdtvController();
      addTearDown(c.dispose);
      final Object? json = await c.bruteForceDecrypt(b64);
      expect(json, isA<Map<dynamic, dynamic>>());
      expect(c.isKeyFound, isTrue);

      await c.resetKeyConfig();
      expect(c.isKeyFound, isFalse);

      final MdtvController c2 = MdtvController();
      addTearDown(c2.dispose);
      await c2.init();
      expect(c2.isKeyFound, isFalse);
    });
  });

  group('Tab 持久化', () {
    test('init 载入持久化 Tab；resetTabs 恢复默认并清除', () async {
      await pm.setJsonList('mdtv_home_tabs', <String>['A', 'B']);
      final MdtvController c = MdtvController();
      addTearDown(c.dispose);
      await c.init();
      expect(c.homeTabs, <String>['A', 'B']);

      await c.resetTabs();
      expect(c.homeTabs, MdtvController.defaultTabs);

      final MdtvController c2 = MdtvController();
      addTearDown(c2.dispose);
      await c2.init();
      expect(c2.homeTabs, MdtvController.defaultTabs);
    });

    test('默认 Tab（未持久化）回退 defaultTabs', () async {
      final MdtvController c = MdtvController();
      addTearDown(c.dispose);
      await c.init();
      expect(c.homeTabs, MdtvController.defaultTabs);
    });
  });
}