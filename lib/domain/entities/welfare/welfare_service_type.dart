/// 领域层：福利平台服务类型（批次 H · H-02）。
///
/// 唯一真相源：iOS `vbox/WelfareRemote/WelfarePlatformConfig.swift`
///   · `WelfareServiceType`（L268-L284）：8 个已知 case + `unknown` 兜底，
///     `init(raw:)` 未命中即回退 `unknown`（**不兜底到其他平台**）。
///
/// 路由口径（对齐 iOS `WelfarePlatformRouter.makeDestinationView`）：
///   · 原生专用：`ybox_special` / `daily_battle` / `kanliao`；
///   · **5 类路由**：`aidan_video` / `fuli_base` / `remote_cms_v10`
///     / `welfare_spider` / `python_spider`；
///   · `unknown`：配置中的 `serviceType` 不在枚举内 → 显示明确「未支持」页。
library;

/// 客户端服务实现类型（对齐 iOS `WelfareServiceType`）。
enum WelfareServiceType {
  /// 香蕉秀专用（`fetchBanana*` 系列）。
  yboxSpecial('ybox_special'),

  /// 每日大乱斗 / 每日大赛。
  dailyBattle('daily_battle'),

  /// 今日看料。
  kanliao('kanliao'),

  /// 艾旦福利视频（CMS V10 专用）。
  aidanVideo('aidan_video'),

  /// 通用 `FuliBaseService` 子类（熊猫视频等）。
  fuliBase('fuli_base'),

  /// 远程可配置 CMS V10 福利源。
  remoteCmsV10('remote_cms_v10'),

  /// 福利专区专用远程 Spider（JS）。
  welfareSpider('welfare_spider'),

  /// 福利专区 Python 蜘蛛。
  pythonSpider('python_spider'),

  /// 未知类型（远程 `serviceType` 不在枚举内）。
  unknown('unknown');

  const WelfareServiceType(this.raw);

  /// 契约字符串值（远程配置 `platforms[].serviceType`）。
  final String raw;

  /// 由契约字符串解析（未知 / 空值回退 [unknown]，对齐 iOS `init(raw:)`）。
  static WelfareServiceType fromRaw(String? raw) {
    final String key = (raw ?? '').trim();
    for (final WelfareServiceType type in values) {
      if (type.raw == key) return type;
    }
    return unknown;
  }

  /// 是否为福利专区专用 Spider（含 JS 与 Python）。
  bool get isWelfareSpider =>
      this == welfareSpider || this == pythonSpider;

  /// 是否有对应路由（`unknown` 无路由，显示「未支持」页）。
  bool get isRoutable => this != unknown;
}