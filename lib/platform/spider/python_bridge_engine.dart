/// 平台层：Python 桥接引擎（常驻脚本 + 逐行 JSON ABI）。
///
/// 对齐 iOS `PythonSpiderEngine` 的脚本执行语义：`loadScript` 载入脚本后，宿主逐行写
/// ABI 请求、逐行读 ABI 响应（`contract/docs/abi_v1.md` §7）。**宿主**由 [PythonRuntime]
/// 抽象承载，按平台分派（Wave G · RT-运1）：
///  - 桌面 / 测试 → `python3 -u <bridge> <script>` 常驻子进程（stdio）；`<bridge>`
///    为桥接垫片（S1/S3），负责 `exec` 用户脚本并以对象调用驱动（对齐 iOS/Android）；
///  - Android → Chaquopy 进程内解释器（Android 无 `python3` 可执行文件）。
///
/// 测试：使用 `conformance/fixtures/python_spider_class.py`（真实 `Spider` 类脚本，
/// 真实 python3 子进程），不可用时（环境无 python3）跳过，不破坏门禁全绿。
library;

import 'dart:convert';

import '../../domain/entities/spider/engine_type.dart';
import '../../domain/entities/spider/spider_engine.dart';
import '../../domain/entities/spider/spider_models.dart';
import 'python_runtime.dart';
import 'spider_abi.dart';
import 'spider_http_bridge.dart';

/// Python 桥接引擎（实现 [SpiderEngine]）。
class PythonBridgeEngine implements SpiderEngine {
  /// [pythonExecutable] 仅对子进程运行时生效（Android 走 Chaquopy，忽略该值）。
  /// [runtime] 可注入（测试用 fake / 指定宿主）。
  /// [httpBridge] 脚本拉取桥（[loadScriptFromURL] 用）；注入实例生命周期归
  /// 调用方，缺省按需临时创建、用后即关。
  /// 超时缺省 20s：对齐 iOS `PythonSpiderEngine.withPythonTimeout`（注册与
  /// 各方法调用统一 20s；真实 py 源在弱网下抓取较慢，15s 偏紧）。
  PythonBridgeEngine({
    String pythonExecutable = 'python3',
    SpiderAbiCodec? codec,
    this.timeout = const Duration(seconds: 20),
    PythonRuntime? runtime,
    SpiderHttpBridge? httpBridge,
  })  : _codec = codec ?? const SpiderAbiCodec(),
        _runtime = runtime ??
            PythonRuntime.forCurrentPlatform(
              pythonExecutable: pythonExecutable,
              timeout: timeout,
            ),
        _httpBridge = httpBridge;

  final Duration timeout;
  final SpiderAbiCodec _codec;
  final PythonRuntime _runtime;
  final SpiderHttpBridge? _httpBridge;

  bool _ready = false;

  @override
  void Function(String)? onLog;

  /// 平台适配：桥接引擎统一为 python 类型（无 python 枚举以外的细分）。
  @override
  SpiderEngineType get engineType => SpiderEngineType.python;

  // ─────────────── 生命周期 ───────────────

  @override
  Future<void> loadScript(String script) async {
    await _runtime.shutdown();
    _ready = false;
    _runtime.onLog = onLog;
    await _runtime.launch(script);
    _ready = true;
    onLog?.call('Python 桥：脚本加载完成（${_runtime.runtimeLabel}）');
  }

  @override
  Future<void> loadLibrary(String script) async {}

  @override
  Future<void> loadScriptFromURL(String urlString) async {
    // 对齐 iOS `PythonSpiderEngine.loadScriptFromURL`
    // （PythonSpiderEngine.swift L127-L132）：URLSession 下载脚本 → 交给
    // 宿主加载。此处经 SpiderHttpBridge（契约 §4.2 编码链 + iOS 默认 UA）
    // 拉取内容后走 [loadScript]，避免「仅支持本地脚本」的端差异。
    final SpiderHttpBridge bridge = _httpBridge ?? SpiderHttpBridge();
    final bool owned = _httpBridge == null;
    try {
      final SpiderHttpResult res = await bridge.request(urlString);
      if (res.status == 0) {
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
      if (res.content.trim().isEmpty) {
        throw SpiderException(
          SpiderErrorCode.scriptLoad,
          '从 URL 加载脚本失败（响应为空）: $urlString',
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
    // Python 桥视脚本 ABI 循环就绪即已注册
    _ready = true;
  }

  @override
  bool get isSpiderReady => _ready;

  // ─────────────── 5 个操作 ───────────────

  @override
  Future<HomeContentResult> callHomeContent() => _roundTrip<HomeContentResult>(
        op: 'homeContent',
        params: const <String, Object?>{},
        parse: HomeContentResult.fromJson,
      );

  @override
  Future<SearchContentResult> callSearchContent(String keyword, int pg) =>
      _roundTrip<SearchContentResult>(
        op: 'searchContent',
        params: <String, Object?>{'keyword': keyword, 'pg': pg},
        parse: SearchContentResult.fromJson,
      );

  @override
  Future<CategoryContentResult> callCategoryContent(
          String tid, int pg, String extend) =>
      _roundTrip<CategoryContentResult>(
        op: 'categoryContent',
        params: <String, Object?>{'tid': tid, 'pg': pg, 'extend': extend},
        parse: CategoryContentResult.fromJson,
      );

  @override
  Future<DetailContentResult> callDetailContent(String ids) =>
      _roundTrip<DetailContentResult>(
        op: 'detailContent',
        params: <String, Object?>{'ids': ids},
        parse: DetailContentResult.fromJson,
      );

  @override
  Future<PlayerContentResult> callPlayerContent(
          String vodId, String flag, String url) =>
      _roundTrip<PlayerContentResult>(
        op: 'playerContent',
        params: <String, Object?>{'vodId': vodId, 'flag': flag, 'url': url},
        parse: PlayerContentResult.fromJson,
      );

  @override
  Future<void> dispose() async {
    _ready = false;
    await _runtime.shutdown();
  }

  // ─────────────── 内部 ───────────────

  Future<T> _roundTrip<T>({
    required String op,
    required Map<String, Object?> params,
    required T Function(Map<String, Object?>) parse,
  }) async {
    if (!_ready) {
      throw const SpiderException(
        SpiderErrorCode.register,
        'Python 桥未就绪：请先 loadScript + registerSpider',
      );
    }
    final Map<String, Object?> req = _codec.encodeRequest(op, params);
    final String line = await _runtime.roundTrip(jsonEncode(req));
    final AbiResponse r = _codec.decodeResponse(line);
    for (final String log in r.logs) {
      onLog?.call(log);
    }
    return parse(r.data ?? const <String, Object?>{});
  }
}
