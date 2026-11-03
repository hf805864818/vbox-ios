/// 数据层：SQLite 读写辅助函数。
///
/// 唯一真相源：`contract/schema/schema_v1.sql`
/// 各模型（`favorite` / `history` / `setting` …）自带 `toMap()` / `fromMap()`，
/// 列名与 Dart 字段名完全一致（不做 camelCase 转换），避免映射歧义；
/// 时间字段统一为 **Unix 秒**（INTEGER），与 iOS 端一致；
/// 布尔字段 SQLite 存 0/1（INTEGER）。
///
/// 约定：
/// - 写入用 `toMap()`，读取用 `fromMap()`；
/// - 本文件只提供跨模型的读写原语（布尔 0/1、Unix 秒、可空字符串）。
library;

/// SQLite 布尔读写辅助（0/1 ↔ bool）。
bool readBool(Object? v) {
  if (v == null) return false;
  if (v is bool) return v;
  if (v is int) return v != 0;
  if (v is String) return v == '1' || v.toLowerCase() == 'true';
  return false;
}

/// 布尔 → SQLite 整数。
int writeBool(bool v) => v ? 1 : 0;

/// 读取可空字符串（NULL → null）。
String? readNullableString(Object? v) => v as String?;

/// Unix 秒 → DateTime（本地时区）。
DateTime readTime(Object? v) =>
    DateTime.fromMillisecondsSinceEpoch((v as int) * 1000);

/// DateTime → Unix 秒。
int writeTime(DateTime t) => t.millisecondsSinceEpoch ~/ 1000;
