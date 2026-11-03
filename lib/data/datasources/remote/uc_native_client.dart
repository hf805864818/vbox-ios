/// 数据层：UC 网盘原生分享链客户端（批次 F · F-P03，对齐 iOS
/// `CloudDriveManager` 的 UC 分支）。
///
/// 唯一真相源：`vbox/Services/CloudDriveManager.swift`
///   · `ucExtractShareInfo`（L8577）：分享链接 → `pwdId` / `passcode`；
///   · `ucAPIURL`（L8589）：`pc-api.uc.cn` 统一 query（`pr=UCBrowser&fr=pc&sys=darwin&ve=1.8.5`）；
///   · `ucSetCommonHeaders`（L8600）：Cookie / Origin / Referer / UA；
///   · `ucPlaybackHeaders`（L8612）：播放请求头；
///   · `ucGetShareToken`（L8677）：`POST /1/clouddrive/share/sharepage/token`；
///   · `ucGetShareDetail`（L8998）+ `ucCollectAllPlayableFiles`（L8975）：分页递归选集；
///   · `ucEnsureFolderWithCookie`（L8803）：确保根目录 `vbox` 存在；
///   · `ucFindExistingFileInVBox`（L8709）：同名文件去重；
///   · `ucSaveShare`（L8622）：`POST …/sharepage/save`；
///   · `ucGetPlayURL`（L9038）：`POST …/file/v2/play`（4k→low 选流）；
///   · `ucGetDownloadURL`（L9154）+ `stripCDNSpeedLimit`（L9185）：下载直链 + 去限速参数；
///   · `resolveUCPlayURL`（L8366）：主链编排。
///
/// 本批移植（NC-清2 / NC-清4，对齐 iOS）：
///   · **TV Token 通道**（`ucGetPlayURLWithTVToken` L9211 / `ucListFilesWithTVToken`
///     L9093）——`open-api-drive.uc.cn` 的 x-pan 签名（SHA256）+ `req_id`（MD5）
///     设备指纹；取链优先级 TV Token streaming（原片最高画质）> `v2/play`
///     （m3u8）> `download_url`；stoken 失效时作为选集兜底；
///   · **空间清理**（`ucDeleteFiles` L8903）——`POST /1/clouddrive/file/delete`
///     删除转存文件；转存链路按 iOS `resolveUCPlayResult` 登记 1 小时延迟清理。
///
/// 说明：**Set-Cookie 合并**分两层——HTTP 桥 `SpiderHttpBridge` 的 cookie jar
/// （`storeFromResponse` + 每请求按 `SpiderCookieMode.merge` 回带）负责跨请求保持；
/// `ensureFolder` 额外把响应 `Set-Cookie` 合并回写登录 Cookie（[mergeSetCookie]，
/// 服务端刷新值优先），对齐 iOS `quarkMergeSetCookie` / `ucEnsureFolderWithCookie`。
/// 历史缺陷：桥层曾无条件用 jar 覆盖显式 Cookie（问题 2），现已按合并策略修正。
///
/// ⚠️ 差异登记（TV Token 设备指纹）：iOS 用 `UIDevice.identifierForVendor`；
/// Flutter 无设备信息插件，本层用**每客户端实例稳定**的随机 32 位 hex
/// （随进程会话稳定，语义等价 `req_id` 只需同会话内一致）。
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart' as crypto;

import '../../../domain/entities/cloud/cloud_drive.dart';
import '../../../platform/spider/spider_http_bridge.dart';
import 'cloud_drive_cleanup_scheduler.dart';

