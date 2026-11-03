/// 平台层：字幕显示样式（UI-F5 字幕设置面板）。
///
/// 对齐 iOS `SubtitleSettingsPanel` 的三个可调项：显示开关 / 字号（12~32）/
/// 颜色档位（白 / 黄 / 青）。这三项在 iOS 侧是 `PlayerState` 的会话级
/// `@Published` 状态（不落 UserDefaults），故此处同样只作**会话级**值对象，
/// 由 [PlayerControlsController] 持有并回抛给播放页。
///
/// 颜色只存**档位索引**，具体色值由表现层从令牌表解析
/// （`VboxColors.subtitlePalette`）——平台层不依赖表现层主题。
library;

/// 字幕字号下限（对齐 iOS Slider `12...32`）。
const double kSubtitleMinFontSize = 12;

/// 字幕字号上限。
const double kSubtitleMaxFontSize = 32;

/// 字幕颜色档位数量（白 / 黄 / 青；色值见表现层令牌表）。
const int kSubtitleColorCount = 3;

/// 字幕显示样式快照。
class SubtitleStyle {
  /// 构造。
  const SubtitleStyle({
    this.visible = true,
    this.fontSize = 16,
    this.colorIndex = 0,
  });

  /// 是否显示字幕。
  final bool visible;

  /// 字号（px）。
  final double fontSize;

  /// 颜色档位索引（`0` 白 / `1` 黄 / `2` 青）。
  final int colorIndex;

  /// 复制并覆盖部分字段（字号钳制在 [kSubtitleMinFontSize] ~ [kSubtitleMaxFontSize]，
  /// 颜色索引钳制在 `0` ~ `kSubtitleColorCount - 1`）。
  SubtitleStyle copyWith({
    bool? visible,
    double? fontSize,
    int? colorIndex,
  }) =>
      SubtitleStyle(
        visible: visible ?? this.visible,
        fontSize: (fontSize ?? this.fontSize)
            .clamp(kSubtitleMinFontSize, kSubtitleMaxFontSize),
        colorIndex: (colorIndex ?? this.colorIndex)
            .clamp(0, kSubtitleColorCount - 1),
      );
}
