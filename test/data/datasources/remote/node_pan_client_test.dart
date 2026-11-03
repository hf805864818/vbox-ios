/// Node 网盘解析客户端单测（批次 F · F-08）。
///
/// 对齐基准（唯一真相源）：iOS `vbox/Services/NodePanResolver.swift`
/// （`resolveShare` / `resolvePlay` / `postJSON` / `extractErrorMessage`）。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/data/datasources/remote/node_pan_client.dart';
import 'package:vbox/domain/entities/cloud/node_pan.dart';

String _idWithName(String name) =>
    base64.encode(utf8.encode(jsonEncode(<String, String>{'name': name})));

/// 可编程传输替身：记录路径 / body，返回脚本化响应。
class _FakeTransport implements NodePanTransport {
  _FakeTransport(this.handler);

  final Future<NodePanHttpResponse> Function(
    String path,
    Map<String, dynamic> body,
  ) handler;

  final List<String> paths = <String>[];
  final List<Map<String, dynamic>> bodies = <Map<String, dynamic>>[];

  @override
  Future<NodePanHttpResponse> postJson(
    String path,
    Map<String, dynamic> body,
  ) {
    paths.add(path);
    bodies.add(body);
    return handler(path, body);
  }
}

NodePanHttpResponse _ok(Map<String, dynamic> json) => NodePanHttpResponse(
      statusCode: 200,
      json: json,
      rawBody: jsonEncode(json),
    );

