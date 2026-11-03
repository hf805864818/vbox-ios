/// 数据层模型：`zhanyuan`（自建源）。
///
/// 唯一真相源：`contract/schema/schema_v1.sql`
/// 唯一约束：UNIQUE(name, dyurl)（v2 起）
library;

import 'db_model.dart';

class Zhanyuan {
  static const String table = 'zhanyuan';

  const Zhanyuan({
    this.id,
    this.key = '',
    required this.name,
    required this.searchUrl,
    this.searchUA = defaultUA,
    this.playUA = '',
    this.websearchurl = '',
    this.searchname = '',
    this.searchid = '',
    this.searchpic = '',
    this.searchstarr = '',
    this.detaillist = '',
    this.detailxl = '',
    this.detailjs = '',
    this.detailjsurl = '',
    this.isActive = true,
    required this.updatedAt,
    this.dyurl = '',
  });

  /// v1 默认 UA（与 DDL DEFAULT 一致；公开供 B-11 站源搜索服务复用）。
  static const String defaultUA =
      'Mozilla/5.0 (Linux; Android 12; Redmi K30 Pro Build/SKQ1.220303.001; wv) '
      'AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/99.0.4844.88 '
      'Mobile Safari/537.36';

  final int? id;

  /// 站点唯一键（对齐订阅合成 key `zhan_N`；用于搜索结果回填 `engineKey`）。
  final String key;

  final String name;
  final String searchUrl;
  final String searchUA;
  final String playUA;
  final String websearchurl;
  final String searchname;
  final String searchid;
  final String searchpic;
  final String searchstarr;
  final String detaillist;
  final String detailxl;
  final String detailjs;
  final String detailjsurl;
  final bool isActive;
  final int updatedAt;
  final String dyurl;

  Map<String, Object?> toMap() => <String, Object?>{
        if (id != null) 'id': id,
        'name': name,
        'searchUrl': searchUrl,
        'searchUA': searchUA,
        'playUA': playUA,
        'websearchurl': websearchurl,
        'searchname': searchname,
        'searchid': searchid,
        'searchpic': searchpic,
        'searchstarr': searchstarr,
        'detaillist': detaillist,
        'detailxl': detailxl,
        'detailjs': detailjs,
        'detailjsurl': detailjsurl,
        'isActive': writeBool(isActive),
        'updatedAt': updatedAt,
        'dyurl': dyurl,
      };

  factory Zhanyuan.fromMap(Map<String, Object?> m) => Zhanyuan(
        id: m['id'] as int?,
        name: m['name'] as String,
        searchUrl: m['searchUrl'] as String,
        searchUA: (m['searchUA'] as String?) ?? '',
        playUA: (m['playUA'] as String?) ?? '',
        websearchurl: (m['websearchurl'] as String?) ?? '',
        searchname: (m['searchname'] as String?) ?? '',
        searchid: (m['searchid'] as String?) ?? '',
        searchpic: (m['searchpic'] as String?) ?? '',
        searchstarr: (m['searchstarr'] as String?) ?? '',
        detaillist: (m['detaillist'] as String?) ?? '',
        detailxl: (m['detailxl'] as String?) ?? '',
        detailjs: (m['detailjs'] as String?) ?? '',
        detailjsurl: (m['detailjsurl'] as String?) ?? '',
        isActive: readBool(m['isActive']),
        updatedAt: m['updatedAt'] as int,
        dyurl: (m['dyurl'] as String?) ?? '',
      );

  Zhanyuan copyWith({
    int? id,
    String? key,
    String? name,
    String? searchUrl,
    String? searchUA,
    String? playUA,
    String? websearchurl,
    String? searchname,
    String? searchid,
    String? searchpic,
    String? searchstarr,
    String? detaillist,
    String? detailxl,
    String? detailjs,
    String? detailjsurl,
    bool? isActive,
    int? updatedAt,
    String? dyurl,
  }) =>
      Zhanyuan(
        id: id ?? this.id,
        key: key ?? this.key,
        name: name ?? this.name,
        searchUrl: searchUrl ?? this.searchUrl,
        searchUA: searchUA ?? this.searchUA,
        playUA: playUA ?? this.playUA,
        websearchurl: websearchurl ?? this.websearchurl,
        searchname: searchname ?? this.searchname,
        searchid: searchid ?? this.searchid,
        searchpic: searchpic ?? this.searchpic,
        searchstarr: searchstarr ?? this.searchstarr,
        detaillist: detaillist ?? this.detaillist,
        detailxl: detailxl ?? this.detailxl,
        detailjs: detailjs ?? this.detailjs,
        detailjsurl: detailjsurl ?? this.detailjsurl,
        isActive: isActive ?? this.isActive,
        updatedAt: updatedAt ?? this.updatedAt,
        dyurl: dyurl ?? this.dyurl,
      );
}
