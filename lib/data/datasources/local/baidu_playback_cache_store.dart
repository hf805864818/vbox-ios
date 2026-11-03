/// 数据层：百度网盘播放缓存统一层（批次 E · E5-5）。
///
/// 唯一真相源：iOS `vbox/Services/CloudDriveManager.swift`
///   · 缓存键常量（L125-134）；
///   · `baiduStableHash`（L904-911）：FNV-1a 64 位（UInt64，offset basis
///     `1469598103934665603`，prime `1099511628211`），输出十六进制小写；
///   · 键派生 `baiduPlayCacheKey`（L344）/`baiduMainRouteCacheKey`（L348）/
///     `baiduFileListCacheKey`（L352）/`baiduShareContextKey`（L356）；
///   · 播放结果缓存（写 L518-538 / 读 L618-624 / 失效 L540-585）；
///   · 文件列表缓存（写 L392-401 / 读 L381-390，TTL 8h、上限 80）；
///   · iBox PlayItem 缓存（写 L606-616 / 读 L587-604，上限 160，自带
///     `dlinkExpiresAt`）；
///   · 分享上下文缓存（写 L424-458 / 读 L403-422，TTL 8h、上限 60，含
///     bdstoken/randsk 完整性校验）；
///   · 路由诊断（写 L309-329 / 读 L331-337 / 清 L339-342，上限 60）；
///   · 摘要与清理（`baiduPlaybackCacheSummary` L768 / `clearExpired…` L812 /
///     `clearAll…` L868）。
///
/// 未移植（如实登记，对齐 iOS 现状）：以下键在 iOS 侧**无真实消费点**，
/// 故不引入读写，避免移植死代码，仅保留设置页清理面清除存量：
///   · `baidu_play_item_cache_v1`（`BaiduPlayItem`）——`baiduCachedPlayItem`/
///     `baiduStorePlayItem`（L587/L591）全仓无调用点；
///   · `baidu_verify_cooldown_v1`（`baiduIsVerifyCoolingDown`/
///     `baiduMarkVerifyCooldown` L482/L492）——全仓无调用点；
///   · `quark_vbox_folder_cache_v1`——写入路径 `setQuarkVboxFolderCache` 仅由
///     `quarkEnsureFolderWithCookie`（L2787）触发，而后者唯一上游
///     `ensureVboxFolder`（L1160）全仓无调用点（且夸克转存实际固定传
///     `to_pdir_fid="0"`，见 L2311「不创建自定义目录」），故该链路整体不可达。
///
/// 落地差异（登记）：iOS 用 `JSONEncoder` 落 `Data`，日期为 Double（参考纪元）；
/// Flutter 端按契约 `storage: string` 存 JSON 字符串，日期统一用 epoch 毫秒 int。
/// （缓存不跨端共享，语义等价即可。）
library;

import 'dart:convert';

import 'prefs_manager.dart';

/// 百度缓存文件条目（对齐 iOS `BaiduFileItem` 的缓存形态）。
class BaiduCacheFile {
  /// 构造。
  const BaiduCacheFile({required this.fsId, required this.name});

  /// 文件 ID。
  final String fsId;

  /// 文件名。
  final String name;

  /// → JSON。
  Map<String, Object?> toJson() => <String, Object?>{'fsId': fsId, 'name': name};

  /// ← JSON。
  static BaiduCacheFile? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final String fsId = raw['fsId']?.toString() ?? '';
    if (fsId.isEmpty) return null;
    return BaiduCacheFile(fsId: fsId, name: raw['name']?.toString() ?? '');
  }
}

/// 持久化播放结果缓存项（对齐 iOS `BaiduPersistedPlayCacheItem`）。
class BaiduPersistedPlayCacheItem {
  /// 构造。
  const BaiduPersistedPlayCacheItem({
    required this.url,
    required this.headers,
    required this.expiresAt,
  });

  /// 播放直链。
  final String url;

  /// 播放请求头。
  final Map<String, String> headers;

  /// 过期时刻。
  final DateTime expiresAt;

  /// → JSON。
  Map<String, Object?> toJson() => <String, Object?>{
        'url': url,
        'headers': headers,
        'expiresAt': expiresAt.millisecondsSinceEpoch,
      };

  /// ← JSON。
  static BaiduPersistedPlayCacheItem? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final String url = raw['url']?.toString() ?? '';
    if (url.isEmpty) return null;
    final Map<String, String> headers = <String, String>{};
    final Object? h = raw['headers'];
    if (h is Map) {
      for (final MapEntry<Object?, Object?> e in h.entries) {
        headers[e.key.toString()] = e.value?.toString() ?? '';
      }
    }
    return BaiduPersistedPlayCacheItem(
      url: url,
      headers: headers,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(
        (raw['expiresAt'] as num?)?.toInt() ?? 0,
      ),
    );
  }
}

