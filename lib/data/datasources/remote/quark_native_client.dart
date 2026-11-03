/// 数据层：夸克网盘原生分享链客户端（批次 F · F-P01，对齐 iOS
/// `CloudDriveManager` 的夸克分支）。
///
/// 唯一真相源：`vbox/Services/CloudDriveManager.swift`
///   · `quarkExtractShareInfo`（L2589）：分享链接 → `pwdId` / `passcode`；
///   · `quarkAPIURL` / `quarkAPIURLWithStrictQuery`（L2616/L2646）：`drive-pc.quark.cn`
///     统一 query（`pr=ucpro&fr=pc&uc_param_str=`）+ stoken 严格编码；
///   · `quarkSetCommonHeaders`（L2626）：Cookie / Origin / Referer / UA / X-Client；
///   · `quarkGetShareToken`（L2755）：`POST /1/clouddrive/share/sharepage/token`；
///   · `quarkGetShareDetail`（L3795）：`GET …/sharepage/detail`（`_size=100` 分页）；
///   · `quarkCollectAllPlayableFiles`（L3772）：递归收集可播放文件（≤20 页）；
///   · `quarkSaveShare`（L3845）：`POST …/sharepage/save`（转存到根 `to_pdir_fid=0`）；
///   · `quarkPollTask`（L3618）：`GET /1/clouddrive/task` 轮询转存落盘；
///   · `quarkRefreshVideoAuth`（L4211）：`POST /1/clouddrive/file/v2/play` →
///     `video_list` 按 `low→4k` 选流（转码 m3u8，作兜底）；
///   · `quarkAcquireDLToken`（L4049）：`POST drive-social-api.quark.cn
///     /1/clouddrive/chat/conv/file/acquire_dl_token`（加速下载 token）；
///   · `quarkGetDownloadURL`（L4086）：`POST /1/clouddrive/file/download` →
///     原画直链 `download_url`（主线路）；
///   · `quarkFindFirstVideoInFolder`（L4138）：v2/play 返回 `not video` 时
///     BFS 定位文件夹内真实视频文件 fid；
///   · `resolveQuarkPlayURL`（L2298）：线路拓扑 —— 主=原画 `download_url`、
///     兜底=转码 `v2-play-m3u8`（`routePreference="transcode"` 时反转）。
///
/// 简化登记（如实）：
///   · **Set-Cookie 合并**：由 HTTP 桥 `SpiderHttpBridge` 的 **cookie jar**
///     （`storeFromResponse` + 每请求自动附加）等价覆盖，无需客户端显式合并；
///   · **转存 fid 缓存**：已实现（契约键 `quark_saved_fid_cache_v1`，TTL 5 分钟、
///     上限 300，键 `pwdId|sourceFid|folderId|cookieHash`）；
///   · **空间清理**（`quarkCleanShareOriginIfNeeded`，容量阈值触发删除
///     「来自：分享」旧转存 + 根目录视频）——**NC-清1 已移植**：含
///     `getQuotaInfo`（member → quota/info 双端点）、`file/sort` 收集、
///     `file/delete` 分批删除（含转存缓存受保护 fid 排除）；另移植
///     `deleteFiles`（对齐 iOS `quarkDeleteFiles`：删除 + 回收站彻底清理）。
///     差异登记：iOS 返回合并后 Cookie，Flutter 由 HTTP 桥 cookie jar 等价
///     承载，故本层改为返回清理条数（便于日志/测试断言）。
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart' as crypto;

import '../../../domain/entities/cloud/cloud_drive.dart';
import '../../../platform/spider/spider_http_bridge.dart';
import '../local/prefs_manager.dart';
import 'cloud_drive_cleanup_scheduler.dart';

/// 夸克分享文件条目（对齐 iOS `QuarkShareFile`）。
class QuarkShareFile {
  /// 构造。
  const QuarkShareFile({
    required this.fid,
    required this.fileName,
    this.shareFidToken = '',
    this.pdirFid = '',
    this.isDir = false,
  });

  /// 文件 / 文件夹 ID。
  final String fid;

  /// 文件名。
  final String fileName;

  /// 分享侧 fid token（转存需带上）。
  final String shareFidToken;

  /// 所属目录 fid。
  final String pdirFid;

  /// 是否文件夹。
  final bool isDir;
}

/// 夸克取链结果（对齐 iOS `PlayResult`：主线路 + 兜底线路拓扑）。
class QuarkPlayResult {
  /// 构造。
  const QuarkPlayResult({
    required this.url,
    required this.fileName,
    this.source = '',
    this.headers = const <String, String>{},
    this.fallbackUrl,
    this.fallbackHeaders = const <String, String>{},
    this.fallbackSource = '',
  });

  /// 主线路播放地址（对齐 iOS `PlayResult.url`：原画直链 / 转码 m3u8）。
  final String url;

  /// 关联文件名（缓存键 / 展示用）。
  final String fileName;

  /// 主线路来源标记（`download_url` / `v2-play-m3u8`，对齐 iOS
  /// `resolveQuarkPlayURL` 的线路选择）。
  final String source;

  /// 主线路播放请求头（对齐 iOS `quarkPlaybackHeaders`；走 Go 代理时由代理
  /// 注入，此处仅作降级直链用）。
  final Map<String, String> headers;

  /// 兜底线路地址（null 表示无兜底，对齐 iOS `PlayResult.fallbackURL`）。
  final String? fallbackUrl;

  /// 兜底线路请求头（对齐 iOS `PlayResult.fallbackHeaders`）。
  final Map<String, String> fallbackHeaders;

  /// 兜底线路来源标记（对齐 iOS `PlayResult.fallbackSource`）。
  final String fallbackSource;
}

/// 夸克原生链异常（对齐 iOS `DriveError` 分档文案）。
class QuarkNativeException implements Exception {
  /// 构造。
  const QuarkNativeException(this.message);

  /// 文案。
  final String message;

  @override
  String toString() => 'QuarkNativeException($message)';
}

/// 夸克原生分享链客户端。
class QuarkNativeClient {
  /// 构造（[bridge] 供测试注入假传输；[prefs] 供测试注入偏好存储）。
  QuarkNativeClient({SpiderHttpBridge? bridge, PrefsManager? prefs})
      : _bridge = bridge ?? SpiderHttpBridge(),
        _prefs = prefs;

  /// 转存 fid 缓存契约键（对齐 iOS `quark_saved_fid_cache_v1`）。
  static const String savedFidCacheKey = 'quark_saved_fid_cache_v1';

  /// 转存 fid 缓存有效期（对齐 iOS `ttl: 5 * 60`）。
  static const Duration savedFidTtl = Duration(minutes: 5);

  /// 转存 fid 缓存上限（对齐 iOS `> 300` 裁剪）。
  static const int savedFidCacheMax = 300;

  /// API 主机（对齐 iOS `quarkAPIURL`）。
  static const String apiHost = 'https://drive-pc.quark.cn';

  /// 加速下载 token 主机（对齐 iOS `quarkAcquireDLToken`：不是 `drive-pc`）。
  static const String socialHost = 'https://drive-social-api.quark.cn';

  /// 默认 Referer（非分享场景）。
  static const String defaultReferer = 'https://pan.quark.cn/';

