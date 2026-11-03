/// 平台层单测：JavaScriptCore 桥接引擎（批次 Q · Q-05，D6 主引擎）。
///
/// 注入 fake [JsCoreNativeBridge]（FFI mock），不依赖真实动态库：
/// 与 `quickjs_bridge_engine_test.dart` **同覆盖面**（三端同一 ABI、同一
/// 引擎形状的验收口径）：
/// - loadScript 异常检测（Error 前缀 → E_SCRIPT_LOAD）+ **B-05a prelude 先注入**
/// - registerSpider 的 `typeof globalThis.__JS_SPIDER__` 检测（含 spider 兜底）
/// - 5 个操作（init 一次 + 字符串 / 对象双返回路径 + JSON 解析）
/// - 原生库不可用 → E_UNIMPLEMENTED（未打包环境安全降级）
/// - loadScriptFromURL（真实本地 HttpServer + B-09 注入 SpiderHttpBridge 离线用例）
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/spider/engine_type.dart';
import 'package:vbox/domain/entities/spider/spider_engine.dart';
import 'package:vbox/platform/runtime/jsc_bridge_engine.dart';
import 'package:vbox/platform/runtime/jsc_ffi.dart';
import 'package:vbox/platform/spider/spider_http_bridge.dart';
import 'package:vbox/platform/spider/spider_js_globals.dart';

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

/// 记录脚本并按规则返回 canned 结果的 FFI mock。
///
/// 匹配优先级：完整脚本命中 → 子串命中 → [defaultValue]。
class _FakeJsCoreBridge implements JsCoreNativeBridge {
  _FakeJsCoreBridge({
    this.byExact = const <String, String>{},
    this.bySubstring = const <String, String>{},
  });

  final bool available = true;
  final Map<String, String> byExact;
  final Map<String, String> bySubstring;
  final String defaultValue = '';

  /// 记录全部 eval 调用（断言参数拼接 / init 只调一次 / prelude 先注入）。
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
class _UnavailableBridge implements JsCoreNativeBridge {
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
  const SpiderEngineType engineTypeAssert = SpiderEngineType.javaScriptCore;

