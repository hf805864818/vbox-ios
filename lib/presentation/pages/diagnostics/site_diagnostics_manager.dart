/// 表现层：站点诊断管理器（批次 G · G-08）。
///
/// 唯一真相源：iOS `vbox/Services/SiteDiagnostics.swift`（264 行）
///   · `SiteDiagnosticResult` / `SiteStatus` / `DiagnosticSummary` / `SiteDiagnosticsManager`
///   · `diagnoseSite(_:)` 判定链（type 0/1/2/3 + searchable==0 覆盖）
///   · `testEngineCompatibility` 双引擎语法测试
///
/// 差异登记（对齐 iOS 语义，非偏离）：
/// - iOS `SpiderManager.engines` 为注册表（引擎实例已存在）；Flutter 侧引擎按需创建
///   （`SpiderEngineFactory.create` / 直接 `JsCoreBridgeEngine` / `QuickJSBridgeEngine`），
///   故诊断时**临时创建引擎**做 `loadScript` 语法测试，用后即弃。
/// - type 2（站源）在 Flutter 侧为内置解析（`SiteMode.zhanyuan`，`resolveEngineType()`
///   返回 null），无外部引擎依赖，视为始终就绪。
/// - `searchable` 字段类型：iOS 为 `Int?`（`== 0` 判定）；Flutter `SiteConfig.searchable`
///   同为 `int?`，逐字对齐。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../domain/entities/spider/site_config.dart';
import '../../../domain/entities/spider/spider_engine.dart';
import '../../../domain/entities/spider/engine_type.dart';
import '../../../platform/runtime/jsc_bridge_engine.dart';
import '../../../platform/runtime/quickjs_bridge_engine.dart';
import '../../../platform/runtime/jsc_ffi.dart';
import '../../../platform/runtime/quickjs_ffi.dart';
import '../../../core/network/http_client.dart';

// ───────────────────────────────────────────────
// 枚举与模型（对齐 iOS SiteStatus / SiteDiagnosticResult / DiagnosticSummary）
// ───────────────────────────────────────────────

/// 诊断状态（对齐 iOS `enum SiteStatus` 11 值）。
enum SiteDiagnosticStatus {
  loaded,
  engineReady,
  apiOnly,
  noApi,
  downloadFailed,
  invalidContent,
  registerFailed,
  unknown,
  skipped,
  jscOnly,
  qjsOnly,
}

/// 状态对应的 emoji 图标（对齐 iOS `SiteStatus.icon`）。
const Map<SiteDiagnosticStatus, String> _statusIcon = <SiteDiagnosticStatus, String>{
  SiteDiagnosticStatus.loaded: '✅',
  SiteDiagnosticStatus.engineReady: '📡',
  SiteDiagnosticStatus.apiOnly: '🌐',
  SiteDiagnosticStatus.noApi: '❌',
  SiteDiagnosticStatus.downloadFailed: '📄',
  SiteDiagnosticStatus.invalidContent: '🔧',
  SiteDiagnosticStatus.registerFailed: '❓',
  SiteDiagnosticStatus.unknown: '⏭️',
  SiteDiagnosticStatus.skipped: '⏭️',
  SiteDiagnosticStatus.jscOnly: '🍎',
  SiteDiagnosticStatus.qjsOnly: '⚡',
};

/// 状态对应的中文标题（对齐 iOS `SiteStatus.rawValue`）。
const Map<SiteDiagnosticStatus, String> _statusTitle = <SiteDiagnosticStatus, String>{
  SiteDiagnosticStatus.loaded: '已加载',
  SiteDiagnosticStatus.engineReady: '引擎就绪',
  SiteDiagnosticStatus.apiOnly: '仅API',
  SiteDiagnosticStatus.noApi: '无API地址',
  SiteDiagnosticStatus.downloadFailed: '下载失败',
  SiteDiagnosticStatus.invalidContent: '内容无效',
  SiteDiagnosticStatus.registerFailed: '注册失败',
  SiteDiagnosticStatus.unknown: '未知',
  SiteDiagnosticStatus.skipped: '已跳过',
  SiteDiagnosticStatus.jscOnly: '仅JSC兼容',
  SiteDiagnosticStatus.qjsOnly: '仅QJS兼容',
};

