/// 平台层：QuickJS 桥接引擎（FFI 原生绑定，G-03-B-2）。
///
/// 对齐 iOS `QJSSpiderEngine`（`vbox/Services/QJSSpiderEngine.swift`）+ 契约 §2/§5：
/// - `loadScript` 经 `vq_eval` 执行脚本，Error 前缀 → `E_SCRIPT_LOAD`
/// - `registerSpider` 检测 `typeof globalThis.__JS_SPIDER__`（含 spider 兜底注册）
/// - 5 个操作：`__JS_SPIDER__.init(config)` 后调用 `__JS_SPIDER__.<op>(args)`，
///   返回值为字符串（JSON）或对象时分别处理（避免双重 JSON 编码，对齐 iOS 修复）
/// - 原生库不可用（`isAvailable == false`）→ `E_UNIMPLEMENTED`，未打包环境安全降级
/// - B-09：`loadScriptFromURL` 走 [SpiderHttpBridge]（5 级编码链 + iOS 默认 UA + cookie）
///
/// 测试：注入 fake [QuickJsNativeBridge]（FFI mock），无需真实动态库。
library;

import 'dart:async';
import 'dart:convert';

import '../../domain/entities/spider/engine_type.dart';
import '../../domain/entities/spider/spider_engine.dart';
import '../../domain/entities/spider/spider_models.dart';
import '../spider/spider_abi.dart';
import '../spider/spider_http_bridge.dart';
import '../spider/spider_js_globals.dart';
import 'quickjs_ffi.dart';

/// QuickJS 桥接引擎（实现 [SpiderEngine]）。
class QuickJSBridgeEngine implements SpiderEngine {
  /// [bridge] 可注入（测试用 fake；缺省为真实 FFI 加载器）。
  ///
  /// [asyncBridge] 可选注入（fake 模拟 worker 桥）；缺省按 [bridge] 自身
  /// 能力探测（`DartFfiQuickJsBridge` 同时实现 [QuickJsAsyncNativeBridge]，
  /// 符号缺失时运行时自动降级同步 eval）。
  QuickJSBridgeEngine({
    QuickJsNativeBridge? bridge,
    QuickJsAsyncNativeBridge? asyncBridge,
    SpiderAbiCodec? codec,
    this.siteKey,
    this.baseUrl,
    this.requestId,
    this.httpBridge,
  })  : _bridge = bridge ?? DartFfiQuickJsBridge(),
        _asyncBridge =
            asyncBridge ?? _detectAsyncBridge(bridge ?? DartFfiQuickJsBridge()),
        _codec = codec ?? const SpiderAbiCodec();

  static QuickJsAsyncNativeBridge? _detectAsyncBridge(Object bridge) =>
      bridge is QuickJsAsyncNativeBridge ? bridge : null;

  final QuickJsNativeBridge _bridge;

  /// 异步能力桥（worker 线程 eval + JS http() 宿主桥；null = 纯同步模式）。
  final QuickJsAsyncNativeBridge? _asyncBridge;
  final SpiderAbiCodec _codec;

  /// 站点键（init 配置 ctx.siteKey）。
  final String? siteKey;

  /// 站点脚本地址（init 配置 ctx.baseUrl）。
  final String? baseUrl;

  /// 请求追踪号（init 配置 ctx.requestId）。
  final String? requestId;

  /// HTTP 桥（B-09：loadScriptFromURL 脚本拉取走 5 级编码链 + iOS 默认 UA + cookie）。
  ///
  /// 注入实例生命周期归调用方；脚本内 `http()` 请求复用同一实例
  /// （注入实例归调用方，未注入时引擎自建 [_ownHttpBridge]、dispose 时关闭）。
  final SpiderHttpBridge? httpBridge;

  int _runtime = 0;
  int _context = 0;
  bool _registered = false;
  bool _inited = false;

  /// 宿主桥回调句柄（0 = 未注册；dispose 时关闭防 NativeCallable 泄漏）。
  int _hostBridgeHandle = 0;

