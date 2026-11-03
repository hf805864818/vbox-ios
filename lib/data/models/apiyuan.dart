/// 数据层模型：`apiyuan`（API 源）。
///
/// 唯一真相源：`contract/schema/schema_v1.sql`
/// 唯一约束：UNIQUE(name, dyurl)（v2 起）
library;

import 'db_model.dart';

class Apiyuan {
  static const String table = 'apiyuan';

  const Apiyuan({
    this.id,
    required this.name,
    required this.searchurl,
    this.searchua = '',
    this.detailurl = '',
    this.detailua = '',
    this.isActive = true,
    this.dyurl = '',
  });

  final int? id;
  final String name;
  final String searchurl;
  final String searchua;
  final String detailurl;
  final String detailua;
  final bool isActive;
  final String dyurl;

  Map<String, Object?> toMap() => <String, Object?>{
        if (id != null) 'id': id,
        'name': name,
        'searchurl': searchurl,
        'searchua': searchua,
        'detailurl': detailurl,
        'detailua': detailua,
        'isActive': writeBool(isActive),
        'dyurl': dyurl,
      };

  factory Apiyuan.fromMap(Map<String, Object?> m) => Apiyuan(
        id: m['id'] as int?,
        name: m['name'] as String,
        searchurl: m['searchurl'] as String,
        searchua: (m['searchua'] as String?) ?? '',
        detailurl: (m['detailurl'] as String?) ?? '',
        detailua: (m['detailua'] as String?) ?? '',
        isActive: readBool(m['isActive']),
        dyurl: (m['dyurl'] as String?) ?? '',
      );

  Apiyuan copyWith({
    int? id,
    String? name,
    String? searchurl,
    String? searchua,
    String? detailurl,
    String? detailua,
    bool? isActive,
    String? dyurl,
  }) =>
      Apiyuan(
        id: id ?? this.id,
        name: name ?? this.name,
        searchurl: searchurl ?? this.searchurl,
        searchua: searchua ?? this.searchua,
        detailurl: detailurl ?? this.detailurl,
        detailua: detailua ?? this.detailua,
        isActive: isActive ?? this.isActive,
        dyurl: dyurl ?? this.dyurl,
      );
}
