/// 网盘文件与清理队列领域模型（批次 F · F-07）。
///
/// 对齐 iOS（唯一契约来源）：
/// - `CloudDriveManager.CleanupQueueItem`（`vbox/Services/CloudDriveManager.swift:137`）
/// - 入队去重 / 上限裁剪 / 到期筛选（`enqueueCleanup` / `flushCleanupQueue`，
///   同文件 `:1239` / `:1278`）
/// - 文件条目取自播放链多文件列表（`CloudDriveManager` 解析结果）
///
/// 存储契约键 **`cloud_drive_cleanup_queue_v1`**（`storage: userdefaults`，
/// 类型 string → JSON 数组字符串），去重键语义与 iOS 一致：
/// `drive|tokenName|fileId`。
library;

/// 网盘文件 / 文件夹条目（多文件选集列表的基础单元）。
class CloudDriveFileEntry {
  /// 构造。
  const CloudDriveFileEntry({
    required this.fileId,
    required this.name,
    this.isFolder = false,
    this.size = 0,
    this.parentId = '',
    this.updatedAt,
  });

  /// 文件 / 文件夹 ID（网盘侧 fid / fs_id）。
  final String fileId;

  /// 名称。
  final String name;

  /// 是否文件夹。
  final bool isFolder;

  /// 字节大小（文件夹为 0）。
  final int size;

  /// 父目录 ID。
  final String parentId;

  /// 最近修改时间。
  final DateTime? updatedAt;

  /// 是否为视频文件（按扩展名判定，对齐 iOS 选集列表过滤口径）。
  bool get isVideo {
    final String lower = name.toLowerCase();
    const List<String> exts = <String>[
      '.mp4',
      '.mkv',
      '.avi',
      '.mov',
      '.flv',
      '.ts',
      '.m3u8',
      '.wmv',
      '.webm',
    ];
    return exts.any(lower.endsWith);
  }

  /// 排序键（文件夹优先，其次按名称，对齐 iOS 文件列表展示序）。
  int compareTo(CloudDriveFileEntry other) {
    if (isFolder != other.isFolder) return isFolder ? -1 : 1;
    return name.toLowerCase().compareTo(other.name.toLowerCase());
  }

  /// 反序列化。
  factory CloudDriveFileEntry.fromJson(Map<String, dynamic> json) {
    return CloudDriveFileEntry(
      fileId: '${json['fileId'] ?? json['fsId'] ?? json['fid'] ?? ''}',
      name: '${json['name'] ?? ''}',
      isFolder: json['isFolder'] == true || json['isDir'] == true,
      size: (json['size'] as num?)?.toInt() ?? 0,
      parentId: '${json['parentId'] ?? ''}',
      updatedAt: _parseDate(json['updatedAt']),
    );
  }

  /// 序列化。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'fileId': fileId,
        'name': name,
        'isFolder': isFolder,
        'size': size,
        if (parentId.isNotEmpty) 'parentId': parentId,
        if (updatedAt != null) 'updatedAt': updatedAt!.toIso8601String(),
      };
}

/// 清理队列条目（对齐 iOS `CleanupQueueItem`）。
class CloudDriveCleanupItem {
  /// 构造。
  const CloudDriveCleanupItem({
    required this.drive,
    required this.tokenName,
    required this.fileId,
    required this.eligibleAt,
    required this.createdAt,
  });

  /// 网盘契约字符串值（[CloudDriveType.id]）。
  final String drive;

  /// 关联 Token 名（空串表示未命中具名 Token，取兜底）。
  final String tokenName;

  /// 待清理文件 ID。
  final String fileId;

  /// 可清理时间（早于等于它即可执行删除）。
  final DateTime eligibleAt;

  /// 入队时间（用于上限裁剪的「保留最新」）。
  final DateTime createdAt;

  /// 去重键（对齐 iOS `"\(drive.rawValue)|\(tokenName)|\(fid)"`）。
  String get dedupKey => '$drive|$tokenName|$fileId';

  /// 是否已到期（对齐 iOS `eligibleAt <= now`）。
  bool isDue(DateTime now) => !eligibleAt.isAfter(now);

