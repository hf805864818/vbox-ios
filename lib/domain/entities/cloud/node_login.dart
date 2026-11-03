/// 网盘登录 · Node 常驻系统协议常量与路由（批次 F · F-P16）。
///
/// 唯一真相源：`vbox/Views/NodeLoginViews.swift`（`NodeLoginAPIClient.request`）
///   · 通用扫码（L661/L707/L791）：`/website/api/login/{start,poll,cancel}`；
///   · 光鸭短信（L238/L262）：`/website/api/guangya/sms/{send,login}`；
///   · 蜗牛账号（L423/L452）：`/website/api/woniu4k/{verify,login}`；
///   · 123 账号（L895）：`/website/api/pan123/account`；
///   · 139 短信（L1060/L1081）：`/website/api/new139/{sms/send,login}`；
///   · 189 账号/短信（L1275/L1257）：`/website/api/pan189/{account,sms/login}`；
///   · 迅雷短信（L1426/L1445）：`/website/api/thunder/sms/{send,login}`。
///
/// 本文件只承载**纯领域**常量与「网盘 → 登录方式/Provider」映射，不含网络调用。
library;

import 'cloud_drive.dart';

/// Node 常驻系统登录端点（对齐 iOS `NodeLoginAPIClient.request` 的 path）。
abstract final class NodeLoginPaths {
  /// 通用扫码：发起任务。
  static const String qrStart = '/website/api/login/start';

  /// 通用扫码：轮询一次。
  static const String qrPoll = '/website/api/login/poll';

  /// 通用扫码：取消任务。
  static const String qrCancel = '/website/api/login/cancel';

  /// 光鸭：发送短信。
  static const String guangyaSmsSend = '/website/api/guangya/sms/send';

  /// 光鸭：短信登录。
  static const String guangyaSmsLogin = '/website/api/guangya/sms/login';

  /// 蜗牛：获取图形验证码。
  static const String woniuVerify = '/website/api/woniu4k/verify';

  /// 蜗牛：账号登录。
  static const String woniuLogin = '/website/api/woniu4k/login';

  /// 123：账号登录。
  static const String pan123Account = '/website/api/pan123/account';

  /// 139：发送短信。
  static const String new139SmsSend = '/website/api/new139/sms/send';

  /// 139：短信登录。
  static const String new139Login = '/website/api/new139/login';

  /// 189：账号登录。
  static const String pan189Account = '/website/api/pan189/account';

  /// 189：短信登录。
  static const String pan189SmsLogin = '/website/api/pan189/sms/login';

  /// 迅雷：发送短信。
  static const String thunderSmsSend = '/website/api/thunder/sms/send';

  /// 迅雷：短信登录。
  static const String thunderSmsLogin = '/website/api/thunder/sms/login';

  /// 百度 Node：代取 bdstoken（Node OpenSSL 栈三跳种码 + gettemplatevariable）。
  static const String baiduBdstoken = '/website/api/baidu/bdstoken';
}

/// Node 登录路由（对齐 iOS 各盘视图的 provider / 端点分派）。
abstract final class NodeLoginRouting {
  /// 扫码 provider（`CloudDriveType` → Node `provider` 参数）。
  ///
  /// 对应 iOS：115 `NodeScanLoginRootView(provider:"pan115")`、
  /// 夸克Node `provider:"quark"`、百度Node `provider:"baidu"`、
  /// UCNode 两步第 1 步 `provider:"ucCookie"`。
  static const Map<CloudDriveType, String> qrProviders =
      <CloudDriveType, String>{
    CloudDriveType.one15: 'pan115',
    CloudDriveType.quarkNode: 'quark',
    CloudDriveType.baiduNode: 'baidu',
    CloudDriveType.ucNode: 'ucCookie',
  };

  /// 短信验证码登录盘（光鸭 / 139 / 迅雷）。
  static const Set<CloudDriveType> smsTypes = <CloudDriveType>{
    CloudDriveType.guangya,
    CloudDriveType.pan139,
    CloudDriveType.xunlei,
  };

  /// 账号密码登录盘（123 / 189 / 蜗牛）。
  ///
  /// 蜗牛需图形验证码（`/woniou4k/verify`），由网关 `loadAccountCaptcha` 供图。
  static const Set<CloudDriveType> accountTypes = <CloudDriveType>{
    CloudDriveType.pan123,
    CloudDriveType.pan189,
    CloudDriveType.woniu4k,
  };

  /// 取扫码 provider（不支持返回 null）。
  static String? qrProviderFor(CloudDriveType type) => qrProviders[type];
}