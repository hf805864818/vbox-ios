/// 数据层模型：`settings`（键值设置表）。
///
/// 唯一真相源：`contract/schema/schema_v1.sql`
/// 主键：`key`（TEXT）
library;


class Setting {
  static const String table = 'settings';

  const Setting({
    required this.key,
    this.value = '',
    required this.updatedAt,
  });

  final String key;
  final String value;
  final int updatedAt;

  Map<String, Object?> toMap() => <String, Object?>{
        'key': key,
        'value': value,
        'updatedAt': updatedAt,
      };

  factory Setting.fromMap(Map<String, Object?> m) => Setting(
        key: m['key'] as String,
        value: (m['value'] as String?) ?? '',
        updatedAt: m['updatedAt'] as int,
      );

  Setting copyWith({String? key, String? value, int? updatedAt}) => Setting(
        key: key ?? this.key,
        value: value ?? this.value,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}
