/// 平台层单测：QuickJS 桥接引擎（FFI 原生绑定，G-03-B-2）。
///
/// 注入 fake [QuickJsNativeBridge]（FFI mock），不依赖真实动态库：
/// - loadScript 异常检测（Error 前缀 → E_SCRIPT_LOAD）
/// - registerSpider 的 `typeof globalThis.__JS_SPIDER__` 检测（含 spider 兜底）
/// - 5 个操作（init 一次 + 字符串 / 对象双返回路径 + JSON 解析）
/// - 原生库不可用 → E_UNIMPLEMENTED（未打包环境安全降级）
/// - loadScriptFromURL（真实本地 HttpServer + B-09 注入 SpiderHttpBridge 离线用例）
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/spider/engine_type.dart';
import 'package:vbox/domain/entities/spider/spider_engine.dart';
import 'package:vbox/platform/runtime/quickjs_bridge_engine.dart';
import 'package:vbox/platform/runtime/quickjs_ffi.dart';
import 'package:vbox/platform/spider/spider_http_bridge.dart';

/// 记录请求并固定返回 200 + UTF-8 脚本正文的 fake 传输层（B-09 注入用例）。
class _ScriptTransport implements SpiderHttpTransport {
  final List<SpiderTransportRequest> requests = <SpiderTransportRequest>[];

  @override
  Future<SpiderTransportResponse> send(SpiderTransportRequest request) async {
    requests.add(request);
    return SpiderTransportResponse(
      status: 200,
      headers: const <String, String>{
        'content-type': 'application/javascript; charset=utf-8',
      },
      bodyBytes: 'var spider = {homeContent: function(){return {};}};'
          .codeUnits,
    );
  }
}

/// 返回固定分类 JSON 的 fake 传输层（G-03-B-3 脚本 http() 场景）。
class _CategoryApiTransport implements SpiderHttpTransport {
  final List<SpiderTransportRequest> requests = <SpiderTransportRequest>[];

  @override
  Future<SpiderTransportResponse> send(SpiderTransportRequest request) async {
    requests.add(request);
    return SpiderTransportResponse(
      status: 200,
      headers: const <String, String>{'content-type': 'application/json'},
      bodyBytes: utf8.encode(
          '{"class":[{"type_id":"6","type_name":"综艺"}],"list":[]}'),
    );
  }
}

/// 恒抛网络异常的 fake 传输层（http 失败回写用例）。
class _FailingTransport implements SpiderHttpTransport {
  @override
  Future<SpiderTransportResponse> send(SpiderTransportRequest request) async {
    throw const SocketException('网络不可达');
  }
}

/// 记录脚本并按规则返回 canned 结果的 FFI mock。
///
/// 匹配优先级：完整脚本命中 → 子串命中 → [defaultValue]。
class _FakeQuickJsBridge implements QuickJsNativeBridge {
  _FakeQuickJsBridge({
    this.byExact = const <String, String>{},
    this.bySubstring = const <String, String>{},
  });

  final bool available = true;
  final Map<String, String> byExact;
  final Map<String, String> bySubstring;
  final String defaultValue = '';

  /// 记录全部 eval 调用（断言参数拼接 / init 只调一次）。
  final List<String> evals = <String>[];
  bool freedContext = false;
  bool freedRuntime = false;

  @override
  bool get isAvailable => available;

  @override
  int createRuntime() => 0x1000;

  @override
  int createContext(int runtime) => 0x2000;

  @override
  void freeContext(int context) => freedContext = true;

  @override
  void freeRuntime(int runtime) => freedRuntime = true;

  @override
  String? eval(int context, String script) {
    evals.add(script);
    final String? exact = byExact[script];
    if (exact != null) return exact;
    for (final MapEntry<String, String> e in bySubstring.entries) {
      if (script.contains(e.key)) return e.value;
    }
    return defaultValue;
  }
}

