/// 数据层单测：extscreen API 客户端（批次 F · F-04）。
///
/// 用假传输 [ExtscreenTransport] 驱动「取时间戳 → 二维码 → 轮询 →
/// 换 refresh_token → 刷新 access_token」全链，覆盖成功与失败分支。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/data/datasources/remote/aliyun_extscreen_client.dart';
import 'package:vbox/domain/entities/cloud/aliyun_extscreen.dart';

/// 记录调用并返回预设响应的假传输。
class _FakeTransport implements ExtscreenTransport {
  _FakeTransport(this.handler);

  final ExtscreenHttpResult Function(
    String method,
    Uri url,
    Map<String, String>? headers,
    Map<String, dynamic>? body,
  ) handler;

  final List<({String method, Uri url})> calls =
      <({String method, Uri url})>[];

  @override
  Future<ExtscreenHttpResult> request({
    required String method,
    required Uri url,
    Map<String, String>? headers,
    Map<String, dynamic>? jsonBody,
  }) async {
    calls.add((method: method, url: url));
    return handler(method, url, headers, jsonBody);
  }
}

ExtscreenHttpResult _json(Object body, {int status = 200}) => ExtscreenHttpResult(
      statusCode: status,
      body: body is String ? body : jsonEncode(body),
    );

/// IV 明文串 → hex（服务端返回的 IV 为 hex 格式）。
String _ivHex(String iv) =>
    iv.codeUnits.map((int c) => c.toRadixString(16).padLeft(2, '0')).join();

