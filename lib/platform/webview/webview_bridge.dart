/// 平台层：内嵌 WebView 桥接契约（批次 F · Web-R1）。
///
/// 对齐 iOS WKWebView 能力矩阵（「唯一真相源」）：
///   · 9 盘内嵌网页登录 `TokenWebView`（`vbox/Views/TokenWebView.swift`）：
///     加载官方登录页 → 轮询 CookieStore 提取 HttpOnly Token；
///   · 百度 XHR 桥 `BaiduWebViewBridge`（`vbox/Services/BaiduWebViewBridge.swift`）：
///     在页面上下文用 `XMLHttpRequest` 请求百度接口，回传 body/headers/status；
///   · 公共解析器回退 `WKWebViewParser`（Web-R2）；
///   · 139 滑块内嵌页 `NodeCaptchaWebView`（Web-R3）。
///
/// **本文件只定义契约与缺省实现**：具体承载（`flutter_inappwebview` /
/// `webview_flutter` / 原生宿主）尚未引入——因依赖选型需覆盖
/// Android / macOS / Windows（项目目标平台），且 `webview_flutter` 的
/// `WebViewCookieManager` 只支持 set、**不支持读取 HttpOnly Cookie**，
/// 无法满足 Web-R1「轮询提取 HttpOnly Token」这一核心验收点。
/// 故先落地契约 + 缺省 [UnavailableWebViewBridge] + 消费点接线，
/// 待依赖引入并验证各平台后，实现一个 `InAppWebViewBridge` 即可生效。
library;

import 'package:flutter/widgets.dart';

import '../../domain/entities/cloud/cloud_drive.dart';

/// WebView 桥异常（文案面向用户）。
class WebViewBridgeException implements Exception {
  /// 构造。
  const WebViewBridgeException(this.message);

  /// 文案。
  final String message;

  @override
  String toString() => message;
}

/// 页面加载结果（对齐 iOS `loadPanPageForBdstoken` 的三要素）。
///
/// [jsResult] 为 `loadPage` 入参 `evaluateJs` 在页面上下文的执行结果
/// （未执行时为空串）——百度 bdstoken 由 JS 运行时注入（`window.locals`/
/// `window.context`），静态 HTML 正则抓不到，须以此结果为准
/// （对齐 iOS `BaiduWebViewBridge.swift:147-152`）。
typedef WebViewPageResult = ({
  String html,
  String url,
  String cookie,
  String jsResult,
});

/// 页面上下文 XHR 结果（对齐 iOS `BaiduWebViewBridge.request` 回传形状）。
typedef WebViewXhrResult = ({
  int status,
  String body,
  Map<String, String> headers,
});

/// 内嵌 WebView 桥接契约（可注入；测试用替身）。
abstract interface class WebViewBridge {
  /// 是否可用（缺省实现恒 false；引入插件后为 true）。
  bool get isAvailable;

  /// 加载页面并等待稳定，返回 `(html, 最终 url, cookie, jsResult)`。
  ///
  /// [cookies] 为预注入 Cookie（按 [WebAuthPolicy.cookieHosts] 域写入，
  /// 不能靠 `document.cookie`，HttpOnly 不可写读）。
  ///
  /// [evaluateJs] 非空时在页面加载完成后于页面上下文执行，返回值放
  /// [WebViewPageResult.jsResult]（对齐 iOS `BaiduWebViewBridge` 的 JS
  /// 注入提取语义；失败时 jsResult 为空串，不抛错）。
  Future<WebViewPageResult> loadPage({
    required String url,
    String? userAgent,
    Map<String, String> cookies = const <String, String>{},
    Duration timeout = const Duration(seconds: 30),
    String? evaluateJs,
  });

  /// 在页面上下文发起 XHR（对齐 iOS 百度桥的 `XMLHttpRequest` 语义）。
  ///
  /// [hostUrl] 为承载页地址（须与 [url] 同源以规避 CORS）；缺省取 [url] 的 origin。
  Future<WebViewXhrResult> request({
    required String url,
    String method = 'GET',
    Map<String, String> headers = const <String, String>{},
    String? body,
    String? hostUrl,
    Duration timeout = const Duration(seconds: 15),
  });

  /// 读取 CookieJar 中指定域的 Cookie 串（HttpOnly 亦可读；空域读全部）。
  Future<String> currentCookieString({String? domain});

  /// 构建**可见** WebView 视图（Web-R3：139 滑块需用户拖动；不可用返回 null）。
  Widget? buildView({required String url, String? userAgent});
}

