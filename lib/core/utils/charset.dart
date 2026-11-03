/// 核心层：字符集原语（契约 §4.2 的映射表与解码器）。
///
/// 唯一真相源：`contract/docs/abi_v1.md` §4.2
/// 逆向来源：iOS `vbox/Services/JSHTTPBridge.swift`
///
/// ⚠️ Dart 核心库不内置 GBK / Big5 码表，故采用**注册式**实现：
/// 平台适配层（`lib/platform/spider/`）在启动时注入码表；
/// **未注入时 `gbk` / `big5` 解码返回 null**（不静默产出乱码），
/// 由探测链继续下探或走 base64 兜底。
/// 码表注入属 G-03（见 `docs/VBOX_PLAN_v6.35.md` 附录 C）；
/// B-09 由平台层 `SpiderCharsetTables` 注入真实码表（enough_convert 转译）。
///
/// **严格语义**（B-09 对齐 iOS `String(data:encoding:)`）：
/// 注册码表后，码表未覆盖的双字节对 / 悬空高位字节 → 返回 null
/// （该级解码失败，探测链继续下探），不静默替换、不吞字节。
library;

import 'dart:convert';
import 'dart:typed_data';

import '../constants/app_constants.dart';

/// 字符集规范化（对齐契约 §4.2 的映射表）。
String normalizeCharset(String input) {
  final String s = input
      .trim()
      .toLowerCase()
      .replaceAll('"', '')
      .replaceAll("'", '');
  return switch (s) {
    'utf-8' || 'utf8' => 'utf-8',
    'gbk' || 'gb2312' || 'gb-2312' || 'gb18030' || 'gb-18030' || 'gb18030-2000' =>
      'gbk',
    'big5' || 'big-5' => 'big5',
    'iso-8859-1' || 'latin1' || 'latin-1' => 'latin1',
    _ => s,
  };
}

/// 从 `Content-Type` 头提取 charset（无则返回 null）。
String? charsetFromContentType(String? contentType) {
  if (contentType == null) return null;
  final RegExp re = RegExp(r'charset\s*=\s*([^\s;]+)', caseSensitive: false);
  final RegExpMatch? m = re.firstMatch(contentType);
  return m?.group(1);
}

/// meta charset 探测正则（对齐 iOS `detectMetaCharset`：
/// `(?i)<meta[^>]+charset=["']?\s*([a-zA-Z0-9_\-]+)`）。
final RegExp _metaCharsetRe = RegExp(
  r'<meta[^>]+charset\s*=\s*["' "'" r']?\s*([a-zA-Z0-9_\-]+)',
  caseSensitive: false,
);

/// 从**已解码文本**探测 meta charset（② 级 UTF-8 成功后自探用）。
String? sniffMetaCharsetFromText(String text) {
  final RegExpMatch? m = _metaCharsetRe.firstMatch(text);
  return m?.group(1);
}

/// 从 HTML 前 [limit] 字节的 ASCII 区域探测 meta charset。
String? sniffMetaCharset(
  Uint8List bytes, {
  int limit = NetConstants.metaSniffLimit,
}) {
  final int window = bytes.length < limit ? bytes.length : limit;
  // 只取 ASCII 可打印区域做探测（中文字节会干扰正则）
  final String head =
      String.fromCharCodes(bytes.sublist(0, window).where((int b) => b < 128));
  return sniffMetaCharsetFromText(head);
}

/// 用指定编码解码字节。
///
/// 返回 null 表示**该编码不可用或解码失败**（调用方应继续下探）：
/// - `gbk` / `big5`：未注册码表时返回 null；注册后按严格语义
///   （未覆盖对 / 悬空高位字节 → null）；
/// - `utf-8`：字节非法时返回 null（`allowMalformed: false`）；
/// - `latin1`：恒成功（单字节全映射）。
String? decodeBytesWith(Uint8List bytes, String charset) {
  try {
    switch (charset) {
      case 'utf-8':
        return utf8.decode(bytes, allowMalformed: false);
      case 'latin1':
        return latin1.decode(bytes);
      case 'gbk':
      case 'gb2312':
      case 'gb18030':
        if (_gbkTable.isEmpty) return null;
        return _decodeMultiByte(bytes, _gbkTable);
      case 'big5':
        if (_big5Table.isEmpty) return null;
        return _decodeMultiByte(bytes, _big5Table);
      default:
        return null;
    }
  } catch (_) {
    return null;
  }
}

// ─────────────────────────────────────────────────────────
// 多字节码表（注册式）
// ─────────────────────────────────────────────────────────

Map<int, String> _gbkTable = <int, String>{};
Map<int, String> _big5Table = <int, String>{};

/// 码表是否已注入（平台适配层未接入时为 false）。
bool get hasMultibyteTables => _gbkTable.isNotEmpty || _big5Table.isNotEmpty;

/// 注入码表（由平台适配层在启动时调用）。
///
/// 传 null 表示保持现状；传空表表示**清空**。
void registerCharsetTables({
  Map<int, String>? gbk,
  Map<int, String>? big5,
}) {
  if (gbk != null) _gbkTable = gbk;
  if (big5 != null) _big5Table = big5;
}

/// 严格双字节解码（GBK / Big5 共用）。
///
/// ASCII 区直通；双字节对须命中码表，否则整体失败返回 null
/// （对齐 iOS 严格解码语义，不产出替换字符、不吞字节）。
String? _decodeMultiByte(Uint8List bytes, Map<int, String> table) {
  final StringBuffer sb = StringBuffer();
  int i = 0;
  while (i < bytes.length) {
    final int b = bytes[i];
    if (b < 0x80) {
      sb.writeCharCode(b);
      i += 1;
    } else if (i + 1 < bytes.length) {
      final int code = (b << 8) | bytes[i + 1];
      final String? ch = table[code];
      if (ch == null) return null; // 未覆盖对 → 该级失败
      sb.write(ch);
      i += 2;
    } else {
      return null; // 悬空高位字节 → 该级失败
    }
  }
  return sb.toString();
}