/// 状态的展示属性（对齐 iOS `SiteStatus.icon` / `rawValue`）。
extension SiteDiagnosticStatusDisplay on SiteDiagnosticStatus {
  /// emoji 图标（逐字保留 iOS 取值）。
  String get icon => _statusIcon[this] ?? '❓';

  /// 中文标题。
  String get title => _statusTitle[this] ?? '未知';
}

/// 单站点诊断结果（对齐 iOS `SiteDiagnosticResult`）。
class SiteDiagnosticResult {
  SiteDiagnosticResult({
    required this.siteKey,
    required this.siteName,
    required this.type,
    required this.api,
    this.searchable,
    required this.status,
    this.errorMessage,
    this.engineLoaded = false,
    this.canSearch = false,
    this.engineType,
    this.jscCompatible = false,
    this.qjsCompatible = false,
  });

  final String siteKey;
  final String siteName;
  final int type;
  final String api;
  final int? searchable;
  SiteDiagnosticStatus status;
  String? errorMessage;
  bool engineLoaded;
  bool canSearch;
  SpiderEngineType? engineType;
  bool jscCompatible;
  bool qjsCompatible;
}

/// 诊断摘要（对齐 iOS `DiagnosticSummary`）。
class DiagnosticSummary {
  const DiagnosticSummary({
    required this.total,
    required this.engineReady,
    required this.apiOnly,
    required this.failed,
    required this.skipped,
    required this.searchableCount,
    required this.jscCount,
    required this.qjsCount,
  });

  final int total;
  final int engineReady;
  final int apiOnly;
  final int failed;
  final int skipped;
  final int searchableCount;
  final int jscCount;
  final int qjsCount;
}

// ───────────────────────────────────────────────
// 管理器（对齐 iOS SiteDiagnosticsManager）
// ───────────────────────────────────────────────

/// 站点诊断管理器（`ChangeNotifier`，UI `ListenableBuilder` 消费）。
class SiteDiagnosticsManager extends ChangeNotifier {
  SiteDiagnosticsManager({
    HttpClient? httpClient,
    JsCoreNativeBridge? jscBridge,
    QuickJsNativeBridge? qjsBridge,
  }) : _httpClient = httpClient ??
        HttpClient(
          receiveTimeout: const Duration(seconds: 10),
          maxRetries: 0,
        ),
      _jscBridge = jscBridge,
      _qjsBridge = qjsBridge;

  final HttpClient _httpClient;
  final JsCoreNativeBridge? _jscBridge;
  final QuickJsNativeBridge? _qjsBridge;

  List<SiteDiagnosticResult> _results = <SiteDiagnosticResult>[];
  bool _isDiagnosing = false;

  /// 诊断结果列表。
  List<SiteDiagnosticResult> get results => List<SiteDiagnosticResult>.unmodifiable(_results);

  /// 是否正在诊断。
  bool get isDiagnosing => _isDiagnosing;

  /// 摘要。
  DiagnosticSummary get summary => _computeSummary();

  /// 对全部站点执行诊断（对齐 iOS `diagnoseAll`）。
  Future<void> diagnoseAll(List<SiteConfig> sites) async {
    _isDiagnosing = true;
    _results = <SiteDiagnosticResult>[];
    notifyListeners();

    final List<SiteDiagnosticResult> results = <SiteDiagnosticResult>[];
    for (final SiteConfig site in sites) {
      final SiteDiagnosticResult result = await _diagnoseSite(site);
      results.add(result);
    }

    _results = results;
    _isDiagnosing = false;
    notifyListeners();
  }

  // ── 单站点判定链（对齐 iOS `diagnoseSite`）───────────────────────