/// 缺省桥：未接入（对齐 iOS Node/WebView 未就绪文案）。
class UnavailableWebViewBridge implements WebViewBridge {
  /// 构造。
  const UnavailableWebViewBridge();

  static const String _message = 'WebView 桥未接入（Web-R1 依赖待引入）';

  @override
  bool get isAvailable => false;

  @override
  Future<WebViewPageResult> loadPage({
    required String url,
    String? userAgent,
    Map<String, String> cookies = const <String, String>{},
    Duration timeout = const Duration(seconds: 30),
    String? evaluateJs,
  }) async =>
      throw const WebViewBridgeException(_message);

  @override
  Future<WebViewXhrResult> request({
    required String url,
    String method = 'GET',
    Map<String, String> headers = const <String, String>{},
    String? body,
    String? hostUrl,
    Duration timeout = const Duration(seconds: 15),
  }) async =>
      throw const WebViewBridgeException(_message);

  @override
  Future<String> currentCookieString({String? domain}) async =>
      throw const WebViewBridgeException(_message);

  @override
  Widget? buildView({required String url, String? userAgent}) => null;
}

/// 网页登录承载策略（对齐 iOS `TokenWebView` 的 startURL / UA / cookieHosts）。
class WebAuthPolicy {
  /// 构造。
  const WebAuthPolicy({
    required this.type,
    required this.startUrl,
    required this.userAgent,
    required this.cookieHosts,
  });

  /// 目标网盘。
  final CloudDriveType type;

  /// 官方登录页起始地址。
  final String startUrl;

  /// 页面 UA（按盘定制；缺省桌面 Chrome）。
  final String userAgent;

  /// Cookie 提取域名白名单。
  final List<String> cookieHosts;

  /// 桌面 Chrome UA（对齐 iOS `TokenWebView.userAgent` 的桌面端策略）。
  static const String desktopChromeUA =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36';

  static const Map<CloudDriveType, WebAuthPolicy> _policies =
      <CloudDriveType, WebAuthPolicy>{
    CloudDriveType.baidu: WebAuthPolicy(
      type: CloudDriveType.baidu,
      startUrl: 'https://pan.baidu.com/',
      userAgent: desktopChromeUA,
      cookieHosts: <String>['pan.baidu.com', '.baidu.com'],
    ),
    CloudDriveType.ali: WebAuthPolicy(
      type: CloudDriveType.ali,
      startUrl: 'https://www.alipan.com/',
      userAgent: desktopChromeUA,
      cookieHosts: <String>['alipan.com', 'aliyundrive.com'],
    ),
    CloudDriveType.quark: WebAuthPolicy(
      type: CloudDriveType.quark,
      startUrl: 'https://pan.quark.cn/',
      userAgent: desktopChromeUA,
      cookieHosts: <String>['pan.quark.cn'],
    ),
    CloudDriveType.uc: WebAuthPolicy(
      type: CloudDriveType.uc,
      startUrl: 'https://drive.uc.cn/',
      userAgent: desktopChromeUA,
      cookieHosts: <String>['drive.uc.cn', 'uc.cn'],
    ),
    CloudDriveType.one15: WebAuthPolicy(
      type: CloudDriveType.one15,
      startUrl: 'https://115.com/?ct=login',
      userAgent: desktopChromeUA,
      cookieHosts: <String>['115.com'],
    ),
    CloudDriveType.pan123: WebAuthPolicy(
      type: CloudDriveType.pan123,
      startUrl: 'https://www.123pan.com/login',
      userAgent: desktopChromeUA,
      cookieHosts: <String>['123pan.com'],
    ),
    CloudDriveType.pan139: WebAuthPolicy(
      type: CloudDriveType.pan139,
      startUrl: 'https://yun.139.com/w/',
      userAgent: desktopChromeUA,
      cookieHosts: <String>['139.com'],
    ),
    CloudDriveType.pan189: WebAuthPolicy(
      type: CloudDriveType.pan189,
      startUrl: 'https://cloud.189.cn/web/login.html',
      userAgent: desktopChromeUA,
      cookieHosts: <String>['189.cn'],
    ),
    CloudDriveType.xunlei: WebAuthPolicy(
      type: CloudDriveType.xunlei,
      startUrl: 'https://i.xunlei.com/xluser/login.html',
      userAgent: desktopChromeUA,
      cookieHosts: <String>['xunlei.com'],
    ),
  };

  /// 取该盘策略（未登记返回 null）。
  static WebAuthPolicy? of(CloudDriveType type) => _policies[type];
}