  /// 复制并覆盖部分字段。
  CloudDriveCleanupItem copyWith({
    String? drive,
    String? tokenName,
    String? fileId,
    DateTime? eligibleAt,
    DateTime? createdAt,
  }) {
    return CloudDriveCleanupItem(
      drive: drive ?? this.drive,
      tokenName: tokenName ?? this.tokenName,
      fileId: fileId ?? this.fileId,
      eligibleAt: eligibleAt ?? this.eligibleAt,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  /// 反序列化。
  factory CloudDriveCleanupItem.fromJson(Map<String, dynamic> json) {
    return CloudDriveCleanupItem(
      drive: '${json['drive'] ?? ''}',
      tokenName: '${json['tokenName'] ?? ''}',
      fileId: '${json['fileId'] ?? ''}',
      eligibleAt: _parseDate(json['eligibleAt']) ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      createdAt: _parseDate(json['createdAt']) ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }

  /// 序列化（对齐 iOS `Codable` 字段名）。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'drive': drive,
        'tokenName': tokenName,
        'fileId': fileId,
        'eligibleAt': eligibleAt.toIso8601String(),
        'createdAt': createdAt.toIso8601String(),
      };

  @override
  bool operator ==(Object other) =>
      other is CloudDriveCleanupItem &&
      other.drive == drive &&
      other.tokenName == tokenName &&
      other.fileId == fileId;

  @override
  int get hashCode => Object.hash(drive, tokenName, fileId);
}

/// 清理队列纯逻辑（对齐 iOS `enqueueCleanup` / `flushCleanupQueue`）。
///
/// 全部为无副作用的静态方法，便于单测锁定「去重正确」验收项。
abstract final class CloudDriveCleanupQueue {
  /// 队列上限（对齐 iOS「保留最新 300 条」）。
  static const int maxItems = 300;

  /// 入队（去重 + 上限裁剪）。
  ///
  /// - 去重键 `drive|tokenName|fileId`，已存在的条目不再追加，且**不改写**其
  ///   原 `eligibleAt`（对齐 iOS：先到者先算）；
  /// - 空 `fileId` 忽略（对齐 iOS `where !fid.isEmpty`）；
  /// - 超过 [maxItems] 时按 `createdAt` 倒序保留最新，同批按入队先后保留后者。
  static List<CloudDriveCleanupItem> enqueue(
    List<CloudDriveCleanupItem> current, {
    required String drive,
    required String tokenName,
    required Iterable<String> fileIds,
    required Duration delay,
    required DateTime now,
  }) {
    final DateTime eligibleAt = now.add(delay);
    final List<CloudDriveCleanupItem> queue =
        List<CloudDriveCleanupItem>.of(current);
    final Set<String> existing =
        current.map((CloudDriveCleanupItem e) => e.dedupKey).toSet();

    for (final String fid in fileIds) {
      if (fid.isEmpty) continue;
      final String key = '$drive|$tokenName|$fid';
      if (existing.contains(key)) continue;
      existing.add(key);
      queue.add(CloudDriveCleanupItem(
        drive: drive,
        tokenName: tokenName,
        fileId: fid,
        eligibleAt: eligibleAt,
        createdAt: now,
      ));
    }
    return _trim(queue);
  }

  /// 到期条目（`eligibleAt <= now`；对齐 iOS `queue.filter { $0.eligibleAt <= now }`）。
  static List<CloudDriveCleanupItem> due(
    List<CloudDriveCleanupItem> queue,
    DateTime now,
  ) =>
      queue.where((CloudDriveCleanupItem e) => e.isDue(now)).toList();

  /// 按 `drive|tokenName` 分组（对齐 iOS 批量删除分组，减少 API 调用）。
  static Map<String, List<String>> groupByDrive(
    Iterable<CloudDriveCleanupItem> items,
  ) {
    final Map<String, List<String>> groups = <String, List<String>>{};
    for (final CloudDriveCleanupItem item in items) {
      groups.putIfAbsent('${item.drive}|${item.tokenName}', () => <String>[])
          .add(item.fileId);
    }
    return groups;
  }

  /// 移除指定条目（去重语义，返回新列表）。
  static List<CloudDriveCleanupItem> remove(
    List<CloudDriveCleanupItem> queue,
    Iterable<CloudDriveCleanupItem> items,
  ) {
    final Set<String> keys =
        items.map((CloudDriveCleanupItem e) => e.dedupKey).toSet();
    return queue
        .where((CloudDriveCleanupItem e) => !keys.contains(e.dedupKey))
        .toList();
  }

  /// 上限裁剪：按 `createdAt` 倒序保留最新 [maxItems] 条。
  ///
  /// Dart `List.sort` 不保证稳定，故显式按「createdAt 倒序 → 入队序倒序」排序，
  /// 保证同批条目裁剪结果可预期。
  static List<CloudDriveCleanupItem> _trim(
    List<CloudDriveCleanupItem> queue,
  ) {
    if (queue.length <= maxItems) return queue;
    final List<int> indices = List<int>.generate(queue.length, (int i) => i);
    indices.sort((int a, int b) {
      final int byTime = queue[b].createdAt.compareTo(queue[a].createdAt);
      if (byTime != 0) return byTime;
      return b.compareTo(a);
    });
    final List<CloudDriveCleanupItem> kept = indices
        .take(maxItems)
        .map((int i) => queue[i])
        .toList();
    // 保持入队序输出（与 iOS 排序后 prefix 结果的元素集合一致）。
    kept.sort((CloudDriveCleanupItem a, CloudDriveCleanupItem b) =>
        queue.indexOf(a).compareTo(queue.indexOf(b)));
    return kept;
  }
}

/// 转存结果（对齐 iOS 分享转存返回：落盘目录 + 顶层文件 ID）。
class CloudDriveTransferResult {
  /// 构造。
  const CloudDriveTransferResult({
    required this.drive,
    required this.targetDir,
    required this.fileIds,
    required this.transferredAt,
  });

  /// 网盘契约字符串值。
  final String drive;

  /// 转存目标目录（对齐 iOS `pg_ali_transfer_dir` 等固定目录）。
  final String targetDir;

  /// 转存产生的顶层文件 / 文件夹 ID。
  final List<String> fileIds;

  /// 转存时间。
  final DateTime transferredAt;

  /// 是否转存出有效文件 ID。
  bool get hasFiles => fileIds.any((String id) => id.isNotEmpty);
}

DateTime? _parseDate(Object? value) {
  if (value is DateTime) return value;
  if (value is num) {
    return DateTime.fromMillisecondsSinceEpoch(value.toInt(), isUtc: true);
  }
  if (value is String && value.isNotEmpty) return DateTime.tryParse(value);
  return null;
}