void main() {
  test('resolveShare 解析条目并清洗分享链接（去零宽字符）', () async {
    final String id = _idWithName('第01集.mp4');
    final _FakeTransport t = _FakeTransport((_, Map<String, dynamic> body) async {
      expect(body['id'], <String>['https://pan.quark.cn/s/abc']);
      return _ok(<String, dynamic>{
        'list': <Map<String, dynamic>>[
          <String, dynamic>{
            'vod_name': '示例剧',
            'vod_play_url': '第01集\$$id',
          },
        ],
      });
    });
    final NodePanClient client = NodePanClient(transport: t);
    final NodePanShare share =
        await client.resolveShare('  https://pan.quark.cn/s/abc\u200B ');
    expect(t.paths.single, NodePanPaths.detail);
    expect(share.title, '示例剧');
    expect(share.entries.single.name, '第01集.mp4');
    expect(share.entries.single.playID, id);
  });

  test('resolveShare 空链接直接 invalidShareURL（不触网络）', () async {
    final _FakeTransport t =
        _FakeTransport((_, __) async => _ok(<String, dynamic>{}));
    final NodePanClient client = NodePanClient(transport: t);
    await expectLater(
      client.resolveShare('   '),
      throwsA(
        isA<NodePanException>().having(
          (NodePanException e) => e.kind,
          'kind',
          NodePanErrorKind.invalidShareURL,
        ),
      ),
    );
    expect(t.paths, isEmpty);
  });

  test('resolveShare list 空且带 msg → nodeRejected(msg)', () async {
    final _FakeTransport t = _FakeTransport(
      (_, __) async => _ok(<String, dynamic>{
        'list': <dynamic>[],
        'msg': '还没有配置 UC Cookie',
      }),
    );
    final NodePanClient client = NodePanClient(transport: t);
    await expectLater(
      client.resolveShare('https://pan.uc.cn/s/x'),
      throwsA(
        isA<NodePanException>().having(
          (NodePanException e) => e.displayMessage,
          'msg',
          '还没有配置 UC Cookie',
        ),
      ),
    );
  });

  test('resolveShare 无 list → 「未解析到可播放网盘资源」', () async {
    final _FakeTransport t =
        _FakeTransport((_, __) async => _ok(<String, dynamic>{}));
    final NodePanClient client = NodePanClient(transport: t);
    await expectLater(
      client.resolveShare('https://pan.uc.cn/s/x'),
      throwsA(
        isA<NodePanException>().having(
          (NodePanException e) => e.displayMessage,
          'msg',
          '未解析到可播放网盘资源',
        ),
      ),
    );
  });

  test('resolveShare 条目为空 → 「分享内未找到可播放视频」', () async {
    final _FakeTransport t = _FakeTransport(
      (_, __) async => _ok(<String, dynamic>{
        'list': <Map<String, dynamic>>[
          <String, dynamic>{'vod_name': '示例剧', 'vod_play_url': ''},
        ],
      }),
    );
    final NodePanClient client = NodePanClient(transport: t);
    await expectLater(
      client.resolveShare('https://pan.uc.cn/s/x'),
      throwsA(
        isA<NodePanException>().having(
          (NodePanException e) => e.displayMessage,
          'msg',
          '分享内未找到可播放视频',
        ),
      ),
    );
  });

  test('resolvePlay 返回直链 / headers / format', () async {
    final _FakeTransport t = _FakeTransport((_, Map<String, dynamic> body) async {
      expect(body['id'], 'PID');
      return _ok(<String, dynamic>{
        'url': 'https://cdn/video.m3u8',
        'header': <String, dynamic>{'Referer': 'https://pan.uc.cn', 'N': 1},
        'format': 'm3u8',
      });
    });
    final NodePanClient client = NodePanClient(transport: t);
    final NodePanPlayData data = await client.resolvePlay('PID');
    expect(t.paths.single, NodePanPaths.play);
    expect(data.url, 'https://cdn/video.m3u8');
    expect(data.headers['Referer'], 'https://pan.uc.cn');
    expect(data.headers['N'], '1');
    expect(data.format, 'm3u8');
  });

  test('resolvePlay 相对路径补全 base（缺省 127.0.0.1:58080）', () async {
    final _FakeTransport t = _FakeTransport(
      (_, __) async => _ok(<String, dynamic>{
        'url': '/spider/push/4/proxy/abc',
      }),
    );
    final NodePanClient client = NodePanClient(transport: t);
    final NodePanPlayData data = await client.resolvePlay('PID');
    expect(data.url, 'http://127.0.0.1:58080/spider/push/4/proxy/abc');
    expect(data.format, isNull);
  });

  test('resolvePlay 空 url 带 msg → nodeRejected(msg)', () async {
    final _FakeTransport t = _FakeTransport(
      (_, __) async => _ok(<String, dynamic>{'msg': '链接已失效'}),
    );
    final NodePanClient client = NodePanClient(transport: t);
    await expectLater(
      client.resolvePlay('PID'),
      throwsA(
        isA<NodePanException>().having(
          (NodePanException e) => e.displayMessage,
          'msg',
          '链接已失效',
        ),
      ),
    );
  });

  test('resolvePlay 空 url 无 msg → 「播放地址为空」', () async {
    final _FakeTransport t =
        _FakeTransport((_, __) async => _ok(<String, dynamic>{}));
    final NodePanClient client = NodePanClient(transport: t);
    await expectLater(
      client.resolvePlay('PID'),
      throwsA(
        isA<NodePanException>().having(
          (NodePanException e) => e.displayMessage,
          'msg',
          '播放地址为空',
        ),
      ),
    );
  });

  test('resolvePlay 空 playID → 「播放参数无效」', () async {
    final _FakeTransport t =
        _FakeTransport((_, __) async => _ok(<String, dynamic>{}));
    final NodePanClient client = NodePanClient(transport: t);
    await expectLater(
      client.resolvePlay(''),
      throwsA(
        isA<NodePanException>().having(
          (NodePanException e) => e.displayMessage,
          'msg',
          '播放参数无效',
        ),
      ),
    );
    expect(t.paths, isEmpty);
  });

  test('HTTP 502 / 503 / 404 → Node 未就绪', () async {
    for (final int code in <int>[502, 503, 404]) {
      final _FakeTransport t = _FakeTransport(
        (_, __) async => NodePanHttpResponse(statusCode: code, rawBody: 'x'),
      );
      final NodePanClient client = NodePanClient(transport: t);
      await expectLater(
        client.resolvePlay('PID'),
        throwsA(
          isA<NodePanException>().having(
            (NodePanException e) => e.kind,
            'kind',
            NodePanErrorKind.nodeUnavailable,
          ),
        ),
        reason: 'HTTP $code',
      );
    }
  });

  test('HTTP 500 提取 message 后包 HTTP 码', () async {
    final _FakeTransport t = _FakeTransport(
      (_, __) async => const NodePanHttpResponse(
        statusCode: 500,
        json: <String, dynamic>{
          'statusCode': 500,
          'error': 'Internal Server Error',
          'message': '还没有配置 UC Cookie',
        },
        rawBody: '{"message":"还没有配置 UC Cookie"}',
      ),
    );
    final NodePanClient client = NodePanClient(transport: t);
    await expectLater(
      client.resolvePlay('PID'),
      throwsA(
        isA<NodePanException>().having(
          (NodePanException e) => e.displayMessage,
          'msg',
          '还没有配置 UC Cookie（HTTP 500）',
        ),
      ),
    );
  });

  test('缺省未接入传输 → Node 未就绪', () async {
    final NodePanClient client =
        NodePanClient(transport: const UnavailableNodePanTransport());
    await expectLater(
      client.resolveShare('https://pan.uc.cn/s/x'),
      throwsA(
        isA<NodePanException>().having(
          (NodePanException e) => e.kind,
          'kind',
          NodePanErrorKind.nodeUnavailable,
        ),
      ),
    );
  });
}
