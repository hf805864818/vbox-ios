/// 数据层模型：`download`（下载任务）。
///
/// 唯一真相源：`contract/schema/schema_v1.sql`
///
/// ⚠️ 关键：`sourceType` / `engineKey` / `vodId` / `headers` 由 v4 `ALTER TABLE`
///    新增，**均为可空**——旧版本写入的行这些列为 NULL，读取必须容忍 NULL。
library;


/// 下载状态枚举。
///
/// DDL 注释只列 4 值（pending|downloading|completed|failed），但 iOS
/// `DownloadManager.pauseDownload` 实际向库写入 `"paused"`（`status` 为自由 TEXT），
/// 故 Dart 端扩展第 5 态保证「暂停 → 重启 → 恢复」可往返（G-02 差异登记）。
enum DownloadStatus {
  pending,
  downloading,
  paused,
  completed,
  failed;

  static DownloadStatus fromDb(String? v) => switch (v) {
        'downloading' => DownloadStatus.downloading,
        'paused' => DownloadStatus.paused,
        'completed' => DownloadStatus.completed,
        'failed' => DownloadStatus.failed,
        _ => DownloadStatus.pending,
      };

  String toDb() => name;
}

class Download {
  static const String table = 'download';

  const Download({
    this.id,
    required this.name,
    this.laiyuan = '',
    this.imgurl = '',
    this.detailurl = '',
    this.playurl = '',
    this.jishu = 0,
    this.progress = 0.0,
    this.status = DownloadStatus.pending,
    this.filePath = '',
    this.fileSize = 0,
    this.downloadedSize = 0,
    required this.addedAt,
    this.sourceType,
    this.engineKey,
    this.vodId,
    this.headers,
  });

  final int? id;
  final String name;
  final String laiyuan;
  final String imgurl;
  final String detailurl;
  final String playurl;
  final int jishu;
  final double progress;
  final DownloadStatus status;
  final String filePath;
  final int fileSize;
  final int downloadedSize;
  final int addedAt;

  // ── v4 可空列（旧数据为 NULL）──
  /// "normal" | "cloud"；旧数据为 null。
  final String? sourceType;

  /// 蜘蛛引擎 key；旧数据为 null。
  final String? engineKey;

  /// playerContent 参数；旧数据为 null。
  final String? vodId;

  /// JSON 编码请求头；旧数据为 null。
  final String? headers;

  Map<String, Object?> toMap() => <String, Object?>{
        if (id != null) 'id': id,
        'name': name,
        'laiyuan': laiyuan,
        'imgurl': imgurl,
        'detailurl': detailurl,
        'playurl': playurl,
        'jishu': jishu,
        'progress': progress,
        'status': status.toDb(),
        'filePath': filePath,
        'fileSize': fileSize,
        'downloadedSize': downloadedSize,
        'addedAt': addedAt,
        'sourceType': sourceType,
        'engineKey': engineKey,
        'vodId': vodId,
        'headers': headers,
      };

  factory Download.fromMap(Map<String, Object?> m) => Download(
        id: m['id'] as int?,
        name: m['name'] as String,
        laiyuan: (m['laiyuan'] as String?) ?? '',
        imgurl: (m['imgurl'] as String?) ?? '',
        detailurl: (m['detailurl'] as String?) ?? '',
        playurl: (m['playurl'] as String?) ?? '',
        jishu: (m['jishu'] as int?) ?? 0,
        progress: (m['progress'] as num?)?.toDouble() ?? 0.0,
        status: DownloadStatus.fromDb(m['status'] as String?),
        filePath: (m['filePath'] as String?) ?? '',
        fileSize: (m['fileSize'] as int?) ?? 0,
        downloadedSize: (m['downloadedSize'] as int?) ?? 0,
        addedAt: m['addedAt'] as int,
        sourceType: m['sourceType'] as String?,
        engineKey: m['engineKey'] as String?,
        vodId: m['vodId'] as String?,
        headers: m['headers'] as String?,
      );

  Download copyWith({
    int? id,
    String? name,
    String? laiyuan,
    String? imgurl,
    String? detailurl,
    String? playurl,
    int? jishu,
    double? progress,
    DownloadStatus? status,
    String? filePath,
    int? fileSize,
    int? downloadedSize,
    int? addedAt,
    String? sourceType,
    String? engineKey,
    String? vodId,
    String? headers,
  }) =>
      Download(
        id: id ?? this.id,
        name: name ?? this.name,
        laiyuan: laiyuan ?? this.laiyuan,
        imgurl: imgurl ?? this.imgurl,
        detailurl: detailurl ?? this.detailurl,
        playurl: playurl ?? this.playurl,
        jishu: jishu ?? this.jishu,
        progress: progress ?? this.progress,
        status: status ?? this.status,
        filePath: filePath ?? this.filePath,
        fileSize: fileSize ?? this.fileSize,
        downloadedSize: downloadedSize ?? this.downloadedSize,
        addedAt: addedAt ?? this.addedAt,
        sourceType: sourceType ?? this.sourceType,
        engineKey: engineKey ?? this.engineKey,
        vodId: vodId ?? this.vodId,
        headers: headers ?? this.headers,
      );
}
