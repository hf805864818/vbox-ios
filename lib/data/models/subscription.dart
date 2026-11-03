/// 数据层模型：`subscription`（订阅）。
///
/// 唯一真相源：`contract/schema/schema_v1.sql`
/// 唯一约束：UNIQUE(dyurl)
library;


class Subscription {
  static const String table = 'subscription';

  const Subscription({
    this.id,
    required this.dyname,
    required this.dyurl,
    this.dyzz = '',
    required this.lastSyncAt,
  });

  final int? id;
  final String dyname;
  final String dyurl;
  final String dyzz;
  final int lastSyncAt;

  Map<String, Object?> toMap() => <String, Object?>{
        if (id != null) 'id': id,
        'dyname': dyname,
        'dyurl': dyurl,
        'dyzz': dyzz,
        'lastSyncAt': lastSyncAt,
      };

  factory Subscription.fromMap(Map<String, Object?> m) => Subscription(
        id: m['id'] as int?,
        dyname: m['dyname'] as String,
        dyurl: m['dyurl'] as String,
        dyzz: (m['dyzz'] as String?) ?? '',
        lastSyncAt: m['lastSyncAt'] as int,
      );

  Subscription copyWith({
    int? id,
    String? dyname,
    String? dyurl,
    String? dyzz,
    int? lastSyncAt,
  }) =>
      Subscription(
        id: id ?? this.id,
        dyname: dyname ?? this.dyname,
        dyurl: dyurl ?? this.dyurl,
        dyzz: dyzz ?? this.dyzz,
        lastSyncAt: lastSyncAt ?? this.lastSyncAt,
      );
}