/// 不可用桥（isAvailable == false，所有调用安全 no-op）。
class _UnavailableBridge implements QuickJsNativeBridge {
  @override
  bool get isAvailable => false;

  @override
  int createRuntime() => 0;

  @override
  int createContext(int runtime) => 0;

  @override
  void freeContext(int context) {}

  @override
  void freeRuntime(int runtime) {}

  @override
  String? eval(int context, String script) => null;
}

/// 模拟 worker 线程的 fake 异步桥（G-03-B-3 · 快速验证桥接模型）。
///
/// 行为复刻 C 侧 worker：evalSubmit 记录脚本并 scheduleMicrotask 执行 ——
/// homeContent / categoryContent 场景先投递 http 事件（event 2）、
/// 等引擎回写 httpComplete 后再投递 eval 完成（event 1）。
class _FakeAsyncBridge implements QuickJsNativeBridge, QuickJsAsyncNativeBridge {
  _FakeAsyncBridge({
    this.bySubstring = const <String, String>{},
  });

  final Map<String, String> bySubstring;
  final String httpUrl = 'https://api.example.com/cats';

  final List<String> evals = <String>[];
  final List<String> httpWrites = <String>[];
  bool closedHostBridge = false;

  QuickJsHostEventHandler? _handler;
  String? _pendingResult;
  int _handleSeq = 0;

  String _resolve(String script) {
    for (final MapEntry<String, String> e in bySubstring.entries) {
      if (script.contains(e.key)) return e.value;
    }
    return '';
  }

  @override
  bool get isAvailable => true;

  @override
  int createRuntime() => 0x1000;

  @override
  int createContext(int runtime) => 0x2000;

  @override
  void freeContext(int context) {}

  @override
  void freeRuntime(int runtime) {}

  @override
  String? eval(int context, String script) {
    evals.add(script);
    return _resolve(script);
  }

  @override
  int setHostBridge(int runtime, QuickJsHostEventHandler handler) {
    _handler = handler;
    return ++_handleSeq;
  }

  @override
  void closeHostBridge(int handle) => closedHostBridge = true;

  @override
  bool evalSubmit(int runtime, String script) {
    evals.add(script);
    scheduleMicrotask(() async {
      if (script.contains('homeContent(') ||
          script.contains('categoryContent(')) {
        _handler!(2, 1, httpUrl, '{"method":"GET"}');
        // 等引擎异步发请求并回写（轮询事件循环，对齐 worker 阻塞等待语义）
        while (httpWrites.isEmpty) {
          await Future<void>.delayed(Duration.zero);
        }
      }
      _pendingResult = _resolve(script);
      _handler!(1, 0, '', '');
    });
    return true;
  }

  @override
  String? evalTakeResult(int runtime) {
    final String? r = _pendingResult;
    _pendingResult = null;
    return r;
  }

  @override
  bool httpComplete(int runtime, int reqId, String responseJson) {
    httpWrites.add(responseJson);
    return true;
  }
}

/// 示例蜘蛛脚本（符合契约：spider.__jsEvalReturn / default 兜底注册）。
const String _sampleSpider = r'''
var spider = {
  homeContent: function () {
    return {
      "class": [{"type_id": "1", "type_name": "电影"}],
      "list": [{"vod_id": "1001", "vod_name": "示例影片", "vod_pic": "https://cdn.example.com/1001.jpg"}]
    };
  },
  searchContent: function (keyword, quick, pg) {
    return { "page": 1, "pagecount": 5, "list": [] };
  }
};
''';

/// 字符串返回路径的包装 JSON（对齐引擎端 `{__type:'string', __value:...}`）。
String _wrapStringJson(Map<String, Object?> data) =>
    jsonEncode(<String, Object?>{'__type': 'string', '__value': jsonEncode(data)});