/// iBox PlayItem 缓存项（对齐 iOS `BaiduIBoxPlayItem`；保留 path 以便
/// dlink 过期后刷新）。
class BaiduIBoxPlayItem {
  /// 构造。
  const BaiduIBoxPlayItem({
    required this.shareUrl,
    required this.fsId,
    required this.fileName,
    required this.path,
    this.dlinkUrl,
    this.headers = const <String, String>{},
    this.dlinkExpiresAt,
    this.compatibilityHint = '',
    this.preferredEngine = '',
    required this.preparedAt,
    required this.updatedAt,
    this.lastUsedAt,
    this.source = '',
  });

  /// 分享链接。
  final String shareUrl;

  /// 文件 ID。
  final String fsId;

  /// 文件名。
  final String fileName;

  /// 转存后的真实路径（`/vbox/xxx`；dlink 过期后用其刷新）。
  final String path;

  /// 已备好的 dlink（可空）。
  final String? dlinkUrl;

  /// 播放请求头。
  final Map<String, String> headers;

  /// dlink 过期时刻（可空）。
  final DateTime? dlinkExpiresAt;

  /// 兼容性提示（如 mkv/hevc；对齐 iOS `baiduCompatibilityHint`）。
  final String compatibilityHint;

  /// 首选引擎标记（对齐 iOS `baiduPreferredEngine`）。
  final String preferredEngine;

  /// 首次备好时刻。
  final DateTime preparedAt;

  /// 最近更新时刻。
  final DateTime updatedAt;

  /// 最近使用时刻。
  final DateTime? lastUsedAt;

  /// 来源标记（诊断用）。
  final String source;

  /// 拷贝并覆盖若干字段。
  BaiduIBoxPlayItem copyWith({
    String? path,
    String? Function()? dlinkUrl,
    Map<String, String>? headers,
    DateTime? Function()? dlinkExpiresAt,
    DateTime? updatedAt,
    DateTime? lastUsedAt,
    String? source,
  }) =>
      BaiduIBoxPlayItem(
        shareUrl: shareUrl,
        fsId: fsId,
        fileName: fileName,
        path: path ?? this.path,
        dlinkUrl: dlinkUrl != null ? dlinkUrl() : this.dlinkUrl,
        headers: headers ?? this.headers,
        dlinkExpiresAt:
            dlinkExpiresAt != null ? dlinkExpiresAt() : this.dlinkExpiresAt,
        compatibilityHint: compatibilityHint,
        preferredEngine: preferredEngine,
        preparedAt: preparedAt,
        updatedAt: updatedAt ?? this.updatedAt,
        lastUsedAt: lastUsedAt ?? this.lastUsedAt,
        source: source ?? this.source,
      );

  /// → JSON。
  Map<String, Object?> toJson() => <String, Object?>{
        'shareURL': shareUrl,
        'fsId': fsId,
        'fileName': fileName,
        'path': path,
        if (dlinkUrl != null) 'dlinkURL': dlinkUrl,
        'headers': headers,
        if (dlinkExpiresAt != null)
          'dlinkExpiresAt': dlinkExpiresAt!.millisecondsSinceEpoch,
        'compatibilityHint': compatibilityHint,
        'preferredEngine': preferredEngine,
        'preparedAt': preparedAt.millisecondsSinceEpoch,
        'updatedAt': updatedAt.millisecondsSinceEpoch,
        if (lastUsedAt != null) 'lastUsedAt': lastUsedAt!.millisecondsSinceEpoch,
        'source': source,
      };

  /// ← JSON。
  static BaiduIBoxPlayItem? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final String fsId = raw['fsId']?.toString() ?? '';
    if (fsId.isEmpty) return null;
    final Map<String, String> headers = <String, String>{};
    final Object? h = raw['headers'];
    if (h is Map) {
      for (final MapEntry<Object?, Object?> e in h.entries) {
        headers[e.key.toString()] = e.value?.toString() ?? '';
      }
    }
    DateTime? at(Object? v) => v is num
        ? DateTime.fromMillisecondsSinceEpoch(v.toInt())
        : null;
    final String? dlink = raw['dlinkURL']?.toString();
    return BaiduIBoxPlayItem(
      shareUrl: raw['shareURL']?.toString() ?? '',
      fsId: fsId,
      fileName: raw['fileName']?.toString() ?? '',
      path: raw['path']?.toString() ?? '',
      dlinkUrl: (dlink != null && dlink.isNotEmpty) ? dlink : null,
      headers: headers,
      dlinkExpiresAt: at(raw['dlinkExpiresAt']),
      compatibilityHint: raw['compatibilityHint']?.toString() ?? '',
      preferredEngine: raw['preferredEngine']?.toString() ?? '',
      preparedAt: at(raw['preparedAt']) ?? DateTime.fromMillisecondsSinceEpoch(0),
      updatedAt: at(raw['updatedAt']) ?? DateTime.fromMillisecondsSinceEpoch(0),
      lastUsedAt: at(raw['lastUsedAt']),
      source: raw['source']?.toString() ?? '',
    );
  }
}

