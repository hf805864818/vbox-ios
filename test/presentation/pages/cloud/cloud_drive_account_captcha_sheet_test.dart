/// 表现层单测：蜗牛账号登录的图形验证码（对齐 iOS `NodeWoniu4kLoginView`）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/cloud/cloud_drive.dart';
import 'package:vbox/domain/entities/cloud/cloud_drive_login.dart';
import 'package:vbox/presentation/pages/cloud/login_gateway.dart';
import 'package:vbox/presentation/pages/cloud/login_sheet.dart';

/// 1×1 PNG data URL（测试可解码）。
const String _onePixelPng =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';

/// 提供图形验证码的网关（其余继承「未接入」实现）。
class _WoniuGateway extends UnavailableCloudDriveLoginGateway {
  const _WoniuGateway();

  @override
  Future<String?> loadAccountCaptcha(CloudDriveType type) async => _onePixelPng;
}

/// 天翼 189 两段式账号登录网关（对齐 iOS `NodePan189AccountLoginView`）。
class _Pan189Gateway extends UnavailableCloudDriveLoginGateway {
  _Pan189Gateway();

  /// 记录二次校验提交的验证码。
  String? lastSmsCode;

  @override
  Future<CloudDriveAccountResult> submitAccountLogin({
    required CloudDriveType type,
    required CloudDriveLoginMode mode,
    required String account,
    required String password,
    String captchaCode = '',
  }) async =>
      (needSms: true, message: '请输入短信验证码');

  @override
  Future<void> submitAccountSmsCode({
    required CloudDriveType type,
    required String code,
  }) async {
    lastSmsCode = code;
  }
}

void main() {
  testWidgets('蜗牛：进入账号 Sheet 自动展示图形验证码输入框', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: CloudDriveAccountLoginSheet(
            driveType: CloudDriveType.woniu4k,
            gateway: _WoniuGateway(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('cloud_login_verify')),
      findsOneWidget,
    );
  });

  testWidgets('无图形验证码的盘：不展示验证码输入框', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: CloudDriveAccountLoginSheet(driveType: CloudDriveType.pan123),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('cloud_login_verify')),
      findsNothing,
    );
  });

  testWidgets('天翼 189：账号提交后转短信二次校验并登录', (WidgetTester tester) async {
    final _Pan189Gateway gateway = _Pan189Gateway();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CloudDriveAccountLoginSheet(
            driveType: CloudDriveType.pan189,
            gateway: gateway,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 初始：短信验证码输入框与「验证短信并登录」按钮均未出现。
    expect(
      find.byKey(const ValueKey<String>('cloud_login_sms_code')),
      findsNothing,
    );
    expect(find.text('登录并保存'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey<String>('cloud_login_account')),
      'tianyi',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('cloud_login_password')),
      'pwd',
    );
    // 待输入经 setState 生效后再点击：按钮 `enabled` 依赖非空校验，
    // 未 rebuild 时 `onTap` 仍为 null，点击会落空。
    await tester.pumpAndSettle();
    await tester.tap(find.text('登录并保存'));
    await tester.pumpAndSettle();

    // 转入二次校验态：出现验证码输入框 + 按钮改文案。
    expect(
      find.byKey(const ValueKey<String>('cloud_login_sms_code')),
      findsOneWidget,
    );
    expect(find.text('验证短信并登录'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey<String>('cloud_login_sms_code')),
      '8888',
    );
    // 同上：待短信码非空经 setState 生效后再点击。
    await tester.pumpAndSettle();
    await tester.tap(find.text('验证短信并登录'));
    await tester.pumpAndSettle();

    expect(gateway.lastSmsCode, '8888');
    expect(find.text('登录成功'), findsWidgets);
  });
}