  /// 待完成 eval 的 Completer（event 1 → complete）。
  Completer<String?>? _evalCompleter;

  /// 引擎自建 HTTP 桥（脚本 http() 用；注入 [httpBridge] 时不创建）。
  SpiderHttpBridge? _ownHttpBridge;

  @override
  void Function(String)? onLog;

  @override
  SpiderEngineType get engineType => SpiderEngineType.quickJS;

  // ─────────────── 生命周期 ───────────────

  @override
  Future<void> loadScript(String script) async {
    _ensureAvailable();
    await dispose();
    _runtime = _bridge.createRuntime();
    _context = _bridge.createContext(_runtime);
    if (_runtime == 0 || _context == 0) {
      throw const SpiderException(
        SpiderErrorCode.runtime,
        'QuickJS 运行时初始化失败（createRuntime/createContext 返回 0）',
      );
    }
    _registerHostBridge();
    // B-05a：JS 全局桥 prelude（console/print/atob/btoa/req/options 归一），
    // 先于用户脚本注入 —— 内置脚本零改动可跑。
    final String? preludeResult = await _evalAsync(SpiderJsGlobals.prelude());
    _checkScriptResult(preludeResult);
    final String? result = await _evalAsync(script);
    _checkScriptResult(result);
    // B-05a：console/print 真实输出 —— 顶层脚本日志取回接 onLog
    await _drainAndEmitLogs();
    onLog?.call('✅ QuickJS 脚本加载完成（${script.length} 字符）');
  }

  @override
  Future<void> loadLibrary(String script) async {
    _ensureAvailable();
    _ensureContext();
    final String? result = await _evalAsync(script);
    _checkScriptResult(result);
  }

  @override
  Future<void> loadScriptFromURL(String urlString) async {
    _ensureAvailable();
    // B-09：脚本拉取走 HTTP 桥（契约 §4.2 编码链 + iOS 默认 UA + cookie）。
    // 注入桥生命周期归调用方；缺省临时创建、用后即关（不泄漏 HttpClient）。
    final SpiderHttpBridge bridge = httpBridge ?? SpiderHttpBridge();
    final bool owned = httpBridge == null;
    try {
      final SpiderHttpResult res = await bridge.request(urlString);
      if (res.status == 0) {
        // 网络失败 / 超时（content 为原因描述：请求超时 / socket 错误）
        throw SpiderException(
          SpiderErrorCode.scriptLoad,
          '从 URL 加载脚本失败（${res.content}）: $urlString',
        );
      }
      if (res.status != 200) {
        throw SpiderException(
          SpiderErrorCode.scriptLoad,
          '无法从 URL 加载脚本（HTTP ${res.status}）: $urlString',
        );
      }
      await loadScript(res.content);
    } finally {
      if (owned) {
        await bridge.close();
      }
    }
  }

  @override
  Future<void> registerSpider() async {
    _ensureAvailable();
    _ensureContext();
    // 对齐 iOS JSSpiderEngine.registerSpider：spider → __JS_SPIDER__ 兜底注册
    const String script = r'''
      if (typeof globalThis.__JS_SPIDER__ === 'undefined') {
        if (typeof spider !== 'undefined') {
          if (typeof spider.__jsEvalReturn === 'function') {
            globalThis.__JS_SPIDER__ = spider.__jsEvalReturn();
          } else if (typeof spider.default === 'function') {
            globalThis.__JS_SPIDER__ = spider.default();
          } else {
            globalThis.__JS_SPIDER__ = spider;
          }
          if (globalThis.__JS_SPIDER__) {
            globalThis.__JS_SPIDER__.is_cat = true;
          }
        }
      }
    ''';
    await _evalAsync(script);
    // 对齐 QJSSpiderEngine.registerSpider：单独检测 typeof（契约 §5）
    final String? result =
        await _evalAsync('typeof globalThis.__JS_SPIDER__');
    if (SpiderErrorDetector.isRegistered(result ?? '')) {
      _registered = true;
      onLog?.call('✅ QuickJS 蜘蛛已注册到 globalThis.__JS_SPIDER__');
    } else {
      throw const SpiderException(
        SpiderErrorCode.register,
        'QuickJS 蜘蛛注册失败: 未找到 __JS_SPIDER__',
      );
    }
  }