/// 分享上下文缓存项（对齐 iOS `BaiduShareContext`）。
class BaiduShareContextCacheItem {
  /// 构造。
  const BaiduShareContextCacheItem({
    required this.shareUrl,
    required this.surl,
    this.pwd,
    required this.shareid,
    required this.shareUk,
    this.bdstoken,
    this.randsk,
    required this.cookie,
    required this.files,
    this.source = '',
    this.expiresAt,
  });

  /// 分享链接。
  final String shareUrl;

  /// 短链 surl（含前导 `1`）。
  final String surl;

  /// 提取码（可空）。
  final String? pwd;

  /// 分享 ID。
  final String shareid;

  /// 分享者 uk。
  final String shareUk;

  /// 分享页 bdstoken（可空）。
  final String? bdstoken;

  /// 提取码验证后的 randsk（可空）。
  final String? randsk;

  /// 链路合并出的 Cookie。
  final String cookie;

  /// 可播放文件列表。
  final List<BaiduCacheFile> files;

  /// 来源标记。
  final String source;

  /// 过期时刻（写侧由 [BaiduPlaybackCacheStore.storeShareContext] 计算）。
  final DateTime? expiresAt;

  /// → JSON。
  Map<String, Object?> toJson() => <String, Object?>{
        'shareURL': shareUrl,
        'surl': surl,
        if (pwd != null) 'pwd': pwd,
        'shareid': shareid,
        'shareUk': shareUk,
        if (bdstoken != null) 'bdstoken': bdstoken,
        if (randsk != null) 'randsk': randsk,
        'cookie': cookie,
        'files': files.map((BaiduCacheFile f) => f.toJson()).toList(),
        'source': source,
        'expiresAt': expiresAt?.millisecondsSinceEpoch ?? 0,
      };

  /// ← JSON。
  static BaiduShareContextCacheItem? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? filesRaw = raw['files'];
    final List<BaiduCacheFile> files = filesRaw is List
        ? filesRaw
            .map(BaiduCacheFile.fromJson)
            .whereType<BaiduCacheFile>()
            .toList(growable: false)
        : const <BaiduCacheFile>[];
    String? opt(Object? v) {
      final String s = v?.toString() ?? '';
      return s.isEmpty ? null : s;
    }

    return BaiduShareContextCacheItem(
      shareUrl: raw['shareURL']?.toString() ?? '',
      surl: raw['surl']?.toString() ?? '',
      pwd: opt(raw['pwd']),
      shareid: raw['shareid']?.toString() ?? '',
      shareUk: raw['shareUk']?.toString() ?? '',
      bdstoken: opt(raw['bdstoken']),
      randsk: opt(raw['randsk']),
      cookie: raw['cookie']?.toString() ?? '',
      files: files,
      source: raw['source']?.toString() ?? '',
      expiresAt: raw['expiresAt'] is num
          ? DateTime.fromMillisecondsSinceEpoch(
              (raw['expiresAt'] as num).toInt(),
            )
          : null,
    );
  }
}

/// 百度链路诊断条目（对齐 iOS `BaiduRouteDiagnostic`）。
class BaiduRouteDiagnostic {
  /// 构造。
  const BaiduRouteDiagnostic({
    required this.time,
    required this.stage,
    required this.status,
    required this.detail,
    this.fsId,
    this.fileName,
  });

  /// 记录时刻。
  final DateTime time;

  /// 阶段（对齐 iOS stage 取值集合）。
  final String stage;

  /// 状态。
  final String status;

  /// 详情。
  final String detail;

  /// 文件 ID（可空）。
  final String? fsId;

  /// 文件名（可空）。
  final String? fileName;

  /// → JSON。
  Map<String, Object?> toJson() => <String, Object?>{
        'time': time.millisecondsSinceEpoch,
        'stage': stage,
        'status': status,
        'detail': detail,
        if (fsId != null) 'fsId': fsId,
        if (fileName != null) 'fileName': fileName,
      };

