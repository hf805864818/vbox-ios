/// 核心层：字符串工具。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// 字符串工具。
abstract final class StringUtils {
  /// 空白判定（null / 空串 / 纯空白 均为 true）。
  static bool isBlank(String? s) => s == null || s.trim().isEmpty;

  /// 非空白判定。
  static bool isNotBlank(String? s) => !isBlank(s);

  /// 截断（超长追加省略号）。
  static String truncate(String s, int maxLength, {String ellipsis = '…'}) {
    if (maxLength <= 0) return '';
    if (s.length <= maxLength) return s;
    return '${s.substring(0, maxLength)}$ellipsis';
  }

  /// SHA-256（十六进制小写）。
  static String sha256Hex(String input) =>
      sha256.convert(utf8.encode(input)).toString();

  /// MD5（十六进制小写，用于缓存文件名等非安全场景）。
  static String md5Hex(String input) =>
      md5.convert(utf8.encode(input)).toString();

  /// 去除 HTML 标签。
  static String stripHtmlTags(String html) =>
      html.replaceAll(RegExp(r'<[^>]*>'), '').trim();

  /// 解码常见 HTML 实体。
  static String decodeHtmlEntities(String s) => s
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');

  /// 取 URL 主机名（解析失败返回空串）。
  static String hostOf(String url) {
    final Uri? uri = Uri.tryParse(url);
    return uri?.host ?? '';
  }

  /// 取 URL 路径扩展名（小写，不含点；无则空串）。
  static String extensionOf(String url) {
    final Uri? uri = Uri.tryParse(url);
    final String path = uri?.path ?? url;
    final int slash = path.lastIndexOf('/');
    final String name = slash >= 0 ? path.substring(slash + 1) : path;
    final int dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return '';
    return name.substring(dot + 1).toLowerCase();
  }

  /// 安全的 `Uri` 拼接（base + 相对路径 / 绝对 URL 直接返回）。
  static Uri? resolveUrl(String base, String target) {
    final Uri? b = Uri.tryParse(base);
    if (b == null) return null;
    return b.resolve(target);
  }
}
