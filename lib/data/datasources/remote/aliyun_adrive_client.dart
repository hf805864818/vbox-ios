/// 数据层：阿里云盘 PG 4kz 播放链客户端（批次 F · F-P09）。
///
/// 唯一真相源：`vbox/Services/AliyunPgPlayManager.swift`（8 步链，L114-L345）：
///   1. `refreshToken`（L352）：三级刷新（官方 client_id/secret → WebApp → extscreen）
///      + `verifyAdriveToken`（L518）校验；
///   2. `getShareToken`（L562）：`POST /v2/share_link/get_share_token`；
///   3. `listShareFiles`/`collectShareFiles`（L610/L627）：`POST /adrive/v3/file/list`
///      递归 + 每目录 ≤10 页，`pgIsPlayable`（L703）过滤后按 name 升序取首个；
///   4. 分享直链优先：`getShareVideoPreviewPlayInfo`（转码 m3u8，L1071）→
///      `getShareDownloadUrl`（原画直链，L923：PDS + ADrive 双端点）；
///   5. 转存兜底（仅 4 失败时）：`getUserDriveId` + `saveFile`（L715）+
///      `waitForTransferTask`（L785）→ 转码 `getVideoPreviewPlayInfo`（L1109）/
///      原画 `getDownloadUrl`（L992）；
///   6. 直链交付（不包 Go 代理）；
///   7. 请求头组装（L306-325）：**转码 m3u8 不注入 UA/Referer**，原画直链补
///      `UA + Referer=https://api.alipan.com`；
///   8. 清理：转存路径 `scheduleCleanup`（L1222）——**NC-清3 已移植**：内存队列
///      + 到期 `moveToTrash`（`POST /adrive/v2/file/delete`），失败保留 ≤10 分钟
///      重试；`autoCleanup` 由 [PgAutoConfig] 决定，转存失败路径无条件登记。
///
/// 未移植项（如实登记）：
///   · **方案C（extscreen 刷新）**——Flutter 已由 `aliyun_extscreen_client.dart`
///     提供 extscreen OAuth；本客户端只做 A（官方）/B（WebApp）+ `verifyAdriveToken`；
///   · **`/ali-stream` 本地代理**（iOS 原画直链走本地代理注入头）——Flutter 直接以
///     `headers` 交付播放器，不建本地代理（登记差异）。
library;

import 'dart:async';
import 'dart:convert';

import '../../../domain/entities/cloud/pg_auto.dart';
import '../../../platform/player/playback_headers.dart';
import '../../../platform/spider/spider_http_bridge.dart';

/// 阿里分享文件条目（对齐 iOS `PgShareFile`）。
class AliyunShareFile {
  /// 构造。
  const AliyunShareFile({
    required this.fileId,
    required this.name,
    this.category = '',
    this.type = 'file',
    this.size = 0,
  });

  /// 文件 ID。
  final String fileId;

  /// 文件名。
  final String name;

  /// 分类（`video` 等）。
  final String category;

  /// 类型（`file` / `folder`）。
  final String type;

  /// 字节大小。
  final int size;

  /// 是否文件夹。
  bool get isFolder => type.toLowerCase() == 'folder';
}

/// 直链信息（对齐 iOS `PgDownloadInfo`）。
class AliyunDownloadInfo {
  /// 构造。
  const AliyunDownloadInfo({required this.url, this.headers = const <String, String>{}});

  /// 直链地址。
  final String url;

  /// 服务端下发请求头（可能为空）。
  final Map<String, String> headers;
}

/// 取链结果。
class AliyunPlayResult {
  /// 构造。
  const AliyunPlayResult({
    required this.url,
    required this.headers,
    required this.source,
    required this.fileName,
    this.fallbackUrl,
    this.fallbackHeaders = const <String, String>{},
    this.fallbackSource = '',
  });

  /// 播放地址。
  final String url;

  /// 播放请求头。
  final Map<String, String> headers;

  /// 来源标记（`ali-share-transcode` / `ali-share-download` /
  /// `ali-transfer-transcode` / `ali-transfer-download`）。
  final String source;

  /// 关联文件名。
  final String fileName;

  /// 兜底线路地址（null 表示无兜底，对齐 iOS `PlayResult.fallbackURL`）。
  final String? fallbackUrl;

  /// 兜底线路请求头（对齐 iOS `PlayResult.fallbackHeaders`）。
  final Map<String, String> fallbackHeaders;

  /// 兜底线路来源标记（`transcode` / `download_url`，对齐 iOS ali 拓扑）。
  final String fallbackSource;
}

/// 阿里 PG 链异常。
class AliyunAdriveException implements Exception {
  /// 构造。
  const AliyunAdriveException(this.message);

  /// 文案。
  final String message;

  @override
  String toString() => 'AliyunAdriveException($message)';
}

/// 待清理转存文件（对齐 iOS `PgCleanupItem`）。
class AliyunCleanupItem {
  /// 构造。
  const AliyunCleanupItem({
    required this.fileId,
    required this.accessToken,
    required this.createdAt,
  });

  /// 待删除文件 ID。
  final String fileId;

  /// 删除所需的 access_token（原画/转存链观众）。
  final String accessToken;

  /// 登记时间（用于延迟判定）。
  final DateTime createdAt;
}

