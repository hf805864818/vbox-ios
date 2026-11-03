/// 数据层：extscreen API 客户端（批次 F · F-04）。
///
/// 对齐 iOS `vbox/Services/ExtscreenAPIClient.swift`：完整扫码授权链 ——
/// 取时间戳 → 生成二维码 → 轮询扫码状态 → `authCode` 换 `refresh_token` →
/// `refresh_token` 刷新 `access_token`。
///
/// 协议调用经 [ExtscreenTransport] 抽象注入（UI/测试不依赖真实网络）；
/// 缺省 [CoreExtscreenTransport] 走核心层 `HttpClient`。
library;

import 'dart:async';
import 'dart:convert';

import '../../../core/network/http_client.dart';
import '../../../domain/entities/cloud/aliyun_extscreen.dart';

/// 单次 HTTP 结果（[body] 为解码后文本）。
class ExtscreenHttpResult {
  /// 构造。
  const ExtscreenHttpResult({required this.statusCode, required this.body});

  /// 状态码。
  final int statusCode;

  /// 响应文本。
  final String body;
}

/// extscreen 传输接缝（可注入）。
abstract interface class ExtscreenTransport {
  /// 发送请求。
  Future<ExtscreenHttpResult> request({
    required String method,
    required Uri url,
    Map<String, String>? headers,
    Map<String, dynamic>? jsonBody,
  });
}

/// 缺省传输：核心层 `HttpClient`。
class CoreExtscreenTransport implements ExtscreenTransport {
  /// 构造（[client] 便于测试注入）。
  CoreExtscreenTransport({HttpClient? client}) : _client = client ?? HttpClient();

  final HttpClient _client;

  @override
  Future<ExtscreenHttpResult> request({
    required String method,
    required Uri url,
    Map<String, String>? headers,
    Map<String, dynamic>? jsonBody,
  }) async {
    final HttpClientResponse res = method.toUpperCase() == 'GET'
        ? await _client.get(url, headers: headers)
        : await _client.postJson(url, json: jsonBody, headers: headers);
    return ExtscreenHttpResult(statusCode: res.statusCode, body: res.text);
  }
}

/// 解密后的令牌结果（对齐 iOS `ExtscreenTokenResult`）。
class ExtscreenToken {
  /// 构造。
  const ExtscreenToken({
    required this.accessToken,
    this.refreshToken,
    this.expiresIn,
    this.tokenType,
  });

  /// 访问令牌。
  final String accessToken;

  /// 新刷新令牌（服务端可能不返回）。
  final String? refreshToken;

  /// 有效期（秒）。
  final int? expiresIn;

  /// 令牌类型。
  final String? tokenType;
}

/// extscreen API 客户端。
class ExtscreenApiClient {
  /// 构造（[transport] / [delay] 便于测试注入）。
  ExtscreenApiClient({
    ExtscreenTransport? transport,
    Future<void> Function(Duration)? delay,
    this.pollInterval = const Duration(seconds: 3),
    this.timeout = const Duration(seconds: 120),
  })  : _transport = transport ?? CoreExtscreenTransport(),
        _delay = delay ?? Future<void>.delayed;

  /// API 基础地址。
  static const String baseUrl = 'https://api.extscreen.com';

  /// 阿里开放平台地址（扫码状态轮询）。
  static const String openApiBase = 'https://openapi.alipan.com';

  /// 业务成功码。
  static const int codeOk = 200;

  final ExtscreenTransport _transport;
  final Future<void> Function(Duration) _delay;

  /// 轮询间隔。
  final Duration pollInterval;

  /// 轮询总超时。
  final Duration timeout;

  // ── Step 0：获取时间戳 ─────────────────────────────────

  /// 从 extscreen 获取服务器时间戳（对齐 `getTimestamp()`）。
  Future<String> getTimestamp() async {
    final ExtscreenHttpResult res = await _transport.request(
      method: 'GET',
      url: Uri.parse('$baseUrl/timestamp'),
    );
    if (res.statusCode != 200) {
      throw const ExtscreenException('获取 extscreen 时间戳失败');
    }
    final Object? decoded = _tryDecode(res.body);
    if (decoded is! Map ||
        decoded['code'] != codeOk ||
        decoded['data'] is! Map) {
      throw const ExtscreenException('获取 extscreen 时间戳失败');
    }
    final Object? ts = (decoded['data'] as Map)['timestamp'];
    if (ts == null) {
      throw const ExtscreenException('获取 extscreen 时间戳失败');
    }
    return '$ts';
  }

  // ── Step 1：生成二维码 ─────────────────────────────────

