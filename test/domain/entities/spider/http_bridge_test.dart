/// 单元测试：Spider HTTP 请求/响应模型。
///
/// 对应源码：lib/domain/entities/spider/http_bridge.dart
/// 契约：contract/docs/abi_v1.md §4.1 / §4.3 / §6
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/spider/http_bridge.dart';

void main() {
  group('SpiderHttpRequest', () {
    test('默认超时为契约 §6 规定的 15 秒', () {
      expect(SpiderHttpRequest.defaultTimeout, 15.0);
    });

    test('仅 url 必填，其余字段取契约默认（GET / 空 headers / 15s / 不绕过 SSL）',
        () {
      const SpiderHttpRequest req =
          SpiderHttpRequest(url: 'https://example.com/api');
      expect(req.url, 'https://example.com/api');
      expect(req.method, 'GET');
      expect(req.headers, isEmpty);
      expect(req.data, isNull);
      expect(req.timeoutSeconds, 15.0);
      expect(req.sslBypass, isFalse);
    });

    test('自定义字段全部保留（POST + body + 自定义超时 + SSL 绕过）', () {
      const SpiderHttpRequest req = SpiderHttpRequest(
        url: 'https://example.com/play',
        method: 'POST',
        headers: <String, String>{'Referer': 'https://example.com/'},
        data: 'wd=test',
        timeoutSeconds: 30.0,
        sslBypass: true,
      );
      expect(req.method, 'POST');
      expect(req.headers['Referer'], 'https://example.com/');
      expect(req.data, 'wd=test');
      expect(req.timeoutSeconds, 30.0);
      expect(req.sslBypass, isTrue);
    });
  });

  group('SpiderHttpResponse', () {
    test('必填字段 status/headers/body 与可选 rawBytes（缺省 null）', () {
      const SpiderHttpResponse res = SpiderHttpResponse(
        status: 200,
        headers: <String, String>{
          'Content-Type': 'text/html; charset=gbk',
        },
        body: '<html></html>',
      );
      expect(res.status, 200);
      expect(res.headers['Content-Type'], 'text/html; charset=gbk');
      expect(res.body, '<html></html>');
      expect(res.rawBytes, isNull);
    });

    test('rawBytes 可携带原始字节（供 getBytes 类调用）', () {
      final Uint8List bytes = Uint8List.fromList(<int>[0x41, 0x42, 0x43]);
      final SpiderHttpResponse res = SpiderHttpResponse(
        status: 500,
        headers: const <String, String>{},
        body: 'error',
        rawBytes: bytes,
      );
      expect(res.status, 500);
      expect(res.rawBytes, bytes);
      expect(res.rawBytes, orderedEquals(<int>[0x41, 0x42, 0x43]));
    });
  });
}