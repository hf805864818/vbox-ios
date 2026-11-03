/// 平台层单测：Node / NodeLX 桥接引擎（注入 fake HTTP 客户端）。
///
/// 协议对齐 iOS `NodeSpiderEngine`：`POST /spider/{nodeKey}/3/{action}` +
/// 原生 JSON body；key 归一化（bundleKeyMap）；play 404 回退 player。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/spider/engine_type.dart';
import 'package:vbox/domain/entities/spider/spider_engine.dart';
import 'package:vbox/domain/entities/spider/spider_models.dart';
import 'package:vbox/platform/spider/node_bridge_engine.dart';
import 'package:vbox/platform/spider/node_http_client.dart';

/// 记录请求并返回预设响应的 fake 客户端。
class _FakeNodeClient implements NodeHttpClient {
  _FakeNodeClient(this._responses);

  final List<NodeHttpResponse> _responses;

  /// 捕获的请求（path, body JSON）。
  final List<(String, Map<String, Object?>)> requests =
      <(String, Map<String, Object?>)>[];

  /// 捕获的请求路径。
  List<String> get paths => requests.map(((String, Map<String, Object?>) r) => r.$1).toList();

  /// 请求次数。
  int callCount = 0;

  /// 强制抛出的异常。
  Object? throwOnPost;

  @override
  Future<NodeHttpResponse> post(String path, String body) async {
    if (throwOnPost != null) throw throwOnPost!;
    callCount++;
    requests.add((path, jsonDecode(body).cast<String, Object?>()));
    return _responses[callCount - 1];
  }

  @override
  Future<void> close() async {}
}

NodeHttpResponse _ok(Map<String, Object?> data) => NodeHttpResponse(
      statusCode: 200,
      body: jsonEncode(data),
    );

/// 返回指定状态码的响应。
NodeHttpResponse _status(int code, [String body = '']) =>
    NodeHttpResponse(statusCode: code, body: body);

