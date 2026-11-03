/// 网盘登录领域模型单测（批次 F · F-02）。
///
/// 对齐基准：iOS `authButtonLabel` / `qrLoginState` 分档与文案
/// （`SettingsViews.swift` / `NodeLoginViews.swift`）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/cloud/cloud_drive.dart';
import 'package:vbox/domain/entities/cloud/cloud_drive_login.dart';

void main() {
  group('CloudDriveLoginMode', () {
    test('动作按钮文案解析逐档对齐授权中心', () {
      expect(
        CloudDriveLoginMode.fromActionLabel('原生扫码'),
        CloudDriveLoginMode.nativeQr,
      );
      expect(
        CloudDriveLoginMode.fromActionLabel('扫码授权'),
        CloudDriveLoginMode.nativeQr,
      );
      expect(
        CloudDriveLoginMode.fromActionLabel('扫码登录'),
        CloudDriveLoginMode.nativeQr,
      );
      expect(
        CloudDriveLoginMode.fromActionLabel('Node扫码登录'),
        CloudDriveLoginMode.nodeQr,
      );
      expect(
        CloudDriveLoginMode.fromActionLabel('Node账号登录'),
        CloudDriveLoginMode.nodeAccount,
      );
      expect(
        CloudDriveLoginMode.fromActionLabel('账号登录'),
        CloudDriveLoginMode.nodeAccount,
      );
      expect(
        CloudDriveLoginMode.fromActionLabel('Node验证码登录'),
        CloudDriveLoginMode.nodeSms,
      );
      expect(
        CloudDriveLoginMode.fromActionLabel('手机验证码登录'),
        CloudDriveLoginMode.nodeSms,
      );
      expect(
        CloudDriveLoginMode.fromActionLabel('网页登录兜底'),
        CloudDriveLoginMode.webFallback,
      );
      expect(
        CloudDriveLoginMode.fromActionLabel('网页兜底'),
        CloudDriveLoginMode.webFallback,
      );
      // 未知文案回退原生扫码（iOS 默认档）。
      expect(
        CloudDriveLoginMode.fromActionLabel('未知动作'),
        CloudDriveLoginMode.nativeQr,
      );
    });

    test('usesNode / isQr / isSms / isWeb 分档正确', () {
      expect(CloudDriveLoginMode.nativeQr.usesNode, isFalse);
      expect(CloudDriveLoginMode.pgQr.usesNode, isFalse);
      expect(CloudDriveLoginMode.webFallback.usesNode, isFalse);
      expect(CloudDriveLoginMode.nodeQr.usesNode, isTrue);
      expect(CloudDriveLoginMode.nodeSms.usesNode, isTrue);
      expect(CloudDriveLoginMode.nodeAccount.usesNode, isTrue);

      expect(CloudDriveLoginMode.nativeQr.isQr, isTrue);
      expect(CloudDriveLoginMode.nodeQr.isQr, isTrue);
      expect(CloudDriveLoginMode.pgQr.isQr, isTrue);
      expect(CloudDriveLoginMode.nodeSms.isQr, isFalse);
      expect(CloudDriveLoginMode.nodeAccount.isQr, isFalse);
      expect(CloudDriveLoginMode.webFallback.isQr, isFalse);

      expect(CloudDriveLoginMode.nodeSms.isSms, isTrue);
      expect(CloudDriveLoginMode.nativeQr.isSms, isFalse);
      expect(CloudDriveLoginMode.webFallback.isWeb, isTrue);
      expect(CloudDriveLoginMode.nativeQr.isWeb, isFalse);
    });
  });

  group('CloudDriveLoginPhase', () {
    test('displayText 逐档对齐 iOS 状态文案', () {
      expect(CloudDriveLoginPhase.idle.displayText, '准备生成二维码');
      expect(CloudDriveLoginPhase.loading.displayText, '正在生成二维码…');
      expect(CloudDriveLoginPhase.waitingScan.displayText, '等待扫码');
      expect(CloudDriveLoginPhase.scanned.displayText, '已扫码，请在手机上确认');
      expect(CloudDriveLoginPhase.exchanging.displayText, '正在确认登录…');
      expect(CloudDriveLoginPhase.saving.displayText, '正在保存凭据…');
      expect(CloudDriveLoginPhase.success.displayText, '登录成功');
      expect(CloudDriveLoginPhase.failed.displayText, '登录失败');
    });

    test('isPolling / canCancel / isTerminal / tone 分档', () {
      expect(CloudDriveLoginPhase.idle.isPolling, isFalse);
      expect(CloudDriveLoginPhase.loading.isPolling, isTrue);
      expect(CloudDriveLoginPhase.waitingScan.isPolling, isTrue);
      expect(CloudDriveLoginPhase.scanned.isPolling, isTrue);
      expect(CloudDriveLoginPhase.exchanging.isPolling, isTrue);
      expect(CloudDriveLoginPhase.saving.isPolling, isTrue);
      expect(CloudDriveLoginPhase.success.isPolling, isFalse);
      expect(CloudDriveLoginPhase.failed.isPolling, isFalse);

      expect(CloudDriveLoginPhase.waitingScan.canCancel, isTrue);
      expect(CloudDriveLoginPhase.idle.canCancel, isFalse);

      expect(CloudDriveLoginPhase.success.isTerminal, isTrue);
      expect(CloudDriveLoginPhase.failed.isTerminal, isTrue);
      expect(CloudDriveLoginPhase.scanned.isTerminal, isFalse);

      expect(CloudDriveLoginPhase.idle.tone, CloudDriveLoginTone.neutral);
      expect(CloudDriveLoginPhase.loading.tone, CloudDriveLoginTone.busy);
      expect(CloudDriveLoginPhase.waitingScan.tone, CloudDriveLoginTone.active);
      expect(CloudDriveLoginPhase.scanned.tone, CloudDriveLoginTone.pending);
      expect(CloudDriveLoginPhase.success.tone, CloudDriveLoginTone.ok);
      expect(CloudDriveLoginPhase.failed.tone, CloudDriveLoginTone.error);
    });
  });

  group('CloudDriveWebLogin', () {
    test('urlFor 逐档对齐 iOS 各 LoginHelper 官方登录地址', () {
      expect(
        CloudDriveWebLogin.urlFor(CloudDriveType.uc),
        'https://drive.uc.cn/',
      );
      expect(
        CloudDriveWebLogin.urlFor(CloudDriveType.quark),
        'https://pan.quark.cn/',
      );
      expect(
        CloudDriveWebLogin.urlFor(CloudDriveType.baidu),
        'https://pan.baidu.com/',
      );
      expect(
        CloudDriveWebLogin.urlFor(CloudDriveType.one15),
        'https://115.com/?ct=login',
      );
      expect(
        CloudDriveWebLogin.urlFor(CloudDriveType.pan123),
        'https://www.123pan.com/login',
      );
      expect(
        CloudDriveWebLogin.urlFor(CloudDriveType.pan139),
        'https://yun.139.com/w/',
      );
      expect(
        CloudDriveWebLogin.urlFor(CloudDriveType.pan189),
        'https://cloud.189.cn/web/login.html',
      );
      expect(
        CloudDriveWebLogin.urlFor(CloudDriveType.xunlei),
        'https://i.xunlei.com/xluser/login.html',
      );
    });

    test('supports 覆盖全部带网页兜底按钮的网盘', () {
      const List<CloudDriveType> withWeb = <CloudDriveType>[
        CloudDriveType.uc,
        CloudDriveType.ucNode,
        CloudDriveType.quark,
        CloudDriveType.quarkNode,
        CloudDriveType.baidu,
        CloudDriveType.baiduNode,
        CloudDriveType.one15,
        CloudDriveType.pan123,
        CloudDriveType.pan139,
        CloudDriveType.pan189,
        CloudDriveType.xunlei,
        // P0-A2：阿里补齐网页兜底（OpenList 授权页，对齐 iOS saveWebViewCookie
        // ali 分支——提取值写 refreshToken 而非 cookie）。
        CloudDriveType.ali,
      ];
      for (final CloudDriveType type in withWeb) {
        expect(CloudDriveWebLogin.supports(type), isTrue, reason: type.id);
        expect(CloudDriveWebLogin.urlFor(type), isNotNull, reason: type.id);
      }
    });

    test('阿里网页兜底指向 OpenList 授权页', () {
      expect(
        CloudDriveWebLogin.urlFor(CloudDriveType.ali),
        'https://api.oplist.org/?driver=alicloud'
        '&driver_txt=alicloud_qr&server_use=true&server_set=true',
      );
    });

    test('无网页兜底入口的网盘（Node 托管三盘）返回 false / null', () {
      const List<CloudDriveType> withoutWeb = <CloudDriveType>[
        CloudDriveType.guangya,
        CloudDriveType.woniu4k,
        CloudDriveType.bilibili,
      ];
      for (final CloudDriveType type in withoutWeb) {
        expect(CloudDriveWebLogin.supports(type), isFalse, reason: type.id);
        expect(CloudDriveWebLogin.urlFor(type), isNull, reason: type.id);
      }
    });

    test('credentialHint 分 Cookie / Cookie+Token 两档', () {
      expect(
        CloudDriveWebLogin.credentialHint(CloudDriveType.uc),
        '粘贴网页登录后的 Cookie',
      );
      expect(
        CloudDriveWebLogin.credentialHint(CloudDriveType.pan123),
        '粘贴网页登录后的 Cookie / Token',
      );
    });
  });
}
