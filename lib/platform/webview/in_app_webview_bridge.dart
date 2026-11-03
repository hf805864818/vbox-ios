/// 平台层：内嵌 WebView 桥的 `flutter_inappwebview` 承载实现（批次 F · Web-R1）。
///
/// 实现 [WebViewBridge] 的三项能力（对齐 iOS WKWebView 语义）：
///   · [loadPage]：无头加载页面（`HeadlessInAppWebView`）→ `onLoadStop` 取
///     `document.documentElement.outerHTML` + `CookieManager.getCookies`
///     （**HttpOnly 可读**，这是选 `flutter_inappwebview` 而非 `webview_flutter`
///     的根本原因）；
///   · [request]：在**同源承载页**上下文执行同步 `XMLHttpRequest`（规避 CORS），
///     返回 `status/body/headers`（对齐 iOS `BaiduWebViewBridge.request`）；
///   · [currentCookieString]：`CookieManager.getCookies` 拼串。
///
/// 平台可用性：[isAvailable] 在 Android / iOS / macOS / Windows 为 true。
/// Windows 由 `flutter_inappwebview_windows`（Microsoft.Web.WebView2 承载）
/// 提供 `HeadlessInAppWebView` / `CookieManager` / `InAppWebView`，与
/// Android/iOS/macOS 走同一套 API；Linux 无 `flutter_inappwebview` 实现，
/// 返回 false（消费点回退「系统浏览器 + 粘贴」兜底），不影响构建。
///
/// Windows 引导：[initialize] 须在 `runApp` 前调用一次，创建**自定义数据目录**
/// 的 `WebViewEnvironment`（WebView2 默认数据目录在 exe 同级，安装到只读目录
/// 时会崩溃），并探测 WebView2 Runtime 是否存在；缺失或创建失败时
/// [isAvailable] 在 Windows 返回 false，消费点自动回退第 4 层保存值兜底。
///
/// 说明：本文件按 `flutter_inappwebview` 6.x 稳定 API 编写；因交付沙箱无
/// Flutter/Dart SDK，具体类/方法签名未经本地编译验证，若 CI 报错需按插件
/// 实际签名微调（已登记于方案文档）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/utils/logger.dart';
import 'webview_bridge.dart';

/// 基于 `flutter_inappwebview` 的 WebView 桥实现。
class InAppWebViewBridge implements WebViewBridge {
  /// 构造。
  InAppWebViewBridge();

  /// Windows 平台 WebView2 环境（自定义数据目录；非 Windows 恒为 null）。
  ///
  /// 由 [initialize] 在启动时创建，供 `CookieManager` / `HeadlessInAppWebView`
  /// / `InAppWebView` 共用（保证 CookieJar 同源）。
  static WebViewEnvironment? _windowsEnvironment;

  /// Windows 平台 WebView2 Runtime 是否可用（其余平台恒 true）。
  ///
  /// 缺省 true（未探测时按可用处理，保持既有行为）；[initialize] 探测到
  /// Runtime 缺失 / 创建失败时置 false，令 Windows 上的 [isAvailable] 返回
  /// false，消费点回退第 4 层保存值兜底。
  static bool _windowsAvailable = true;

  /// 是否已执行 [initialize]（幂等保护，避免重复创建环境）。
  static bool _windowsInitialized = false;

  /// Windows 无头 WebView2 是否允许（`loadPage` / XHR `request`）。
  ///
  /// 默认 **false**（原生崩溃保护）：3.1839 实测 `flutter_inappwebview_windows`
  /// （6.2.0-beta.3）的 `HeadlessInAppWebView` 在部分 Windows 机器上触发原生
  /// abort（WER 现场：异常代码 c0000409、故障模块 flutter_windows.dll，模块
  /// 清单含 WebView2Loader.dll + flutter_inappwebview_windows_plugin.dll），
  /// 进程闪退且 Dart 层无法捕获；复现路径为百度解析链每次必经的无头兜底层。
  /// 故无头操作默认整体跳过（首次留痕日志）；**可见 WebView 不受影响**
  /// （授权中心登录页走 [buildView]，无需无头）。插件升级后再恢复默认开启。
  static bool windowsHeadlessEnabled = false;

  /// 「无头已禁用」告警只打一次。
  static bool _windowsHeadlessWarned = false;

