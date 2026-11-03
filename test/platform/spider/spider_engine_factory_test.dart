/// 平台层单测：Spider 引擎工厂（B-05 定稿：JSC 主 / QuickJS 降级 + 降级可观测）。
///
/// 对齐 `contract/docs/abi_v1.md` §1「引擎类型」+ §1.1「引擎选择规则」+ D6：
/// - node / nodeLX → [NodeBridgeEngine]（HTTP 桥，58080 / 58083）
/// - python → [PythonBridgeEngine]（子进程 stdio ABI）
/// - quickJS → [QuickJSBridgeEngine]（降级备份位，不可用 → E_UNIMPLEMENTED）
/// - javaScriptCore → [JsCoreBridgeEngine]（JSC 主引擎）；
///   **JSC 不可用 → 自动降级 QuickJS 且降级可观测（onLog 事件）**
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/spider/engine_type.dart';
import 'package:vbox/domain/entities/spider/spider_engine.dart';
import 'package:vbox/platform/runtime/jsc_bridge_engine.dart';
import 'package:vbox/platform/runtime/jsc_ffi.dart';
import 'package:vbox/platform/runtime/quickjs_bridge_engine.dart';
import 'package:vbox/platform/runtime/quickjs_ffi.dart';
import 'package:vbox/platform/spider/node_bridge_engine.dart';
import 'package:vbox/platform/spider/node_http_client.dart';
import 'package:vbox/platform/spider/python_bridge_engine.dart';
import 'package:vbox/platform/spider/spider_engine_factory.dart';

/// FFI mock：可用 QuickJS 桥。
class _FakeQuickJsBridge implements QuickJsNativeBridge {
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
    if (script == 'typeof globalThis.__JS_SPIDER__') return 'object';
    return '';
  }
}

/// FFI mock：可用 JSC 桥。
class _FakeJsCoreBridge implements JsCoreNativeBridge {
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
    if (script == 'typeof globalThis.__JS_SPIDER__') return 'object';
    return '';
  }
}

/// 不可用桥（isAvailable == false）—— D6 降级触发器。
class _UnavailableBridge implements QuickJsNativeBridge, JsCoreNativeBridge {
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

/// 记录请求并返回预设响应的 fake 客户端（复用 Node 桥测试的响应结构）。
class _FakeNodeClient implements NodeHttpClient {
  final List<NodeHttpResponse> _responses;
  int _index = 0;

  _FakeNodeClient(this._responses);

  @override
  Future<NodeHttpResponse> post(String path, String body) async =>
      _responses[_index++];