  /// ← JSON。
  static BaiduRouteDiagnostic? fromJson(Object? raw) {
    if (raw is! Map) return null;
    return BaiduRouteDiagnostic(
      time: DateTime.fromMillisecondsSinceEpoch(
        (raw['time'] as num?)?.toInt() ?? 0,
      ),
      stage: raw['stage']?.toString() ?? '',
      status: raw['status']?.toString() ?? '',
      detail: raw['detail']?.toString() ?? '',
      fsId: raw['fsId']?.toString(),
      fileName: raw['fileName']?.toString(),
    );
  }
}

/// 百度播放缓存摘要（对齐 iOS `BaiduPlaybackCacheSummary` 的有效字段子集）。
///
/// 落地差异（登记）：iOS `playItemCount` 取自死键 `baidu_play_item_cache_v1`
/// （恒为 0），故不单列字段。
class BaiduPlaybackCacheSummary {
  /// 构造。
  const BaiduPlaybackCacheSummary({
    required this.playResultCount,
    required this.expiredPlayResultCount,
    required this.iBoxPlayItemCount,
    required this.validIBoxDlinkCount,
    required this.expiredIBoxDlinkCount,
    required this.fileListCount,
    required this.expiredFileListCount,
    required this.storageBytes,
    this.lastUpdatedAt,
  });

  /// 播放结果缓存条数。
  final int playResultCount;

  /// 已过期播放结果条数。
  final int expiredPlayResultCount;

  /// iBox PlayItem 条数。
  final int iBoxPlayItemCount;

  /// 有效 dlink 条数。
  final int validIBoxDlinkCount;

  /// 已过期 dlink 条数。
  final int expiredIBoxDlinkCount;

  /// 文件列表缓存条数。
  final int fileListCount;

  /// 已过期文件列表条数。
  final int expiredFileListCount;

  /// 占用字节数（相关键原始字符串字节和）。
  final int storageBytes;

  /// 最近更新时刻。
  final DateTime? lastUpdatedAt;

  /// 总条数。
  int get totalCount =>
      playResultCount + iBoxPlayItemCount + fileListCount;
}

/// 百度播放缓存统一层（纯持久化，全部经 [PrefsManager]）。
class BaiduPlaybackCacheStore {
  /// 构造（注入契约偏好管理器）。
  BaiduPlaybackCacheStore(this._prefs);

  final PrefsManager _prefs;

  /// 播放结果缓存键（对齐 iOS `baiduPersistedPlayCacheKey`）。
  static const String playResultKey = 'baidu_play_result_cache_v1';

  /// iBox PlayItem 缓存键。
  static const String iboxPlayItemKey = 'baidu_ibox_play_item_cache_v1';

  /// 文件列表缓存键。
  static const String fileListKey = 'baidu_file_list_cache_v1';

  /// 分享上下文缓存键。
  static const String shareContextKey = 'baidu_share_context_cache_v1';

  /// 路由诊断键。
  static const String routeDiagnosticsKey = 'baidu_route_diagnostics_v1';

  /// 播放结果缓存 TTL（对齐 iOS `storePlayResult` 默认 6h）。
  static const Duration playResultTtl = Duration(hours: 6);

  /// 文件列表缓存 TTL（对齐 iOS `storeFileList` 默认 8h）。
  static const Duration fileListTtl = Duration(hours: 8);

  /// 分享上下文缓存 TTL（对齐 iOS `storeShareContext` 默认 8h）。
  static const Duration shareContextTtl = Duration(hours: 8);

  /// iBox dlink 缓存 TTL（对齐 iOS `baiduStoreIBoxPlayItem` 写 `+6h`）。
  static const Duration iboxDlinkTtl = Duration(hours: 6);

  /// 播放结果容量上限（对齐 iOS 80）。
  static const int playResultCap = 80;

  /// iBox PlayItem 容量上限（对齐 iOS 160）。
  static const int iboxPlayItemCap = 160;

  /// 文件列表容量上限（对齐 iOS 80）。
  static const int fileListCap = 80;

  /// 分享上下文容量上限（对齐 iOS 60）。
  static const int shareContextCap = 60;

  /// 诊断条目上限（对齐 iOS 60）。
  static const int routeDiagnosticsCap = 60;

  // ─────────────────── 键派生（对齐 iOS 同名函数）───────────────────

  /// FNV-1a 64 位稳定哈希（对齐 iOS `baiduStableHash`，UInt64，输出 hex）。
  static String stableHash(String input) {
    int hash = 1469598103934665603;
    for (final int b in utf8.encode(input)) {
      hash ^= b;
      hash = hash * 1099511628211;
    }
    // Dart int 为 64 位有符号，按 UInt64 语义输出无符号十六进制。
    return BigInt.from(hash).toUnsigned(64).toRadixString(16);
  }

