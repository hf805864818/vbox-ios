/// 网盘登录 Sheet Widget 单测（批次 F · F-02）。
///
/// 对齐基准：iOS `NativeCloudQRLoginView` / `BiliQrLoginView`（扫码）与
/// `NodeGuangyaSMSLoginView`（短信验证码）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vbox/data/datasources/local/cloud_drive_credential_store.dart';
import 'package:vbox/data/datasources/local/prefs_manager.dart';
import 'package:vbox/domain/entities/cloud/cloud_drive.dart';
import 'package:vbox/domain/entities/cloud/cloud_drive_login.dart';
import 'package:vbox/presentation/pages/cloud/login_gateway.dart';
import 'package:vbox/presentation/pages/cloud/login_sheet.dart';

/// 替身网关：扫码成功返回二维码，短信发送即报错。
class _SheetGateway implements CloudDriveLoginGateway {
  static const String _qrDataUrl =
      'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
      'AAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';

  @override
  Future<CloudDriveQrTask> startQrLogin({
    required CloudDriveType type,
    required CloudDriveLoginMode mode,
    String? providerOverride,
  }) async =>
      (taskId: 'qr-1', qrDataUrl: _qrDataUrl);

  @override
  Future<CloudDriveLoginPhase> pollQrLogin({
    required CloudDriveType type,
    required CloudDriveLoginMode mode,
    required String taskId,
    String? providerOverride,
  }) async =>
      CloudDriveLoginPhase.success;

  @override
  Future<void> cancelQrLogin(String taskId) async {}

  @override
  Future<String> sendSmsCode({
    required CloudDriveType type,
    required String phone,
  }) async =>
      throw const CloudDriveLoginException('Node 常驻系统未就绪');

  @override
  Future<void> submitSmsCode({
    required CloudDriveType type,
    required String taskId,
    required String code,
  }) async =>
      throw const CloudDriveLoginException('Node 常驻系统未就绪');

  @override
  Future<CloudDriveAccountResult> submitAccountLogin({
    required CloudDriveType type,
    required CloudDriveLoginMode mode,
    required String account,
    required String password,
    String captchaCode = '',
  }) async =>
      throw const CloudDriveLoginException('Node 常驻系统未就绪');

  @override
  Future<void> submitAccountSmsCode({
    required CloudDriveType type,
    required String code,
  }) async =>
      throw const CloudDriveLoginException('Node 常驻系统未就绪');

  @override
  String? pendingCaptchaUrl(CloudDriveType type) => null;

  @override
  Future<String?> loadAccountCaptcha(CloudDriveType type) async => null;
}

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  await tester.pump();
}