  @override
  bool get isSpiderReady => _registered && _context != 0;

  // ─────────────── 5 个操作 ───────────────

  @override
  Future<HomeContentResult> callHomeContent() =>
      _callSpiderApi<HomeContentResult>(
        apiName: 'homeContent',
        args: const <String>[],
        parse: HomeContentResult.fromJson,
      );

  @override
  Future<SearchContentResult> callSearchContent(String keyword, int pg) =>
      _callSpiderApi<SearchContentResult>(
        // 对齐 iOS：TVBox 标准签名 searchContent(keyword, quickSearch, pg)
        apiName: 'searchContent',
        args: <String>[keyword, 'false', '$pg'],
        parse: SearchContentResult.fromJson,
      );

  @override
  Future<CategoryContentResult> callCategoryContent(
          String tid, int pg, String extend) =>
      _callSpiderApi<CategoryContentResult>(
        apiName: 'categoryContent',
        args: <String>[tid, '$pg', extend],
        parse: CategoryContentResult.fromJson,
      );

  @override
  Future<DetailContentResult> callDetailContent(String ids) =>
      _callSpiderApi<DetailContentResult>(
        apiName: 'detailContent',
        args: <String>[ids],
        parse: DetailContentResult.fromJson,
      );

  @override
  Future<PlayerContentResult> callPlayerContent(
          String vodId, String flag, String url) =>
      _callSpiderApi<PlayerContentResult>(
        apiName: 'playerContent',
        args: <String>[vodId, flag, url],
        parse: PlayerContentResult.fromJson,
      );

  @override
  Future<void> dispose() async {
    _closeHostBridge();
    if (_context != 0) {
      _bridge.freeContext(_context);
      _context = 0;
    }
    if (_runtime != 0) {
      _bridge.freeRuntime(_runtime);
      _runtime = 0;
    }
    // pending eval 随 runtime 释放作废（event 1 不再来，completer 直接丢弃）
    _evalCompleter = null;
    _registered = false;
    _inited = false;
    // 关闭引擎自建 HTTP 桥（注入实例生命周期归调用方，不动）
    final SpiderHttpBridge? own = _ownHttpBridge;
    _ownHttpBridge = null;
    await own?.close();
  }

  // ─────────────── 内部 ───────────────

  void _ensureAvailable() {
    if (!_bridge.isAvailable) {
      throw const SpiderException(
        SpiderErrorCode.unimplemented,
        'QuickJS 原生库未打包（libvbox_quickjs 缺失，见 G-03-B 分发决策）',
      );
    }
  }

  void _ensureContext() {
    if (_context == 0) {
      _runtime = _bridge.createRuntime();
      _context = _bridge.createContext(_runtime);
      if (_runtime == 0 || _context == 0) {
        throw const SpiderException(
          SpiderErrorCode.runtime,
          'QuickJS 运行时初始化失败',
        );
      }
      _registerHostBridge();
    }
  }

  // ─────────────── G-03-B-3：worker 桥接（eval 异步提交 + JS http() 宿主桥） ──

  /// 注册宿主回调（runtime 创建后调用一次；重复调用先关旧句柄）。
  void _registerHostBridge() {
    final QuickJsAsyncNativeBridge? ab = _asyncBridge;
    if (ab == null || _runtime == 0) return;
    _closeHostBridge();
    _hostBridgeHandle = ab.setHostBridge(_runtime, _onHostEvent);
  }

  void _closeHostBridge() {
    if (_hostBridgeHandle != 0) {
      _asyncBridge?.closeHostBridge(_hostBridgeHandle);
      _hostBridgeHandle = 0;
    }
  }