  /// 播放缓存基础键（对齐 iOS `baiduPlayCacheKey`）。
  static String playCacheKey({
    required String shareUrl,
    required String fsId,
    required String bduss,
    String pcsCookie = '',
  }) =>
      '$shareUrl|$fsId|${stableHash(bduss)}|${stableHash(pcsCookie)}';

  /// 主路链缓存键（对齐 iOS `baiduMainRouteCacheKey`：前缀 `main-route-v2|`）。
  static String mainRouteCacheKey({
    required String shareUrl,
    required String fsId,
    required String bduss,
    String pcsCookie = '',
  }) =>
      'main-route-v2|${playCacheKey(shareUrl: shareUrl, fsId: fsId, bduss: bduss, pcsCookie: pcsCookie)}';

  /// 文件列表缓存键（对齐 iOS `baiduFileListCacheKey`）。
  static String fileListCacheKey({
    required String shareUrl,
    required String bduss,
  }) =>
      '$shareUrl|${stableHash(bduss)}';

  /// 分享上下文缓存键（对齐 iOS `baiduShareContextKey`）。
  static String shareContextCacheKey({
    required String shareUrl,
    required String cookie,
  }) =>
      '$shareUrl|${stableHash(cookie)}';

  // ─────────────────── 通用 JSON 助手 ───────────────────

  Future<Map<String, Object?>> _loadMap(String key) async {
    final String raw = await _prefs.getString(key);
    if (raw.isEmpty) return <String, Object?>{};
    try {
      final Object? decoded = jsonDecode(raw);
      return decoded is Map ? decoded.cast<String, Object?>() : <String, Object?>{};
    } on FormatException {
      return <String, Object?>{};
    }
  }

  Future<void> _saveMap(String key, Map<String, Object?> value) async {
    await _prefs.set(key, jsonEncode(value));
  }

  // ─────────────────── 播放结果缓存 ───────────────────

  /// 读播放结果缓存（命中且未过期才返回；过期项顺手剔除）。
  Future<BaiduPersistedPlayCacheItem?> cachedPlayResult(
    String key, {
    DateTime? now,
  }) async {
    final Map<String, Object?> cache = await _loadMap(playResultKey);
    final DateTime ts = now ?? DateTime.now();
    bool dirty = false;
    for (final MapEntry<String, Object?> e in cache.entries.toList()) {
      final BaiduPersistedPlayCacheItem? item =
          BaiduPersistedPlayCacheItem.fromJson(e.value);
      if (item == null || !item.expiresAt.isAfter(ts)) {
        cache.remove(e.key);
        dirty = true;
      }
    }
    if (dirty) await _saveMap(playResultKey, cache);
    return BaiduPersistedPlayCacheItem.fromJson(cache[key]);
  }

  /// 写播放结果缓存（TTL 6h，上限 80 按过期时刻裁剪）。
  Future<void> storePlayResult(
    String key, {
    required String url,
    required Map<String, String> headers,
    DateTime? now,
    Duration ttl = playResultTtl,
  }) async {
    final DateTime ts = now ?? DateTime.now();
    Map<String, Object?> cache = await _loadMap(playResultKey);
    cache[key] = BaiduPersistedPlayCacheItem(
      url: url,
      headers: headers,
      expiresAt: ts.add(ttl),
    ).toJson();
    cache = cache.map((String k, Object? v) => MapEntry<String, Object?>(
          k,
          BaiduPersistedPlayCacheItem.fromJson(v)?.toJson() ?? v,
        ));
    cache.removeWhere((String _, Object? v) =>
        (BaiduPersistedPlayCacheItem.fromJson(v)?.expiresAt
                .isAfter(ts) ??
            false) ==
        false);
    if (cache.length > playResultCap) {
      final List<MapEntry<String, Object?>> sorted = cache.entries.toList()
        ..sort((MapEntry<String, Object?> a, MapEntry<String, Object?> b) {
          final DateTime? ea =
              BaiduPersistedPlayCacheItem.fromJson(a.value)?.expiresAt;
          final DateTime? eb =
              BaiduPersistedPlayCacheItem.fromJson(b.value)?.expiresAt;
          return (eb ?? DateTime.fromMillisecondsSinceEpoch(0))
              .compareTo(ea ?? DateTime.fromMillisecondsSinceEpoch(0));
        });
      cache = Map<String, Object?>.fromEntries(sorted.take(playResultCap));
    }
    await _saveMap(playResultKey, cache);
  }

