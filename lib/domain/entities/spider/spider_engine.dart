/// 领域层：Spider 引擎抽象接口。
///
/// 唯一真相源：`contract/docs/abi_v1.md` §2「统一接口签名」+ §5「错误处理」
/// 逆向来源：iOS `vbox/Services/SpiderEngineProtocol.swift`
library;

import 'engine_type.dart';
import 'spider_models.dart';

/// Spider 错误（对齐契约 §5.1 建议错误码）。
class SpiderException implements Exception {
  const SpiderException(this.code, this.message);

  /// 结构化错误码。
  final SpiderErrorCode code;
  final String message;

  @override
  String toString() => 'SpiderException[${code.name}]: $message';
}

/// 错误码（契约 §5.1 建议值）。
enum SpiderErrorCode {
  /// 注册失败（未找到 `__JS_SPIDER__`）。
  register,

  /// 脚本加载/解码失败。
  scriptLoad,

  /// 协议错误（JS 返回 nil / 结果编码无效）。
  protocol,

  /// 超时（契约 HTTP 默认 15s）。
  timeout,

  /// 运行时崩溃。
  runtime,

  /// 不支持（.jar 等）。
  unsupported,

  /// 未实现。
  unimplemented,
}

/// Spider 引擎接口（对齐 iOS `protocol SpiderEngineProtocol`）。
///
/// 生命周期：
/// ```
/// loadScript(script) → registerSpider() → isSpiderReady == true
///   → callHomeContent() / callSearchContent() / ...
/// ```
abstract class SpiderEngine {
  /// 引擎类型。
  SpiderEngineType get engineType;

  /// 日志回调（字符串流式，契约 §6）。
  set onLog(void Function(String)? handler);

  // ─────────────── 生命周期 ───────────────

  /// 加载蜘蛛脚本。
  Future<void> loadScript(String script);

  /// 加载库（不检查注册）。
  Future<void> loadLibrary(String script);

  /// 从 URL 加载脚本（契约：HTTP 默认 15s 超时）。
  Future<void> loadScriptFromURL(String urlString);

  /// 注册蜘蛛（契约 §5：检测 `typeof globalThis.__JS_SPIDER__ == object`）。
  Future<void> registerSpider();

  /// 是否已注册。
  bool get isSpiderReady;

  // ─────────────── 5 个操作 ───────────────

  /// 首页内容。
  Future<HomeContentResult> callHomeContent();

  /// 搜索内容。[pg] 从 1 开始。
  Future<SearchContentResult> callSearchContent(String keyword, int pg);

  /// 分类内容。
  Future<CategoryContentResult> callCategoryContent(
      String tid, int pg, String extend);

  /// 详情内容（[ids] 逗号分隔）。
  Future<DetailContentResult> callDetailContent(String ids);

  /// 播放内容。
  Future<PlayerContentResult> callPlayerContent(
      String vodId, String flag, String url);

  // ─────────────── 释放 ───────────────

  /// 释放引擎资源。
  Future<void> dispose();
}

/// 错误检测辅助（对齐契约 §5 的字符串前缀检测）。
class SpiderErrorDetector {
  SpiderErrorDetector._();

  static const List<String> _errorPrefixes = <String>[
    'Error',
    'TypeError',
    'ReferenceError',
    'SyntaxError',
  ];

  /// 返回字符串是否以 JS 错误前缀开头。
  static bool looksLikeError(String trimmed) {
    for (final String p in _errorPrefixes) {
      if (trimmed.startsWith(p)) return true;
    }
    return false;
  }

  /// 判断 `typeof globalThis.__JS_SPIDER__` 的返回值是否为 object。
  ///
  /// 契约：`result == "object" || result == "\"object\"" || 含 "object"`。
  static bool isRegistered(String evaluateResult) {
    final String r = evaluateResult.trim();
    if (r == 'object') return true;
    if (r == '"object"') return true;
    if (r.contains('object')) return true;
    return false;
  }
}