  Future<SiteDiagnosticResult> _diagnoseSite(SiteConfig site) async {
    final SiteDiagnosticResult result = SiteDiagnosticResult(
      siteKey: site.key,
      siteName: site.name,
      type: site.type,
      api: site.api ?? '',
      searchable: site.searchable,
      status: SiteDiagnosticStatus.unknown,
      errorMessage: null,
      engineLoaded: false,
      // 对齐 iOS `diagnoseSite`：`canSearch` 初值 false，仅由各分支显式置位。
      canSearch: false,
      engineType: null,
      jscCompatible: false,
      qjsCompatible: false,
    );

    switch (site.type) {
      case 0:
      case 1:
        _diagnoseApiType(site, result);
        break;

      case 2:
        _diagnoseZhanyuanType(site, result);
        break;

      case 3:
        await _diagnoseSpiderType(site, result);
        break;

      default:
        result.status = SiteDiagnosticStatus.unknown;
        result.errorMessage = '未知类型 type=${site.type}';
        result.canSearch = false;
    }

    // searchable==0 覆盖（对齐 iOS 末尾覆盖逻辑）
    if (result.searchable == 0) {
      result.canSearch = false;
      if (result.errorMessage != null && result.errorMessage!.isNotEmpty) {
        result.errorMessage = '${result.errorMessage} [searchable=0，已禁用搜索]';
      } else {
        result.errorMessage = '[searchable=0，已禁用搜索]';
      }
    }

    return result;
  }

  /// type 0/1：API 端点（对齐 iOS case 0/1）。
  void _diagnoseApiType(SiteConfig site, SiteDiagnosticResult result) {
    final String api = site.api ?? '';
    if (api.isNotEmpty && (api.startsWith('http://') || api.startsWith('https://'))) {
      result.status = SiteDiagnosticStatus.apiOnly;
      result.canSearch = true;
    } else {
      result.status = SiteDiagnosticStatus.noApi;
      result.errorMessage = 'API地址为空或无效';
      result.canSearch = false;
    }
  }

  /// type 2：站源（对齐 iOS case 2）。
  ///
  /// Flutter 侧 type 2 对应 `SiteMode.zhanyuan`，`resolveEngineType()` 返回 null，
  /// 为内置解析（无外部引擎依赖），视为始终就绪。
  void _diagnoseZhanyuanType(SiteConfig site, SiteDiagnosticResult result) {
    result.status = SiteDiagnosticStatus.engineReady;
    result.engineLoaded = true;
    result.canSearch = true;
  }

  /// type 3：JS 蜘蛛（对齐 iOS case 3）。
  Future<void> _diagnoseSpiderType(SiteConfig site, SiteDiagnosticResult result) async {
    final String api = site.api ?? '';

    // api 非 http/https 校验
    if (api.isEmpty) {
      result.status = SiteDiagnosticStatus.noApi;
      result.errorMessage = 'api 字段为空';
      result.canSearch = false;
      return;
    }
    if (!api.startsWith('http://') && !api.startsWith('https://')) {
      result.status = SiteDiagnosticStatus.noApi;
      result.errorMessage = 'api 不是 http/https URL: $api';
      result.canSearch = false;
      return;
    }

    // 下载脚本（对齐 iOS 10s 超时 + 非200判定）
    final HttpClientResponse download;
    try {
      download = await _httpClient.get(Uri.parse(api));
    } catch (e) {
      result.status = SiteDiagnosticStatus.downloadFailed;
      result.errorMessage = '下载失败: $e';
      result.canSearch = false;
      return;
    }

    if (download.statusCode != 200) {
      result.status = SiteDiagnosticStatus.downloadFailed;
      result.errorMessage = 'HTTP ${download.statusCode}，无法下载 JS 脚本';
      result.canSearch = false;
      return;
    }

    final String script = download.text;

    // 长度校验（对齐 iOS <200 字符）
    if (script.length < 200) {
      result.status = SiteDiagnosticStatus.invalidContent;
      result.errorMessage = 'JS 代码太短(${script.length}字符)，可能不包含完整爬虫逻辑';
      result.canSearch = false;
      return;
    }

    // 关键字校验（对齐 iOS function/spider）
    if (!script.contains('function ') && !script.contains('spider')) {
      result.status = SiteDiagnosticStatus.invalidContent;
      result.errorMessage = '内容不包含 function/spider 关键字，可能不是有效的 JS 爬虫脚本';
      result.canSearch = false;
      return;
    }

    // 双引擎语法测试（对齐 iOS testEngineCompatibility）
    final (bool, String?) jscResult = await _testEngineCompatibility(
      SpiderEngineType.javaScriptCore,
      script,
    );
    final (bool, String?) qjsResult = await _testEngineCompatibility(
      SpiderEngineType.quickJS,
      script,
    );

    if (jscResult.$1 && qjsResult.$1) {
      result.status = SiteDiagnosticStatus.registerFailed;
      result.errorMessage =
          'JSC 和 QuickJS 都能解析该脚本，但运行时注册失败（可能缺少依赖库如 cheerio/模板.js）';
    } else if (jscResult.$1) {
      result.status = SiteDiagnosticStatus.jscOnly;
      result.errorMessage =
          '仅 JSC 兼容，QuickJS 失败: ${qjsResult.$2 ?? "未知错误"}';
      result.jscCompatible = true;
      result.engineType = SpiderEngineType.javaScriptCore;
    } else if (qjsResult.$1) {
      result.status = SiteDiagnosticStatus.qjsOnly;
      result.errorMessage =
          '仅 QuickJS 兼容，JSC 失败: ${jscResult.$2 ?? "未知错误"}';
      result.qjsCompatible = true;
      result.engineType = SpiderEngineType.quickJS;
    } else {
      result.status = SiteDiagnosticStatus.registerFailed;
      result.errorMessage =
          'JSC 失败: ${jscResult.$2 ?? "未知错误"} | QuickJS 失败: ${qjsResult.$2 ?? "未知错误"}';
    }
  }

