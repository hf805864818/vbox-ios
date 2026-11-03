/// 平台层：Spider 引擎工厂（按引擎类型分派适配器，B-05 定稿）。
///
/// 对齐契约 §1「引擎类型」+ §1.1「引擎选择规则」+ D6（主方案 D31）：
/// - node / nodeLX → [NodeBridgeEngine]（HTTP 桥，58080 / 58083）
/// - python → [PythonBridgeEngine]（子进程 stdio ABI）
/// - javaScriptCore → [JsCoreBridgeEngine]（**JSC 主引擎**，D6）
/// - quickJS → [QuickJSBridgeEngine]（**降级备份**位）
/// - **D6 降级**：`javaScriptCore` 请求时 JSC 原生库不可用（`libvbox_jsc`
///   缺失 / 平台不支持）→ 自动降级 [QuickJSBridgeEngine]，**降级可观测**
///   （[onLog] 输出降级事件；JSC 与 QuickJS 均不可用 → `E_UNIMPLEMENTED`）
library;

import '../../domain/entities/spider/engine_type.dart';
import '../../domain/entities/spider/spider_engine.dart';
import '../runtime/jsc_bridge_engine.dart';
import '../runtime/jsc_ffi.dart';
import '../runtime/quickjs_bridge_engine.dart';
import '../runtime/quickjs_ffi.dart';
import 'node_bridge_engine.dart';
import 'node_http_client.dart';
import 'python_bridge_engine.dart';

/// Spider 引擎工厂。
class SpiderEngineFactory {
  /// 构造（可注入依赖便于测试）。
  const SpiderEngineFactory();

  /// 按引擎类型创建引擎适配器。
  ///
  /// [nodeClient] 可注入（测试用 fake）；缺省为本机 Node 进程客户端。
  /// [jsCoreBridge] / [quickJsBridge] 可注入（测试用 FFI mock）；
  /// 缺省为真实 FFI 加载器。
  /// [onLog] 接收引擎日志流（含 **D6 降级事件**，降级可观测的验收口径）。
  SpiderEngine create(
    SpiderEngineType type, {
    NodeHttpClient? nodeClient,
    QuickJsNativeBridge? quickJsBridge,
    JsCoreNativeBridge? jsCoreBridge,
    String? siteKey,
    String? baseUrl,
    String? requestId,
    void Function(String)? onLog,
  }) {
    switch (type) {
      case SpiderEngineType.node:
      case SpiderEngineType.nodeLX:
        return NodeBridgeEngine(
          engineType: type,
          client: nodeClient ??
              LocalNodeHttpClient(
                port: type == SpiderEngineType.nodeLX ? 58083 : 58080,
              ),
          siteKey: siteKey,
          baseUrl: baseUrl,
          requestId: requestId,
        );
      case SpiderEngineType.python:
        return _createPython(onLog);
      case SpiderEngineType.quickJS:
        return _createQuickJs(
          quickJsBridge: quickJsBridge,
          siteKey: siteKey,
          baseUrl: baseUrl,
          requestId: requestId,
          onLog: onLog,
        );
      case SpiderEngineType.javaScriptCore:
        return _createJsCore(
          quickJsBridge: quickJsBridge,
          jsCoreBridge: jsCoreBridge,
          siteKey: siteKey,
          baseUrl: baseUrl,
          requestId: requestId,
          onLog: onLog,
        );
    }
  }

  /// JS 引擎解析（B-05 映射核心，D6：JSC 主 / QuickJS 降级）。
  ///
  /// [ResolvedSiteMode.engineType] 给出 `javaScriptCore`（JS 站点主映射）时，
  /// 经本方法创建：JSC 可用 → JSC 主引擎；否则自动降级 QuickJS 且降级可观测。
  SpiderEngine createForJsSite({
    NodeHttpClient? nodeClient,
    QuickJsNativeBridge? quickJsBridge,
    JsCoreNativeBridge? jsCoreBridge,
    String? siteKey,
    String? baseUrl,
    String? requestId,
    void Function(String)? onLog,
  }) =>
      create(
        SpiderEngineType.javaScriptCore,
        nodeClient: nodeClient,
        quickJsBridge: quickJsBridge,
        jsCoreBridge: jsCoreBridge,
        siteKey: siteKey,
        baseUrl: baseUrl,
        requestId: requestId,
        onLog: onLog,
      );

  PythonBridgeEngine _createPython(void Function(String)? onLog) {
    final PythonBridgeEngine engine = PythonBridgeEngine();
    // ★ 对齐 iOS `PythonSpiderEngine.onLog`（SpiderManager.swift L1473-L1475：
    //   引擎日志写入 AppLogStore）。此前工厂未接 onLog → Python 桥的脚本
    //   traceback、桥启动异常、ABI 响应里的 logs 全部丢弃，日志页看不到
    //   py 源失败原因（诊断盲区）。
    engine.onLog = onLog;
    return engine;
  }

  QuickJSBridgeEngine _createQuickJs({
    required QuickJsNativeBridge? quickJsBridge,
    required String? siteKey,
    required String? baseUrl,
    required String? requestId,
    required void Function(String)? onLog,
  }) {
    final QuickJsNativeBridge bridge = quickJsBridge ?? DartFfiQuickJsBridge();
    if (!bridge.isAvailable) {
      throw const SpiderException(
        SpiderErrorCode.unimplemented,
        'QuickJS 原生库未打包（libvbox_quickjs 缺失，见 G-03-B 分发决策）',
      );
    }
    final QuickJSBridgeEngine engine = QuickJSBridgeEngine(
      bridge: bridge,
      siteKey: siteKey,
      baseUrl: baseUrl,
      requestId: requestId,
    );
    engine.onLog = onLog;
    return engine;
  }

  SpiderEngine _createJsCore({
    required QuickJsNativeBridge? quickJsBridge,
    required JsCoreNativeBridge? jsCoreBridge,
    required String? siteKey,
    required String? baseUrl,
    required String? requestId,
    required void Function(String)? onLog,
  }) {
    final JsCoreNativeBridge jsc = jsCoreBridge ?? DartFfiJsCoreBridge();
    if (jsc.isAvailable) {
      final JsCoreBridgeEngine engine = JsCoreBridgeEngine(
        bridge: jsc,
        siteKey: siteKey,
        baseUrl: baseUrl,
        requestId: requestId,
      );
      engine.onLog = onLog;
      return engine;
    }
    // D6 降级：JSC 不可用 → QuickJS 顶替（降级可观测）
    onLog?.call('⚠️ JSC 引擎不可用（libvbox_jsc 缺失），按 D6 自动降级 QuickJS');
    final QuickJSBridgeEngine fallback = _createQuickJs(
      quickJsBridge: quickJsBridge,
      siteKey: siteKey,
      baseUrl: baseUrl,
      requestId: requestId,
      onLog: onLog,
    );
    onLog?.call('✅ 已降级为 QuickJS 引擎（站点 $siteKey）');
    return fallback;
  }
}