void main() {
  final ExtscreenCrypto crypto = ExtscreenCrypto(
    timestamp: '1700000000000',
    uniqueId: 'a1b2c3d4e5f60718293a4b5c6d7e8f90',
    wifiMac: '123456789012',
  );

  /// 用 [crypto] 生成服务端加密信封响应。
  Map<String, dynamic> encryptedResponse(Map<String, dynamic> plain) {
    final ({String iv, String ciphertext}) enc = crypto.encrypt(plain);
    return <String, dynamic>{
      'code': 200,
      'data': <String, dynamic>{'iv': _ivHex(enc.iv), 'ciphertext': enc.ciphertext},
      't': crypto.timestamp,
    };
  }

  ExtscreenApiClient clientWith(
    ExtscreenHttpResult Function(
      String method,
      Uri url,
      Map<String, String>? headers,
      Map<String, dynamic>? body,
    ) handler,
  ) =>
      ExtscreenApiClient(
        transport: _FakeTransport(handler),
        delay: (Duration _) async {},
      );

  group('getTimestamp', () {
    test('解析 data.timestamp 为字符串', () async {
      final ExtscreenApiClient c = clientWith((_, __, ___, ____) =>
          _json(<String, dynamic>{
            'code': 200,
            'data': <String, dynamic>{'timestamp': 1700000000000},
          }));
      expect(await c.getTimestamp(), '1700000000000');
    });

    test('HTTP 非 200 / code 非 200 均抛错', () async {
      final ExtscreenApiClient http =
          clientWith((_, __, ___, ____) => _json('{}', status: 500));
      await expectLater(http.getTimestamp(), throwsA(isA<ExtscreenException>()));

      final ExtscreenApiClient code =
          clientWith((_, __, ___, ____) => _json(<String, dynamic>{'code': 500}));
      await expectLater(code.getTimestamp(), throwsA(isA<ExtscreenException>()));
    });
  });

  group('getQrcode', () {
    test('加密请求体 + 解密响应得到 sid 与授权链接', () async {
      late Map<String, dynamic> sentBody;
      late Map<String, String> sentHeaders;
      final ExtscreenApiClient c = clientWith((method, url, headers, body) {
        sentBody = body!;
        sentHeaders = headers!;
        return _json(encryptedResponse(<String, dynamic>{'sid': 'SID-1'}));
      });

      final ({String qrLink, String sid}) out = await c.getQrcode(crypto);

      expect(out.sid, 'SID-1');
      expect(
        out.qrLink,
        'https://www.aliyundrive.com/o/oauth/authorize?sid=SID-1',
      );
      expect(sentBody.keys.toSet(), <String>{'iv', 'ciphertext'});
      expect(sentHeaders['sign']!.length, 64);
      expect(sentHeaders['akv'], '2.6.1143');
    });

    test('业务错误码抛错', () async {
      final ExtscreenApiClient c = clientWith((_, __, ___, ____) =>
          _json(<String, dynamic>{'code': 401, 'msg': 'bad'}));
      await expectLater(c.getQrcode(crypto), throwsA(isA<ExtscreenException>()));
    });
  });

  group('pollQrcodeStatus', () {
    test('New → Scaned → LoginSuccess 返回 authCode 并回调状态', () async {
      final List<String> statuses = <String>['New', 'Scaned', 'LoginSuccess'];
      int i = 0;
      final ExtscreenApiClient c = clientWith((_, __, ___, ____) {
        final String status = statuses[i++];
        return _json(<String, dynamic>{
          'status': status,
          if (status == 'LoginSuccess') 'authCode': 'AC-1',
        });
      });

      final List<String> seen = <String>[];
      final String authCode = await c.pollQrcodeStatus(
        sid: 'SID-1',
        onStatusChange: seen.add,
      );
      expect(authCode, 'AC-1');
      expect(seen, <String>['New', 'Scaned', 'LoginSuccess']);
    });

    test('Expired 抛扫码超时', () async {
      final ExtscreenApiClient c = clientWith(
          (_, __, ___, ____) => _json(<String, dynamic>{'status': 'Expired'}));
      await expectLater(
        c.pollQrcodeStatus(sid: 'S'),
        throwsA(isA<ExtscreenException>()),
      );
    });

    test('超时抛错', () async {
      final ExtscreenApiClient c = ExtscreenApiClient(
        transport: _FakeTransport(
            (_, __, ___, ____) => _json(<String, dynamic>{'status': 'New'})),
        delay: (Duration _) async {},
        timeout: const Duration(milliseconds: 30),
        pollInterval: Duration.zero,
      );
      await expectLater(
        c.pollQrcodeStatus(sid: 'S'),
        throwsA(isA<ExtscreenException>()),
      );
    });
  });

  group('getRefreshToken', () {
    test('解密得到 refresh_token', () async {
      final ExtscreenApiClient c = clientWith((_, __, ___, ____) =>
          _json(encryptedResponse(<String, dynamic>{'refresh_token': 'RT-1'})));
      expect(
        await c.getRefreshToken(authCode: 'AC', crypto: crypto),
        'RT-1',
      );
    });

    test('HTTP 非 200 抛错', () async {
      final ExtscreenApiClient c =
          clientWith((_, __, ___, ____) => _json('{}', status: 502));
      await expectLater(
        c.getRefreshToken(authCode: 'AC', crypto: crypto),
        throwsA(isA<ExtscreenException>()),
      );
    });
  });

  group('refresh', () {
    test('解密得到 access_token / expires_in', () async {
      final ExtscreenApiClient c = clientWith((_, __, ___, ____) =>
          _json(encryptedResponse(<String, dynamic>{
            'access_token': 'AT-1',
            'refresh_token': 'RT-2',
            'expires_in': 7200,
            'token_type': 'Bearer',
          })));
      final ExtscreenToken token =
          await c.refresh(refreshToken: 'RT', crypto: crypto);
      expect(token.accessToken, 'AT-1');
      expect(token.refreshToken, 'RT-2');
      expect(token.expiresIn, 7200);
      expect(token.tokenType, 'Bearer');
    });

    test('缺 access_token 抛错', () async {
      final ExtscreenApiClient c = clientWith(
          (_, __, ___, ____) => _json(encryptedResponse(<String, dynamic>{})));
      await expectLater(
        c.refresh(refreshToken: 'RT', crypto: crypto),
        throwsA(isA<ExtscreenException>()),
      );
    });
  });
}
