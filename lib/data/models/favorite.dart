/// 数据层模型：`favorite`（收藏）。
///
/// 唯一真相源：`contract/schema/schema_v1.sql`
library;


class Favorite {
  static const String table = 'favorite';

  const Favorite({
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

  final int? id;
  final String name;
  final String laiyuan;
  final String imgurl;
  final String detailurl;
  final String detailua;
  final int xianlu;
  final int jishu;
  final int addedAt;

  Map<String, Object?> toMap() => <String, Object?>{
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

  factory Favorite.fromMap(Map<String, Object?> m) => Favorite(
        id: m['id'] as int?,
        name: m['name'] as String,
        laiyuan: (m['laiyuan'] as String?) ?? '',
        imgurl: (m['imgurl'] as String?) ?? '',
        detailurl: (m['detailurl'] as String?) ?? '',
        detailua: (m['detailua'] as String?) ?? '',
        xianlu: (m['xianlu'] as int?) ?? 0,
        jishu: (m['jishu'] as int?) ?? 0,
        addedAt: m['addedAt'] as int,
      );

  Favorite copyWith({
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
      Favorite(
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
}
