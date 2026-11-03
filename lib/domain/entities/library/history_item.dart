/// 领域层：播放历史项。
///
/// 列名与 `contract/schema/schema_v1.sql` 的 `history` 表逐位对齐。
library;

import '../../../core/utils/json_utils.dart';

/// 播放历史项。
class HistoryItem {
  /// 构造。
  const HistoryItem({
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

  /// 表名（契约）。
  static const String table = 'history';

  /// 主键。
  final int? id;

  /// 名称。
  final String name;

  /// 来源（站点 key）。
  final String laiyuan;

  /// 封面图。
  final String imgurl;

  /// 详情地址（历史去重依据）。
  final String detailurl;

  /// 详情 UA。
  final String detailua;

  /// 线路索引。
  final int xianlu;

  /// 集数索引。
  final int jishu;

  /// 播放进度（0.0–1.0）。
  final double progress;

  /// 最后播放时间（Unix 秒）。
  final int lastPlayedAt;

  /// 进度归一（越界钳制到 `[0,1]`）。
  double get clampedProgress {
    if (progress.isNaN) return 0.0;
    if (progress < 0.0) return 0.0;
    if (progress > 1.0) return 1.0;
    return progress;
  }

  /// 是否可续播（进度在 1%–95% 之间）。
  bool get isResumable =>
      clampedProgress >= 0.01 && clampedProgress <= 0.95;

  /// 数据库行 → 实体。
  factory HistoryItem.fromRow(Map<String, Object?> m) => HistoryItem(
        id: JsonUtils.asInt(m['id']),
        name: JsonUtils.asString(m['name']) ?? '',
        laiyuan: JsonUtils.asString(m['laiyuan']) ?? '',
        imgurl: JsonUtils.asString(m['imgurl']) ?? '',
        detailurl: JsonUtils.asString(m['detailurl']) ?? '',
        detailua: JsonUtils.asString(m['detailua']) ?? '',
        xianlu: JsonUtils.asInt(m['xianlu']) ?? 0,
        jishu: JsonUtils.asInt(m['jishu']) ?? 0,
        progress: JsonUtils.asDouble(m['progress']) ?? 0.0,
        lastPlayedAt: JsonUtils.asInt(m['lastPlayedAt']) ?? 0,
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
        'progress': progress,
        'lastPlayedAt': lastPlayedAt,
      };

  /// 复制并覆盖部分字段。
  HistoryItem copyWith({
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
      HistoryItem(
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

  @override
  String toString() => 'HistoryItem($name, ${(clampedProgress * 100).round()}%)';
}
