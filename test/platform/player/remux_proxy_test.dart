/// 批次 C · C-07：转封装代理（RemuxPlan 判定 / 透传 / RemuxProxy HTTP 链路）。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vbox/platform/player/remux_proxy.dart';

/// 固定字节流转封装器（测试替身，不启动 ffmpeg）。
class FakeRemuxer implements Remuxer {
  const FakeRemuxer(this.bytes);

  final List<int> bytes;

  @override
  Stream<List<int>> remux({
    required Stream<List<int>> upstream,
    required RemuxPlan plan,
  }) =>
      Stream<List<int>>.value(bytes);
}

void main() {
  group('RemuxPlan', () {
    test('复杂封装（MKV/FLV/TS/M2TS/RMVB/AVI/WMV/WEBM）→ fmp4', () {
      for (final String ext in <String>[
        '.mkv', '.flv', '.ts', '.m2ts', '.rmvb', '.avi', '.wmv', '.webm',
      ]) {
        expect(
          RemuxPlan.decide('http://x/video$ext').format,
          RemuxFormat.fmp4,
          reason: ext,
        );
      }
    });

    test('兼容封装（MP4/M4V/HLS）→ passthrough', () {
      expect(RemuxPlan.decide('http://x/a.mp4').format, RemuxFormat.passthrough);
      expect(RemuxPlan.decide('http://x/a.m4v').format, RemuxFormat.passthrough);
      expect(
        RemuxPlan.decide('http://x/a.m3u8').format,
        RemuxFormat.passthrough,
      );
      expect(RemuxPlan.decide('http://x/plain').format, RemuxFormat.passthrough);
    });

    test('overrideFormat 优先于 URL 判定', () {
      expect(
        RemuxPlan.decide('http://x/a.mp4', overrideFormat: RemuxFormat.fmp4)
            .format,
        RemuxFormat.fmp4,
      );
      expect(
        RemuxPlan.decide('http://x/a.mkv', overrideFormat: RemuxFormat.passthrough)
            .format,
        RemuxFormat.passthrough,
      );
    });

    test('needsRemux 仅 fmp4 为 true', () {
      expect(RemuxPlan.decide('http://x/a.mkv').needsRemux, isTrue);
      expect(RemuxPlan.decide('http://x/a.mp4').needsRemux, isFalse);
    });

    test('withFormat 复制并覆盖格式，保留 URL/headers', () {
      final RemuxPlan p = RemuxPlan.decide('http://x/a.mkv',
          headers: <String, String>{'Referer': 'http://x'});
      final RemuxPlan p2 = p.withFormat(RemuxFormat.passthrough);
      expect(p2.format, RemuxFormat.passthrough);
      expect(p2.upstreamUrl, 'http://x/a.mkv');
      expect(p2.upstreamHeaders['Referer'], 'http://x');
    });

    test('headers 缺省为空 map', () {
      expect(RemuxPlan.decide('http://x/a.mp4').upstreamHeaders, isEmpty);
    });
  });

  group('PassthroughRemuxer', () {
    test('原样转发上游流', () {
      final Stream<List<int>> upstream =
          Stream<List<int>>.fromIterable(<List<int>>[
        <int>[1, 2, 3],
      ]);
      final Stream<List<int>> out = const PassthroughRemuxer().remux(
        upstream: upstream,
        plan: RemuxPlan.decide('http://x/a.mp4'),
      );
      expect(out, same(upstream));
    });
  });

  group('RemuxException', () {
    test('toString 携带 message', () {
      expect(RemuxException('boom').toString(), 'RemuxException: boom');
      expect(
        RemuxException('boom', cause: StateError('x')).cause,
        isA<StateError>(),
      );
    });
  });

  group('RemuxProxy', () {
    test('start 幂等 / boundPort / baseUrl / stop', () async {
      final RemuxProxy proxy = RemuxProxy(
        port: 0,
        client: MockClient((http.Request _) async => http.Response('x', 200)),
      );
      expect(proxy.isRunning, isFalse);
      await proxy.start();
      expect(proxy.isRunning, isTrue);
      expect(proxy.boundPort, greaterThan(0));
      expect(proxy.baseUrl, 'http://127.0.0.1:${proxy.boundPort}');
      await proxy.start(); // 幂等，不重复绑定
      expect(proxy.isRunning, isTrue);
      await proxy.stop();
      expect(proxy.isRunning, isFalse);
      await proxy.dispose();
    });

    test('非 GET/HEAD → 405', () async {
      final RemuxProxy proxy = RemuxProxy(
        port: 0,
        client: MockClient((http.Request _) async => http.Response('x', 200)),
      );
      await proxy.start();
      final http.Response resp = await http
          .post(Uri.parse('${proxy.baseUrl}/remux?src=http://x/a.mp4'));
      expect(resp.statusCode, 405);
      await proxy.stop();
    });

    test('未知端点 → 404', () async {
      final RemuxProxy proxy = RemuxProxy(
        port: 0,
        client: MockClient((http.Request _) async => http.Response('x', 200)),
      );
      await proxy.start();
      final http.Response resp =
          await http.get(Uri.parse('${proxy.baseUrl}/other'));
      expect(resp.statusCode, 404);
      await proxy.stop();
    });

    test('缺少 src → 400', () async {
      final RemuxProxy proxy = RemuxProxy(
        port: 0,
        client: MockClient((http.Request _) async => http.Response('x', 200)),
      );
      await proxy.start();
      final http.Response resp =
          await http.get(Uri.parse('${proxy.baseUrl}/remux'));
      expect(resp.statusCode, 400);
      await proxy.stop();
    });

    test('非 http(s) src → 400', () async {
      final RemuxProxy proxy = RemuxProxy(
        port: 0,
        client: MockClient((http.Request _) async => http.Response('x', 200)),
      );
      await proxy.start();
      final http.Response resp = await http
          .get(Uri.parse('${proxy.baseUrl}/remux?src=file:///etc/passwd'));
      expect(resp.statusCode, 400);
      await proxy.stop();
    });

    test('透传路径：转发上游状态码与 body', () async {
      final RemuxProxy proxy = RemuxProxy(
        port: 0,
        client: MockClient((http.Request r) async {
          expect(r.url.path, '/a.mp4');
          return http.Response('passthrough-body', 200);
        }),
      );
      await proxy.start();
      final http.Response resp = await http
          .get(Uri.parse('${proxy.baseUrl}/remux?src=http://x/a.mp4'));
      expect(resp.statusCode, 200);
      expect(resp.body, 'passthrough-body');
      await proxy.stop();
    });

    test('转封装路径：调用注入 remuxer 输出 fMP4', () async {
      final RemuxProxy proxy = RemuxProxy(
        port: 0,
        client: MockClient((http.Request _) async => http.Response('mkv-bytes', 200)),
        remuxer: const FakeRemuxer(<int>[9, 9, 9]),
      );
      await proxy.start();
      final http.Response resp = await http
          .get(Uri.parse('${proxy.baseUrl}/remux?src=http://x/a.mkv'));
      expect(resp.statusCode, 200);
      expect(resp.headers['content-type'], 'video/mp4');
      expect(resp.bodyBytes, <int>[9, 9, 9]);
      await proxy.stop();
    });

    test('HEAD 转封装只返回头，不读 body', () async {
      final RemuxProxy proxy = RemuxProxy(
        port: 0,
        client: MockClient((http.Request _) async => http.Response('mkv', 200)),
        remuxer: const FakeRemuxer(<int>[1, 2, 3]),
      );
      await proxy.start();
      final http.Response resp = await http
          .head(Uri.parse('${proxy.baseUrl}/remux?src=http://x/a.mkv'));
      expect(resp.statusCode, 200);
      expect(resp.body, isEmpty);
      await proxy.stop();
    });

    test('上游 4xx → 502', () async {
      final RemuxProxy proxy = RemuxProxy(
        port: 0,
        client: MockClient((http.Request _) async => http.Response('nope', 404)),
      );
      await proxy.start();
      final http.Response resp = await http
          .get(Uri.parse('${proxy.baseUrl}/remux?src=http://x/a.mp4'));
      expect(resp.statusCode, 502);
      await proxy.stop();
    });

    test('fmt=passthrough 强制透传（URL 复杂封装也透传）', () async {
      final RemuxProxy proxy = RemuxProxy(
        port: 0,
        client: MockClient((http.Request _) async => http.Response('raw', 200)),
      );
      await proxy.start();
      final http.Response resp = await http.get(
          Uri.parse('${proxy.baseUrl}/remux?src=http://x/a.mkv&fmt=passthrough'));
      expect(resp.statusCode, 200);
      expect(resp.body, 'raw');
      await proxy.stop();
    });

    test('UTF-8 错误正文编码', () async {
      final RemuxProxy proxy = RemuxProxy(
        port: 0,
        client: MockClient((http.Request _) async => http.Response('x', 200)),
      );
      await proxy.start();
      final http.Response resp =
          await http.get(Uri.parse('${proxy.baseUrl}/remux?src=not-a-url'));
      expect(resp.statusCode, 400);
      expect(resp.headers['content-type'], contains('charset=utf-8'));
      expect(utf8.decode(resp.bodyBytes), 'src 必须是 http(s) 地址');
      await proxy.stop();
    });
  });

  group('RemuxProxy 流注册（P-芯3）', () {
    test('registerStream 返回唯一 id；unregisterStream / clearStreams 幂等', () {
      final RemuxProxy proxy = RemuxProxy(port: 0);
      final String id = proxy.registerStream(
        url: 'http://x/a.mkv',
        headers: <String, String>{'Cookie': 'k=v'},
      );
      expect(id, isNotEmpty);
      proxy.unregisterStream(id);
      final String id2 = proxy.registerStream(url: 'http://x/b.mkv');
      expect(id2, isNot(id));
      proxy.clearStreams();
    });

    test('GET /remux?id= 转发注册的上游鉴权头', () async {
      final RemuxProxy proxy = RemuxProxy(
        port: 0,
        client: MockClient((http.Request r) async {
          expect(r.headers['Cookie'], 'k=v');
          return http.Response('ok', 200);
        }),
      );
      await proxy.start();
      final String id = proxy.registerStream(
        url: 'http://x/a.mp4',
        headers: <String, String>{'Cookie': 'k=v'},
      );
      final http.Response resp =
          await http.get(Uri.parse('${proxy.baseUrl}/remux?id=$id'));
      expect(resp.statusCode, 200);
      expect(resp.body, 'ok');
      await proxy.stop();
    });

    test('未知 id → 404', () async {
      final RemuxProxy proxy = RemuxProxy(
        port: 0,
        client: MockClient((http.Request _) async => http.Response('x', 200)),
      );
      await proxy.start();
      final http.Response resp =
          await http.get(Uri.parse('${proxy.baseUrl}/remux?id=nope'));
      expect(resp.statusCode, 404);
      await proxy.stop();
    });
  });
}