/// 数据层：备份负载（BackupPayload）。
///
/// 唯一真相源：`contract/docs/backup_v1.md` §5（Payload 结构）。
///
/// 结构（与 iOS `BackupPayload` 逐字段对齐）：
/// ```
/// { "account": String, "categories": { <category rawValue>: <Data> } }
/// ```
///
/// ⚠️ Swift 的 `Data` 在 Codable 中编码为 **Base64 字符串**，因此
/// `categories` 的值是「该类目 JSON 的 UTF-8 字节 → 标准 Base64」，
/// 而非直接内嵌 JSON 对象。本文件严格按此约定编解码，保证双向互通。
library;

import 'dart:convert';

import 'backup_manager.dart';

/// 备份负载：账号 + 各类目内容。
///
/// 注：非 `const` 构造 —— [putCategory] 会写入 [categories]，若默认值为
/// `const <String, String>{}`，多个实例将共享同一份**不可变**映射，
/// 写入时抛 `UnsupportedError`。故默认值改为每次新建的可变映射。
class BackupPayload {
  BackupPayload({
    this.account = '',
    Map<String, String>? categories,
  }) : categories = categories ?? <String, String>{};

  /// 账号标识（对齐 `BackupPayload.account`）。
  final String account;

  /// 类目内容：key = [BackupCategory] rawValue，value = base64(类目 JSON UTF-8)。
  final Map<String, String> categories;

  /// 顶层 JSON。
  Map<String, Object?> toJson() => <String, Object?>{
        'account': account,
        'categories': categories,
      };

  factory BackupPayload.fromJson(Map<String, Object?> j) {
    final Map<String, String> cats = <String, String>{};
    final Object? raw = j['categories'];
    if (raw is Map) {
      raw.forEach((Object? k, Object? v) {
        if (k is String) cats[k] = v?.toString() ?? '';
      });
    }
    return BackupPayload(
      account: j['account'] as String? ?? '',
      categories: cats,
    );
  }

  /// 序列化为 JSON 字符串（即信封 payload 的明文）。
  String encode() => jsonEncode(toJson());

  /// 从 JSON 字符串解析。
  factory BackupPayload.decode(String content) {
    final Object? decoded = jsonDecode(content);
    if (decoded is! Map) {
      throw const InvalidFormatException('备份负载顶层不是 JSON 对象');
    }
    return BackupPayload.fromJson(decoded.cast<String, Object?>());
  }

  /// 是否含某类目。
  bool contains(BackupCategory c) => categories.containsKey(c.name);

  /// 写入一个类目（[data] 为可 JSON 序列化的对象，如 List / Map）。
  ///
  /// 值按契约存为 Base64（UTF-8 JSON 字节）。
  void putCategory(BackupCategory c, Object? data) {
    categories[c.name] =
        base64.encode(utf8.encode(jsonEncode(data)));
  }

  /// 读取一个类目的 JSON（缺失返回 null；base64/JSON 非法返回 null）。
  Object? readCategory(BackupCategory c) {
    final String? b64 = categories[c.name];
    if (b64 == null || b64.isEmpty) return null;
    try {
      return jsonDecode(utf8.decode(base64.decode(b64)));
    } on FormatException {
      return null;
    }
  }

  /// 返回仅含指定类目的副本（其余丢弃）。
  BackupPayload subset(Set<BackupCategory> keep) {
    final Map<String, String> out = <String, String>{};
    for (final BackupCategory c in keep) {
      final String? v = categories[c.name];
      if (v != null) out[c.name] = v;
    }
    return BackupPayload(account: account, categories: out);
  }
}