  /// 失效播放缓存（对齐 iOS `invalidateBaiduPlaybackCache`：删播放结果键 +
  /// 保留 iBox path 仅清 dlink）。
  Future<void> invalidatePlayback(
    List<String> keys, {
    String reason = '手动刷新',
    DateTime? now,
  }) async {
    final DateTime ts = now ?? DateTime.now();
    final Map<String, Object?> playCache = await _loadMap(playResultKey);
    bool playDirty = false;
    for (final String k in keys) {
      playDirty = playCache.remove(k) != null || playDirty;
    }
    if (playDirty) await _saveMap(playResultKey, playCache);

    final Map<String, Object?> iboxCache = await _loadMap(iboxPlayItemKey);
    bool iboxDirty = false;
    for (final String k in keys) {
      final BaiduIBoxPlayItem? item =
          BaiduIBoxPlayItem.fromJson(iboxCache[k]);
      if (item == null) continue;
      iboxCache[k] = item
          .copyWith(
            dlinkUrl: () => null,
            dlinkExpiresAt: () => null,
            updatedAt: ts,
            source: '${item.source}-invalidated',
          )
          .toJson();
      iboxDirty = true;
    }
    if (iboxDirty) await _saveMap(iboxPlayItemKey, iboxCache);
  }

  // ─────────────────── 文件列表缓存 ───────────────────

  /// 读文件列表缓存（命中且未过期且非空才返回；过期项剔除）。
  Future<List<BaiduCacheFile>?> cachedFileList(
    String key, {
    DateTime? now,
  }) async {
    final DateTime ts = now ?? DateTime.now();
    final Map<String, Object?> cache = await _loadMap(fileListKey);
    final Object? entry = cache[key];
    if (entry is! Map) return null;
    final List<BaiduCacheFile> files = _decodeFiles(entry['files']);
    final int exp = (entry['expiresAt'] as num?)?.toInt() ?? 0;
    if (exp > ts.millisecondsSinceEpoch && files.isNotEmpty) return files;
    cache.remove(key);
    await _saveMap(fileListKey, cache);
    return null;
  }

  /// 写文件列表缓存（TTL 8h，上限 80 仅保留未过期）。
  Future<void> storeFileList(
    String key,
    List<BaiduCacheFile> files, {
    DateTime? now,
    Duration ttl = fileListTtl,
  }) async {
    if (files.isEmpty) return;
    final DateTime ts = now ?? DateTime.now();
    Map<String, Object?> cache = await _loadMap(fileListKey);
    cache[key] = <String, Object?>{
      'files': files.map((BaiduCacheFile f) => f.toJson()).toList(),
      'expiresAt': ts.add(ttl).millisecondsSinceEpoch,
    };
    if (cache.length > fileListCap) {
      cache.removeWhere((String _, Object? v) {
        final Map<Object?, Object?> m =
            v is Map ? v : const <Object?, Object?>{};
        return ((m['expiresAt'] as num?)?.toInt() ?? 0) <=
            ts.millisecondsSinceEpoch;
      });
    }
    await _saveMap(fileListKey, cache);
  }

  // ─────────────────── iBox PlayItem 缓存 ───────────────────

  /// 读 iBox PlayItem（无 TTL，过期由调用方按 `dlinkExpiresAt` 判定）。
  Future<BaiduIBoxPlayItem?> cachedIBoxPlayItem(String key) async {
    final Map<String, Object?> cache = await _loadMap(iboxPlayItemKey);
    return BaiduIBoxPlayItem.fromJson(cache[key]);
  }

  /// 写 iBox PlayItem（上限 160 按 updatedAt 裁剪）。
  Future<void> storeIBoxPlayItem(String key, BaiduIBoxPlayItem item) async {
    Map<String, Object?> cache = await _loadMap(iboxPlayItemKey);
    cache[key] = item.toJson();
    if (cache.length > iboxPlayItemCap) {
      final List<MapEntry<String, Object?>> sorted = cache.entries.toList()
        ..sort((MapEntry<String, Object?> a, MapEntry<String, Object?> b) {
          final DateTime? ua = BaiduIBoxPlayItem.fromJson(a.value)?.updatedAt;
          final DateTime? ub = BaiduIBoxPlayItem.fromJson(b.value)?.updatedAt;
          return (ub ?? DateTime.fromMillisecondsSinceEpoch(0))
              .compareTo(ua ?? DateTime.fromMillisecondsSinceEpoch(0));
        });
      cache = Map<String, Object?>.fromEntries(sorted.take(iboxPlayItemCap));
    }
    await _saveMap(iboxPlayItemKey, cache);
  }

  // ─────────────────── 分享上下文缓存 ───────────────────

