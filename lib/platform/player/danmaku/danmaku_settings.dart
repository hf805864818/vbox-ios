/// 平台层：弹幕设置（批次 C · C-03）。
///
/// - 会话级显示参数（开 / 透明度 / 字号 / 显示区域 / 颜色模式 / 滚动速度）：
///   契约 99 键已冻结，不持久化，由弹幕设置面板在播放会话内调整
///   （默认 开 / 0.8 / 16px / 1.0 / 随机色 / 1.0x）。
/// - 自定义弹幕源（开关 + 地址）：走契约键 `custom_danmaku_source_enabled` /
///   `custom_danmaku_source_url`，经 [PlaybackSettings.loadWithDanmaku] 读取。
library;

import '../playback_settings.dart';

/// 会话级弹幕显示设置快照（不可变）。
class DanmakuSettings {
  /// 构造。
  const DanmakuSettings({
    required this.enabled,
    required this.opacity,
    required this.fontSize,
    required this.area,
    required this.colorMode,
    required this.speed,
    required this.customSourceEnabled,
    required this.customSourceUrl,
  });

  /// 默认值（开 / 0.8 / 16px / 1.0 / 颜色随机 / 1.0x；自定义源关 + 空地址）。
  ///
  /// 颜色模式默认 7（随机）、速度默认 1.0x，对齐 iOS
  /// `PlayerState.danmakuColorMode = 7 / danmakuSpeed = 1.0`。
  static const DanmakuSettings defaults = DanmakuSettings(
    enabled: true,
    opacity: 0.8,
    fontSize: 16,
    area: 1.0,
    colorMode: 7,
    speed: 1.0,
    customSourceEnabled: false,
    customSourceUrl: '',
  );

  /// 滚动速度档位（对齐 iOS `speedValues`：0.5 / 0.75 / 1.0 / 1.5 / 2.0）。
  static const List<double> speedValues = <double>[0.5, 0.75, 1.0, 1.5, 2.0];

  /// 滚动速度档位标签（对齐 iOS `speedLabels`）。
  static const List<String> speedLabels = <String>[
    '0.5x 慢', '0.75x', '1.0x 正常', '1.5x', '2.0x 快',
  ];

  /// 弹幕颜色预设表（对齐 iOS `PlayerState.presetColors`；RGB 值，渲染时补
  /// alpha）。0=原始颜色（不覆盖，用弹幕自带色）；7=随机（特殊标记，
  /// 实际颜色由渲染层从 [randomColorPool] 选取）。
  static const Map<int, int> presetColors = <int, int>{
    1: 0xFFFFFF, // 白色 #FFFFFF
    2: 0xFFFF00, // 黄色 #FFFF00
    3: 0x00FF00, // 绿色 #00FF00
    4: 0x0000FF, // 蓝色 #0000FF
    5: 0xFF0000, // 红色 #FF0000
    6: 0xFF69B4, // 粉色 #FF69B4
  };

  /// 随机颜色候选池（对齐 iOS `PlayerState.randomColorPool`；排除白色，
  /// 因为白色在浅色背景上不可见）。
  static const List<int> randomColorPool = <int>[
    0xFFFF00, // 黄色
    0x00FF00, // 绿色
    0x0000FF, // 蓝色
    0xFF0000, // 红色
    0xFF69B4, // 粉色
    0xFF8C00, // 橙色 #FF8C00
    0x00FFFF, // 青色 #00FFFF
    0x9932CC, // 紫色 #9932CC
  ];

  /// 弹幕开关。
  final bool enabled;

  /// 不透明度（0.0 ~ 1.0）。
  final double opacity;

  /// 字号（px）。
  final double fontSize;

  /// 显示区域（0.25 ~ 1.0，1.0 全屏）。
  final double area;

  /// 颜色模式（0=原始 1=白 2=黄 3=绿 4=蓝 5=红 6=粉 7=随机；对齐 iOS
  /// `danmakuColorMode`）。
  final int colorMode;

  /// 弹幕滚动速度倍率（0.5 ~ 2.0，默认 1.0；对齐 iOS `danmakuSpeed`）。
  final double speed;

  /// 自定义弹幕源开关。
  final bool customSourceEnabled;

  /// 自定义弹幕源地址。
  final String customSourceUrl;

  /// 复制并修改部分字段。
  DanmakuSettings copyWith({
    bool? enabled,
    double? opacity,
    double? fontSize,
    double? area,
    int? colorMode,
    double? speed,
    bool? customSourceEnabled,
    String? customSourceUrl,
  }) =>
      DanmakuSettings(
        enabled: enabled ?? this.enabled,
        opacity: opacity ?? this.opacity,
        fontSize: fontSize ?? this.fontSize,
        area: area ?? this.area,
        colorMode: colorMode ?? this.colorMode,
        speed: speed ?? this.speed,
        customSourceEnabled: customSourceEnabled ?? this.customSourceEnabled,
        customSourceUrl: customSourceUrl ?? this.customSourceUrl,
      );

  /// 由播放行为设置构建弹幕显示设置（会话参数保持默认，自定义源取自契约）。
  static DanmakuSettings fromPlayback(PlaybackSettings p) => DanmakuSettings(
        enabled: true,
        opacity: 0.8,
        fontSize: 16,
        area: 1.0,
        colorMode: 7,
        speed: 1.0,
        customSourceEnabled: p.customDanmakuSourceEnabled,
        customSourceUrl: p.customDanmakuSourceUrl,
      );

  /// 异步加载：播放设置（含自定义弹幕源契约键）+ 会话默认显示参数。
  static Future<DanmakuSettings> load() async {
    final PlaybackSettings p = await PlaybackSettings.loadWithDanmaku();
    return fromPlayback(p);
  }

  /// 校验显示参数合法（面板滑块用：clamp 后回写）。
  DanmakuSettings normalized() => copyWith(
        opacity: opacity.clamp(0.1, 1.0),
        fontSize: fontSize.clamp(10, 32),
        area: area.clamp(0.25, 1.0),
        speed: speed.clamp(0.25, 2.0),
      );

  @override
  String toString() =>
      'DanmakuSettings(en=$enabled, op=$opacity, size=$fontSize, area=$area, '
      'color=$colorMode, speed=$speed, custom=$customSourceEnabled)';
}
