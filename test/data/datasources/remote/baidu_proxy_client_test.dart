/// 数据层单测：百度网盘专用代理客户端（批次 F · F-05）。
///
/// 用假传输 [BaiduProxyTransport] 驱动「序列化 → 签名 → 发送 → 解析」全链，
/// 覆盖签名向量、失败分支与 PCS 设备指纹持久化。
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vbox/data/datasources/local/prefs_manager.dart';
import 'package:vbox/data/datasources/remote/baidu_proxy_client.dart';
import 'package:vbox/domain/entities/cloud/baidu_proxy.dart';

/// 记录调用并返回预设响应的假传输。
class _FakeTransport implements BaiduProxyTransport {
  _FakeTransport(this.response);

  Object? response;

  final List<({String path, String body, Map<String, String> headers})> calls =
      <({String path, String body, Map<String, String> headers})>[];

  @override
  Future<Object?> postJson(
    String path,
    String body,
    Map<String, String> headers,
  ) async {
    calls.add((path: path, body: body, headers: headers));
    return response;
  }
}

BaiduProxyClient _client(_FakeTransport transport) => BaiduProxyClient(
      transport: transport,
      clock: () => 1700000000000,
      nonceFactory: () => 'abcdef0123456789abcdef0123456789',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('parseShareLink', () {
    test('原样发送已签名 body，签名与 Node 端向量一致', () async {
      final _FakeTransport transport = _FakeTransport(<String, dynamic>{
        'success': true,
        'data': <String, dynamic>{'url': 'play-url', 'type': 'mp4'},
      });
      final BaiduProxyResponse res = await _client(transport).parseShareLink(
        url: 'https://pan.baidu.com/s/abc',
      );

      expect(res.success, isTrue);
      expect(res.data?.url, 'play-url');
      final ({String path, String body, Map<String, String> headers}) call =
          transport.calls.single;
      expect(call.path, BaiduProxyEndpoints.parsePath);
      // 关键：body 必须与签名时序列化结果逐字节一致。
      expect(
        call.body,
        '{"url":"https://pan.baidu.com/s/abc","pwd":"","cookie":""}',
      );
      expect(
        call.headers['X-Signature'],
        '5073113ce839633c3d170c62ea25d3483e06a3201ff333a07e2487c255678e95',
      );
      expect(call.headers['X-Auth-Token'], '199114');
      expect(call.headers['X-Timestamp'], '1700000000000');
      expect(call.headers['X-Nonce'], 'abcdef0123456789abcdef0123456789');
    });
  });

  group('getPlayURL', () {
    test('body 顺序与签名向量一致', () async {
      final _FakeTransport transport = _FakeTransport(<String, dynamic>{
        'success': true,
        'data': <String, dynamic>{'url': 'u', 'type': 'mp4'},
      });
      await _client(transport).getPlayURL(
        shareURL: 'x',
        pwd: '1',
        fsId: '9',
        cookie: 'c',
        pcsCookie: 'p',
      );

      final ({String path, String body, Map<String, String> headers}) call =
          transport.calls.single;
      expect(call.path, BaiduProxyEndpoints.playPath);
      expect(
        call.body,
        '{"url":"x","pwd":"1","fs_id":"9","cookie":"c","pcs_cookie":"p"}',
      );
      expect(
        call.headers['X-Signature'],
        '07eb5f2d15109f8ccd6e363f4cb4d877d0d0e306fb2c288ebc33d76ed8441fcc',
      );
    });
  });

  group('失败分支', () {
    test('success=false 带 error → 抛错并携带服务端文案', () async {
      final _FakeTransport transport = _FakeTransport(<String, dynamic>{
        'success': false,
        'error': '链接已失效',
      });
      await expectLater(
        _client(transport).parseShareLink(url: 'u'),
        throwsA(
          isA<BaiduProxyException>()
              .having((BaiduProxyException e) => e.message, 'message', '链接已失效'),
        ),
      );
    });

    test('success=false 无 error → 回退默认文案', () async {
      final _FakeTransport transport =
          _FakeTransport(<String, dynamic>{'success': false});
      await expectLater(
        _client(transport).parseShareLink(url: 'u'),
        throwsA(
          isA<BaiduProxyException>().having(
            (BaiduProxyException e) => e.message,
            'message',
            '百度代理请求失败',
          ),
        ),
      );
    });

    test('非对象响应 → 抛解析失败', () async {
      final _FakeTransport transport = _FakeTransport('not-json');
      await expectLater(
        _client(transport).parseShareLink(url: 'u'),
        throwsA(
          isA<BaiduProxyException>().having(
            (BaiduProxyException e) => e.message,
            'message',
            '无效的 JSON 响应',
          ),
        ),
      );
    });

    test('缺省「未接入」传输：报百度代理未接入', () async {
      await expectLater(
        const UnavailableBaiduProxyTransport().postJson('/p', '{}', const <String, String>{}),
        throwsA(
          isA<BaiduProxyException>().having(
            (BaiduProxyException e) => e.message,
            'message',
            '百度代理未接入',
          ),
        ),
      );
    });
  });

  group('BaiduPcsDeviceId', () {
    late PrefsManager pm;

    setUpAll(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      pm = PrefsManager.instance;
      await pm.init();
    });

    setUp(() async {
      await pm.clearAll();
    });

    test('首次生成 32 位大写 hex 并持久化，后续复用同值', () async {
      final String first = await BaiduPcsDeviceId.ensure(prefs: pm);
      expect(first.length, 32);
      expect(RegExp(r'^[0-9A-F]{32}$').hasMatch(first), isTrue);

      // 第二次不再走生成器，读回同一值。
      bool generatedAgain = false;
      final String second = await BaiduPcsDeviceId.ensure(
        prefs: pm,
        generator: () {
          generatedAgain = true;
          return 'FFFF';
        },
      );
      expect(second, first);
      expect(generatedAgain, isFalse);
      expect(await pm.getString(BaiduPcsDeviceId.key), first);
    });

    test('已存在值直接返回（不覆盖）', () async {
      await pm.set(BaiduPcsDeviceId.key, 'PRESEEDED');
      final String value = await BaiduPcsDeviceId.ensure(prefs: pm);
      expect(value, 'PRESEEDED');
    });
  });
}
