/// 核心层：JSON 安全取值。
///
/// 背景：蜘蛛脚本 / 远程配置返回的 JSON 类型不稳定（数字可能是字符串、
/// 布尔可能是 0/1），直接 `as` 强转会在运行时抛错。此处统一**宽容转换**，
/// 失败返回 null / 默认值，绝不抛异常。
library;

import 'dart:convert';

/// JSON 工具。
abstract final class JsonUtils {
  /// 转字符串（num / bool 也接受）。
  static String? asString(Object? v) {
    if (v == null) return null;
    if (v is String) return v;
    if (v is num || v is bool) return v.toString();
    return null;
  }

  /// 转整数（`"12"` / `12.0` / `true` 均可）。
  static int? asInt(Object? v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is double) return v.isFinite ? v.toInt() : null;
    if (v is bool) return v ? 1 : 0;
    if (v is String) return int.tryParse(v.trim());
    return null;
  }

  /// 转浮点。
  static double? asDouble(Object? v) {
    if (v == null) return null;
    if (v is double) return v;
    if (v is int) return v.toDouble();
    if (v is bool) return v ? 1.0 : 0.0;
    if (v is String) return double.tryParse(v.trim());
    return null;
  }

  /// 转布尔（`1/0`、`"true"/"false"`、`"yes"/"no"`）。
  static bool? asBool(Object? v) {
    if (v == null) return null;
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v is String) {
      switch (v.trim().toLowerCase()) {
        case 'true':
        case '1':
        case 'yes':
        case 'y':
          return true;
        case 'false':
        case '0':
        case 'no':
        case 'n':
          return false;
      }
    }
    return null;
  }

  /// 转列表（非列表返回空列表）。
  static List<Object?> asList(Object? v) {
    if (v is List) return List<Object?>.from(v);
    return const <Object?>[];
  }

  /// 转 `Map<String, Object?>`（键统一 `toString()`）。
  static Map<String, Object?> asMap(Object? v) {
    if (v is! Map) return const <String, Object?>{};
    final Map<String, Object?> out = <String, Object?>{};
    v.forEach((Object? k, Object? val) {
      out['$k'] = val;
    });
    return out;
  }

  /// 转 `List<Map<String, Object?>>`（自动丢弃非对象元素）。
  static List<Map<String, Object?>> asMapList(Object? v) =>
      asList(v).whereType<Map>().map(asMap).toList(growable: false);

  /// 解析 JSON 对象文本（失败返回 null）。
  static Map<String, Object?>? tryDecodeMap(String text) {
    try {
      final Object? v = jsonDecode(text);
      return v is Map ? asMap(v) : null;
    } catch (_) {
      return null;
    }
  }

  /// 解析 JSON 数组文本（失败返回 null）。
  static List<Object?>? tryDecodeList(String text) {
    try {
      final Object? v = jsonDecode(text);
      return v is List ? List<Object?>.from(v) : null;
    } catch (_) {
      return null;
    }
  }

  /// 编码（`jsonEncode` 的显式入口，便于统一替换实现）。
  static String encode(Object? value) => jsonEncode(value);

  /// 解码任意 JSON。
  static Object? decode(String text) => jsonDecode(text);

  // ── map 便捷取值 ──

  /// 取字符串。
  static String? pickString(Map<String, Object?> m, String key) =>
      asString(m[key]);

  /// 取字符串（带默认值）。
  static String pickStringOr(
    Map<String, Object?> m,
    String key,
    String fallback,
  ) =>
      asString(m[key]) ?? fallback;

  /// 取整数。
  static int pickInt(
    Map<String, Object?> m,
    String key, {
    int fallback = 0,
  }) =>
      asInt(m[key]) ?? fallback;

  /// 取布尔。
  static bool pickBool(
    Map<String, Object?> m,
    String key, {
    bool fallback = false,
  }) =>
      asBool(m[key]) ?? fallback;

  /// 取子对象。
  static Map<String, Object?> pickMap(Map<String, Object?> m, String key) =>
      asMap(m[key]);
}
