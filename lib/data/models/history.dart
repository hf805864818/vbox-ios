/// 数据层模型：`history`（播放历史）。
///
/// 唯一真相源：`contract/schema/schema_v1.sql`
library;


class History {
  static const String table = 'history';

  const History({
    this.id,
    required this.name,
    this.laiyuan = '',
    this.imgurl = '',
    this.detailurl = '',
    this.detailua = '',
    this.xianlu = 0,
    this.jishu = 0,
    this.progress = 0.0,
    required this.lastPlayedAt,
  });

  final int? id;
  final String name;
  final String laiyuan;
  final String imgurl;
  final String detailurl;
  final String detailua;
  final int xianlu;
  final int jishu;

  /// 播放进度：REAL NOT NULL DEFAULT 0。
  final double progress;
  final int lastPlayedAt;

  Map<String, Object?> toMap() => <String, Object?>{
        if (id != null) 'id': id,
        'name': name,
        'laiyuan': laiyuan,
        'imgurl': imgurl,
        'detailurl': detailurl,
        'detailua': detailua,
        'xianlu': xianlu,
        'jishu': jishu,
        'progress': progress,
        'lastPlayedAt': lastPlayedAt,
      };

  factory History.fromMap(Map<String, Object?> m) => History(
        id: m['id'] as int?,
        name: m['name'] as String,
        laiyuan: (m['laiyuan'] as String?) ?? '',
        imgurl: (m['imgurl'] as String?) ?? '',
        detailurl: (m['detailurl'] as String?) ?? '',
        detailua: (m['detailua'] as String?) ?? '',
        xianlu: (m['xianlu'] as int?) ?? 0,
        jishu: (m['jishu'] as int?) ?? 0,
        progress: (m['progress'] as num?)?.toDouble() ?? 0.0,
        lastPlayedAt: m['lastPlayedAt'] as int,
      );

  History copyWith({
    int? id,
    String? name,
    String? laiyuan,
    String? imgurl,
    String? detailurl,
    String? detailua,
    int? xianlu,
    int? jishu,
    double? progress,
    int? lastPlayedAt,
  }) =>
      History(
        id: id ?? this.id,
        name: name ?? this.name,
        laiyuan: laiyuan ?? this.laiyuan,
        imgurl: imgurl ?? this.imgurl,
        detailurl: detailurl ?? this.detailurl,
        detailua: detailua ?? this.detailua,
        xianlu: xianlu ?? this.xianlu,
        jishu: jishu ?? this.jishu,
        progress: progress ?? this.progress,
        lastPlayedAt: lastPlayedAt ?? this.lastPlayedAt,
      );
}
