/// 领域层：订阅项（远程源订阅）。
///
/// 列名与 `contract/schema/schema_v1.sql` 的 `subscription` 表逐位对齐。
library;

import '../../../core/utils/json_utils.dart';

/// 订阅项。
class SubscriptionItem {
  /// 构造。
  const SubscriptionItem({
    this.id,
    required this.dyname,
    required this.dyurl,
    this.dyzz = '',
    required this.lastSyncAt,
  });

  /// 表名（契约）。
  static const String table = 'subscription';

  /// 主键。
  final int? id;

  /// 订阅名称。
  final String dyname;

  /// 订阅地址。
  final String dyurl;

  /// 订阅备注。
  final String dyzz;

  /// 上次同步时间（Unix 秒；0 表示从未同步）。
  final int lastSyncAt;

  /// 是否从未同步过。
  bool get neverSynced => lastSyncAt <= 0;

  /// 距上次同步的秒数（`now` 为当前 Unix 秒）。
  int ageSeconds(int now) => now - lastSyncAt;

  /// 是否到达同步间隔（`minIntervalSeconds`）。
  bool isDue(int now, int minIntervalSeconds) =>
      neverSynced || ageSeconds(now) >= minIntervalSeconds;

  /// 数据库行 → 实体。
  factory SubscriptionItem.fromRow(Map<String, Object?> m) => SubscriptionItem(
        id: JsonUtils.asInt(m['id']),
        dyname: JsonUtils.asString(m['dyname']) ?? '',
        dyurl: JsonUtils.asString(m['dyurl']) ?? '',
        dyzz: JsonUtils.asString(m['dyzz']) ?? '',
        lastSyncAt: JsonUtils.asInt(m['lastSyncAt']) ?? 0,
      );

  /// 实体 → 数据库行。
  Map<String, Object?> toRow() => <String, Object?>{
        if (id != null) 'id': id,
        'dyname': dyname,
        'dyurl': dyurl,
        'dyzz': dyzz,
        'lastSyncAt': lastSyncAt,
      };

  /// 复制并覆盖部分字段。
  SubscriptionItem copyWith({
    int? id,
    String? dyname,
    String? dyurl,
    String? dyzz,
    int? lastSyncAt,
  }) =>
      SubscriptionItem(
        id: id ?? this.id,
        dyname: dyname ?? this.dyname,
        dyurl: dyurl ?? this.dyurl,
        dyzz: dyzz ?? this.dyzz,
        lastSyncAt: lastSyncAt ?? this.lastSyncAt,
      );

  @override
  String toString() => 'SubscriptionItem($dyname @ $dyurl)';
}