  /// Windows 专用引导：创建**自定义数据目录**的 `WebViewEnvironment`。
  ///
  /// 须在 `runApp` 前调用一次（`main()` 内）。依据官方要求，WebView2 默认
  /// 数据目录位于 exe 同级（只读安装目录下会崩溃），改用应用支持目录下
  /// `webview2/` 规避；同时探测 WebView2 Runtime 是否存在。非 Windows 为空
  /// 操作；Runtime 缺失或创建失败时静默降级（仅告警，不阻断启动）。
  static Future<void> initialize() async {
    if (kIsWeb || !Platform.isWindows) return;
    if (_windowsInitialized) return;
    _windowsInitialized = true;
    try {
      final String? version = await WebViewEnvironment.getAvailableVersion();
      if (version == null) {
        _windowsAvailable = false;
        AppLog.warn('webview', '未检测到 WebView2 Runtime，Windows 内嵌 WebView 兜底不可用');
        return;
      }
      final Directory base = await getApplicationSupportDirectory();
      final Directory dir = Directory(p.join(base.path, 'webview2'));
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      _windowsEnvironment = await WebViewEnvironment.create(
        settings: WebViewEnvironmentSettings(userDataFolder: dir.path),
      );
    } catch (e) {
      _windowsAvailable = false;
      AppLog.warn('webview', 'Windows WebView2 环境初始化失败: $e');
    }
  }

  @override
  bool get isAvailable =>
      !kIsWeb &&
      (Platform.isAndroid ||
          Platform.isIOS ||
          Platform.isMacOS ||
          (Platform.isWindows && _windowsAvailable));

  void _ensureAvailable() {
    if (!isAvailable) {
      throw const WebViewBridgeException('当前平台不支持 WebView 桥（Web-R1）');
    }
  }

  /// 无头操作闸门（`loadPage` / `request` 专用）。
  ///
  /// Windows 上默认禁用（见 [windowsHeadlessEnabled]），避免 beta 插件无头
  /// 模式的原生 abort 闪退；首次触发留痕日志。抛 [WebViewBridgeException]，
  /// 消费点（百度解析链各兜底层）均有 try/catch，会优雅跳过该层。
  void _ensureHeadlessAllowed() {
    _ensureAvailable();
    if (Platform.isWindows && !windowsHeadlessEnabled) {
      if (!_windowsHeadlessWarned) {
        _windowsHeadlessWarned = true;
        AppLog.warn(
          'webview',
          'Windows 无头 WebView2 已禁用（原生崩溃保护）——无头兜底层全部跳过；'
          '如需启用请设置 InAppWebViewBridge.windowsHeadlessEnabled = true',
        );
      }
      throw const WebViewBridgeException('Windows 无头 WebView2 已禁用（崩溃保护）');
    }
  }

