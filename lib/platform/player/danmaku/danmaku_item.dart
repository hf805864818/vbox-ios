/// 平台层：弹幕模型（批次 C · C-03）。
///
/// 对齐 Bilibili 弹幕语义：滚动 / 顶部 / 底部三种模式，ARGB 颜色，
/// 字号相对档位（默认按 25 档体系映射为 px）。会话级显示参数见
/// [DanmakuSettings]（弹幕设置面板，`danmaku/settings.dart`）。
library;

/// 弹幕显示模式。
enum DanmakuMode {
  /// 从右向左滚动。
  scroll,

  /// 顶部固定（数秒后消失）。
  top,

  /// 底部固定。
  bottom;

  static DanmakuMode fromInt(int v) => switch (v) {
        5 => DanmakuMode.top,
        4 => DanmakuMode.bottom,
        1 || 6 => DanmakuMode.scroll,
        _ => DanmakuMode.scroll,
      };
}

/// 单条弹幕。
class DanmakuItem {
  /// 构造。
  const DanmakuItem({
    required this.content,
    required this.timeMs,
    this.mode = DanmakuMode.scroll,
    this.color = 0xFFFFFFFF,
    this.sizePx = 16,
    this.id,
  });

  /// 文本。
  final String content;

  /// 相对视频起点的时间（毫秒）。
  final int timeMs;

  /// 显示模式。
  final DanmakuMode mode;

  /// ARGB 颜色（如 `0xFF42A5F5`）。
  final int color;

  /// 字号（px；由弹幕设置面板字号档换算）。
  final double sizePx;

  /// 弹幕源内唯一 id（可选）。
  final String? id;

  /// 是否为空文本（应被丢弃）。
  bool get isEmpty => content.trim().isEmpty;

  /// 渲染颜色（ARGB → Flutter [Color]）。
  int get argb => 0xFF000000 | (color & 0xFFFFFF);

  @override
  String toString() => 'DanmakuItem[$timeMs ms][$mode] '
      '${content.length > 12 ? '${content.substring(0, 12)}…' : content}';
}
