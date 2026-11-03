/// 平台层单测：Spider HTTP 桥（第 2 轮批次 B · B-09）。
///
/// 注入 fake [SpiderHttpTransport]，离线验证（B-09 验收口径）：
/// - 编码链：GBK / Big5 正向（真实码表经 [SpiderCharsetTables] 注入）+
///   **GBK/Big5 负向**（严格解码失败 → 契约链逐级回退，不吞字节、不乱码扩散）
/// - cookie：Set-Cookie 收集 + 同域回带 + 域隔离
/// - 超时 / 网络失败：`ok=false, status=0` 固定形状（对齐 iOS 超时分支）
/// - 请求组装：iOS 默认 UA + 自定义头覆盖 + referer + method 归一
/// - 结果形状：`ok/status/content/url/headers` 对齐 iOS `syncRequest` 字典
library;

import 'dart:async';
import 'dart:convert' show utf8;
import 'dart:io';
import 'dart:typed_data';

import 'package:enough_convert/enough_convert.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/core/utils/charset.dart' show decodeBytesWith;
import 'package:vbox/platform/spider/spider_http_bridge.dart';

/// 记录请求并按预设响应的 fake 传输层。
class _FakeTransport implements SpiderHttpTransport {
  _FakeTransport(this._responder);

  final SpiderTransportResponse Function(SpiderTransportRequest request)
      _responder;

  /// 全部收到的请求（断言组装 / 回带 / 未被调用）。
  final List<SpiderTransportRequest> requests = <SpiderTransportRequest>[];

  @override
  Future<SpiderTransportResponse> send(SpiderTransportRequest request) async {
    requests.add(request);
    return _responder(request);
  }
}

/// 恒抛指定异常的 fake 传输层（超时 / 网络失败分支）。
class _ThrowingTransport implements SpiderHttpTransport {
  _ThrowingTransport(this.error);

  final Object error;

  @override
  Future<SpiderTransportResponse> send(SpiderTransportRequest request) async =>
      throw error;
}

/// 200 + UTF-8 正文的标准响应。
SpiderTransportResponse _utf8Response(String text) =>
    SpiderTransportResponse(
      status: 200,
      headers: const <String, String>{
        'content-type': 'text/html; charset=utf-8',
      },
      bodyBytes: utf8.encode(text),
    );