/// UC 分享文件条目（对齐 iOS `UCShareFile`）。
class UcShareFile {
  /// 构造。
  const UcShareFile({
    required this.fid,
    required this.fileName,
    this.shareFidToken = '',
    this.pdirFid = '0',
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

/// UC 取链结果（对齐 iOS `PlayResult` 的 UC 子集：主线路 + 兜底线路）。
class UcPlayResult {
  /// 构造。
  const UcPlayResult({
    required this.url,
    required this.headers,
    required this.source,
    this.fallbackUrl,
    this.fallbackHeaders = const <String, String>{},
    this.fallbackSource = '',
  });

  /// 播放地址。
  final String url;

  /// 播放请求头（Cookie / UA / Referer / Origin / Accept）。
  final Map<String, String> headers;

  /// 取链来源标记：`uc_tv_token` / `v2-play` / `download_url`。
  final String source;

  /// 兜底线路地址（null 表示无兜底，对齐 iOS `PlayResult.fallbackURL`）。
  final String? fallbackUrl;

  /// 兜底线路请求头（对齐 iOS `PlayResult.fallbackHeaders`）。
  final Map<String, String> fallbackHeaders;

  /// 兜底线路来源标记（对齐 iOS `PlayResult.fallbackSource`）。
  final String fallbackSource;
}

/// UC 原生链异常（对齐 iOS `DriveError` 分档文案）。
class UcNativeException implements Exception {
  /// 构造。
  const UcNativeException(this.message);

  /// 文案。
  final String message;

  @override
  String toString() => 'UcNativeException($message)';
}

/// UC 原生分享链客户端。
class UcNativeClient {
  /// 构造（[bridge] 供测试注入假传输）。
  UcNativeClient({SpiderHttpBridge? bridge})
      : _bridge = bridge ?? SpiderHttpBridge();

  /// API 主机（对齐 iOS `ucAPIURL`）。
  static const String apiHost = 'https://pc-api.uc.cn';

  /// 播放清晰度优先级（对齐 iOS `ucGetPlayURL`：4k→low 降序）。
  static const List<String> qualityOrder = <String>[
    '4k', '2k', 'super', 'high', 'normal', 'low',
  ];

  /// 可播放扩展名（对齐 iOS `quarkIsPlayableFileName`，UC 复用同表）。
  static const List<String> playableExts = <String>[
    'mp4', 'mkv', 'mov', 'm3u8', 'avi', 'wmv', 'flv', 'ts', 'mp3', 'm4a',
  ];

  /// TV Token x-pan 签名密钥（对齐 iOS `ucGetPlayURLWithTVToken` 内联常量）。
  static const String tvSignKey = 'l3srvtd7p42l0d0x1u8d7yc8ye9kki4d';

  /// TV Token x-pan 客户端 ID（对齐 iOS 内联常量）。
  static const String tvClientId = '5acf882d27b74502b7040b0c65519aa7';

  /// TV Token 端点主机（对齐 iOS `open-api-drive.uc.cn`）。
  static const String tvApiHost = 'https://open-api-drive.uc.cn';

  /// TV Token 请求 UA（对齐 iOS 内联 UA）。
  static const String tvUserAgent =
      'Mozilla/5.0 (Linux; U; Android 13; zh-cn; M2004J7AC '
      'Build/UKQ1.231108.001) AppleWebKit/533.1 (KHTML, like Gecko) '
      'Mobile Safari/533.1';

  final SpiderHttpBridge _bridge;

  /// 转存后延迟清理调度（对齐 iOS `scheduleCleanup`；缺省不调度）。
  CloudDriveCleanupScheduler? cleanupScheduler;

  /// TV Token 设备指纹（每个客户端实例稳定；对齐 iOS `identifierForVendor`）。
  String? _deviceIdCache;

  // ─────────────── 静态工具（对齐 iOS 同名函数）───────────────

  /// 解析分享链接 → `(pwdId, passcode)`（对齐 iOS `ucExtractShareInfo`）。
  static ({String pwdId, String passcode}) extractShareInfo(String url) {
    String pwdId = '';
    final RegExpMatch? m = RegExp(r'/s/([^/?#]+)').firstMatch(url);
    if (m != null) {
      pwdId = m.group(1) ?? '';
    } else {
      pwdId = url.trim();
    }
    String passcode = '';
    final Uri? uri = Uri.tryParse(url);
    if (uri != null) {
      for (final MapEntry<String, String> e in uri.queryParameters.entries) {
        if (<String>['pwd', 'passcode', 'password']
            .contains(e.key.toLowerCase())) {
          passcode = e.value;
          break;
        }
      }
    }
    return (pwdId: pwdId, passcode: passcode);
  }

  /// 是否可播放文件（对齐 iOS `quarkIsPlayableFileName`）。
  static bool isPlayableFileName(String name) {
    final String lower = name.toLowerCase();
    return playableExts.any((String e) => lower.endsWith('.$e'));
  }

  /// 统一 API URL（对齐 iOS `ucAPIURL`）。
  static Uri apiUrl(String path, {List<(String, String)> extra = const []}) =>
      Uri.parse('$apiHost$path').replace(queryParameters: <String, String>{
        'pr': 'UCBrowser',
        'fr': 'pc',
        'sys': 'darwin',
        've': '1.8.5',
        for (final (String, String) e in extra) e.$1: e.$2,
      });

  /// 分享 Referer（对齐 iOS `ucShareReferer`）。
  static String shareReferer(String pwdId) => 'https://drive.uc.cn/s/$pwdId';

  /// 播放请求头（对齐 iOS `ucPlaybackHeaders`）。
  static Map<String, String> playbackHeaders(String cookie) => <String, String>{
        if (cookie.isNotEmpty) 'Cookie': cookie,
        'User-Agent':
            'Mozilla/5.0 (Linux; Android 12; HD1900 Build/SKQ1.211113.001; wv) '
                'AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 '
                'Chrome/97.0.4692.98 Mobile Safari/537.36',
        'Referer': 'https://drive.uc.cn/',
        'Origin': 'https://drive.uc.cn',
        'Accept': '*/*',
      };

  /// 去掉 CDN 下载/限速参数（对齐 iOS `stripCDNSpeedLimit`）。
  ///
  /// 仅对下载 CDN（`dl-c-` / 带 `response-content-disposition`）去 `sp` 限速；
  /// 流媒体 CDN 的 `sp` 是 profile ID，不可移除。
  ///
  /// 与 iOS 正则逐条替换的差异：这里按 query 参数逐个筛选，参数出现在首位
  /// 或末位同样能被移除，且不会残留 `?` / `&` 悬挂分隔符。
  static String stripCdnSpeedLimit(String url) {
    final int q = url.indexOf('?');
    if (q < 0) return url;
    final bool isDownloadCdn =
        url.contains('dl-c-') || url.contains('response-content-disposition');
    final int hash = url.indexOf('#', q);
    final String base = url.substring(0, q);
    final String query =
        hash < 0 ? url.substring(q + 1) : url.substring(q + 1, hash);
    final String fragment = hash < 0 ? '' : url.substring(hash);
    final List<String> kept = <String>[];
    for (final String part in query.split('&')) {
      if (part.isEmpty) continue;
      final int eq = part.indexOf('=');
      final String key = (eq < 0 ? part : part.substring(0, eq)).toLowerCase();
      if (key == 'response-content-disposition') continue;
      if (key == 'x-oss-traffic-limit') continue;
      if (key == 'sp' && isDownloadCdn) continue;
      kept.add(part);
    }
    if (kept.isEmpty) return '$base$fragment';
    return '$base?${kept.join('&')}$fragment';
  }

  /// 统一请求头（对齐 iOS `ucSetCommonHeaders`）。
  Map<String, String> _commonHeaders(String cookie, {String? referer}) =>
      <String, String>{
        'Content-Type': 'application/json',
        if (cookie.isNotEmpty) 'Cookie': cookie,
        'Origin': 'https://drive.uc.cn',
        'Referer': referer ?? 'https://drive.uc.cn/',
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                '(KHTML, like Gecko) uc-cloud-drive/1.8.5 '
                'Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 '
                'Safari/537.36 Channel/ucpan_other_ch',
      };

  static int _nowMs() => DateTime.now().millisecondsSinceEpoch;

  /// Cookie 属性名黑名单（对齐 iOS `quarkMergeSetCookie` 的字典合并语义）。
  static const Set<String> _cookieAttributes = <String>{
    'expires', 'path', 'domain', 'max-age', 'secure', 'httponly', 'samesite',
  };

  /// 合并响应 `Set-Cookie` 到当前 Cookie（服务端值覆盖，对齐 iOS `quarkMergeSetCookie`）。
  ///
  /// 问题 2 修复 B：补齐 iOS 已有的 Cookie 刷新回写能力。`Set-Cookie` 可能以
  /// `, ` 连接多值，先归一为 `;` 再逐项合并；属性名忽略，后到覆盖。
  static String mergeSetCookie(String cookie, List<String> setCookies) {
    if (setCookies.isEmpty) return cookie;
    final List<String> keys = <String>[];
    final Map<String, (String, String)> values = <String, (String, String)>{};
    void ingest(String raw) {
      if (raw.isEmpty) return;
      final String normalized = raw
          .replaceAllMapped(
            RegExp(r',\s*([A-Za-z_][A-Za-z0-9_\-]*)='),
            (Match m) => ';\n${m.group(1)}=',
          )
          .replaceAll('\n', ';');
      for (final String part in normalized.split(';')) {
        final String item = part.trim();
        final int eq = item.indexOf('=');
        if (eq <= 0) continue;
        final String name = item.substring(0, eq).trim();
        final String value = item.substring(eq + 1).trim();
        if (name.isEmpty || value.isEmpty) continue;
        final String key = name.toLowerCase();
        if (_cookieAttributes.contains(key)) continue;
        if (!values.containsKey(key)) keys.add(key);
        values[key] = (name, value);
      }
    }

    ingest(cookie);
    for (final String sc in setCookies) {
      ingest(sc);
    }
    return keys
        .where(values.containsKey)
        .map((String k) => '${values[k]!.$1}=${values[k]!.$2}')
        .join('; ');
  }

  // ─────────────── 分享 token / 文件列表 ───────────────

  /// 获取分享 `stoken`（对齐 iOS `ucGetShareToken`）。
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
        data: jsonEncode(<String, Object?>{'pwd_id': pwdId, 'passcode': passcode}),
      ),
    );
    final Map<String, Object?>? json = _decodeMap(res.content);
    if (json == null) {
      throw const UcNativeException('UC 分享 token 响应异常');
    }
    final int code = _asInt(json['code']) ?? 0;
    if (code != 0) {
      throw UcNativeException(
        'UC 分享 token 获取失败：${_asString(json['message']) ?? 'code=$code'}',
      );
    }
    final String st = _asString(_asMap(json['data'])?['stoken']) ?? '';
    if (st.isEmpty) throw const UcNativeException('UC 未返回 stoken');
    return st;
  }

