/// 网盘登录会话控制器单测（批次 F · F-02）。
///
/// 以替身网关驱动状态机，覆盖扫码成功 / 失败 / 取消与短信验证码全流程。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/cloud/cloud_drive.dart';
import 'package:vbox/domain/entities/cloud/cloud_drive_login.dart';
import 'package:vbox/presentation/pages/cloud/login_controller.dart';
import 'package:vbox/presentation/pages/cloud/login_gateway.dart';

/// 替身网关：按脚本推进轮询阶段。
class _FakeGateway implements CloudDriveLoginGateway {
  _FakeGateway({
    this.startError,
    List<CloudDriveLoginPhase> pollScript = const <CloudDriveLoginPhase>[
      CloudDriveLoginPhase.scanned,
      CloudDriveLoginPhase.success,
    ],
    this.smsSendError,
    this.smsSubmitError,
    this.accountError,
    this.accountNeedSms = false,
    this.accountSmsMessage = '',
  }) : _pollScript = List<CloudDriveLoginPhase>.of(pollScript);

  static const String _qrDataUrl = 'data:image/png;base64,AAAA';
  static const String _smsTaskId = 'sms-task-1';

  final String? startError;
  final List<CloudDriveLoginPhase> _pollScript;
  final String? smsSendError;
  final String? smsSubmitError;
  final String? accountError;
  final bool accountNeedSms;
  final String accountSmsMessage;

  int startCalls = 0;
  int cancelCalls = 0;
  int pollCalls = 0;
  String? lastTaskId;
  String? lastPhone;
  String? lastCode;
  String? lastAccount;
  String? lastPassword;
  String? lastAccountSmsCode;
  String? lastProviderOverride;

  @override
  Future<CloudDriveQrTask> startQrLogin({
    required CloudDriveType type,
    required CloudDriveLoginMode mode,
    String? providerOverride,
  }) async {
    startCalls += 1;
    lastProviderOverride = providerOverride;
    final String? error = startError;
    if (error != null) throw CloudDriveLoginException(error);
    return (taskId: 'qr-task-1', qrDataUrl: _qrDataUrl);
  }

  @override
  Future<CloudDriveLoginPhase> pollQrLogin({
    required CloudDriveType type,
    required CloudDriveLoginMode mode,
    required String taskId,
    String? providerOverride,
  }) async {
    pollCalls += 1;
    lastTaskId = taskId;
    if (_pollScript.isEmpty) return CloudDriveLoginPhase.success;
    return _pollScript.removeAt(0);
  }

  @override
  Future<void> cancelQrLogin(String taskId) async {
    cancelCalls += 1;
  }

  @override
  Future<String> sendSmsCode({
    required CloudDriveType type,
    required String phone,
  }) async {
    lastPhone = phone;
    final String? error = smsSendError;
    if (error != null) throw CloudDriveLoginException(error);
    return _smsTaskId;
  }

  @override
  Future<void> submitSmsCode({
    required CloudDriveType type,
    required String taskId,
    required String code,
  }) async {
    lastTaskId = taskId;
    lastCode = code;
    final String? error = smsSubmitError;
    if (error != null) throw CloudDriveLoginException(error);
  }

  @override
  Future<CloudDriveAccountResult> submitAccountLogin({
    required CloudDriveType type,
    required CloudDriveLoginMode mode,
    required String account,
    required String password,
    String captchaCode = '',
  }) async {
    lastAccount = account;
    lastPassword = password;
    final String? error = accountError;
    if (error != null) throw CloudDriveLoginException(error);
    return (needSms: accountNeedSms, message: accountSmsMessage);
  }

  @override
  Future<void> submitAccountSmsCode({
    required CloudDriveType type,
    required String code,
  }) async {
    lastAccountSmsCode = code;
    final String? error = smsSubmitError;
    if (error != null) throw CloudDriveLoginException(error);
  }

  @override
  String? pendingCaptchaUrl(CloudDriveType type) => null;

  @override
  Future<String?> loadAccountCaptcha(CloudDriveType type) async => null;
}