  /// 夸克桌面 UA（对齐 iOS `quarkPlaybackHeaders` 抓包值）。
  static const String desktopUA =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) quark-cloud-drive/2.5.20 '
      'Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 '
      'Safari/537.36 Channel/pckk_other_ch';

  /// 夸克设备 ID 契约键（对齐 iOS `quark_device_id`）。
  static const String deviceIdKey = 'quark_device_id';

  /// 播放清晰度优先级（对齐 iOS：普通会员下 low 最流畅）。
  static const List<String> qualityOrder = <String>[
    'low', 'normal', 'high', 'super', '2k', '4k',
  ];

  /// 可播放扩展名（对齐 iOS `quarkIsPlayableFileName`）。
  static const List<String> playableExts = <String>[
    'mp4', 'mkv', 'mov', 'm3u8', 'avi', 'wmv', 'flv', 'ts', 'mp3', 'm4a',
  ];

  final SpiderHttpBridge _bridge;
  final PrefsManager? _prefs;

  /// 转存后延迟清理调度（对齐 iOS `scheduleCleanup`；缺省不调度）。
  CloudDriveCleanupScheduler? cleanupScheduler;

  /// 最近一次转存任务 ID（对齐 iOS `quarkLastSaveTaskId`，用于转存后轮询落盘）。
  String? _lastSaveTaskId;

  // ─────────────── 转存 fid 缓存（契约键 `quark_saved_fid_cache_v1`）───────────────

  Map<String, Object?>? _cacheMemory;
  bool _cacheLoaded = false;

  /// Cookie 摘要（对齐 iOS `String(cookie.hash)`：仅作缓存键区分，不含明文）。
  static String cookieHash(String cookie) =>
      crypto.sha256.convert(utf8.encode(cookie)).toString().substring(0, 16);

  /// 缓存键 `pwdId|sourceFid|folderId|cookieHash`（对齐 iOS `quarkSavedFidCacheKey`）。
  static String cacheKeyFor({
    required String pwdId,
    required String sourceFid,
    required String folderId,
    required String cookie,
  }) =>
      '$pwdId|$sourceFid|$folderId|${cookieHash(cookie)}';

  Future<Map<String, Object?>> _loadCache() async {
    if (_cacheLoaded && _cacheMemory != null) return _cacheMemory!;
    _cacheLoaded = true;
    Map<String, Object?> cache = <String, Object?>{};
    try {
      final PrefsManager p = _prefs ?? PrefsManager.instance;
      final String raw = await p.getString(savedFidCacheKey);
      if (raw.isNotEmpty) {
        final Object? decoded = jsonDecode(raw);
        if (decoded is Map) cache = decoded.cast<String, Object?>();
      }
    } catch (_) {
      // 存储不可用 → 退化为内存缓存。
    }
    _cacheMemory = cache;
    return cache;
  }

  Future<void> _saveCache(Map<String, Object?> cache) async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final List<MapEntry<String, Object?>> alive = cache.entries
        .where((MapEntry<String, Object?> e) {
          final Map<String, Object?>? v =
              e.value is Map ? (e.value as Map).cast<String, Object?>() : null;
          final int exp = (v?['expiresAt'] as num?)?.toInt() ?? 0;
          return exp > now;
        })
        .toList()
      ..sort((MapEntry<String, Object?> a, MapEntry<String, Object?> b) {
        final int ta = ((a.value as Map)['createdAt'] as num?)?.toInt() ?? 0;
        final int tb = ((b.value as Map)['createdAt'] as num?)?.toInt() ?? 0;
        return tb.compareTo(ta);
      });
    final Map<String, Object?> capped = <String, Object?>{
      for (final MapEntry<String, Object?> e in alive.take(savedFidCacheMax))
        e.key: e.value,
    };
    _cacheMemory = capped;
    try {
      final PrefsManager p = _prefs ?? PrefsManager.instance;
      await p.set(savedFidCacheKey, jsonEncode(capped));
    } catch (_) {
      // 落盘失败不阻断播放（下次重存）。
    }
  }

  /// 命中未过期的转存 fid（对齐 iOS `quarkCachedSavedTopFids`）。
  Future<List<String>?> cachedSavedFids(String key) async {
    final Map<String, Object?> cache = await _loadCache();
    final Object? raw = cache[key];
    if (raw is! Map) return null;
    final Map<String, Object?> v = raw.cast<String, Object?>();
    final int exp = (v['expiresAt'] as num?)?.toInt() ?? 0;
    if (exp <= DateTime.now().millisecondsSinceEpoch) return null;
    final Object? top = v['topLevelFids'];
    if (top is! List) return null;
    final List<String> ids =
        top.map((Object? e) => '$e').toList(growable: false);
    return ids.isEmpty ? null : ids;
  }

  /// 存入转存 fid（对齐 iOS `quarkStoreSavedItem`：空 / 全 `"0"` 不入缓存）。
  Future<void> storeSavedFids(
    String key,
    List<String> topLevelFids, {
    Duration? ttl,
  }) async {
    if (topLevelFids.isEmpty ||
        topLevelFids.every((String id) => id == '0')) {
      return;
    }
    final Map<String, Object?> cache =
        Map<String, Object?>.of(await _loadCache());
    final int now = DateTime.now().millisecondsSinceEpoch;
    cache[key] = <String, Object?>{
      'topLevelFids': topLevelFids,
      'createdAt': now,
      'expiresAt': now + (ttl ?? savedFidTtl).inMilliseconds,
    };
    await _saveCache(cache);
  }

  /// 清理历史转存对象（对齐 iOS `quarkCleanupPreviousSavedItems`）。
  ///
  /// 新转存完成后，删除缓存中**除 [excludingKey]** 外的全部历史转存 fid 并移除
  /// 对应缓存键（避免历史转存文件长期占用网盘空间）。返回提交删除的文件数。
  Future<int> cleanupPreviousSavedItems({
    required String excludingKey,
    required String cookie,
  }) async {
    final Map<String, Object?> cache = await _loadCache();
    final List<String> keysToRemove = <String>[];
    final List<String> fidsToDelete = <String>[];
    for (final MapEntry<String, Object?> entry in cache.entries) {
      if (entry.key == excludingKey) continue;
      keysToRemove.add(entry.key);
      final Object? v = entry.value;
      if (v is Map) {
        final Object? top = v['topLevelFids'];
        if (top is List) {
          fidsToDelete.addAll(top.map((Object? e) => '$e'));
        }
      }
    }
    final List<String> uniqueFids = fidsToDelete
        .where((String id) => id.isNotEmpty && id != '0')
        .toSet()
        .toList(growable: false);
    if (uniqueFids.isEmpty) return 0;

    final int deleted = await deleteFiles(fileIds: uniqueFids, cookie: cookie);
    for (final String key in keysToRemove) {
      cache.remove(key);
    }
    await _saveCache(cache);
    return deleted;
  }

  // ─────────────── 分享信息 ───────────────

  /// 解析分享链接 → `(pwdId, passcode)`（对齐 iOS `quarkExtractShareInfo`）。
  static ({String pwdId, String passcode}) extractShareInfo(String shareUrl) {
    final Uri? uri = Uri.tryParse(shareUrl);
    if (uri != null) {
      final List<String> comps =
          uri.path.split('/').where((String s) => s.isNotEmpty).toList();
      String pwdId = '';
      final int sIndex = comps.indexOf('s');
      if (sIndex >= 0 && comps.length > sIndex + 1) {
        pwdId = comps[sIndex + 1];
      } else if (comps.isNotEmpty) {
        pwdId = comps.last;
      }
      String passcode = '';
      for (final String key in <String>['pwd', 'passcode', 'password']) {
        final String? v = uri.queryParameters[key];
        if (v != null && v.isNotEmpty) {
          passcode = v;
          break;
        }
      }
      return (pwdId: pwdId, passcode: passcode);
    }
    // 退化路径（非标准 URL）：`.*/s/` 截取 + `pwd=` 提取。
    String cleaned = shareUrl.replaceAll(RegExp(r'.*/s/'), '');
    cleaned = cleaned.split('?').first;
    final RegExpMatch? m =
        RegExp(r'(pwd|passcode|password)=([^&]+)').firstMatch(shareUrl);
    return (pwdId: cleaned.trim(), passcode: m?.group(2) ?? '');
  }

  /// 分享 Referer（对齐 iOS `quarkShareReferer`）。
  static String shareReferer(String pwdId) =>
      pwdId.isEmpty ? defaultReferer : 'https://pan.quark.cn/s/$pwdId';

  /// 是否为可播放文件（对齐 iOS `quarkIsPlayableFileName`）。
  static bool isPlayableFileName(String name) {
    final String lower = name.toLowerCase();
    return playableExts.any((String e) => lower.endsWith('.$e'));
  }

  /// 统一 API URL（对齐 iOS `quarkAPIURL`）。
  static Uri apiUrl(String path, {List<(String, String)> extra = const []}) {
    return Uri.parse('$apiHost$path').replace(queryParameters: <String, String>{
      'pr': 'ucpro',
      'fr': 'pc',
      'uc_param_str': '',
      for (final (String, String) e in extra) e.$1: e.$2,
    });
  }

  /// stoken 严格查询编码（对齐 iOS `quarkStrictQueryEncode`：
  /// 仅 `A-Za-z0-9-._~` 不编码，`+` → `%2B`）。
  static String strictQueryEncode(String value) {
    const String unreserved =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final StringBuffer out = StringBuffer();
    for (final int rune in value.runes) {
      final String ch = String.fromCharCode(rune);
      out.write(unreserved.contains(ch) ? ch : Uri.encodeComponent(ch));
    }
    return out.toString();
  }

  Map<String, String> _commonHeaders(String cookie, {String? referer}) =>
      <String, String>{
        'Content-Type': 'application/json',
        if (cookie.isNotEmpty) 'Cookie': cookie,
        'Origin': 'https://pan.quark.cn',
        'Referer': referer ?? defaultReferer,
        'User-Agent': desktopUA,
        'X-Client': 'QingmanLslandApp/1.0',
      };

  static int _nowMs() => DateTime.now().millisecondsSinceEpoch;

  // ─────────────── 设备指纹 / 播放请求头 ───────────────

  String? _deviceIdCache;

  /// 稳定设备 ID（对齐 iOS `quarkDeviceID`：取 `quark_device_id`，无则生成
  /// 32 位 hex 并持久化）。
  Future<String> deviceId() async {
    if (_deviceIdCache != null && _deviceIdCache!.isNotEmpty) {
      return _deviceIdCache!;
    }
    try {
      final PrefsManager p = _prefs ?? PrefsManager.instance;
      final String cached = await p.getString(deviceIdKey);
      if (cached.isNotEmpty) {
        _deviceIdCache = cached;
        return cached;
      }
      final String generated = List<String>.generate(
        32,
        (_) => math.Random.secure().nextInt(16).toRadixString(16),
      ).join();
      _deviceIdCache = generated;
      await p.set(deviceIdKey, generated);
      return generated;
    } catch (_) {
      // 存储不可用 → 退化为会话内随机指纹。
      return _deviceIdCache ??= List<String>.generate(
        32,
        (_) => math.Random.secure().nextInt(16).toRadixString(16),
      ).join();
    }
  }

  /// 夸克播放请求头（对齐 iOS `quarkPlaybackHeaders`：桌面 UA + X-Device-Id）。
  ///
  /// 走 Go 代理时鉴权头由代理注入，此处仅作降级直链使用。
  Future<Map<String, String>> playbackHeaders(String cookie) async {
    final String device = await deviceId();
    return <String, String>{
      if (cookie.isNotEmpty) 'Cookie': cookie,
      'User-Agent': desktopUA,
      'Referer': defaultReferer,
      'Origin': 'https://pan.quark.cn',
      'Accept': '*/*',
      'Accept-Encoding': 'br, gzip, deflate',
      'X-Device-Id': device,
      'X-Client': 'QingmanLslandApp/1.0',
    };
  }

  // ─────────────── 分享 token ───────────────

  /// 获取分享 `stoken`（对齐 iOS `quarkGetShareToken`）。
  Future<String> getShareToken({
    required String pwdId,
    required String passcode,
    required String cookie,
  }) async {
    final Uri url = apiUrl(
      '/1/clouddrive/share/sharepage/token',
      extra: <(String, String)>[('__t', '${_nowMs()}')],
    );
    final SpiderHttpResult res = await _bridge.request(
      url.toString(),
      options: SpiderHttpOptions(
        method: 'POST',
        headers: _commonHeaders(cookie, referer: shareReferer(pwdId)),
        data: jsonEncode(<String, Object?>{
          'pwd_id': pwdId,
          'passcode': passcode,
        }),
      ),
    );
    final Map<String, Object?>? json = _decodeMap(res.content);
    if (!res.ok || json == null) {
      throw const QuarkNativeException('夸克分享 token 获取失败：网络或响应异常');
    }
    final int code = _asInt(json['code']) ?? 0;
    if (code != 0) {
      throw QuarkNativeException(
        '夸克分享 token 获取失败：${json['message'] ?? 'code=$code'}',
      );
    }
    final Map<String, Object?>? data = _asMap(json['data']);
    final String st = _asString(data?['stoken']) ?? '';
    if (st.isEmpty) {
      throw const QuarkNativeException('夸克未返回 stoken');
    }
    return st;
  }

  // ─────────────── 文件列表 ───────────────

  /// 单页分享文件列表（对齐 iOS `quarkGetShareDetail`）。
  Future<List<QuarkShareFile>> getShareDetail({
    required String pwdId,
    required String stoken,
    required String pdirFid,
    required String cookie,
    int page = 1,
  }) async {
    final Uri url = apiUrl(
      '/1/clouddrive/share/sharepage/detail',
      extra: <(String, String)>[
        ('__t', '${_nowMs()}'),
        ('_fetch_banner', '1'),
        ('_fetch_total', '1'),
        ('_page', '$page'),
        ('_size', '100'),
        ('_sort', 'file_type:asc,file_name:asc'),
        ('force', '0'),
        ('pdir_fid', pdirFid),
        ('pwd_id', pwdId),
      ],
    );
    // stoken 严格编码（对齐 iOS：`+` 需编码为 %2B，否则服务端解析失败）。
    final String withStoken =
        '${url.toString()}&stoken=${strictQueryEncode(stoken)}';
    final SpiderHttpResult res = await _bridge.request(
      withStoken,
      options: SpiderHttpOptions(
        headers: _commonHeaders(cookie, referer: shareReferer(pwdId)),
      ),
    );
    final Map<String, Object?>? json = _decodeMap(res.content);
    if (json == null) {
      throw const QuarkNativeException('夸克文件列表响应异常');
    }
    final int code = _asInt(json['code']) ?? 0;
    if (code != 0) {
      throw QuarkNativeException('夸克文件列表失败：${json['message'] ?? 'code=$code'}');
    }
    final Map<String, Object?>? data = _asMap(json['data']);
    final Object? list = data?['list'];
    if (list is! List) return const <QuarkShareFile>[];
    return list
        .whereType<Map<Object?, Object?>>()
        .map((Map<Object?, Object?> raw) {
          final Map<String, Object?> item = raw.cast<String, Object?>();
          final String fid = _asString(item['fid']) ?? '';
          final String name =
              _asString(item['file_name']) ?? _asString(item['name']) ?? '';
          final String token = _asString(item['share_fid_token']) ??
              _asString(item['fid_token']) ??
              '';
          final bool? dirFlag = item['dir'] as bool?;
          final bool? fileFlag = item['file'] as bool?;
          final int? fileType = _asInt(item['file_type']);
          final bool isDir = dirFlag ??
              (fileFlag == false && fileType == 0);
          return QuarkShareFile(
            fid: fid,
            fileName: name,
            shareFidToken: token,
            pdirFid: pdirFid,
            isDir: isDir,
          );
        })
        .where((QuarkShareFile f) => f.fid.isNotEmpty && f.fileName.isNotEmpty)
        .toList(growable: false);
  }

  /// 递归收集全部可播放文件（对齐 iOS `quarkCollectAllPlayableFiles`）。
  Future<List<QuarkShareFile>> collectAllPlayableFiles({
    required String pwdId,
    required String stoken,
    required String cookie,
    String pdirFid = '0',
    int maxPages = 20,
  }) async {
    final List<QuarkShareFile> out = <QuarkShareFile>[];
    await _collect(
      pwdId: pwdId,
      stoken: stoken,
      pdirFid: pdirFid,
      cookie: cookie,
      out: out,
      maxPages: maxPages,
    );
    return out;
  }

  Future<void> _collect({
    required String pwdId,
    required String stoken,
    required String pdirFid,
    required String cookie,
    required List<QuarkShareFile> out,
    required int maxPages,
  }) async {
    int page = 1;
    bool hasMore = true;
    while (hasMore) {
      final List<QuarkShareFile> files = await getShareDetail(
        pwdId: pwdId,
        stoken: stoken,
        pdirFid: pdirFid,
        cookie: cookie,
        page: page,
      );
      for (final QuarkShareFile f in files) {
        if (!f.isDir && isPlayableFileName(f.fileName)) out.add(f);
      }
      for (final QuarkShareFile dir in files.where((QuarkShareFile f) => f.isDir)) {
        await _collect(
          pwdId: pwdId,
          stoken: stoken,
          pdirFid: dir.fid,
          cookie: cookie,
          out: out,
          maxPages: maxPages,
        );
      }
      hasMore = files.length >= 100;
      page += 1;
      if (page > maxPages) break;
    }
  }

  /// 分享链接 → 全部可播放文件（对齐 iOS `quarkGetFileList`）。
  Future<List<QuarkShareFile>> getFileList({
    required String shareUrl,
    required String cookie,
  }) async {
    final ({String pwdId, String passcode}) info = extractShareInfo(shareUrl);
    if (info.pwdId.isEmpty) {
      throw const QuarkNativeException('无法识别的分享链接');
    }
    final String stoken = await getShareToken(
      pwdId: info.pwdId,
      passcode: info.passcode,
      cookie: cookie,
    );
    return collectAllPlayableFiles(
      pwdId: info.pwdId,
      stoken: stoken,
      cookie: cookie,
    );
  }

  // ─────────────── 转存 + 轮询 ───────────────

  /// 转存分享文件到根目录，返回顶层 fid 列表（对齐 iOS `quarkSaveShare`）。
  Future<List<String>> saveShare({
    required String pwdId,
    required String stoken,
    required QuarkShareFile file,
    required String cookie,
    String folderId = '0',
  }) async {
    final Uri url = apiUrl(
      '/1/clouddrive/share/sharepage/save',
      extra: <(String, String)>[('__t', '${_nowMs()}')],
    );
    final SpiderHttpResult res = await _bridge.request(
      url.toString(),
      options: SpiderHttpOptions(
        method: 'POST',
        headers: _commonHeaders(cookie, referer: shareReferer(pwdId)),
        data: jsonEncode(<String, Object?>{
          'fid_list': <String>[file.fid],
          'fid_token_list': <String>[file.shareFidToken],
          'to_pdir_fid': folderId,
          'pwd_id': pwdId,
          'stoken': stoken,
          'pdir_fid': file.pdirFid,
          'scene': 'link',
          'platform_original': 'chrome',
          'nu_distribute': 0,
        }),
      ),
    );
    final Map<String, Object?>? json = _decodeMap(res.content);
    if (json == null) {
      throw const QuarkNativeException('夸克转存失败：响应异常');
    }
    final int status = _asInt(json['status']) ?? 0;
    final int code = _asInt(json['code']) ?? 0;
    if (status != 200 && status != 0) {
      throw QuarkNativeException(
        '夸克转存失败：${json['message'] ?? json['msg'] ?? 'status=$status'}',
      );
    }
    if (code != 0) {
      throw QuarkNativeException(
        '夸克转存失败：${json['message'] ?? json['msg'] ?? 'code=$code'}',
      );
    }
    final Map<String, Object?>? data = _asMap(json['data']);
    _lastSaveTaskId = _asString(data?['task_id']);

    // 取 fid 顺序严格对齐 iOS `quarkSaveShare`：显式字段（占位目录 ID 时继续）
    // → 递归提取 → 按文件名查找 → 全部落空才算转存失败。
    List<String> ids = _extractSavedFids(data, folderId: folderId);
    if (ids.isEmpty) {
      ids = _extractSavedFidsRecursively(json, excluding: file.fid);
    }
    if (ids.isEmpty) {
      final String? existing = await _findSavedFileIdByFileName(
        fileName: file.fileName,
        folderId: folderId,
        cookie: cookie,
      );
      if (existing != null) ids = <String>[existing];
    }
    if (ids.isEmpty) {
      throw const QuarkNativeException('夸克转存成功但未返回已转存 fid');
    }
    return ids;
  }

  /// 从转存响应显式字段取 fid（对齐 iOS `quarkSaveShare` 的前四层候选）。
  ///
  /// `save_as_top_fids` / `save_as_select_top_fids` 若全为占位目录 ID（`"0"` /
  /// `folderId`），不返回并继续下一个候选；`file_ids` / `list` 直接返回。
  List<String> _extractSavedFids(
    Map<String, Object?>? data, {
    required String folderId,
  }) {
    if (data == null) return const <String>[];
    final Map<String, Object?>? taskResp = _asMap(data['task_resp']);
    final Map<String, Object?>? taskData = _asMap(taskResp?['data']);
    final Map<String, Object?>? saveAs = _asMap(taskData?['save_as']);
    for (final String key in <String>[
      'save_as_top_fids',
      'save_as_select_top_fids',
    ]) {
      final Object? raw = saveAs?[key];
      if (raw is List && raw.isNotEmpty) {
        final List<String> ids =
            raw.map((Object? e) => '$e').toList(growable: false);
        if (!ids.every((String id) => id == '0' || id == folderId)) {
          return ids;
        }
      }
    }
    final Object? fileIds = data['file_ids'];
    if (fileIds is List && fileIds.isNotEmpty) {
      return fileIds.map((Object? e) => '$e').toList(growable: false);
    }
    final Object? list = data['list'];
    if (list is List && list.isNotEmpty) {
      final List<String> ids = list
          .whereType<Map<Object?, Object?>>()
          .map((Map<Object?, Object?> m) =>
              _asString(m['fid']) ?? _asString(m['file_id']) ?? '')
          .where((String s) => s.isNotEmpty)
          .toList(growable: false);
      if (ids.isNotEmpty) return ids;
    }
    return const <String>[];
  }

  /// 递归提取响应中任意含 `fid`/`file_id` 的字段（对齐 iOS
  /// `quarkExtractSavedFileIds`：排除 `token` 键与源分享 fid）。
  List<String> _extractSavedFidsRecursively(
    Object? value, {
    required String excluding,
  }) {
    final List<String> out = <String>[];

    void append(Object? raw, String key) {
      final String lowerKey = key.toLowerCase();
      if (!lowerKey.contains('fid') && !lowerKey.contains('file_id')) return;
      if (lowerKey.contains('token')) return;
      if (raw is String) {
        if (raw.isNotEmpty && raw != excluding) out.add(raw);
      } else if (raw is int) {
        final String text = '$raw';
        if (text != excluding) out.add(text);
      } else if (raw is List) {
        for (final Object? e in raw) {
          if (e is String && e.isNotEmpty && e != excluding) {
            out.add(e);
          } else if (e is int && '$e' != excluding) {
            out.add('$e');
          }
        }
      }
    }

    void walk(Object? node) {
      if (node is Map) {
        node.forEach((Object? key, Object? item) {
          if (key is String) append(item, key);
          walk(item);
        });
      } else if (node is List) {
        for (final Object? e in node) {
          walk(e);
        }
      }
    }

    walk(value);
    final Set<String> seen = <String>{};
    return out.where(seen.add).toList(growable: false);
  }

  /// 按文件名在转存目录查找 fid（对齐 iOS `quarkFindSavedFileId`：
  /// `POST file/sort`，3 次尝试，间隔 800ms）。
  Future<String?> _findSavedFileIdByFileName({
    required String fileName,
    required String folderId,
    required String cookie,
  }) async {
    for (int attempt = 0; attempt < 3; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(const Duration(milliseconds: 800));
      }
      final SpiderHttpResult res = await _bridge.request(
        apiUrl('/1/clouddrive/file/sort').toString(),
        options: SpiderHttpOptions(
          method: 'POST',
          headers: _commonHeaders(cookie),
          data: jsonEncode(<String, Object?>{
            'pdir_fid': folderId,
            'sort_by': 'file_name',
            'sort_order': 'asc',
            'page': 1,
            'size': 100,
          }),
        ),
      );
      final Map<String, Object?>? json = _decodeMap(res.content);
      final Object? list = _asMap(json?['data'])?['list'];
      if (list is! List) continue;
      for (final Object? raw in list) {
        final Map<String, Object?>? item = _asMap(raw);
        final String name =
            _asString(item?['file_name']) ?? _asString(item?['name']) ?? '';
        if (name != fileName) continue;
        final String? fid = _asString(item?['fid']) ??
            _asString(item?['file_id']) ??
            (_asInt(item?['fid']) != null ? '${item?['fid']}' : null);
        if (fid != null && fid.isNotEmpty) return fid;
      }
    }
    return null;
  }

  /// 提取转存任务 ID（对齐 iOS `quarkLastSaveTaskId`；无则返回 null）。
  String? extractSaveTaskId(String responseBody) {
    final Map<String, Object?>? json = _decodeMap(responseBody);
    return _asString(_asMap(json?['data'])?['task_id']);
  }

  /// 轮询转存任务直到落盘（对齐 iOS `quarkPollTask`）。
  Future<void> pollTask({
    required String taskId,
    required String cookie,
    int maxRetries = 10,
    Duration interval = const Duration(seconds: 1),
  }) async {
    for (int i = 0; i < maxRetries; i++) {
      final Uri url = apiUrl(
        '/1/clouddrive/task',
        extra: <(String, String)>[
          ('__t', '${_nowMs()}'),
          ('task_id', taskId),
          ('retry_index', '0'),
        ],
      );
      final SpiderHttpResult res = await _bridge.request(
        url.toString(),
        options: SpiderHttpOptions(headers: _commonHeaders(cookie)),
      );
      final Map<String, Object?>? json = _decodeMap(res.content);
      final Map<String, Object?>? data = _asMap(json?['data']);
      if (data != null) {
        final int status = _asInt(data['status']) ?? -1;
        final bool finish = data['finish'] as bool? ?? false;
        if (finish || status == 2) return;
        if (status == 3 || status == -1) return; // 异常：继续尝试播放
      }
      if (i < maxRetries - 1) await Future<void>.delayed(interval);
    }
  }

  // ─────────────── 取链 ───────────────

  /// 取播放地址（对齐 iOS `quarkRefreshVideoAuth`：`POST /file/v2/play`）。
  Future<String> getPlayUrl({
    required String fileId,
    required String cookie,
  }) async {
    final Uri url = apiUrl('/1/clouddrive/file/v2/play');
    final SpiderHttpResult res = await _bridge.request(
      url.toString(),
      options: SpiderHttpOptions(
        method: 'POST',
        headers: _commonHeaders(cookie),
        data: jsonEncode(<String, Object?>{
          'fid': fileId,
          'resolutions': 'normal,low,high,super,2k,4k',
          'supports': 'fmp4,m3u8',
        }),
      ),
    );
    final Map<String, Object?>? json = _decodeMap(res.content);
    if (json == null) {
      throw const QuarkNativeException('夸克取链响应异常');
    }
    final int code = _asInt(json['code']) ?? 0;
    if (code != 0) {
      throw QuarkNativeException('夸克 v2/play 失败：${json['message'] ?? 'code=$code'}');
    }
    final Map<String, Object?>? data = _asMap(json['data']);
    final Object? videos = data?['video_list'];
    if (videos is List) {
      // 按质量顺序 low→4k 选第一个可用流。
      for (final String quality in qualityOrder) {
        for (final Object? item in videos) {
          final Map<String, Object?>? m = _asMap(item);
          if (m == null) continue;
          final Map<String, Object?>? info = _asMap(m['video_info']);
          final String? res0 = _asString(info?['resolution']);
          final bool accessable = m['accessable'] as bool? ?? true;
          final String? u = _asString(info?['url']);
          if (res0 == quality && accessable && (u ?? '').isNotEmpty) return u!;
        }
      }
      for (final Object? item in videos) {
        final Map<String, Object?>? m = _asMap(item);
        if (m == null) continue;
        final bool accessable = m['accessable'] as bool? ?? true;
        final String? u = _asString(_asMap(m['video_info'])?['url']);
        if (accessable && (u ?? '').isNotEmpty) return u!;
      }
    }
    final String? playUrl = _asString(json['play_url']);
    if (playUrl != null && playUrl.isNotEmpty) return playUrl;
    throw const QuarkNativeException('夸克未返回可用播放地址');
  }

  /// 获取加速下载 token（对齐 iOS `quarkAcquireDLToken`）。
  ///
  /// 注意：该接口主机为 [socialHost]（`drive-social-api.quark.cn`），非 `drive-pc`。
  Future<String> acquireDlToken({required String cookie}) async {
    final Uri url = Uri.parse(
      '$socialHost/1/clouddrive/chat/conv/file/acquire_dl_token',
    ).replace(queryParameters: <String, String>{
      'pr': 'ucpro',
      'fr': 'pc',
      'sys': 'darwin',
      've': '3.19.0',
    });
    final int ts = _nowMs();
    final SpiderHttpResult res = await _bridge.request(
      url.toString(),
      options: SpiderHttpOptions(
        method: 'POST',
        headers: _commonHeaders(cookie),
        data: jsonEncode(<String, Object?>{
          'conversation_id': '300000$ts',
          'conversation_type': 3,
          'msg_id': '${ts}000',
        }),
      ),
    );
    final Map<String, Object?>? json = _decodeMap(res.content);
    if (json == null) {
      throw const QuarkNativeException('夸克 acquire_dl_token 响应异常');
    }
    final int code = _asInt(json['code']) ?? 0;
    if (code != 0) {
      throw QuarkNativeException(
        '夸克 acquire_dl_token 失败：${json['message'] ?? 'code=$code'}',
      );
    }
    final String token = _asString(_asMap(json['data'])?['token']) ?? '';
    if (token.isEmpty) {
      throw const QuarkNativeException('夸克 acquire_dl_token 未返回 token');
    }
    return token;
  }

  /// 取原画直链（对齐 iOS `quarkGetDownloadURL`：`POST /file/download`）。
  ///
  /// 先取加速 token（失败降级普通下载），返回 `(url, fileName)`；`url` 为空表示
  /// 该资源无原画直链（调用方降级转码 m3u8）。
  Future<({String url, String fileName})> getDownloadUrl({
    required String fileId,
    required String cookie,
  }) async {
    String dlToken = '';
    try {
      dlToken = await acquireDlToken(cookie: cookie);
    } catch (_) {
      // 加速 token 失败不阻断：降级为普通下载。
    }
    final SpiderHttpResult res = await _bridge.request(
      apiUrl('/1/clouddrive/file/download').toString(),
      options: SpiderHttpOptions(
        method: 'POST',
        headers: _commonHeaders(cookie),
        data: jsonEncode(<String, Object?>{
          'fids': <String>[fileId],
          'speedup_session': '',
          if (dlToken.isNotEmpty) 'token': dlToken,
        }),
      ),
    );
    final Map<String, Object?>? json = _decodeMap(res.content);
    if (json == null) {
      throw const QuarkNativeException('夸克 download_url 响应异常');
    }
    final int code = _asInt(json['code']) ?? 0;
    if (code != 0) {
      throw QuarkNativeException(
        '夸克 download_url 获取失败：${json['message'] ?? 'code=$code'}',
      );
    }
    // 对齐 iOS：`data` 为数组，取首项的 download_url / file_name。
    final Object? data = json['data'];
    if (data is List && data.isNotEmpty) {
      final Map<String, Object?>? first = _asMap(data.first);
      final String url = _asString(first?['download_url']) ?? '';
      final String name = _asString(first?['file_name']) ?? '';
      return (url: url, fileName: name);
    }
    final Map<String, Object?>? map = _asMap(data);
    final List<Object?>? list = map?['list'] as List<Object?>?;
    if (list != null && list.isNotEmpty) {
      final Map<String, Object?>? first = _asMap(list.first);
      return (
        url: _asString(first?['download_url']) ?? '',
        fileName: _asString(first?['file_name']) ?? '',
      );
    }
    throw const QuarkNativeException('夸克未返回 download_url 数据');
  }

  /// 读取会员类型（对齐 iOS `quarkGetMemberInfo`；仅用于日志 / 清晰度判断）。
  ///
  /// 失败返回 null（不阻断取链）。
  Future<String?> getMemberInfo({required String cookie}) async {
    final SpiderHttpResult res = await _bridge.request(
      apiUrl(
        '/1/clouddrive/member',
        extra: <(String, String)>[
          ('fetch_subscribe', 'true'),
          ('fetch_identity', 'true'),
          ('_ch', 'home'),
          ('ve', '3.19.0'),
        ],
      ).toString(),
      options: SpiderHttpOptions(headers: _commonHeaders(cookie)),
    );
    final Map<String, Object?>? json = _decodeMap(res.content);
    final Map<String, Object?>? d = _asMap(json?['data']);
    if (d == null) return null;
    return _asString(d['member_type']) ??
        _asString(_asMap(d['member_type'])?['type']);
  }

  /// 递归查找文件夹内首个视频 fid（对齐 iOS `quarkFindFirstVideoInFolder`）。
  ///
  /// v2/play 返回 `not video`（fid 实为文件夹）时用于定位真实视频文件；
  /// BFS 最多 3 层。
  Future<String?> findFirstVideoInFolder({
    required String folderId,
    required String cookie,
  }) async {
    const List<String> videoExts = <String>[
      '.mp4', '.mkv', '.avi', '.ts', '.mov', '.flv', '.wmv', '.m4v', '.3gp',
      '.webm', '.rmvb', '.rm', '.mpg', '.mpeg',
    ];
    final List<String> queue = <String>[folderId];
    final Set<String> visited = <String>{};
    int depth = 0;
    while (queue.isNotEmpty && depth < 3) {
      final int levelCount = queue.length;
      for (int i = 0; i < levelCount; i++) {
        final String fid = queue.removeAt(0);
        if (!visited.add(fid)) continue;
        final List<Map<String, Object?>> list = await _fileSortList(
          cookie: cookie,
          query: <(String, String)>[
            ('pdir_fid', fid),
            ('_sort', 'file_type:asc,updated_at:desc'),
            ('_page', '1'),
            ('_size', '200'),
            ('_fetch_total', '1'),
          ],
        );
        for (final Map<String, Object?> item in list) {
          final bool isDir = (_asInt(item['file_type']) == 0) ||
              (item['is_dir'] == true);
          final String name =
              (_asString(item['file_name']) ?? _asString(item['name']) ?? '')
                  .toLowerCase();
          final String itemFid = _asString(item['fid']) ??
              _asString(item['file_id']) ??
              (_asInt(item['fid']) != null ? '${item['fid']}' : '');
          if (itemFid.isEmpty) continue;
          if (isDir) {
            queue.add(itemFid);
          } else if (videoExts.any((String e) => name.endsWith(e))) {
            return itemFid;
          }
        }
      }
      depth += 1;
    }
    return null;
  }

  /// 失效转存 fid 缓存（对齐 iOS `quarkInvalidateSavedFidCache`）。
  Future<void> invalidateSavedFids(String key) async {
    final Map<String, Object?> cache =
        Map<String, Object?>.of(await _loadCache());
    if (cache.remove(key) != null) await _saveCache(cache);
  }

  /// 分享链接 → 取链（对齐 iOS `resolveQuarkPlayURL` 主链：主=原画/兜底=m3u8）。
  ///
  /// 流程：清理空间 → 分享 token → 可播放文件 → 转存（含缓存）→ v2/play 转码
  /// （失败按 `not video` 递归定位真实视频文件重试）→ download_url 原画 →
  /// 按 [routePreference] 选定主线路并派生兜底线路。
  ///
  /// [routePreference]：`'original'`（缺省，原画直链为主）/ `'transcode'`
  /// （转码 m3u8 为主），对齐 iOS `routePreference` 语义。
  Future<QuarkPlayResult> resolvePlayUrl({
    required String shareUrl,
    required String cookie,
    String? preferredFid,
    String? routePreference,
  }) async {
    final ({String pwdId, String passcode}) info = extractShareInfo(shareUrl);
    if (info.pwdId.isEmpty) {
      throw const QuarkNativeException('无法识别的分享链接');
    }
    // 播放前检测夸克空间，快满时清理「来自：分享」目录（对齐 iOS L2309）。
    try {
      await cleanShareOriginIfNeeded(cookie: cookie, thresholdGb: 2.0);
    } catch (_) {
      // 清理失败不阻断播放（容量管理为尽力而为）。
    }
    final String stoken = await getShareToken(
      pwdId: info.pwdId,
      passcode: info.passcode,
      cookie: cookie,
    );
    final List<QuarkShareFile> files = await collectAllPlayableFiles(
      pwdId: info.pwdId,
      stoken: stoken,
      cookie: cookie,
    );
    if (files.isEmpty) {
      throw const QuarkNativeException('夸克分享内未找到可播放视频');
    }
    final QuarkShareFile source = (preferredFid != null && preferredFid.isNotEmpty)
        ? files.firstWhere(
            (QuarkShareFile f) => f.fid == preferredFid,
            orElse: () => files.first,
          )
        : files.first;
    // 转存 fid 缓存命中则跳过本次转存（对齐 iOS `quarkCachedSavedTopFids`）。
    final String cacheKey = cacheKeyFor(
      pwdId: info.pwdId,
      sourceFid: source.fid,
      folderId: '0',
      cookie: cookie,
    );
    List<String> saved = await cachedSavedFids(cacheKey) ?? const <String>[];
    bool fromCache = saved.isNotEmpty;
    if (!fromCache) {
      saved = await saveShare(
        pwdId: info.pwdId,
        stoken: stoken,
        file: source,
        cookie: cookie,
      );
      await storeSavedFids(cacheKey, saved);
      // 转存成功即安排 1 小时后清理，并清理历史转存对象（对齐 iOS L2350/L2353）。
      await cleanupScheduler?.schedule(
        drive: CloudDriveType.quark,
        fileIds: saved,
        delay: const Duration(hours: 1),
      );
      await cleanupPreviousSavedItems(excludingKey: cacheKey, cookie: cookie);
      // 新转存后轮询任务直到落盘（对齐 iOS `quarkPollTask`），避免「转存尚未
      // 落盘就 v2/play / download → file not found」竞态。
      if (_lastSaveTaskId != null) {
        await pollTask(taskId: _lastSaveTaskId!, cookie: cookie);
      }
    }
    if (saved.isEmpty) {
      throw const QuarkNativeException('夸克: 转存后未返回文件ID');
    }
    // 占位 fileId（"0" / 全"0"）→ 文件未真正落盘，疑似已被和谐/转码失败
    // （对齐 iOS `isPlaceholderFileId`）。
    if (saved.first == '0' || saved.every((String id) => id == '0')) {
      throw const QuarkNativeException(
        '该资源在夸克网盘中已失效（可能被和谐或转码失败），请尝试其他资源',
      );
    }
    String playbackFileId = saved.first;

    // 会员信息仅用于日志 / 清晰度判断（失败不阻断）。
    await getMemberInfo(cookie: cookie);

    // 主链路：先 v2/play 刷新 Video-Auth（返回转码 m3u8，作为兜底）。
    String transcode = '';
    try {
      transcode = await getPlayUrl(fileId: playbackFileId, cookie: cookie);
    } on QuarkNativeException catch (e) {
      // v2/play 返回 `not video` → fid 实为文件夹，递归定位真实视频文件重试。
      if (e.message.toLowerCase().contains('not video')) {
        final String? videoFid = await findFirstVideoInFolder(
          folderId: playbackFileId,
          cookie: cookie,
        );
        if (videoFid != null) {
          playbackFileId = videoFid;
          try {
            transcode = await getPlayUrl(fileId: videoFid, cookie: cookie);
          } on QuarkNativeException {
            // 重试仍失败 → 继续尝试 download_url。
          }
        }
      }
    }

    // 原画直链：失败时区分「缓存失效」（重转存）与「资源失效」（报错）。
    ({String url, String fileName}) download = (url: '', fileName: '');
    try {
      download = await getDownloadUrl(fileId: playbackFileId, cookie: cookie);
    } on QuarkNativeException catch (e) {
      final String msg = e.message.toLowerCase();
      if (msg.contains('not found') || msg.contains('不存在')) {
        if (fromCache) {
          // 缓存 fileId 已失效 → 清缓存重转存（对齐 iOS L2428-L2457）。
          await invalidateSavedFids(cacheKey);
          final List<String> newFids = await saveShare(
            pwdId: info.pwdId,
            stoken: stoken,
            file: source,
            cookie: cookie,
          );
          await storeSavedFids(cacheKey, newFids);
          await cleanupScheduler?.schedule(
            drive: CloudDriveType.quark,
            fileIds: newFids,
            delay: const Duration(hours: 1),
          );
          await cleanupPreviousSavedItems(excludingKey: cacheKey, cookie: cookie);
          fromCache = false;
          // 重转存后同样轮询落盘（对齐 iOS L2450-L2452）。
          if (_lastSaveTaskId != null) {
            await pollTask(taskId: _lastSaveTaskId!, cookie: cookie);
          }
          if (newFids.isEmpty || newFids.first == '0') {
            throw const QuarkNativeException(
              '该资源在夸克网盘中已失效（可能被和谐或转码失败），请尝试其他资源',
            );
          }
          playbackFileId = newFids.first;
          try {
            download =
                await getDownloadUrl(fileId: playbackFileId, cookie: cookie);
          } on QuarkNativeException {
            // 重转存后仍无原画 → 走下方拓扑（转码兜底）。
          }
        } else {
          throw const QuarkNativeException('该资源已被和谐或禁止播放，请尝试其他资源');
        }
      }
      // 其余错误不阻断：转码 m3u8 仍可用。
    }

    // 线路选择（对齐 iOS L2472-L2504）：缺省原画为主，转码 m3u8 为兜底。
    final bool preferOriginal = routePreference != 'transcode';
    final String url;
    final String lineSource;
    if (preferOriginal && download.url.isNotEmpty) {
      url = download.url;
      lineSource = 'download_url';
    } else if (transcode.isNotEmpty) {
      url = transcode;
      lineSource = 'v2-play-m3u8';
    } else if (download.url.isNotEmpty) {
      url = download.url;
      lineSource = 'download_url';
    } else {
      throw const QuarkNativeException('夸克: download_url 和转码地址均为空');
    }
    String? fallbackUrl;
    String fallbackSource = '';
    if (lineSource == 'download_url' && transcode.isNotEmpty) {
      fallbackUrl = transcode;
      fallbackSource = 'v2-play-m3u8';
    } else if (lineSource == 'v2-play-m3u8' && download.url.isNotEmpty) {
      fallbackUrl = download.url;
      fallbackSource = 'download_url';
    }

    // 兜底线路不提前注册 Go 代理（避免与主线路共享 stream id）；播放请求头由
    // 各线路在触发时注入（对齐 iOS L2529-L2539）。
    final Map<String, String> headers = await playbackHeaders(cookie);
    return QuarkPlayResult(
      url: url,
      fileName: download.fileName.isEmpty ? source.fileName : download.fileName,
      source: lineSource,
      headers: headers,
      fallbackUrl: fallbackUrl,
      fallbackHeaders: headers,
      fallbackSource: fallbackSource,
    );
  }

  /// 取链 + 重试（对齐 iOS `resolveQuarkPlayURLWithRetry`：最多重试
  /// [maxRetries] 次、指数退避 1s/2s/4s；确定性错误不再重试）。
  ///
  /// 确定性错误（资源已失效 / 被和谐 / 禁止播放 / 转存返回占位）直接抛出，
  /// 避免对同一不可用资源反复重试。
  Future<QuarkPlayResult> resolvePlayUrlWithRetry({
    required String shareUrl,
    required String cookie,
    String? preferredFid,
    String? routePreference,
    int maxRetries = 3,
  }) async {
    Object? lastError;
    for (int attempt = 0; attempt < maxRetries; attempt++) {
      try {
        return await resolvePlayUrl(
          shareUrl: shareUrl,
          cookie: cookie,
          preferredFid: preferredFid,
          routePreference: routePreference,
        );
      } catch (e) {
        lastError = e;
        final String msg = e.toString().toLowerCase();
        final bool nonRetryable = msg.contains('已失效') ||
            msg.contains('已被和谐') ||
            msg.contains('禁止播放') ||
            msg.contains('转存返回占位');
        if (nonRetryable) rethrow;
        if (attempt < maxRetries - 1) {
          await Future<void>.delayed(Duration(seconds: 1 << attempt));
        }
      }
    }
    if (lastError is QuarkNativeException) {
      throw lastError;
    }
    throw QuarkNativeException('夸克播放解析失败（已重试$maxRetries次）');
  }

  // ─────────────── 空间清理（NC-清1，对齐 iOS `quarkCleanShareOriginIfNeeded` /
  //                 `quarkDeleteFiles`）───────────────

  /// 根目录清理视频后缀白名单（对齐 iOS `quarkCleanShareOriginIfNeeded` 内联表）。
  static const List<String> cleanupVideoExts = <String>[
    '.mp4', '.mkv', '.avi', '.ts', '.mov', '.flv', '.wmv', '.m4v', '.3gp',
  ];

  /// 清理目标目录名变体（对齐 iOS 四种写法）。
  static const List<String> shareOriginFolderNames = <String>[
    '来自：分享', '来自:分享', '来自分享的文件', '来自分享',
  ];

  /// 读取容量信息（对齐 iOS `quarkGetQuotaInfo`：member → quota/info 双端点）。
  ///
  /// 返回 `(used, total)` 字节；全部失败时 `total == 0`（调用方按「容量未知」
  /// 走保守清理）。Set-Cookie 合并由 HTTP 桥 cookie jar 等价承载。
  Future<({int used, int total})> getQuotaInfo({required String cookie}) async {
    final ({int used, int total})? member =
        await _quotaFromMember(cookie: cookie);
    if (member != null && member.total > 0) return member;

    final Uri url = apiUrl(
      '/1/clouddrive/quota/info',
      extra: <(String, String)>[('ut', '${_nowMs()}')],
    );
    final SpiderHttpResult res = await _bridge.request(
      url.toString(),
      options: SpiderHttpOptions(
        method: 'POST',
        headers: _commonHeaders(cookie),
        // iBox 抓包显示 quota/info 需要 dlt_keys，否则 405/参数错误。
        data: jsonEncode(<String, Object?>{
          'dlt_keys': <String>['uc_nor_dlt'],
        }),
      ),
    );
    if (!res.ok) return (used: 0, total: 0);
    final Map<String, Object?>? json = _decodeMap(res.content);
    if (json == null) return (used: 0, total: 0);
    final Map<String, Object?>? data = _asMap(json['data']);
    final Map<String, Object?> cap = _asMap(data?['capinfo']) ??
        _asMap(data?['capacity']) ??
        _asMap(data?['account_capacity']) ??
        data ??
        json;
    final int used =
        _asInt(cap['used'] ?? cap['size_used'] ?? data?['used']) ?? 0;
    int total =
        _asInt(cap['total'] ?? cap['size_total'] ?? data?['total']) ?? 0;
    if (total <= 0) {
      final Map<String, Object?>? account = _asMap(data?['account']);
      total = _asInt(account?['total_capacity'] ??
              account?['capacity_total'] ??
              account?['total']) ??
          0;
    }
    return (used: used, total: total);
  }

  /// member 端点容量兜底（对齐 iOS `quarkGetQuotaFromMember`）。
  Future<({int used, int total})?> _quotaFromMember(
      {required String cookie}) async {
    final Uri url = apiUrl(
      '/1/clouddrive/member',
      extra: <(String, String)>[
        ('fetch_subscribe', 'true'),
        ('fetch_identity', 'true'),
        ('_ch', 'home'),
        ('ve', '3.19.0'),
      ],
    );
    final SpiderHttpResult res = await _bridge.request(
      url.toString(),
      options: SpiderHttpOptions(headers: _commonHeaders(cookie)),
    );
    final Map<String, Object?>? json = _decodeMap(res.content);
    final Map<String, Object?>? d = _asMap(json?['data']);
    if (d == null) return null;
    final Map<String, Object?>? cap = _asMap(d['capacity']) ??
        _asMap(d['capinfo']) ??
        _asMap(d['account_capacity']);
    int used = _asInt(cap?['used'] ?? cap?['size_used'] ?? d['used']) ?? 0;
    int total = _asInt(cap?['total'] ?? cap?['size_total'] ?? d['total']) ?? 0;
    final Map<String, Object?>? account = _asMap(d['account']);
    if (total <= 0) {
      total = _asInt(account?['total_capacity'] ??
              account?['capacity_total'] ??
              account?['total']) ??
          0;
    }
    if (used <= 0) {
      used = _asInt(account?['used_capacity'] ??
              account?['capacity_used'] ??
              account?['used']) ??
          0;
    }
    if (total > 0 && used <= 0) {
      used = total - (_asInt(d['remain']) ?? 0);
    }
    if (total <= 0) return null;
    return (used: used, total: total);
  }

  /// 容量阈值触发清理（对齐 iOS `quarkCleanShareOriginIfNeeded`）。
  ///
  /// 剩余空间低于 [thresholdGb] 时，删除「来自：分享」目录（含子文件夹）与
  /// 根目录视频；容量未知时按保守策略清理根目录最新 100 个视频。转存 fid
  /// 缓存中未过期的对象跳过，避免误删正在使用/待播放的转存文件。
  ///
  /// 返回清理条数。Set-Cookie 合并由 HTTP 桥 cookie jar 承载（差异登记）。
  Future<int> cleanShareOriginIfNeeded({
    required String cookie,
    double thresholdGb = 1.0,
  }) async {
    final ({int used, int total}) quota =
        await getQuotaInfo(cookie: cookie);
    final bool quotaAvailable = quota.total > 0;
    if (quotaAvailable) {
      final double freeGb =
          (quota.total - quota.used) / 1073741824.0;
      if (freeGb >= thresholdGb) return 0;
    }

    List<String> shareFids = const <String>[];
    for (final String name in shareOriginFolderNames) {
      final String? folderId = await _findFolderId(name, cookie);
      if (folderId != null) {
        // 分享目录内同时清理子文件夹和文件，避免文件夹形式转存残留。
        shareFids = await _collectFids(
          folderId: folderId,
          cookie: cookie,
          includeFolders: true,
        );
        break;
      }
    }
    // 容量未知时更激进：只清理根目录最新 100 个视频，避免空间爆掉。
    final List<String> rootFids = await _collectFids(
      folderId: '0',
      cookie: cookie,
      onlyVideo: true,
      limit: quotaAvailable ? null : 100,
    );

    final Set<String> all = <String>{...shareFids, ...rootFids};
    if (all.isEmpty) return 0;
    final Set<String> protected = await protectedCachedFids();
    final List<String> targets =
        all.where((String fid) => !protected.contains(fid)).toList();
    if (targets.isEmpty) return 0;
    return _deleteFidsBatched(targets, cookie: cookie);
  }

  /// 转存 fid 缓存内未过期的对象 fid（对齐 iOS `protectedCachedFileIds`）。
  Future<Set<String>> protectedCachedFids() async {
    final Map<String, Object?> cache = await _loadCache();
    final int now = _nowMs();
    final Set<String> fids = <String>{};
    for (final Object? raw in cache.values) {
      final Map<String, Object?>? v = _asMap(raw);
      if (v == null) continue;
      if ((_asInt(v['expiresAt']) ?? 0) <= now) continue;
      final Object? top = v['topLevelFids'];
      if (top is List) {
        for (final Object? e in top) {
          fids.add('$e');
        }
      }
      final String? playback = _asString(v['playbackFileId']);
      if (playback != null && playback.isNotEmpty) fids.add(playback);
    }
    return fids;
  }

  /// 删除文件并彻底清理回收站（对齐 iOS `quarkDeleteFiles`）。
  ///
  /// 返回提交删除的文件数（回收站清理为尽力而为）。
  Future<int> deleteFiles({
    required List<String> fileIds,
    required String cookie,
  }) async {
    if (fileIds.isEmpty) return 0;
    final SpiderHttpResult res = await _bridge.request(
      apiUrl('/1/clouddrive/file/delete').toString(),
      options: SpiderHttpOptions(
        method: 'POST',
        headers: _commonHeaders(cookie),
        data: jsonEncode(<String, Object?>{
          'action_type': 2,
          'filelist': fileIds,
          'exclude_fids': <String>[],
        }),
      ),
    );
    final Map<String, Object?>? json = _decodeMap(res.content);
    final String taskId = _asString(json?['task_id']) ?? '';
    if (taskId.isEmpty) return fileIds.length;

    // 彻底清理回收站：等待删除任务落盘 → recycle/list → recycle/remove。
    await Future<void>.delayed(const Duration(seconds: 1));
    final SpiderHttpResult recycleRes = await _bridge.request(
      apiUrl(
        '/1/clouddrive/file/recycle/list',
        extra: <(String, String)>[
          ('_page', '1'),
          ('_size', '100'),
          ('_sort', 'move_recycle_at:desc'),
        ],
      ).toString(),
      options: SpiderHttpOptions(headers: _commonHeaders(cookie)),
    );
    final Map<String, Object?>? recycleJson =
        _decodeMap(recycleRes.content);
    final Object? list = recycleJson?['data'];
    if (list is! List) return fileIds.length;
    final List<String> recordIds = <String>[];
    for (final Object? raw in list) {
      final Map<String, Object?>? item = _asMap(raw);
      final String recordId = _asString(item?['record_id']) ?? '';
      if (recordId.isEmpty) continue;
      if (recordId.contains(taskId) ||
          fileIds.any((String fid) => recordId.contains(fid))) {
        recordIds.add(recordId);
      }
    }
    if (recordIds.isEmpty) return fileIds.length;
    await _bridge.request(
      apiUrl('/1/clouddrive/file/recycle/remove').toString(),
      options: SpiderHttpOptions(
        method: 'POST',
        headers: _commonHeaders(cookie),
        data: jsonEncode(<String, Object?>{
          'select_mode': 2,
          'record_list': recordIds,
        }),
      ),
    );
    return fileIds.length;
  }

  /// 分批删除（对齐 iOS `deleteFids`：每批 100、批间 100ms 防风控）。
  Future<int> _deleteFidsBatched(
    List<String> fids, {
    required String cookie,
  }) async {
    const int batchSize = 100;
    int deleted = 0;
    for (int i = 0; i < fids.length; i += batchSize) {
      final List<String> batch =
          fids.sublist(i, math.min(i + batchSize, fids.length));
      final SpiderHttpResult res = await _bridge.request(
        apiUrl('/1/clouddrive/file/delete').toString(),
        options: SpiderHttpOptions(
          method: 'POST',
          headers: _commonHeaders(cookie),
          data: jsonEncode(<String, Object?>{
            'action_type': 2,
            'filelist': batch,
            'exclude_fids': <String>[],
          }),
        ),
      );
      final Map<String, Object?>? json = _decodeMap(res.content);
      if ((_asInt(json?['code']) ?? 0) == 0) deleted += batch.length;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return deleted;
  }

  /// 收集目录下文件 fid（对齐 iOS `collectFids`）。
  Future<List<String>> _collectFids({
    required String folderId,
    required String cookie,
    bool onlyVideo = false,
    int? limit,
    bool includeFolders = false,
  }) async {
    const int pageSize = 200;
    final int maxPages =
        limit != null ? math.min(10, (limit + pageSize - 1) ~/ pageSize) : 10;
    final List<String> fids = <String>[];
    for (int page = 1; page <= maxPages; page++) {
      final List<Map<String, Object?>> list = await _fileSortList(
        cookie: cookie,
        query: <(String, String)>[
          ('pdir_fid', folderId),
          ('_sort', 'file_type:asc,updated_at:desc'),
          ('_page', '$page'),
          ('_size', '$pageSize'),
          ('_fetch_total', '1'),
        ],
      );
      if (list.isEmpty) break;
      for (final Map<String, Object?> item in list) {
        final bool isDir = (_asInt(item['file_type']) == 0) ||
            (item['is_dir'] == true);
        if (isDir && !includeFolders) continue;
        if (onlyVideo && !isDir) {
          final String name = (_asString(item['file_name']) ??
                  _asString(item['name']) ??
                  '')
              .toLowerCase();
          if (!cleanupVideoExts.any((String e) => name.endsWith(e))) continue;
        }
        final String fid = _asString(item['fid']) ??
            _asString(item['file_id']) ??
            (_asInt(item['fid']) != null ? '${item['fid']}' : '');
        if (fid.isNotEmpty) fids.add(fid);
        if (limit != null && fids.length >= limit) break;
      }
      if (list.length < pageSize) break;
      if (limit != null && fids.length >= limit) break;
    }
    return fids;
  }

  /// 按名称在根目录查找文件夹 fid（对齐 iOS `findFolderId`）。
  Future<String?> _findFolderId(String name, String cookie) async {
    final List<Map<String, Object?>> list = await _fileSortList(
      cookie: cookie,
      query: <(String, String)>[
        ('pdir_fid', '0'),
        ('_sort', 'file_type:asc,file_name:asc'),
        ('_page', '1'),
        ('_size', '200'),
        ('_fetch_total', '1'),
      ],
    );
    final String target = name.trim().toLowerCase();
    for (final Map<String, Object?> item in list) {
      final String itemName = (_asString(item['file_name']) ??
              _asString(item['name']) ??
              '')
          .trim()
          .toLowerCase();
      if (itemName != target) continue;
      final String fid = _asString(item['fid']) ??
          _asString(item['file_id']) ??
          (_asInt(item['fid']) != null ? '${item['fid']}' : '');
      if (fid.isNotEmpty) return fid;
    }
    return null;
  }

  /// `file/sort` 列表条目（对齐 iOS 清理辅助里的 GET 列表）。
  Future<List<Map<String, Object?>>> _fileSortList({
    required String cookie,
    required List<(String, String)> query,
  }) async {
    final SpiderHttpResult res = await _bridge.request(
      apiUrl('/1/clouddrive/file/sort', extra: query).toString(),
      options: SpiderHttpOptions(headers: _commonHeaders(cookie)),
    );
    final Map<String, Object?>? json = _decodeMap(res.content);
    final Object? list = _asMap(json?['data'])?['list'];
    if (list is! List) return const <Map<String, Object?>>[];
    return list
        .whereType<Map<Object?, Object?>>()
        .map((Map<Object?, Object?> m) => m.cast<String, Object?>())
        .toList(growable: false);
  }

  // ─────────────── JSON 助手 ───────────────

  Map<String, Object?>? _decodeMap(String body) {
    if (body.isEmpty) return null;
    try {
      final Object? decoded = jsonDecode(body);
      return decoded is Map ? decoded.cast<String, Object?>() : null;
    } catch (_) {
      return null;
    }
  }

  static Map<String, Object?>? _asMap(Object? v) =>
      v is Map ? v.cast<String, Object?>() : null;

  static String? _asString(Object? v) => v is String ? v : null;

  static int? _asInt(Object? v) =>
      v is int ? v : (v is num ? v.toInt() : int.tryParse('$v'));
}