/// 平台层：网页播放页媒体直链嗅探器（G-03-B · 快捷解析链）。
///
/// 对齐 iOS 语义：spider / CMS 返回的播放地址为**网页播放页**（如
/// `https://host/play/xxxx`）而非媒体直链时，iOS 由原生 WebView 加载页面、
/// 监听网络请求提取真实直链（`WKWebView` 嗅探）后再起播。Flutter 端三平台
/// 无统一网络层监听能力，以等价的两层提取实现：
///   ① 静态层（全平台）：HTTP GET 播放页 → 页面源码正则提取直链
///      （CMS 系播放页直链通常内嵌在源码 / player 配置里）；
///   ② 动态层（Android/iOS/macOS）：[WebViewBridge.loadPage] 无头渲染
///      （执行页面 JS 后的 outerHTML）→ 同样正则提取（对齐 Web-R2
///      「公共解析器回退 WKWebViewParser」契约）。
///
/// 提取优先级：`.m3u8`（HLS）> `.mp4` > `.flv` > `.mkv`，与播放器内核
/// 支持矩阵（M1 Media3 / libmpv）一致。全层未命中返回 null（调用侧
/// 回落原地址，保留原有错误展示）。
library;

import '../../core/network/http_client.dart';
import '../webview/webview_bridge.dart';

/// 网页播放页嗅探器（可注入；测试用替身）。
class WebPageSniffer {
  /// 构造。
  ///
  /// [client] 静态层抓页客户端（缺省新建，桌面 Chrome UA 降低防爬拦截）；
  /// [webview] 动态层渲染桥（缺省不可用，静态层未命中即返回 null）。
  WebPageSniffer({HttpClient? client, WebViewBridge? webview})
      : _client = client ??
            HttpClient(userAgent: snifferDesktopChromeUA),
        _webview = webview;

  static const String logTag = 'sniffer';

  final HttpClient _client;
  final WebViewBridge? _webview;

  /// 从播放页提取媒体直链。
  ///
  /// 返回 null 表示两层都未命中（不是失败——调用侧保留原地址继续起播）。
  Future<String?> extractMediaUrl(String pageUrl) async {
    final String url = pageUrl.trim();
    if (url.isEmpty) return null;

    // ① 静态层：直接抓页面源码提取。
    try {
      final HttpClientResponse res = await _client.get(Uri.parse(url));
      final String? hit = extractFromHtml(res.text, res.uri.toString());
      if (hit != null) return hit;
    } catch (_) {
      // 静态层失败（防爬/证书/超时）→ 落到动态层。
    }

    // ② 动态层：WebView 无头渲染（执行 JS 后的 HTML）再提取。
    final WebViewBridge? bridge = _webview;
    if (bridge == null || !bridge.isAvailable) return null;
    try {
      final WebViewPageResult page = await bridge.loadPage(url: url);
      return extractFromHtml(page.html, page.url);
    } catch (_) {
      return null;
    }
  }

  /// 从页面 HTML 提取媒体直链（静态/动态两层共用）。
  ///
  /// 处理常见 JS 转义（`\u002F` / `\/`）后按 `.m3u8 > .mp4 > .flv > .mkv`
  /// 优先级取第一个可解析的绝对地址；相对地址以 [pageUrl] 解析。
  static String? extractFromHtml(String html, String pageUrl) {
    if (html.isEmpty) return null;
    // JS 常见转义还原：`\/` → `/`、`\u002F`（大小写）→ `/`。
    final String normalized = html
        .replaceAll(r'\/', '/')
        .replaceAllMapped(
          RegExp(r'\\u002[fF]'),
          (Match m) => '/',
        );

    const List<String> exts = <String>['m3u8', 'mp4', 'flv', 'mkv'];
    for (final String ext in exts) {
      final RegExpMatch? m = RegExp(
        // URL 字符集（排除引号/空白/尖括号/反斜杠），扩展名后可带 query。
        'https?://[^"\'\\s<>\\\\]+?\\.$ext(?:\\?[^"\'\\s<>\\\\]*)?',
        caseSensitive: false,
      ).firstMatch(normalized);
      if (m == null) continue;
      final String hit = m.group(0)!;
      final Uri? resolved = _resolve(hit, pageUrl);
      if (resolved != null) return resolved.toString();
    }

    // 相对路径直链（源码内 `url: '/play/xxx.m3u8'` 形态）。
    for (final String ext in exts) {
      final RegExpMatch? m = RegExp(
        '["\'(]\\s*(/[^"\'\\s<>]+?\\.$ext(?:\\?[^"\'\\s<>]*)?)\\s*["\')]?', 
        caseSensitive: false,
      ).firstMatch(normalized);
      if (m == null) continue;
      final Uri? resolved = _resolve(m.group(1)!, pageUrl);
      if (resolved != null) return resolved.toString();
    }
    return null;
  }

  /// 以播放页地址为 base 解析（非法 base 时仅接受绝对地址）。
  static Uri? _resolve(String candidate, String pageUrl) {
    final Uri? direct = Uri.tryParse(candidate);
    if (direct != null && direct.hasScheme) return direct;
    final Uri? base = Uri.tryParse(pageUrl);
    if (base == null || !base.hasScheme) return null;
    try {
      return base.resolve(candidate);
    } on FormatException {
      return null;
    }
  }
}

/// 桌面 Chrome UA（嗅探抓页用，降低防爬拦截；与 `WebAuthPolicy.desktopChromeUA`
/// 同口径，单列常量避免嗅探器反向依赖网盘契约文件）。
const String snifferDesktopChromeUA =
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36';
