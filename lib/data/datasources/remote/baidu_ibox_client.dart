/// 数据层：百度网盘 iBox 本机链客户端（批次 F · F-P02，C1 + C2 段）。
///
/// 唯一真相源：`vbox/Services/CloudDriveManager.swift`
///   · C1：`parseBaiduToken`（L4471）粘贴串 → (cookie, BDUSS)；
///     `baiduMergeCookieStrings`（L5619）多段 Cookie 合并（忽略属性名）；
///     `baiduErrorMessage`（L5391）errno → 中文文案；
///     `baiduExtractShareMeta`（L5906-L6376）分享验证链
///     `wap/init → (share/verify) → 桌面分享页 → gettemplatevariable → share/list(root + dirs)`；
///   · C2：`baiduFetchUserBdstokenLocal`（L4684）用户态 bdstoken；
///     `baiduEnsureVboxFolderLocal`（L4832）建 `/vbox` 转存目录；
///     `baiduFindExistingVboxPath`（L5034）/`baiduWaitForTransferredPath`（L5147）落盘确认；
///     `baiduTransferFileOnDevice`（L5169）`share/transfer` 转存；
///     `baiduRefreshTransferSekey`（L5320）账号态 verify 刷新 sekey；
///     `baiduGetDLNADlinkOnDevice`（L5429）`api/mediainfo` DLNA 取链；
///     `baiduGetLocatedownloadOnDevice`（L5477）`pcs/file?method=locatedownload` 原画取链。
///
/// C1 只做**分享上下文 + 多文件选集列表**；C2 补**转存链（建目录/转存/等待落盘）+
/// DLNA 取链（mediainfo/locatedownload）**；WebView 回退见 C3（Web-R1）。
///
/// 实现说明（对齐口径）：直接使用 [SpiderHttpTransport]（**不经** `SpiderHttpBridge`
/// 的 cookie jar）——因为 iOS 明确要求 `share/verify` **不带任何 Cookie**，而桥层会
/// 自动附加 jar cookie；传输层同时显式返回 `setCookies`，便于按 iOS
/// `baiduMergeCookieStrings` 语义手动合并。
///
/// 未移植项（如实登记）：iOS 在 URLSession 失败时回退 WKWebView XHR
/// （create/list/transfer/bdstoken）——属 C3（Web-R1），本段不实现，失败即抛错。
///
/// C3 回退点（对齐 iOS 调用点，待 WebView 桥接入后逐点补）：
///   · `fetchUserBdstoken` ← `baiduFetchUserBdstokenViaWebView`（CloudDriveManager L4724）；
///   · `ensureTransferDir`  ← `baiduCreateFolderViaWebView`（L4873）+ `baiduCanListTransferDirViaWebView`（L4885）；
///   · `findExistingVboxPath` ← `baiduFindExistingVboxPathViaWebView`（L5077/L5083/L5088）；
///   · `transferFile`       ← `baiduTransferFileViaWebView`（L5224/L5240）。
library;

import 'dart:convert';
import 'dart:io' show Platform;

import '../../../core/utils/logger.dart';
import '../../../platform/node/node_runtime_manager.dart';
import '../../../platform/spider/spider_http_bridge.dart';
import '../../../platform/webview/baidu_native_token_bridge.dart';
import '../../../platform/webview/webview_bridge.dart';
import '../local/baidu_playback_cache_store.dart';
import '../local/prefs_manager.dart';
import 'node_login_client.dart';

/// 百度分享文件条目（对齐 iOS `BaiduFileItem`）。
class BaiduFileItem {
  /// 构造。
  const BaiduFileItem({required this.fsId, required this.name});

  /// 文件 ID。
  final String fsId;

  /// 文件名。
  final String name;

  /// 是否可播放视频（对齐 iOS `baiduIsPlayableVideoFileName`）。
  bool get isPlayableVideo =>
      BaiduIBoxClient.isPlayableVideoFileName(name);
}

/// 分享上下文（对齐 iOS `BaiduShareContext` 的核心字段）。
class BaiduShareMeta {
  /// 构造。
  const BaiduShareMeta({
    required this.shareid,
    required this.shareUk,
    required this.bdstoken,
    required this.surl,
    required this.cookie,
    required this.files,
    required this.randsk,
  });

  /// 分享 ID。
  final String shareid;

  /// 分享者 uk。
  final String shareUk;

  /// 用户态 bdstoken（可能为空）。
  final String bdstoken;

  /// 短链 surl（含前导 `1`）。
  final String surl;

  /// 链路过程中合并出的 Cookie。
  final String cookie;

  /// 可播放文件列表（选集）。
  final List<BaiduFileItem> files;

  /// 提取码验证后的 `randsk`（目录列举需用）。
  final String randsk;
}

/// 百度取链结果（对齐 iOS `PlayResult` 的百度子集）。
class BaiduPlayResult {
  /// 构造。
  const BaiduPlayResult({
    required this.url,
    required this.headers,
    required this.source,
  });

  /// 播放地址。
  final String url;

  /// 播放请求头（Cookie / UA / Referer / Origin）。
  final Map<String, String> headers;

  /// 取链来源标记（诊断 / 缓存用）。
  final String source;
}

/// 百度 iBox 本机链异常。
class BaiduIBoxException implements Exception {
  /// 构造。
  const BaiduIBoxException(this.message);

  /// 文案。
  final String message;

  @override
  String toString() => 'BaiduIBoxException($message)';
}

/// 百度 iBox 本机链客户端（C1：分享上下文 + 文件列表）。
class BaiduIBoxClient {
  /// 构造（[transport] / [prefs] / [cache] 供测试注入）。
  BaiduIBoxClient({
    SpiderHttpTransport? transport,
    PrefsManager? prefs,
    WebViewBridge? webView,
    BaiduPlaybackCacheStore? cache,
    NodeLoginClient? nodeLogin,
  })  : _transport = transport ?? IoSpiderHttpTransport(),
        _prefs = prefs,
        _webView = webView ?? const UnavailableWebViewBridge(),
        _cacheOverride = cache,
        _nodeLogin = nodeLogin ?? NodeLoginClient();

  /// 分享上下文缓存契约键（对齐 iOS `baidu_share_context_cache_v1`）。
  static const String shareContextCacheKey =
      BaiduPlaybackCacheStore.shareContextKey;

  /// 分享上下文缓存 TTL（对齐 iOS `storeShareContext` 默认 8h；批次 E · E5-5
  /// 由原 30min 修正为 8h）。
  static const Duration shareContextTtl =
      BaiduPlaybackCacheStore.shareContextTtl;

  /// Mac Chrome UA（对齐 iOS iBox：分享验证 / share/list 用它，非 iOS Safari）。
  static const String webUA =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36';

  /// 浏览器请求头近似组（治标）：仅对 `webUA` 浏览器语义请求补 `sec-ch-ua` 等
  /// header，用于对齐百度 header 层校验。不改变 TLS 层指纹（JA3），故对风控
  /// 收效有限，只作降级微调，不投入主链路。
  static const Map<String, String> browserFingerprintHeaders =
      <String, String>{
        'sec-ch-ua':
            '"Chromium";v="134", "Not:A-Brand";v="24", "Google Chrome";v="134"',
        'sec-ch-ua-mobile': '?0',
        'sec-ch-ua-platform': '"macOS"',
        'Accept-Language': 'zh-CN,zh;q=0.9',
      };

  /// PCS 客户端 UA（对齐 iOS `baiduPCSUserAgent`：mediainfo / locatedownload 用）。
  static const String pcsUserAgent =
      'Mozilla/5.0 (Linux; Android 12; HD1900 Build/SKQ1.211113.001) '
      'AppleWebKit/537.36 (KHTML, like Gecko)'
      '&channel=android_12_HD1900_bdnetdisktv_1025538l&version=1.21.1'
      '&network_type=wifi&app_id=250528&size=c1080_u1600';

  /// 转存目标目录（对齐 iOS `baiduIBoxTransferDir`：百度真实根路径 `/vbox`）。
  static const String transferDir = '/vbox';

  /// 转存落盘轮询上限（对齐 iOS `1...8`）。
  static const int transferWaitAttempts = 8;

  /// 可播放视频扩展名（对齐 iOS `baiduIsPlayableVideoFileName`）。
  static const List<String> playableVideoExts = <String>[
    'mp4', 'mkv', 'mov', 'm4v', 'avi', 'wmv', 'flv', 'ts', 'm2ts', 'mts',
    'webm', 'mpg', 'mpeg', '3gp', 'rm', 'rmvb', 'asf', 'f4v', 'm3u8',
  ];

  final SpiderHttpTransport _transport;
  final PrefsManager? _prefs;

  /// 内嵌 WebView 桥（C3 回退：URLSession 失败时复刻 iOS WKWebView XHR）。
  final WebViewBridge _webView;

  /// 播放缓存统一层注入（测试用；缺省走全局 [PrefsManager]）。
  final BaiduPlaybackCacheStore? _cacheOverride;

  /// Node 常驻代取客户端（P1 ③；缺省本机 Node，取号失败时跳过交后续兜底）。
  final NodeLoginClient _nodeLogin;

  /// 最近一次原生 WebView2 桥取 bdstoken 的失败原因（Windows 专属；
  /// 用于把真实失败原因带进最终报错，避免用户盲目反复扫码）。
  String _lastBaiduNativeFailure = '';

  /// 播放缓存统一层（批次 E · E5-5；对齐 iOS `CloudDriveManager` 缓存族）。
  BaiduPlaybackCacheStore get _cache =>
      _cacheOverride ??
      BaiduPlaybackCacheStore(_prefs ?? PrefsManager.instance);

  // ─────────────── 静态工具（对齐 iOS 同名函数）───────────────

  /// 粘贴串 → `(cookie, BDUSS)`（对齐 iOS `parseBaiduToken`）。
  static ({String cookie, String bduss}) parseToken(String raw) {
    String input = raw.trim();
    if (input.toLowerCase().startsWith('cookie:')) {
      input = input.substring('cookie:'.length).trim();
    }
    // `\r\n` 先作整体替换，避免被拆成两个分隔符而产生空的 `; ;` 条目。
    String normalizeCookie(String s) => s
        .replaceAll('\r\n', '; ')
        .replaceAll('\n', '; ')
        .replaceAll('\r', '; ')
        .replaceAll(RegExp(r';+\s*$'), '');

    if (RegExp(r'BDUSS=([^;|]+)').hasMatch(input)) {
      final String normalized = normalizeCookie(input);
      final RegExpMatch? m = RegExp(r'BDUSS=([^;|]+)').firstMatch(normalized);
      final String bduss = (m?.group(1) ?? '').trim();
      if (bduss.isNotEmpty) return (cookie: normalized, bduss: bduss);
    }
    if (input.contains('|')) {
      final String cleaned = input.replaceAll(RegExp(r'^BDUSS='), '');
      final List<String> parts = cleaned.split('|');
      final String bduss = parts[0].trim();
      String cookie = 'BDUSS=$bduss';
      if (parts.length >= 2) {
        final String stoken =
            parts[1].replaceAll(RegExp(r'^STOKEN='), '').trim();
        cookie += '; STOKEN=$stoken';
      }
      return (cookie: cookie, bduss: bduss);
    }
    final String bduss = input.replaceAll('BDUSS=', '').trim();
    return (cookie: 'BDUSS=$bduss', bduss: bduss);
  }