void main() {
  group('SpiderCharsetTables（G-03 码表注入）', () {
    test('ensureInstalled 幂等；注入后 GBK / Big5 真实可解码', () {
      expect(SpiderCharsetTables.isInstalled, isFalse);
      SpiderCharsetTables.ensureInstalled();
      expect(SpiderCharsetTables.isInstalled, isTrue);
      SpiderCharsetTables.ensureInstalled(); // 二次调用幂等
      expect(SpiderCharsetTables.isInstalled, isTrue);

      // GBK 正向（codec 编码 → 注入码表解码，往返一致）
      final List<int> gbk = const GbkCodec(allowInvalid: false).encode('中文测试');
      expect(decodeBytesWith(Uint8List.fromList(gbk), 'gbk'), '中文测试');
      // Big5 正向
      final List<int> big5 = const Big5Codec(allowInvalid: false).encode('中文測試');
      expect(decodeBytesWith(Uint8List.fromList(big5), 'big5'), '中文測試');
      // GBK 负向：码表外的字节对 → null（严格语义，链式回退的前提）
      expect(decodeBytesWith(Uint8List.fromList(<int>[0xFF, 0xFE]), 'gbk'), isNull);
      expect(decodeBytesWith(Uint8List.fromList(<int>[0xFF, 0xFE]), 'big5'), isNull);
    });
  });

  group('SpiderCookieStore（契约 §4.4）', () {
    test('Set-Cookie 收集：属性剥离 + 同域回带顺序', () {
      final SpiderCookieStore store = SpiderCookieStore();
      final Uri uri = Uri.parse('https://example.com/a');
      store.storeFromResponse(uri, <String>[
        'sid=abc; Path=/; HttpOnly',
        'uid=42',
      ]);
      expect(store.countFor(uri), 2);
      expect(store.cookieHeaderFor(uri), 'sid=abc; uid=42');
    });

    test('域隔离：他域不回带；空响应 no-op', () {
      final SpiderCookieStore store = SpiderCookieStore();
      final Uri a = Uri.parse('https://a.example.com/');
      final Uri b = Uri.parse('https://b.example.com/');
      store.storeFromResponse(a, const <String>['k=v']);
      store.storeFromResponse(b, const <String>[]);
      expect(store.cookieHeaderFor(a), 'k=v');
      expect(store.cookieHeaderFor(b), isNull);
      expect(store.countFor(b), 0);
    });

    test('畸形 Set-Cookie 容错（无 = / 空名）', () {
      final SpiderCookieStore store = SpiderCookieStore();
      final Uri uri = Uri.parse('https://example.com/');
      store.storeFromResponse(uri, const <String>['novalue', '=x', 'ok=1']);
      expect(store.cookieHeaderFor(uri), 'ok=1');
    });
  });

  group('SpiderHttpOptions.fromMap（JS options 字典归一）', () {
    test('全字段提取（method / headers / data / timeout / referer）', () {
      final SpiderHttpOptions opt = SpiderHttpOptions.fromMap(<String, Object?>{
        'method': 'post',
        'headers': <String, Object?>{'X-Token': 't1'},
        'data': 'wd=功夫',
        'timeout': 2.5,
        'referer': 'https://example.com/',
      });
      expect(opt.method, 'post');
      expect(opt.headers, <String, String>{'X-Token': 't1'});
      expect(opt.data, 'wd=功夫');
      expect(opt.timeout, const Duration(milliseconds: 2500));
      expect(opt.referer, 'https://example.com/');
    });

    test('null / 非法字段 → 契约默认（不抛异常）', () {
      const SpiderHttpOptions n = SpiderHttpOptions();
      expect(n.method, 'GET');
      expect(n.headers, isNull);
      expect(n.data, isNull);
      expect(n.timeout, const Duration(seconds: 15));
      expect(n.referer, isNull);

      final SpiderHttpOptions bad = SpiderHttpOptions.fromMap(<String, Object?>{
        'method': 123,
        'headers': 'no-map',
        'data': 42,
        'timeout': 'fast',
        'referer': <int>[1],
      });
      expect(bad.method, 'GET');
      expect(bad.headers, isNull);
      expect(bad.data, isNull);
      expect(bad.timeout, const Duration(seconds: 15));
      expect(bad.referer, isNull);
    });
  });

  group('SpiderHttpBridge（fake transport 离线）', () {
    test('结果形状对齐 iOS：ok / status / content / url / headers', () async {
      final SpiderHttpBridge bridge = SpiderHttpBridge(
        transport: _FakeTransport(
          (_) => _utf8Response('你好，世界'),
        ),
      );
      final SpiderHttpResult res =
          await bridge.request('https://example.com/api');
      expect(res.ok, isTrue);
      expect(res.status, 200);
      expect(res.content, '你好，世界');
      expect(res.url, 'https://example.com/api');
      expect(res.headers['content-type'], 'text/html; charset=utf-8');
    });

    test('默认 UA 注入（iOS 复刻值）；自定义头覆盖优先', () async {
      final _FakeTransport transport = _FakeTransport((_) => _utf8Response('ok'));
      final SpiderHttpBridge bridge = SpiderHttpBridge(transport: transport);
      await bridge.request('https://example.com/1');
      expect(
        transport.requests.first.headers['User-Agent'],
        SpiderHttpBridge.defaultUserAgent,
      );

      final _FakeTransport transport2 = _FakeTransport((_) => _utf8Response('ok'));
      final SpiderHttpBridge bridge2 = SpiderHttpBridge(
        transport: transport2,
        defaultHeaders: const <String, String>{'X-Site': 's1'},
      );
      await bridge2.request(
        'https://example.com/2',
        options: const SpiderHttpOptions(
          headers: <String, String>{'User-Agent': 'MyUA/1.0'},
        ),
      );
      final Map<String, String> h = transport2.requests.first.headers;
      expect(h['User-Agent'], 'MyUA/1.0'); // 调用方显式 UA 不被覆盖（对齐 iOS）
      expect(h['X-Site'], 's1');
    });

    test('method 归一大写 + body 透传 + referer 直传', () async {
      final _FakeTransport transport = _FakeTransport((_) => _utf8Response('ok'));
      final SpiderHttpBridge bridge = SpiderHttpBridge(transport: transport);
      await bridge.request(
        'https://example.com/play',
        options: const SpiderHttpOptions(
          method: 'post',
          data: 'wd=test',
          referer: 'https://example.com/',
        ),
      );
      final SpiderTransportRequest req = transport.requests.single;
      expect(req.method, 'POST');
      expect(req.body, 'wd=test');
      expect(req.headers['Referer'], 'https://example.com/');
    });

    test('GBK 正向：响应头声明 charset=gbk → 编码链 ① 级直解', () async {
      final List<int> gbkBytes =
          const GbkCodec(allowInvalid: false).encode('中文测试');
      final SpiderHttpBridge bridge = SpiderHttpBridge(
        transport: _FakeTransport(
          (_) => SpiderTransportResponse(
            status: 200,
            headers: const <String, String>{
              'content-type': 'text/html; charset=gbk',
            },
            bodyBytes: gbkBytes,
          ),
        ),
      );
      final SpiderHttpResult res = await bridge.request('https://example.com/gbk');
      expect(res.content, '中文测试');
      expect(res.ok, isTrue);
    });

    test('Big5 正向：响应头声明 charset=big5 → 编码链 ① 级直解', () async {
      final List<int> big5Bytes =
          const Big5Codec(allowInvalid: false).encode('中文測試');
      final SpiderHttpBridge bridge = SpiderHttpBridge(
        transport: _FakeTransport(
          (_) => SpiderTransportResponse(
            status: 200,
            headers: const <String, String>{
              'content-type': 'text/html; charset=big5',
            },
            bodyBytes: big5Bytes,
          ),
        ),
      );
      final SpiderHttpResult res = await bridge.request('https://example.com/big5');
      expect(res.content, '中文測試');
    });

    test('GBK 正向（无声明）：③ 级 meta 探测 → 按声明解码', () async {
      final List<int> html =
          const GbkCodec(allowInvalid: false).encode('<meta charset="gbk">中文测试');
      final SpiderHttpBridge bridge = SpiderHttpBridge(
        transport: _FakeTransport(
          (_) => SpiderTransportResponse(
            status: 200,
            headers: const <String, String>{},
            bodyBytes: html,
          ),
        ),
      );
      final SpiderHttpResult res = await bridge.request('https://example.com/meta');
      expect(res.content, '<meta charset="gbk">中文测试');
    });

    test('GBK/Big5 负向：无声明且严格非法字节 → 链回退 latin1（不吞字节）',
        () async {
      final SpiderHttpBridge bridge = SpiderHttpBridge(
        transport: _FakeTransport(
          (_) => const SpiderTransportResponse(
            status: 200,
            headers: <String, String>{},
            bodyBytes: <int>[0xFF, 0xFE],
          ),
        ),
      );
      final SpiderHttpResult res = await bridge.request('https://example.com/bad');
      expect(res.content, '\u00FF\u00FE'); // latin1 全保留（非 GBK 误吞/替换）
    });

    test('GB18030 四字节序列（登记偏差）：严格 GBK 拒绝 → 链回退 latin1',
        () async {
      // '𠀀'(U+20000) 的 GB18030 四字节序列（trail 0x32/0x36 越出 GBK
      // 双字节区 0x40–0xFE）→ ① 级 gbk 严格失败 → 逐级下探 → latin1 全保留。
      // 与 iOS 的偏差已登记（iOS CF 为 GB_18030_2000 超集可直解）：
      // 含该类扩展字符的页面按契约链回退 latin1，不致乱码扩散。
      final SpiderHttpBridge bridge = SpiderHttpBridge(
        transport: _FakeTransport(
          (_) => const SpiderTransportResponse(
            status: 200,
            headers: <String, String>{
              'content-type': 'text/html; charset=gb18030',
            },
            bodyBytes: <int>[0x95, 0x32, 0x82, 0x36],
          ),
        ),
      );
      final SpiderHttpResult res = await bridge.request('https://example.com/ext');
      expect(res.content, '\u00952\u00826'); // latin1 全字节保留
    });

    test('GBK 悬空高位字节（奇数截断）：该级失败 → 链回退 latin1', () async {
      // '中'(0xD6D0) + 悬空 0xC4（下一双字节对被截断）：
      // 严格语义整段判失败（不吞字节、不产出替换符）。
      final SpiderHttpBridge bridge = SpiderHttpBridge(
        transport: _FakeTransport(
          (_) => const SpiderTransportResponse(
            status: 200,
            headers: <String, String>{
              'content-type': 'text/html; charset=gbk',
            },
            bodyBytes: <int>[0xD6, 0xD0, 0xC4],
          ),
        ),
      );
      final SpiderHttpResult res = await bridge.request('https://example.com/trunc');
      expect(res.content, '\u00D6\u00D0\u00C4'); // latin1 全字节保留
    });

    test('非 2xx：ok=false 但 status / content 保留（对齐 iOS）', () async {
      final SpiderHttpBridge bridge = SpiderHttpBridge(
        transport: _FakeTransport(
          (_) => const SpiderTransportResponse(
            status: 404,
            headers: <String, String>{},
            bodyBytes: <int>[0x4E, 0x4F],
          ),
        ),
      );
      final SpiderHttpResult res = await bridge.request('https://example.com/x');
      expect(res.ok, isFalse);
      expect(res.status, 404);
      expect(res.content, 'NO');
    });

    test('超时：ok=false / status=0 / content=请求超时（iOS 超时分支）', () async {
      final SpiderHttpBridge bridge = SpiderHttpBridge(
        transport: _ThrowingTransport(TimeoutException('too slow')),
      );
      final SpiderHttpResult res = await bridge.request('https://example.com/slow');
      expect(res.ok, isFalse);
      expect(res.status, 0);
      expect(res.content, '请求超时');
    });

    test('网络失败：SocketException → status=0 + 错误消息透传', () async {
      final SpiderHttpBridge bridge = SpiderHttpBridge(
        transport: _ThrowingTransport(const SocketException('网络不可达')),
      );
      final SpiderHttpResult res = await bridge.request('https://example.com/down');
      expect(res.ok, isFalse);
      expect(res.status, 0);
      expect(res.content, '网络不可达');
    });

    test('无效 URL：status=0 / content=无效URL，且不触达传输层', () async {
      final _FakeTransport transport = _FakeTransport((_) => _utf8Response('x'));
      final SpiderHttpBridge bridge = SpiderHttpBridge(transport: transport);
      final SpiderHttpResult res = await bridge.request('not-a-url');
      expect(res.ok, isFalse);
      expect(res.status, 0);
      expect(res.content, '无效URL');
      expect(transport.requests, isEmpty);
    });

    test('cookie 回带：首响应收集 → 同域二次请求携带；他域不带', () async {
      final List<SpiderTransportResponse> canned = <SpiderTransportResponse>[
        SpiderTransportResponse(
          status: 200,
          headers: const <String, String>{},
          bodyBytes: 'ok'.codeUnits,
          setCookies: const <String>['sid=abc; Path=/; HttpOnly'],
        ),
        _utf8Response('ok2'),
        _utf8Response('ok3'),
      ];
      final _FakeTransport transport = _FakeTransport(
        (_) => canned.removeAt(0),
      );
      final SpiderHttpBridge bridge = SpiderHttpBridge(transport: transport);

      await bridge.request('https://example.com/first'); // 收集 sid
      await bridge.request('https://example.com/second'); // 同域回带
      final Map<String, String> secondHeaders =
          transport.requests[1].headers;
      expect(secondHeaders[HttpHeaders.cookieHeader], 'sid=abc');

      await bridge.request('https://other.example.com/third'); // 域隔离
      expect(
        transport.requests[2].headers.containsKey(HttpHeaders.cookieHeader),
        isFalse,
      );
    });

    test('sslBypass 接线：实例开关 + IoSpiderHttpTransport 标记', () {
      final SpiderHttpBridge bridge = SpiderHttpBridge(sslBypass: true);
      expect(bridge.sslBypass, isTrue);
      expect(IoSpiderHttpTransport(sslBypass: true).sslBypass, isTrue);
      expect(IoSpiderHttpTransport().sslBypass, isFalse);
    });

    test('close()：注入 fake transport 时 no-op 不抛', () async {
      final SpiderHttpBridge bridge = SpiderHttpBridge(
        transport: _FakeTransport((_) => _utf8Response('x')),
      );
      await bridge.close(); // 非 IoSpiderHttpTransport → 安全 no-op
    });
  });
}
