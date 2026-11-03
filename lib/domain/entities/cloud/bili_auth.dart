/// 领域层：B 站扫码登录（批次 F · F-05）。
///
/// 对齐 iOS `BiliAuthManager.swift`（对接 Node 常驻系统
/// `/website/api/bili/login/*` 路由）：
/// - **Step 1**：`POST /website/api/bili/login/start`（无 body）→ 扁平结构
///   `{code, taskId, status, msg, qrUrl, qrImage}`，`qrImage` 为服务端已生成的
///   `data:image/png;base64,...`，客户端直接渲染（**无需本地 QR 编码库**）；
/// - **Step 2**：`POST /website/api/bili/login/poll` body `{provider, taskId}` →
///   `{code, status, terminal, msg}`；Node bundle 对「等待扫码」与「已扫码待确认」
///   都返回 `status:"waiting"`，已扫码态只在 `msg` 中体现（含「已扫码」）；
/// - **Step 3**：`POST /website/api/bili/login/cancel`；cookie 回收由
///   `NodeCredentialSyncService.saveProfile()` 完成（F-03 已交付）。
///
/// 本文件只承载**纯领域**语义（状态档 / 启动结果 / 路径常量 / 状态映射），
/// 不做任何网络与 Flutter 依赖。
library;

import 'cloud_drive_login.dart';

/// B 站扫码状态（对齐 iOS `BiliQrLoginState`，合并为可解析的线格式档）。
enum BiliAuthStatus {
  /// 等待扫码（`waiting`，未扫码）。
  waiting('waiting'),

  /// 已扫码，等待手机确认（`waiting` + msg 含「已扫码」/ `scanned` / `confirm`）。
  scanned('scanned'),

  /// 登录成功（`success`）。
  success('success'),

  /// 二维码已过期（`expired`）。
  expired('expired'),

  /// 失败（`error` / `failed`）。
  error('error');

  const BiliAuthStatus(this.wire);

  /// 协议线格式字符串。
  final String wire;

  /// 由 Node 返回的 `status` 字段（+ 可选 `msg`）解析。
  ///
  /// 对齐 iOS：`waiting` 档需结合 `msg` 判断是否「已扫码」。
  static BiliAuthStatus fromWire(String? status, {String msg = ''}) {
    final String s = (status ?? '').toLowerCase();
    switch (s) {
      case 'waiting':
        return msg.contains('已扫码') ? BiliAuthStatus.scanned : BiliAuthStatus.waiting;
      case 'scanned':
      case 'confirm':
      case 'confirmed':
        return BiliAuthStatus.scanned;
      case 'success':
        return BiliAuthStatus.success;
      case 'expired':
        return BiliAuthStatus.expired;
      case 'error':
      case 'failed':
        return BiliAuthStatus.error;
      default:
        // 未知状态：以「已扫码」文案兜底，否则维持等待（对齐 iOS default 分支）。
        return msg.contains('已扫码') ? BiliAuthStatus.scanned : BiliAuthStatus.waiting;
    }
  }

  /// 是否为终态（轮询应停止）。
  bool get isTerminal => this == success || this == expired || this == error;

  /// 映射到统一登录阶段（`CloudDriveLoginPhase`）。
  CloudDriveLoginPhase toPhase() => switch (this) {
        BiliAuthStatus.waiting => CloudDriveLoginPhase.waitingScan,
        BiliAuthStatus.scanned => CloudDriveLoginPhase.scanned,
        BiliAuthStatus.success => CloudDriveLoginPhase.saving,
        BiliAuthStatus.expired => CloudDriveLoginPhase.failed,
        BiliAuthStatus.error => CloudDriveLoginPhase.failed,
      };
}

/// `start` 接口返回的二维码任务（对齐 iOS `BiliAuthManager.QrStart`）。
class BiliQrStart {
  /// 构造。
  const BiliQrStart({
    required this.taskId,
    this.qrUrl = '',
    this.qrImage = '',
    this.msg = '',
  });

  /// 轮询用任务 ID。
  final String taskId;

  /// 二维码承载的授权链接（服务端 `qrUrl`）。
  final String qrUrl;

  /// 服务端已生成的二维码图片（`data:image/png;base64,...`，可能为空）。
  final String qrImage;

  /// 服务端提示文案。
  final String msg;

  /// 可渲染的二维码 data URL（[qrImage] 为空时返回 null）。
  ///
  /// 说明：iOS 在 `qrImage` 缺失时用 CoreImage 本地生成；Flutter 侧由
  /// [NodeCloudDriveLoginGateway.startQrLogin] 把 [qrUrl] 标记为 `qr_data:`
  /// 形态，UI 复用 `QrImageView` 本地编码兜底（P2-3）。
  String? get qrDataUrl => qrImage.isEmpty ? null : qrImage;

  /// 提示文案（空则回退 iOS 默认文案）。
  String get displayMessage =>
      msg.isEmpty ? '请使用哔哩哔哩 App 扫码确认' : msg;
}

/// B 站登录路径常量（对齐 iOS `BiliAuthManager` 的 `nodeBaseURL` 拼接）。
abstract final class BiliAuthPaths {
  /// 生成二维码。
  static const String start = '/website/api/bili/login/start';

  /// 轮询扫码状态。
  static const String poll = '/website/api/bili/login/poll';

  /// 取消扫码任务。
  static const String cancel = '/website/api/bili/login/cancel';

  /// 写入 / 删除 B 站 Cookie。
  static const String cookie = '/website/api/bili/cookie';

  /// 轮询 body 固定的 provider 值。
  static const String provider = 'bili';
}

/// B 站登录错误（文案对齐 iOS `BiliAuthError`）。
class BiliAuthException implements Exception {
  /// 构造。
  const BiliAuthException(this.message);

  /// 面向用户的错误文案。
  final String message;

  @override
  String toString() => message;
}