/// 阿里云盘 ADrive 播放链客户端。
class AliyunAdriveClient {
  /// 构造（[transport] 供测试注入）。
  ///
  /// [startCleanupWorker] 为 `false` 时不自动起 30s 定时器（测试用），
  /// 需显式调用 [processPendingCleanups]。
  ///
  /// [onTokenRefreshed]：刷新成功回调（对齐 iOS `refreshAliAccessTokenIfNeeded`
  /// 全链落库语义，`CloudDriveAuthManager.swift:270-339`）——阿里 refresh_token
  /// 有轮换语义（每次刷新返回新值），不落库会导致下次播放用旧值自毁凭据。
  AliyunAdriveClient({
    SpiderHttpTransport? transport,
    this.startCleanupWorker = true,
    this.onTokenRefreshed,
  }) : _transport = transport ?? IoSpiderHttpTransport();

  /// 刷新成功回调：参数为刷新后的 `accessToken` / `refreshToken`（轮换新值优先）。
  final void Function(String accessToken, String refreshToken)?
      onTokenRefreshed;

  /// 阿里 API 基址（对齐 iOS `aliApiBase` / `aliPdsApiBase`，两者同值）。
  static const String apiBase = 'https://api.alipan.com';

  /// 官方客户端 ID（对齐 iOS `refreshAliViaOfficialAPI`）。
  static const String officialClientId = '5f6b9c8e3f8a4b2c9e1d7a3f5b8c2e4d';

  /// 官方客户端密钥（对齐 iOS `refreshAliViaOfficialAPI`）。
  static const String officialClientSecret =
      '8c7e2a1f3d5b4c6e9a8f2d3c1b4e5a6f';

  /// OpenList renewapi 请求 UA（P2-6，对齐 iOS `aliUserAgent`，
  /// `CloudDriveAuthManager.swift:2685-2687`）。
  static const String _aliOpenListUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  /// 桌面 UA（对齐 iOS 直链默认头；集中层单一常量 [PlaybackHeaders.aliyunDesktopUA]）。
  static const String desktopUA = PlaybackHeaders.aliyunDesktopUA;

  /// 可播放扩展名（对齐 iOS `pgIsPlayable`）。
  static const List<String> playableExts = <String>[
    'mp4', 'mkv', 'mov', 'm3u8', 'avi', 'wmv', 'flv', 'ts', 'm4v',
  ];

  /// 转码画质优先级（对齐 iOS `extractVideoPreviewInfo`）。
  static const List<String> qualityOrder = <String>[
    'QHD', 'FHD', 'HD', 'SD', 'LD',
  ];

  final SpiderHttpTransport _transport;

  /// 是否自动起 30s 清理工作线程（对齐 iOS `startCleanupWorker`）。
  final bool startCleanupWorker;

  /// 待清理转存文件（对齐 iOS `pendingCleanups`）。
  final List<AliyunCleanupItem> _pendingCleanups = <AliyunCleanupItem>[];

  /// 清理工作线程定时器（惰性创建）。
  Timer? _cleanupTimer;

  /// 生效清理延迟（对齐 iOS `config.cleanupDelay`，缺省 60s）。
  ///
  /// [resolvePlayUrl] 收到 [PgAutoConfig] 后按契约值覆盖；工作线程按此判定到期。
  Duration cleanupDelay = const Duration(seconds: 60);

  /// 清理重试上限窗口（对齐 iOS：失败保留 10 分钟后放弃）。
  static const Duration cleanupRetryWindow = Duration(minutes: 10);

  /// 工作线程轮询间隔（对齐 iOS 每 30 秒检查）。
  static const Duration cleanupPollInterval = Duration(seconds: 30);

  /// 待清理条目数（测试 / 诊断）。
  int get pendingCleanupCount => _pendingCleanups.length;

  // ─────────────── 静态工具 ───────────────

  /// 分享链接 → shareId（对齐 iOS `parseShareId`，不使用正则）。
  static String parseShareId(String shareUrl) {
    final int idx = shareUrl.indexOf('/s/');
    if (idx >= 0) {
      String after = shareUrl.substring(idx + 3);
      after = after.split('?').first;
      after = after.split('#').first;
      after = after.split('/').first;
      return after;
    }
    final Uri? uri = Uri.tryParse(shareUrl);
    if (uri != null) {
      final List<String> comps =
          uri.path.split('/').where((String s) => s.isNotEmpty).toList();
      final int sIdx = comps.indexOf('s');
      if (sIdx >= 0 && comps.length > sIdx + 1) return comps[sIdx + 1];
    }
    return '';
  }

  /// 是否可播放（对齐 iOS `pgIsPlayable`）。
  static bool isPlayable(AliyunShareFile file) {
    if (file.category.toLowerCase() == 'video') return true;
    final String lower = file.name.toLowerCase();
    return playableExts.any((String e) => lower.endsWith('.$e'));
  }

  /// 是否阿里转码 m3u8（对齐 iOS 步骤7 判定：host 含 aliyun+video 且
  /// path 含 `/lt/` 或 `/qv/`）。
  ///
  /// 判据单一来源在集中层 [PlaybackHeaders.isAliTranscodeM3u8]（F-P12）。
  static bool isTranscodeM3u8(String url) =>
      PlaybackHeaders.isAliTranscodeM3u8(url);

  /// code 判定（对齐 iOS：String 需 `OK/ok/0`；Int 需 `0/200`；缺省通过）。
  static bool _codeOk(Object? code) {
    if (code == null) return true;
    if (code is int) return code == 0 || code == 200;
    final String s = '$code';
    return s == 'OK' || s == 'ok' || s == '0';
  }