  /// 宿主事件分发（isolate 事件循环执行）。
  void _onHostEvent(int event, int reqId, String url, String optionsJson) {
    if (event == 1) {
      // eval 完成：先同步取走结果，再 complete（避免竞态）
      final String? result = _asyncBridge?.evalTakeResult(_runtime);
      final Completer<String?>? completer = _evalCompleter;
      _evalCompleter = null;
      if (completer != null && !completer.isCompleted) {
        completer.complete(result);
      }
    } else if (event == 2) {
      // 脚本 http(url, options)：异步执行后回写（worker 阻塞等待）
      _performJsHttp(reqId, url, optionsJson);
    }
  }

  /// eval 统一入口：异步桥可用则提交 worker 线程（脚本可同步 http()），
  /// 否则回退同步 eval（旧语义：http() 不可用）。
  Future<String?> _evalAsync(String script) async {
    final QuickJsAsyncNativeBridge? ab = _asyncBridge;
    if (ab != null && _hostBridgeHandle != 0 && ab.evalSubmit(_runtime, script)) {
      final Completer<String?> completer = Completer<String?>();
      _evalCompleter = completer;
      return completer.future.timeout(
        const Duration(seconds: 60),
        onTimeout: () {
          _evalCompleter = null;
          throw const SpiderException(
            SpiderErrorCode.runtime,
            'QuickJS eval 超时（worker 桥等待上限，疑似脚本挂死）',
          );
        },
      );
    }
    return _bridge.eval(_context, script);
  }

  /// 脚本 `http(url, options)` 的 Dart 执行与回写。
  ///
  /// 结果形状对齐 iOS JSSpiderEngine 字典返回：
  /// `{ok,status,content,url,headers,error}`（脚本消费 resp.status/resp.content/resp.ok）。
  Future<void> _performJsHttp(
      int reqId, String url, String optionsJson) async {
    Map<String, Object?>? opts;
    if (optionsJson.isNotEmpty) {
      try {
        final Object? decoded = jsonDecode(optionsJson);
        if (decoded is Map<String, Object?>) opts = decoded;
      } on FormatException {
        opts = null; // options 非 JSON → 默认 GET（对齐 iOS as? 容错）
      }
    }
    // 注入桥优先（归调用方）；未注入用引擎自建桥（懒创建，dispose 关闭）
    final SpiderHttpBridge bridge =
        httpBridge ?? (_ownHttpBridge ??= SpiderHttpBridge());
    SpiderHttpResult res;
    try {
      res = await bridge.request(url, options: SpiderHttpOptions.fromMap(opts));
    } catch (e) {
      res = SpiderHttpResult.failure(url, '请求失败: $e');
    }
    final String responseJson = jsonEncode(<String, Object?>{
      'ok': res.ok,
      'status': res.status,
      'content': res.content,
      'url': res.url,
      'headers': res.headers,
      'error': res.ok
          ? ''
          : (res.status == 0 ? res.content : 'HTTP ${res.status}'),
    });
    _asyncBridge?.httpComplete(_runtime, reqId, responseJson);
  }

  /// 契约 §5 错误检测：Error / TypeError / ReferenceError / SyntaxError 前缀。
  void _checkScriptResult(String? result) {
    if (result == null || result.isEmpty) return;
    final String trimmed = result.trim();
    if (SpiderErrorDetector.looksLikeError(trimmed)) {
      throw SpiderException(
        SpiderErrorCode.scriptLoad,
        'JS 异常: $trimmed',
      );
    }
  }

  String _quote(String s) => "'${s.replaceAll("'", "\\'")}'";

  /// init 配置（对齐 iOS callInit(config:) —— 传给 `__JS_SPIDER__.init`）。
  String _initConfigJson() =>
      jsonEncode(_codec.encodeRequest(
        'init',
        const <String, Object?>{},
        siteKey: siteKey,
        engineType: engineType.rawValue,
        baseUrl: baseUrl,
        requestId: requestId,
      ));