  /// 读分享上下文（对齐 iOS `baiduCachedShareContext` 完整性校验：
  /// 过期 / shareid / shareUk / files / bdstoken 缺失即丢弃；
  /// [needsRandsk] 为真时还要求 randsk 非空）。
  Future<BaiduShareContextCacheItem?> cachedShareContext(
    String key, {
    bool needsRandsk = false,
    DateTime? now,
  }) async {
    final DateTime ts = now ?? DateTime.now();
    final Map<String, Object?> cache = await _loadMap(shareContextKey);
    final BaiduShareContextCacheItem? ctx =
        BaiduShareContextCacheItem.fromJson(cache[key]);
    if (ctx == null) return null;
    final bool valid = (ctx.expiresAt?.isAfter(ts) ?? false) &&
        ctx.shareid.isNotEmpty &&
        ctx.shareUk.isNotEmpty &&
        ctx.files.isNotEmpty &&
        (ctx.bdstoken ?? '').isNotEmpty &&
        (!needsRandsk || (ctx.randsk ?? '').isNotEmpty);
    if (valid) return ctx;
    cache.remove(key);
    await _saveMap(shareContextKey, cache);
    return null;
  }

  /// 写分享上下文（TTL 8h，上限 60 仅保留未过期）。
  Future<void> storeShareContext(
    String key,
    BaiduShareContextCacheItem item, {
    DateTime? now,
    Duration ttl = shareContextTtl,
  }) async {
    if (item.shareid.isEmpty || item.shareUk.isEmpty || item.files.isEmpty) {
      return;
    }
    final DateTime ts = now ?? DateTime.now();
    Map<String, Object?> cache = await _loadMap(shareContextKey);
    cache[key] = BaiduShareContextCacheItem(
      shareUrl: item.shareUrl,
      surl: item.surl,
      pwd: item.pwd,
      shareid: item.shareid,
      shareUk: item.shareUk,
      bdstoken: item.bdstoken,
      randsk: item.randsk,
      cookie: item.cookie,
      files: item.files,
      source: item.source,
      expiresAt: ts.add(ttl),
    ).toJson();
    if (cache.length > shareContextCap) {
      cache.removeWhere((String _, Object? v) {
        final Map<Object?, Object?> m =
            v is Map ? v : const <Object?, Object?>{};
        return ((m['expiresAt'] as num?)?.toInt() ?? 0) <=
            ts.millisecondsSinceEpoch;
      });
    }
    await _saveMap(shareContextKey, cache);
  }

  // ─────────────────── 路由诊断 ───────────────────

  /// 记录一条诊断（头插、上限 60，对齐 iOS `recordBaiduRouteDiagnostic`）。
  Future<void> recordRouteDiagnostic({
    required String stage,
    required String status,
    required String detail,
    String? fsId,
    String? fileName,
    DateTime? now,
  }) async {
    final List<BaiduRouteDiagnostic> items =
        await recentRouteDiagnostics();
    items.insert(
      0,
      BaiduRouteDiagnostic(
        time: now ?? DateTime.now(),
        stage: stage,
        status: status,
        detail: detail,
        fsId: fsId,
        fileName: fileName,
      ),
    );
    final List<BaiduRouteDiagnostic> capped = items.length > routeDiagnosticsCap
        ? items.sublist(0, routeDiagnosticsCap)
        : items;
    await _prefs.set(
      routeDiagnosticsKey,
      jsonEncode(capped.map((BaiduRouteDiagnostic d) => d.toJson()).toList()),
    );
  }