  /// 生成扫码登录二维码（对齐 `getQrcode(crypto:)`）。
  ///
  /// 返回 `(qrLink, sid)`；`qrLink` 为需渲染成二维码的授权链接。
  Future<({String qrLink, String sid})> getQrcode(
    ExtscreenCrypto crypto,
  ) async {
    const String apiPath = '/v2/qrcode';
    final Map<String, dynamic> plainBody = <String, dynamic>{
      'scopes': 'user:base,file:all:read,file:all:write',
      'width': 500,
      'height': 500,
    };
    final Map<String, dynamic> requestBody = _envelope(crypto, plainBody);
    final String sign = crypto.computeSign(method: 'POST', apiPath: apiPath);

    final ExtscreenHttpResult res = await _transport.request(
      method: 'POST',
      url: Uri.parse('$baseUrl/aliyundrive$apiPath'),
      headers: crypto.headers(sign),
      jsonBody: requestBody,
    );
    if (res.statusCode != 200) {
      throw const ExtscreenException('生成二维码失败');
    }

    final _EncryptedEnvelope env = _parseEnvelope(res.body);
    final String decrypted = crypto.decrypt(
      ciphertextBase64: env.ciphertext,
      ivHex: env.iv,
      t: env.t,
    );
    final Object? result = _tryDecode(decrypted);
    final Object? sid = result is Map ? result['sid'] : null;
    if (sid is! String || sid.isEmpty) {
      throw const ExtscreenException('生成二维码失败');
    }
    return (
      qrLink: 'https://www.aliyundrive.com/o/oauth/authorize?sid=$sid',
      sid: sid,
    );
  }

  // ── Step 2：轮询扫码状态 ───────────────────────────────

  /// 轮询扫码授权状态（对齐 `pollQrcodeStatus(sid:timeout:onStatusChange:)`）。
  ///
  /// 网络错误 / 非 200 / 解码失败均重试；成功后返回 `authCode`。
  /// 状态档：`New` / `Scaned` / `Expired` / `LoginSuccess`。
  Future<String> pollQrcodeStatus({
    required String sid,
    void Function(String status)? onStatusChange,
  }) async {
    final Uri url =
        Uri.parse('$openApiBase/oauth/qrcode/$sid/status');
    final Stopwatch sw = Stopwatch()..start();

    while (sw.elapsed < timeout) {
      await _delay(pollInterval);

      ExtscreenHttpResult res;
      try {
        res = await _transport.request(method: 'GET', url: url);
      } on Object {
        continue;
      }
      if (res.statusCode != 200) continue;

      final Object? decoded = _tryDecode(res.body);
      if (decoded is! Map) continue;

      final String status = '${decoded['status'] ?? ''}';
      onStatusChange?.call(status);

      if (status == 'LoginSuccess') {
        final Object? authCode = decoded['authCode'];
        if (authCode is! String || authCode.isEmpty) {
          throw const ExtscreenException('authCode 换取 token 失败');
        }
        return authCode;
      }
      if (status == 'Expired') {
        throw const ExtscreenException('扫码超时，请重试');
      }
    }
    throw const ExtscreenException('扫码超时，请重试');
  }

  /// 单次查询扫码状态（非阻塞；供控制器按自身节奏轮询）。
  ///
  /// 返回 `(status, authCode)`：状态档 `New` / `Scaned` / `Expired` /
  /// `LoginSuccess`；`authCode` 仅在 `LoginSuccess` 时非空。
  /// 网络错误 / 非 200 / 解码失败按「未就绪」返回 `New`（不抛，交由上层重试）。
  Future<({String status, String? authCode})> queryQrcodeStatus({
    required String sid,
  }) async {
    final Uri url = Uri.parse('$openApiBase/oauth/qrcode/$sid/status');
    ExtscreenHttpResult res;
    try {
      res = await _transport.request(method: 'GET', url: url);
    } on Object {
      return (status: 'New', authCode: null);
    }
    if (res.statusCode != 200) return (status: 'New', authCode: null);
    final Object? decoded = _tryDecode(res.body);
    if (decoded is! Map) return (status: 'New', authCode: null);
    final String status = '${decoded['status'] ?? ''}';
    final Object? authCode = decoded['authCode'];
    return (
      status: status.isEmpty ? 'New' : status,
      authCode: authCode is String && authCode.isNotEmpty ? authCode : null,
    );
  }

  // ── Step 3：authCode 换 refresh_token ──────────────────

