/// 领域层单测：百度网盘专用代理（批次 F · F-05）。
///
/// 对齐基准（唯一真相源）：iOS `BaiduProxyClient.swift`
/// （Cloudflare Worker HMAC-SHA256 签名 + 响应模型）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/cloud/baidu_proxy.dart';

void main() {
  group('BaiduProxySigner', () {
    // 固定向量由 Node `crypto.createHmac('sha256', secret)` 生成，锁定跨端一致性。
    const String secret = 'vbox-baidu-secret-2026-change-me';
    const String timestamp = '1700000000000';
    const String nonce = 'abcdef0123456789abcdef0123456789';

    test('parse 路径签名与 Node 端一致（固定向量）', () {
      const BaiduProxySigner signer = BaiduProxySigner();
      final String sig = signer.sign(
        path: BaiduProxyEndpoints.parsePath,
        timestamp: timestamp,
        nonce: nonce,
        body: '{"url":"https://pan.baidu.com/s/abc","pwd":"","cookie":""}',
      );
      expect(
        sig,
        '5073113ce839633c3d170c62ea25d3483e06a3201ff333a07e2487c255678e95',
      );
      expect(sig.length, 64);
    });

    test('play 路径签名与 Node 端一致（固定向量）', () {
      const BaiduProxySigner signer = BaiduProxySigner();
      final String sig = signer.sign(
        path: BaiduProxyEndpoints.playPath,
        timestamp: timestamp,
        nonce: nonce,
        body:
            '{"url":"x","pwd":"1","fs_id":"9","cookie":"c","pcs_cookie":"p"}',
      );
      expect(
        sig,
        '07eb5f2d15109f8ccd6e363f4cb4d877d0d0e306fb2c288ebc33d76ed8441fcc',
      );
    });

    test('secret 可注入：不同密钥得到不同签名', () {
      const BaiduProxySigner custom = BaiduProxySigner(secret: secret);
      const BaiduProxySigner other = BaiduProxySigner(secret: 'other');
      final String a = custom.sign(
        path: '/p',
        timestamp: '1',
        nonce: 'n',
        body: 'b',
      );
      final String b = other.sign(
        path: '/p',
        timestamp: '1',
        nonce: 'n',
        body: 'b',
      );
      expect(a, isNot(b));
    });

    test('headers 携带鉴权四要素，X-Signature 等于 sign()', () {
      const BaiduProxySigner signer = BaiduProxySigner();
      final Map<String, String> headers = signer.headers(
        path: BaiduProxyEndpoints.parsePath,
        timestamp: timestamp,
        nonce: nonce,
        body: '{}',
      );
      expect(headers['X-Auth-Token'], BaiduProxyEndpoints.token);
      expect(headers['X-Timestamp'], timestamp);
      expect(headers['X-Nonce'], nonce);
      expect(
        headers['X-Signature'],
        signer.sign(
          path: BaiduProxyEndpoints.parsePath,
          timestamp: timestamp,
          nonce: nonce,
          body: '{}',
        ),
      );
      expect(headers.containsKey('Content-Type'), isFalse);
    });
  });

  group('BaiduProxyPlayData.tryFromJson', () {
    test('缺 url / type 或非对象返回 null', () {
      expect(BaiduProxyPlayData.tryFromJson(null), isNull);
      expect(BaiduProxyPlayData.tryFromJson('x'), isNull);
      expect(BaiduProxyPlayData.tryFromJson(<String, dynamic>{}), isNull);
      expect(
        BaiduProxyPlayData.tryFromJson(<String, dynamic>{'url': ''}),
        isNull,
      );
      expect(
        BaiduProxyPlayData.tryFromJson(<String, dynamic>{
          'url': 'u',
          'type': 1,
        }),
        isNull,
      );
    });

    test('完整解析 url / type / file_name / quality / headers', () {
      final BaiduProxyPlayData? data =
          BaiduProxyPlayData.tryFromJson(<String, dynamic>{
        'url': 'https://d.pcs.baidu.com/x.mp4',
        'type': 'mp4',
        'file_name': 'x.mp4',
        'quality': '1080p',
        'headers': <String, dynamic>{'User-Agent': 'UA', 'Cookie': 1},
      });
      expect(data, isNotNull);
      expect(data!.url, 'https://d.pcs.baidu.com/x.mp4');
      expect(data.type, 'mp4');
      expect(data.fileName, 'x.mp4');
      expect(data.quality, '1080p');
      expect(data.headers, <String, String>{'User-Agent': 'UA', 'Cookie': '1'});
    });
  });

  group('BaiduProxyResponse.fromJson', () {
    test('非对象 → 解析失败响应', () {
      final BaiduProxyResponse r = BaiduProxyResponse.fromJson(<int>[1]);
      expect(r.success, isFalse);
      expect(r.error, '无效的 JSON 响应');
    });

    test('success=true 且 data 可解析', () {
      final BaiduProxyResponse r =
          BaiduProxyResponse.fromJson(<String, dynamic>{
        'success': true,
        'data': <String, dynamic>{'url': 'u', 'type': 'mp4'},
      });
      expect(r.success, isTrue);
      expect(r.data?.url, 'u');
      expect(r.error, isNull);
    });

    test('空 error 归一为 null', () {
      final BaiduProxyResponse r = BaiduProxyResponse.fromJson(
        <String, dynamic>{'success': false, 'error': ''},
      );
      expect(r.error, isNull);
    });
  });

  test('BaiduProxyException 携带 message 与 statusCode', () {
    const BaiduProxyException e =
        BaiduProxyException('boom', statusCode: 403);
    expect(e.toString(), 'boom');
    expect(e.statusCode, 403);
  });

  test('端点契约常量对齐 iOS', () {
    expect(BaiduProxyEndpoints.baseUrl, 'https://vbox.ltd');
    expect(BaiduProxyEndpoints.token, '199114');
    expect(BaiduProxyEndpoints.parsePath, '/api/baidu/parse');
    expect(BaiduProxyEndpoints.playPath, '/api/baidu/play');
  });
}