  @override
  Future<void> close() async {}
}

void main() {
  const SpiderEngineFactory factory = SpiderEngineFactory();

  group('SpiderEngineFactory', () {
    test('node → NodeBridgeEngine（engineType 对齐）', () {
      final SpiderEngine engine = factory.create(SpiderEngineType.node);
      expect(engine, isA<NodeBridgeEngine>());
      expect(engine.engineType, SpiderEngineType.node);
    });

    test('nodeLX → NodeBridgeEngine（engineType 对齐）', () {
      final SpiderEngine engine = factory.create(SpiderEngineType.nodeLX);
      expect(engine, isA<NodeBridgeEngine>());
      expect(engine.engineType, SpiderEngineType.nodeLX);
    });

    test('python → PythonBridgeEngine', () {
      final SpiderEngine engine = factory.create(SpiderEngineType.python);
      expect(engine, isA<PythonBridgeEngine>());
      expect(engine.engineType, SpiderEngineType.python);
    });

    test('quickJS → QuickJSBridgeEngine（降级备份位，G-03-B）', () async {
      final SpiderEngine engine = factory.create(
        SpiderEngineType.quickJS,
        quickJsBridge: _FakeQuickJsBridge(),
        siteKey: 'js_示例',
        baseUrl: 'https://example.com/js/demo.js',
        requestId: 'req-factory-qjs',
      );
      expect(engine, isA<QuickJSBridgeEngine>());
      expect(engine.engineType, SpiderEngineType.quickJS);
      await engine.loadScript('var spider = {homeContent: function(){return {};}};');
      await engine.registerSpider();
      expect(engine.isSpiderReady, isTrue);
      await engine.dispose();
    });

    test('quickJS 原生库不可用 → E_UNIMPLEMENTED（无二次降级）', () {
      expect(
        () => factory.create(
          SpiderEngineType.quickJS,
          quickJsBridge: _UnavailableBridge(),
        ),
        throwsA(
          isA<SpiderException>().having(
            (SpiderException e) => e.code,
            'code',
            SpiderErrorCode.unimplemented,
          ),
        ),
      );
    });

    test('javaScriptCore → JsCoreBridgeEngine（D6 主引擎）', () async {
      final SpiderEngine engine = factory.create(
        SpiderEngineType.javaScriptCore,
        jsCoreBridge: _FakeJsCoreBridge(),
        siteKey: 'js_示例',
        baseUrl: 'https://example.com/js/demo.js',
        requestId: 'req-factory-jsc',
      );
      expect(engine, isA<JsCoreBridgeEngine>());
      expect(engine.engineType, SpiderEngineType.javaScriptCore);
      await engine.loadScript('var spider = {homeContent: function(){return {};}};');
      await engine.registerSpider();
      expect(engine.isSpiderReady, isTrue);
      await engine.dispose();
    });

    test('D6 降级：JSC 不可用 → QuickJS 顶替 + 降级可观测（onLog 事件）', () async {
      final List<String> logs = <String>[];
      final SpiderEngine engine = factory.create(
        SpiderEngineType.javaScriptCore,
        jsCoreBridge: _UnavailableBridge(),
        quickJsBridge: _FakeQuickJsBridge(),
        siteKey: 'js_演示',
        onLog: logs.add,
      );
      // 降级产物：QuickJS 引擎（engineType 随之切换为降级引擎）
      expect(engine, isA<QuickJSBridgeEngine>());
      expect(engine.engineType, SpiderEngineType.quickJS);
      // 降级可观测：⚠️ 降级事件 + ✅ 降级完成事件
      expect(logs.join('\n'), contains('⚠️ JSC 引擎不可用'));
      expect(logs.join('\n'), contains('按 D6 自动降级 QuickJS'));
      expect(logs.join('\n'), contains('✅ 已降级为 QuickJS 引擎（站点 js_演示）'));
      // 降级引擎全生命周期可用
      await engine.loadScript('var spider = {homeContent: function(){return {};}};');
      await engine.registerSpider();
      expect(engine.isSpiderReady, isTrue);
      await engine.dispose();
    });

    test('D6 兜底：JSC 与 QuickJS 均不可用 → E_UNIMPLEMENTED', () {
      expect(
        () => factory.create(
          SpiderEngineType.javaScriptCore,
          jsCoreBridge: _UnavailableBridge(),
          quickJsBridge: _UnavailableBridge(),
        ),
        throwsA(
          isA<SpiderException>()
              .having(
                (SpiderException e) => e.code,
                'code',
                SpiderErrorCode.unimplemented,
              )
              .having(
                (SpiderException e) => e.message,
                'message',
                contains('libvbox_quickjs'),
              ),
        ),
      );
    });

    test('createForJsSite：JS 站点主映射入口（B-05）', () {
      final SpiderEngine engine = factory.createForJsSite(
        jsCoreBridge: _FakeJsCoreBridge(),
        siteKey: 'js_演示',
      );
      expect(engine, isA<JsCoreBridgeEngine>());
      expect(engine.engineType, SpiderEngineType.javaScriptCore);
    });

    test('注入 fake 客户端：node 引擎 register + homeContent 走 /spider/{key}/3/home', () async {
      final _FakeNodeClient client = _FakeNodeClient(<NodeHttpResponse>[
        const NodeHttpResponse(
          statusCode: 200,
          body: '{"class":[{"type_id":"1","type_name":"电影"}],"list":[]}',
        ),
      ]);
      final SpiderEngine engine = factory.create(
        SpiderEngineType.node,
        nodeClient: client,
        siteKey: 'nodejs_hanxiaoquan',
        baseUrl: '',
        requestId: 'req-factory-1',
      );
      expect(engine, isA<NodeBridgeEngine>());
      await engine.registerSpider();
      expect(engine.isSpiderReady, isTrue);

      final dynamic home = await engine.callHomeContent();
      expect(home.classes, hasLength(1));
      expect(home.classes!.first.typeName, '电影');
      await engine.dispose();
    });
  });
}