void main() {
  group('normalizeNodeKey（对齐 iOS 归一化规则）', () {
    test('nodejs_ 前缀 + 显式映射表', () {
      expect(NodeBridgeEngine.normalizeNodeKey('nodejs_SoKaKa'), 'sokaka');
      expect(
          NodeBridgeEngine.normalizeNodeKey('nodejs_SoAiQuPanShe'),
          'soaiqupanshe');
      expect(
          NodeBridgeEngine.normalizeNodeKey('nodejs_WexAiDuBoKu'),
          'wexDuBoKu');
    });

    test('nodejs_ 前缀 + 小写兜底', () {
      expect(
          NodeBridgeEngine.normalizeNodeKey('nodejs_hanxiaoquan'),
          'hanxiaoquan');
      expect(
          NodeBridgeEngine.normalizeNodeKey('nodejs_woniu4k'),
          'woniu4k');
    });

    test('csp_ 前缀 + 小写兜底', () {
      expect(NodeBridgeEngine.normalizeNodeKey('csp_MyPan'), 'mypan');
      expect(NodeBridgeEngine.normalizeNodeKey('csp_AiNewMuOu'), 'muou');
    });

    test('中文 key 原样（走映射表）', () {
      expect(NodeBridgeEngine.normalizeNodeKey('nodejs_少儿教育'), '少儿教育');
      expect(NodeBridgeEngine.normalizeNodeKey('nodejs_玩偶'), 'wogg');
    });

    test('无前缀原样', () {
      expect(NodeBridgeEngine.normalizeNodeKey('biliys'), 'biliys');
    });
  });

  group('NodeBridgeEngine（node）', () {
    test('homeContent：/spider/{key}/3/home + 空 body + 解析 classes', () async {
      final _FakeNodeClient client = _FakeNodeClient(<NodeHttpResponse>[
        _ok(<String, Object?>{
          'class': <Map<String, Object?>>[
            <String, Object?>{'type_id': '1', 'type_name': '电影'},
          ],
          'list': <Map<String, Object?>>[
            <String, Object?>{
              'vod_id': '1001',
              'vod_name': '测试影片',
              'vod_pic': 'https://cdn.example.com/1001.jpg',
            },
          ],
        }),
      ]);
      final NodeBridgeEngine engine = NodeBridgeEngine(
        engineType: SpiderEngineType.node,
        client: client,
        siteKey: 'nodejs_hanxiaoquan',
      );
      await engine.registerSpider();
      expect(engine.isSpiderReady, isTrue);

      final HomeContentResult r = await engine.callHomeContent();

      expect(client.paths.single, '/spider/hanxiaoquan/3/home');
      expect(client.requests.single.$2, isEmpty);
      expect(r.classes, hasLength(1));
      expect(r.classes!.first.typeName, '电影');
      expect(r.list, hasLength(1));
      await engine.dispose();
    });

    test('searchContent：body {wd, pg} + 直解响应（无 ABI 包裹）', () async {
      final _FakeNodeClient client = _FakeNodeClient(<NodeHttpResponse>[
        _ok(<String, Object?>{
          'page': 1,
          'pagecount': 5,
          'list': <Map<String, Object?>>[
            <String, Object?>{
              'vod_id': '2001',
              'vod_name': '测试影片',
              'vod_pic': 'https://cdn.example.com/2001.jpg',
            },
          ],
        }),
      ]);
      final NodeBridgeEngine engine = NodeBridgeEngine(
        engineType: SpiderEngineType.node,
        client: client,
        siteKey: 'nodejs_SoKaKa',
      );
      await engine.registerSpider();

      final SearchContentResult r = await engine.callSearchContent('测试', 1);

      expect(client.paths.single, '/spider/sokaka/3/search');
      expect(client.requests.single.$2, <String, Object?>{'wd': '测试', 'pg': 1});
      expect(r.page, 1);
      expect(r.list, hasLength(1));
      expect(r.list!.first.vodName, '测试影片');
      await engine.dispose();
    });

    test('categoryContent：body {tid, pg, extend}', () async {
      final _FakeNodeClient client = _FakeNodeClient(<NodeHttpResponse>[
        _ok(<String, Object?>{
          'page': 1,
          'pagecount': 3,
          'list': <Map<String, Object?>>[],
        }),
      ]);
      final NodeBridgeEngine engine = NodeBridgeEngine(
        engineType: SpiderEngineType.node,
        client: client,
        siteKey: 'csp_MyPan',
      );
      await engine.registerSpider();

      await engine.callCategoryContent('2', 1, '{}');

      expect(client.paths.single, '/spider/mypan/3/category');
      expect(client.requests.single.$2,
          <String, Object?>{'tid': '2', 'pg': 1, 'extend': '{}'});
      await engine.dispose();
    });

    test('detailContent：body 统一读 id（同时携带 ids 兼容）', () async {
      final _FakeNodeClient client = _FakeNodeClient(<NodeHttpResponse>[
        _ok(<String, Object?>{
          'list': <Map<String, Object?>>[
            <String, Object?>{'vod_id': '1001', 'vod_name': '详情'},
          ],
        }),
      ]);
      final NodeBridgeEngine engine = NodeBridgeEngine(
        engineType: SpiderEngineType.node,
        client: client,
        siteKey: 'nodejs_woniu4k',
      );
      await engine.registerSpider();

      final DetailContentResult r = await engine.callDetailContent('1001');

      expect(client.paths.single, '/spider/woniu4k/3/detail');
      expect(client.requests.single.$2,
          <String, Object?>{'id': '1001', 'ids': '1001'});
      expect(r.list, hasLength(1));
      await engine.dispose();
    });

    test('playerContent：body.id=播放地址 + play 成功后缓存偏好', () async {
      final _FakeNodeClient client = _FakeNodeClient(<NodeHttpResponse>[
        _ok(<String, Object?>{
          'parse': 0,
          'url': 'https://cdn.example.com/ep1.m3u8',
        }),
        _ok(<String, Object?>{
          'parse': 0,
          'url': 'https://cdn.example.com/ep2.m3u8',
        }),
      ]);
      final NodeBridgeEngine engine = NodeBridgeEngine(
        engineType: SpiderEngineType.node,
        client: client,
        siteKey: 'nodejs_hanxiaoquan',
      );
      await engine.registerSpider();

      final PlayerContentResult r1 = await engine.callPlayerContent(
        '1001',
        '线路1',
        '/play/96518-3-1.html',
      );
      expect(client.paths[0], '/spider/hanxiaoquan/3/play');
      expect(client.requests[0].$2['id'], '/play/96518-3-1.html');
      expect(r1.urls, hasLength(1));

      // 第二次直接复用 play（无 404 探测往返）。
      await engine.callPlayerContent('1001', '线路1', '/play/96518-3-2.html');
      expect(client.paths[1], '/spider/hanxiaoquan/3/play');
      expect(client.callCount, 2);
      await engine.dispose();
    });

    test('play 404 → 回退旧协议 player + 偏好缓存', () async {
      final _FakeNodeClient client = _FakeNodeClient(<NodeHttpResponse>[
        _status(404),
        _ok(<String, Object?>{
          'parse': 0,
          'url': 'https://cdn.example.com/ep1.m3u8',
        }),
        _ok(<String, Object?>{
          'parse': 0,
          'url': 'https://cdn.example.com/ep2.m3u8',
        }),
      ]);
      final NodeBridgeEngine engine = NodeBridgeEngine(
        engineType: SpiderEngineType.node,
        client: client,
        siteKey: 'nodejs_hanxiaoquan',
      );
      await engine.registerSpider();

      final PlayerContentResult r = await engine.callPlayerContent(
        '1001',
        '线路1',
        '/play/1-1-1.html',
      );
      expect(client.paths[0], '/spider/hanxiaoquan/3/play');
      expect(client.paths[1], '/spider/hanxiaoquan/3/player');
      expect(r.url, 'https://cdn.example.com/ep1.m3u8');

      // 后续直接走 player（不再先试 play）。
      await engine.callPlayerContent('1001', '线路1', '/play/1-1-2.html');
      expect(client.paths[2], '/spider/hanxiaoquan/3/player');
      expect(client.callCount, 3);
      await engine.dispose();
    });

    test('非 2xx 响应 → SpiderException(runtime)（含 HTTP 状态码）', () async {
      final _FakeNodeClient client = _FakeNodeClient(<NodeHttpResponse>[
        _status(500, 'boom'),
      ]);
      final NodeBridgeEngine engine = NodeBridgeEngine(
        engineType: SpiderEngineType.node,
        client: client,
        siteKey: 'nodejs_hanxiaoquan',
      );
      await engine.registerSpider();

      await expectLater(
        engine.callHomeContent(),
        throwsA(
          isA<SpiderException>()
              .having((SpiderException e) => e.code, 'code',
                  SpiderErrorCode.runtime)
              .having((SpiderException e) => e.message, 'message',
                  contains('HTTP 500')),
        ),
      );
      await engine.dispose();
    });

    test('空响应体 → protocol', () async {
      final _FakeNodeClient client = _FakeNodeClient(<NodeHttpResponse>[
        _status(200, ''),
      ]);
      final NodeBridgeEngine engine = NodeBridgeEngine(
        engineType: SpiderEngineType.node,
        client: client,
        siteKey: 'nodejs_hanxiaoquan',
      );
      await engine.registerSpider();

      await expectLater(
        engine.callHomeContent(),
        throwsA(
          isA<SpiderException>().having(
            (SpiderException e) => e.code,
            'code',
            SpiderErrorCode.protocol,
          ),
        ),
      );
      await engine.dispose();
    });

    test('非 JSON 响应 → protocol', () async {
      final _FakeNodeClient client = _FakeNodeClient(<NodeHttpResponse>[
        const NodeHttpResponse(statusCode: 200, body: 'oops'),
      ]);
      final NodeBridgeEngine engine = NodeBridgeEngine(
        engineType: SpiderEngineType.node,
        client: client,
        siteKey: 'nodejs_hanxiaoquan',
      );
      await engine.registerSpider();

      await expectLater(
        engine.callHomeContent(),
        throwsA(
          isA<SpiderException>().having(
            (SpiderException e) => e.code,
            'code',
            SpiderErrorCode.protocol,
          ),
        ),
      );
      await engine.dispose();
    });

    test('传输超时 → timeout', () async {
      final _FakeNodeClient client = _FakeNodeClient(<NodeHttpResponse>[])
        ..throwOnPost = TimeoutException('slow');
      final NodeBridgeEngine engine = NodeBridgeEngine(
        engineType: SpiderEngineType.node,
        client: client,
        siteKey: 'nodejs_hanxiaoquan',
      );
      await engine.registerSpider();

      await expectLater(
        engine.callHomeContent(),
        throwsA(
          isA<SpiderException>().having(
            (SpiderException e) => e.code,
            'code',
            SpiderErrorCode.timeout,
          ),
        ),
      );
      await engine.dispose();
    });

    test('siteKey 缺失 → runtime', () async {
      final _FakeNodeClient client = _FakeNodeClient(<NodeHttpResponse>[]);
      final NodeBridgeEngine engine = NodeBridgeEngine(
        engineType: SpiderEngineType.node,
        client: client,
      );
      await engine.registerSpider();

      await expectLater(
        engine.callHomeContent(),
        throwsA(
          isA<SpiderException>().having(
            (SpiderException e) => e.code,
            'code',
            SpiderErrorCode.runtime,
          ),
        ),
      );
      await engine.dispose();
    });
  });

  group('NodeBridgeEngine（nodeLX，对齐 iOS LXBridgeEngine 空返回语义）', () {
    test('五协议空返回，不发起 HTTP 请求', () async {
      final _FakeNodeClient client = _FakeNodeClient(<NodeHttpResponse>[]);
      final NodeBridgeEngine engine = NodeBridgeEngine(
        engineType: SpiderEngineType.nodeLX,
        client: client,
        siteKey: 'nodejs_musicaidaxe',
      );
      await engine.registerSpider();
      expect(engine.isSpiderReady, isTrue);

      final HomeContentResult home = await engine.callHomeContent();
      final CategoryContentResult cat =
          await engine.callCategoryContent('1', 1, '{}');
      final SearchContentResult search =
          await engine.callSearchContent('周杰伦', 1);
      final DetailContentResult detail = await engine.callDetailContent('1');
      final PlayerContentResult player =
          await engine.callPlayerContent('1', '', '');

      expect(home.classes, isNull);
      expect(home.list, isNull);
      expect(cat.page, 1);
      expect(search.page, 1);
      expect(search.list, isNull);
      expect(detail.list, isNull);
      expect(player.parse, 0);
      expect(client.callCount, 0);
      await engine.dispose();
    });
  });

  test('引擎类型断言：仅支持 node / nodeLX', () {
    expect(
      () => NodeBridgeEngine(
        engineType: SpiderEngineType.quickJS,
        client: _FakeNodeClient(const <NodeHttpResponse>[]),
      ),
      throwsAssertionError,
    );
  });
}