  /// 直链提取（对齐 iOS `extractDownloadInfo`：`url` → `download_url` →
  /// `url_list[0]`；`headers` 为 `[String:String]` 时采用，否则空）。
  static AliyunDownloadInfo extractDownloadInfo(Map<String, Object?> json) {
    String url = _asString(json['url']) ?? '';
    if (url.isEmpty) url = _asString(json['download_url']) ?? '';
    if (url.isEmpty) {
      final Object? list = json['url_list'];
      if (list is List) {
        for (final Object? e in list) {
          final String s = _asString(e) ?? '';
          if (s.isNotEmpty) {
            url = s;
            break;
          }
        }
      }
    }
    if (url.isEmpty) {
      throw const AliyunAdriveException('get_download_url 响应中无 download_url');
    }
    final Object? rawHeaders = json['headers'];
    final Map<String, String> headers = rawHeaders is Map
        ? <String, String>{
            for (final MapEntry<Object?, Object?> e in rawHeaders.entries)
              e.key.toString(): '${e.value}',
          }
        : const <String, String>{};
    return AliyunDownloadInfo(url: url, headers: headers);
  }

  /// 转码地址提取（对齐 iOS `extractVideoPreviewInfo`：按
  /// QHD→FHD→HD→SD→LD 用 `template_id` 子串匹配，兜底首个非空 url）。
  static String extractVideoPreviewUrl(Map<String, Object?> json) {
    if (!_codeOk(json['code'])) {
      throw AliyunAdriveException(
        '转码地址获取失败：${_asString(json['message']) ?? 'code=${json['code']}'}',
      );
    }
    final Object? vpiRaw = json['video_preview_play_info'];
    final Map<String, Object?>? vpi = _asMap(vpiRaw);
    final Object? tasksRaw = vpi?['live_transcoding_task_list'];
    if (tasksRaw is! List) {
      throw const AliyunAdriveException('video_preview_play_info 无转码任务列表');
    }
    final List<Map<String, Object?>> tasks =
        tasksRaw.whereType<Map<Object?, Object?>>().map(
              (Map<Object?, Object?> m) => m.cast<String, Object?>(),
            ).toList();
    for (final String quality in qualityOrder) {
      for (final Map<String, Object?> task in tasks) {
        final String template =
            (_asString(task['template_id']) ?? '').toUpperCase();
        final String url = _asString(task['url']) ?? '';
        if (template.contains(quality) && url.isNotEmpty) return url;
      }
    }
    for (final Map<String, Object?> task in tasks) {
      final String url = _asString(task['url']) ?? '';
      if (url.isNotEmpty) return url;
    }
    throw const AliyunAdriveException('转码任务列表中无可用 url');
  }

  // ─────────────── Token 刷新 ───────────────

  /// 刷新 ADrive 兼容 token（对齐 iOS `refreshViaAliyunPgAuthManager` +
  /// `verifyAdriveToken`；方案C extscreen 见类注释）。
  Future<({String accessToken, String refreshToken})> refreshAccessToken({
    required String refreshToken,
  }) async {
    if (refreshToken.isEmpty) {
      throw const AliyunAdriveException('PG凭证中无refresh_token');
    }
    // 方案A：官方 client_id/secret。
    final ({String accessToken, String refreshToken})? official =
        await _refreshOfficial(refreshToken);
    if (official != null && await verifyAdriveToken(official.accessToken)) {
      onTokenRefreshed?.call(official.accessToken, official.refreshToken);
      return official;
    }
    // 方案B：WebApp（不带 secret，双端点）。
    final ({String accessToken, String refreshToken})? webApp =
        await _refreshWebApp(refreshToken);
    if (webApp != null && await verifyAdriveToken(webApp.accessToken)) {
      onTokenRefreshed?.call(webApp.accessToken, webApp.refreshToken);
      return webApp;
    }
    // 兜底：OpenList renewapi GET（P2-6，对齐 iOS `refreshAliViaOpenList`
    // GET 分支，`CloudDriveAuthManager.swift:295-307`；成功直接返回，
    // 不做 `verifyAdriveToken`——对齐 iOS OpenList 层落库语义）。
    try {
      final ({String accessToken, String refreshToken}) openListGet =
          await _refreshOpenList(refreshToken, usePost: false);
      onTokenRefreshed?.call(openListGet.accessToken, openListGet.refreshToken);
      return openListGet;
    } catch (_) {
      // GET 失败 → 继续 POST 兜底。
    }
    // 兜底：OpenList renewapi POST（对齐 iOS POST 分支，`L309-323`）。
    try {
      final ({String accessToken, String refreshToken}) openListPost =
          await _refreshOpenList(refreshToken, usePost: true);
      onTokenRefreshed?.call(openListPost.accessToken,
          openListPost.refreshToken);
      return openListPost;
    } catch (_) {
      // POST 也失败 → 落到下方统一抛错。
    }
    throw const AliyunAdriveException(
      'PG Token 刷新失败：无法获取兼容分享操作的 ADrive token',
    );
  }