  group('JsCoreBridgeEngine（Q-05 · D6 主引擎）', () {
    test('engineType 恒为 javaScriptCore；初始未注册', () {
      final JsCoreBridgeEngine engine = JsCoreBridgeEngine(
        bridge: _FakeJsCoreBridge(),
      );
      expect(engine.engineType, engineTypeAssert);
      expect(engine.isSpiderReady, isFalse);
    });

    test('原生库不可用 → E_UNIMPLEMENTED（loadScript / register / 操作）', () async {
      final JsCoreBridgeEngine engine = JsCoreBridgeEngine(
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

    test('loadScript：B-05a prelude 先于用户脚本注入（内置脚本零改动可跑）', () async {
      final _FakeJsCoreBridge bridge = _FakeJsCoreBridge();
      final JsCoreBridgeEngine engine = JsCoreBridgeEngine(bridge: bridge);
      await engine.loadScript(_sampleSpider);

      // eval 顺序：prelude → 用户脚本 → 日志取回（B-05a：console/print/atob/btoa/req/options）
      expect(bridge.evals, hasLength(3));
      expect(
        bridge.evals.first.contains(SpiderJsGlobals.preludeVersion),
        isTrue,
        reason: '首个 eval 必须是 JS 全局桥 prelude',
      );
      expect(bridge.evals[1], _sampleSpider);
      expect(bridge.evals[2], SpiderJsGlobals.drainLogsScript());
      await engine.dispose();
    });

    test('loadScript：JS 异常（Error 前缀）→ E_SCRIPT_LOAD', () async {
      final JsCoreBridgeEngine engine = JsCoreBridgeEngine(
        bridge: _FakeJsCoreBridge(byExact: <String, String>{
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
      final _FakeJsCoreBridge bridge = _FakeJsCoreBridge(
        byExact: <String, String>{
          'typeof globalThis.__JS_SPIDER__': 'object',
        },
      );
      final JsCoreBridgeEngine engine = JsCoreBridgeEngine(
        bridge: bridge,
        siteKey: 'js_示例',
        baseUrl: 'https://example.com/js/demo.js',
        requestId: 'req-jsc-1',
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
      final JsCoreBridgeEngine engine = JsCoreBridgeEngine(
        bridge: _FakeJsCoreBridge(
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
      final JsCoreBridgeEngine engine = JsCoreBridgeEngine(
        bridge: _FakeJsCoreBridge(),
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
      final _FakeJsCoreBridge bridge = _FakeJsCoreBridge(
        byExact: <String, String>{
          'typeof globalThis.__JS_SPIDER__': 'object',
        },
        bySubstring: <String, String>{
          'homeContent(': _wrapStringJson(home),
        },
      );
      final JsCoreBridgeEngine engine = JsCoreBridgeEngine(
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
      expect(initEvals.first, contains('"engineType":"JavaScriptCore"'));

      // 再调一次 → init 仍只有一次
      await engine.callHomeContent();
      expect(
        bridge.evals.where((String s) => s.contains('__JS_SPIDER__.init(')),
        hasLength(1),
      );
      await engine.dispose();
    });

    test('callSearchContent：TVBox 标准签名三参（keyword, quickSearch, pg）', () async {
      final _FakeJsCoreBridge bridge = _FakeJsCoreBridge(
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
      final JsCoreBridgeEngine engine = JsCoreBridgeEngine(bridge: bridge);
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

    test('callCategoryContent / callDetailContent / callPlayerContent：五操作齐备', () async {
      final _FakeJsCoreBridge bridge = _FakeJsCoreBridge(
        byExact: <String, String>{
          'typeof globalThis.__JS_SPIDER__': 'object',
        },
        bySubstring: <String, String>{
          'categoryContent(': _wrapStringJson(<String, Object?>{
            'list': <Map<String, Object?>>[
              <String, Object?>{'vod_id': '2001', 'vod_name': '分类影片'},
            ],
          }),
          'detailContent(': _wrapStringJson(<String, Object?>{
            'list': <Map<String, Object?>>[
              <String, Object?>{'vod_id': '2001', 'vod_name': '详情影片'},
            ],
          }),
          'playerContent(': _wrapStringJson(<String, Object?>{
            'parse': '',
            'playUrl': 'https://play.example.com/index.m3u8',
            'header': <String, String>{'User-Agent': 'okhttp/4'},
          }),
        },
      );
      final JsCoreBridgeEngine engine = JsCoreBridgeEngine(bridge: bridge);
      await engine.loadScript(_sampleSpider);
      await engine.registerSpider();

      final dynamic category = await engine.callCategoryContent('1', 1, '');
      expect(category.list!.first.vodName, '分类影片');

      final dynamic detail = await engine.callDetailContent('2001');
      expect(detail.list!.first.vodName, '详情影片');

      final dynamic player = await engine.callPlayerContent('2001', '默认', 'https://play.example.com/1.m3u8');
      expect(player.playUrl, 'https://play.example.com/index.m3u8');
      await engine.dispose();
    });

    test('对象返回路径（__type=object）→ 直接解析', () async {
      final _FakeJsCoreBridge bridge = _FakeJsCoreBridge(
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
      final JsCoreBridgeEngine engine = JsCoreBridgeEngine(bridge: bridge);
      await engine.loadScript(_sampleSpider);
      await engine.registerSpider();

      final dynamic result = await engine.callHomeContent();
      expect(result.classes!.first.typeName, '电视剧');
      await engine.dispose();
    });

    test('结果编码无效（非 JSON / 未知 __type）→ E_PROTOCOL', () async {
      final _FakeJsCoreBridge bridge = _FakeJsCoreBridge(
        byExact: <String, String>{
          'typeof globalThis.__JS_SPIDER__': 'object',
        },
        bySubstring: <String, String>{
          'homeContent(': '{not-json',
        },
      );
      final JsCoreBridgeEngine engine = JsCoreBridgeEngine(bridge: bridge);
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

    test('drainJsLogs：B-05a 缓冲日志取回接 onLog', () async {
      final _FakeJsCoreBridge bridge = _FakeJsCoreBridge(
        byExact: <String, String>{
          'typeof globalThis.__JS_SPIDER__': 'object',
          SpiderJsGlobals.drainLogsScript(): '["LOG|hello JSC","ERROR|boom"]',
        },
      );
      final JsCoreBridgeEngine engine = JsCoreBridgeEngine(bridge: bridge);
      final List<String> logs = <String>[];
      engine.onLog = logs.add;
      await engine.loadScript(_sampleSpider);
      await engine.registerSpider();

      final List<String> drained = await engine.drainJsLogs();
      expect(drained, <String>['hello JSC', 'ERROR: boom']);
      // loadScript 内部已自动取回一次 + 显式取回一次（fake 桥恒回 canned 日志）
      expect(logs.where((String l) => l.startsWith('JS ')), hasLength(4));
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

      final _FakeJsCoreBridge bridge = _FakeJsCoreBridge(
        byExact: <String, String>{
          'typeof globalThis.__JS_SPIDER__': 'object',
        },
      );
      final JsCoreBridgeEngine engine = JsCoreBridgeEngine(bridge: bridge);
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

      final JsCoreBridgeEngine engine = JsCoreBridgeEngine(
        bridge: _FakeJsCoreBridge(),
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
      final JsCoreBridgeEngine engine = JsCoreBridgeEngine(
        bridge: _FakeJsCoreBridge(
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

    test('loadScript 前 dispose 幂等；dispose 后 isSpiderReady=false', () async {
      final _FakeJsCoreBridge bridge = _FakeJsCoreBridge(
        byExact: <String, String>{
          'typeof globalThis.__JS_SPIDER__': 'object',
        },
      );
      final JsCoreBridgeEngine engine = JsCoreBridgeEngine(bridge: bridge);
      await engine.dispose(); // 未加载 → 幂等
      await engine.loadScript(_sampleSpider);
      await engine.registerSpider();
      expect(engine.isSpiderReady, isTrue);
      await engine.dispose();
      expect(engine.isSpiderReady, isFalse);
    });
  });
}