  Future<T> _callSpiderApi<T>({
    required String apiName,
    required List<String> args,
    required T Function(Map<String, Object?>) parse,
  }) async {
    _ensureAvailable();
    if (_context == 0 || !_registered) {
      throw const SpiderException(
        SpiderErrorCode.register,
        'QuickJS 引擎未就绪：请先 loadScript + registerSpider',
      );
    }
    if (!_inited) {
      // init 只调用一次（对齐 iOS：引擎创建后 callInit 一次）
      await _evalAsync(
          'globalThis.__JS_SPIDER__.init(${_initConfigJson()})');
      _inited = true;
    }
    final String escapedArgs = args.map(_quote).join(', ');
    // 包装：返回值可能是字符串（已是 JSON）或对象 → 统一 JSON.stringify 编码，
    // 避免对字符串重复编码（对齐 iOS callSpiderMethod 的修复）。
    final String script =
        'JSON.stringify((function(){'
        'var __r = globalThis.__JS_SPIDER__.$apiName($escapedArgs);'
        "if (typeof __r === 'string') { return {__type: 'string', __value: __r}; }"
        "return {__type: 'object', __value: __r};"
        '})())';
    final String? raw = await _evalAsync(script);
    // B-05a：本次操作期间脚本 console/print 输出接日志
    await _drainAndEmitLogs();
    if (raw == null || raw.isEmpty) {
      throw SpiderException(
        SpiderErrorCode.protocol,
        '$apiName 返回无效（JS 返回 nil）',
      );
    }
    final String trimmed = raw.trim();
    if (SpiderErrorDetector.looksLikeError(trimmed)) {
      throw SpiderException(
        SpiderErrorCode.runtime,
        '$apiName 运行时异常: $trimmed',
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      throw SpiderException(
        SpiderErrorCode.protocol,
        '$apiName 结果编码无效（非 JSON）',
      );
    }
    if (decoded is! Map<String, Object?>) {
      throw SpiderException(
        SpiderErrorCode.protocol,
        '$apiName 结果编码无效（非 JSON 包装）',
      );
    }
    final Object? value = decoded['__value'];
    final Map<String, Object?> data;
    if (decoded['__type'] == 'string' && value is String) {
      final Object? inner;
      try {
        inner = jsonDecode(value);
      } on FormatException {
        throw SpiderException(
          SpiderErrorCode.protocol,
          '$apiName 返回字符串非 JSON',
        );
      }
      if (inner is! Map<String, Object?>) {
        throw SpiderException(
          SpiderErrorCode.protocol,
          '$apiName 返回字符串非 JSON 对象',
        );
      }
      data = inner;
    } else if (decoded['__type'] == 'object' && value is Map) {
      data = value.cast<String, Object?>();
    } else {
      throw SpiderException(
        SpiderErrorCode.protocol,
        '$apiName 结果编码无效（__type 未知）',
      );
    }
    return parse(data);
  }

  // ─────────────── B-05a：JS 全局桥 + 日志取回 ───────────────

  /// 取回 JS 缓冲日志（`console`/`print` 真实输出，经 `__vboxLogs` 缓冲）
  /// 并逐条转发到 [onLog]。
  ///
  /// 无上下文（未 loadScript / 已 dispose）时安全返回空列表；
  /// `loadScript` / 5 个操作内部已自动调用，本方法供调用方按需手动取回。
  Future<List<String>> drainJsLogs() async {
    _ensureAvailable();
    if (_context == 0) return const <String>[];
    final String? raw =
        await _evalAsync(SpiderJsGlobals.drainLogsScript());
    final List<String> logs = SpiderJsGlobals.parseLogs(raw ?? '');
    for (final String line in logs) {
      onLog?.call('JS $line');
    }
    return logs;
  }

  Future<void> _drainAndEmitLogs() => drainJsLogs();
}
