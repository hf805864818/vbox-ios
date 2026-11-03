/// Emby 配置客户端单测（批次 C，对齐 iOS `EmbyConfigService` 五接口）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/data/datasources/remote/emby_config_client.dart';

/// 录制型 fake 传输：记录请求并回放预设响应。
class _RecordingTransport implements EmbyTransport {
  _RecordingTransport(this.responses);

  final List<EmbyHttpResponse> responses;
  final List<({String method, String path, Map<String, dynamic>? body})>
      calls = <({String method, String path, Map<String, dynamic>? body})>[];

  @override
  Future<EmbyHttpResponse> request(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    calls.add((method: method, path: path, body: body));
    return responses.removeAt(0);
  }
}

void main() {
  test('fetchServers 解析 data.data 列表（servername 缺失跳过）', () async {
    final _RecordingTransport transport = _RecordingTransport(<EmbyHttpResponse>[
      const EmbyHttpResponse(
        statusCode: 200,
        json: <String, dynamic>{
          'code': 0,
          'data': <String, dynamic>{
            'data': <dynamic>[
              <String, dynamic>{
                'servername': '家里 NAS',
                'serverurl': 'http://192.168.1.10:8096',
                'username': 'admin',
                'password': 'p1',
                'choose': 1,
              },
              <String, dynamic>{'serverurl': 'http://x'}, // 无 servername → 跳过
            ],
          },
        },
      ),
    ]);
    final EmbyConfigClient client = EmbyConfigClient(transport: transport);

    final List<EmbyServerItem> servers = await client.fetchServers();

    expect(servers, hasLength(1));
    expect(servers.single.servername, '家里 NAS');
    expect(servers.single.serverurl, 'http://192.168.1.10:8096');
    expect(servers.single.username, 'admin');
    expect(servers.single.password, 'p1');
    expect(servers.single.choose, 1);
    expect(transport.calls.single.method, 'GET');
    expect(transport.calls.single.path, '/website/api/emby/config');
    expect(transport.calls.single.body, isNull);
  });

  test('fetchServers 空列表 / data 缺失 → 空数组', () async {
    final _RecordingTransport transport = _RecordingTransport(<EmbyHttpResponse>[
      const EmbyHttpResponse(statusCode: 200, json: <String, dynamic>{'code': 0}),
    ]);
    final EmbyConfigClient client = EmbyConfigClient(transport: transport);

    expect(await client.fetchServers(), isEmpty);
  });

  test('saveServers PUT {data:[...]}，字段名与 Node 一致', () async {
    final _RecordingTransport transport = _RecordingTransport(<EmbyHttpResponse>[
      const EmbyHttpResponse(statusCode: 200, json: <String, dynamic>{'code': 0}),
    ]);
    final EmbyConfigClient client = EmbyConfigClient(transport: transport);

    await client.saveServers(const <EmbyServerItem>[
      EmbyServerItem(
        servername: 'a',
        serverurl: 'http://a:8096',
        username: 'u',
        password: 'p',
        choose: 1,
      ),
    ]);

    expect(transport.calls.single.method, 'PUT');
    expect(transport.calls.single.path, '/website/api/emby/config');
    expect(transport.calls.single.body, <String, dynamic>{
      'data': <Map<String, dynamic>>[
        <String, dynamic>{
          'servername': 'a',
          'serverurl': 'http://a:8096',
          'username': 'u',
          'password': 'p',
          'choose': 1,
        },
      ],
    });
  });

  test('setDefault / test / delete 的方法与路径', () async {
    final _RecordingTransport transport = _RecordingTransport(<EmbyHttpResponse>[
      const EmbyHttpResponse(statusCode: 200, json: <String, dynamic>{'code': 0}),
      const EmbyHttpResponse(statusCode: 200, json: <String, dynamic>{'code': 0}),
      const EmbyHttpResponse(statusCode: 200, json: <String, dynamic>{'code': 0}),
    ]);
    final EmbyConfigClient client = EmbyConfigClient(transport: transport);

    await client.setDefault(2);
    await client.test(1);
    await client.delete(0);

    expect(transport.calls[0].method, 'PUT');
    expect(transport.calls[0].path, '/website/api/emby/choose');
    expect(transport.calls[0].body, <String, dynamic>{'index': 2});
    expect(transport.calls[1].method, 'POST');
    expect(transport.calls[1].path, '/website/api/emby/test');
    expect(transport.calls[1].body, <String, dynamic>{'index': 1});
    expect(transport.calls[2].method, 'DELETE');
    expect(transport.calls[2].path, '/website/api/emby/0');
    expect(transport.calls[2].body, isNull);
  });

  test('非 2xx → 透出 Fastify message / msg', () async {
    final _RecordingTransport message = _RecordingTransport(<EmbyHttpResponse>[
      const EmbyHttpResponse(
        statusCode: 400,
        json: <String, dynamic>{'statusCode': 400, 'message': '服务器不存在'},
      ),
    ]);
    final _RecordingTransport msg = _RecordingTransport(<EmbyHttpResponse>[
      const EmbyHttpResponse(
        statusCode: 500,
        json: <String, dynamic>{'msg': '内部错误'},
      ),
    ]);

    await expectLater(
      EmbyConfigClient(transport: message).fetchServers(),
      throwsA(isA<EmbyConfigException>()
          .having((EmbyConfigException e) => e.message, 'message', '服务器不存在')),
    );
    await expectLater(
      EmbyConfigClient(transport: msg).test(0),
      throwsA(isA<EmbyConfigException>()
          .having((EmbyConfigException e) => e.message, 'message', '内部错误')),
    );
  });

  test('2xx 且 code != 0 → 抛 msg；code 缺省文案', () async {
    final _RecordingTransport withMsg = _RecordingTransport(<EmbyHttpResponse>[
      const EmbyHttpResponse(
        statusCode: 200,
        json: <String, dynamic>{'code': 1, 'msg': '登录失败'},
      ),
    ]);
    final _RecordingTransport noMsg = _RecordingTransport(<EmbyHttpResponse>[
      const EmbyHttpResponse(
        statusCode: 200,
        json: <String, dynamic>{'code': 2},
      ),
    ]);

    await expectLater(
      EmbyConfigClient(transport: withMsg).test(0),
      throwsA(isA<EmbyConfigException>()
          .having((EmbyConfigException e) => e.message, 'message', '登录失败')),
    );
    await expectLater(
      EmbyConfigClient(transport: noMsg).test(0),
      throwsA(isA<EmbyConfigException>()
          .having((EmbyConfigException e) => e.message, 'message', '操作失败（code=2）')),
    );
  });
}
