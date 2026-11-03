/// 网盘登录网关 · 原生扫码实现（批次 F · F-05 余项）。
///
/// 承接 F-02 定义的 [CloudDriveLoginGateway] 接缝，补齐 iOS
/// `NativeCloudQRLoginView`（`SettingsViews.swift:4391`）中**不经 Node 常驻系统**
/// 的三条原生扫码链：
/// - **UC 网盘**：`api.open.uc.cn/cas/ajax/getTokenForQrcodeLogin`
///   → 本地生成二维码（`su.uc.cn` 授权链接）→ `getServiceTicketByQrcodeToken`
///   → `drive.uc.cn/account/mobileinfo` 换取 `__pus/kps/__uid` Cookie
///   （对齐 iOS `ucCreateQrToken` / `ucPollQrStatus` / `ucExchangeServiceTicket`）；
/// - **百度网盘**：`passport.baidu.com/v2/api/getqrcode`（图片二维码）
///   → `passport.baidu.com/channel/unicast` 轮询 → `qrbdusslogin` 逐跳跟随
///   重定向收集 `BDUSS/STOKEN` Cookie（对齐 iOS `baiduCreateQrToken` /
///   `baiduPollQrStatus` / `baiduExchangeQrLogin`）；
/// - **夸克网盘**：`uop.quark.cn/cas/ajax/getTokenForQrcodeLogin`
///   → 本地生成二维码（`su.quark.cn` 授权链接）→ `getServiceTicketByQrcodeToken`
///   → `pan.quark.cn/account/info` 换取 `__kps/__pus/__uid` Cookie
///   （对齐 iOS `quarkCreateQrToken` / `quarkPollQrStatus` /
///   `quarkExchangeServiceTicket`）。
///
/// 成功后统一写入契约安全存储 `cloud_drive_credentials_v1`（`authType=qr`），
/// 授权中心据此展示「已获取」。
///
/// 未覆盖：阿里（走 PG/extscreen，[AliyunPgLoginGateway]）与 Node 托管盘
/// （[NodeCloudDriveLoginGateway]）。
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

import '../../../core/utils/logger.dart';

import '../../../data/datasources/local/cloud_drive_credential_store.dart';
import '../../../data/datasources/local/prefs_manager.dart';
import '../../../domain/entities/cloud/cloud_drive.dart';
import '../../../domain/entities/cloud/cloud_drive_login.dart';
import '../../../platform/spider/spider_http_bridge.dart';
import '../../../platform/webview/baidu_native_token_bridge.dart';
import 'login_gateway.dart';

/// UC 扫码任务暂存（跨 start/poll 复用 token 与轮询 client_id）。
class _UcQrTask {
  const _UcQrTask({required this.token, required this.pollClientId});

  final String token;
  final String pollClientId;
}

/// UC TV 授权任务暂存（对齐 iOS `UCTVAuthQR`：qr_data / query_token / deviceId）。
class _UcTvTask {
  const _UcTvTask({required this.queryToken, required this.deviceId});

  final String queryToken;
  final String deviceId;
}

/// 百度扫码任务暂存（`sign` 为交换兜底参数）。
class _BaiduQrTask {
  const _BaiduQrTask({
    required this.sign,
    required this.channelId,
    required this.qrURL,
  });

  final String sign;
  final String channelId;
  final String qrURL;
}

/// 百度 enrich 结果（对齐 iOS `baiduEnrichAccountCookie` 的返回：
/// 补全后的 Cookie + extra 落库字段）。
class _BaiduEnrichResult {
  const _BaiduEnrichResult({
    required this.cookie,
    this.extra = const <String, String>{},
  });

  final String cookie;
  final Map<String, String> extra;
}

/// 夸克扫码任务暂存。
class _QuarkQrTask {
  const _QuarkQrTask({required this.token});

  final String token;
}

/// 天翼 189 扫码任务暂存（对齐 iOS `Pan189QrLoginToken`：uuid / ticket）。
class _Pan189QrTask {
  const _Pan189QrTask({required this.uuid, required this.ticket});

  final String uuid;
  final String ticket;
}

/// 原生扫码登录网关（UC / 百度 / 夸克 / 天翼 189）。
class NativeCloudDriveLoginGateway implements CloudDriveLoginGateway {
  /// 构造（[bridge] / [credentialStore] 供测试注入）。
  NativeCloudDriveLoginGateway({
    SpiderHttpBridge? bridge,
    CloudDriveCredentialStore? credentialStore,
  })  : _bridge = bridge ?? SpiderHttpBridge(),
        _store = credentialStore ??
            CloudDriveCredentialStore(PrefsManager.instance);

  final SpiderHttpBridge _bridge;
  final CloudDriveCredentialStore _store;

  /// 原生扫码覆盖的网盘（对齐 iOS 原生档；不含阿里 / Node 托管盘）。
  /// P2-1：+ 天翼 189（对齐 iOS `NativeCloudQRLoginView(.pan189)` 内
  /// `pan189Helper` 三段链路，`CloudDriveAuthManager.swift:455-603`）。
  static const Set<CloudDriveType> nativeTypes = <CloudDriveType>{
    CloudDriveType.uc,
    CloudDriveType.baidu,
    CloudDriveType.quark,
    CloudDriveType.pan189,
  };

  /// 该网关是否覆盖给定网盘 / 方式。
  static bool supports(CloudDriveType type, CloudDriveLoginMode mode) =>
      mode == CloudDriveLoginMode.nativeQr && nativeTypes.contains(type);

  // ─────────────── iOS 契约常量 ───────────────