void main() {
  const SpiderEngineType engineTypeAssert = SpiderEngineType.quickJS;

  group('QuickJSBridgeEngine', () {
    test('engineType 恒为 quickJS；初始未注册', () {
      final QuickJSBridgeEngine engine = QuickJSBridgeEngine(
        bridge: _FakeQuickJsBridge(),
      );
      expect(engine.engineType, engineTypeAssert);
      expect(engine.isSpiderReady, isFalse);
    });

    test('原生库不可用 → E_UNIMPLEMENTED（loadScript / register / 操作）', () async {
      final QuickJSBridgeEngine engine = QuickJSBridgeEngine(
        bridge: _UnavailableBridge(),
      );
      await expectLater(
        engine.loadScript('var x = 1;'),
        throwsA(
          isA<SpiderException>().having(
            (SpiderException e) => e.code,
            'code',
            SpiderErrorCode.unimplemented,
          ),
        ),
      );
      await expectLater(
        engine.registerSpider(),
        throwsA(
          isA<SpiderException>().having(
            (SpiderException e) => e.code,
            'code',
            SpiderErrorCode.unimplemented,
          ),
        ),
      );
      await expectLater(
        engine.callHomeContent(),
        throwsA(
          isA<SpiderException>().having(
            (SpiderException e) => e.code,
            'code',
            SpiderErrorCode.unimplemented,
          ),
        ),
      );
    });

    test('loadScript：JS 异常（Error 前缀）→ E_SCRIPT_LOAD', () async {
      final QuickJSBridgeEngine engine = QuickJSBridgeEngine(
        bridge: _FakeQuickJsBridge(byExact: <String, String>{
          'var = ;': 'SyntaxError: unexpected token',
        }),
      );
      await expectLater(
        engine.loadScript('var = ;'),
        throwsA(
          isA<SpiderException>()
              .having(
                (SpiderException e) => e.code,
                'code',
                SpiderErrorCode.scriptLoad,
              )
              .having(
                (SpiderException e) => e.message,
                'message',
                contains('JS 异常'),
              ),
        ),
      );
    });

    test('loadScript + registerSpider 成功路径（typeof → object）', () async {
      final _FakeQuickJsBridge bridge = _FakeQuickJsBridge(
        byExact: <String, String>{
          'typeof globalThis.__JS_SPIDER__': 'object',
        },
      );
      final QuickJSBridgeEngine engine = QuickJSBridgeEngine(
        bridge: bridge,
        siteKey: 'js_示例',
        baseUrl: 'https://example.com/js/demo.js',
        requestId: 'req-qjs-1',
      );
      final List<String> logs = <String>[];
      engine.onLog = logs.add;

      await engine.loadScript(_sampleSpider);
      await engine.registerSpider();
      expect(engine.isSpiderReady, isTrue);
      expect(logs.join('\n'), contains('蜘蛛已注册'));

      await engine.dispose();
      expect(bridge.freedContext, isTrue);
      expect(bridge.freedRuntime, isTrue);
      expect(engine.isSpiderReady, isFalse);
    });

    test('registerSpider：未找到 __JS_SPIDER__ → E_REGISTER', () async {
      final QuickJSBridgeEngine engine = QuickJSBridgeEngine(
        bridge: _FakeQuickJsBridge(
          byExact: <String, String>{
            'typeof globalThis.__JS_SPIDER__': 'undefined',
          },
        ),
      );
      await engine.loadScript('var spider = {};');
      await expectLater(
        engine.registerSpider(),
        throwsA(
          isA<SpiderException>()
              .having(
                (SpiderException e) => e.code,
                'code',
                SpiderErrorCode.register,
              )
              .having(
                (SpiderException e) => e.message,
                'message',
                contains('__JS_SPIDER__'),
              ),
        ),
      );
    });

    test('未注册即调用操作 → E_REGISTER', () async {
      final QuickJSBridgeEngine engine = QuickJSBridgeEngine(
        bridge: _FakeQuickJsBridge(),
      );
      await engine.loadScript(_sampleSpider);
      await expectLater(
        engine.callHomeContent(),
        throwsA(
          isA<SpiderException>().having(
            (SpiderException e) => e.code,
            'code',
            SpiderErrorCode.register,
          ),
        ),
      );
    });

    test('callHomeContent：字符串返回路径 + init 只调用一次', () async {
      final Map<String, Object?> home = <String, Object?>{
        'class': <Map<String, Object?>>[
          <String, Object?>{'type_id': '1', 'type_name': '电影'},
        ],
        'list': <Map<String, Object?>>[],
      };
      final _FakeQuickJsBridge bridge = _FakeQuickJsBridge(
        byExact: <String, String>{
          'typeof globalThis.__JS_SPIDER__': 'object',
        },
        bySubstring: <String, String>{
          'homeContent(': _wrapStringJson(home),
        },
      );
      final QuickJSBridgeEngine engine = QuickJSBridgeEngine(
        bridge: bridge,
        siteKey: 'js_示例',
      );
      await engine.loadScript(_sampleSpider);
      await engine.registerSpider();

      final dynamic result = await engine.callHomeContent();
      expect(result.classes, hasLength(1));
      expect(result.classes!.first.typeName, '电影');

      // init 恰一次（对齐 iOS：引擎创建后 callInit 一次）
      final Iterable<String> initEvals = bridge.evals
          .where((String s) => s.contains('__JS_SPIDER__.init('));
      expect(initEvals, hasLength(1));
      expect(initEvals.first, contains('"siteKey":"js_示例"'));

      // 再调一次 → init 仍只有一次
      await engine.callHomeContent();
      expect(
        bridge.evals.where((String s) => s.contains('__JS_SPIDER__.init(')),
        hasLength(1),
      );
      await engine.dispose();
    });

    test('callSearchContent：TVBox 标准签名三参（keyword, quickSearch, pg）', () async {
      final _FakeQuickJsBridge bridge = _FakeQuickJsBridge(
        byExact: <String, String>{
          'typeof globalThis.__JS_SPIDER__': 'object',
        },
        bySubstring: <String, String>{
          'searchContent(': _wrapStringJson(<String, Object?>{
            'page': 1,
            'pagecount': 5,
            'list': <Map<String, Object?>>[],
          }),
        },
      );
      final QuickJSBridgeEngine engine = QuickJSBridgeEngine(bridge: bridge);
      await engine.loadScript(_sampleSpider);
      await engine.registerSpider();

      final dynamic result = await engine.callSearchContent('功夫', 1);
      expect(result.page, 1);
      final String apiCall = bridge.evals
          .firstWhere((String s) => s.contains('__JS_SPIDER__.searchContent('));
      // 引号转义 + 参数顺序：searchContent('功夫', 'false', '1')
      expect(apiCall, contains("__JS_SPIDER__.searchContent('功夫', 'false', '1')"));
      await engine.dispose();
    });

    test('对象返回路径（__type=object）→ 直接解析', () async {
      final _FakeQuickJsBridge bridge = _FakeQuickJsBridge(
        byExact: <String, String>{
          'typeof globalThis.__JS_SPIDER__': 'object',
        },
        bySubstring: <String, String>{
          'homeContent(': jsonEncode(<String, Object?>{
            '__type': 'object',
            '__value': <String, Object?>{
              'class': <Map<String, Object?>>[
                <String, Object?>{'type_id': '2', 'type_name': '电视剧'},
              ],
              'list': <Map<String, Object?>>[],
            },
          }),
        },
      );
      final QuickJSBridgeEngine engine = QuickJSBridgeEngine(bridge: bridge);
      await engine.loadScript(_sampleSpider);
      await engine.registerSpider();

      final dynamic result = await engine.callHomeContent();
      expect(result.classes!.first.typeName, '电视剧');
      await engine.dispose();
    });

    test('结果编码无效（非 JSON / 未知 __type）→ E_PROTOCOL', () async {
      final _FakeQuickJsBridge bridge = _FakeQuickJsBridge(
        byExact: <String, String>{
          'typeof globalThis.__JS_SPIDER__': 'object',
        },
        bySubstring: <String, String>{
          'homeContent(': '{not-json',
        },
      );
      final QuickJSBridgeEngine engine = QuickJSBridgeEngine(bridge: bridge);
      await engine.loadScript(_sampleSpider);
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

    test('loadScriptFromURL：本地 HttpServer 200 → 脚本加载成功', () async {
      final HttpServer server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => server.close(force: true));
      server.listen((HttpRequest req) {
        req.response.statusCode = 200;
        req.response.write('var spider = {homeContent: function(){return {};}};');
        req.response.close();
      });
      final int port = server.port;

      final _FakeQuickJsBridge bridge = _FakeQuickJsBridge(
        byExact: <String, String>{
          'typeof globalThis.__JS_SPIDER__': 'object',
        },
      );
      final QuickJSBridgeEngine engine = QuickJSBridgeEngine(bridge: bridge);
      await engine.loadScriptFromURL('http://127.0.0.1:$port/spider.js');
      expect(engine.isSpiderReady, isFalse); // 仅加载，未注册
      await engine.registerSpider();
      expect(engine.isSpiderReady, isTrue);
      await engine.dispose();
    });

    test('loadScriptFromURL：非 200 → E_SCRIPT_LOAD', () async {
      final HttpServer server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => server.close(force: true));
      server.listen((HttpRequest req) {
        req.response.statusCode = 404;
        req.response.close();
      });
      final int port = server.port;

      final QuickJSBridgeEngine engine = QuickJSBridgeEngine(
        bridge: _FakeQuickJsBridge(),
      );
      await expectLater(
        engine.loadScriptFromURL('http://127.0.0.1:$port/missing.js'),
        throwsA(
          isA<SpiderException>()
              .having(
                (SpiderException e) => e.code,
                'code',
                SpiderErrorCode.scriptLoad,
              )
              .having(
                (SpiderException e) => e.message,
                'message',
                contains('HTTP 404'),
              ),
        ),
      );
    });

    test('loadScriptFromURL：注入 SpiderHttpBridge（fake transport）→ 离线加载',
        () async {
      final _ScriptTransport transport = _ScriptTransport();
      final SpiderHttpBridge http = SpiderHttpBridge(transport: transport);
      final QuickJSBridgeEngine engine = QuickJSBridgeEngine(
        bridge: _FakeQuickJsBridge(
          byExact: <String, String>{
            'typeof globalThis.__JS_SPIDER__': 'object',
          },
        ),
        httpBridge: http,
      );
      await engine.loadScriptFromURL('https://example.com/spider.js');
      expect(engine.isSpiderReady, isFalse); // 仅加载，未注册
      await engine.registerSpider();
      expect(engine.isSpiderReady, isTrue);
      // B-09：脚本拉取经 HTTP 桥 → iOS 默认 UA 面向蜘蛛站点
      expect(
        transport.requests.single.headers['User-Agent'],
        SpiderHttpBridge.defaultUserAgent,
      );
      await engine.dispose();
    });

    test('G-03-B-3：worker 桥 — 脚本 http() 经宿主事件异步回写', () async {
      final _CategoryApiTransport transport = _CategoryApiTransport();
      final SpiderHttpBridge http = SpiderHttpBridge(transport: transport);
      final Map<String, Object?> home = <String, Object?>{
        'class': <Map<String, Object?>>[
          <String, Object?>{'type_id': '6', 'type_name': '综艺'},
        ],
        'list': <Map<String, Object?>>[],
      };
      final _FakeAsyncBridge bridge = _FakeAsyncBridge(
        bySubstring: <String, String>{
          'typeof globalThis.__JS_SPIDER__': 'object',
          'homeContent(': _wrapStringJson(home),
        },
      );
      final QuickJSBridgeEngine engine = QuickJSBridgeEngine(
        bridge: bridge,
        asyncBridge: bridge,
        httpBridge: http,
      );
      await engine.loadScript(_sampleSpider);
      await engine.registerSpider();

      final dynamic result = await engine.callHomeContent();
      expect(result.classes, hasLength(1));
      expect(result.classes!.first.typeName, '综艺');

      // http 请求经桥发出（iOS 默认 UA + 归一 options）
      expect(transport.requests, hasLength(1));
      expect(
        transport.requests.single.headers['User-Agent'],
        SpiderHttpBridge.defaultUserAgent,
      );
      expect(transport.requests.single.url, Uri.parse('https://api.example.com/cats'));

      // 回写响应形状对齐 iOS JSSpiderEngine 字典：ok/status/content/url/headers/error
      final Map<String, Object?> resp =
          jsonDecode(bridge.httpWrites.single) as Map<String, Object?>;
      expect(resp['ok'], isTrue);
      expect(resp['status'], 200);
      expect(resp['content'], contains('综艺'));
      expect(resp['url'], 'https://api.example.com/cats');
      expect(resp.keys, containsAll(<String>['headers', 'error']));

      await engine.dispose();
      expect(bridge.closedHostBridge, isTrue);
    });

    test('G-03-B-3：worker 桥 — http 失败回写 ok=false（脚本拿失败对象）', () async {
      final SpiderHttpBridge http =
          SpiderHttpBridge(transport: _FailingTransport());
      final Map<String, Object?> home = <String, Object?>{
        'class': <Map<String, Object?>>[],
        'list': <Map<String, Object?>>[],
      };
      final _FakeAsyncBridge bridge = _FakeAsyncBridge(
        bySubstring: <String, String>{
          'typeof globalThis.__JS_SPIDER__': 'object',
          'homeContent(': _wrapStringJson(home),
        },
      );
      final QuickJSBridgeEngine engine = QuickJSBridgeEngine(
        bridge: bridge,
        asyncBridge: bridge,
        httpBridge: http,
      );
      await engine.loadScript(_sampleSpider);
      await engine.registerSpider();

      // 脚本消费失败对象后仍正常返回（引擎不因 http 失败抛错，对齐 iOS 语义）
      final dynamic result = await engine.callHomeContent();
      expect(result.classes, isEmpty);

      final Map<String, Object?> resp =
          jsonDecode(bridge.httpWrites.single) as Map<String, Object?>;
      expect(resp['ok'], isFalse);
      expect(resp['status'], 0);
      expect(resp['content'], isNotEmpty); // 错误消息
      await engine.dispose();
    });

    test('G-03-B-3：无 asyncBridge → 同步 eval 回退（旧语义不回归）', () async {
      final _FakeQuickJsBridge bridge = _FakeQuickJsBridge(
        byExact: <String, String>{
          'typeof globalThis.__JS_SPIDER__': 'object',
        },
        bySubstring: <String, String>{
          'homeContent(': _wrapStringJson(<String, Object?>{
            'class': <Map<String, Object?>>[
              <String, Object?>{'type_id': '1', 'type_name': '电影'},
            ],
            'list': <Map<String, Object?>>[],
          }),
        },
      );
      final QuickJSBridgeEngine engine = QuickJSBridgeEngine(bridge: bridge);
      await engine.loadScript(_sampleSpider);
      await engine.registerSpider();
      final dynamic result = await engine.callHomeContent();
      expect(result.classes!.first.typeName, '电影');
      await engine.dispose();
    });

    test('loadScript 前 dispose 幂等；dispose 后 isSpiderReady=false', () async {
      final _FakeQuickJsBridge bridge = _FakeQuickJsBridge(
        byExact: <String, String>{
          'typeof globalThis.__JS_SPIDER__': 'object',
        },
      );
      final QuickJSBridgeEngine engine = QuickJSBridgeEngine(bridge: bridge);
      await engine.dispose(); // 未加载 → 幂等
      await engine.loadScript(_sampleSpider);
      await engine.registerSpider();
      expect(engine.isSpiderReady, isTrue);
      await engine.dispose();
      expect(engine.isSpiderReady, isFalse);
    });
  });
}