  /// 读全部诊断（新→旧）。
  Future<List<BaiduRouteDiagnostic>> recentRouteDiagnostics() async {
    final String raw = await _prefs.getString(routeDiagnosticsKey);
    if (raw.isEmpty) return <BaiduRouteDiagnostic>[];
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! List) return <BaiduRouteDiagnostic>[];
      return decoded
          .map(BaiduRouteDiagnostic.fromJson)
          .whereType<BaiduRouteDiagnostic>()
          .toList(growable: true);
    } on FormatException {
      return <BaiduRouteDiagnostic>[];
    }
  }

  /// 清空诊断（对齐 iOS `clearBaiduRouteDiagnostics`）。
  Future<void> clearRouteDiagnostics() async {
    await _prefs.remove(routeDiagnosticsKey);
  }

  // ─────────────────── 摘要与清理 ───────────────────

  /// 摘要（对齐 iOS `baiduPlaybackCacheSummary`）。
  Future<BaiduPlaybackCacheSummary> summary({DateTime? now}) async {
    final DateTime ts = now ?? DateTime.now();
    final Map<String, Object?> playCache = await _loadMap(playResultKey);
    final Map<String, Object?> iboxCache = await _loadMap(iboxPlayItemKey);
    final Map<String, Object?> fileLists = await _loadMap(fileListKey);

    int expiredPlay = 0;
    final List<DateTime> dates = <DateTime>[];
    for (final Object? v in playCache.values) {
      final BaiduPersistedPlayCacheItem? item =
          BaiduPersistedPlayCacheItem.fromJson(v);
      if (item == null) continue;
      dates.add(item.expiresAt);
      if (!item.expiresAt.isAfter(ts)) expiredPlay++;
    }
    int validIBox = 0;
    int expiredIBox = 0;
    for (final Object? v in iboxCache.values) {
      final BaiduIBoxPlayItem? item = BaiduIBoxPlayItem.fromJson(v);
      if (item == null) continue;
      dates.add(item.updatedAt);
      final DateTime? exp = item.dlinkExpiresAt;
      final bool hasDlink = (item.dlinkUrl ?? '').isNotEmpty;
      if (exp != null && hasDlink) {
        if (exp.isAfter(ts)) {
          validIBox++;
        } else {
          expiredIBox++;
        }
      }
    }
    int expiredFileLists = 0;
    for (final Object? v in fileLists.values) {
      final Map<Object?, Object?> m =
          v is Map ? v : const <Object?, Object?>{};
      final int exp = (m['expiresAt'] as num?)?.toInt() ?? 0;
      dates.add(DateTime.fromMillisecondsSinceEpoch(exp));
      if (exp <= ts.millisecondsSinceEpoch) expiredFileLists++;
    }
    int bytes = 0;
    for (final String k in <String>[
      playResultKey,
      iboxPlayItemKey,
      fileListKey,
      shareContextKey,
    ]) {
      bytes += utf8.encode(await _prefs.getString(k)).length;
    }
    dates.sort();
    return BaiduPlaybackCacheSummary(
      playResultCount: playCache.length,
      expiredPlayResultCount: expiredPlay,
      iBoxPlayItemCount: iboxCache.length,
      validIBoxDlinkCount: validIBox,
      expiredIBoxDlinkCount: expiredIBox,
      fileListCount: fileLists.length,
      expiredFileListCount: expiredFileLists,
      storageBytes: bytes,
      lastUpdatedAt: dates.isEmpty ? null : dates.last,
    );
  }

  /// 清理过期（对齐 iOS `clearExpiredBaiduPlaybackCaches`：删过期播放结果/文件
  /// 列表/分享上下文；iBox 条目保留 path 仅清过期 dlink）。
  Future<void> clearExpired({DateTime? now}) async {
    final DateTime ts = now ?? DateTime.now();
    final Map<String, Object?> playCache = await _loadMap(playResultKey);
    playCache.removeWhere((String _, Object? v) =>
        (BaiduPersistedPlayCacheItem.fromJson(v)?.expiresAt.isAfter(ts) ??
            false) ==
        false);
    await _saveMap(playResultKey, playCache);

    final Map<String, Object?> fileLists = await _loadMap(fileListKey);
    fileLists.removeWhere((String _, Object? v) {
      final Map<Object?, Object?> m =
          v is Map ? v : const <Object?, Object?>{};
      return ((m['expiresAt'] as num?)?.toInt() ?? 0) <= ts.millisecondsSinceEpoch;
    });
    await _saveMap(fileListKey, fileLists);

    final Map<String, Object?> contexts = await _loadMap(shareContextKey);
    contexts.removeWhere((String _, Object? v) {
      final Map<Object?, Object?> m =
          v is Map ? v : const <Object?, Object?>{};
      return ((m['expiresAt'] as num?)?.toInt() ?? 0) <= ts.millisecondsSinceEpoch;
    });
    await _saveMap(shareContextKey, contexts);

    final Map<String, Object?> iboxCache = await _loadMap(iboxPlayItemKey);
    for (final MapEntry<String, Object?> e in iboxCache.entries.toList()) {
      final BaiduIBoxPlayItem? item = BaiduIBoxPlayItem.fromJson(e.value);
      final DateTime? exp = item?.dlinkExpiresAt;
      if (item == null || exp == null || exp.isAfter(ts)) continue;
      iboxCache[e.key] = item
          .copyWith(
            dlinkUrl: () => null,
            dlinkExpiresAt: () => null,
            updatedAt: ts,
            source: '${item.source}-expired-cleaned',
          )
          .toJson();
    }
    await _saveMap(iboxPlayItemKey, iboxCache);
  }

  /// 全量清空（对齐 iOS `clearAllBaiduPlaybackCaches`：清 6 键）。
  Future<void> clearAll() async {
    for (final String k in <String>[
      playResultKey,
      iboxPlayItemKey,
      fileListKey,
      shareContextKey,
      'baidu_play_item_cache_v1',
      'baidu_verify_cooldown_v1',
    ]) {
      await _prefs.remove(k);
    }
  }

  static List<BaiduCacheFile> _decodeFiles(Object? raw) =>
      raw is List
          ? raw.map(BaiduCacheFile.fromJson).whereType<BaiduCacheFile>().toList(
              growable: false,
            )
          : const <BaiduCacheFile>[];
}