  // ── 双引擎语法测试（对齐 iOS testEngineCompatibility）─────────────

  Future<(bool, String?)> _testEngineCompatibility(
    SpiderEngineType engineType,
    String script,
  ) async {
    final SpiderEngine engine;
    try {
      engine = _createTestEngine(engineType);
    } catch (e) {
      return (false, e.toString());
    }

    try {
      await engine.loadScript(script);

      // 脚本需导出 __JS_SPIDER__（或含 function spider / var spider）
      if (script.contains('__JS_SPIDER__') ||
          script.contains('function spider') ||
          script.contains('var spider')) {
        return (true, null);
      }
      return (false, '脚本缺少 __JS_SPIDER__ 导出');
    } catch (e) {
      return (false, e.toString());
    } finally {
      engine.dispose();
    }
  }

  /// 创建测试用引擎（可注入 fake bridge）。
  SpiderEngine _createTestEngine(SpiderEngineType type) {
    switch (type) {
      case SpiderEngineType.javaScriptCore:
        return JsCoreBridgeEngine(bridge: _jscBridge);
      case SpiderEngineType.quickJS:
        return QuickJSBridgeEngine(bridge: _qjsBridge);
      case SpiderEngineType.node:
      case SpiderEngineType.nodeLX:
      case SpiderEngineType.python:
        throw SpiderException(
          SpiderErrorCode.unimplemented,
          '诊断不支持引擎类型: $type',
        );
    }
  }

  // ── 摘要计算（对齐 iOS DiagnosticSummary）───────────────────────

  DiagnosticSummary _computeSummary() {
    final int total = _results.length;
    final int engineReady = _results
        .where((SiteDiagnosticResult r) => r.status == SiteDiagnosticStatus.engineReady)
        .length;
    final int apiOnly = _results
        .where((SiteDiagnosticResult r) => r.status == SiteDiagnosticStatus.apiOnly)
        .length;
    final int failed = _results
        .where((SiteDiagnosticResult r) => const <SiteDiagnosticStatus>[
              SiteDiagnosticStatus.downloadFailed,
              SiteDiagnosticStatus.invalidContent,
              SiteDiagnosticStatus.registerFailed,
              SiteDiagnosticStatus.noApi,
            ].contains(r.status))
        .length;
    final int skipped = _results
        .where((SiteDiagnosticResult r) => r.status == SiteDiagnosticStatus.skipped)
        .length;
    final int searchableCount =
        _results.where((SiteDiagnosticResult r) => r.canSearch).length;
    final int jscCount = _results
        .where((SiteDiagnosticResult r) => r.engineType == SpiderEngineType.javaScriptCore)
        .length;
    final int qjsCount = _results
        .where((SiteDiagnosticResult r) => r.engineType == SpiderEngineType.quickJS)
        .length;

    return DiagnosticSummary(
      total: total,
      engineReady: engineReady,
      apiOnly: apiOnly,
      failed: failed,
      skipped: skipped,
      searchableCount: searchableCount,
      jscCount: jscCount,
      qjsCount: qjsCount,
    );
  }
}