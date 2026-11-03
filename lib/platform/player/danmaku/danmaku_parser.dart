/// 平台层：弹幕解析（批次 C · C-03）。
///
/// 支持两种主流格式：
///  - Bilibili XML：`<d p="时间,模式,字号,颜色,时间戳,弹幕池,用户,rowID">文本</d>`
///  - JSON 数组：`[{"time": 1.2, "text": "...", "color": 16711680, "mode": 1}]`
///    （兼容弹弹play / 部分第三方弹幕接口）。
library;

import 'dart:convert';

import 'danmaku_item.dart';

/// 弹幕解析器（C-03）。
class DanmakuParser {
  DanmakuParser._();

  /// 按内容嗅探格式后解析；无法识别或内容非法 → 空列表（不抛异常）。
  static List<DanmakuItem> parse(String content) {
    final String c = content.trim();
    if (c.isEmpty) return const <DanmakuItem>[];
    if (c.startsWith('<')) return parseBilibiliXml(c);
    if (c.startsWith('[') || c.startsWith('{')) return parseJson(c);
    return const <DanmakuItem>[];
  }

  /// 解析 Bilibili 弹幕 XML。
  ///
  /// `p` 属性字段（逗号分隔）：
  ///  0 时间(s) · 1 模式(1 滚动/4 底部/5 顶部/6 逆向，统一按 [DanmakuMode.fromInt]) ·
  ///  2 字号(25 档，非 px) · 3 颜色(十进制) · 4 发送时间戳 · 5 弹幕池 · 6 用户 · 7 rowID。
  static List<DanmakuItem> parseBilibiliXml(String content) {
    final List<DanmakuItem> out = <DanmakuItem>[];
    final RegExp dTag = RegExp(
      r'<d\s+[^>]*p="([^"]*)"[^>]*>(.*?)</d>',
      dotAll: true,
    );
    int index = 0;
    for (final RegExpMatch m in dTag.allMatches(content)) {
      final String text = _unescapeXml(m.group(2)!).trim();
      if (text.isEmpty) continue;
      final List<String> p = m.group(1)!.split(',');
      final double? t = double.tryParse(p.isEmpty ? '' : p[0]);
      if (t == null) continue;
      final int mode = p.length > 1 ? int.tryParse(p[1]) ?? 0 : 0;
      final int size = p.length > 2 ? int.tryParse(p[2]) ?? 25 : 25;
      final int color = p.length > 3 ? int.tryParse(p[3]) ?? 0xFFFFFF : 0xFFFFFF;
      out.add(DanmakuItem(
        content: text,
        timeMs: (t * 1000).round(),
        mode: DanmakuMode.fromInt(mode),
        color: 0xFF000000 | (color & 0xFFFFFF),
        sizePx: _mapSizeLevel(size),
        id: 'xml-$index',
      ));
      index++;
    }
    return out;
  }

  /// 解析 JSON 弹幕（数组或单对象）。
  ///
  /// 字段兼容：`time`/`t`/`c`（秒）· `text`/`content`/`m` · `color`/`colour`（十进制）·
  /// `mode`（1 滚动 / 4 底部 / 5 顶部）。时间缺失或非数 → 丢弃该条。
  static List<DanmakuItem> parseJson(String content) {
    final List<DanmakuItem> out = <DanmakuItem>[];
    Object? decoded;
    try {
      decoded = jsonDecode(content);
    } on FormatException {
      return const <DanmakuItem>[];
    }
    final List<Object?> items = decoded is List
        ? decoded
        : decoded is Map ? <Object?>[decoded] : const <Object?>[];
    int index = 0;
    for (final Object? raw in items) {
      if (raw is! Map) continue;
      final Object? time = raw['time'] ?? raw['t'] ?? raw['c'];
      final Object? text = raw['text'] ?? raw['content'] ?? raw['m'];
      if (time == null || text == null) continue;
      final double? sec = _toDouble(time);
      if (sec == null) continue;
      final int mode = _toInt(raw['mode']) ?? 0;
      final int color = _toInt(raw['color']) ?? _toInt(raw['colour']) ?? 0xFFFFFF;
      out.add(DanmakuItem(
        content: text.toString().trim(),
        timeMs: (sec * 1000).round(),
        mode: DanmakuMode.fromInt(mode),
        color: 0xFF000000 | (color & 0xFFFFFF),
        id: 'json-$index',
      ));
      index++;
    }
    return out;
  }

  // ─────────── 内部工具 ───────────

  /// Bilibili 25 档字号 → px（常见映射，默认档 25 → 16px）。
  static double _mapSizeLevel(int level) {
    if (level <= 0) return 16;
    if (level >= 25) return 16 + (level - 25) * 0.5;
    return 12 + level * 0.16;
  }

  static double? _toDouble(Object? v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  static int? _toInt(Object? v) {
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  static String _unescapeXml(String s) => s
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'");
}
