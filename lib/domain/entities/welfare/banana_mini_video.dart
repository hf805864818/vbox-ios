/// 领域层：香蕉秀短视频实体（对齐 iOS `YBoxBananaMiniVideo`）。
///
/// 唯一真相源：iOS `vbox/Services/YBoxService2.swift` L70-L80
/// （`/minivod/reqlist` 返回的 `vodrow` + `user` 解析结果）。
///
/// 说明：本实体不并入通用福利模型 `fuli_models.dart`（该文件对齐 iOS
/// `FuliPlatformKit` 的通用契约 `FuliVideo`）——短视频携带作者昵称 / 头像，
/// 与长视频契约形状不同，故对齐 iOS 侧「短视频用独立模型」的划分。
library;

/// 香蕉秀短视频条目（对齐 iOS `YBoxBananaMiniVideo`）。
class BananaMiniVideo {
  /// 构造。
  const BananaMiniVideo({
    required this.vodId,
    required this.title,
    required this.cover,
    this.videoUrl,
    this.duration,
    this.userName = '',
    this.userAvatar = '',
  });

  /// 视频 ID（裸 id；端点判定由服务侧 `mini:` 前缀在播放时补足）。
  final String vodId;

  /// 标题。
  final String title;

  /// 封面。
  final String cover;

  /// 播放地址（列表内嵌 `play_url`；可能为空，播放时经 `/minivod/reqplay` 现取）。
  final String? videoUrl;

  /// 时长（原始文案，如 `00:15`）。
  final String? duration;

  /// 作者昵称。
  final String userName;

  /// 作者头像。
  final String userAvatar;
}