  /// 多段 Cookie 合并（对齐 iOS `baiduMergeCookieStrings`：忽略属性名，后到覆盖）。
  static String mergeCookieStrings(List<String> cookies) {
    const Set<String> ignored = <String>{
      'expires', 'path', 'domain', 'max-age', 'secure', 'httponly', 'samesite',
    };
    final List<String> keys = <String>[];
    final Map<String, (String, String)> values = <String, (String, String)>{};
    for (final String cookie in cookies) {
      if (cookie.isEmpty) continue;
      final String normalized = cookie
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
        if (ignored.contains(key)) continue;
        if (!values.containsKey(key)) keys.add(key);
        values[key] = (name, value);
      }
    }
    return keys
        .where(values.containsKey)
        .map((String k) => '${values[k]!.$1}=${values[k]!.$2}')
        .join('; ');
  }

  /// errno → 中文文案（对齐 iOS `baiduErrorMessage`）。
  static String errorMessage(int errno, [String? fallback]) => switch (errno) {
        0 => '成功',
        -9 => '提取码错误',
        200025 => '分享验证态未绑定当前账号，请重新验证后转存',
        -8 => '目标目录或文件已存在',
        -7 || -10 => '账号登录态已过期，请重新扫码登录',
        -6 => '身份验证失败，请重新登录百度网盘',
        -4 || 4 => '需要图形验证码或安全验证',
        2 => '参数错误或分享信息不完整',
        5 => '分享链接不存在或已失效',
        10 => '分享内容不存在或已被删除',
        _ => fallback ?? '百度错误 errno=$errno',
      };

  /// 提取 surl（对齐 iOS：优先 `/s/1xxx` 保留前导 1）。
  static String? extractSurl(String shareUrl) {
    final RegExpMatch? m1 = RegExp(r'/s/1([^/?]+)').firstMatch(shareUrl);
    if (m1 != null) return '1${m1.group(1)}';
    final RegExpMatch? m2 = RegExp(r'/s/([^/?]+)').firstMatch(shareUrl);
    return m2?.group(1);
  }

  /// 提取提取码（对齐 iOS `extractBaiduPwd`）。
  static String? extractPwd(String shareUrl) {
    final RegExpMatch? m = RegExp(r'[?&]pwd=([^&]+)').firstMatch(shareUrl);
    return m?.group(1);
  }

  /// iOS `baiduShortSurl`：去掉 surl 前导 `1`。
  static String shortSurl(String surl) =>
      surl.startsWith('1') ? surl.substring(1) : surl;

  // ─────────────── 静态工具（C2，对齐 iOS 同名函数）───────────────

  /// 是否为可播放视频（对齐 iOS `baiduIsPlayableVideoFileName`）。
  static bool isPlayableVideoFileName(String fileName) {
    final String lower = fileName.toLowerCase();
    return playableVideoExts.any((String e) => lower.endsWith('.$e'));
  }

  /// 取 Cookie 指定字段值（对齐 iOS `baiduCookieValue`；空值视为不存在）。
  static String? cookieValue(String cookie, String name) {
    final String lowerName = name.toLowerCase();
    for (final String part in cookie.split(';')) {
      final String item = part.trim();
      final int eq = item.indexOf('=');
      if (eq <= 0) continue;
      final String key = item.substring(0, eq).trim().toLowerCase();
      final String value = item.substring(eq + 1).trim();
      if (key == lowerName && value.isNotEmpty) return value;
    }
    return null;
  }

  /// 剔除分享态字段，仅保留账号态 Cookie（对齐 iOS `baiduPureAccountCookie`）。
  ///
  /// 私域接口（gettemplatevariable / api/create / filemanager / api/list）只允许
  /// 账号态 Cookie；混入 BDCLND 等会触发 errno=-6/-9。
  static String pureAccountCookie(String cookie) {
    if (cookie.isEmpty) return cookie;
    const Set<String> drop = <String>{
      'bdclnd', 'bdclnd_bfess', 'share_pwd', 'share_pwd_bfess',
    };
    final String merged = mergeCookieStrings(<String>[cookie]);
    return merged
        .split(';')
        .map((String p) => p.trim())
        .where((String item) {
          final int eq = item.indexOf('=');
          if (eq <= 0) return false;
          final String name = item.substring(0, eq).trim().toLowerCase();
          return !drop.contains(name);
        })
        .join('; ');
  }

  /// 规范化 PCS Cookie（对齐 iOS `normalizeBaiduPCSCookie`）。
  static String normalizePCSCookie(String raw) => raw
      .trim()
      .replaceAll('\n', '; ')
      .replaceAll('\r', '; ')
      .replaceAll(RegExp(r'\s*;\s*'), '; ')
      .replaceAll(RegExp(r';+\s*$'), '');

  /// 严格查询编码（对齐 iOS `baiduQueryEncoded`：`urlQueryAllowed` 去掉 `&+=?#`）。
  static String queryEncodeStrict(String value) {
    const String allowed = r"-._~!$'()*,;:@/?";
    final StringBuffer sb = StringBuffer();
    for (final int rune in value.runes) {
      final String ch = String.fromCharCode(rune);
      final bool keep =
          RegExp(r'[A-Za-z0-9]').hasMatch(ch) || allowed.contains(ch);
      sb.write(keep ? ch : Uri.encodeComponent(ch));
    }
    return sb.toString();
  }

  /// 从 HTML 抓用户态 bdstoken（对齐 iOS `baiduExtractBdstokenFromHTML`）。
  static String? extractBdstokenFromHTML(String html) {
    const List<String> patterns = <String>[
      r'''["']bdstoken["']\s*:\s*["']([^"']+)["']''',
      r'''bdstoken\s*=\s*["']([^"']+)["']''',
      r'bdstoken=([A-Za-z0-9_\-%.]+)',
    ];
    for (final String p in patterns) {
      final RegExpMatch? m =
          RegExp(p, caseSensitive: false).firstMatch(html);
      if (m != null && m.group(1) != null) {
        final String token = m.group(1)!.trim();
        if (token.isNotEmpty) {
          try {
            return Uri.decodeComponent(token);
          } catch (_) {
            return token;
          }
        }
      }
    }
    return null;
  }

  // ─────────────── 分享上下文 + 文件列表（C1 主链）───────────────

  /// 分享链接 → 全部可播放文件（对齐 iOS `baiduGetFileList`：文件列表缓存 +
  /// 路由诊断埋点）。
  Future<List<BaiduFileItem>> getFileList({
    required String shareUrl,
    required String cookie,
  }) async {
    final String cacheKey = BaiduPlaybackCacheStore.fileListCacheKey(
      shareUrl: shareUrl,
      bduss: cookie,
    );
    final List<BaiduCacheFile>? cached = await _cache.cachedFileList(cacheKey);
    if (cached != null) {
      await _cache.recordRouteDiagnostic(
        stage: '文件列表',
        status: '缓存命中',
        detail: '命中百度文件列表缓存：${cached.length} 个文件',
      );
      return cached
          .map((BaiduCacheFile f) => BaiduFileItem(fsId: f.fsId, name: f.name))
          .toList(growable: false);
    }
    await _cache.recordRouteDiagnostic(
      stage: '文件列表',
      status: 'iBox开始',
      detail: '本机 /wap/init + verify + share页/yunData + gettemplatevariable '
          '+ share/list(web=1)，不走 Worker',
    );
    final BaiduShareMeta meta = await extractShareMeta(
      shareUrl: shareUrl,
      cookie: cookie,
      returnAll: true,
    );
    await _cache.storeFileList(
      cacheKey,
      meta.files
          .map((BaiduFileItem f) => BaiduCacheFile(fsId: f.fsId, name: f.name))
          .toList(growable: false),
    );
    await _cache.recordRouteDiagnostic(
      stage: '文件列表',
      status: 'iBox成功',
      detail: 'share/list 返回 ${meta.files.length} 个文件',
    );
    return meta.files;
  }

  /// 分享验证链（对齐 iOS `baiduExtractShareMeta`，C1 范围）。
  Future<BaiduShareMeta> extractShareMeta({
    required String shareUrl,
    required String cookie,
    bool returnAll = false,
  }) async {
    final String? surl = extractSurl(shareUrl);
    if (surl == null || surl.isEmpty) {
      throw const BaiduIBoxException('无法识别的分享链接');
    }
    final String? pwd = extractPwd(shareUrl);
    final String contextKey = BaiduPlaybackCacheStore.shareContextCacheKey(
      shareUrl: shareUrl,
      cookie: cookie,
    );

    if (!returnAll) {
      final BaiduShareContextCacheItem? cached =
          await _cache.cachedShareContext(
        contextKey,
        needsRandsk: (pwd ?? '').isNotEmpty,
      );
      if (cached != null) {
        await _cache.recordRouteDiagnostic(
          stage: '分享上下文',
          status: '缓存命中',
          detail: '命中分享上下文缓存',
        );
        return _metaFromCache(cached);
      }
    }

    final String shortSurl = shortSurlOf(surl);
    final String initUrl = 'https://pan.baidu.com/wap/init?surl=$shortSurl';
    final String desktopShareUrl = 'https://pan.baidu.com/s/1$shortSurl';

    String iBoxCookie = cookie;
    String shareid = '';
    String shareUk = '';
    String bdstoken = '';
    String randskForList = '';
    final List<BaiduFileItem> files = <BaiduFileItem>[];

    // ① GET /wap/init
    final _Resp initResp = await _request(
      initUrl,
      headers: <String, String>{
        'Cookie': iBoxCookie,
        'User-Agent': webUA,
        'Referer': 'https://pan.baidu.com/',
        'Accept':
            'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'zh-CN,zh;q=0.9',
      },
      timeout: 18,
    );
    iBoxCookie = mergeCookieStrings(<String>[iBoxCookie, ...initResp.setCookies]);
    _applyYunDataHtml(initResp.text, files);

    // ② POST /share/verify（对齐 iOS：**不带任何 Cookie**）
    if (pwd != null && pwd.isNotEmpty) {
      final String encodedPwd = queryEncodeStrict(pwd);
      final String verifyUrl =
          'https://pan.baidu.com/share/verify?t=${DateTime.now().millisecondsSinceEpoch}'
          '&surl=$shortSurl&channel=chunlei&web=1&app_id=250528'
          '&bdstoken=&clienttype=0';
      final String verifyBody =
          'pwd=$encodedPwd&vcode=&vcode_str=&channel=chunlei&web=1'
          '&app_id=250528&clienttype=0&bdstoken=';
      final _Resp verifyResp = await _request(
        verifyUrl,
        method: 'POST',
        headers: <String, String>{
          'Content-Type': 'application/x-www-form-urlencoded; charset=utf-8',
          'Cookie': '',
          'User-Agent': webUA,
          'Origin': 'https://pan.baidu.com',
          'Referer': 'https://pan.baidu.com/',
          'Accept': '*/*',
          'Accept-Language': 'zh-Hans-001;q=1.0',
        },
        body: verifyBody,
        timeout: 18,
      );
      iBoxCookie = mergeCookieStrings(<String>[iBoxCookie, ...verifyResp.setCookies]);
      final Map<String, Object?>? vjson = _decodeMap(verifyResp.text);
      final int? errno = _asInt(vjson?['errno']);
      if (vjson == null || errno == null) {
        throw BaiduIBoxException(
          '百度 iBox 验证返回非 JSON：${_preview(verifyResp.text)}',
        );
      }
      if (errno != 0) {
        throw BaiduIBoxException(
          '百度 iBox 验证失败：${errorMessage(errno, _asString(vjson['errmsg']) ?? _asString(vjson['show_msg']))}',
        );
      }
      final String? rawRandsk = _asString(vjson['randsk']);
      if (rawRandsk != null && rawRandsk.isNotEmpty) {
        final String decoded = Uri.decodeComponent(rawRandsk);
        randskForList = decoded;
        iBoxCookie = mergeCookieStrings(<String>[
          iBoxCookie,
          'BDCLND=$rawRandsk; randsk=$decoded',
        ]);
      }
    }

    // ②.5 桌面分享页（带 BDCLND/randsk 后再抓，否则会在验证页循环）
    final _Resp desktopResp = await _request(
      desktopShareUrl,
      headers: <String, String>{
        'Cookie': iBoxCookie,
        'User-Agent': webUA,
        'Referer': initUrl,
        'Accept':
            'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'zh-CN,zh;q=0.9',
      },
      timeout: 18,
    );
    iBoxCookie = mergeCookieStrings(<String>[iBoxCookie, ...desktopResp.setCookies]);
    _applyYunDataHtml(desktopResp.text, files);

    // ②.6 gettemplatevariable（分享页上下文之后，桌面分享页 Referer）
    final _Resp tplResp = await _request(
      'https://pan.baidu.com/api/gettemplatevariable'
      '?clienttype=0&app_id=250528&web=1&bdstoken=$bdstoken'
      '&fields=${Uri.encodeComponent('["bdstoken","token","uk","username","shareid","share_id","share_uk","sign","timestamp","file_list","filelist","list","records","shareinfo","share_info","yunData"]')}',
      headers: <String, String>{
        'Cookie': iBoxCookie,
        'User-Agent': webUA,
        'Referer': desktopShareUrl,
        'Accept': 'application/json, text/javascript, */*; q=0.01',
        'X-Requested-With': 'XMLHttpRequest',
      },
      timeout: 15,
    );
    iBoxCookie = mergeCookieStrings(<String>[iBoxCookie, ...tplResp.setCookies]);
    final Map<String, Object?>? tpl = _decodeMap(tplResp.text);
    if (tpl != null) {
      final String tBd = _deepString(tpl, <String>{'bdstoken'});
      final String tShareid =
          _deepString(tpl, <String>{'shareid', 'share_id'});
      final String tUk = _deepString(tpl, <String>{'share_uk', 'uk'});
      final List<BaiduFileItem> tFiles = _deepFiles(tpl);
      if (bdstoken.isEmpty && tBd.isNotEmpty) bdstoken = tBd;
      if (shareid.isEmpty && tShareid.isNotEmpty) shareid = tShareid;
      if (shareUk.isEmpty && tUk.isNotEmpty) shareUk = tUk;
      if (files.isEmpty && tFiles.isNotEmpty) files.addAll(tFiles);
    }

    // ③ share/list：root-shorturl（不带账号态 Cookie）
    final String encodedShortSurl = _queryEncoded(shortSurl);
    final String rootUrl =
        'https://pan.baidu.com/share/list?app_id=250528&bdstoken=&channel=chunlei'
        '&clienttype=0&desc=1&num=20&order=time&page=1&root=1'
        '&shorturl=$encodedShortSurl&showempty=0&view_mode=1&web=1';
    final List<String> dirsToLoad = <String>[];
    String lastListError = '';

    Future<Map<String, Object?>?> requestShareList(
      String listUrl, {
      required bool includeAccountCookie,
    }) async {
      final _Resp r = await _request(
        listUrl,
        headers: <String, String>{
          'Cookie': _cookieForShareList(
            iBoxCookie,
            includeAccount: includeAccountCookie,
          ),
          'User-Agent': webUA,
          'Referer': 'https://pan.baidu.com/',
          'Accept': '*/*',
          'Accept-Language': 'zh-Hans-001;q=1.0',
          'Origin': 'https://pan.baidu.com',
        },
        timeout: 18,
      );
      iBoxCookie = mergeCookieStrings(<String>[iBoxCookie, ...r.setCookies]);
      final Map<String, Object?>? json = _decodeMap(r.text);
      if (json == null) {
        lastListError = _preview(r.text);
        return null;
      }
      final int errno = _asInt(json['errno']) ?? 0;
      if (errno != 0) {
        lastListError =
            errorMessage(errno, _asString(json['errmsg']) ?? _asString(json['show_msg']));
        return null;
      }
      return json;
    }

    final Map<String, Object?>? rootJson =
        await requestShareList(rootUrl, includeAccountCookie: false);
    if (rootJson != null) {
      final Map<String, Object?> root =
          _asMap(rootJson['data']) ?? rootJson;
      final String rootShareid =
          _asString(root['share_id']) ?? _asString(root['shareid']) ?? '';
      final String rootUk =
          _asString(root['uk']) ?? _asString(root['share_uk']) ?? '';
      if (rootShareid.isNotEmpty) shareid = rootShareid;
      if (rootUk.isNotEmpty) shareUk = rootUk;
      final Object? rawList = root['list'];
      if (rawList is List) {
        final List<Map<String, Object?>> items =
            rawList.whereType<Map<Object?, Object?>>().map((Map<Object?, Object?> m) => m.cast<String, Object?>()).toList();
        files.addAll(_parsePlayableFiles(items));
        dirsToLoad.addAll(items
            .where(_isDirectory)
            .map((Map<String, Object?> i) => _asString(i['path']) ?? '')
            .where((String p) => p.isNotEmpty));
      }
    }

    // ③.5 子目录列举（需 shareid/uk/randsk；对齐 iOS 上限 30 个目录）
    if (shareid.isNotEmpty && shareUk.isNotEmpty && randskForList.isNotEmpty) {
      final Set<String> seen = <String>{};
      int index = 0;
      while (index < dirsToLoad.length && index < 30) {
        final String dir = dirsToLoad[index];
        index++;
        if (dir.isEmpty || seen.contains(dir)) continue;
        seen.add(dir);
        final String dirUrl =
            'https://pan.baidu.com/share/list?app_id=250528&bdstoken=&channel=chunlei'
            '&clienttype=0&desc=1&dir=${_iBoxQueryEncoded(dir)}&is_from_web=true'
            '&num=100&order=other&page=1&sekey=${_iBoxQueryEncoded(randskForList)}'
            '&shareid=${_queryEncoded(shareid)}&showempty=0'
            '&uk=${_queryEncoded(shareUk)}&view_mode=1&web=1';
        final Map<String, Object?>? dirJson =
            await requestShareList(dirUrl, includeAccountCookie: true);
        if (dirJson != null) {
          final Map<String, Object?> root =
              _asMap(dirJson['data']) ?? dirJson;
          final Object? rawList = root['list'];
          if (rawList is List) {
            final List<Map<String, Object?>> items = rawList
                .whereType<Map<Object?, Object?>>()
                .map((Map<Object?, Object?> m) => m.cast<String, Object?>())
                .toList();
            files.addAll(_parsePlayableFiles(items));
            dirsToLoad.addAll(items
                .where(_isDirectory)
                .map((Map<String, Object?> i) => _asString(i['path']) ?? '')
                .where((String p) => p.isNotEmpty));
          }
        }
      }
    }

    if (shareid.isEmpty || shareUk.isEmpty) {
      throw const BaiduIBoxException('百度 iBox 路链未拿到 shareid/uk');
    }
    if (files.isEmpty) {
      throw BaiduIBoxException('百度 iBox share/list 未返回文件列表：$lastListError');
    }

    final BaiduShareMeta meta = BaiduShareMeta(
      shareid: shareid,
      shareUk: shareUk,
      bdstoken: bdstoken,
      surl: surl,
      cookie: iBoxCookie,
      files: files,
      randsk: randskForList,
    );
    await _cache.storeShareContext(
      contextKey,
      BaiduShareContextCacheItem(
        shareUrl: shareUrl,
        surl: surl,
        pwd: pwd,
        shareid: shareid,
        shareUk: shareUk,
        bdstoken: bdstoken,
        randsk: randskForList,
        cookie: iBoxCookie,
        files: files
            .map((BaiduFileItem f) => BaiduCacheFile(fsId: f.fsId, name: f.name))
            .toList(growable: false),
        source: 'iBox',
      ),
    );
    return meta;
  }

  /// 缓存项 → [BaiduShareMeta]。
  static BaiduShareMeta _metaFromCache(BaiduShareContextCacheItem c) =>
      BaiduShareMeta(
        shareid: c.shareid,
        shareUk: c.shareUk,
        bdstoken: c.bdstoken ?? '',
        surl: c.surl,
        cookie: c.cookie,
        files: c.files
            .map((BaiduCacheFile f) => BaiduFileItem(fsId: f.fsId, name: f.name))
            .toList(growable: false),
        randsk: c.randsk ?? '',
      );

  // ─────────────── 转存链 + DLNA 取链（C2 主链）───────────────

  /// 取用户态 bdstoken（对齐 iOS `baiduFetchUserBdstokenLocal`，WebView 回退属 C3）。
  ///
  /// 私域接口（api/create / filemanager / api/list）必须用登录态 bdstoken；
  /// 分享页 yunData 里的 bdstoken 会被百度判越权（errno=-6）。
  ///
  /// - [savedBdstoken]：授权中心保存值（凭据 `extra["bdstoken"]`）。**优先路径**：
  ///   非空时直接复用（第 -1 层），跳过网络取号，云电脑/数据中心 IP 下稳定起播。
  ///
  /// 完整兜底链（iOS 同款 + Windows 专属增强）：
  ///   1. Dart URLSession 档 gettemplatevariable（对齐 iOS）；
  ///   1½. 浏览器栈 XHR·原始 Cookie（WebView2 真实 Edge 网络栈，Windows 增强）；
  ///   1.5. Cookie 补全 + Dart 重试（对齐 iOS `baiduEnrichAccountCookie`）；
  ///   1¾. 浏览器栈 XHR·补全 Cookie（覆盖「缺指纹 + 请求指纹风控」叠加）；
  ///   2. disk/main 静态 HTML 正则（对齐 iOS）；
  ///   3. WebView 载入 disk/main + 页面 JS 提取（对齐 iOS）；
  ///   4. 授权中心保存值（对齐 iOS）。
  /// - [onFetched]：活取成功回调（来源 = urlsession-templatevariable /
  ///   urlsession-disk-main / webview-disk-main，与 iOS 逐字一致；Windows 增强
  ///   层来源 = webview-xhr-templatevariable），携带本次
  ///   请求所用 cookie，调用方据此回写凭据 extra 与 cookie
  ///   （对齐 iOS `baiduPersistUserBdstoken`，`CloudDriveManager.swift:4758-4772`）。
  Future<String> fetchUserBdstoken({
    required String cookie,
    String savedBdstoken = '',
    void Function(String bdstoken, String source, String mergedCookie)? onFetched,
  }) async {
    // ── 第 -1 层：授权中心保存值优先 ──
    // 凭据已持久化 bdstoken（登录成功时经 WinHTTP/WebView2 落库）且非空时，
    // 直接复用保存值起播、跳过四层网络取号——云电脑/数据中心 IP 下隐藏取号
    // 链被百度风控全灭时，这是稳定起播的唯一路径；同时避免每次播放重复被风控。
    if (savedBdstoken.isNotEmpty) {
      AppLog.warn(
        'baidu-local',
        '第 -1 层 命中授权中心保存值，直接起播（source=credential-saved）',
        category: LogCategory.cloud,
      );
      return savedBdstoken;
    }
    // ── 第 0 前置层（Windows 专属，3.1858）：WinHTTP 系统栈直取 ──
    // 对齐 iOS 第 1 层 URLSession 的「系统网络栈」语义（Windows 上等价物为
    // WinHTTP/Schannel）：不依赖 WebView2 运行时、无窗口、秒级完成，成功则
    // 一步到位。errno 留痕判定百度对 Schannel 指纹的信任度（-6=仍被风控，
    // 继续走 WebView2 / 原有兜底链）。非 Windows 平台跳过。
    if (Platform.isWindows) {
      final viaWinHttp =
          await BaiduNativeTokenBridge.fetchBdstokenWinHttp(cookie);
      if (viaWinHttp.token.isNotEmpty) {
        AppLog.debug(
          'baidu-local',
          '第 0 前置层 WinHTTP（系统栈）取得用户态 bdstoken',
          category: LogCategory.cloud,
        );
        onFetched?.call(
          viaWinHttp.token,
          'winhttp-templatevariable',
          viaWinHttp.cookie.isEmpty ? cookie : viaWinHttp.cookie,
        );
        return viaWinHttp.token;
      }
      AppLog.warn(
        'baidu-local',
        '第 0 前置层 WinHTTP 未取得 bdstoken'
        '（errno=${viaWinHttp.errno}，${viaWinHttp.message}），'
        '继续 WebView2 / 原有兜底链',
        category: LogCategory.cloud,
      );
    }
    // ── 第 0¼ 层（Node 常驻代取，全平台）：Node OpenSSL 系统栈三跳种码 + 取号 ──
    // 背景：dart:io(BoringSSL) 与 Node(OpenSSL) 的 TLS 指纹不同，百度拦 dart:io
    // （errno=-6），但 Node 常驻进程直连可用（main.js 已对 http/https 打桩并成功
    // 打印 [HTTP-BAIDU]）。Node 端点三跳种码（www → passport → disk/main）富集
    // BAIDUID 后 GET gettemplatevariable，绕 dart:io 风控。Node 未就绪 / 取号失败
    // 时静默跳过，交后续 WebView2 / Dart 兜底链（不阻塞、不额外等待）。
    if (NodeRuntimeManager.instance.isSystemReady) {
      try {
        final ({String bdstoken, String cookie}) viaNode =
            await _nodeLogin.fetchBaiduBdstoken(cookie);
        if (viaNode.bdstoken.isNotEmpty) {
          AppLog.debug(
            'baidu-local',
            'Node 常驻代取取得用户态 bdstoken',
            category: LogCategory.cloud,
          );
          onFetched?.call(
            viaNode.bdstoken,
            'node-bdstoken',
            viaNode.cookie.isEmpty ? cookie : viaNode.cookie,
          );
          return viaNode.bdstoken;
        }
        AppLog.warn(
          'baidu-local',
          'Node 常驻代取未取得 bdstoken（Node OpenSSL 栈仍被风控或登录态失效），'
          '继续 WebView2 / Dart 兜底链',
          category: LogCategory.cloud,
        );
      } catch (e) {
        AppLog.warn(
          'baidu-local',
          'Node 常驻代取失败（$e），继续 WebView2 / Dart 兜底链',
          category: LogCategory.cloud,
        );
      }
    }
    // ── 第 0 层（Windows 专属，新增）：原生 WebView2 桥（真实 Edge 网络栈）──
    // iOS 端 URLSession / WKWebView 均为系统网络栈，百度天然信任，故 iOS 无此问题；
    // Windows 端 dart:io HttpClient 的 TLS/请求指纹会被百度风控（errno=-6），
    // 而原生 WebView2 桥（windows/runner/baidu_token_bridge.cpp）走真实 Edge 栈、
    // 与登录网关同源，信任度最高，故在 Windows 上提为首选项，Dart 层降为兜底。
    // 非 Windows 平台跳过本层，iOS/Android/macOS 行为完全不变。
    if (Platform.isWindows) {
      final viaNative = await BaiduNativeTokenBridge.fetchBdstoken(cookie);
      if (viaNative.token.isNotEmpty) {
        AppLog.debug(
          'baidu-local',
          '第 0 层 原生 WebView2 桥取得用户态 bdstoken',
          category: LogCategory.cloud,
        );
        // 回传 WebView2 Jar 全量 Cookie（含服务端现场补种的
        // BAIDUID/BAIDUID_BFESS），经 onFetched → pan_player._saveBaiduBdstoken
        // 合并落库，后续播放第 1 层即可命中。
        onFetched?.call(
          viaNative.token,
          'native-webview2-bdstoken',
          viaNative.cookie.isEmpty ? cookie : viaNative.cookie,
        );
        return viaNative.token;
      }
      if (viaNative.errno != -1 || viaNative.message.isNotEmpty) {
        _lastBaiduNativeFailure = viaNative.message.isEmpty
            ? '原生 WebView2 桥未取得 bdstoken（errno=${viaNative.errno}）'
            : viaNative.message;
        AppLog.warn(
          'baidu-local',
          '第 0 层 原生 WebView2 桥未取得 bdstoken'
          '（errno=${viaNative.errno}，$_lastBaiduNativeFailure），继续原有兜底链',
          category: LogCategory.cloud,
        );
      }
    }
    final _Resp tpl = await _request(
      'https://pan.baidu.com/api/gettemplatevariable'
      '?clienttype=0&app_id=250528&web=1'
      '&fields=${Uri.encodeComponent('["bdstoken","token","uk","isdocuser","servertime"]')}',
      headers: <String, String>{
        'Cookie': cookie,
        'User-Agent': webUA,
        'Referer': 'https://pan.baidu.com/disk/main',
      },
      timeout: 12,
    );
    final Map<String, Object?>? json = _decodeMap(tpl.text);
    if (json == null) {
      // 响应不是 JSON 时旧代码静默跳过，导致「取不到 bdstoken」无法区分是
      // 风控（errno）还是登录态失效被重定向到登录页 / 响应被压缩。
      AppLog.warn(
        'baidu-local',
        '第 1 层 gettemplatevariable 响应非 JSON'
        '（status=${tpl.status}，'
        'contentType=${tpl.headers['content-type'] ?? tpl.headers['Content-Type'] ?? '未知'}，'
        'len=${tpl.text.length}）',
        category: LogCategory.cloud,
      );
    }
    if (json != null) {
      // 对齐 iOS baiduFetchTemplateVariables：解析 errno，非 0 记录日志，
      // 避免登录态异常时静默吞掉、无法排查。
      final int errno = _asInt(json['errno']) ?? 0;
      if (errno != 0) {
        AppLog.warn(
          'baidu-local',
          'gettemplatevariable 返回 errno=$errno（百度登录态异常，无法取得 bdstoken）',
          category: LogCategory.cloud,
        );
      }
      final String token = _deepString(json, <String>{'bdstoken'});
      if (token.isNotEmpty) {
        AppLog.debug(
          'baidu-local',
          '第 1 层 gettemplatevariable 取得用户态 bdstoken',
          category: LogCategory.cloud,
        );
        onFetched?.call(token, 'urlsession-templatevariable', cookie);
        return token;
      }
      AppLog.warn(
        'baidu-local',
        // 对齐 iOS L4712：打印顶层 keys（不含值，避免 bdstoken 泄漏）+ result 结构，
        // 便于区分 errno 风控与字段结构变化。
        '第 1 层 gettemplatevariable 未返回 bdstoken'
        '（errno=$errno，keys=${json.keys.toList()..sort()}，'
        'result=${_asMap(json['result'])?.keys.toList() ?? '无'}）',
        category: LogCategory.cloud,
      );
    }
    // ── 第 1.5 层（新增）：Cookie 补全 + 重试（对齐 iOS `baiduEnrichAccountCookie`）──
    // 背景（实测四层兜底在「登录态正常」下全空的主因）：凭据 Cookie 缺
    // `BAIDUID` 等指纹字段（旧版本登录 / 登录补全被风控）时，gettemplatevariable
    // 会被百度风控（errno=-6）——而原四层兜底全部用**同一份 Cookie** 发请求，
    // 必然全空。本层按 iOS 已验证有效的端点套路串行访问只读端点，让百度
    // 逐跳 Set-Cookie 补齐指纹后再取 bdstoken；补全后的完整 Cookie 经
    // onFetched 回写凭据（pan_player `_saveBaiduBdstoken` 合并落库），
    // 下次播放第 1 层可直接命中。
    //
    // 顺序说明（3.1839 闪退修复）：本层是**纯 Dart** HTTP，不依赖 WebView2，
    // 必须排在浏览器栈层之前——Windows 无头 WebView2 有原生崩溃风险
    // （见 `InAppWebViewBridge.windowsHeadlessEnabled` 崩溃保护），3.1839 把
    // 浏览器栈放在补全之前，导致补全层从未获得执行机会、每次播放必崩。
    final ({String token, String cookie}) enriched = await _enrichBdstoken(cookie);
    if (enriched.token.isNotEmpty) {
      AppLog.debug(
        'baidu-local',
        '第 1.5 层 Cookie 补全后取得用户态 bdstoken',
        category: LogCategory.cloud,
      );
      onFetched?.call(enriched.token, 'urlsession-templatevariable', enriched.cookie);
      return enriched.token;
    }
    AppLog.warn(
      'baidu-local',
      '第 1.5 层 Cookie 补全仍未取得 bdstoken（继续浏览器栈 / HTML / WebView / 保存值兜底）',
      category: LogCategory.cloud,
    );
    // ── 浏览器栈层（Windows 专属增强，iOS 无此层）：WebView2 XHR 直取 ──
    // 背景（iOS 端同代码一直正常的关键差异）：iOS 经 URLSession 发请求，Apple
    // TLS 指纹被百度信任；Windows 端 Dart HttpClient 的 TLS/请求指纹可能被
    // 风控（ errno=-6 / 非 JSON 风控页），此时同一 Cookie 换真实 Edge 网络栈
    // （WebView2）即可通过。账号 Cookie 先经 CookieManager 种入 WebView2 持久化
    // Jar，页面上下文 XHR 自动携带（XHR 手动设 Cookie 头会被浏览器剥离）；
    // Jar 中服务端新种的指纹 Cookie 随返回值带回。复刻 iOS URLSession 信任度。
    //
    // 只调用一次，取补全后的最优 Cookie（补全合并了服务端指纹字段则用补全
    // 结果，否则用原始），覆盖「Cookie 缺指纹 + 请求指纹风控」叠加场景；
    // Windows 上无头 WebView2 默认被崩溃保护禁用（抛 WebViewBridgeException，
    // 本层 try/catch 优雅跳过，见 `_webViewXhrBdstoken`）。
    final String browserCookie =
        (enriched.cookie.isNotEmpty && enriched.cookie != cookie)
            ? enriched.cookie
            : cookie;
    final ({String token, String cookie}) viaBrowser =
        await _webViewXhrBdstoken(browserCookie);
    if (viaBrowser.token.isNotEmpty) {
      AppLog.debug(
        'baidu-local',
        '浏览器栈 XHR 取得用户态 bdstoken',
        category: LogCategory.cloud,
      );
      onFetched?.call(viaBrowser.token, 'webview-xhr-templatevariable', viaBrowser.cookie);
      return viaBrowser.token;
    }
    // 回退：直接抓 disk/main 页面里的用户态 bdstoken。
    final _Resp page = await _request(
      'https://pan.baidu.com/disk/main',
      headers: <String, String>{'Cookie': cookie, 'User-Agent': webUA},
      timeout: 12,
    );
    final String fromHtml = extractBdstokenFromHTML(page.text) ?? '';
    if (fromHtml.isNotEmpty) {
      AppLog.debug(
        'baidu-local',
        '第 2 层 disk/main HTML 正则取得 bdstoken',
        category: LogCategory.cloud,
      );
      onFetched?.call(fromHtml, 'urlsession-disk-main', cookie);
      return fromHtml;
    }
    AppLog.warn(
      'baidu-local',
      '第 2 层 disk/main HTML 未解析到 bdstoken',
      category: LogCategory.cloud,
    );
    // C3 回退：WKWebView 载入 disk/main 复用 CookieJar
    // （对齐 `baiduFetchUserBdstokenViaWebView`）。
    final ({String token, String cookie}) fromWebView =
        await _webViewBdstoken(cookie);
    if (fromWebView.token.isNotEmpty) {
      AppLog.debug(
        'baidu-local',
        '第 3 层 WebView 取得 bdstoken',
        category: LogCategory.cloud,
      );
      onFetched?.call(
        fromWebView.token,
        'webview-disk-main',
        fromWebView.cookie.isEmpty ? cookie : fromWebView.cookie,
      );
      return fromWebView.token;
    }
    AppLog.warn(
      'baidu-local',
      '第 3 层 WebView 未解析到 bdstoken（Windows 端需确认 WebView2 可用）',
      category: LogCategory.cloud,
    );
    AppLog.error(
      'baidu-local',
      '四层兜底（含 Cookie 补全重试）全部失败，未取得用户态 bdstoken，'
      '无法创建 vbox 转存目录 —— 多为百度风控或旧版凭据缺指纹 Cookie，'
      '建议到授权中心重新扫码登录',
      category: LogCategory.cloud,
    );
    return '';
  }

  /// Cookie 串行补全 + bdstoken 重试（对齐 iOS `baiduEnrichAccountCookie`，
  /// `CloudDriveAuthManager.swift:1262-1316`）。
  ///
  /// 与登录补全相同的只读端点套路：先访问百度主域 / passport 让服务端
  /// Set-Cookie 补齐 `BAIDUID`/`BAIDUID_BFESS` 等指纹字段，再取
  /// gettemplatevariable。全部 GET、单次串行、失败静默回退，不写网盘、
  /// 不触发额外风控。返回补全后的完整 Cookie，供调用方经 `onFetched`
  /// 回写凭据（下次播放直接带完整指纹）。
  Future<({String token, String cookie})> _enrichBdstoken(String cookie) async {
    final Map<String, String> merged = <String, String>{};
    void ingest(String raw) {
      for (final String pair in raw.split(';')) {
        final String p = pair.trim();
        final int eq = p.indexOf('=');
        if (eq <= 0) continue;
        merged[p.substring(0, eq).trim()] = p.substring(eq + 1).trim();
      }
    }

    void absorb(List<String> setCookies) {
      for (final String raw in setCookies) {
        final String firstPair = raw.split(';').first.trim();
        final int eq = firstPair.indexOf('=');
        if (eq <= 0) continue;
        merged[firstPair.substring(0, eq).trim()] =
            firstPair.substring(eq + 1).trim();
      }
    }

    String cookieString() => merged.entries
        .map((MapEntry<String, String> e) => '${e.key}=${e.value}')
        .join('; ');

    ingest(cookie);
    const List<String> endpoints = <String>[
      'https://www.baidu.com/',
      'https://passport.baidu.com/center',
      'https://pan.baidu.com/disk/main',
    ];
    for (final String url in endpoints) {
      try {
        final _Resp res = await _request(
          url,
          headers: <String, String>{
            'Cookie': cookieString(),
            'User-Agent': webUA,
          },
          timeout: 12,
        );
        absorb(res.setCookies);
      } catch (_) {
        continue; // 单点失败静默回退（对齐 iOS continue 语义）。
      }
    }
    try {
      final _Resp tpl = await _request(
        'https://pan.baidu.com/api/gettemplatevariable'
        '?clienttype=0&app_id=250528&web=1'
        '&fields=${Uri.encodeComponent('["bdstoken","uk","username"]')}',
        headers: <String, String>{
          'Cookie': cookieString(),
          'User-Agent': webUA,
          'Referer': 'https://pan.baidu.com/disk/main',
        },
        timeout: 12,
      );
      absorb(tpl.setCookies);
      final Map<String, Object?>? json = _decodeMap(tpl.text);
      final String token = _deepString(json, <String>{'bdstoken'});
      if (token.isNotEmpty) {
        return (token: token, cookie: cookieString());
      }
      final int errno = _asInt(json?['errno']) ?? 0;
      AppLog.warn(
        'baidu-local',
        'Cookie 补全后 gettemplatevariable 仍未返回 bdstoken（errno=$errno）',
        category: LogCategory.cloud,
      );
    } catch (_) {
      // 静默回退（对齐 iOS continue 语义）。
    }
    return (token: '', cookie: cookieString());
  }

  /// 浏览器栈 XHR 取用户态 bdstoken（Windows 专属增强，iOS 无此层）。
  ///
  /// 与 Dart 层同 URL / 同参数，但经 WebView2（真实 Edge 网络栈）发出：
  ///   · TLS/请求指纹与真实浏览器一致，复刻 iOS URLSession 的信任度；
  ///   · 账号 Cookie 先经 [WebViewBridge.loadPage] 的 CookieManager 预注入
  ///     持久化 Jar——XHR 里手动设 `Cookie` 头会被浏览器按规范剥离，必须靠
  ///     Jar 自动携带；
  ///   · loadPage 顺带完成一次真实浏览会话，服务端 Set-Cookie 新种的指纹
  ///     字段经返回值 `cookie` 带回，供调用方回写凭据。
  ///
  /// 页面本身即使被风控重定向也不影响后续 XHR（Cookie 已种入 Jar）。
  Future<({String token, String cookie})> _webViewXhrBdstoken(String cookie) async {
    if (!_webView.isAvailable) {
      AppLog.warn(
        'baidu-local',
        '浏览器栈 XHR 层跳过（WebView2 环境未就绪）',
        category: LogCategory.cloud,
      );
      return (token: '', cookie: '');
    }
    try {
      // 种 Cookie 进持久 Jar + 真实浏览会话（disk/main；页面内容不参与判定）。
      final WebViewPageResult page = await _webView.loadPage(
        url: 'https://pan.baidu.com/disk/main',
        userAgent: webUA,
        cookies: _cookieMap(cookie),
        timeout: const Duration(seconds: 15),
      );
      final String jarCookie = page.cookie;
      final String reqCookie = jarCookie.isEmpty
          ? cookie
          : mergeCookieStrings(<String>[cookie, jarCookie]);
      // 页面上下文同步 XHR（同源无 CORS；Cookie 由 Jar 自动携带）。
      final WebViewXhrResult xhr = await _webView.request(
        url: 'https://pan.baidu.com/api/gettemplatevariable'
            '?clienttype=0&app_id=250528&web=1'
            '&fields=${Uri.encodeComponent('["bdstoken","token","uk","isdocuser","servertime"]')}',
        hostUrl: 'https://pan.baidu.com/disk/main',
        timeout: const Duration(seconds: 15),
      );
      final Map<String, Object?>? json = _decodeMap(xhr.body);
      final String token = _deepString(json, <String>{'bdstoken'});
      if (token.isNotEmpty) {
        return (token: token, cookie: reqCookie);
      }
      final int errno = _asInt(json?['errno']) ?? -1;
      AppLog.warn(
        'baidu-local',
        '浏览器栈 XHR 未取得 bdstoken'
        '（status=${xhr.status}，errno=$errno，bodyLen=${xhr.body.length}；'
        'errno=-1 表示响应非 JSON，多为风控页）',
        category: LogCategory.cloud,
      );
      return (token: '', cookie: reqCookie);
    } on WebViewBridgeException catch (e) {
      AppLog.warn(
        'baidu-local',
        '浏览器栈 XHR 失败：$e',
        category: LogCategory.cloud,
      );
      return (token: '', cookie: '');
    }
  }

  /// `/vbox` 转存目录是否可列举（对齐 iOS `baiduCanListTransferDir`）。
  Future<bool> canListTransferDir({
    required String cookie,
    required String bdstoken,
    String referer = 'https://pan.baidu.com/disk/main',
  }) async {
    final _Resp r = await _request(
      'https://pan.baidu.com/api/list?dir=${_queryEncoded(transferDir)}'
      '&order=time&desc=1&num=1&page=1&bdstoken=$bdstoken'
      '&channel=chunlei&web=1&app_id=250528&clienttype=0',
      headers: <String, String>{
        'Cookie': cookie,
        'User-Agent': webUA,
        'Referer': referer,
      },
      timeout: 12,
    );
    final Map<String, Object?>? json = _decodeMap(r.text);
    if (json == null) return false;
    return (_asInt(json['errno']) ?? 0) == 0;
  }

  /// 确保 `/vbox` 转存目录存在（对齐 iOS `baiduEnsureVboxFolderLocal`，WebView 回退属 C3）。
  Future<void> ensureTransferDir({
    required String cookie,
    required String bdstoken,
    String referer = 'https://pan.baidu.com/disk/main',
  }) async {
    if (await canListTransferDir(
      cookie: cookie,
      bdstoken: bdstoken,
      referer: referer,
    )) {
      return;
    }
    String lastResponse = '';
    // ① api/create（严格对齐 iBox 抓包：size=0、method=post，block_list 的 [] 也需编码）
    final _Resp create = await _request(
      'https://pan.baidu.com/api/create?a=commit&bdstoken=$bdstoken'
      '&channel=chunlei&web=1&app_id=250528&clienttype=0',
      method: 'POST',
      headers: <String, String>{
        'Cookie': cookie,
        'Content-Type': 'application/x-www-form-urlencoded',
        'User-Agent': webUA,
        'Referer': referer,
        'Origin': 'https://pan.baidu.com',
        'X-Requested-With': 'XMLHttpRequest',
      },
      body: 'path=${_queryEncoded(transferDir)}&size=0&isdir=1'
          '&block_list=${_queryEncoded('[]')}&method=post',
      timeout: 12,
    );
    lastResponse = _preview(create.text);
    final int createErrno = _asInt(_decodeMap(create.text)?['errno']) ?? -1;
    if (createErrno != 0 && createErrno != -8) {
      // ② filemanager create 兜底（对齐 iOS `baiduCreateFolderByFileManager`）。
      final _Resp fm = await _request(
        'https://pan.baidu.com/api/filemanager?opera=create&bdstoken=$bdstoken'
        '&channel=chunlei&web=1&app_id=250528&clienttype=0',
        method: 'POST',
        headers: <String, String>{
          'Cookie': cookie,
          'Content-Type': 'application/x-www-form-urlencoded',
          'User-Agent': webUA,
          'Referer': referer,
          'Origin': 'https://pan.baidu.com',
          'X-Requested-With': 'XMLHttpRequest',
        },
        body: 'path=${_queryEncoded(transferDir)}&isdir=1'
            '&block_list=${_queryEncoded('[]')}',
        timeout: 12,
      );
      lastResponse = _preview(fm.text);
    }
    if (await canListTransferDir(
      cookie: cookie,
      bdstoken: bdstoken,
      referer: referer,
    )) {
      return;
    }
    // C3 回退：WKWebView XHR 建目录 + 复检（对齐 `baiduCreateFolderViaWebView` /
    // `baiduCanListTransferDirViaWebView`）。
    if (await _webEnsureTransferDir(cookie: cookie, bdstoken: bdstoken)) {
      return;
    }
    throw BaiduIBoxException('百度 $transferDir 转存目录创建失败：$lastResponse');
  }

  /// 在 `/vbox` 检索已转存文件路径（对齐 iOS `baiduFindExistingVboxPath`）。
  Future<String?> findExistingVboxPath({
    required String fileName,
    required String cookie,
  }) async {
    final _Resp r = await _request(
      'https://pan.baidu.com/api/list?bdstoken=&channel=chunlei&web=1'
      '&app_id=250528&clienttype=0',
      method: 'POST',
      headers: <String, String>{
        'Cookie': cookie,
        'User-Agent': webUA,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: 'dir=${_queryEncoded(transferDir)}&order=time&desc=1&num=200&page=1',
      timeout: 12,
    );
    final Map<String, Object?>? json = _decodeMap(r.text);
    final String? local = (json != null && (_asInt(json['errno']) ?? 0) == 0)
        ? _matchedVboxPath(json, fileName)
        : null;
    if (local != null) return local;
    // C3 回退：WKWebView XHR 列 /vbox（对齐 `baiduFindExistingVboxPathViaWebView`）。
    return _webFindExistingVboxPath(cookie: cookie, fileName: fileName);
  }

  /// 转存落盘确认（对齐 iOS `baiduWaitForTransferredPath`）。
  Future<String> waitForTransferredPath({
    required String fileName,
    required String cookie,
    String? preferredPath,
  }) async {
    if (preferredPath != null && preferredPath.isNotEmpty) return preferredPath;
    final String normalized = _lastPathSegment(fileName);
    for (int attempt = 1; attempt <= transferWaitAttempts; attempt++) {
      if (attempt > 1) {
        final int factor = attempt < 4 ? attempt : 4;
        await Future<void>.delayed(Duration(milliseconds: 650 * factor));
      }
      final String? path =
          await findExistingVboxPath(fileName: normalized, cookie: cookie);
      if (path != null) return path;
    }
    throw BaiduIBoxException('百度转存任务未确认落盘：$transferDir/$normalized');
  }

  /// `share/transfer` 转存单文件（对齐 iOS `baiduTransferFileOnDevice`，WebView 回退属 C3）。
  Future<String> transferFile({
    required String shareUrl,
    required String shareid,
    required String shareUk,
    required String bdstoken,
    required String? randsk,
    required String fsId,
    required String fileName,
    required String cookie,
    required String accountCookie,
    required String referer,
  }) async {
    final String transferCookie =
        await refreshTransferSekey(
          shareUrl: shareUrl,
          accountCookie: accountCookie,
          existingCookie: cookie,
        ) ??
            cookie;
    // sekey 优先 Cookie 里的 BDCLND 原始值（通常已是百分号编码，不能二次编码）。
    final String rawSekey =
        cookieValue(transferCookie, 'BDCLND') ?? randsk ?? '';
    final List<String> query = <String>[
      'shareid=${queryEncodeStrict(shareid)}',
      'from=${queryEncodeStrict(shareUk)}',
      'channel=chunlei',
      'web=1',
      'app_id=250528',
      'clienttype=0',
      'bdstoken=${queryEncodeStrict(bdstoken)}',
    ];
    if (rawSekey.isNotEmpty) {
      final String encodedSekey =
          rawSekey.contains('%') ? rawSekey : queryEncodeStrict(rawSekey);
      query.add('sekey=$encodedSekey');
    }
    final String transferUrl =
        'https://pan.baidu.com/share/transfer?${query.join('&')}';
    final String transferBody = 'fsidlist=${_queryEncoded('[$fsId]')}'
        '&path=${_queryEncoded(transferDir)}&async=1&ondup=newcopy';
    final _Resp r = await _request(
      transferUrl,
      method: 'POST',
      headers: <String, String>{
        'Cookie': transferCookie,
        'Content-Type': 'application/x-www-form-urlencoded',
        'Referer': referer,
        'Origin': 'https://pan.baidu.com',
        'X-Requested-With': 'XMLHttpRequest',
        'User-Agent': webUA,
      },
      body: transferBody,
      timeout: 25,
    );
    final Map<String, Object?>? json = _decodeMap(r.text);
    final int errno = (r.status == 200 && json != null)
        ? (_asInt(json['errno']) ?? -1)
        : -1;
    if (errno == 0) {
      final Object? list = _asMap(json?['extra'])?['list'];
      if (list is List && list.isNotEmpty) {
        final String to = _asString(_asMap(list.first)?['to']) ?? '';
        if (to.isNotEmpty) return to;
      }
      return waitForTransferredPath(
        fileName: _lastPathSegment(fileName),
        cookie: accountCookie,
      );
    }
    // C3 回退：WKWebView XHR 转存（对齐 `baiduTransferFileViaWebView`）。
    final String? webPath = await _webTransferFile(
      transferUrl: transferUrl,
      transferBody: transferBody,
      cookie: transferCookie,
      fileName: fileName,
      accountCookie: accountCookie,
    );
    if (webPath != null) return webPath;
    if (r.status != 200 || json == null) {
      throw BaiduIBoxException('百度本机转存 HTTP ${r.status}');
    }
    throw BaiduIBoxException(
      '百度本机转存失败：${errorMessage(errno, _asString(json['errmsg']) ?? _asString(json['show_msg']))}',
    );
  }

  /// 账号态 verify 刷新转存 sekey（对齐 iOS `baiduRefreshTransferSekey`）。
  ///
  /// `share/list` 可用匿名分享态验证，但 `share/transfer` 属账号转存动作：百度会
  /// 校验 BDCLND/sekey 是否绑定当前账号会话，否则返回 errno=200025。
  Future<String?> refreshTransferSekey({
    required String shareUrl,
    required String accountCookie,
    required String existingCookie,
  }) async {
    final String? pwd = extractPwd(shareUrl);
    final String? surl = extractSurl(shareUrl);
    if (pwd == null || pwd.isEmpty || surl == null || surl.isEmpty) return null;
    final String short = shortSurl(surl);
    final _Resp r = await _request(
      'https://pan.baidu.com/share/verify?t=${DateTime.now().millisecondsSinceEpoch}'
      '&surl=$short&channel=chunlei&web=1&app_id=250528&bdstoken=&clienttype=0',
      method: 'POST',
      headers: <String, String>{
        'Content-Type': 'application/x-www-form-urlencoded; charset=utf-8',
        'Cookie': accountCookie,
        'User-Agent': webUA,
        'Origin': 'https://pan.baidu.com',
        'Referer': 'https://pan.baidu.com/s/1$short',
        'Accept': '*/*',
        'Accept-Language': 'zh-Hans-001;q=1.0',
      },
      body: 'pwd=${queryEncodeStrict(pwd)}&vcode=&vcode_str=&channel=chunlei'
          '&web=1&app_id=250528&clienttype=0&bdstoken=',
      timeout: 18,
    );
    final Map<String, Object?>? json = _decodeMap(r.text);
    if (json == null || (_asInt(json['errno']) ?? -1) != 0) return null;
    String merged = mergeCookieStrings(
      <String>[existingCookie, accountCookie, ...r.setCookies],
    );
    final String? rawRandsk = _asString(json['randsk']);
    if (rawRandsk != null && rawRandsk.isNotEmpty) {
      final String decoded = Uri.decodeComponent(rawRandsk);
      merged = mergeCookieStrings(
        <String>[merged, 'BDCLND=$rawRandsk; randsk=$decoded'],
      );
    }
    return merged;
  }

  /// `api/mediainfo` DLNA 取链（对齐 iOS `baiduGetDLNADlinkOnDevice`）。
  Future<BaiduPlayResult> getDLNADlink({
    required String filePath,
    required String cookie,
    String source = 'local-mediainfo',
  }) async {
    final _Resp r = await _request(
      'https://pan.baidu.com/api/mediainfo?clienttype=80&origin=dlna',
      method: 'POST',
      headers: <String, String>{
        'Cookie': cookie,
        'User-Agent': pcsUserAgent,
        'Accept': '*/*',
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: 'path=${_queryEncoded(filePath)}&type=M3U8_FLV_264_480',
      timeout: 20,
    );
    if (r.status != 200) {
      throw BaiduIBoxException('百度 DLNA HTTP ${r.status}');
    }
    final Map<String, Object?>? json = _decodeMap(r.text);
    if (json == null) {
      throw const BaiduIBoxException('百度 DLNA 返回非 JSON');
    }
    final Map<String, Object?>? info = _asMap(json['info']);
    final String dlink = _asString(info?['dlink']) ??
        _asString(json['dlink']) ??
        _asString(json['url']) ??
        '';
    if (dlink.isNotEmpty) return _playResult(dlink, cookie, source);
    final int errno = _asInt(json['errno']) ?? -1;
    throw BaiduIBoxException(
      '百度 DLNA 未返回 dlink：${errorMessage(errno, _asString(json['errmsg']) ?? _asString(json['show_msg']) ?? _asString(json['msg']))}',
    );
  }

  /// `locatedownload` 原画取链（对齐 iOS `baiduGetLocatedownloadOnDevice`）。
  Future<BaiduPlayResult> getLocatedownload({
    required String filePath,
    required String cookie,
    String source = 'local-locatedownload',
    bool enableFastestNode = false,
  }) async {
    final String url =
        'https://d.pcs.baidu.com/rest/2.0/pcs/file?app_id=250528'
        '&method=locatedownload&check_blue=1&path=${_queryEncoded(filePath)}';
    final _Resp r = await _request(
      url,
      headers: <String, String>{
        'Cookie': cookie,
        'User-Agent': pcsUserAgent,
        'Referer': 'https://pan.baidu.com/',
        'Origin': 'https://pan.baidu.com',
        'Accept': '*/*',
      },
      timeout: 20,
    );
    // 302 已由传输层跟随：CDN 落点即最终地址。
    if ((r.status == 200 || r.status == 206) &&
        r.finalUrl.isNotEmpty &&
        r.finalUrl != url &&
        !r.finalUrl.contains('d.pcs.baidu.com/rest/2.0/pcs/file')) {
      return _playResult(r.finalUrl, cookie, source);
    }
    final String location = r.headers['location'] ?? '';
    if (r.status >= 300 && r.status < 400 && location.isNotEmpty) {
      return _playResult(location, cookie, source);
    }
    if (r.status != 200) {
      throw BaiduIBoxException('百度本机取链 HTTP ${r.status}');
    }
    final Map<String, Object?>? json = _decodeMap(r.text);
    if (json == null) {
      throw const BaiduIBoxException('百度本机取链返回非 JSON');
    }
    final int errno = _asInt(json['errno']) ?? 0;
    if (errno != 0) {
      throw BaiduIBoxException(
        '百度本机取链失败：${errorMessage(errno, _asString(json['errmsg']) ?? _asString(json['show_msg']) ?? _asString(json['msg']))}',
      );
    }
    final Object? rawUrls = json['urls'];
    final List<String> all = rawUrls is List
        ? rawUrls
            .whereType<Map<Object?, Object?>>()
            .map((Map<Object?, Object?> m) => _asString(m['url']) ?? '')
            .where((String u) => u.isNotEmpty)
            .toList()
        : const <String>[];
    final String located = all.isNotEmpty
        ? all.first
        : (_asString(json['url']) ?? _asString(json['dlink']) ?? '');
    if (located.isEmpty) {
      throw const BaiduIBoxException('百度本机取链未返回播放地址');
    }
    if (enableFastestNode && all.length > 1) {
      final _BaiduNodeSpeed? fastest = await _findFastestNode(all, cookie);
      if (fastest != null && fastest.url != located) {
        return _playResult(fastest.url, cookie, '$source-fastest');
      }
    }
    return _playResult(located, cookie, source);
  }

  /// 分享链接 + fsId → 播放地址（对齐 iOS `resolveBaiduPlayURLViaMainRoute` 主链）。
  ///
  /// `wap/init → verify → 分享页/yunData → gettemplatevariable → share/list →
  /// api/create → api/list → share/transfer → api/list → locatedownload(→mediainfo)`。
  /// 不含 iOS 的 WebView 回退（C3）与 1 小时后清理调度（空间管理项）。
  ///
  /// - [savedBdstoken] / [onBdstokenFetched]：透传 [fetchUserBdstoken]
  ///   （第 4 层保存值兜底 + 活取回写，对齐 iOS 四层链）。
  Future<BaiduPlayResult> resolvePlayURL({
    required String shareUrl,
    required String bduss,
    required String fsId,
    String pcsCookie = '',
    String savedBdstoken = '',
    void Function(String bdstoken, String source, String mergedCookie)?
        onBdstokenFetched,
  }) async {
    final ({String cookie, String bduss}) parsed = parseToken(bduss);
    final String webCookie = parsed.cookie;
    final String pcs = normalizePCSCookie(pcsCookie);
    final String accountCookie = mergeCookieStrings(<String>[webCookie, pcs]);
    final String pureCookie = pureAccountCookie(accountCookie);

    // 主路链缓存键（对齐 iOS `baiduMainRouteCacheKey`，前缀 `main-route-v2|`）。
    final String cacheKey = BaiduPlaybackCacheStore.mainRouteCacheKey(
      shareUrl: shareUrl,
      fsId: fsId,
      bduss: bduss,
      pcsCookie: pcsCookie,
    );

    // ① 命中主路链播放缓存 → 直接返回（对齐 iOS L5729-5733）。
    final BaiduPersistedPlayCacheItem? cachedPlay =
        await _cache.cachedPlayResult(cacheKey);
    if (cachedPlay != null) {
      await _cache.recordRouteDiagnostic(
        stage: '主路链缓存',
        status: '命中',
        detail: '命中主路链 dlink 缓存',
        fsId: fsId,
      );
      return BaiduPlayResult(
        url: cachedPlay.url,
        headers: cachedPlay.headers,
        source: 'baidu-main-cache',
      );
    }

    // ② iBox PlayItem 复用（dlink 命中 / path 刷新；对齐 iOS L5735-5751）。
    final BaiduPlayResult? itemResult = await _resolveViaIBoxPlayItem(
      cacheKey: cacheKey,
      fsId: fsId,
      cookie: webCookie,
    );
    if (itemResult != null) {
      await _cache.storePlayResult(
        cacheKey,
        url: itemResult.url,
        headers: itemResult.headers,
      );
      return itemResult;
    }

    await _cache.recordRouteDiagnostic(
      stage: 'iBox主路链',
      status: '开始',
      detail: 'wap/init → verify → share页/yunData → gettemplatevariable → '
          'share/list → transfer → api/list → locatedownload → 本地代理',
      fsId: fsId,
    );

    final BaiduShareMeta context = await extractShareMeta(
      shareUrl: shareUrl,
      cookie: webCookie,
      returnAll: true,
    );
    // 分享页解析与 bdstoken 获取可并行（对齐 iOS [优化2]）。
    final String userBdstoken = await fetchUserBdstoken(
      cookie: pureCookie,
      savedBdstoken: savedBdstoken,
      onFetched: onBdstokenFetched,
    );
    if (userBdstoken.isEmpty) {
      final String hint = _lastBaiduNativeFailure.isEmpty
          ? 'Cookie 补全重试仍失败，多为百度风控或旧版凭据缺指纹 Cookie'
          : _lastBaiduNativeFailure;
      final String message = '百度登录态正常，但未取得用户态 bdstoken，'
          '无法创建 vbox 转存目录 —— $hint。'
          '建议到授权中心重新扫码登录，或粘贴含 BDUSS+STOKEN 的完整 Cookie';
      await _cache.recordRouteDiagnostic(
        stage: '主路链',
        status: '缺少用户态bdstoken',
        detail: message,
        fsId: fsId,
      );
      throw BaiduIBoxException(message);
    }
    final BaiduFileItem? selected = _selectFile(context.files, fsId);
    if (selected == null) {
      await _cache.recordRouteDiagnostic(
        stage: '主路链',
        status: '文件未找到',
        detail: 'fsId=$fsId 未在主路链文件列表中找到可播放视频',
        fsId: fsId,
      );
      throw const BaiduIBoxException('主路链未找到可播放视频');
    }
    final String mergedCookie =
        mergeCookieStrings(<String>[context.cookie, accountCookie]);
    if (mergedCookie.isEmpty) {
      await _cache.recordRouteDiagnostic(
        stage: '主路链',
        status: 'Cookie缺失',
        detail: '主路链缺少百度 Cookie',
        fsId: fsId,
      );
      throw const BaiduIBoxException('主路链缺少百度 Cookie');
    }
    await ensureTransferDir(
      cookie: pureCookie,
      bdstoken: userBdstoken,
      referer: 'https://pan.baidu.com/disk/main',
    );
    final String? existing = await findExistingVboxPath(
      fileName: selected.name,
      cookie: pureCookie,
    );
    final String filePath;
    final String sourcePrefix;
    if (existing != null) {
      filePath = existing;
      sourcePrefix = 'main-existing';
    } else {
      filePath = await transferFile(
        shareUrl: shareUrl,
        shareid: context.shareid,
        shareUk: context.shareUk,
        bdstoken: userBdstoken,
        randsk: context.randsk,
        fsId: selected.fsId,
        fileName: selected.name,
        cookie: mergedCookie,
        accountCookie: pureCookie,
        referer: shareUrl,
      );
      sourcePrefix = 'main-transfer';
      await _cache.recordRouteDiagnostic(
        stage: 'iBox主路链',
        status: '转存成功',
        detail: '转存落盘：$filePath',
        fsId: fsId,
        fileName: selected.name,
      );
    }
    try {
      final BaiduPlayResult result = await getLocatedownload(
        filePath: filePath,
        cookie: mergedCookie,
        source: '$sourcePrefix-locatedownload',
        enableFastestNode: true,
      );
      await _storeMainRouteSuccess(
        cacheKey: cacheKey,
        shareUrl: shareUrl,
        fsId: selected.fsId,
        fileName: selected.name,
        path: filePath,
        result: result,
        source: '$sourcePrefix-locatedownload',
      );
      return result;
    } on BaiduIBoxException {
      await _cache.recordRouteDiagnostic(
        stage: 'iBox主路链',
        status: 'locatedownload失败',
        detail: 'locatedownload 失败，转 mediainfo 兜底',
        fsId: fsId,
        fileName: selected.name,
      );
      // locatedownload 失败 → mediainfo dlink 兜底（对齐 iOS）。
      try {
        final BaiduPlayResult result = await getDLNADlink(
          filePath: filePath,
          cookie: mergedCookie,
          source: '$sourcePrefix-mediainfo-fallback',
        );
        await _storeMainRouteSuccess(
          cacheKey: cacheKey,
          shareUrl: shareUrl,
          fsId: selected.fsId,
          fileName: selected.name,
          path: filePath,
          result: result,
          source: '$sourcePrefix-mediainfo-fallback',
        );
        return result;
      } on BaiduIBoxException catch (e) {
        await _cache.recordRouteDiagnostic(
          stage: 'iBox主路链',
          status: '失败',
          detail: '$e',
          fsId: fsId,
          fileName: selected.name,
        );
        rethrow;
      }
    }
  }

  /// 主路链成功落缓存（播放结果 + iBox PlayItem，对齐 iOS L5865-5890）。
  Future<void> _storeMainRouteSuccess({
    required String cacheKey,
    required String shareUrl,
    required String fsId,
    required String fileName,
    required String path,
    required BaiduPlayResult result,
    required String source,
    DateTime? now,
  }) async {
    final DateTime ts = now ?? DateTime.now();
    await _cache.storePlayResult(
      cacheKey,
      url: result.url,
      headers: result.headers,
      now: ts,
    );
    await _cache.storeIBoxPlayItem(
      cacheKey,
      BaiduIBoxPlayItem(
        shareUrl: shareUrl,
        fsId: fsId,
        fileName: fileName,
        path: path,
        dlinkUrl: result.url,
        headers: result.headers,
        dlinkExpiresAt: ts.add(BaiduPlaybackCacheStore.iboxDlinkTtl),
        preparedAt: ts,
        updatedAt: ts,
        lastUsedAt: ts,
        source: source,
      ),
    );
    await _cache.recordRouteDiagnostic(
      stage: 'iBox主路链',
      status: '成功',
      detail: '取链成功：$path',
      fsId: fsId,
      fileName: fileName,
    );
  }

  /// iBox PlayItem 复用（对齐 iOS `baiduResolveViaIBoxPlayItem`）：
  /// dlink 未过期（> now+5min）直接用；否则用 path 刷新（locatedownload →
  /// mediainfo 兜底）；均失败返回 null 交由主路链重跑。
  Future<BaiduPlayResult?> _resolveViaIBoxPlayItem({
    required String cacheKey,
    required String fsId,
    required String cookie,
    DateTime? now,
  }) async {
    final BaiduIBoxPlayItem? item = await _cache.cachedIBoxPlayItem(cacheKey);
    if (item == null) return null;
    final DateTime ts = now ?? DateTime.now();
    final String dlink = item.dlinkUrl ?? '';
    final DateTime? exp = item.dlinkExpiresAt;
    if (exp != null &&
        exp.isAfter(ts.add(const Duration(minutes: 5))) &&
        dlink.isNotEmpty) {
      await _cache.recordRouteDiagnostic(
        stage: 'iBox',
        status: 'dlink命中',
        detail: '命中已准备 dlink，source=${item.source}',
        fsId: fsId,
        fileName: item.fileName,
      );
      await _cache.storeIBoxPlayItem(
        cacheKey,
        item.copyWith(updatedAt: ts, lastUsedAt: ts),
      );
      return BaiduPlayResult(
        url: dlink,
        headers: item.headers,
        source: 'baidu-main-playitem',
      );
    }

    if (item.path.isEmpty) return null;
    await _cache.recordRouteDiagnostic(
      stage: 'iBox',
      status: 'path刷新',
      detail: 'dlink 过期/缺失，使用 path 刷新：${item.path}',
      fsId: fsId,
      fileName: item.fileName,
    );
    final String itemCookie = item.headers.entries
        .firstWhere(
          (MapEntry<String, String> e) => e.key.toLowerCase() == 'cookie',
          orElse: () => const MapEntry<String, String>('', ''),
        )
        .value;
    final String mergedCookie = mergeCookieStrings(<String>[itemCookie, cookie]);
    if (mergedCookie.isEmpty) {
      await _cache.recordRouteDiagnostic(
        stage: 'iBox',
        status: 'Cookie缺失',
        detail: 'path 刷新缺少 Cookie，转入 iBox 主路链重新验证/转存',
        fsId: fsId,
        fileName: item.fileName,
      );
      return null;
    }

    Future<BaiduPlayResult?> refresh(Future<BaiduPlayResult> Function() fetch) async {
      try {
        final BaiduPlayResult refreshed = await fetch();
        await _cache.storeIBoxPlayItem(
          cacheKey,
          item.copyWith(
            dlinkUrl: () => refreshed.url,
            headers: refreshed.headers,
            dlinkExpiresAt: () => ts.add(BaiduPlaybackCacheStore.iboxDlinkTtl),
            updatedAt: ts,
            lastUsedAt: ts,
            source: 'ibox-path-refresh',
          ),
        );
        await _cache.recordRouteDiagnostic(
          stage: 'iBox',
          status: 'path刷新成功',
          detail: 'path 刷新完成：${item.path}',
          fsId: fsId,
          fileName: item.fileName,
        );
        return refreshed;
      } on BaiduIBoxException {
        return null;
      }
    }

    final BaiduPlayResult? located = await refresh(() => getLocatedownload(
          filePath: item.path,
          cookie: mergedCookie,
          source: 'ibox-path-refresh',
          enableFastestNode: true,
        ));
    if (located != null) return located;

    final BaiduPlayResult? dlna = await refresh(() => getDLNADlink(
          filePath: item.path,
          cookie: mergedCookie,
          source: 'ibox-mediainfo-fallback',
        ));
    if (dlna != null) return dlna;

    await _cache.recordRouteDiagnostic(
      stage: 'iBox',
      status: 'mediainfo失败',
      detail: 'path 刷新 locatedownload/mediainfo 均失败：${item.path}',
      fsId: fsId,
      fileName: item.fileName,
    );
    return null;
  }

  // ─────────────── 内部：HTTP ───────────────

  Future<_Resp> _request(
    String url, {
    String method = 'GET',
    Map<String, String> headers = const <String, String>{},
    String? body,
    int timeout = 15,
  }) async {
    final Map<String, String> effective = <String, String>{...headers};
    if (effective['User-Agent'] == webUA) {
      effective.addAll(browserFingerprintHeaders);
    }
    final SpiderTransportResponse res = await _transport.send(
      SpiderTransportRequest(
        method: method,
        url: Uri.parse(url),
        headers: effective,
        body: body,
        timeout: Duration(seconds: timeout),
      ),
    );
    final String text = utf8.decode(res.bodyBytes, allowMalformed: true);
    return _Resp(
      text: text,
      setCookies: res.setCookies,
      status: res.status,
      headers: res.headers,
      finalUrl: res.finalUrl.isEmpty ? url : res.finalUrl,
    );
  }

  // ─────────────── 内部：解析 ───────────────

  /// 从 HTML 抓 yunData（shareid/uk/bdstoken/FILEINFO）（对齐 iOS `applyYunDataHTML`）。
  void _applyYunDataHtml(String html, List<BaiduFileItem> files) {
    String first(List<String> patterns) {
      for (final String p in patterns) {
        final RegExpMatch? m = RegExp(p, caseSensitive: false).firstMatch(html);
        if (m != null && m.groupCount >= 1 && m.group(1) != null) {
          return m.group(1)!;
        }
      }
      return '';
    }

    final String fileinfo = first(<String>[
      r'yunData\.FILEINFO\s*=\s*(\[[\s\S]*?\]);',
    ]);
    if (fileinfo.isEmpty) return;
    final Object? decoded = _tryDecode(fileinfo);
    if (decoded is! List) return;
    final List<Map<String, Object?>> items = decoded
        .whereType<Map<Object?, Object?>>()
        .map((Map<Object?, Object?> m) => m.cast<String, Object?>())
        .toList();
    final List<BaiduFileItem> parsed = _parsePlayableFiles(items);
    if (files.isEmpty && parsed.isNotEmpty) files.addAll(parsed);
  }

  /// 解析可播放文件（过滤目录与非视频）（对齐 iOS `parsePlayableFiles`）。
  List<BaiduFileItem> _parsePlayableFiles(List<Map<String, Object?>> rawList) {
    final List<BaiduFileItem> out = <BaiduFileItem>[];
    for (final Map<String, Object?> item in rawList) {
      if (_isDirectory(item)) continue;
      final String fsId = _asString(item['fs_id']) ??
          _asString(item['fsId']) ??
          '';
      final String name = _asString(item['server_filename']) ??
          _asString(item['file_name']) ??
          _asString(item['name']) ??
          '';
      if (fsId.isEmpty) continue;
      final BaiduFileItem f =
          BaiduFileItem(fsId: fsId, name: name.isEmpty ? '未知文件' : name);
      if (f.isPlayableVideo) out.add(f);
    }
    return out;
  }

  bool _isDirectory(Map<String, Object?> item) {
    final String v = _asString(item['isdir']) ?? '';
    return v == '1' || v.toLowerCase() == 'true';
  }

  static String _queryEncoded(String value) {
    // 对齐 iOS `addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)`：
    // 空格 → %20（非 `+`），保留 `:/?&=` 等 query 常用字符。
    const String allowed = r"-._~!$&'()*+,;=:@/?";
    final StringBuffer sb = StringBuffer();
    for (final int rune in value.runes) {
      final String ch = String.fromCharCode(rune);
      final bool keep =
          RegExp(r'[A-Za-z0-9]').hasMatch(ch) || allowed.contains(ch);
      sb.write(keep ? ch : Uri.encodeComponent(ch));
    }
    return sb.toString();
  }

  /// iBox 保留 `/` 的查询编码（对齐 iOS `iBoxQueryEncoded(keepSlash: true)`）。
  static String _iBoxQueryEncoded(String value) {
    const String keep = '/';
    final StringBuffer sb = StringBuffer();
    for (final int rune in value.runes) {
      final String ch = String.fromCharCode(rune);
      final bool ok = RegExp(r'[A-Za-z0-9\-_.~]').hasMatch(ch) ||
          (keep.contains(ch) && ch.isNotEmpty);
      sb.write(ok ? ch : Uri.encodeComponent(ch));
    }
    return sb.toString();
  }

  /// 分享态 Cookie 过滤（对齐 iOS `cookieForShareList`）。
  static String _cookieForShareList(
    String cookie, {
    required bool includeAccount,
  }) {
    final Set<String> drop = <String>{
      'stoken', 'stoken_bfess', 'ptoken', 'ptoken_bfess',
      'passid', 'ubi_bfess', 'randsk',
    };
    if (!includeAccount) {
      drop.addAll(<String>['bduss', 'bduss_bfess']);
    }
    return cookie
        .split(';')
        .map((String p) => p.trim())
        .where((String part) {
          final int eq = part.indexOf('=');
          if (eq <= 0) return false;
          final String name = part.substring(0, eq).toLowerCase();
          return !drop.contains(name);
        })
        .join('; ');
  }

  static String _deepString(Object? value, Set<String> keys) {
    final Object? normalized = _parseJsonStringIfNeeded(value);
    if (normalized is Map) {
      for (final MapEntry<Object?, Object?> e in normalized.entries) {
        if (keys.contains('${e.key}'.toLowerCase())) {
          final String direct = _asString(e.value) ?? '';
          if (direct.isNotEmpty) return direct;
        }
      }
      for (final Object? raw in normalized.values) {
        final String found = _deepString(raw, keys);
        if (found.isNotEmpty) return found;
      }
    } else if (normalized is List) {
      for (final Object? raw in normalized) {
        final String found = _deepString(raw, keys);
        if (found.isNotEmpty) return found;
      }
    }
    return '';
  }

  /// 深层找文件列表（对齐 iOS `deepFiles`）。
  List<BaiduFileItem> _deepFiles(Object? value) {
    final Object? normalized = _parseJsonStringIfNeeded(value);
    if (normalized is Map) {
      for (final String key in <String>[
        'list', 'file_list', 'records', 'filelist', 'result', 'data', 'info',
      ]) {
        final Object? raw = normalized[key];
        if (raw is List) {
          final List<BaiduFileItem> parsed = _parsePlayableFiles(
            raw
                .whereType<Map<Object?, Object?>>()
                .map((Map<Object?, Object?> m) => m.cast<String, Object?>())
                .toList(),
          );
          if (parsed.isNotEmpty) return parsed;
        }
        if (raw != null) {
          final List<BaiduFileItem> nested = _deepFiles(raw);
          if (nested.isNotEmpty) return nested;
        }
      }
      for (final Object? raw in normalized.values) {
        final List<BaiduFileItem> found = _deepFiles(raw);
        if (found.isNotEmpty) return found;
      }
    } else if (normalized is List) {
      final List<BaiduFileItem> parsed = _parsePlayableFiles(
        normalized
            .whereType<Map<Object?, Object?>>()
            .map((Map<Object?, Object?> m) => m.cast<String, Object?>())
            .toList(),
      );
      if (parsed.isNotEmpty) return parsed;
      for (final Object? raw in normalized) {
        final List<BaiduFileItem> found = _deepFiles(raw);
        if (found.isNotEmpty) return found;
      }
    }
    return const <BaiduFileItem>[];
  }

  static Object? _parseJsonStringIfNeeded(Object? value) {
    if (value is! String) return value;
    final String trimmed = value.trim();
    if (!trimmed.startsWith('{') && !trimmed.startsWith('[')) return value;
    return _tryDecode(trimmed) ?? value;
  }

  // ─────────────── 内部：C2 助手 ───────────────

  /// 组装播放结果（对齐 iOS `baiduPlayResult`）。
  BaiduPlayResult _playResult(String url, String cookie, String source) =>
      BaiduPlayResult(
        url: url,
        headers: <String, String>{
          'Cookie': cookie,
          'User-Agent': pcsUserAgent,
          'Referer': 'https://pan.baidu.com/',
          'Origin': 'https://pan.baidu.com',
        },
        source: source,
      );

  /// 路径末段文件名。
  static String _lastPathSegment(String path) {
    final List<String> parts = path.split('/');
    return parts.isEmpty ? path : parts.last;
  }

  /// 去扩展名（对齐 iOS `deletingPathExtension`）。
  static String _deletePathExtension(String name) {
    final int dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  /// 取扩展名（对齐 iOS `pathExtension`）。
  static String _pathExtension(String name) {
    final int dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(dot + 1) : '';
  }

  /// 在 `/vbox` 列表中匹配目标文件（对齐 iOS `baiduFindExistingVboxPath.matchedPath`）。
  static String? _matchedVboxPath(
    Map<String, Object?> json,
    String fileName,
  ) {
    final Map<String, Object?> root = _asMap(json['data']) ?? json;
    final Object? rawList =
        root['list'] ?? root['file_list'] ?? root['records'];
    if (rawList is! List) return null;
    final String normalizedTarget = _lastPathSegment(fileName);
    final String targetBase = _deletePathExtension(normalizedTarget);
    final String targetExt = _pathExtension(normalizedTarget);
    for (final Object? raw in rawList) {
      final Map<String, Object?>? item = _asMap(raw);
      if (item == null) continue;
      final String name = _asString(item['server_filename']) ??
          _asString(item['filename']) ??
          _asString(item['name']) ??
          '';
      final String nameBase = _deletePathExtension(name);
      final String nameExt = _pathExtension(name);
      if (name == normalizedTarget ||
          (targetBase.isNotEmpty &&
              nameBase.startsWith(targetBase) &&
              (targetExt.isEmpty || nameExt == targetExt))) {
        final String path = _asString(item['path']) ?? '';
        return path.isNotEmpty ? path : '$transferDir/$normalizedTarget';
      }
    }
    return null;
  }

  /// 选集：优先 fsId 命中的可播放文件，否则首个可播放文件（对齐 iOS 主路链判定）。
  static BaiduFileItem? _selectFile(List<BaiduFileItem> files, String fsId) {
    for (final BaiduFileItem f in files) {
      if (f.fsId.trim() == fsId.trim() && f.isPlayableVideo) return f;
    }
    for (final BaiduFileItem f in files) {
      if (f.isPlayableVideo) return f;
    }
    return null;
  }

  /// 多 CDN 节点 HEAD 测速选优（对齐 iOS `baiduFindFastestNode`，单节点 3s 超时）。
  Future<_BaiduNodeSpeed?> _findFastestNode(
    List<String> urls,
    String cookie,
  ) async {
    final List<_BaiduNodeSpeed?> results = await Future.wait(
      <Future<_BaiduNodeSpeed?>>[
        for (final String url in urls) _probeNode(url, cookie),
      ],
    );
    _BaiduNodeSpeed? best;
    for (final _BaiduNodeSpeed? r in results) {
      if (r == null) continue;
      if (best == null || r.rttMs < best.rttMs) best = r;
    }
    return best;
  }

  Future<_BaiduNodeSpeed?> _probeNode(String url, String cookie) async {
    final DateTime start = DateTime.now();
    try {
      final _Resp r = await _request(
        url,
        method: 'HEAD',
        headers: <String, String>{
          'Cookie': cookie,
          'User-Agent': pcsUserAgent,
          'Referer': 'https://pan.baidu.com/',
        },
        timeout: 3,
      );
      final bool ok = r.status == 200 ||
          r.status == 206 ||
          (r.status >= 300 && r.status < 400);
      if (!ok) return null;
      return _BaiduNodeSpeed(
        url: url,
        rttMs: DateTime.now().difference(start).inMilliseconds,
      );
    } catch (_) {
      return null;
    }
  }

  // ─────────────── 内部：C3 WebView 回退 ───────────────

  /// Cookie 串 → Map（WebView CookieJar 注入用）。
  static Map<String, String> _cookieMap(String cookie) {
    final Map<String, String> out = <String, String>{};
    for (final String part in cookie.split(';')) {
      final String item = part.trim();
      final int eq = item.indexOf('=');
      if (eq <= 0) continue;
      out[item.substring(0, eq).trim()] = item.substring(eq + 1).trim();
    }
    return out;
  }

  /// 注入 Cookie 并载入 `pan.baidu.com` 承载页（WebView XHR 前置）。
  Future<bool> _webSeed(String cookie) async {
    if (!_webView.isAvailable) return false;
    try {
      await _webView.loadPage(
        url: 'https://pan.baidu.com/disk/main',
        userAgent: webUA,
        cookies: _cookieMap(cookie),
        timeout: const Duration(seconds: 15),
      );
      return true;
    } on WebViewBridgeException {
      return false;
    }
  }

  /// WebView 页面上下文 XHR → JSON（对齐 iOS `BaiduWebViewBridge.request`）。
  Future<Map<String, Object?>?> _webJson(
    String url, {
    required String cookie,
    String method = 'POST',
    String? body,
  }) async {
    if (!await _webSeed(cookie)) return null;
    try {
      final WebViewXhrResult r = await _webView.request(
        url: url,
        method: method,
        headers: <String, String>{
          'Content-Type': 'application/x-www-form-urlencoded',
          'X-Requested-With': 'XMLHttpRequest',
        },
        body: body,
        hostUrl: 'https://pan.baidu.com',
        timeout: const Duration(seconds: 15),
      );
      return _decodeMap(r.body);
    } on WebViewBridgeException {
      return null;
    }
  }

  /// WebView 取用户态 bdstoken（对齐 iOS `baiduFetchUserBdstokenViaWebView`）。
  ///
  /// 第 3 层：页面上下文 JS 提取（`window.locals`/`window.yunData`/`window.context`，
  /// 对齐 iOS `BaiduWebViewBridge.swift:147-152` 三重提取）优先，渲染后 HTML
  /// 正则兜底——disk/main 的 bdstoken 由 JS 运行时注入，静态正则大概率空手。
  ///
  /// 三源顺序与 iOS 严格一致：`locals` → `yunData.MYBDSTOKEN` → `context`。
  /// 早期版本漏了 `yunData` 一层，导致 WebView 兜底整条链空手返回。
  ///
  /// 返回值同时带回 WebView CookieJar 的 cookie（对齐 iOS
  /// `BaiduWebViewBridge.loadPanPageForBdstoken` 的 `result.cookie`），
  /// 供调用方按 `baiduPersistUserBdstoken` 语义合并回凭据。
  Future<({String token, String cookie})> _webViewBdstoken(String cookie) async {
    // Windows 专属：优先走原生 WebView2 桥（runner C++ 直连，不经 Flutter
    // 插件 WebView——规避 3.1839 无头闪退 / 3.1844 根 Overlay 白屏路径）。
    // 原生侧与登录网关同源：凭据 Cookie 种入 WebView2 持久化 Jar → 真实
    // 浏览器栈导航 disk/main → 页面上下文 fetch gettemplatevariable，
    // 复刻 iOS WKWebView 的系统网络栈信任度，并带回 Jar 全量 Cookie
    // （含服务端新种指纹字段，供上层合并回写凭据）。
    final viaNative = await BaiduNativeTokenBridge.fetchBdstoken(cookie);
    if (viaNative.token.isNotEmpty) {
      AppLog.debug(
        'baidu-local',
        '原生 WebView2 桥取得用户态 bdstoken',
        category: LogCategory.cloud,
      );
      return (
        token: viaNative.token,
        cookie: viaNative.cookie.isEmpty ? cookie : viaNative.cookie,
      );
    }
    AppLog.warn(
      'baidu-local',
      '原生 WebView2 桥未取得 bdstoken（errno=${viaNative.errno}，'
      '${viaNative.message}），回退 Flutter 插件 WebView 路径',
      category: LogCategory.cloud,
    );
    if (!_webView.isAvailable) {
      // 关键诊断：Windows 端 WebView2 环境未就绪时第 3 层恒空，必须留痕，
      // 否则排查时无法与「页面确实没有 bdstoken」区分。
      AppLog.warn(
        'baidu-local',
        '第 3 层 WebView 不可用（WebView2 环境未就绪），跳过',
        category: LogCategory.cloud,
      );
      return (token: '', cookie: '');
    }
    try {
      // 指纹预热：Windows 的 WebView2 用独立 userDataFolder，CookieJar 首次为
      // 空，仅预注入账号 Cookie 缺 BAIDUID 等指纹字段时 disk/main 大概率被
      // 风控到验证页（对齐 iOS WKWebView 共享系统 jar 的效果）。先访问一次
      // 百度主域让服务端种指纹 Cookie（jar 持久化，仅首次生效），再进 disk/main。
      try {
        await _webView.loadPage(
          url: 'https://www.baidu.com/',
          userAgent: webUA,
          cookies: _cookieMap(cookie),
          timeout: const Duration(seconds: 10),
        );
      } catch (_) {
        // 预热失败不阻断主流程。
      }
      final WebViewPageResult page = await _webView.loadPage(
        url: 'https://pan.baidu.com/disk/main',
        userAgent: webUA,
        cookies: _cookieMap(cookie),
        timeout: const Duration(seconds: 18),
        evaluateJs: '''
(function(){
  try { if (window.locals && window.locals.get) { var v = window.locals.get('bdstoken'); if (v) return v; } } catch(e){}
  try { if (window.yunData && window.yunData.MYBDSTOKEN) return window.yunData.MYBDSTOKEN; } catch(e){}
  try { if (window.context && window.context.bdstoken) return window.context.bdstoken; } catch(e){}
  return null;
})()
''',
      );
      final String merged = page.cookie.isEmpty ? cookie : page.cookie;
      if (page.jsResult.isNotEmpty) {
        return (token: page.jsResult, cookie: merged);
      }
      return (token: extractBdstokenFromHTML(page.html) ?? '', cookie: merged);
    } on WebViewBridgeException {
      return (token: '', cookie: '');
    }
  }

  /// WebView 建 `/vbox` 目录并复检（对齐 iOS `baiduCreateFolderViaWebView` +
  /// `baiduCanListTransferDirViaWebView`）。
  Future<bool> _webEnsureTransferDir({
    required String cookie,
    required String bdstoken,
  }) async {
    final String listUrl =
        'https://pan.baidu.com/api/list?dir=${_queryEncoded(transferDir)}'
        '&order=time&desc=1&num=1&page=1&bdstoken=$bdstoken'
        '&channel=chunlei&web=1&app_id=250528&clienttype=0';
    final Map<String, Object?>? first =
        await _webJson(listUrl, cookie: cookie, method: 'GET');
    if (first != null && (_asInt(first['errno']) ?? 0) == 0) return true;
    await _webJson(
      'https://pan.baidu.com/api/create?a=commit&bdstoken=$bdstoken'
      '&channel=chunlei&web=1&app_id=250528&clienttype=0',
      cookie: cookie,
      body: 'path=${_queryEncoded(transferDir)}&size=0&isdir=1'
          '&block_list=${_queryEncoded('[]')}&method=post',
    );
    final Map<String, Object?>? reList =
        await _webJson(listUrl, cookie: cookie, method: 'GET');
    return reList != null && (_asInt(reList['errno']) ?? 0) == 0;
  }

  /// WebView 列 `/vbox` 匹配文件（对齐 `baiduFindExistingVboxPathViaWebView`）。
  Future<String?> _webFindExistingVboxPath({
    required String cookie,
    required String fileName,
  }) async {
    final Map<String, Object?>? json = await _webJson(
      'https://pan.baidu.com/api/list?bdstoken=&channel=chunlei&web=1'
      '&app_id=250528&clienttype=0',
      cookie: cookie,
      body: 'dir=${_queryEncoded(transferDir)}&order=time&desc=1&num=200&page=1',
    );
    if (json == null || (_asInt(json['errno']) ?? 0) != 0) return null;
    return _matchedVboxPath(json, fileName);
  }

  /// WebView 转存（对齐 iOS `baiduTransferFileViaWebView`）。
  Future<String?> _webTransferFile({
    required String transferUrl,
    required String transferBody,
    required String cookie,
    required String fileName,
    required String accountCookie,
  }) async {
    final Map<String, Object?>? json =
        await _webJson(transferUrl, cookie: cookie, body: transferBody);
    if (json == null || (_asInt(json['errno']) ?? -1) != 0) return null;
    final Object? list = _asMap(json['extra'])?['list'];
    if (list is List && list.isNotEmpty) {
      final String to = _asString(_asMap(list.first)?['to']) ?? '';
      if (to.isNotEmpty) return to;
    }
    return waitForTransferredPath(
      fileName: _lastPathSegment(fileName),
      cookie: accountCookie,
    );
  }

  // 分享上下文缓存读写已统一并入 [BaiduPlaybackCacheStore]（批次 E · E5-5），
  // 对齐 iOS `CloudDriveManager` 的 `baiduCachedShareContext` /
  // `baiduStoreShareContext`（TTL 8h、上限 60、bdstoken/randsk 完整性校验）；
  // 键派生改用 `BaiduPlaybackCacheStore.shareContextCacheKey`（FNV-1a，对齐
  // iOS `baiduShareContextKey`）。

  // ─────────────── JSON 助手 ───────────────

  static Map<String, Object?>? _decodeMap(String body) {
    final Object? d = _tryDecode(body);
    return d is Map ? d.cast<String, Object?>() : null;
  }

  static Object? _tryDecode(String body) {
    if (body.isEmpty) return null;
    try {
      return jsonDecode(body);
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

  static String _preview(String text) =>
      text.length <= 200 ? text : text.substring(0, 200);
}

/// CDN 节点测速结果（对齐 iOS `BaiduNodeSpeedResult`）。
class _BaiduNodeSpeed {
  const _BaiduNodeSpeed({required this.url, required this.rttMs});

  final String url;
  final int rttMs;
}

/// 轻量响应（正文 + Set-Cookie + 状态/头/最终 URL）。
class _Resp {
  const _Resp({
    required this.text,
    required this.setCookies,
    this.status = 200,
    this.headers = const <String, String>{},
    this.finalUrl = '',
  });

  final String text;
  final List<String> setCookies;
  final int status;
  final Map<String, String> headers;
  final String finalUrl;
}

/// 便捷：去掉 surl 前导 1（顶层可读别名）。
String shortSurlOf(String surl) => BaiduIBoxClient.shortSurl(surl);