void main() {
  group('CloudDriveQrLoginSheet', () {
    testWidgets('初始态：标题 + 二维码占位 + 状态 + 提示 + 主按钮', (WidgetTester tester) async {
      await _pump(
        tester,
        const CloudDriveQrLoginSheet(driveType: CloudDriveType.baidu),
      );

      expect(find.text('百度网盘 原生扫码授权'), findsOneWidget);
      expect(find.text('准备生成二维码'), findsOneWidget);
      expect(find.text('生成二维码'), findsOneWidget);
      expect(find.byIcon(Icons.qr_code_2), findsOneWidget);
      expect(find.textContaining('请使用百度网盘 App 扫码并确认'), findsOneWidget);
      // 未轮询时不展示「取消」。
      expect(find.text('取消'), findsNothing);
    });

    testWidgets('缺省网关：点「生成二维码」即报原生链路未接入', (WidgetTester tester) async {
      await _pump(
        tester,
        const CloudDriveQrLoginSheet(driveType: CloudDriveType.ali),
      );

      await tester.tap(find.text('生成二维码'));
      await tester.pump();

      expect(find.text('登录失败'), findsOneWidget);
      expect(find.text('原生登录链路尚未接入'), findsOneWidget);
    });

    testWidgets('替身网关：生成后展示二维码并切「重新生成二维码」', (WidgetTester tester) async {
      await _pump(
        tester,
        CloudDriveQrLoginSheet(
          driveType: CloudDriveType.quark,
          gateway: _SheetGateway(),
        ),
      );

      await tester.tap(find.text('生成二维码'));
      await tester.pump();

      expect(find.text('等待扫码'), findsOneWidget);
      expect(find.text('重新生成二维码'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
    });
  });

  group('CloudDriveSmsLoginSheet', () {
    testWidgets('初始态：标题 + 手机号 / 验证码表单 + 主按钮', (WidgetTester tester) async {
      await _pump(
        tester,
        const CloudDriveSmsLoginSheet(driveType: CloudDriveType.guangya),
      );

      expect(find.text('光鸭网盘 授权'), findsOneWidget);
      expect(find.text('获取验证码'), findsOneWidget);
      expect(find.text('验证码登录'), findsOneWidget);
      expect(find.text('输入手机号后获取验证码'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('cloud_login_phone')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('cloud_login_code')),
        findsOneWidget,
      );
    });

    testWidgets('未接入网关：获取验证码即报 Node 未就绪', (WidgetTester tester) async {
      await _pump(
        tester,
        const CloudDriveSmsLoginSheet(
          driveType: CloudDriveType.pan139,
          gateway: UnavailableCloudDriveLoginGateway(),
        ),
      );

      await tester.enterText(
        find.byKey(const ValueKey<String>('cloud_login_phone')),
        '13800000000',
      );
      await tester.pump();
      await tester.tap(find.text('获取验证码'));
      await tester.pump();

      expect(find.text('登录失败'), findsOneWidget);
      expect(find.text('Node 常驻系统未就绪'), findsOneWidget);
    });
  });

  group('CloudDriveAccountLoginSheet', () {
    testWidgets('初始态：标题 + 账号 / 密码表单 + 状态 + 主按钮', (WidgetTester tester) async {
      await _pump(
        tester,
        const CloudDriveAccountLoginSheet(driveType: CloudDriveType.pan123),
      );

      expect(find.text('123云盘 账号登录'), findsOneWidget);
      expect(find.text('输入账号密码登录'), findsOneWidget);
      expect(find.text('登录并保存'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('cloud_login_account')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('cloud_login_password')),
        findsOneWidget,
      );
      expect(find.textContaining('账号 + 密码'), findsOneWidget);
    });

    testWidgets('未接入网关：填账号密码后点「登录并保存」即报 Node 未就绪', (WidgetTester tester) async {
      await _pump(
        tester,
        const CloudDriveAccountLoginSheet(
          driveType: CloudDriveType.woniu4k,
          gateway: UnavailableCloudDriveLoginGateway(),
        ),
      );

      await tester.enterText(
        find.byKey(const ValueKey<String>('cloud_login_account')),
        'woniu',
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('cloud_login_password')),
        'secret',
      );
      await tester.pump();
      await tester.tap(find.text('登录并保存'));
      await tester.pump();

      expect(find.text('登录失败'), findsOneWidget);
      expect(find.text('Node 常驻系统未就绪'), findsOneWidget);
    });
  });

  group('CloudDriveWebLoginSheet', () {
    testWidgets('初始态：标题 + 官方地址 + 复制/打开 + 粘贴框 + 主按钮', (WidgetTester tester) async {
      await _pump(
        tester,
        const CloudDriveWebLoginSheet(driveType: CloudDriveType.pan123),
      );

      expect(find.text('123云盘 网页登录兜底'), findsOneWidget);
      expect(find.text('https://www.123pan.com/login'), findsOneWidget);
      expect(find.text('复制链接'), findsOneWidget);
      expect(find.text('打开网页'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('cloud_login_web_secret')),
        findsOneWidget,
      );
      expect(find.text('等待粘贴 Token / Cookie'), findsOneWidget);
      expect(find.text('保存并授权'), findsOneWidget);
    });

    testWidgets('空凭据：主按钮禁用，点击不触发落盘', (WidgetTester tester) async {
      int calls = 0;
      await _pump(
        tester,
        CloudDriveWebLoginSheet(
          driveType: CloudDriveType.uc,
          saver:
              ({required CloudDriveType type, required String secret}) async {
            calls += 1;
          },
        ),
      );

      await tester.tap(find.text('保存并授权'), warnIfMissed: false);
      await tester.pump();

      expect(calls, 0);
      expect(find.text('等待粘贴 Token / Cookie'), findsOneWidget);

      // 粘贴后恢复可点（按钮仍为文案「保存并授权」）。
      await tester.enterText(
        find.byKey(const ValueKey<String>('cloud_login_web_secret')),
        '__pus=abc',
      );
      await tester.pump();
      expect(find.text('保存并授权'), findsOneWidget);
    });

    testWidgets('粘贴后保存 → 成功态且落盘收到去空格凭据', (WidgetTester tester) async {
      CloudDriveType? gotType;
      String? gotSecret;
      await _pump(
        tester,
        CloudDriveWebLoginSheet(
          driveType: CloudDriveType.baidu,
          saver:
              ({required CloudDriveType type, required String secret}) async {
            gotType = type;
            gotSecret = secret;
          },
        ),
      );

      await tester.enterText(
        find.byKey(const ValueKey<String>('cloud_login_web_secret')),
        '  BDUSS=abc; STOKEN=def  ',
      );
      await tester.pump();
      await tester.tap(find.text('保存并授权'));
      await tester.pump();

      expect(gotType, CloudDriveType.baidu);
      expect(gotSecret, 'BDUSS=abc; STOKEN=def');
      expect(find.text('已保存到授权中心'), findsOneWidget);
      expect(find.text('已保存'), findsOneWidget);
    });

    testWidgets('落盘抛错 → 失败态 + 错误文案', (WidgetTester tester) async {
      await _pump(
        tester,
        CloudDriveWebLoginSheet(
          driveType: CloudDriveType.xunlei,
          saver:
              ({required CloudDriveType type, required String secret}) async {
            throw StateError('boom');
          },
        ),
      );

      await tester.enterText(
        find.byKey(const ValueKey<String>('cloud_login_web_secret')),
        'cookie',
      );
      await tester.pump();
      await tester.tap(find.text('保存并授权'));
      await tester.pump();

      expect(find.text('保存失败'), findsOneWidget);
      expect(find.textContaining('保存失败：'), findsOneWidget);
    });

    testWidgets('openCloudDriveLoginSheet：网页兜底动作打开网页登录 Sheet', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => ElevatedButton(
                onPressed: () => openCloudDriveLoginSheet(
                  context,
                  type: CloudDriveType.pan189,
                  action: '网页兜底',
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('天翼云盘 网页登录兜底'), findsOneWidget);
    });
  });

  group('saveWebCredentialToStore', () {
    setUpAll(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      await PrefsManager.instance.init();
    });

    test('写入 cloud_drive_credentials_v1：authType=webView + cookie + valid', () async {
      await saveWebCredentialToStore(
        type: CloudDriveType.pan139,
        secret: 'SESSION=xyz',
      );
      final CloudDriveCredentialStore store =
          CloudDriveCredentialStore(PrefsManager.instance);
      final CloudDriveCredential? credential =
          await store.credential(CloudDriveType.pan139);
      expect(credential, isNotNull);
      expect(credential!.authType, CloudDriveAuthType.webView);
      expect(credential.cookie, 'SESSION=xyz');
      expect(credential.state, CloudDriveAuthState.valid);
      expect(credential.lastCheckedAt, isNotNull);
    });
  });
}
