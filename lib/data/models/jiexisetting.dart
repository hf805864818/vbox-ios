/// 数据层模型：`jiexisetting`（解析设置）。
///
/// 唯一真相源：`contract/schema/schema_v1.sql`
/// 主键：`bianma`（TEXT，编码）
library;


class Jiexisetting {
  static const String table = 'jiexisetting';

  const Jiexisetting({
    required this.bianma,
    this.zhuurl = '',
    this.beiurl = '',
  });

  /// 编码（主键）。
  final String bianma;

  /// 主解析地址。
  final String zhuurl;

  /// 备用解析地址。
  final String beiurl;

  Map<String, Object?> toMap() => <String, Object?>{
        'bianma': bianma,
        'zhuurl': zhuurl,
        'beiurl': beiurl,
      };

  factory Jiexisetting.fromMap(Map<String, Object?> m) => Jiexisetting(
        bianma: m['bianma'] as String,
        zhuurl: (m['zhuurl'] as String?) ?? '',
        beiurl: (m['beiurl'] as String?) ?? '',
      );

  Jiexisetting copyWith({String? bianma, String? zhuurl, String? beiurl}) =>
      Jiexisetting(
        bianma: bianma ?? this.bianma,
        zhuurl: zhuurl ?? this.zhuurl,
        beiurl: beiurl ?? this.beiurl,
      );
}
