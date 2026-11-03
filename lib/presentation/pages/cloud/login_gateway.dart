/// 网盘登录网关（批次 F · F-02 接缝）。
///
/// 把「原生扫码 / Node 扫码 / Node 短信验证码 / Node 账号 / 网页兜底」的**协议
/// 调用**抽象为接口，UI 与状态机（`login_controller.dart`）只依赖本抽象：
/// - 真实实现随 F-04（阿里 extscreen 链）、F-05（B站扫码 + 百度专用代理）与
///   Node 常驻系统 HTTP 客户端补齐；
/// - 本段提供 [UnavailableCloudDriveLoginGateway] 作为缺省实现，行为对齐 iOS
///   —— Node 未就绪时 `NodeLoginAPIClient.request` 抛 `nodeNotReady`，页面显示
///   「Node 常驻系统未就绪」（`NodeLoginViews.swift:22`）。
library;

import '../../../domain/entities/cloud/cloud_drive.dart';
import '../../../domain/entities/cloud/cloud_drive_login.dart';

/// 扫码任务句柄（Node/原生协议返回 `taskId` + 二维码 data URL）。
///
/// `qrDataUrl` 两种形态：
/// - 图片 data URL（`data:image/png;base64,...` 或裸 base64）→ 直接渲染图片；
/// - **`qr_data:<文本>`** 前缀 → 文本为待编码的授权链接，由表现层本地生成二维码
///   （C-盘3：PG/extscreen 返回链接而非图片）。
typedef CloudDriveQrTask = ({String taskId, String qrDataUrl});

/// `qrDataUrl` 承载「待编码文本」的前缀（见 [CloudDriveQrTask]）。
const String kQrDataContentPrefix = 'qr_data:';

/// 取 [CloudDriveQrTask.qrDataUrl] 中的待编码文本（非该形态返回 null）。
String? qrContentOf(String? qrDataUrl) {
  if (qrDataUrl == null) return null;
  if (!qrDataUrl.startsWith(kQrDataContentPrefix)) return null;
  final String content = qrDataUrl.substring(kQrDataContentPrefix.length);
  return content.isEmpty ? null : content;
}

/// 账号登录提交结果（对齐 iOS `NodePan189AccountLoginView.submit` 的 `sms` 分支）。
///
/// [needSms] 为 true 表示 Node 已接受账号密码但需**短信二次校验**
/// （天翼 189 开启二次校验时）；此时**尚未登录成功**，须由 UI 追加验证码后
/// 调用 [CloudDriveLoginGateway.submitAccountSmsCode] 完成。否则登录成功。
typedef CloudDriveAccountResult = ({bool needSms, String message});

/// 登录网关错误（文案对齐 iOS `NodeLoginError`）。
class CloudDriveLoginException implements Exception {
  /// 构造。
  const CloudDriveLoginException(this.message);

  /// 面向用户的错误文案。
  final String message;

  @override
  String toString() => message;
}

/// 登录网关「终端态」异常（对齐 iOS `NodeLoginError.terminal`）。
///
/// 表示 Node / 原生侧任务已**不可恢复地失效**（任务不存在、已结束、已过期、
/// 引擎重启清表）。此类错误**不可当作瞬时网络错误重试**：控制器必须停止轮询、
/// 自动换一张新码（对齐 iOS `handleTerminal` → `regenerate`），
/// 超过上限后才落失败态。
class CloudDriveTerminalLoginException extends CloudDriveLoginException {
  /// 构造。
  const CloudDriveTerminalLoginException(super.message);
}

/// 网盘登录网关抽象。
///
/// 所有方法失败时抛 [CloudDriveLoginException]（UI 统一渲染到错误行）。
abstract interface class CloudDriveLoginGateway {
  /// 发起扫码：返回任务句柄（[CloudDriveQrTask]）。
  ///
  /// [providerOverride] 覆盖默认 provider（UCNode 两步登录第 2 步用 `ucToken`）。
  Future<CloudDriveQrTask> startQrLogin({
    required CloudDriveType type,
    required CloudDriveLoginMode mode,
    String? providerOverride,
  });