  /// 用 [authCode] 换取初始 `refresh_token`（对齐 `getRefreshToken`）。
  Future<String> getRefreshToken({
    required String authCode,
    required ExtscreenCrypto crypto,
  }) async {
    const String apiPath = '/v4/token';
    final Map<String, dynamic> requestBody = _envelope(
      crypto,
      <String, dynamic>{'code': authCode},
    );
    final String sign = crypto.computeSign(method: 'POST', apiPath: apiPath);

    final ExtscreenHttpResult res = await _transport.request(
      method: 'POST',
      url: Uri.parse('$baseUrl/aliyundrive$apiPath'),
      headers: crypto.headers(sign),
      jsonBody: requestBody,
    );
    if (res.statusCode != 200) {
      throw const ExtscreenException('authCode 换取 token 失败');
    }

    final _EncryptedEnvelope env = _parseEnvelope(res.body);
    final String decrypted = crypto.decrypt(
      ciphertextBase64: env.ciphertext,
      ivHex: env.iv,
      t: env.t,
    );
    final Object? result = _tryDecode(decrypted);
    final Object? refreshToken = result is Map ? result['refresh_token'] : null;
    if (refreshToken is! String || refreshToken.isEmpty) {
      throw const ExtscreenException('authCode 换取 token 失败');
    }
    return refreshToken;
  }

  // ── Step 4：刷新 access_token ──────────────────────────

  /// 用 [refreshToken] 刷新 `access_token`（对齐 `refreshToken`）。
  Future<ExtscreenToken> refresh({
    required String refreshToken,
    required ExtscreenCrypto crypto,
  }) async {
    const String apiPath = '/v4/token';
    final Map<String, dynamic> requestBody = _envelope(
      crypto,
      <String, dynamic>{'refresh_token': refreshToken},
    );
    final String sign = crypto.computeSign(method: 'POST', apiPath: apiPath);

    final ExtscreenHttpResult res = await _transport.request(
      method: 'POST',
      url: Uri.parse('$baseUrl/aliyundrive$apiPath'),
      headers: crypto.headers(sign),
      jsonBody: requestBody,
    );
    if (res.statusCode != 200) {
      throw const ExtscreenException('token 刷新失败');
    }

    final _EncryptedEnvelope env = _parseEnvelope(res.body);
    final String decrypted = crypto.decrypt(
      ciphertextBase64: env.ciphertext,
      ivHex: env.iv,
      t: env.t,
    );
    final Object? result = _tryDecode(decrypted);
    if (result is! Map || result['access_token'] is! String) {
      throw const ExtscreenException('token 刷新失败');
    }
    return ExtscreenToken(
      accessToken: result['access_token'] as String,
      refreshToken: result['refresh_token'] as String?,
      expiresIn: result['expires_in'] as int?,
      tokenType: result['token_type'] as String?,
    );
  }

  // ── 便捷方法：取时间戳并初始化加密器 ───────────────────

  /// 获取时间戳并初始化 [ExtscreenCrypto]（对齐 `makeCrypto()`）。
  Future<ExtscreenCrypto> makeCrypto() async =>
      ExtscreenCrypto(timestamp: await getTimestamp());

  // ── 内部工具 ───────────────────────────────────────────

  Map<String, dynamic> _envelope(
    ExtscreenCrypto crypto,
    Map<String, dynamic> plain,
  ) {
    final ({String iv, String ciphertext}) enc = crypto.encrypt(plain);
    return <String, dynamic>{'iv': enc.iv, 'ciphertext': enc.ciphertext};
  }

  /// 解析 `{code, data:{iv,ciphertext}, t, msg}`；`code != 200` 抛错误。
  _EncryptedEnvelope _parseEnvelope(String body) {
    final Object? decoded = _tryDecode(body);
    if (decoded is! Map) {
      throw const ExtscreenException('响应解析失败');
    }
    final int code = decoded['code'] is int
        ? decoded['code'] as int
        : int.tryParse('${decoded['code']}') ?? -1;
    final Object? data = decoded['data'];
    if (code != codeOk || data is! Map) {
      throw ExtscreenException('extscreen API 错误 [$code]: ${decoded['msg'] ?? 'Unknown'}');
    }
    final Object? iv = data['iv'];
    final Object? ciphertext = data['ciphertext'];
    if (iv is! String || ciphertext is! String) {
      throw const ExtscreenException('响应解析失败');
    }
    final Object? t = decoded['t'];
    return _EncryptedEnvelope(
      iv: iv,
      ciphertext: ciphertext,
      t: t == null ? null : '$t',
    );
  }

  Object? _tryDecode(String body) {
    try {
      return jsonDecode(body);
    } on FormatException {
      return null;
    }
  }
}

/// 加密响应信封（内部）。
class _EncryptedEnvelope {
  const _EncryptedEnvelope({
    required this.iv,
    required this.ciphertext,
    required this.t,
  });

  final String iv;
  final String ciphertext;
  final String? t;
}
