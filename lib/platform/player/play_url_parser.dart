/// 平台层：播放页地址二次解析（批次 W · W-福5）。
///
/// 唯一真相源：iOS `vbox/Services/SpiderManager.swift`
///   · `parsePlayUrl(from:)`（L4271-L4329）：自定义协议跳过 → TVBox 前缀剥离 →
///     已是直链直接返回 → 请求播放页 `extractDirectPlayURL` →（WKWebView 回退）；
///   · `extractDirectPlayURL`（L4438-L4508）：Content-Type 判定 + HTML 正则提取。
///
/// 消费场景：福利播放中转页在 `FuliPlayerResult.parse == 1` 时（URL 是网页地址
/// 而非直链）先经本解析器提取直链，失败仍回落原 URL（对齐 iOS
/// `FuliVideoBridgeView.resolveEpisode` L410-L423）。
///
/// **差异登记（如实）**：iOS 还有第 3 步 WKWebView 客户端解析回退
/// （`tryWKWebViewParse`，依赖 `WKWebViewParser` + 公共解析器 jsURL）。Flutter
/// 的 [WebViewBridge](../../platform/webview/webview_bridge.dart) 尚未接入插件
/// （`UnavailableWebViewBridge`），故此处仅落地「直链判定 + HTTP 播放页提取」两步；
/// 纯 JS 渲染的播放页需待 WebView 依赖引入后补回退链。
library;

import 'package:http/http.dart' as http;

/// 播放页 → 直链解析器（对齐 iOS `SpiderManager.parsePlayUrl`）。
class PlayUrlParser {
  /// 构造（[client] 可注入，测试用 `package:http/testing.dart` 的 MockClient）。
  PlayUrlParser({
    http.Client? client,
    this.timeout = const Duration(seconds: 10),
  }) : _client = client ?? http.Client();

  final http.Client _client;

  /// 单次请求超时（对齐 iOS `extractDirectPlayURL` 的 10s）。
  final Duration timeout;

  /// 解析 [playPageUrl] 为可播放直链；无法解析返回 `null`。
  Future<String?> parse(String playPageUrl) async {
    if (playPageUrl.isEmpty) return null;

    // 1. 自定义协议（如 xk://）不经解析器（对齐 iOS：无从 HTTP 提取）。
    final String lower = playPageUrl.toLowerCase();
    const List<String> standardSchemes = <String>[
      'http://',
      'https://',
      'file://',
      'rtmp://',
      'rtsp://',
    ];
    if (!standardSchemes.any(lower.startsWith)) return null;

    // 2. TVBox 特殊前缀剥离。
    String actualUrl = playPageUrl;
    if (actualUrl.startsWith('parse://')) {
      actualUrl = actualUrl.substring(8);
    } else if (actualUrl.startsWith('json://')) {
      actualUrl = actualUrl.substring(8);
    }

    // 3. 已是直链 → 原样返回。
    if (_looksDirect(actualUrl)) return actualUrl;

    // 4. 请求播放页，按 Content-Type / HTML 提取直链。
    final Uri? uri = Uri.tryParse(actualUrl);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      return null;
    }
    try {
      final http.Response response = await _client.get(
        uri,
        headers: const <String, String>{
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          'Accept': '*/*',
        },
      ).timeout(timeout);

      final String contentType = _header(response, 'content-type').toLowerCase();
      if (contentType.contains('application/vnd.apple.mpegurl') ||
          contentType.contains('video/mp4')) {
        return actualUrl;
      }
      return extractFromHtml(response.body, uri);
    } catch (_) {
      // 网络 / 解析异常 → 交由调用方回落原 URL。
      return null;
    }
  }

  /// 释放底层 client（应用退出时调用）。
  void dispose() => _client.close();

  /// URL 是否已是直链（`.m3u8` / `.mp4` 结尾，忽略查询串；对齐 iOS 后缀判定）。
  static bool _looksDirect(String url) {
    final String path = Uri.tryParse(url)?.path ?? url;
    final String lower = path.toLowerCase();
    return lower.endsWith('.m3u8') || lower.endsWith('.mp4');
  }

  /// 从 HTML 文本提取 m3u8 / mp4 直链（静态，便于单测）。
  ///
  /// 覆盖 iOS `extractDirectPlayURL` 的 7 条正则；相对路径按 [base] 补全。
  static String? extractFromHtml(String html, Uri base) {
    if (html.isEmpty) return null;
    for (final RegExp pattern in _htmlPatterns) {
      final RegExpMatch? match = pattern.firstMatch(html);
      if (match == null) continue;
      final String raw = (match.groupCount > 1
          ? match.group(1)
          : match.group(0))!;
      final String? normalized = _normalize(raw, base);
      if (normalized != null) return normalized;
    }
    return null;
  }

  /// 清理并补全提取结果（对齐 iOS：去引号 / 相对路径补全 / 仅接受 http）。
  static String? _normalize(String raw, Uri base) {
    String value = raw.trim();
    if (value.length > 1 &&
        value.startsWith('"') &&
        value.endsWith('"')) {
      value = value.substring(1, value.length - 1);
    }
    if (value.startsWith('//')) {
      value = 'https:$value';
    } else if (value.startsWith('/') && base.host.isNotEmpty) {
      value = '${base.scheme}://${base.host}$value';
    }
    return value.startsWith('http') ? value : null;
  }

  /// 大小写不敏感地读取响应头（HTTP 头名不区分大小写）。
  static String _header(http.Response response, String name) {
    final String? exact = response.headers[name];
    if (exact != null) return exact;
    final String lower = name.toLowerCase();
    for (final MapEntry<String, String> e in response.headers.entries) {
      if (e.key.toLowerCase() == lower) return e.value;
    }
    return '';
  }

  /// HTML 提取正则（对齐 iOS `extractDirectPlayURL` 的 patterns）。
  static final List<RegExp> _htmlPatterns = <RegExp>[
    RegExp(r'''https?://[^\s"'<>]+\.m3u8[^\s"'<>]*'''),
    RegExp(r'''https?://[^\s"'<>]+\.mp4[^\s"'<>]*'''),
    RegExp(r"""player\.src\(\{\s*src:\s*['"]([^'"]+)['"]"""),
    RegExp(r"""video\.src\(\{\s*src:\s*['"]([^'"]+)['"]"""),
    RegExp(r"""config\s*=\s*\{[^}]*url:\s*['"]([^'"]+)['"]"""),
    RegExp(r'''"playUrl":\s*"([^"]+)"'''),
    RegExp(r'''data-play-url="([^"]+)"'''),
  ];
}