import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/cloud/cloud_drive.dart';
import 'package:vbox/platform/webview/webview_bridge.dart';
import 'package:vbox/presentation/pages/cloud/login_sheet.dart';

/// 假 WebView 桥（可控可用性 / Cookie / 错误）。
class _FakeWebViewBridge implements WebViewBridge {
  _FakeWebViewBridge({
    this.available = true,
    this.error,
  });

  final bool available;
  final String cookie = 'BDUSS=1; STOKEN=2';
  final String? error;
  int loadCalls = 0;
  int cookieCalls = 0;

  @override
  bool get isAvailable => available;

  @override
  Future<WebViewPageResult> loadPage({
    required String url,
    String? userAgent,
    Map<String, String> cookies = const <String, String>{},
    Duration timeout = const Duration(seconds: 30),
    String? evaluateJs,
  }) async {
    loadCalls++;
    if (error != null) throw WebViewBridgeException(error!);
    return (html: '<html></html>', url: url, cookie: '', jsResult: '');
  }

  @override
  Future<WebViewXhrResult> request({
    required String url,
    String method = 'GET',
    Map<String, String> headers = const <String, String>{},
    String? body,
    String? hostUrl,
    Duration timeout = const Duration(seconds: 15),
  }) async =>
      (status: 200, body: '', headers: const <String, String>{});

  @override
  Future<String> currentCookieString({String? domain}) async {
    cookieCalls++;
    return cookie;
  }

  @override
  Widget? buildView({required String url, String? userAgent}) =>
      available ? const SizedBox(key: ValueKey<String>('fake-webview')) : null;
}

Widget _host({required WebViewBridge bridge, Future<void> Function(String)? onSecret}) =>
    MaterialApp(
      home: Scaffold(
        body: CloudDriveWebLoginSheet(
          driveType: CloudDriveType.baidu,
          bridge: bridge,
          saver: ({required CloudDriveType type, required String secret}) async {
            onSecret?.call(secret);
          },
        ),
      ),
    );

void main() {
  group('WebViewBridge 契约', () {
    test('缺省桥不可用且抛明确文案', () async {
      const WebViewBridge bridge = UnavailableWebViewBridge();
      expect(bridge.isAvailable, isFalse);
      await expectLater(
        bridge.loadPage(url: 'https://x'),
        throwsA(
          isA<WebViewBridgeException>()
              .having((WebViewBridgeException e) => e.message, 'message', contains('Web-R1')),
        ),
      );
      await expectLater(
        bridge.currentCookieString(),
        throwsA(isA<WebViewBridgeException>()),
      );
    });

    test('WebAuthPolicy：登记盘有策略，未登记为 null', () {
      final WebAuthPolicy? baidu = WebAuthPolicy.of(CloudDriveType.baidu);
      expect(baidu, isNotNull);
      expect(baidu!.startUrl, contains('pan.baidu.com'));
      expect(baidu.cookieHosts, isNotEmpty);
      expect(WebAuthPolicy.of(CloudDriveType.bilibili), isNull);
    });
  });

  group('网页登录档 · 内嵌自动回收（Web-R1）', () {
    testWidgets('桥不可用：不展示自动回收按钮', (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(bridge: _FakeWebViewBridge(available: false)),
      );
      expect(find.text('内嵌登录并自动回收'), findsNothing);
    });

    testWidgets('桥可用：点击自动回收 Cookie 并落盘', (WidgetTester tester) async {
      final _FakeWebViewBridge bridge = _FakeWebViewBridge();
      String? saved;
      await tester.pumpWidget(
        _host(bridge: bridge, onSecret: (String s) async {
          saved = s;
        }),
      );
      expect(find.text('内嵌登录并自动回收'), findsOneWidget);
      await tester.tap(find.text('内嵌登录并自动回收'));
      await tester.pumpAndSettle();
      expect(bridge.loadCalls, 1);
      expect(bridge.cookieCalls, 1);
      expect(saved, 'BDUSS=1; STOKEN=2');
      expect(find.text('已保存到授权中心'), findsOneWidget);
    });

    testWidgets('桥抛错：展示错误文案', (WidgetTester tester) async {
      final _FakeWebViewBridge bridge =
          _FakeWebViewBridge(error: 'WebView 桥未接入（Web-R1 依赖待引入）');
      await tester.pumpWidget(_host(bridge: bridge));
      await tester.tap(find.text('内嵌登录并自动回收'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Web-R1'),
        findsWidgets,
      );
      // 错误路径会弹 Toast（内部 2s 定时器），推进时钟让其自然结束，避免遗留 pending timer。
      await tester.pump(const Duration(seconds: 3));
    });
  });
}