  /// OpenList renewapi 刷新（P2-6，对齐 iOS `refreshAliViaOpenList`，
  /// `CloudDriveAuthManager.swift:372-435`）：
  /// - 端点 `https://api.oplist.org/alicloud/renewapi`；
  /// - GET（URL query）/ POST（form-urlencoded body）两形态，参数
  ///   `driver_txt=alicloud_qr` / `refresh_ui=<refreshToken>` / `server_use=true`；
  /// - `{"text":"..."}` 错误格式：含 invalid / expired / 过期 → 「已失效」文案；
  /// - HTTP >= 400 报错（message / error 字段）；
  /// - 必须返回新 refresh_token 才算成功（不回退旧 token，避免掩盖错误）；
  ///   access_token 可空（返回空串，语义对齐 iOS 可空落库）。
  Future<({String accessToken, String refreshToken})> _refreshOpenList(
    String refreshToken, {
    required bool usePost,
  }) async {
    const String renewURL = 'https://api.oplist.org/alicloud/renewapi';
    final Map<String, String> query = <String, String>{
      'driver_txt': 'alicloud_qr',
      'refresh_ui': refreshToken,
      'server_use': 'true',
    };
    final SpiderTransportResponse res = await _transport.send(
      SpiderTransportRequest(
        method: usePost ? 'POST' : 'GET',
        url: Uri.parse(usePost
            ? renewURL
            : Uri.parse(renewURL).replace(queryParameters: query).toString()),
        headers: <String, String>{
          'User-Agent': _aliOpenListUserAgent,
          if (usePost) 'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: usePost
            ? query.entries
                .map((MapEntry<String, String> e) =>
                    '${e.key}=${Uri.encodeQueryComponent(e.value)}')
                .join('&')
            : null,
        timeout: const Duration(seconds: 30),
      ),
    );
    final int httpStatus = res.status;
    final String text = utf8.decode(res.bodyBytes, allowMalformed: true);
    Map<String, Object?>? json;
    try {
      final Object? decoded = jsonDecode(text);
      if (decoded is Map) json = decoded.cast<String, Object?>();
    } catch (_) {
      json = null;
    }
    // OpenList 错误格式：`{"text":"<错误描述>"}`。
    final String? errorText = _asString(json?['text']);
    if (errorText != null && errorText.isNotEmpty) {
      if (errorText.contains('invalid') ||
          errorText.contains('expired') ||
          errorText.contains('过期')) {
        throw AliyunAdriveException('阿里云盘 refresh_token 已失效：$errorText');
      }
      throw AliyunAdriveException('阿里云盘 token 刷新失败：$errorText');
    }
    if (httpStatus >= 400) {
      final String msg = _asString(json?['message']) ??
          _asString(json?['error']) ??
          'HTTP $httpStatus';
      throw AliyunAdriveException('阿里云盘 token 刷新失败：$msg');
    }
    final String newRefreshToken =
        _asString(json?['refresh_token']) ?? _asString(json?['refreshToken']) ?? '';
    final String newAccessToken =
        _asString(json?['access_token']) ?? _asString(json?['accessToken']) ?? '';
    if (newRefreshToken.isEmpty) {
      throw AliyunAdriveException(
        '阿里云盘刷新 token 未返回 refresh_token (HTTP $httpStatus)',
      );
    }
    return (accessToken: newAccessToken, refreshToken: newRefreshToken);
  }

  Future<({String accessToken, String refreshToken})?> _refreshOfficial(
    String refreshToken,
  ) async {
    final ({int status, Map<String, Object?>? json}) res = await _post(
      'https://auth.aliyundrive.com/v2/account/token',
      headers: <String, String>{'Content-Type': 'application/json'},
      body: <String, Object?>{
        'refresh_token': refreshToken,
        'client_id': officialClientId,
        'client_secret': officialClientSecret,
        'grant_type': 'refresh_token',
      },
    );
    if (res.status != 200 || res.json == null) return null;
    final String access = _asString(res.json!['access_token']) ?? '';
    final String refresh = _asString(res.json!['refresh_token']) ?? '';
    if (access.isEmpty || refresh.isEmpty) return null;
    return (accessToken: access, refreshToken: refresh);
  }

  Future<({String accessToken, String refreshToken})?> _refreshWebApp(
    String refreshToken,
  ) async {
    const List<String> endpoints = <String>[
      'https://auth.aliyundrive.com/v2/account/token',
      'https://api.aliyundrive.com/v2/account/token',
    ];
    for (final String endpoint in endpoints) {
      final ({int status, Map<String, Object?>? json}) res = await _post(
        endpoint,
        headers: <String, String>{'Content-Type': 'application/json'},
        body: <String, Object?>{
          'refresh_token': refreshToken,
          'grant_type': 'refresh_token',
        },
      );
      if (res.status != 200 || res.json == null) continue;
      final String access = _asString(res.json!['access_token']) ?? '';
      final String refresh = _asString(res.json!['refresh_token']) ?? '';
      if (access.isEmpty || refresh.isEmpty) continue;
      return (accessToken: access, refreshToken: refresh);
    }
    return null;
  }

  /// 校验 ADrive token 是否可用于分享操作（对齐 iOS `verifyAdriveToken`）。
  Future<bool> verifyAdriveToken(String accessToken) async {
    final ({int status, Map<String, Object?>? json}) res = await _post(
      '$apiBase/adrive/v2/user/get',
      headers: <String, String>{
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $accessToken',
      },
      body: const <String, Object?>{},
    );
    return res.status == 200;
  }

  // ─────────────── 分享 token / 文件列表 ───────────────

  /// 取分享 token（对齐 iOS `getShareToken`）。
  Future<String> getShareToken({
    required String accessToken,
    required String shareId,
  }) async {
    final ({int status, Map<String, Object?>? json}) res = await _post(
      '$apiBase/v2/share_link/get_share_token',
      headers: <String, String>{
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $accessToken',
      },
      body: <String, Object?>{'share_id': shareId},
    );
    if (res.status != 200) {
      throw AliyunAdriveException('get_share_token HTTP ${res.status}');
    }
    final Map<String, Object?>? json = res.json;
    if (json == null || !_codeOk(json['code'])) {
      throw AliyunAdriveException(
        '取分享 token 失败：${_asString(json?['message']) ?? 'code=${json?['code']}'}',
      );
    }
    final String token = _asString(json['share_token']) ?? '';
    if (token.isEmpty) throw const AliyunAdriveException('分享 token 为空');
    return token;
  }

  /// 列举分享内全部文件（root，递归 + 每目录 ≤10 页）。
  Future<List<AliyunShareFile>> listShareFiles({
    required String accessToken,
    required String shareToken,
    required String shareId,
  }) async {
    final List<AliyunShareFile> out = <AliyunShareFile>[];
    await _collectShareFiles(
      accessToken: accessToken,
      shareToken: shareToken,
      shareId: shareId,
      parentFileId: 'root',
      out: out,
    );
    return out;
  }

  Future<void> _collectShareFiles({
    required String accessToken,
    required String shareToken,
    required String shareId,
    required String parentFileId,
    required List<AliyunShareFile> out,
  }) async {
    String marker = '';
    for (int page = 0; page < 10; page++) {
      final Map<String, Object?> body = <String, Object?>{
        'share_id': shareId,
        'parent_file_id': parentFileId,
        'limit': 100,
        'order_by': 'name',
        'order_direction': 'ASC',
        if (marker.isNotEmpty) 'marker': marker,
      };
      final ({int status, Map<String, Object?>? json}) res = await _post(
        '$apiBase/adrive/v3/file/list',
        headers: <String, String>{
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $accessToken',
          'x-share-token': shareToken,
          'Referer': 'https://www.alipan.com/',
        },
        body: body,
      );
      if (res.status != 200) {
        throw AliyunAdriveException('file/list HTTP ${res.status}');
      }
      final Map<String, Object?>? json = res.json;
      if (json == null) throw const AliyunAdriveException('file/list 响应异常');
      if (!_codeOk(json['code'])) {
        throw AliyunAdriveException(
          '文件列表失败：${_asString(json['message']) ?? 'code=${json['code']}'}',
        );
      }
      final Object? items = json['items'];
      if (items is List) {
        for (final Object? raw in items) {
          final Map<String, Object?>? item = _asMap(raw);
          if (item == null) continue;
          final String fileId = _asString(item['file_id']) ?? '';
          if (fileId.isEmpty) continue;
          final AliyunShareFile file = AliyunShareFile(
            fileId: fileId,
            name: _asString(item['name']) ??
                _asString(item['file_name']) ??
                '',
            type: _asString(item['type']) ?? 'file',
            category: _asString(item['category']) ?? '',
            size: _asInt(item['size']) ?? 0,
          );
          if (file.isFolder) {
            await _collectShareFiles(
              accessToken: accessToken,
              shareToken: shareToken,
              shareId: shareId,
              parentFileId: fileId,
              out: out,
            );
          } else {
            out.add(file);
          }
        }
      }
      final String next = _asString(json['next_marker']) ?? '';
      if (next.isEmpty) break;
      marker = next;
    }
  }

  /// 分享链接 → 全部可播放文件（按 name 升序，对齐 iOS 步骤3）。
  Future<List<AliyunShareFile>> listPlayableFiles({
    required String shareUrl,
    required String refreshToken,
  }) async {
    final String shareId = parseShareId(shareUrl);
    if (shareId.isEmpty) throw const AliyunAdriveException('无法识别的分享链接');
    final ({String accessToken, String refreshToken}) token =
        await refreshAccessToken(refreshToken: refreshToken);
    final String shareToken = await getShareToken(
      accessToken: token.accessToken,
      shareId: shareId,
    );
    final List<AliyunShareFile> files = await listShareFiles(
      accessToken: token.accessToken,
      shareToken: shareToken,
      shareId: shareId,
    );
    final List<AliyunShareFile> playable =
        files.where(isPlayable).toList()..sort(
            (AliyunShareFile a, AliyunShareFile b) => a.name.compareTo(b.name),
          );
    return playable;
  }

  // ─────────────── 转存 ───────────────

  /// 取用户 drive_id（对齐 iOS `getUserDriveId`）。
  Future<String> getDriveId(String accessToken) async {
    final ({int status, Map<String, Object?>? json}) res = await _post(
      '$apiBase/adrive/v2/user/get',
      headers: <String, String>{
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $accessToken',
      },
      body: const <String, Object?>{},
    );
    if (res.status != 200 || res.json == null) {
      throw AliyunAdriveException('user/get HTTP ${res.status}');
    }
    final Map<String, Object?> json = res.json!;
    final String driveId = _asString(json['default_drive_id']) ??
        _asString(json['resource_drive_id']) ??
        _asString(json['drive_id']) ??
        '';
    if (driveId.isEmpty) {
      throw const AliyunAdriveException('user/get 未返回 drive_id');
    }
    return driveId;
  }

  /// 转存分享文件到 root（对齐 iOS `saveFile`），返回 file_id。
  Future<String> saveFile({
    required String accessToken,
    required String shareToken,
    required String shareId,
    required String fileId,
    required String driveId,
  }) async {
    final ({int status, Map<String, Object?>? json}) res = await _post(
      '$apiBase/adrive/v2/file/copy',
      headers: <String, String>{
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $accessToken',
        'x-share-token': shareToken,
      },
      body: <String, Object?>{
        'share_id': shareId,
        'file_id': fileId,
        'to_drive_id': driveId,
        'to_parent_file_id': 'root',
        'auto_rename': true,
      },
    );
    if (res.status != 200 && res.status != 201) {
      throw AliyunAdriveException('file/copy HTTP ${res.status}');
    }
    final Map<String, Object?>? json = res.json;
    if (json == null) throw const AliyunAdriveException('file/copy 响应异常');
    if (!_codeOk(json['code'])) {
      throw AliyunAdriveException(
        '转存失败：${_asString(json['message']) ?? 'code=${json['code']}'}',
      );
    }
    final String copiedId = _asString(json['file_id']) ?? '';
    if (copiedId.isNotEmpty) return copiedId;
    final String taskId = _asString(json['async_task_id']) ?? '';
    if (taskId.isNotEmpty) {
      await waitForTransferTask(taskId: taskId, accessToken: accessToken);
    }
    return findRecentlySavedFile(accessToken: accessToken, driveId: driveId);
  }

  /// 轮询转存任务（对齐 iOS `waitForTransferTask`：最多 10 次、每次先 sleep 3s、
  /// 超时不抛错）。
  Future<void> waitForTransferTask({
    required String taskId,
    required String accessToken,
  }) async {
    for (int attempt = 0; attempt < 10; attempt++) {
      await Future<void>.delayed(const Duration(seconds: 3));
      final ({int status, Map<String, Object?>? json}) res = await _post(
        '$apiBase/adrive/v2/async_task/get',
        headers: <String, String>{
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $accessToken',
        },
        body: <String, Object?>{'async_task_id': taskId},
      );
      final Map<String, Object?>? json = res.json;
      if (res.status != 200 || json == null) continue;
      final String state =
          (_asString(json['state']) ?? _asString(json['status']) ?? 'running')
              .toLowerCase();
      if (state.contains('succeed') || state.contains('success')) return;
      if (state.contains('fail') || state.contains('error')) {
        throw AliyunAdriveException(
          '转存任务失败：${_asString(json['message']) ?? _asString(json['error']) ?? state}',
        );
      }
    }
  }

  /// 兜底查找最近转存文件（对齐 iOS `findRecentlySavedFile`）。
  Future<String> findRecentlySavedFile({
    required String accessToken,
    required String driveId,
  }) async {
    final ({int status, Map<String, Object?>? json}) res = await _post(
      '$apiBase/adrive/v3/file/list',
      headers: <String, String>{
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $accessToken',
      },
      body: <String, Object?>{
        'drive_id': driveId,
        'parent_file_id': 'root',
        'limit': 20,
        'order_by': 'updated_at',
        'order_direction': 'DESC',
      },
    );
    if (res.status != 200 || res.json == null) {
      throw AliyunAdriveException('file/list HTTP ${res.status}');
    }
    final Object? items = res.json!['items'];
    if (items is List) {
      for (final Object? raw in items) {
        final Map<String, Object?>? item = _asMap(raw);
        if (item == null) continue;
        final String id = _asString(item['file_id']) ?? '';
        final bool isVideo = _asString(item['type']) == 'file' &&
            _asString(item['category']) == 'video';
        if (isVideo && id.isNotEmpty) return id;
      }
      for (final Object? raw in items) {
        final Map<String, Object?>? item = _asMap(raw);
        final String id = _asString(item?['file_id']) ?? '';
        if (id.isNotEmpty) return id;
      }
    }
    throw const AliyunAdriveException('转存后未找到已保存文件');
  }

  // ─────────────── 直链 / 转码 ───────────────

  /// 分享原画直链（对齐 iOS `getShareDownloadUrl`：PDS → ADrive 双端点）。
  Future<AliyunDownloadInfo> getShareDownloadInfo({
    required String accessToken,
    required String shareToken,
    required String shareId,
    required String fileId,
  }) async {
    const List<String> endpoints = <String>[
      'https://api.aliyundrive.com/v2/file/get_download_url',
      '$apiBase/adrive/v2/file/get_download_url',
    ];
    for (final String endpoint in endpoints) {
      final ({int status, Map<String, Object?>? json}) res = await _post(
        endpoint,
        headers: <String, String>{
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $accessToken',
          'x-share-token': shareToken,
          'Referer': 'https://www.alipan.com/',
        },
        body: <String, Object?>{
          'file_id': fileId,
          'share_id': shareId,
          'expire_sec': 14400,
        },
      );
      if (res.status == 200 && res.json != null) {
        return extractDownloadInfo(res.json!);
      }
    }
    throw const AliyunAdriveException('分享直链获取失败（PDS + ADrive 两种方案均失败）');
  }

  /// 个人网盘原画直链（对齐 iOS `getDownloadUrl`）。
  Future<AliyunDownloadInfo> getDownloadInfo({
    required String accessToken,
    required String driveId,
    required String fileId,
  }) async {
    final ({int status, Map<String, Object?>? json}) res = await _post(
      '$apiBase/adrive/v2/file/get_download_url',
      headers: <String, String>{
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $accessToken',
      },
      body: <String, Object?>{
        'drive_id': driveId,
        'file_id': fileId,
        'expire_sec': 14400,
      },
    );
    if (res.status != 200 || res.json == null) {
      throw AliyunAdriveException('get_download_url HTTP ${res.status}');
    }
    return extractDownloadInfo(res.json!);
  }

  /// 分享转码 m3u8（对齐 iOS `getShareVideoPreviewPlayInfo`）。
  Future<String> getShareVideoPreviewUrl({
    required String accessToken,
    required String shareToken,
    required String fileId,
  }) async {
    final ({int status, Map<String, Object?>? json}) res = await _post(
      '$apiBase/adrive/v2/file/get_video_preview_play_info',
      headers: <String, String>{
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $accessToken',
        'x-share-token': shareToken,
        'Referer': 'https://www.alipan.com/',
      },
      body: <String, Object?>{'file_id': fileId, 'category': 'live_transcoding'},
    );
    if (res.status != 200 || res.json == null) {
      throw AliyunAdriveException('转码信息 HTTP ${res.status}');
    }
    return extractVideoPreviewUrl(res.json!);
  }

  /// 个人网盘转码 m3u8（对齐 iOS `getVideoPreviewPlayInfo`）。
  Future<String> getVideoPreviewUrl({
    required String accessToken,
    required String driveId,
    required String fileId,
  }) async {
    final ({int status, Map<String, Object?>? json}) res = await _post(
      '$apiBase/adrive/v2/file/get_video_preview_play_info',
      headers: <String, String>{
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $accessToken',
      },
      body: <String, Object?>{
        'drive_id': driveId,
        'file_id': fileId,
        'category': 'live_transcoding',
      },
    );
    if (res.status != 200 || res.json == null) {
      throw AliyunAdriveException('转码信息 HTTP ${res.status}');
    }
    return extractVideoPreviewUrl(res.json!);
  }

  // ─────────────── 主链编排（对齐 resolveViaPgChain）───────────────

  /// 分享链接 → 取链（对齐 iOS `resolveViaPgChain` 8 步）。
  ///
  /// [pgConfig] 提供转存清理开关（`autoCleanup`）与延迟（`cleanupDelay`）；
  /// 缺省 [PgAutoConfig.defaults]（契约缺省 `autoCleanup=false`，不登记）。
  Future<AliyunPlayResult> resolvePlayUrl({
    required String shareUrl,
    required String refreshToken,
    String? preferredFileId,
    PgAutoConfig pgConfig = PgAutoConfig.defaults,
  }) async {
    final String shareId = parseShareId(shareUrl);
    if (shareId.isEmpty) throw const AliyunAdriveException('无法识别的分享链接');
    // 生效清理延迟（对齐 iOS `config.cleanupDelay`，供工作线程判定到期）。
    cleanupDelay = PgAutoRules.cleanupDelay(pgConfig);
    // 步骤1
    final ({String accessToken, String refreshToken}) token =
        await refreshAccessToken(refreshToken: refreshToken);
    // 步骤2
    final String shareToken = await getShareToken(
      accessToken: token.accessToken,
      shareId: shareId,
    );
    // 步骤3
    final AliyunShareFile target;
    if (preferredFileId != null && preferredFileId.isNotEmpty) {
      target = AliyunShareFile(
        fileId: preferredFileId,
        name: '指定文件',
        category: 'video',
      );
    } else {
      final List<AliyunShareFile> files = await listShareFiles(
        accessToken: token.accessToken,
        shareToken: shareToken,
        shareId: shareId,
      );
      final List<AliyunShareFile> playable =
          files.where(isPlayable).toList()..sort(
              (AliyunShareFile a, AliyunShareFile b) =>
                  a.name.compareTo(b.name),
            );
      if (playable.isEmpty) {
        throw const AliyunAdriveException('分享内未找到可播放视频');
      }
      target = playable.first;
    }

    // 步骤4：分享直链（转码 m3u8 与原画直链**均尝试**，对齐 iOS 双取，
    //        以便派生兜底线路）。
    String? transcodeUrl;
    AliyunDownloadInfo? download;
    String source = '';
    try {
      transcodeUrl = await getShareVideoPreviewUrl(
        accessToken: token.accessToken,
        shareToken: shareToken,
        fileId: target.fileId,
      );
      source = 'ali-share-transcode';
    } on AliyunAdriveException {
      transcodeUrl = null;
    }
    try {
      download = await getShareDownloadInfo(
        accessToken: token.accessToken,
        shareToken: shareToken,
        shareId: shareId,
        fileId: target.fileId,
      );
      if (source.isEmpty) source = 'ali-share-download';
    } on AliyunAdriveException {
      download = null;
    }

    // 步骤5：转存兜底（仅 4 全失败）。
    String? transferredFileId;
    if (transcodeUrl == null && download == null) {
      try {
        final String driveId = await getDriveId(token.accessToken);
        final String savedId = await saveFile(
          accessToken: token.accessToken,
          shareToken: shareToken,
          shareId: shareId,
          fileId: target.fileId,
          driveId: driveId,
        );
        transferredFileId = savedId;
        try {
          transcodeUrl = await getVideoPreviewUrl(
            accessToken: token.accessToken,
            driveId: driveId,
            fileId: savedId,
          );
          source = 'ali-transfer-transcode';
        } on AliyunAdriveException {
          transcodeUrl = null;
        }
        if (transcodeUrl == null) {
          download = await getDownloadInfo(
            accessToken: token.accessToken,
            driveId: driveId,
            fileId: savedId,
          );
          source = 'ali-transfer-download';
        }
      } on AliyunAdriveException catch (e) {
        // 转存失败也要清理可能已转存的文件（对齐 iOS L279-282）。
        if (transferredFileId != null) {
          scheduleCleanup(
            fileId: transferredFileId,
            accessToken: token.accessToken,
          );
        }
        throw AliyunAdriveException('PG步骤4-5 获取播放直链失败: ${e.message}');
      }
    }

    // 步骤6/7：交付地址 + 请求头组装。
    final String url = transcodeUrl ?? download!.url;
    final bool isTranscode = transcodeUrl != null || isTranscodeM3u8(url);
    // 原画直链请求头（下载信息自带头 + 缺省 UA / Referer；同时作转码主线的
    // 兜底线路头，对齐 iOS L925-929 fallbackHeaders=directHeaders）。
    final Map<String, String> directHeaders =
        Map<String, String>.of(download?.headers ?? const <String, String>{});
    directHeaders.putIfAbsent(
      'User-Agent',
      () => PlaybackHeaders.aliyunDesktopUA,
    );
    directHeaders.putIfAbsent('Referer', () => PlaybackHeaders.aliyunReferer);
    // 主线路请求头来自**命中线路**的响应（对齐 iOS AliyunPgPlayManager 步骤7
    // `playHeaders = downloadInfo.headers`，L306）：分享转码线路不拼 download
    // 响应的头，也不注入 UA/Referer——转码 m3u8 是带签名自鉴权 CDN 直链，注入
    // 会被视频 CDN 防盗链拒绝（-1102）；仅原画直链保留服务端头 + 缺省注入。
    final Map<String, String> headers =
        isTranscode ? const <String, String>{} : directHeaders;

    // 兜底线路派生（对齐 iOS `resolveAliyunSharePlayURL` 拓扑）：
    //   转码为主 → 兜底原画直链（`download_url`）；
    //   原画为主 → 兜底转码（`transcode`）。
    String? fallbackUrl;
    String fallbackSource = '';
    Map<String, String> fallbackHeaders = const <String, String>{};
    if (isTranscode) {
      if (download != null && download.url.isNotEmpty) {
        fallbackUrl = download.url;
        fallbackSource = 'download_url';
        fallbackHeaders = directHeaders;
      }
    } else if (transcodeUrl != null && transcodeUrl.isNotEmpty) {
      fallbackUrl = transcodeUrl;
      fallbackSource = 'transcode';
    }

    // 步骤8：转存路径按 `autoCleanup` 登记延迟清理（对齐 iOS）。
    if (transferredFileId != null &&
        PgAutoRules.shouldScheduleCleanup(pgConfig)) {
      scheduleCleanup(
        fileId: transferredFileId,
        accessToken: token.accessToken,
      );
    }
    return AliyunPlayResult(
      url: url,
      headers: headers,
      source: source,
      fileName: target.name,
      fallbackUrl: fallbackUrl,
      fallbackHeaders: fallbackHeaders,
      fallbackSource: fallbackSource,
    );
  }

  // ─────────────── 转存清理（NC-清3，对齐 iOS `scheduleCleanup` /
  //                 `processPendingCleanups` / `moveToTrash`）───────────────

  /// 登记延迟清理（对齐 iOS `scheduleCleanup(fileId:accessToken:)`）。
  ///
  /// 首次登记时按需拉起工作线程（[startCleanupWorker] 为 true）。
  void scheduleCleanup({
    required String fileId,
    required String accessToken,
  }) {
    if (fileId.isEmpty) return;
    _pendingCleanups.add(
      AliyunCleanupItem(
        fileId: fileId,
        accessToken: accessToken,
        createdAt: DateTime.now(),
      ),
    );
    _ensureCleanupWorker();
  }

  void _ensureCleanupWorker() {
    if (!startCleanupWorker) return;
    if (_cleanupTimer != null) return;
    _cleanupTimer = Timer.periodic(cleanupPollInterval, (_) {
      unawaited(processPendingCleanups(delay: cleanupDelay));
    });
  }

  /// 停止清理工作线程（释放资源 / 测试收尾）。
  void disposeCleanupWorker() {
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
  }

  /// 处理到期清理（对齐 iOS `processPendingCleanups`）。
  ///
  /// 到期条目尝试删除；失败条目在 [cleanupRetryWindow] 内保留重试，超窗放弃。
  Future<int> processPendingCleanups({
    required Duration delay,
    DateTime? now,
  }) async {
    if (_pendingCleanups.isEmpty) return 0;
    final DateTime stamp = now ?? DateTime.now();
    final List<AliyunCleanupItem> remaining = <AliyunCleanupItem>[];
    int deleted = 0;
    for (final AliyunCleanupItem item in _pendingCleanups) {
      final Duration age = stamp.difference(item.createdAt);
      if (age < delay) {
        remaining.add(item);
        continue;
      }
      try {
        await deleteFile(
          accessToken: item.accessToken,
          fileId: item.fileId,
        );
        deleted += 1;
      } on AliyunAdriveException {
        if (age < cleanupRetryWindow) remaining.add(item);
      }
    }
    _pendingCleanups
      ..clear()
      ..addAll(remaining);
    if (_pendingCleanups.isEmpty) disposeCleanupWorker();
    return deleted;
  }

  /// 删除转存临时文件（对齐 iOS `moveToTrash`：
  /// `POST {apiPds}/adrive/v2/file/delete`，需先取 drive_id）。
  Future<void> deleteFile({
    required String accessToken,
    required String fileId,
  }) async {
    final String driveId = await getDriveId(accessToken);
    final ({int status, Map<String, Object?>? json}) res = await _post(
      '$apiBase/adrive/v2/file/delete',
      headers: <String, String>{
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $accessToken',
      },
      body: <String, Object?>{
        'drive_id': driveId,
        'file_id': fileId,
      },
    );
    if (res.status != 200) {
      throw AliyunAdriveException('file/delete HTTP ${res.status}');
    }
  }

  // ─────────────── 内部：HTTP / JSON ───────────────

  Future<({int status, Map<String, Object?>? json})> _post(
    String url, {
    required Map<String, String> headers,
    required Map<String, Object?> body,
  }) async {
    final SpiderTransportResponse res = await _transport.send(
      SpiderTransportRequest(
        method: 'POST',
        url: Uri.parse(url),
        headers: headers,
        body: jsonEncode(body),
        timeout: const Duration(seconds: 30),
      ),
    );
    final String text = utf8.decode(res.bodyBytes, allowMalformed: true);
    Map<String, Object?>? json;
    try {
      final Object? decoded = jsonDecode(text);
      if (decoded is Map) json = decoded.cast<String, Object?>();
    } catch (_) {
      json = null;
    }
    return (status: res.status, json: json);
  }

  static Map<String, Object?>? _asMap(Object? v) =>
      v is Map ? v.cast<String, Object?>() : null;

  static String? _asString(Object? v) =>
      v is String ? v : (v is num ? '$v' : null);

  static int? _asInt(Object? v) =>
      v is int ? v : (v is num ? v.toInt() : int.tryParse('$v'));
}