  @override
  Future<WebViewPageResult> loadPage({
    required String url,
    String? userAgent,
    Map<String, String> cookies = const <String, String>{},
    Duration timeout = const Duration(seconds: 30),
    String? evaluateJs,
  }) async {
    _ensureHeadlessAllowed();
    final WebUri uri = WebUri(url);
    final CookieManager cookieManager =
        CookieManager.instance(webViewEnvironment: _windowsEnvironment);
    // 预注入 Cookie：HttpOnly 只能经 CookieManager 写入（不能靠 document.cookie）。
    for (final MapEntry<String, String> e in cookies.entries) {
      await cookieManager.setCookie(
        url: uri,
        name: e.key,
        value: e.value,
      );
    }

    final Completer<WebViewPageResult> completer =
        Completer<WebViewPageResult>();
    final HeadlessInAppWebView headless = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(url: uri),
      webViewEnvironment: _windowsEnvironment,
      initialSettings: InAppWebViewSettings(
        userAgent: userAgent,
        javaScriptEnabled: true,
      ),
      onLoadStop: (InAppWebViewController controller, WebUri? loaded) async {
        try {
          final Object? html = await controller.evaluateJavascript(
            source: 'document.documentElement.outerHTML',
          );
          // evaluateJs：页面上下文提取（对齐 iOS `BaiduWebViewBridge` 的
          // JS 注入语义，如 `window.locals.get('bdstoken')`）；失败静默为空。
          String jsResult = '';
          if (evaluateJs != null && evaluateJs.isNotEmpty) {
            try {
              final Object? js = await controller.evaluateJavascript(
                source: evaluateJs,
              );
              jsResult = _normalizeJsResult(js);
            } catch (_) {
              jsResult = '';
            }
          }
          final List<Cookie> cs = await cookieManager.getCookies(url: uri);
          final String cookieStr =
              cs.map((Cookie c) => '${c.name}=${c.value}').join('; ');
          if (!completer.isCompleted) {
            completer.complete((
              html: '${html ?? ''}',
              url: '${loaded ?? uri}',
              cookie: cookieStr,
              jsResult: jsResult,
            ));
          }
        } catch (e) {
          if (!completer.isCompleted) {
            completer.completeError(WebViewBridgeException('页面读取失败：$e'));
          }
        }
      },
      onReceivedError: (
        InAppWebViewController controller,
        WebResourceRequest request,
        WebResourceError error,
      ) {
        if (!completer.isCompleted) {
          completer.completeError(
            WebViewBridgeException('页面加载失败：${error.description}'),
          );
        }
      },
    );
    await headless.run();
    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      throw const WebViewBridgeException('页面加载超时');
    } finally {
      await headless.dispose();
    }
  }

  /// `evaluateJavascript` 返回值归一为字符串
  /// （null / 字面量 `null` / `undefined` 归空串，其余转字符串）。
  static String _normalizeJsResult(Object? js) {
    if (js == null) return '';
    final String s = '$js';
    if (s == 'null' || s == 'undefined' || s == '<null>') return '';
    return s;
  }

  @override
  Future<WebViewXhrResult> request({
    required String url,
    String method = 'GET',
    Map<String, String> headers = const <String, String>{},
    String? body,
    String? hostUrl,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    _ensureHeadlessAllowed();
    final String host = hostUrl ?? _originOf(url);
    final HeadlessInAppWebView page = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(host)),
      webViewEnvironment: _windowsEnvironment,
      initialSettings: InAppWebViewSettings(javaScriptEnabled: true),
    );
    await page.run();
    try {
      final InAppWebViewController? controller = page.webViewController;
      if (controller == null) {
        throw const WebViewBridgeException('WebView 承载页未就绪');
      }
      final Object? raw = await controller
          .evaluateJavascript(
            source: _xhrScript(
              url: url,
              method: method,
              headers: headers,
              body: body,
            ),
          )
          .timeout(timeout);
      return parseXhrResult(raw);
    } on TimeoutException {
      throw const WebViewBridgeException('页面 XHR 超时');
    } finally {
      await page.dispose();
    }
  }

  /// XHR 脚本执行结果的统一解析（无头桥与隐藏 widget 桥共用）。
  ///
  /// 插件对 `evaluateJavascript` 的字符串返回值在不同平台可能直接回传
  /// Dart String，或做一次 JSON 编码回传；脚本本身返回 `JSON.stringify(...)`
  /// 字符串，故对 String 做（至多两重）解码容错。解析不出 Map 即抛
  /// [WebViewBridgeException]（消费点均 catch 后优雅跳过该层）。
  static WebViewXhrResult parseXhrResult(Object? raw) {
    Object? decoded = raw is String ? _tryJsonDecode(raw) : raw;
    if (decoded is String) decoded = _tryJsonDecode(decoded);
    if (decoded is! Map) {
      throw const WebViewBridgeException('页面 XHR 结果解析失败');
    }
    final Map<String, Object?> m = decoded.cast<String, Object?>();
    final Object? rawHeaders = m['headers'];
    final Map<String, String> rh = rawHeaders is Map
        ? <String, String>{
            for (final MapEntry<Object?, Object?> e in rawHeaders.entries)
              e.key.toString(): '${e.value}',
          }
        : const <String, String>{};
    return (
      status: (m['status'] as num?)?.toInt() ?? 0,
      body: '${m['body'] ?? ''}',
      headers: rh,
    );
  }

  /// JSON 解码（失败返回 null，不抛错）。
  static Object? _tryJsonDecode(String s) {
    try {
      return jsonDecode(s);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<String> currentCookieString({String? domain}) async {
    _ensureAvailable();
    final CookieManager cookieManager =
        CookieManager.instance(webViewEnvironment: _windowsEnvironment);
    final List<Cookie> cs = domain == null || domain.isEmpty
        ? await cookieManager.getAllCookies()
        : await cookieManager.getCookies(
            url: WebUri('https://$domain/'),
          );
    return cs.map((Cookie c) => '${c.name}=${c.value}').join('; ');
  }

  @override
  Widget? buildView({required String url, String? userAgent}) {
    if (!isAvailable) return null;
    return InAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(url)),
      webViewEnvironment: _windowsEnvironment,
      initialSettings: InAppWebViewSettings(
        userAgent: userAgent,
        javaScriptEnabled: true,
      ),
    );
  }

  /// 同源承载页 origin（无法解析时退回 `about:blank`）。
  static String _originOf(String url) {
    final Uri? u = Uri.tryParse(url);
    if (u == null || u.host.isEmpty) return 'about:blank';
    return '${u.scheme}://${u.host}';
  }

  /// 同步 XHR 脚本（对齐 iOS 桥在页面上下文发请求的语义）。
  static String _xhrScript({
    required String url,
    required String method,
    required Map<String, String> headers,
    String? body,
  }) {
    final String h = jsonEncode(headers);
    final String b = body == null ? 'null' : jsonEncode(body);
    return '''
(function(){
  try {
    var x = new XMLHttpRequest();
    x.open(${jsonEncode(method)}, ${jsonEncode(url)}, false);
    var hs = $h;
    for (var k in hs) { x.setRequestHeader(k, hs[k]); }
    x.send($b);
    var rh = {};
    x.getAllResponseHeaders().trim().split('\\r\\n').forEach(function(line){
      var i = line.indexOf(':');
      if (i > 0) { rh[line.slice(0, i).trim().toLowerCase()] = line.slice(i + 1).trim(); }
    });
    return JSON.stringify({status: x.status, body: x.responseText, headers: rh});
  } catch (e) {
    return JSON.stringify({status: 0, body: '' + e, headers: {}});
  }
})()
''';
  }
}
