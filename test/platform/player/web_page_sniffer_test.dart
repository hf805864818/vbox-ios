/// 平台层单测：WebPageSniffer（网页播放页 → 媒体直链提取，A3 对齐 iOS 嗅探语义）。
///
/// 静态层用 http.MockClient 注入；动态层 WebViewBridge 用恒不可用替身；
/// 纯提取逻辑直接调静态方法，无 IO 依赖。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vbox/core/network/http_client.dart';
import 'package:vbox/platform/player/web_page_sniffer.dart';
import 'package:vbox/platform/webview/webview_bridge.dart';

/// 恒不可用 WebView 桥（动态层跳过）。
class _NoWebView implements WebViewBridge {
  @override
  bool get isAvailable => false;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// 可用 WebView 桥（返回注入 HTML，记录加载的 URL）。
class _FakeWebView implements WebViewBridge {
  _FakeWebView(this.html);

  final String html;
  final List<String> loaded = <String>[];

  @override
  bool get isAvailable => true;

  @override
  Future<WebViewPageResult> loadPage({
    required String url,
    String? userAgent,
    Map<String, String> cookies = const <String, String>{},
    Duration timeout = const Duration(seconds: 30),
    String? evaluateJs,
  }) async {
    loaded.add(url);
    return (html: html, url: url, cookie: '', jsResult: '');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

HttpClient _clientWith(String body) => HttpClient(
      inner: MockClient((http.Request req) async => http.Response(
            body,
            200,
            headers: <String, String>{
              'content-type': 'text/html; charset=utf-8',
            },
          )),
      maxRetries: 0,
    );

void main() {
  group('extractFromHtml：绝对直链', () {
    test('页面内嵌 .m3u8 直链 → 提取（最高优先级）', () {
      const String html = '<html><script>'
          'var url = "https://cdn.ex.com/vod/abc/index.m3u8";'
          '</script></html>';
      expect(
        WebPageSniffer.extractFromHtml(html, 'https://ex.com/play/1'),
        'https://cdn.ex.com/vod/abc/index.m3u8',
      );
    });

    test('m3u8 优先于 mp4（HLS 优先，对齐内核支持矩阵）', () {
      const String html = '<a href="https://c.com/a.mp4">x</a>'
          'var s="https://c.com/b.m3u8";';
      expect(
        WebPageSniffer.extractFromHtml(html, 'https://ex.com/p'),
        'https://c.com/b.m3u8',
      );
    });

    test('带 query 的直链完整保留', () {
      const String html = '"https://c.com/a.m3u8?sign=ab12&from=play"';
      expect(
        WebPageSniffer.extractFromHtml(html, 'https://ex.com/p'),
        'https://c.com/a.m3u8?sign=ab12&from=play',
      );
    });

    test('JS 转义 `\\/` 还原后提取', () {
      const String html = r'var u = "https:\/\/c.com\/vod\/1.m3u8";';
      expect(
        WebPageSniffer.extractFromHtml(html, 'https://ex.com/p'),
        'https://c.com/vod/1.m3u8',
      );
    });

    test('JS 转义 `\\u002F` 还原后提取', () {
      const String html = r'var u = "https:\u002F\u002Fc.com\u002F1.m3u8";';
      expect(
        WebPageSniffer.extractFromHtml(html, 'https://ex.com/p'),
        'https://c.com/1.m3u8',
      );
    });
  });

  group('extractFromHtml：相对路径与优先级', () {
    test('相对路径直链以播放页为 base 解析', () {
      const String html = "url: '/vod/2026/01/01.m3u8'";
      expect(
        WebPageSniffer.extractFromHtml(html, 'https://ex.com/play/1'),
        'https://ex.com/vod/2026/01/01.m3u8',
      );
    });

    test('无媒体直链 → null', () {
      const String html = '<html><body>纯播放页壳子，无直链</body></html>';
      expect(
        WebPageSniffer.extractFromHtml(html, 'https://ex.com/play/1'),
        isNull,
      );
    });

    test('空 HTML → null', () {
      expect(
        WebPageSniffer.extractFromHtml('', 'https://ex.com/play/1'),
        isNull,
      );
    });
  });

  group('extractMediaUrl：两层链路', () {
    test('静态层命中 → 直接返回，不触达 WebView', () async {
      final HttpClient client = _clientWith(
        '<script>var u="https://cdn.ex.com/1.m3u8";</script>',
      );
      final WebPageSniffer sniffer =
          WebPageSniffer(client: client, webview: _NoWebView());
      final String? hit = await sniffer.extractMediaUrl('https://ex.com/play/1');
      expect(hit, 'https://cdn.ex.com/1.m3u8');
    });

    test('静态层未命中 → WebView 动态层兜底', () async {
      final HttpClient client = _clientWith('<html>壳子</html>');
      final _FakeWebView webview = _FakeWebView(
        '<script>var u="https://render.ex.com/2.m3u8";</script>',
      );
      final WebPageSniffer sniffer = WebPageSniffer(
        client: client,
        webview: webview,
      );
      final String? hit = await sniffer.extractMediaUrl('https://ex.com/play/2');
      expect(hit, 'https://render.ex.com/2.m3u8');
      expect(webview.loaded, <String>['https://ex.com/play/2']);
    });

    test('两层都未命中 → null（调用侧回落原地址）', () async {
      final HttpClient client = _clientWith('<html>没有直链</html>');
      final _FakeWebView webview = _FakeWebView('<html>渲染后也没有</html>');
      final WebPageSniffer sniffer = WebPageSniffer(
        client: client,
        webview: webview,
      );
      expect(
        await sniffer.extractMediaUrl('https://ex.com/play/3'),
        isNull,
      );
    });

    test('静态层抛错（防爬） → 动态层兜底不抛', () async {
      final HttpClient client = HttpClient(
        inner: MockClient((http.Request req) async =>
            http.Response('forbidden', 403)),
        maxRetries: 0,
      );
      final _FakeWebView webview = _FakeWebView(
        '<script>var u="https://ok.ex.com/3.m3u8";</script>',
      );
      final WebPageSniffer sniffer = WebPageSniffer(
        client: client,
        webview: webview,
      );
      expect(
        await sniffer.extractMediaUrl('https://ex.com/play/4'),
        'https://ok.ex.com/3.m3u8',
      );
    });
  });
}