  /// 单页分享文件列表（对齐 iOS `ucGetShareDetail`）。
  Future<List<UcShareFile>> getShareDetail({
    required String pwdId,
    required String stoken,
    required String pdirFid,
    required String cookie,
    int page = 1,
    int size = 100,
  }) async {
    final Uri url = apiUrl(
      '/1/clouddrive/share/sharepage/detail',
      extra: <(String, String)>[
        ('__t', '${_nowMs()}'),
        ('_fetch_banner', '1'),
        ('_fetch_total', '1'),
        ('_page', '$page'),
        ('_size', '$size'),
        ('_sort', 'file_type:asc,file_name:asc'),
        ('pdir_fid', pdirFid),
        ('pwd_id', pwdId),
        ('stoken', stoken),
      ],
    );
    final SpiderHttpResult res = await _bridge.request(
      url.toString(),
      options: SpiderHttpOptions(
        headers: _commonHeaders(cookie, referer: shareReferer(pwdId)),
      ),
    );
    final Map<String, Object?>? json = _decodeMap(res.content);
    if (json == null) throw const UcNativeException('UC 文件列表响应异常');
    final int code = _asInt(json['code']) ?? 0;
    if (code != 0) {
      throw UcNativeException(
        'UC 文件列表失败：${_asString(json['message']) ?? 'code=$code'}',
      );
    }
    final Object? list = _asMap(json['data'])?['list'];
    if (list is! List) throw const UcNativeException('UC 文件列表为空');
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
          final bool isDir =
              dirFlag ?? (fileFlag == false && fileType == 0);
          return UcShareFile(
            fid: fid,
            fileName: name,
            shareFidToken: token,
            pdirFid: pdirFid,
            isDir: isDir,
          );
        })
        .where((UcShareFile f) => f.fid.isNotEmpty && f.fileName.isNotEmpty)
        .toList(growable: false);
  }

  /// 递归收集全部可播放文件（对齐 iOS `ucCollectAllPlayableFiles`）。
  Future<List<UcShareFile>> collectAllPlayableFiles({
    required String pwdId,
    required String stoken,
    required String cookie,
    String pdirFid = '0',
    int maxPages = 20,
  }) async {
    final List<UcShareFile> out = <UcShareFile>[];
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
    required List<UcShareFile> out,
    required int maxPages,
  }) async {
    int page = 1;
    bool hasMore = true;
    while (hasMore) {
      final List<UcShareFile> files = await getShareDetail(
        pwdId: pwdId,
        stoken: stoken,
        pdirFid: pdirFid,
        cookie: cookie,
        page: page,
      );
      for (final UcShareFile f in files) {
        if (!f.isDir && isPlayableFileName(f.fileName)) out.add(f);
      }
      for (final UcShareFile dir in files.where((UcShareFile f) => f.isDir)) {
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

  /// 分享链接 → 全部可播放文件（对齐 iOS `ucGetFileList`，三层容错 + TV 兜底）。
  ///
  /// 三层容错：刷新 Cookie → stoken 失效重试 → 明确报错；若提供 [tvToken]，
  /// 第三层失败后按 iOS `ucResolveUCShareFile` 走 TV Token 兜底列表。
  Future<List<UcShareFile>> getFileList({
    required String shareUrl,
    required String cookie,
    String? tvToken,
  }) async {
    final ({String pwdId, String passcode}) info = extractShareInfo(shareUrl);
    if (info.pwdId.isEmpty) {
      throw const UcNativeException('无法识别的分享链接');
    }
    // 第一层：刷新 Cookie（失败则用原始 Cookie 继续）。
    String authCookie = cookie;
    try {
      authCookie = (await ensureFolder(cookie: cookie)).mergedCookie;
    } on UcNativeException {
      // 忽略（对齐 iOS：ensureFolder 失败仍继续尝试）。
    }
    final String stoken = await getShareToken(
      pwdId: info.pwdId,
      passcode: info.passcode,
      cookie: authCookie,
    );
    // 第二层：stoken 失效刷新重试；第三层：TV Token 兜底 → 明确报错。
    try {
      return await _collectWithRetry(
        pwdId: info.pwdId,
        passcode: info.passcode,
        stoken: stoken,
        cookie: authCookie,
      );
    } on UcNativeException {
      if (tvToken == null || tvToken.isEmpty) rethrow;
      final List<UcShareFile> tvFiles =
          await listFilesWithTVToken(tvToken: tvToken);
      final List<UcShareFile> playable = tvFiles
          .where((UcShareFile f) => !f.isDir && isPlayableFileName(f.fileName))
          .toList(growable: false);
      if (playable.isEmpty) rethrow;
      return playable;
    }
  }

  Future<List<UcShareFile>> _collectWithRetry({
    required String pwdId,
    required String passcode,
    required String stoken,
    required String cookie,
  }) async {
    try {
      return await collectAllPlayableFiles(
        pwdId: pwdId,
        stoken: stoken,
        cookie: cookie,
      );
    } on UcNativeException catch (e) {
      if (!_isTokenError(e.message)) rethrow;
      final String newStoken = await getShareToken(
        pwdId: pwdId,
        passcode: passcode,
        cookie: cookie,
      );
      try {
        return await collectAllPlayableFiles(
          pwdId: pwdId,
          stoken: newStoken,
          cookie: cookie,
        );
      } on UcNativeException {
        throw const UcNativeException('UC Cookie 已过期，请重新扫码登录');
      }
    }
  }

  static bool _isTokenError(String message) =>
      message.contains('非法token') || message.contains('token');

  // ─────────────── 转存（vbox 目录 + 去重 + save）───────────────

  /// 确保根目录 `vbox` 存在，返回 `(fid, mergedCookie)`（对齐 iOS `ucEnsureFolderWithCookie`）。
  ///
  /// 返回的 `mergedCookie` 已把各响应 `Set-Cookie` 合并回写（服务端刷新值优先），
  /// 供后续请求复用——补齐 iOS 已有的 Cookie 刷新回写能力（问题 2 修复 B）。
  Future<({String fid, String mergedCookie})> ensureFolder({
    required String cookie,
  }) async {
    final List<(String, String)> sortQuery = <(String, String)>[
      ('pdir_fid', '0'),
      ('_sort', 'file_type:asc,file_name:asc'),
      ('_page', '1'),
      ('_size', '100'),
      ('_fetch_total', '1'),
    ];
    String currentCookie = cookie;
    final ({Map<String, Object?>? json, List<String> setCookies}) listRaw =
        await _fileSortRaw(cookie: currentCookie, query: sortQuery);
    currentCookie = mergeSetCookie(currentCookie, listRaw.setCookies);
    _throwIfInvalidCookie(listRaw.json, 'list');
    final String? found = _findVboxFid(listRaw.json);
    if (found != null) return (fid: found, mergedCookie: currentCookie);

    // 创建 vbox
    final SpiderHttpResult createRes = await _bridge.request(
      apiUrl('/1/clouddrive/file').toString(),
      options: SpiderHttpOptions(
        method: 'POST',
        headers: _commonHeaders(currentCookie),
        data: jsonEncode(<String, Object?>{
          'pdir_fid': '0',
          'file_name': 'vbox',
          'dir': true,
          'dir_path': '',
        }),
      ),
    );
    currentCookie = mergeSetCookie(currentCookie, createRes.setCookies);
    final Map<String, Object?>? createJson = _decodeMap(createRes.content);
    if (createJson != null) {
      final int code = _asInt(createJson['code']) ?? 0;
      if (code == 0) {
        final String fid =
            _asString(_asMap(createJson['data'])?['fid']) ?? '';
        if (fid.isNotEmpty) return (fid: fid, mergedCookie: currentCookie);
      } else if (code != 23008) {
        throw UcNativeException(
          'UC: Cookie 可能已失效，请重新登录 (create code=$code '
          'msg=${_asString(createJson['message']) ?? ''})',
        );
      }
    }

    // 已存在（code=23008）→ 重新 list
    final ({Map<String, Object?>? json, List<String> setCookies}) reRaw =
        await _fileSortRaw(cookie: currentCookie, query: sortQuery);
    currentCookie = mergeSetCookie(currentCookie, reRaw.setCookies);
    _throwIfInvalidCookie(reRaw.json, 're-list');
    final String? reFound = _findVboxFid(reRaw.json);
    if (reFound != null) return (fid: reFound, mergedCookie: currentCookie);
    throw const UcNativeException('UC: 无法找到或创建 vbox 文件夹');
  }

  Future<Map<String, Object?>?> _fileSort({
    required String cookie,
    required List<(String, String)> query,
  }) async =>
      (await _fileSortRaw(cookie: cookie, query: query)).json;

  /// 文件列表请求，附带响应 `Set-Cookie`（供 Cookie 刷新回写，问题 2 修复 B）。
  Future<({Map<String, Object?>? json, List<String> setCookies})> _fileSortRaw({
    required String cookie,
    required List<(String, String)> query,
  }) async {
    final SpiderHttpResult res = await _bridge.request(
      apiUrl('/1/clouddrive/file/sort', extra: query).toString(),
      options: SpiderHttpOptions(headers: _commonHeaders(cookie)),
    );
    return (json: _decodeMap(res.content), setCookies: res.setCookies);
  }

  void _throwIfInvalidCookie(Map<String, Object?>? json, String stage) {
    if (json == null) return;
    final int code = _asInt(json['code']) ?? 0;
    if (code == 10001 || code == 10002 || code == 10003) {
      throw UcNativeException('UC: Cookie 可能已失效，请重新登录 ($stage code=$code)');
    }
  }

  /// 在 `data.list` / `data`（数组）中查 `vbox` 目录 fid。
  static String? _findVboxFid(Map<String, Object?>? json) {
    if (json == null) return null;
    final Object? data = json['data'];
    final Object? list = data is Map ? data['list'] : data;
    if (list is! List) return null;
    for (final Object? raw in list) {
      final Map<String, Object?>? f = _asMap(raw);
      if (f == null) continue;
      if (_asString(f['file_name']) == 'vbox') {
        final String fid = _asString(f['fid']) ?? '';
        if (fid.isNotEmpty) return fid;
      }
    }
    return null;
  }

  /// 检查 vbox 目录中是否已有同名文件（对齐 iOS `ucFindExistingFileInVBox`）。
  Future<String?> findExistingFileInVBox({
    required String fileName,
    required String folderId,
    required String cookie,
  }) async {
    final Map<String, Object?>? json = await _fileSort(
      cookie: cookie,
      query: <(String, String)>[
        ('pdir_fid', folderId),
        ('_sort', 'file_type:asc,file_name:asc'),
        ('_page', '1'),
        ('_size', '50'),
        ('_fetch_total', '1'),
      ],
    );
    if (json == null) return null;
    final Object? data = json['data'];
    final Object? list = data is Map ? data['list'] : data;
    if (list is! List) return null;
    for (final Object? raw in list) {
      final Map<String, Object?>? f = _asMap(raw);
      if (f == null) continue;
      if (_asString(f['file_name']) == fileName) {
        final String fid = _asString(f['fid']) ?? '';
        if (fid.isNotEmpty) return fid;
      }
    }
    return null;
  }

  /// 转存分享文件到 `folderId`，返回顶层 fid 列表（对齐 iOS `ucSaveShare`）。
  Future<List<String>> saveShare({
    required String pwdId,
    required String stoken,
    required UcShareFile file,
    required String folderId,
    required String cookie,
  }) async {
    final SpiderHttpResult res = await _bridge.request(
      apiUrl(
        '/1/clouddrive/share/sharepage/save',
        extra: <(String, String)>[('__t', '${_nowMs()}')],
      ).toString(),
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
        }),
      ),
    );
    final Map<String, Object?>? json = _decodeMap(res.content);
    if (json == null) throw const UcNativeException('UC 转存失败：响应异常');
    final int status = _asInt(json['status']) ?? 0;
    if (status != 200 && status != 0) {
      throw UcNativeException(
        'UC 转存失败：${_asString(json['message']) ?? _asString(json['msg']) ?? '状态码：$status'}',
      );
    }
    final int code = _asInt(json['code']) ?? 0;
    if (code != 0) {
      throw UcNativeException(
        'UC 转存失败：${_asString(json['message']) ?? _asString(json['msg']) ?? '错误码：$code'}',
      );
    }
    final List<String> ids = _extractSavedFids(_asMap(json['data']));
    if (ids.isEmpty) {
      throw const UcNativeException('UC 转存成功但未返回已转存 fid');
    }
    return ids;
  }

  List<String> _extractSavedFids(Map<String, Object?>? data) {
    if (data == null) return const <String>[];
    final Map<String, Object?>? taskResp = _asMap(data['task_resp']);
    final Map<String, Object?>? taskData = _asMap(taskResp?['data']);
    final Map<String, Object?>? saveAs = _asMap(taskData?['save_as']);
    for (final String key in <String>[
      'save_as_top_fids',
      'save_as_select_top_fids',
    ]) {
      final Object? ids = saveAs?[key];
      if (ids is List && ids.isNotEmpty) {
        return ids.map((Object? e) => '$e').toList(growable: false);
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

  // ─────────────── 取链 ───────────────

  /// `POST …/file/v2/play` 转码流（对齐 iOS `ucGetPlayURL`，4k→low 选流）。
  Future<String> getPlayUrl({
    required String fileId,
    required String cookie,
  }) async {
    final SpiderHttpResult res = await _bridge.request(
      apiUrl(
        '/1/clouddrive/file/v2/play',
        extra: <(String, String)>[
          ('pr', 'UCBrowser'),
          ('fr', 'pc'),
          ('sys', 'ios'),
          ('ve', '1.8.5'),
        ],
      ).toString(),
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
    if (json == null) throw const UcNativeException('UC v2/play 响应异常');
    final int code = _asInt(json['code']) ?? 0;
    if (code != 0) {
      throw UcNativeException(
        'UC v2/play 失败: ${_asString(json['message']) ?? 'code=$code'}',
      );
    }
    final Object? videos = _asMap(json['data'])?['video_list'];
    if (videos is List) {
      for (final String quality in qualityOrder) {
        for (final Object? item in videos) {
          final Map<String, Object?>? m = _asMap(item);
          if (m == null) continue;
          final Map<String, Object?>? info = _asMap(m['video_info']);
          if (_asString(info?['resolution']) != quality) continue;
          final bool accessable = m['accessable'] as bool? ?? true;
          final String u = _asString(info?['url']) ?? '';
          if (accessable && u.isNotEmpty) return u;
        }
      }
    }
    final String playUrl =
        _asString(_asMap(json['data'])?['play_url']) ??
            _asString(json['play_url']) ??
            '';
    if (playUrl.isNotEmpty) return playUrl;
    throw const UcNativeException('UC: 未返回播放地址');
  }

  /// `POST …/file/download` 下载直链（对齐 iOS `ucGetDownloadURL` + 去限速）。
  Future<String> getDownloadUrl({
    required String fileId,
    required String cookie,
  }) async {
    final SpiderHttpResult res = await _bridge.request(
      apiUrl('/1/clouddrive/file/download').toString(),
      options: SpiderHttpOptions(
        method: 'POST',
        headers: _commonHeaders(cookie),
        data: jsonEncode(<String, Object?>{
          'fids': <String>[fileId],
        }),
      ),
    );
    final Map<String, Object?>? json = _decodeMap(res.content);
    if (json == null) throw const UcNativeException('UC download_url 响应异常');
    final int code = _asInt(json['code']) ?? 0;
    if (code != 0) {
      throw UcNativeException(
        'UC download_url 获取失败：${_asString(json['message']) ?? 'code=$code'}',
      );
    }
    final Object? data = json['data'];
    if (data is List && data.isNotEmpty) {
      final String u = _asString(_asMap(data.first)?['download_url']) ?? '';
      if (u.isNotEmpty) return stripCdnSpeedLimit(u);
    }
    final String u = _asString(_asMap(data)?['download_url']) ?? '';
    if (u.isNotEmpty) return stripCdnSpeedLimit(u);
    return '';
  }

  // ─────────────── TV Token 通道（NC-清4，对齐 iOS
  //                 `ucGetPlayURLWithTVToken` / `ucListFilesWithTVToken`）───────────────

  /// TV Token 稳定设备指纹（32 位 hex；对齐 iOS `identifierForVendor` 去横线）。
  String _deviceId() =>
      _deviceIdCache ??= List<String>.generate(
        32,
        (_) => math.Random.secure().nextInt(16).toRadixString(16),
      ).join();

  /// x-pan 签名 token（对齐 iOS：`SHA256("GET&/file&<tm>&<signKey>")`）。
  static String _xPanToken(String timestamp) => crypto.sha256
      .convert(utf8.encode('GET&/file&$timestamp&$tvSignKey'))
      .toString();

  /// `req_id`（对齐 iOS：`MD5(deviceId + timestamp)`）。
  static String _tvReqId(String deviceId, String timestamp) =>
      crypto.md5.convert(utf8.encode('$deviceId$timestamp')).toString();

  /// TV Token 通用请求头（对齐 iOS x-pan 三件套 + Accept + UA）。
  Map<String, String> _tvHeaders(String timestamp) => <String, String>{
        'Accept': 'application/json, text/plain, */*',
        'x-pan-client-id': tvClientId,
        'x-pan-tm': timestamp,
        'x-pan-token': _xPanToken(timestamp),
        'User-Agent': tvUserAgent,
      };

  /// TV Token 设备指纹查询参数（对齐 iOS `components.queryItems` 公共段，iOS 端
  /// `device_*` 固定为 Apple/iPhone 口径）。
  Map<String, String> _tvDeviceQuery(String deviceId, String reqId) =>
      <String, String>{
        'app_ver': '1.6.8',
        'device_id': deviceId,
        'device_brand': 'Apple',
        'platform': 'tv',
        'device_name': 'iPhone',
        'device_model': 'iPhone',
        'build_device': 'iPhone',
        'build_product': 'iPhone',
        'device_gpu': 'Apple',
        'activity_rect': '{}',
        'channel': 'UCTVOFFICIALWEB',
        'req_id': reqId,
      };

  /// 用 TV Token 列举云盘文件（对齐 iOS `ucListFilesWithTVToken`）。
  ///
  /// 用于 stoken 失效时的兜底选集：`GET /file?method=list`（签名走 [tvHeaders]）。
  Future<List<UcShareFile>> listFilesWithTVToken({
    required String tvToken,
    String parentFid = '0',
  }) async {
    final String timestamp = '${_nowMs()}';
    final String deviceId = _deviceId();
    final Uri url = Uri.parse('$tvApiHost/file').replace(
      queryParameters: <String, String>{
        'method': 'list',
        'parent_fid': parentFid,
        'order_by': '3',
        'desc': '1',
        'category': '',
        'source': '',
        'ex_source': '',
        'list_all': '0',
        'page_size': '100',
        'page_index': '0',
        'access_token': tvToken,
        ..._tvDeviceQuery(deviceId, _tvReqId(deviceId, timestamp)),
      },
    );
    final SpiderHttpResult res = await _bridge.request(
      url.toString(),
      options: SpiderHttpOptions(headers: _tvHeaders(timestamp)),
    );
    final Map<String, Object?>? json = _decodeMap(res.content);
    if (json == null) throw const UcNativeException('TV Token 列表响应异常');
    final int? status = _asInt(json['status']);
    if (status == -1) {
      throw UcNativeException(
        'TV Token 列表失败：${_asString(json['error_info']) ?? 'status=-1'}',
      );
    }
    final Object? files = _asMap(json['data'])?['files'];
    if (files is! List) return const <UcShareFile>[];
    return files
        .whereType<Map<Object?, Object?>>()
        .map((Map<Object?, Object?> raw) {
          final Map<String, Object?> item = raw.cast<String, Object?>();
          return UcShareFile(
            fid: _asString(item['fid']) ?? '',
            fileName:
                _asString(item['filename']) ?? _asString(item['file_name']) ?? '',
            isDir: (_asInt(item['isdir']) ?? 0) == 1,
          );
        })
        .where((UcShareFile f) => f.fid.isNotEmpty && f.fileName.isNotEmpty)
        .toList(growable: false);
  }

  /// 用 TV Token 取原片流媒体直链（对齐 iOS `ucGetPlayURLWithTVToken`）。
  ///
  /// `GET /file?method=streaming`（x-pan 签名）：原片最高画质、不限速。返回
  /// 地址已去 CDN 限速参数；`errno=10001 && status=-1` 视为 Token 过期。
  Future<String> getPlayUrlWithTVToken({
    required String fileId,
    required String tvToken,
  }) async {
    final String timestamp = '${_nowMs()}';
    final String deviceId = _deviceId();
    final Uri url = Uri.parse('$tvApiHost/file').replace(
      queryParameters: <String, String>{
        'method': 'streaming',
        'group_by': 'source',
        'fid': fileId,
        'resolution': 'low,normal,high,super,2k,4k',
        'support': 'dolby_vision',
        'access_token': tvToken,
        ..._tvDeviceQuery(deviceId, _tvReqId(deviceId, timestamp)),
      },
    );
    final SpiderHttpResult res = await _bridge.request(
      url.toString(),
      options: SpiderHttpOptions(headers: _tvHeaders(timestamp)),
    );
    final Map<String, Object?>? json = _decodeMap(res.content);
    if (json == null) throw const UcNativeException('TV Token streaming 响应异常');
    final int? status = _asInt(json['status']);
    if (status == -1 && _asInt(json['errno']) == 10001) {
      throw const UcNativeException('TV Token 已过期，请重新授权 TV');
    }
    if (status == -1) {
      throw UcNativeException(
        'UCTV Token 获取播放地址失败：${_asString(json['error_info']) ?? _asString(json['message']) ?? 'status=-1'}',
      );
    }
    final Map<String, Object?>? data = _asMap(json['data']);
    if (data != null) {
      for (final String key in <String>[
        'download_url',
        'stream_url',
        'url',
        'play_url',
      ]) {
        final String u = _asString(data[key]) ?? '';
        if (u.isNotEmpty) return stripCdnSpeedLimit(u);
      }
      // streaming 端点：video_info 直接在 data 下。
      final Object? videoInfo = data['video_info'];
      if (videoInfo is List) {
        for (final Object? item in videoInfo) {
          final String u = _asString(_asMap(item)?['url']) ?? '';
          if (u.isNotEmpty) return stripCdnSpeedLimit(u);
        }
      }
      // download 端点：video_list 嵌套 video_info。
      final Object? videoList = data['video_list'];
      if (videoList is List) {
        for (final Object? item in videoList) {
          final String u =
              _asString(_asMap(_asMap(item)?['video_info'])?['url']) ?? '';
          if (u.isNotEmpty) return stripCdnSpeedLimit(u);
        }
      }
    }
    throw const UcNativeException('UCTV Token 返回中未找到播放地址');
  }

  // ─────────────── 空间清理（NC-清2，对齐 iOS `ucDeleteFiles`）───────────────

  /// 删除转存文件（对齐 iOS `ucDeleteFiles`）。
  ///
  /// 返回提交删除的文件数（iOS 忽略响应结果，本层同样不解析）。
  Future<int> deleteFiles({
    required List<String> fileIds,
    required String cookie,
  }) async {
    if (fileIds.isEmpty) return 0;
    await _bridge.request(
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
    return fileIds.length;
  }

  /// 分享链接 → 取链（对齐 iOS `resolveUCPlayURL` 主链）。
  ///
  /// 取链优先级：TV Token streaming（原片最高画质）> `v2/play`（m3u8）>
  /// `download_url`；转存后按 iOS `resolveUCPlayResult` 登记 1 小时延迟清理。
  Future<UcPlayResult> resolvePlayUrl({
    required String shareUrl,
    required String cookie,
    String? preferredFid,
    String? tvToken,
  }) async {
    final ({String pwdId, String passcode}) info = extractShareInfo(shareUrl);
    if (info.pwdId.isEmpty) {
      throw const UcNativeException('无法识别的分享链接');
    }
    final ({String fid, String mergedCookie}) folder =
        await ensureFolder(cookie: cookie);
    final String folderId = folder.fid;
    final String authCookie = folder.mergedCookie;
    final String stoken = await getShareToken(
      pwdId: info.pwdId,
      passcode: info.passcode,
      cookie: authCookie,
    );

    // 选集：正常路径失败 → TV Token 兜底（对齐 iOS `ucResolveUCShareFile`）。
    List<UcShareFile> files;
    try {
      files = await _collectWithRetry(
        pwdId: info.pwdId,
        passcode: info.passcode,
        stoken: stoken,
        cookie: authCookie,
      );
    } on UcNativeException {
      if (tvToken == null || tvToken.isEmpty) rethrow;
      files = await listFilesWithTVToken(tvToken: tvToken);
    }
    final List<UcShareFile> playable = files
        .where((UcShareFile f) => !f.isDir && isPlayableFileName(f.fileName))
        .toList(growable: false);
    if (playable.isEmpty) {
      throw const UcNativeException('UC 分享内未找到可播放视频');
    }
    final UcShareFile source =
        (preferredFid != null && preferredFid.isNotEmpty)
            ? playable.firstWhere(
                (UcShareFile f) => f.fid == preferredFid,
                orElse: () => playable.first,
              )
            : playable.first;

    // 转存前查重，避免重复转存（对齐 iOS `ucResolveUCShareFile.trySave`）。
    final String? existing = await findExistingFileInVBox(
      fileName: source.fileName,
      folderId: folderId,
      cookie: authCookie,
    );
    final List<String> savedFids;
    if (existing != null) {
      savedFids = <String>[existing];
    } else {
      savedFids = await saveShare(
        pwdId: info.pwdId,
        stoken: stoken,
        file: source,
        folderId: folderId,
        cookie: authCookie,
      );
    }
    final String fileId = savedFids.first;

    String transcode = '';
    try {
      transcode = await getPlayUrl(fileId: fileId, cookie: authCookie);
    } on UcNativeException {
      // 忽略，继续降级。
    }
    String download = '';
    try {
      download = await getDownloadUrl(fileId: fileId, cookie: authCookie);
    } on UcNativeException {
      // 忽略，可能 v2/play 已可用。
    }

    // 优先级：TV Token streaming（原片最高画质）> v2/play（m3u8）> download_url。
    String url = '';
    String sourceTag = '';
    if (tvToken != null && tvToken.isNotEmpty) {
      try {
        url = await getPlayUrlWithTVToken(fileId: fileId, tvToken: tvToken);
        sourceTag = 'uc_tv_token';
      } on UcNativeException {
        // 忽略，降级到 v2/play。
      }
    }
    if (url.isEmpty && transcode.isNotEmpty) {
      url = transcode;
      sourceTag = 'v2-play';
    }
    if (url.isEmpty) {
      url = download;
      sourceTag = 'download_url';
    }
    if (url.isEmpty) {
      throw const UcNativeException('UC: download_url、转码地址和 UCTV Token 兜底均为空');
    }

    // 转存成功后登记 1 小时延迟清理（对齐 iOS `resolveUCPlayResult`）。
    if (existing == null) {
      await cleanupScheduler?.schedule(
        drive: CloudDriveType.uc,
        fileIds: savedFids,
        delay: const Duration(hours: 1),
      );
    }

    // TV Token CDN 直链不传自定义 Header（对齐 iOS：让播放器原生网络栈处理
    // Range）；v2/play 与 download_url 需 UC Cookie 头。
    final Map<String, String> headers = sourceTag == 'uc_tv_token'
        ? const <String, String>{}
        : playbackHeaders(authCookie);
    // 兜底线路派生（对齐 iOS `resolveUCPlayResult` 的 switch 拓扑）：
    //   · uc_tv_token → 优先转码 v2-play，其次 download_url；
    //   · v2-play     → download_url；
    //   · download_url→ 无兜底。
    String? fallbackUrl;
    String fallbackSource = '';
    Map<String, String> fallbackHeaders = const <String, String>{};
    if (sourceTag == 'uc_tv_token') {
      if (transcode.isNotEmpty) {
        fallbackUrl = transcode;
        fallbackSource = 'v2-play';
      } else if (download.isNotEmpty) {
        fallbackUrl = download;
        fallbackSource = 'download_url';
      }
      if (fallbackUrl != null) fallbackHeaders = playbackHeaders(authCookie);
    } else if (sourceTag == 'v2-play') {
      if (download.isNotEmpty) {
        fallbackUrl = download;
        fallbackSource = 'download_url';
        fallbackHeaders = headers;
      }
    }
    return UcPlayResult(
      url: url,
      headers: headers,
      source: sourceTag,
      fallbackUrl: fallbackUrl,
      fallbackHeaders: fallbackHeaders,
      fallbackSource: fallbackSource,
    );
  }

  // ─────────────── JSON 助手 ───────────────

  static Map<String, Object?>? _decodeMap(String body) {
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

  static String? _asString(Object? v) =>
      v is String ? v : (v is num ? '$v' : null);

  static int? _asInt(Object? v) =>
      v is int ? v : (v is num ? v.toInt() : int.tryParse('$v'));
}