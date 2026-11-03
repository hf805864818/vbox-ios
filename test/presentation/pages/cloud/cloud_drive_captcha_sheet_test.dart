/// 表现层单测：139 短信登录的滑块验证面板（Web-R3）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/cloud/cloud_drive.dart';
import 'package:vbox/platform/webview/webview_bridge.dart';
import 'package:vbox/presentation/pages/cloud/login_gateway.dart';
import 'package:vbox/presentation/pages/cloud/login_sheet.dart';

/// 恒返回滑块地址的网关（其余继承「未接入」实现）。
class _CaptchaGateway extends UnavailableCloudDriveLoginGateway {
  const _CaptchaGateway();

  @override
  String? pendingCaptchaUrl(CloudDriveType type) => 'https://captcha/1';
}

/// 可控可用性的可见 WebView 假桥。
class _FakeViewBridge implements WebViewBridge {
  _FakeViewBridge(this.available);

  final bool available;

  @override
  bool get isAvailable => available;

  @override
  Widget? buildView({required String url, String? userAgent}) => available
      ? const SizedBox(key: ValueKey<String>('captcha-view'))
      : null;

  @override
  Future<WebViewPageResult> loadPage({
    required String url,
    String? userAgent,
    Map<String, String> cookies = const <String, String>{},
    Duration timeout = const Duration(seconds: 30),
    String? evaluateJs,
  }) async =>
      (html: '', url: url, cookie: '', jsResult: '');

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
  Future<String> currentCookieString({String? domain}) async => '';
}

Widget _host(WebViewBridge bridge) => MaterialApp(
      home: Scaffold(
        body: CloudDriveSmsLoginSheet(
          driveType: CloudDriveType.pan139,
          bridge: bridge,
          gateway: const _CaptchaGateway(),
        ),
      ),
    );

void main() {
  testWidgets('139 滑块：桥可用时展示内嵌验证面板', (WidgetTester tester) async {
    await tester.pumpWidget(_host(_FakeViewBridge(true)));
    expect(find.text('滑块验证（完成后请等待短信）'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('captcha-view')), findsOneWidget);
  });

  testWidgets('桥不可用：不展示滑块面板（回退无滑块路径）',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host(_FakeViewBridge(false)));
    expect(find.text('滑块验证（完成后请等待短信）'), findsNothing);
  });
}