CloudDriveLoginController _qrController(
  CloudDriveLoginGateway gateway, {
  CloudDriveType type = CloudDriveType.baidu,
  CloudDriveLoginMode mode = CloudDriveLoginMode.nativeQr,
}) =>
    CloudDriveLoginController(
      driveType: type,
      mode: mode,
      gateway: gateway,
      // 长间隔避免测试期间自动轮询，改为手动 pollOnce 驱动。
      pollInterval: const Duration(minutes: 1),
    );

void main() {
  group('扫码流程', () {
    test('generateQr 成功 → waitingScan + 二维码 + 主按钮切「重新生成」', () async {
      final _FakeGateway gateway = _FakeGateway();
      final CloudDriveLoginController controller = _qrController(gateway);
      addTearDown(controller.dispose);

      await controller.generateQr();

      expect(controller.phase, CloudDriveLoginPhase.waitingScan);
      expect(controller.qrDataUrl, 'data:image/png;base64,AAAA');
      expect(controller.error, isNull);
      expect(controller.message, contains('百度网盘'));
      expect(controller.primaryLabel, '重新生成二维码');
    });

    test('轮询按 scanned → success 推进并停轮询', () async {
      final _FakeGateway gateway = _FakeGateway();
      final CloudDriveLoginController controller = _qrController(gateway);
      addTearDown(controller.dispose);

      await controller.generateQr();
      await controller.pollOnce();
      expect(controller.phase, CloudDriveLoginPhase.scanned);

      await controller.pollOnce();
      expect(controller.phase, CloudDriveLoginPhase.success);
      expect(controller.message, '登录成功');
      expect(gateway.lastTaskId, 'qr-task-1');
    });

    test('generateQr 失败（网关抛错）→ failed + 错误文案', () async {
      final _FakeGateway gateway = _FakeGateway(startError: '原生登录链路尚未接入');
      final CloudDriveLoginController controller = _qrController(gateway);
      addTearDown(controller.dispose);

      await controller.generateQr();

      expect(controller.phase, CloudDriveLoginPhase.failed);
      expect(controller.error, '原生登录链路尚未接入');
      expect(controller.primaryLabel, '生成二维码');
    });

    test('cancel 回 idle 并通知网关取消', () async {
      final _FakeGateway gateway = _FakeGateway();
      final CloudDriveLoginController controller = _qrController(gateway);
      addTearDown(controller.dispose);

      await controller.generateQr();
      await controller.cancel();

      expect(controller.phase, CloudDriveLoginPhase.idle);
      expect(controller.qrDataUrl, isNull);
      expect(gateway.cancelCalls, 1);
    });

    test('未发起时 pollOnce 为空操作', () async {
      final _FakeGateway gateway = _FakeGateway();
      final CloudDriveLoginController controller = _qrController(gateway);
      addTearDown(controller.dispose);

      await controller.pollOnce();

      expect(gateway.pollCalls, 0);
      expect(controller.phase, CloudDriveLoginPhase.idle);
    });
  });

  group('短信验证码流程', () {
    CloudDriveLoginController smsController(_FakeGateway gateway) =>
        CloudDriveLoginController(
          driveType: CloudDriveType.guangya,
          mode: CloudDriveLoginMode.nodeSms,
          gateway: gateway,
        );

    test('sendSms 成功 → 记录 taskId + 启动 60s 冷却', () async {
      final _FakeGateway gateway = _FakeGateway();
      final CloudDriveLoginController controller = smsController(gateway);
      addTearDown(controller.dispose);

      await controller.sendSms(' 13800000000 ');

      expect(gateway.lastPhone, '13800000000');
      expect(controller.phase, CloudDriveLoginPhase.waitingScan);
      expect(controller.countdown, 60);
      expect(controller.smsCooldownActive, isTrue);
      expect(controller.primaryLabel, '验证码登录');
    });

    test('手机号为空 → 报「请输入手机号」且不调用网关', () async {
      final _FakeGateway gateway = _FakeGateway();
      final CloudDriveLoginController controller = smsController(gateway);
      addTearDown(controller.dispose);

      await controller.sendSms('   ');

      expect(controller.error, '请输入手机号');
      expect(gateway.lastPhone, isNull);
    });

    test('sendSms 失败（网关抛错）→ failed + 错误文案且不计冷却', () async {
      final _FakeGateway gateway = _FakeGateway(smsSendError: '短信服务暂不可用');
      final CloudDriveLoginController controller = smsController(gateway);
      addTearDown(controller.dispose);

      await controller.sendSms('13800000000');

      expect(controller.phase, CloudDriveLoginPhase.failed);
      expect(controller.error, '短信服务暂不可用');
      expect(controller.smsCooldownActive, isFalse);
    });

    test('未获取验证码就登录 → 报「请先获取验证码」', () async {
      final _FakeGateway gateway = _FakeGateway();
      final CloudDriveLoginController controller = smsController(gateway);
      addTearDown(controller.dispose);

      await controller.loginWithSms('1234');

      expect(controller.error, '请先获取验证码');
      expect(gateway.lastCode, isNull);
    });

    test('sendSms → loginWithSms 成功', () async {
      final _FakeGateway gateway = _FakeGateway();
      final CloudDriveLoginController controller = smsController(gateway);
      addTearDown(controller.dispose);

      await controller.sendSms('13800000000');
      await controller.loginWithSms(' 1234 ');

      expect(gateway.lastTaskId, 'sms-task-1');
      expect(gateway.lastCode, '1234');
      expect(controller.phase, CloudDriveLoginPhase.success);
    });

    test('submitSmsCode 抛错 → failed + 错误文案', () async {
      final _FakeGateway gateway = _FakeGateway(smsSubmitError: '验证码错误');
      final CloudDriveLoginController controller = smsController(gateway);
      addTearDown(controller.dispose);

      await controller.sendSms('13800000000');
      await controller.loginWithSms('0000');

      expect(controller.phase, CloudDriveLoginPhase.failed);
      expect(controller.error, '验证码错误');
    });
  });

  group('账号密码流程', () {
    CloudDriveLoginController accountController(_FakeGateway gateway) =>
        CloudDriveLoginController(
          driveType: CloudDriveType.pan123,
          mode: CloudDriveLoginMode.nodeAccount,
          gateway: gateway,
        );

    test('loginWithAccount 成功 → success 且账号去空格', () async {
      final _FakeGateway gateway = _FakeGateway();
      final CloudDriveLoginController controller = accountController(gateway);
      addTearDown(controller.dispose);

      await controller.loginWithAccount(' 123user ', 'secret');

      expect(gateway.lastAccount, '123user');
      expect(gateway.lastPassword, 'secret');
      expect(controller.phase, CloudDriveLoginPhase.success);
      expect(controller.error, isNull);
    });

    test('账号为空 → 报「请输入账号」且不调用网关', () async {
      final _FakeGateway gateway = _FakeGateway();
      final CloudDriveLoginController controller = accountController(gateway);
      addTearDown(controller.dispose);

      await controller.loginWithAccount('   ', 'secret');

      expect(controller.error, '请输入账号');
      expect(gateway.lastAccount, isNull);
    });

    test('密码为空 → 报「请输入密码」且不调用网关', () async {
      final _FakeGateway gateway = _FakeGateway();
      final CloudDriveLoginController controller = accountController(gateway);
      addTearDown(controller.dispose);

      await controller.loginWithAccount('123user', '');

      expect(controller.error, '请输入密码');
      expect(gateway.lastAccount, isNull);
    });

    test('submitAccountLogin 抛错 → failed + 错误文案', () async {
      final _FakeGateway gateway = _FakeGateway(accountError: '账号或密码错误');
      final CloudDriveLoginController controller = accountController(gateway);
      addTearDown(controller.dispose);

      await controller.loginWithAccount('123user', 'bad');

      expect(controller.phase, CloudDriveLoginPhase.failed);
      expect(controller.error, '账号或密码错误');
    });

    test('缺省网关 → Node 档报「Node 常驻系统未就绪」', () async {
      final CloudDriveLoginController controller = CloudDriveLoginController(
        driveType: CloudDriveType.woniu4k,
        mode: CloudDriveLoginMode.nodeAccount,
      );
      addTearDown(controller.dispose);

      await controller.loginWithAccount('woniu', 'pwd');

      expect(controller.phase, CloudDriveLoginPhase.failed);
      expect(controller.error, 'Node 常驻系统未就绪');
    });

    test('tipText 账号档独立分档', () {
      final CloudDriveLoginController controller = accountController(
        _FakeGateway(),
      );
      addTearDown(controller.dispose);
      expect(controller.tipText, contains('账号 + 密码'));
      expect(controller.tipText, contains('授权中心'));
    });

    test('189 账号需二次校验 → idle + accountNeedsSms + 携带 Node msg', () async {
      final _FakeGateway gateway = _FakeGateway(
        accountNeedSms: true,
        accountSmsMessage: '请输入短信验证码',
      );
      final CloudDriveLoginController controller =
          accountController(gateway);
      addTearDown(controller.dispose);

      await controller.loginWithAccount('tianyi', 'pwd');

      expect(controller.accountNeedsSms, isTrue);
      expect(controller.phase, CloudDriveLoginPhase.idle);
      expect(controller.message, '请输入短信验证码');
      expect(controller.error, isNull);
    });

    test('二次校验态提交验证码 → success 并清除 accountNeedsSms', () async {
      final _FakeGateway gateway = _FakeGateway(accountNeedSms: true);
      final CloudDriveLoginController controller =
          accountController(gateway);
      addTearDown(controller.dispose);

      await controller.loginWithAccount('tianyi', 'pwd');
      await controller.loginWithAccountSms(' 8888 ');

      expect(gateway.lastAccountSmsCode, '8888');
      expect(controller.accountNeedsSms, isFalse);
      expect(controller.phase, CloudDriveLoginPhase.success);
    });

    test('二次校验态验证码为空 → 报「请输入短信验证码」且不调用网关', () async {
      final _FakeGateway gateway = _FakeGateway(accountNeedSms: true);
      final CloudDriveLoginController controller =
          accountController(gateway);
      addTearDown(controller.dispose);

      await controller.loginWithAccount('tianyi', 'pwd');
      await controller.loginWithAccountSms('   ');

      expect(controller.error, '请输入短信验证码');
      expect(gateway.lastAccountSmsCode, isNull);
    });

    test('二次校验提交失败 → failed + 错误文案', () async {
      final _FakeGateway gateway = _FakeGateway(
        accountNeedSms: true,
        smsSubmitError: '验证码错误',
      );
      final CloudDriveLoginController controller =
          accountController(gateway);
      addTearDown(controller.dispose);

      await controller.loginWithAccount('tianyi', 'pwd');
      await controller.loginWithAccountSms('0000');

      expect(controller.phase, CloudDriveLoginPhase.failed);
      expect(controller.error, '验证码错误');
    });
  });

  group('缺省网关', () {
    test('Node 档报「Node 常驻系统未就绪」，原生档报「原生登录链路尚未接入」', () async {
      final CloudDriveLoginController node = CloudDriveLoginController(
        driveType: CloudDriveType.pan139,
        mode: CloudDriveLoginMode.nodeSms,
      );
      addTearDown(node.dispose);
      await node.generateQr();
      expect(node.error, 'Node 常驻系统未就绪');

      final CloudDriveLoginController native = CloudDriveLoginController(
        driveType: CloudDriveType.ali,
        mode: CloudDriveLoginMode.nativeQr,
      );
      addTearDown(native.dispose);
      await native.generateQr();
      expect(native.error, '原生登录链路尚未接入');
    });

    test('tipText 按方式分档', () {
      final CloudDriveLoginController qr = _qrController(_FakeGateway());
      addTearDown(qr.dispose);
      expect(qr.tipText, contains('百度网盘'));

      final CloudDriveLoginController nodeQr = CloudDriveLoginController(
        driveType: CloudDriveType.baidu,
        mode: CloudDriveLoginMode.nodeQr,
      );
      addTearDown(nodeQr.dispose);
      expect(nodeQr.tipText, contains('Node 常驻系统'));
    });
  });
}
