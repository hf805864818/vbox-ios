/// 数据层：Node 托管盘 playID 解码（批次 F · F-P26）。
///
/// 对齐 iOS `PlayerViewsV2.swift` 的三处静态辅助（唯一真相源）：
/// - `decodeNodePlayIDObject`（L3785）：playID base64 → JSON 字典；容忍
///   data URL 前缀（`base64,` 之前整段丢弃）与「`+` 被当作空格」解码的情形；
/// - `nodeStableFileKey`（L3768）：从 `fileId` 取稳定文件键，其次 `playToken`
///   嵌套 JSON 文本中的 `fid`；
/// - `nodePlayIDFileName`（L3780）：从 `name` 取展示文件名（文件名兜底匹配用）。
///
/// 背景：Node 每次 detail 都会重新生成 playToken（含 stoken/expiry），**同一文件的
/// playID 整串可能变化**，故详情页 fragment 携带的旧 playID 不能只靠整串相等定位；
/// 需先用「稳定键 / 文件名」匹配到本次新解析出的条目，再用新 playID 取链。
library;

import 'dart:convert';

/// Node playID 载荷解码（对齐 iOS 三个静态辅助）。
abstract final class NodePlayId {
  /// playID base64 → JSON 字典（失败返回 null）。
  ///
  /// 容错顺序与 iOS 一致：先把空格还原成 `+`，再剥离 `base64,` 前缀，
  /// 最后忽略 base64 字母表之外的字符后解码并解析 JSON。
  static Map<String, dynamic>? decodeObject(String playID) {
    if (playID.isEmpty) return null;
    String source = playID.replaceAll(' ', '+');
    final int marker = source.indexOf('base64,');
    if (marker >= 0) source = source.substring(marker + 'base64,'.length);
    final List<int>? bytes = _decodeBase64(source);
    if (bytes == null) return null;
    return _decodeJson(utf8.decode(bytes, allowMalformed: true));
  }

  /// 稳定文件键（对齐 iOS `nodeStableFileKey`）：`fileId` 优先，
  /// 其次 `playToken` 嵌套 JSON 的 `fid`；均缺失返回 null。
  static String? stableFileKey(String playID) {
    final Map<String, dynamic>? obj = decodeObject(playID);
    if (obj == null) return null;
    final Object? fileId = obj['fileId'];
    if (fileId is String && fileId.isNotEmpty) return fileId;
    final Object? token = obj['playToken'];
    if (token is String) {
      final Object? fid = _decodeJson(token)?['fid'];
      if (fid is String && fid.isNotEmpty) return fid;
    }
    return null;
  }

  /// 展示文件名（对齐 iOS `nodePlayIDFileName`）：`name` 字段（非字符串返回 null）。
  static String? fileName(String playID) {
    final Object? name = decodeObject(playID)?['name'];
    return name is String ? name : null;
  }

  /// base64 解码：剔除字母表外字符（等价 iOS `.ignoreUnknownCharacters`）后补 `=`。
  static List<int>? _decodeBase64(String input) {
    final String cleaned = input.replaceAll(RegExp(r'[^A-Za-z0-9+/]'), '');
    final int remainder = cleaned.length % 4;
    if (remainder == 1) return null; // 非法长度（无法通过补位修复）。
    final String padded =
        remainder == 0 ? cleaned : cleaned + '=' * (4 - remainder);
    try {
      return base64.decode(padded);
    } catch (_) {
      return null;
    }
  }

  /// JSON 文本 → 字典（失败返回 null）。
  static Map<String, dynamic>? _decodeJson(String text) {
    if (text.isEmpty) return null;
    try {
      final Object? obj = jsonDecode(text);
      if (obj is Map) {
        return <String, dynamic>{
          for (final MapEntry<Object?, Object?> e in obj.entries)
            e.key.toString(): e.value,
        };
      }
    } catch (_) {
      // 非法 JSON / 空文本一律回落 null。
    }
    return null;
  }
}