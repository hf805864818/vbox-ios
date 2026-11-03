/// 网盘播放错误分档（F-P14）。
///
/// 对齐 iOS `DriveError`（`vbox/Services/CloudDriveManager.swift:10575-10604`）：
/// 7 个分档 + `errorDescription` 通用文案。播放站点另有一档**收敛口径**
/// （`PlayerViewsV2.swift:3669-3679`，百度分支 `2315-2322`）：`noPlayURL` 直出
/// reason、`invalidResponse` 作「服务器响应异常」、`notImplemented` 作「暂不支持」
/// —— 见 [DriveError.playbackMessage]。
library;

/// 错误分档（逐档对齐 iOS `DriveError`）。
enum DriveErrorKind {
  /// `noPlayURL(String)` —— 无法获取播放地址。
  noPlayURL,

  /// `invalidResponse` —— 服务器响应无效。
  invalidResponse,

  /// `invalidShareURL` —— 无效的分享链接。
  invalidShareURL,

  /// `saveFailed` —— 转存失败。
  saveFailed,

  /// `notImplemented` —— 该网盘暂不支持。
  notImplemented,

  /// `tokenNotConfigured(String)` —— 未配置 Token。
  tokenNotConfigured,

  /// `nodeNotReady(String)` —— Node 常驻系统未就绪。
  nodeNotReady,
}

/// 网盘播放错误（对齐 iOS `DriveError`）。
class DriveError implements Exception {
  /// 构造。
  const DriveError(this.kind, [this.detail = '']);

  /// `noPlayURL(reason)`。
  const DriveError.noPlayURL(String reason)
      : kind = DriveErrorKind.noPlayURL,
        detail = reason;

  /// `invalidResponse`。
  const DriveError.invalidResponse()
      : kind = DriveErrorKind.invalidResponse,
        detail = '';

  /// `invalidShareURL`。
  const DriveError.invalidShareURL()
      : kind = DriveErrorKind.invalidShareURL,
        detail = '';

  /// `saveFailed`。
  const DriveError.saveFailed()
      : kind = DriveErrorKind.saveFailed,
        detail = '';

  /// `notImplemented`。
  const DriveError.notImplemented()
      : kind = DriveErrorKind.notImplemented,
        detail = '';

  /// `tokenNotConfigured(name)`。
  const DriveError.tokenNotConfigured(String name)
      : kind = DriveErrorKind.tokenNotConfigured,
        detail = name;

  /// `nodeNotReady(name)`。
  const DriveError.nodeNotReady(String name)
      : kind = DriveErrorKind.nodeNotReady,
        detail = name;

  /// 分档。
  final DriveErrorKind kind;

  /// 分档载荷：`noPlayURL` 为 reason；`tokenNotConfigured` / `nodeNotReady` 为盘名。
  final String detail;

  /// 通用文案（逐字对齐 iOS `DriveError.errorDescription`，`10586-10603`）。
  String get description => switch (kind) {
        DriveErrorKind.noPlayURL => '无法获取播放地址：$detail',
        DriveErrorKind.invalidResponse => '服务器响应无效',
        DriveErrorKind.invalidShareURL => '无效的分享链接',
        DriveErrorKind.saveFailed => '转存失败',
        DriveErrorKind.notImplemented => '该网盘暂不支持',
        DriveErrorKind.tokenNotConfigured => '未配置$detail Token',
        DriveErrorKind.nodeNotReady => '$detail 需要 Node 常驻系统，当前未就绪，请稍后重试',
      };

  /// 播放站点文案（对齐 iOS 播放循环 catch 分档，`PlayerViewsV2.swift:3669-3679`）。
  ///
  /// 与 [description] 的三处差异为 iOS 实测有意为之，不可合并：
  /// - `noPlayURL` 直出 reason（不再加「无法获取播放地址：」前缀）；
  /// - `invalidResponse` 作「服务器响应异常」；
  /// - `notImplemented` 作「暂不支持」。
  String get playbackMessage => switch (kind) {
        DriveErrorKind.noPlayURL => detail,
        DriveErrorKind.invalidResponse => '服务器响应异常',
        DriveErrorKind.invalidShareURL => '无效的分享链接',
        DriveErrorKind.saveFailed => '转存失败',
        DriveErrorKind.notImplemented => '暂不支持',
        DriveErrorKind.tokenNotConfigured => '未配置$detail Token',
        DriveErrorKind.nodeNotReady => '$detail 需要 Node 常驻系统，当前未就绪，请稍后重试',
      };

  @override
  String toString() => 'DriveError(${kind.name}: $description)';
}