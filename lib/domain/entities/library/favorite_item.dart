/// 领域层：收藏项。
///
/// 列名与 `contract/schema/schema_v1.sql` 的 `favorite` 表逐位对齐
/// （由 `test/domain/entities/library_parity_test.dart` 守护与数据模型的列一致性）。
library;

import '../../../core/utils/json_utils.dart';

/// 收藏项。
class FavoriteItem {
  /// 构造。
  const FavoriteItem({
    this.id,
    required this.name,
    this.laiyuan = '',
    this.imgurl = '',
    this.detailurl = '',
    this.detailua = '',
    this.xianlu = 0,
    this.jishu = 0,
    required this.addedAt,
  });

  /// 表名（契约）。
  static const String table = 'favorite';

  /// 主键（未落库为 null）。
  final int? id;

  /// 名称。
  final String name;

  /// 来源（站点 key）。
  final String laiyuan;

  /// 封面图。
  final String imgurl;

  /// 详情地址（收藏去重依据）。
  final String detailurl;

  /// 详情 UA（空表示用默认 UA）。
  final String detailua;

  /// 线路索引。
  final int xianlu;

  /// 集数索引。
  final int jishu;

  /// 收藏时间（Unix 秒）。
  final int addedAt;

  /// 数据库行 → 实体（容错：缺失列回落默认值，不抛异常）。
  factory FavoriteItem.fromRow(Map<String, Object?> m) => FavoriteItem(
        id: JsonUtils.asInt(m['id']),
        name: JsonUtils.asString(m['name']) ?? '',
        laiyuan: JsonUtils.asString(m['laiyuan']) ?? '',
        imgurl: JsonUtils.asString(m['imgurl']) ?? '',
        detailurl: JsonUtils.asString(m['detailurl']) ?? '',
        detailua: JsonUtils.asString(m['detailua']) ?? '',
        xianlu: JsonUtils.asInt(m['xianlu']) ?? 0,
        jishu: JsonUtils.asInt(m['jishu']) ?? 0,
        addedAt: JsonUtils.asInt(m['addedAt']) ?? 0,
      );

  /// 实体 → 数据库行。
  Map<String, Object?> toRow() => <String, Object?>{
        if (id != null) 'id': id,
        'name': name,
        'laiyuan': laiyuan,
        'imgurl': imgurl,
        'detailurl': detailurl,
        'detailua': detailua,
        'xianlu': xianlu,
        'jishu': jishu,
        'addedAt': addedAt,
      };

  /// 复制并覆盖部分字段。
  FavoriteItem copyWith({
    int? id,
    String? name,
    String? laiyuan,
    String? imgurl,
    String? detailurl,
    String? detailua,
    int? xianlu,
    int? jishu,
    int? addedAt,
  }) =>
      FavoriteItem(
        id: id ?? this.id,
        name: name ?? this.name,
        laiyuan: laiyuan ?? this.laiyuan,
        imgurl: imgurl ?? this.imgurl,
        detailurl: detailurl ?? this.detailurl,
        detailua: detailua ?? this.detailua,
        xianlu: xianlu ?? this.xianlu,
        jishu: jishu ?? this.jishu,
        addedAt: addedAt ?? this.addedAt,
      );

  @override
  String toString() => 'FavoriteItem($name @ $detailurl)';
}
