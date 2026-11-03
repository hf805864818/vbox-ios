/// 品牌资源常量（批次 A · A-13）。
///
/// 唯一真相源：`docs/第2轮开发计划_功能补全_v2.6.md` 批次 A「品牌字体 + 启动页字母图」。
///
/// 口径：品牌字体 `VboxBrand` 仅用于**品牌字标 / 启动页字母**（拉丁字形子集），
/// 正文仍走系统字体 —— 对齐令牌口径「字体族不强制」（UI 基准 §2.3）。
library;

/// 品牌资源。
class VboxBrand {
  const VboxBrand._();

  /// 品牌字体族（pubspec `fonts:` 登记；子集含字母 V/b/o/x 与数字）。
  static const String fontFamily = 'VboxBrand';

  /// 启动页字母图（品牌渐变圆角方 + 白色首字母 V）。
  static const String splashLogoAsset = 'assets/splash/vbox_letter.png';

  /// 品牌字标（用 [fontFamily] 渲染）。
  static const String wordmark = 'vbox';
}