  /// 轮询一次扫码任务：返回下一刻阶段。
  ///
  /// 阶段推进：`waitingScan → scanned → exchanging → success`；终端态即停轮询。
  Future<CloudDriveLoginPhase> pollQrLogin({
    required CloudDriveType type,
    required CloudDriveLoginMode mode,
    required String taskId,
    String? providerOverride,
  });

  /// 取消扫码任务（幂等；失败不抛）。
  Future<void> cancelQrLogin(String taskId);

  /// 发送短信验证码：返回 Node 侧 `taskId`。
  Future<String> sendSmsCode({
    required CloudDriveType type,
    required String phone,
  });

  /// 提交短信验证码完成登录（成功后由实现侧回收凭据）。
  Future<void> submitSmsCode({
    required CloudDriveType type,
    required String taskId,
    required String code,
  });

  /// 短信登录过程中若需滑块验证，返回验证码页面地址（对齐 iOS 139 `captchaUrl`）。
  ///
  /// 供 UI 在短信 Sheet 内嵌 WebView 过滑块（Web-R3）；无则返回 null。
  String? pendingCaptchaUrl(CloudDriveType type);

  /// 账号密码登录（Node 托管盘：123 / 蜗牛 / 天翼 等）。
  ///
  /// 对齐 iOS `NodePan123LoginView` / `NodeWoniu4kLoginView` 的
  /// `PUT /website/api/pan123/account {account, password}` 语义，
  /// 成功后由实现侧回收凭据并同步到本机安全存储。
  ///
  /// [captchaCode] 为图形验证码（蜗牛 `woniu4k` 需要；其余传空）。
  ///
  /// 返回 [CloudDriveAccountResult]：`needSms == true` 表示 Node 要求短信二次校验
  /// （天翼 189，对齐 iOS `NodePan189AccountLoginView.submit` 的 `needSms` 分支），
  /// 此时未登录成功、不回收凭据；否则登录成功并由实现侧回收凭据。
  Future<CloudDriveAccountResult> submitAccountLogin({
    required CloudDriveType type,
    required CloudDriveLoginMode mode,
    required String account,
    required String password,
    String captchaCode = '',
  });

  /// 账号登录的**短信二次校验**（对齐 iOS 天翼 189 `POST /website/api/pan189/sms/login`）。
  ///
  /// 仅当 [submitAccountLogin] 返回 `needSms == true` 时调用；成功后回收凭据。
  Future<void> submitAccountSmsCode({
    required CloudDriveType type,
    required String code,
  });

  /// 获取账号登录所需的**图形验证码**图片（data URL；无则 null）。
  ///
  /// 对齐 iOS `NodeWoniu4kLoginView.fetchVerify`：进入页面即拉取，点击可刷新；
  /// 实现侧同时缓存服务端 `taskId` 供 [submitAccountLogin] 使用。
  Future<String?> loadAccountCaptcha(CloudDriveType type);
}

/// 缺省网关：登录链尚未接入，统一抛「未就绪」。
///
/// 文案分档对齐 iOS —— Node 托管档报「Node 常驻系统未就绪」，原生档报
/// 「原生登录链路尚未接入」（F-04 / F-05 落地）。
class UnavailableCloudDriveLoginGateway implements CloudDriveLoginGateway {
  /// 构造。
  const UnavailableCloudDriveLoginGateway();

  String _messageFor(CloudDriveLoginMode mode) =>
      mode.usesNode ? 'Node 常驻系统未就绪' : '原生登录链路尚未接入';

  @override
  Future<CloudDriveQrTask> startQrLogin({
    required CloudDriveType type,
    required CloudDriveLoginMode mode,
    String? providerOverride,
  }) async =>
      throw CloudDriveLoginException(_messageFor(mode));

  @override
  Future<CloudDriveLoginPhase> pollQrLogin({
    required CloudDriveType type,
    required CloudDriveLoginMode mode,
    required String taskId,
    String? providerOverride,
  }) async =>
      throw CloudDriveLoginException(_messageFor(mode));

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