  static const String _ucWebClientId = '381';
  static const String _ucUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) uc-cloud-drive/1.8.5 '
      'Chrome/100.0.4896.160 Electron/18.3.5.16-b62cf9c50d Safari/537.36 '
      'Channel/ucpan_other_ch';
  static const String _ucMobileUserAgent =
      'Mozilla/5.0 (Linux; Android 12; HD1900 Build/SKQ1.211113.001; wv) '
      'AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 '
      'Chrome/97.0.4692.98 Mobile Safari/537.36';
  static const String _baiduUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
  /// 夸克桌面客户端 UA（对齐 Node `gr.userAgent` 与 `QuarkNativeClient.desktopUA`，
  /// 含 `quark-cloud-drive/2.5.20` 与 `Channel/pckk_other_ch` 签名）。此前误用纯
  /// 浏览器 `Chrome/94` UA，与二维码 `sch=pckk@other_ch` 渠道口径不符，服务端据此
  /// 铸造的 token 与夸克 App「确认登录」时校验的客户端上下文不一致，被判「登录请求
  /// 已过期」（问题 1 真根因，client_id 只是表象因此 532→386 未解决）。
  static const String _quarkUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) quark-cloud-drive/2.5.20 '
      'Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 '
      'Safari/537.36 Channel/pckk_other_ch';
  /// 夸克二维码 / 轮询统一 `client_id`（对齐 Node `startQuark`/`pollQuark`：
  /// 全程 386）。此前二维码与轮询误用 532、与铸造 token 的 386 不一致，导致
  /// 夸克 App 确认登录时被服务端判「登录请求已过期」（问题 1）。
  static const String _quarkQrClientId = '386';
  /// 天翼 189 桌面 Chrome UA（对齐 iOS `pan189UserAgent`，
  /// `CloudDriveAuthManager.swift:453`）。
  static const String _pan189UserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  // UC TV OAuth 常量（对齐 iOS `CloudDriveAuthManager.swift:906-910`）。
  static const String _ucTvClientId = '5acf882d27b74502b7040b0c65519aa7';
  static const String _ucTvSignKey = 'l3srvtd7p42l0d0x1u8d7yc8ye9kki4d';
  static const String _ucTvAppVer = '1.6.8';
  static const String _ucTvChannel = 'UCTVOFFICIALWEB';
  static const String _ucTvUserAgent =
      'Mozilla/5.0 (Linux; U; Android 13; zh-cn; M2004J7AC Build/UKQ1.231108.001) '
      'AppleWebKit/533.1 (KHTML, like Gecko) Mobile Safari/533.1';

  final Map<String, _UcQrTask> _ucTasks = <String, _UcQrTask>{};
  final Map<String, _UcTvTask> _ucTvTasks = <String, _UcTvTask>{};
  final Map<String, _BaiduQrTask> _baiduTasks = <String, _BaiduQrTask>{};
  final Map<String, _QuarkQrTask> _quarkTasks = <String, _QuarkQrTask>{};
  final Map<String, _Pan189QrTask> _pan189Tasks = <String, _Pan189QrTask>{};

  // ─────────────── 扫码入口 ───────────────

  @override
  Future<CloudDriveQrTask> startQrLogin({
    required CloudDriveType type,
    required CloudDriveLoginMode mode,
    String? providerOverride,
  }) async {
    if (!supports(type, mode)) {
      throw const CloudDriveLoginException('该网盘不支持原生扫码登录');
    }
    switch (type) {
      case CloudDriveType.uc:
        return _ucStart();
      case CloudDriveType.baidu:
        return _baiduStart();
      case CloudDriveType.quark:
        return _quarkStart();
      case CloudDriveType.pan189:
        return _pan189Start();
      default:
        throw CloudDriveLoginException('${type.displayName} 原生扫码尚未接入');
    }
  }

  @override
  Future<CloudDriveLoginPhase> pollQrLogin({
    required CloudDriveType type,
    required CloudDriveLoginMode mode,
    required String taskId,
    String? providerOverride,
  }) async {
    if (!supports(type, mode)) {
      throw const CloudDriveLoginException('该网盘不支持原生扫码登录');
    }
    switch (type) {
      case CloudDriveType.uc:
        return _ucPoll(taskId);
      case CloudDriveType.baidu:
        return _baiduPoll(taskId);
      case CloudDriveType.quark:
        return _quarkPoll(taskId);
      case CloudDriveType.pan189:
        return _pan189Poll(taskId);
      default:
        throw CloudDriveLoginException('${type.displayName} 原生扫码尚未接入');
    }
  }

  @override
  Future<void> cancelQrLogin(String taskId) async {
    _ucTasks.remove(taskId);
    _ucTvTasks.remove(taskId);
    _baiduTasks.remove(taskId);
    _quarkTasks.remove(taskId);
    _pan189Tasks.remove(taskId);
  }

  // ─────────────── UC ───────────────

  Future<CloudDriveQrTask> _ucStart() async {
    final int ts = _nowMs();
    final Uri url = Uri.parse('https://api.open.uc.cn/cas/ajax/getTokenForQrcodeLogin')
        .replace(queryParameters: <String, String>{'__dt': '2951', '__t': '$ts'});
    final SpiderHttpResult res = await _bridge.request(
      url.toString(),
      options: SpiderHttpOptions(
        method: 'POST',
        headers: <String, String>{
          'Content-Type': 'application/x-www-form-urlencoded; charset=utf-8',
          'Origin': 'https://broccoli.uc.cn',
          'Referer': 'https://broccoli.uc.cn/',
          'User-Agent': _ucUserAgent,
          'Accept': '*/*',
        },
        data: 'client_id=$_ucWebClientId&request_id=$ts&v=1.2',
      ),
    );
    final Map<String, Object?>? json = _decodeMap(res.content);
    String token = _pickString(json, <String>['token', 'qrcode_token']);
    if (token.isEmpty) token = _nestedString(json, <String>['data', 'members', 'token']) ?? '';
    if (token.isEmpty) token = _nestedString(json, <String>['data', 'token']) ?? '';
    if (token.isEmpty) token = _nestedString(json, <String>['result', 'token']) ?? '';
    if (token.isEmpty) {
      throw CloudDriveLoginException(_apiMessage(json, 'UC 未返回二维码 token'));
    }
    final String taskId = 'uc_${_randomHex(16)}';
    _ucTasks[taskId] = _UcQrTask(token: token, pollClientId: _ucWebClientId);
    return (
      taskId: taskId,
      qrDataUrl: '$kQrDataContentPrefix${_ucQrPayload(token, _ucWebClientId)}',
    );
  }

  Future<CloudDriveLoginPhase> _ucPoll(String taskId) async {
    final _UcQrTask? task = _ucTasks[taskId];
    if (task == null) {
      throw const CloudDriveLoginException('扫码任务已失效，请重新生成二维码');
    }
    final int ts = _nowMs();
    final Uri url =
        Uri.parse('https://api.open.uc.cn/cas/ajax/getServiceTicketByQrcodeToken')
            .replace(queryParameters: <String, String>{'__dt': '10314', '__t': '$ts'});
    final SpiderHttpResult res = await _bridge.request(
      url.toString(),
      options: SpiderHttpOptions(
        method: 'POST',
        headers: <String, String>{
          'Content-Type': 'application/x-www-form-urlencoded; charset=utf-8',
          'Origin': 'https://broccoli.uc.cn',
          'Referer': 'https://broccoli.uc.cn/',
          'User-Agent': _ucUserAgent,
          'Accept': '*/*',
        },
        data: 'client_id=${task.pollClientId}&request_id=$ts'
            '&token=${task.token}&v=1.2',
      ),
    );
    final Map<String, Object?>? json = _decodeMap(res.content);
    final String ticket = _nestedString(json, <String>['data', 'members', 'service_ticket']) ??
        _nestedString(json, <String>['data', 'service_ticket']) ??
        _nestedString(json, <String>['result', 'service_ticket']) ??
        _pickString(json, <String>['service_ticket', 'ticket']);
    if (ticket.isNotEmpty) {
      await _ucExchange(ticket);
      _ucTasks.remove(taskId);
      return CloudDriveLoginPhase.success;
    }
    final int status = _pickInt(json, <String>['status', 'code']) ??
        _nestedInt(json, <String>['data', 'members', 'status']) ??
        _nestedInt(json, <String>['data', 'status']) ??
        -1;
    if (const <int>{50004002, 50004003, 50004004, 50004005, 50004006, 50004007}
        .contains(status)) {
      _ucTasks.remove(taskId);
      throw const CloudDriveLoginException('二维码已过期，请重试');
    }
    if (status == 50004000) return CloudDriveLoginPhase.scanned;
    return CloudDriveLoginPhase.waitingScan;
  }

  Future<void> _ucExchange(String serviceTicket) async {
    final Uri url = Uri.parse('https://drive.uc.cn/account/mobileinfo')
        .replace(queryParameters: <String, String>{
      'pr': 'UCBrowser',
      'fr': 'h5',
      '__t': '${_nowMs()}',
      'st': serviceTicket,
    });
    final SpiderHttpResult res = await _bridge.request(
      url.toString(),
      options: const SpiderHttpOptions(
        headers: <String, String>{
          'Origin': 'https://drive.uc.cn',
          'Referer': 'https://drive.uc.cn/',
          'User-Agent': _ucMobileUserAgent,
          'Accept-Language': 'zh-Hans-001;q=1.0',
          'Accept': '*/*',
        },
      ),
    );
    final Map<String, String> cookies = _cookiesFromHeaders(res.headers);
    final Map<String, Object?>? data = _asMap(_decodeMap(res.content)?['data']);
    _putCredential(cookies, '__pus', data?['__pus']);
    _putCredential(cookies, 'kps', data?['kps']);
    _putCredential(cookies, '__uid', data?['uid']);
    final String cookie = joinCookies(cookies);
    final bool ok = cookie.contains('__pus=') ||
        cookie.contains('__kps=') ||
        cookie.contains('__uid=');
    if (!ok) {
      throw const CloudDriveLoginException('UC Cookie 缺少必须字段，登录可能无效');
    }
    await _persist(
      CloudDriveType.uc,
      cookie: cookie,
      statusMessage: 'UC 扫码登录成功',
    );
  }

  /// UC 二维码内容（对齐 iOS `ucQRCodePayload`：`su.uc.cn` 授权链接）。
  static String _ucQrPayload(String token, String clientId) =>
      Uri.parse('https://su.uc.cn/1_n0ZCv').replace(queryParameters: <String, String>{
        'uc_param_str': 'frpfbive',
        'fr': 'iphone',
        'pf': '44',
        'bi': '997',
        've': '18.9.8.2995',
        'token': token,
        'client_id': clientId,
        'uc_biz_str': 'S:custom|C:titlebar_fix',
      }).toString();

  // ─────────────── UC TV 授权（P1-B，对齐 iOS `ucStartTVAuth` /
  // `ucPollTVAuth` / `ucExchangeTVCode` / `ucSaveTVToken`）───────────────

  /// x-pan-token 签名：`SHA256(method&pathname&timestamp&signKey)` hex
  /// （对齐 iOS `ucTVGenerateSign`，`CloudDriveAuthManager.swift:913`）。
  static String _ucTvGenerateSign(
    String method,
    String pathname,
    String timestamp,
  ) =>
      sha256
          .convert(utf8.encode('$method&$pathname&$timestamp&$_ucTvSignKey'))
          .toString();

  /// req_id：`MD5(deviceId+timestamp)` hex
  /// （对齐 iOS `ucTVGenerateReqId`，`CloudDriveAuthManager.swift:920`）。
  static String _ucTvGenerateReqId(String deviceId, String timestamp) =>
      md5.convert(utf8.encode('$deviceId$timestamp')).toString();

  /// UC TV 公共查询参数（对齐 iOS start/poll 两端点的共有字段）。
  static Map<String, String> _ucTvCommonQuery({
    required String deviceId,
    required String reqId,
    String? queryToken,
  }) =>
      <String, String>{
        'access_token': '',
        'activity_rect': '%7B%7D',
        'app_ver': _ucTvAppVer,
        'build_device': 'iPhone',
        'build_product': 'iPhone',
        'channel': _ucTvChannel,
        'client_id': _ucTvClientId,
        'device_brand': 'Apple',
        'device_gpu': 'Apple',
        'device_id': deviceId,
        'device_model': 'iPhone',
        'platform': 'tv',
        if (queryToken != null) 'query_token': queryToken,
        'req_id': reqId,
        'scope': 'netdisk',
      };

  /// UC TV 公共请求头（对齐 iOS `x-pan-client-id` / `x-pan-tm` / `x-pan-token`）。
  static Map<String, String> _ucTvHeaders(String pathname, String timestamp) =>
      <String, String>{
        'User-Agent': _ucTvUserAgent,
        'Accept': 'application/json, text/plain, */*',
        'x-pan-client-id': _ucTvClientId,
        'x-pan-tm': timestamp,
        'x-pan-token': _ucTvGenerateSign('GET', pathname, timestamp),
      };

  /// 启动 UC TV 授权：返回任务句柄 + base64 PNG 二维码
  /// （对齐 iOS `ucStartTVAuth`，`GET open-api-drive.uc.cn/oauth/authorize`）。
  Future<CloudDriveQrTask> startUcTvAuth() async {
    final String deviceId = _randomHex(32).toLowerCase();
    final String timestamp = '${_nowMs()}';
    const String pathname = '/oauth/authorize';
    final String reqId = _ucTvGenerateReqId(deviceId, timestamp);
    final Uri url = Uri.parse('https://open-api-drive.uc.cn$pathname')
        .replace(queryParameters: _ucTvCommonQuery(
      deviceId: deviceId,
      reqId: reqId,
    )..['qrcode'] = '1'
          ..['qr_width'] = '460'
          ..['qr_height'] = '460'
          ..['auth_type'] = 'code');
    final SpiderHttpResult res = await _bridge.request(
      url.toString(),
      options: SpiderHttpOptions(headers: _ucTvHeaders(pathname, timestamp)),
    );
    final Map<String, Object?>? json = _decodeMap(res.content);
    final int status = _pickInt(json, <String>['status']) ?? -1;
    final String qrData = _pickString(json, <String>['qr_data']);
    final String queryToken = _pickString(json, <String>['query_token']);
    if (status != 0 || qrData.isEmpty || queryToken.isEmpty) {
      throw CloudDriveLoginException(
        _apiMessage(json, 'UC TV 授权：无法获取二维码'),
      );
    }
    final String taskId = 'ucTv_${_randomHex(16)}';
    _ucTvTasks[taskId] = _UcTvTask(queryToken: queryToken, deviceId: deviceId);
    // qr_data 为 base64 PNG（对齐 iOS `UIImage(data:)` 直解）。
    return (taskId: taskId, qrDataUrl: qrData);
  }

  /// 轮询 UC TV 授权状态：返回 32 位 hex 授权码，未确认为 null；过期抛错
  /// （对齐 iOS `ucPollTVAuth`：errno 11003=继续、10002=过期）。
  Future<String?> pollUcTvAuth(String taskId) async {
    final _UcTvTask? task = _ucTvTasks[taskId];
    if (task == null) {
      throw const CloudDriveLoginException('TV 授权任务已失效，请重新获取二维码');
    }
    final String timestamp = '${_nowMs()}';
    const String pathname = '/oauth/code';
    final String reqId = _ucTvGenerateReqId(task.deviceId, timestamp);
    final Uri url = Uri.parse('https://open-api-drive.uc.cn$pathname')
        .replace(queryParameters: _ucTvCommonQuery(
      deviceId: task.deviceId,
      reqId: reqId,
      queryToken: task.queryToken,
    ));
    final SpiderHttpResult res = await _bridge.request(
      url.toString(),
      options: SpiderHttpOptions(headers: _ucTvHeaders(pathname, timestamp)),
    );
    final Map<String, Object?>? json = _decodeMap(res.content);
    // errno：11003=用户未确认（继续轮询）；10002=二维码过期；其他非零=错误。
    final int errno = _pickInt(json, <String>['errno']) ?? 0;
    if (errno == 11003) return null;
    if (errno == 10002) {
      _ucTvTasks.remove(taskId);
      throw const CloudDriveLoginException('二维码已过期，请重新获取');
    }
    if (errno != 0) {
      throw CloudDriveLoginException(
        _apiMessage(json, 'UC TV 授权错误 errno=$errno'),
      );
    }
    if ((_pickInt(json, <String>['status']) ?? 0) == -1) {
      throw CloudDriveLoginException(_apiMessage(json, 'UC TV 授权错误'));
    }
    // 成功：status=0 且 code 为 32 位 hex（对齐 iOS hexPattern 校验）。
    final RegExp hex32 = RegExp(r'^[0-9a-f]{32}$');
    final Map<String, Object?>? data = _asMap(json?['data']);
    final String code = _pickString(json, <String>['code']);
    final String nested = _pickString(data, <String>['code']);
    for (final String candidate in <String>[code, nested]) {
      if (candidate.isNotEmpty && hex32.hasMatch(candidate)) return candidate;
    }
    return null;
  }

  /// 用授权码兑换 TV Token 并并入 uc 凭据
  /// （对齐 iOS `ucExchangeTVCode` + `ucSaveTVToken`：
  /// `api.extscreen.com/ucdrive/token` POST，https 失败回退 http；
  /// extra 写 `uc_tv_token` / `uc_tv_refresh_token`，保留 Cookie）。
  Future<void> exchangeUcTvToken(String taskId, String code) async {
    final _UcTvTask? task = _ucTvTasks[taskId];
    if (task == null) {
      throw const CloudDriveLoginException('TV 授权任务已失效，请重新获取二维码');
    }
    final String timestamp = '${_nowMs()}';
    final String reqId = _ucTvGenerateReqId(task.deviceId, timestamp);
    final Map<String, Object?> body = <String, Object?>{
      'req_id': reqId,
      'app_ver': _ucTvAppVer,
      'device_id': task.deviceId,
      'device_brand': 'Apple',
      'platform': 'tv',
      'device_name': 'iPhone',
      'device_model': 'iPhone',
      'build_device': 'iPhone',
      'build_product': 'iPhone',
      'device_gpu': 'Apple',
      'activity_rect': '{}',
      'channel': _ucTvChannel,
      'code': code,
    };
    const List<String> endpoints = <String>[
      'https://api.extscreen.com/ucdrive/token',
      'http://api.extscreen.com/ucdrive/token',
    ];
    Object? lastError;
    for (final String endpoint in endpoints) {
      try {
        final SpiderHttpResult res = await _bridge.request(
          endpoint,
          options: SpiderHttpOptions(
            method: 'POST',
            headers: <String, String>{
              'Content-Type': 'application/json',
              'User-Agent': _ucTvUserAgent,
            },
            data: jsonEncode(body),
          ),
        );
        final Map<String, Object?>? json = _decodeMap(res.content);
        final int respCode = _pickInt(json, <String>['code']) ?? 200;
        if (respCode != 200) {
          throw CloudDriveLoginException(
            _apiMessage(json, 'UC TV Token 兑换失败 code=$respCode'),
          );
        }
        final Map<String, Object?> dataObj =
            _asMap(json?['data']) ?? json ?? const <String, Object?>{};
        final String accessToken = _pickString(dataObj, <String>['access_token']);
        if (accessToken.isEmpty) {
          throw const CloudDriveLoginException('UC TV Token 返回为空');
        }
        final String refreshToken =
            _pickString(dataObj, <String>['refresh_token']);
        await _mergeUcTvToken(
          accessToken: accessToken,
          refreshToken: refreshToken,
        );
        _ucTvTasks.remove(taskId);
        return;
      } catch (e) {
        lastError = e;
      }
    }
    throw lastError ??
        const CloudDriveLoginException('UC TV Token 兑换失败');
  }

  /// TV Token 并入 uc 凭据（对齐 iOS `ucSaveTVToken`：extra 追加、保留
  /// Cookie 等既有字段；凭据不存在时静默返回不报错——对齐 iOS 宽松语义，
  /// 不回滚已保存的扫码结果）。
  Future<void> _mergeUcTvToken({
    required String accessToken,
    required String refreshToken,
  }) async {
    final CloudDriveCredential? existing =
        await _store.credential(CloudDriveType.uc);
    if (existing == null) {
      // 对齐 iOS：仅记录警告，不抛错（扫码 Cookie 已正常保存）。
      return;
    }
    final Map<String, String> extra = Map<String, String>.of(existing.extra);
    extra['uc_tv_token'] = accessToken;
    if (refreshToken.isNotEmpty) extra['uc_tv_refresh_token'] = refreshToken;
    await _store.save(existing.copyWith(
      extra: extra,
      statusMessage: 'UC 已授权 TV（高速通道已就绪）',
      updatedAt: DateTime.now(),
    ));
  }

  // ─────────────── 百度 ───────────────

  Future<CloudDriveQrTask> _baiduStart() async {
    final int ts = _nowMs();
    final Uri url = Uri.parse('https://passport.baidu.com/v2/api/getqrcode')
        .replace(queryParameters: <String, String>{
      'lp': 'pc',
      'qrloginfrom': 'pc',
      'gid': _randomHex(32),
      'apiver': 'v3',
      'tt': '$ts',
    });
    final SpiderHttpResult res = await _bridge.request(
      url.toString(),
      options: const SpiderHttpOptions(
        headers: <String, String>{
          'User-Agent': _baiduUserAgent,
          'Accept': 'application/json, text/plain, */*',
        },
      ),
    );
    final Map<String, Object?>? json = _decodeMap(res.content);
    String sign = _pickString(json, <String>['sign']);
    if (sign.isEmpty) sign = _nestedString(json, <String>['data', 'sign']) ?? '';
    String channelId = _pickString(json, <String>['channel_id']);
    if (channelId.isEmpty) channelId = _nestedString(json, <String>['data', 'channel_id']) ?? sign;
    String imgurl = _pickString(json, <String>['imgurl']);
    if (imgurl.isEmpty) imgurl = _nestedString(json, <String>['data', 'imgurl']) ?? '';
    if (sign.isEmpty || imgurl.isEmpty) {
      throw CloudDriveLoginException(_apiMessage(json, '百度未返回二维码 sign/imgurl'));
    }
    final String qrURL = imgurl.startsWith('http')
        ? imgurl
        : 'https://${imgurl.replaceAll(RegExp(r'^/+'), '')}';
    final String taskId = 'baidu_${_randomHex(16)}';
    _baiduTasks[taskId] =
        _BaiduQrTask(sign: sign, channelId: channelId, qrURL: qrURL);
    // 百度返回的是**图片地址**（非文本），表现层按远程图片渲染。
    return (taskId: taskId, qrDataUrl: qrURL);
  }

  Future<CloudDriveLoginPhase> _baiduPoll(String taskId) async {
    final _BaiduQrTask? task = _baiduTasks[taskId];
    if (task == null) {
      throw const CloudDriveLoginException('扫码任务已失效，请重新生成二维码');
    }
    final Uri url = Uri.parse('https://passport.baidu.com/channel/unicast')
        .replace(queryParameters: <String, String>{
      'channel_id': task.channelId,
      'tpl': 'netdisk',
      'apiver': 'v3',
      'tt': '${_nowMs()}',
    });
    final SpiderHttpResult res = await _bridge.request(
      url.toString(),
      options: const SpiderHttpOptions(
        headers: <String, String>{
          'User-Agent': _baiduUserAgent,
          'Accept': 'application/json, text/plain, */*',
        },
      ),
    );
    final Map<String, Object?>? json = _decodeMap(res.content);
    // P1-C（问题 1）：区分「响应不可解析 / 瞬时抖动」与「真·业务错误」。
    // 响应体为空或非 JSON 时 `_decodeMap` 返回 null，此前会被兜底成 errno=-1
    // 并直接致命失败；现改为抛**可重试的瞬时失败**，由控制器按连续失败计数
    // （对齐 iOS 网络类错误重试 5 次的策略），不再一次抖动就判死。
    if (json == null) {
      throw const CloudDriveLoginException('百度轮询响应异常，请稍后重试');
    }
    final int? errnoRaw = _pickInt(json, <String>['errno']);
    if (errnoRaw == null || errnoRaw == -1) {
      throw const CloudDriveLoginException('百度轮询响应异常，请稍后重试');
    }
    final int errno = errnoRaw;
    if (errno == 1 || errno == 2) return CloudDriveLoginPhase.waitingScan;
    if (errno == 0) {
      Map<String, Object?> payload = json;
      final Object? raw = json['channel_v'];
      if (raw is String) {
        final Map<String, Object?>? nested = _decodeMap(raw);
        if (nested != null) payload = nested;
      }
      final int status = _pickInt(payload, <String>['status']) ?? -1;
      String bdussURL = _pickString(payload, <String>['bduss']);
      if (bdussURL.isEmpty) bdussURL = _pickString(payload, <String>['v']);
      if (status == 2 || bdussURL.isNotEmpty) {
        await _baiduExchange(task, bdussURL.isEmpty ? null : bdussURL);
        _baiduTasks.remove(taskId);
        return CloudDriveLoginPhase.success;
      }
      if (status == 0 || status == 1) return CloudDriveLoginPhase.scanned;
      return CloudDriveLoginPhase.waitingScan;
    }
    if (errno == 3 || errno == 4) {
      // 任务失效（过期）：抛终端态 → 控制器停止轮询并自动换码（对齐 iOS expired）。
      _baiduTasks.remove(taskId);
      throw const CloudDriveTerminalLoginException('二维码已过期，请重试');
    }
    final String msg = _pickString(json, <String>['errmsg']);
    throw CloudDriveLoginException(
      msg.isNotEmpty ? msg : '百度轮询异常 errno=$errno',
    );
  }

  Future<void> _baiduExchange(_BaiduQrTask task, String? bdussURL) async {
    final String bdussParam = _normalizeBaiduBduss(bdussURL) ?? task.sign;
    final Uri url = Uri.parse('https://passport.baidu.com/v3/login/main/qrbdusslogin')
        .replace(queryParameters: <String, String>{
      'v': '${_nowMs()}',
      'bduss': bdussParam,
      'u': 'https://pan.baidu.com/disk/main',
      'loginVersion': 'v4',
      'qrcode': '1',
      'tpl': 'netdisk',
    });
    final Map<String, String> cookies = await _collectFollowingRedirects(
      url.toString(),
      headers: <String, String>{
        'User-Agent': _baiduUserAgent,
        'Referer': 'https://pan.baidu.com/',
      },
    );
    final String cookie = joinCookies(cookies);
    if (!_isBaiduAccountCookie(cookie)) {
      // 3.1862 诊断增强：失败点留痕键名列表——区分「扫码链 Cookie 不全」
      // 与「富集被风控」两类失败（用户诉求：扫码后有没有拿到需要的 token
      // 要有日志提示）。只打键名不打值，避免凭据泄露。
      AppLog.warn(
        'baidu-auth',
        '扫码 Cookie 校验未通过：总长 ${cookie.length}，键名 '
        '[${_cookieKeyNames(cookie).join(', ')}]（要求含 BDUSS+STOKEN）',
      );
      throw const CloudDriveLoginException('百度扫码未返回完整 BDUSS/STOKEN');
    }
    // 对齐 iOS `baiduEnrichAccountCookie`（`CloudDriveAuthManager.swift:1262`）：
    // 扫码成功后补全 BFESS 系 Cookie，并把用户态 bdstoken/uk/username 落 extra
    // （播放链「保存值兜底」的数据源，对齐 iOS `saveBdstokenCredential`，
    // `CloudDriveManager.swift:4761`）。
    //
    // Windows 专属增强：先走原生 WebView2 桥补全（真实 Edge 网络栈 + 持久化 Jar）。
    // iOS 端 WKWebView 共享系统 Cookie Jar，补全天然有效；Windows 端
    // _enrichBaiduAccount 走 dart:io HttpClient（指纹被百度风控），BAIDUID 补不全、
    // bdstoken 取不到 → 落库凭据缺指纹，播放链第 4 层保存值兜底也为空。
    // 原生桥返回 Jar 全量 Cookie（含 BAIDUID/BAIDUID_BFESS）与用户态 bdstoken；
    // 非 Windows 该方法内部立即返回空，iOS/Android/macOS 行为不变。
    final native = await BaiduNativeTokenBridge.fetchBdstoken(cookie);
    // ② WinHTTP（Schannel 系统栈）直取：指纹≠dart:io，且不依赖可能被崩溃保护
    // 禁用的 WebView2。登录瞬间风控最松，直取 bdstoken + 补种 BAIDUID 指纹，
    // 作 native 之外的第二来源（native 失败时仍能落库 bdstoken）。
    final viaWinHttp = await BaiduNativeTokenBridge.fetchBdstokenWinHttp(cookie);
    final String seedCookie = (native.cookie.isEmpty && viaWinHttp.cookie.isEmpty)
        ? cookie
        : joinCookies(<String, String>{
            ..._cookieStringToMap(cookie),
            ..._cookieStringToMap(native.cookie),
            ..._cookieStringToMap(viaWinHttp.cookie),
          });
    // 原生补全后的 Cookie 继续走原 Dart 补全（仍可再补一层，取并集）。
    final _BaiduEnrichResult enriched = await _enrichBaiduAccount(seedCookie);
    final String finalCookie = joinCookies(<String, String>{
      ..._cookieStringToMap(seedCookie),
      ..._cookieStringToMap(enriched.cookie),
    });
    // 3.1862 诊断增强：扫码凭据链全景留痕（用户诉求：扫码成功后有没有获取
    // 到需要的 token 要有明确日志提示）。只打键名不打值防凭据泄露；据此可
    // 直接判定落库凭据缺哪些指纹键（BAIDUID/BAIDUID_BFESS/STOKEN 等），
    // 以及原生 WebView2 富集与 Dart 富集各自是否拿到 bdstoken。
    AppLog.info(
      'baidu-auth',
      '扫码凭据链全景：扫码 Cookie 键名 [${_cookieKeyNames(cookie).join(', ')}] | '
      '原生 WebView2 富集'
      '${native.token.isEmpty ? '未取得 bdstoken' : '取得 bdstoken（长度 ${native.token.length}）'}'
      '${native.cookie.isEmpty ? '，未返回 Jar Cookie' : '，Jar 键名 [${_cookieKeyNames(native.cookie).join(', ')}]'} | '
      'WinHTTP 富集'
      '${viaWinHttp.token.isEmpty ? '未取得 bdstoken' : '取得 bdstoken（长度 ${viaWinHttp.token.length}）'}'
      '${viaWinHttp.cookie.isEmpty ? '，未返回 Cookie' : '，Cookie 键名 [${_cookieKeyNames(viaWinHttp.cookie).join(', ')}]'} | '
      'Dart 富集 extra 键 [${enriched.extra.keys.join(', ')}] | '
      '最终落库 Cookie 键名 [${_cookieKeyNames(finalCookie).join(', ')}]，'
      '总长 ${finalCookie.length}',
    );
    // 合并既有 extra 再落库：播放链经 onFetched 回写的 bdstoken（凭据
    // `extra["bdstoken"]`，第 4 层「保存值兜底」的数据源）不得被重新扫码
    // 整体覆盖抹掉——否则云电脑上每次重登都会清空兜底值，永远回到
    // 「登录正常但取不到 bdstoken」的死循环（原生桥取不到时 native.token
    // 为空，旧实现会把已保存的 bdstoken 一并丢掉）。
    final CloudDriveCredential? existing =
        await _store.credential(CloudDriveType.baidu);
    final Map<String, String> extra = <String, String>{
      ...?existing?.extra,
      'cookie_mode': 'BDUSS_STOKEN',
      ...enriched.extra,
      // 播放链第 4 层「保存值兜底」的数据源（对齐 iOS saveBdstokenCredential）。
      // 优先级：native（WebView2）> viaWinHttp（Schannel）> enriched.extra
      // （dart:io，JA3 被风控时为空）——两条件互斥，仅一个会写入 bdstoken。
      if (native.token.isNotEmpty) 'bdstoken': native.token,
      if (native.token.isEmpty && viaWinHttp.token.isNotEmpty)
        'bdstoken': viaWinHttp.token,
      if (native.token.isNotEmpty)
        'bdstoken_source': 'native-webview2-login',
      if (native.token.isEmpty && viaWinHttp.token.isNotEmpty)
        'bdstoken_source': 'winhttp-login',
    };
    await _persist(
      CloudDriveType.baidu,
      cookie: finalCookie,
      statusMessage: '百度扫码登录成功，已保存 BDUSS/STOKEN',
      extra: extra,
    );
  }

  /// 百度扫码 Cookie 补全（对齐 iOS `baiduEnrichAccountCookie`，
  /// `CloudDriveAuthManager.swift:1262-1316`）。
  ///
  /// 扫码完成后串行访问五条「只读、不改账号、不写网盘」端点，让百度服务端
  /// 通过 Set-Cookie 补齐 BFESS 系字段（BAIDUID/STOKEN_BFESS/BDUSS_BFESS 等），
  /// 并从 gettemplatevariable 取回用户态 bdstoken/uk/username。全部 GET、
  /// 单次串行、失败静默回退，不会改账号资料、不触发风控、不阻断登录。
  Future<_BaiduEnrichResult> _enrichBaiduAccount(String cookie) async {
    final Map<String, String> merged = _cookieStringToMap(cookie);
    final Map<String, String> extra = <String, String>{};
    void putField(String key, Object? value) {
      final String? text =
          value is String ? value : (value is num ? '$value' : null);
      if (text != null && text.isNotEmpty) extra[key] = text;
    }

    /// 取用户态 bdstoken / uk / username（用当前 merged Cookie）。
    /// 对齐 iOS `baiduFetchTemplateVariables`：同时解析 `errno`，非 0 时记日志。
    Future<void> fetchUserFields() async {
      try {
        final SpiderHttpResult res = await _bridge.request(
          'https://pan.baidu.com/api/gettemplatevariable?clienttype=0&app_id=250528'
          '&web=1&fields=[%22bdstoken%22,%22uk%22,%22username%22]',
          options: SpiderHttpOptions(
            headers: <String, String>{
              'Cookie': joinCookies(merged),
              'User-Agent': _baiduUserAgent,
              'Referer': 'https://pan.baidu.com/disk/main',
            },
            timeout: const Duration(seconds: 12),
          ),
        );
        merged.addAll(_filteredCookiesFromHeaders(res.headers));
        final Map<String, Object?>? json = _decodeMap(res.content);
        final int? errno = _pickInt(json, <String>['errno']);
        if (errno != null && errno != 0) {
          AppLog.warn(
            'baidu-auth',
            'gettemplatevariable 返回 errno=$errno（登录态异常，可能未取到 bdstoken）',
            category: LogCategory.cloud,
          );
        }
        final Map<String, Object?>? result = _asMap(json?['result']);
        putField('bdstoken', result?['bdstoken'] ?? json?['bdstoken']);
        putField('uk', result?['uk'] ?? json?['uk']);
        putField('username', result?['username'] ?? json?['username']);
      } catch (_) {
        // 静默回退（对齐 iOS continue 语义）。
      }
    }

    // 对齐 iOS `baiduEnrichAccountCookie`（5 端点）：`gettemplatevariable`
    // 与其它四个端点一样参与循环，让服务端 Set-Cookie 逐跳补齐
    // `BAIDUID`/`BAIDUID_BFESS` 等跨域字段，使后续请求能取到用户态 bdstoken。
    const List<String> endpoints = <String>[
      'https://www.baidu.com/',
      'https://passport.baidu.com/center',
      'https://pan.baidu.com/disk/main',
      'https://pan.baidu.com/api/gettemplatevariable?clienttype=0&app_id=250528'
          '&web=1&fields=[%22bdstoken%22,%22uk%22,%22username%22]',
      'https://pan.baidu.com/api/getuinfo?clienttype=0&app_id=250528&web=1',
    ];
    for (final String urlString in endpoints) {
      try {
        final SpiderHttpResult res = await _bridge.request(
          urlString,
          options: SpiderHttpOptions(
            headers: <String, String>{
              'Cookie': joinCookies(merged),
              'User-Agent': _baiduUserAgent,
              'Referer': 'https://pan.baidu.com/',
            },
            timeout: const Duration(seconds: 12),
          ),
        );
        merged.addAll(_filteredCookiesFromHeaders(res.headers));
        // 对齐 iOS：gettemplatevariable 端点同时解析用户态字段。
        if (urlString.contains('gettemplatevariable')) {
          final Map<String, Object?>? json = _decodeMap(res.content);
          final int? errno = _pickInt(json, <String>['errno']);
          if (errno != null && errno != 0) {
            AppLog.warn(
            'baidu-auth',
            'gettemplatevariable 返回 errno=$errno（登录态异常，可能未取到 bdstoken）',
            category: LogCategory.cloud,
          );
          }
          final Map<String, Object?>? result = _asMap(json?['result']);
          putField('bdstoken', result?['bdstoken'] ?? json?['bdstoken']);
          putField('uk', result?['uk'] ?? json?['uk']);
          putField('username', result?['username'] ?? json?['username']);
        }
      } catch (_) {
        continue; // 单点失败静默回退（对齐 iOS continue 语义）。
      }
    }
    // 兜底：端点循环内未取到 bdstoken 时再单独试一次（对齐 iOS 二次尝试）。
    if (!extra.containsKey('bdstoken')) {
      await fetchUserFields();
    }
    // 对齐 iOS：输出补全后的 cookie 字段名清单，便于排查登录态是否完整。
    AppLog.info(
      'baidu-auth',
      '扫码 Cookie 补全后字段：${merged.keys.join(",")}',
      category: LogCategory.cloud,
    );
    if (extra.containsKey('bdstoken')) {
      AppLog.info(
        'baidu-auth',
        '扫码补全取得用户态 bdstoken（后续转存目录可直接复用）',
        category: LogCategory.cloud,
      );
    } else {
      AppLog.warn(
        'baidu-auth',
        '扫码补全未取得用户态 bdstoken（转存目录将在播放时活取）',
        category: LogCategory.cloud,
      );
    }
    return _BaiduEnrichResult(cookie: joinCookies(merged), extra: extra);
  }

  /// 百度 `bduss` 参数归一（对齐 iOS `normalizeBaiduQrBDUSSParam`）。
  static String? _normalizeBaiduBduss(String? raw) {
    if (raw == null) return null;
    String value = raw.trim();
    if (value.isEmpty) return null;
    try {
      value = Uri.decodeComponent(value);
    } catch (_) {
      // 保持原值。
    }
    final Uri? uri = Uri.tryParse(value);
    if (uri != null && uri.hasQuery) {
      final String? b =
          uri.queryParameters['bduss'] ?? uri.queryParameters['BDUSS'];
      if (b != null && b.isNotEmpty) return b;
    }
    final RegExpMatch? m = RegExp(r'(?:^|[?&])bduss=([^&\s]+)', caseSensitive: false)
        .firstMatch(value);
    return m?.group(1) ?? value;
  }

  /// 逐跳跟随 3xx 并收集各跳 `Set-Cookie`（百度登录态主要落在重定向跳）。
  Future<Map<String, String>> _collectFollowingRedirects(
    String url, {
    required Map<String, String> headers,
    int maxHops = 5,
  }) async {
    final Map<String, String> cookies = <String, String>{};
    String current = url;
    for (int hop = 0; hop <= maxHops; hop++) {
      final SpiderHttpResult res = await _bridge.request(
        current,
        options: SpiderHttpOptions(
          headers: <String, String>{
            ...headers,
            if (cookies.isNotEmpty) 'Cookie': joinCookies(cookies),
          },
          followRedirects: false,
        ),
      );
      cookies.addAll(_cookiesFromHeaders(res.headers));
      if (res.status < 300 || res.status >= 400) break;
      final String location = res.headers['location'] ?? '';
      if (location.isEmpty) break;
      current = Uri.parse(current).resolve(location).toString();
    }
    return cookies;
  }

  static bool _isBaiduAccountCookie(String cookie) =>
      cookie.contains('BDUSS=') && cookie.contains('STOKEN=');

  /// 3.1862 诊断增强：提取 Cookie 键名列表（只打键名不打值，防凭据泄露）。
  static List<String> _cookieKeyNames(String cookie) =>
      _cookieStringToMap(cookie).keys.map((String k) => k.trim()).toList();

  // ─────────────── 夸克 ───────────────

  Future<CloudDriveQrTask> _quarkStart() async {
    final Uri url = Uri.parse('https://uop.quark.cn/cas/ajax/getTokenForQrcodeLogin')
        .replace(queryParameters: <String, String>{
      'pr': 'ucpro',
      'fr': 'pc',
      'sys': 'win32',
      'client_id': _quarkQrClientId,
      'v': '1.2',
      'request_id': _randomUuid(),
    });
    final SpiderHttpResult res = await _bridge.request(
      url.toString(),
      options: const SpiderHttpOptions(
        headers: <String, String>{
          'Origin': 'https://pan.quark.cn',
          'Referer': 'https://pan.quark.cn/',
          'User-Agent': _quarkUserAgent,
          'Accept': '*/*',
        },
      ),
    );
    // 对齐 iOS `quarkCreateQrToken`：先判 HTTP 200（L4325-4327）。
    if (res.status != 200) {
      throw CloudDriveLoginException('夸克扫码 token 接口 HTTP 失败 (${res.status})');
    }
    final Map<String, Object?>? json = _decodeMap(res.content);
    final int status = _pickInt(json, <String>['status']) ?? -1;
    final String token = _nestedString(json, <String>['data', 'members', 'token']) ?? '';
    if (status != 2000000 || token.isEmpty) {
      throw CloudDriveLoginException(_apiMessage(json, '夸克扫码 token 接口异常'));
    }
    final String taskId = 'quark_${_randomHex(16)}';
    _quarkTasks[taskId] = _QuarkQrTask(token: token);
    return (
      taskId: taskId,
      qrDataUrl:
          '$kQrDataContentPrefix${_quarkQrPayload(token, _quarkQrClientId)}',
    );
  }

  Future<CloudDriveLoginPhase> _quarkPoll(String taskId) async {
    final _QuarkQrTask? task = _quarkTasks[taskId];
    if (task == null) {
      throw const CloudDriveLoginException('扫码任务已失效，请重新生成二维码');
    }
    final Uri url =
        Uri.parse('https://uop.quark.cn/cas/ajax/getServiceTicketByQrcodeToken')
            .replace(queryParameters: <String, String>{
      'pr': 'ucpro',
      'fr': 'pc',
      'sys': 'win32',
      'client_id': _quarkQrClientId,
      'v': '1.2',
      'request_id': _randomUuid(),
      'token': task.token,
    });
    final SpiderHttpResult res = await _bridge.request(
      url.toString(),
      options: const SpiderHttpOptions(
        headers: <String, String>{
          'Origin': 'https://pan.quark.cn',
          'Referer': 'https://pan.quark.cn/',
          'User-Agent': _quarkUserAgent,
          'Accept': '*/*',
        },
      ),
    );
    final Map<String, Object?>? json = _decodeMap(res.content);
    // P1-C（问题 6）：响应体为空 / 非 JSON 时按可重试的瞬时失败处理（对齐 iOS
    // 会话连续性 + 控制器连续失败容忍），不因一次抖动直接提示「登录请求已过期」。
    if (json == null) {
      throw const CloudDriveLoginException('夸克扫码状态查询失败，请稍后重试');
    }
    final int status = _pickInt(json, <String>['status']) ?? -1;
    if (status == 2000000) {
      final String ticket =
          _nestedString(json, <String>['data', 'members', 'service_ticket']) ?? '';
      if (ticket.isEmpty) {
        throw const CloudDriveLoginException('夸克未返回 service_ticket');
      }
      await _quarkExchange(ticket);
      _quarkTasks.remove(taskId);
      return CloudDriveLoginPhase.success;
    }
    if (status == 50004001) return CloudDriveLoginPhase.waitingScan;
    if (status == 50004002 || status == 50004003 || status == 50004004) {
      // 任务失效（过期）：抛终端态 → 控制器停止轮询并自动换码（对齐 iOS `.expired`）。
      _quarkTasks.remove(taskId);
      throw const CloudDriveTerminalLoginException('二维码已过期，请重试');
    }
    final String msg = _pickString(json, <String>['message']);
    throw CloudDriveLoginException(
      msg.isNotEmpty ? '夸克扫码失败：$msg' : '夸克扫码状态异常（$status）',
    );
  }

  Future<void> _quarkExchange(String serviceTicket) async {
    final Uri url = Uri.parse('https://pan.quark.cn/account/info')
        .replace(queryParameters: <String, String>{
      'st': serviceTicket,
      'fr': 'pc',
      'platform': 'pc',
    });
    // 对齐 iOS `quarkExchangeServiceTicket`（L4400-4471）：iOS 用一次性
    // ephemeral session（httpShouldSetCookies=true）让 URLSession 跨跳自动
    // 收集 Set-Cookie，再「响应头 → cookieStorage → 原始 Set-Cookie 字符串」
    // 三联兜底合并。Dart 无等价自动 cookie jar，故 `followRedirects=false`
    // 逐跳跟随，每跳同时收集 `res.setCookies`（原始多值）与展平 set-cookie
    // 头，避免只取最终单次响应头而漏掉重定向跳上的 __kps/__pus/__uid。
    final Map<String, String> cookies = <String, String>{};
    String content = '';
    int finalStatus = 0;
    String current = url.toString();
    for (int hop = 0; hop <= 5; hop++) {
      final SpiderHttpResult res = await _bridge.request(
        current,
        options: const SpiderHttpOptions(
          headers: <String, String>{
            'Origin': 'https://pan.quark.cn',
            'Referer': 'https://pan.quark.cn/',
            'User-Agent': _quarkUserAgent,
            'Accept': '*/*',
          },
          followRedirects: false,
        ),
      );
      cookies.addAll(_cookiesFromSetCookies(res.setCookies));
      cookies.addAll(_filteredCookiesFromHeaders(res.headers));
      if (res.status < 300 || res.status >= 400) {
        finalStatus = res.status;
        content = res.content;
        break;
      }
      final String location = res.headers['location'] ?? '';
      if (location.isEmpty) {
        finalStatus = res.status;
        content = res.content;
        break;
      }
      current = Uri.parse(current).resolve(location).toString();
    }
    // 对齐 iOS `quarkExchangeServiceTicket`：非 200 判交换失败（L4422-4424）。
    if (finalStatus != 200) {
      throw CloudDriveLoginException('夸克换取 Cookie HTTP 失败 ($finalStatus)');
    }
    final String cookie = joinCookies(cookies);
    for (final String key in <String>['__kps', '__pus', '__uid']) {
      if (!cookie.contains('$key=')) {
        throw CloudDriveLoginException('夸克未拿到 $key Cookie，可能扫码授权失败');
      }
    }
    final Map<String, Object?>? json = _decodeMap(content);
    final Map<String, Object?>? data = _asMap(json?['data']);
    final String nick = _pickString(data, <String>['nickname', 'nick_name']).isNotEmpty
        ? _pickString(data, <String>['nickname', 'nick_name'])
        : _pickString(json, <String>['nickname']);
    await _persist(
      CloudDriveType.quark,
      cookie: cookie,
      statusMessage: '夸克扫码登录成功',
      userName: nick.isEmpty ? null : nick,
    );
  }

  /// 夸克二维码内容（对齐 iOS `quarkQRCodePayload` 的 RFC 3986 输出）。
  /// 修复「登录请求已过期」：此前用 `Uri.replace(queryParameters:)`（form 编码）
  /// 会把 `@`→`%40`、`:`→`%3A`，与 iOS `URLComponents.queryItems`（RFC 3986，
  /// `@`/`:` 原样保留、仅 `|`→`%7C`）生成的二维码原始字符串不一致，夸克 App 扫码
  /// 后按原始串校验渠道口径时被判「已过期」。改为字符串拼接，`@`/`:` 原样、`|`
  /// 手动写 `%7C`，token 用 `encodeQueryComponent`（对齐 iOS 对 token 的处理）。
  static String _quarkQrPayload(String token, String clientId) =>
      'https://su.quark.cn/4_eMHBJ'
      '?token=${Uri.encodeQueryComponent(token)}'
      '&client_id=$clientId'
      '&sch=pckk@other_ch'
      '&sve=3.1.8'
      '&ssb=weblogin'
      '&uc_param_str='
      '&uc_biz_str=S:custom%7COPT:SAREA@0%7COPT:IMMERSIVE@1%7COPT:BACK_BTN_STYLE@0';

  // ─────────────── 天翼 189（P2-1，对齐 iOS `pan189CreateQrToken` /
  // `pan189PollQrStatus` / `pan189ExchangeCookie`，L455-603）───────────────

  Future<CloudDriveQrTask> _pan189Start() async {
    final SpiderHttpResult res = await _bridge.request(
      'https://cloud.189.cn/api/portal/getQRCodeInfo.action',
      options: const SpiderHttpOptions(
        headers: <String, String>{
          'User-Agent': _pan189UserAgent,
          'Referer': 'https://cloud.189.cn/',
        },
        timeout: Duration(seconds: 15),
      ),
    );
    // 对齐 iOS：HTTP 非 200 直接报错（`pan189CreateQrToken` L474-476）。
    if (res.status != 200) {
      throw CloudDriveLoginException('天翼云盘获取二维码 HTTP 失败 (${res.status})');
    }
    final Map<String, Object?>? json = _decodeMap(res.content);
    final int resCode = _pickInt(json, <String>['resCode']) ?? -1;
    if (resCode != 0) {
      final String msg = _pickString(json, <String>['resMessage', 'msg']);
      throw CloudDriveLoginException(
        '获取二维码失败: ${msg.isNotEmpty ? msg : '未知错误'}',
      );
    }
    final Map<String, Object?>? data = _asMap(json?['data']);
    final String uuid = _pickString(data, <String>['uuid']);
    final String ticket = _pickString(data, <String>['ticket']);
    if (uuid.isEmpty || ticket.isEmpty) {
      throw const CloudDriveLoginException('天翼云盘未返回二维码 uuid/ticket');
    }
    final String taskId = 'pan189_${_randomHex(16)}';
    _pan189Tasks[taskId] = _Pan189QrTask(uuid: uuid, ticket: ticket);
    // 对齐 iOS `qrPayload = cloud.189.cn/qrlogin?uuid=`（L493）：文本授权
    // 链接 → `qr_data:` 前缀交给 UI 本地生成二维码。
    return (
      taskId: taskId,
      qrDataUrl:
          '${kQrDataContentPrefix}https://cloud.189.cn/qrlogin?uuid=$uuid',
    );
  }

  Future<CloudDriveLoginPhase> _pan189Poll(String taskId) async {
    final _Pan189QrTask? task = _pan189Tasks[taskId];
    if (task == null) {
      throw const CloudDriveLoginException('扫码任务已失效，请重新生成二维码');
    }
    final Uri url = Uri.parse(
      'https://cloud.189.cn/api/portal/queryQRCodeStatus.action',
    ).replace(queryParameters: <String, String>{
      'ticket': task.ticket,
      'uuid': task.uuid,
    });
    final SpiderHttpResult res = await _bridge.request(
      url.toString(),
      options: const SpiderHttpOptions(
        headers: <String, String>{
          'User-Agent': _pan189UserAgent,
          'Referer': 'https://cloud.189.cn/',
        },
        timeout: Duration(seconds: 10),
      ),
    );
    final Map<String, Object?>? json = _decodeMap(res.content);
    final int resCode = _pickInt(json, <String>['resCode']) ?? -1;
    if (resCode != 0) {
      // 对齐 iOS `.failed(message:)`（L517-520）：报错但不销毁任务，可重试。
      final String msg = _pickString(json, <String>['resMessage', 'msg']);
      throw CloudDriveLoginException(
        msg.isNotEmpty ? msg : '天翼云盘查询异常',
      );
    }
    final Map<String, Object?>? data = _asMap(json?['data']);
    // 对齐 iOS 状态机（L530-544）：0=待扫 1=已扫 2=成功(loginUrl)
    // -1=过期 其他=data 缺失 → 一律按 pending。
    final int status = _pickInt(data, <String>['status']) ?? 0;
    switch (status) {
      case 1:
        return CloudDriveLoginPhase.scanned;
      case 2:
        final String loginUrl = _pickString(data, <String>['loginUrl']);
        if (loginUrl.isEmpty) {
          throw const CloudDriveLoginException('登录成功但未返回 loginUrl');
        }
        await _pan189Exchange(loginUrl);
        _pan189Tasks.remove(taskId);
        return CloudDriveLoginPhase.success;
      case -1:
        _pan189Tasks.remove(taskId);
        throw const CloudDriveLoginException('二维码已过期，请重试');
      default:
        return CloudDriveLoginPhase.waitingScan;
    }
  }

  /// 天翼 189 兑换 Cookie（对齐 iOS `pan189ExchangeCookie`，L547-603）。
  ///
  /// iOS 用独立 ephemeral session 自动跟随跳转后从 cookie jar 收集
  /// `cloud.189.cn` 全部 Cookie；Flutter 端复用 [_collectFollowingRedirects]
  /// 逐跳跟随并携带已收集 Cookie，语义等价。校验通过后 Cookie 整串落库。
  Future<void> _pan189Exchange(String loginUrl) async {
    final Map<String, String> cookies = await _collectFollowingRedirects(
      loginUrl,
      headers: <String, String>{
        'User-Agent': _pan189UserAgent,
        'Referer': 'https://cloud.189.cn/',
      },
      maxHops: 8,
    );
    final String cookie = joinCookies(cookies);
    // 对齐 iOS 登录态字段判定（L571-574）：小写包含任一标记即有效。
    final String cookieLower = cookie.toLowerCase();
    const List<String> loginMarkers = <String>[
      'ssotoken=',
      'sso_token=',
      'usersession=',
      'ec_session=',
      'castgc=',
      'islogin=',
    ];
    final bool hasLoginCookie = loginMarkers.any(cookieLower.contains);
    if (!hasLoginCookie) {
      throw const CloudDriveLoginException(
        '天翼云盘 Cookie 缺少登录态字段，登录可能无效',
      );
    }
    await _persist(
      CloudDriveType.pan189,
      cookie: cookie,
      statusMessage: '扫码授权成功',
    );
  }

  // ─────────────── 落库 ───────────────

  /// 凭据落库（`cloud_drive_credentials_v1`）；失败不阻断「登录成功」展示。
  Future<void> _persist(
    CloudDriveType type, {
    required String cookie,
    required String statusMessage,
    String? userName,
    Map<String, String>? extra,
  }) async {
    try {
      final DateTime now = DateTime.now();
      await _store.save(CloudDriveCredential(
        driveType: type.id,
        authType: CloudDriveAuthType.qr,
        cookie: cookie,
        userName: userName ?? '${type.displayName}扫码账号',
        state: CloudDriveAuthState.valid,
        statusMessage: statusMessage,
        updatedAt: now,
        lastCheckedAt: now,
        extra: extra ?? const <String, String>{},
      ));
    } catch (_) {
      // 凭据回收失败不影响登录态（对齐 iOS 网关容错）。
    }
  }

  // ─────────────── 非扫码档（原生网关不承载）───────────────

  @override
  Future<String> sendSmsCode({
    required CloudDriveType type,
    required String phone,
  }) async =>
      throw const CloudDriveLoginException('该网盘不支持验证码登录');

  @override
  Future<void> submitSmsCode({
    required CloudDriveType type,
    required String taskId,
    required String code,
  }) async =>
      throw const CloudDriveLoginException('该网盘不支持验证码登录');

  @override
  Future<CloudDriveAccountResult> submitAccountLogin({
    required CloudDriveType type,
    required CloudDriveLoginMode mode,
    required String account,
    required String password,
    String captchaCode = '',
  }) async =>
      throw const CloudDriveLoginException('该网盘不支持账号密码登录');

  @override
  Future<void> submitAccountSmsCode({
    required CloudDriveType type,
    required String code,
  }) async =>
      throw const CloudDriveLoginException('该网盘不支持账号密码登录');

  @override
  String? pendingCaptchaUrl(CloudDriveType type) => null;

  @override
  Future<String?> loadAccountCaptcha(CloudDriveType type) async => null;

  // ─────────────── 工具 ───────────────

  /// 从响应头收集 `Set-Cookie`（小写键；值按 `name=value` 提取）。
  static Map<String, String> _cookiesFromHeaders(Map<String, String> headers) {
    final Map<String, String> out = <String, String>{};
    final RegExp re = RegExp(r'([A-Za-z0-9_\-]+)=([^;,]+)');
    for (final MapEntry<String, String> e in headers.entries) {
      if (e.key.toLowerCase() != 'set-cookie') continue;
      for (final RegExpMatch m in re.allMatches(e.value)) {
        final String k = m.group(1) ?? '';
        final String v = (m.group(2) ?? '').trim();
        if (k.isNotEmpty && v.isNotEmpty) out[k] = v;
      }
    }
    return out;
  }

  /// 从原始 `Set-Cookie` 值列表提取 `name=value`（取每条目首个 `k=v` 段，
  /// 忽略 Path/Expires 等属性段）。对齐 iOS `quarkExchangeServiceTicket`
  /// 三联兜底中的「原始 Set-Cookie 字符串拆分」，比 `_cookiesFromHeaders`
  /// 更稳（不被多值 `, ` 展平破坏含逗号的属性值）。
  static Map<String, String> _cookiesFromSetCookies(List<String> setCookies) {
    final Map<String, String> out = <String, String>{};
    for (final String raw in setCookies) {
      final String firstPair = raw.split(';').first.trim();
      final int eq = firstPair.indexOf('=');
      if (eq <= 0) continue;
      final String name = firstPair.substring(0, eq).trim();
      final String value = firstPair.substring(eq + 1).trim();
      if (name.isNotEmpty && value.isNotEmpty) out[name] = value;
    }
    return out;
  }

  static void _putCredential(Map<String, String> out, String key, Object? value) {
    if (value is String && value.isNotEmpty) out[key] = value;
    if (value is num) out[key] = '$value';
  }

  /// Cookie 字典 → `a=1; b=2`（对齐 iOS `cookieDict.joined`）。
  static String joinCookies(Map<String, String> cookies) => cookies.entries
      .map((MapEntry<String, String> e) => '${e.key}=${e.value}')
      .join('; ');

  /// Cookie 属性名黑名单（对齐 iOS `mergeCookieStrings` 的 ignored 集合）。
  static const Set<String> _cookieAttrNames = <String>{
    'path', 'domain', 'expires', 'max-age', 'secure', 'httponly', 'samesite',
  };

  /// cookie 字符串 → 键值表（过滤 Path/Expires 等属性段）。
  static Map<String, String> _cookieStringToMap(String cookie) {
    final Map<String, String> out = <String, String>{};
    for (final String part in cookie.split(';')) {
      final String item = part.trim();
      final int eq = item.indexOf('=');
      if (eq <= 0) continue;
      final String name = item.substring(0, eq).trim();
      final String value = item.substring(eq + 1).trim();
      if (name.isEmpty ||
          value.isEmpty ||
          _cookieAttrNames.contains(name.toLowerCase())) {
        continue;
      }
      out[name] = value;
    }
    return out;
  }

  /// 从响应头收集 `Set-Cookie` 并过滤属性名
  /// （对齐 iOS `mergeCookieStrings` 的 ignored 语义）。
  static Map<String, String> _filteredCookiesFromHeaders(
    Map<String, String> headers,
  ) {
    final Map<String, String> raw = _cookiesFromHeaders(headers);
    return Map<String, String>.fromEntries(
      raw.entries.where(
        (MapEntry<String, String> e) =>
            !_cookieAttrNames.contains(e.key.toLowerCase()),
      ),
    );
  }

  static int _nowMs() => DateTime.now().millisecondsSinceEpoch;

  static String _randomHex(int length) {
    final math.Random rng = math.Random();
    const String hex = '0123456789abcdef';
    final StringBuffer sb = StringBuffer();
    for (int i = 0; i < length; i++) {
      sb.write(hex[rng.nextInt(16)]);
    }
    return sb.toString();
  }

  /// 小写 UUID（8-4-4-4-12；对齐 iOS `UUID().uuidString.lowercased()`）。
  static String _randomUuid() {
    final String h = _randomHex(32);
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-'
        '${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }

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

  /// 一级键取字符串（首个非空命中）。
  static String _pickString(Map<String, Object?>? json, List<String> keys) {
    if (json == null) return '';
    for (final String k in keys) {
      final Object? v = json[k];
      if (v is String && v.isNotEmpty) return v;
      if (v is num) return '$v';
    }
    return '';
  }

  /// 一级键取整数。
  static int? _pickInt(Map<String, Object?>? json, List<String> keys) {
    if (json == null) return null;
    for (final String k in keys) {
      final Object? v = json[k];
      if (v is int) return v;
      if (v is num) return v.toInt();
      if (v is String) {
        final int? parsed = int.tryParse(v);
        if (parsed != null) return parsed;
      }
    }
    return null;
  }

  /// 按路径取嵌套字符串（任一层非 Map / 缺键 → null）。
  static String? _nestedString(Map<String, Object?>? json, List<String> path) {
    Object? current = json;
    for (final String k in path) {
      final Map<String, Object?>? m = _asMap(current);
      if (m == null) return null;
      current = m[k];
    }
    return current is String ? current : null;
  }

  /// 按路径取嵌套整数。
  static int? _nestedInt(Map<String, Object?>? json, List<String> path) {
    Object? current = json;
    for (final String k in path) {
      final Map<String, Object?>? m = _asMap(current);
      if (m == null) return null;
      current = m[k];
    }
    if (current is int) return current;
    if (current is num) return current.toInt();
    if (current is String) return int.tryParse(current);
    return null;
  }

  /// 接口错误文案（`message` / `msg` / `error_info`，缺省回退）。
  static String _apiMessage(Map<String, Object?>? json, String fallback) {
    if (json == null) return fallback;
    for (final String k in <String>['message', 'msg', 'error_info', 'errmsg']) {
      final Object? v = json[k];
      if (v is String && v.isNotEmpty) return v;
    }
    return fallback;
  }
}
