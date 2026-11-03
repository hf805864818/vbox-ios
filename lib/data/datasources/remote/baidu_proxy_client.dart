/// 数据层：百度网盘专用代理客户端（批次 F · F-05）。
///
/// 对齐 iOS `BaiduProxyClient.swift` —— 经 Cloudflare Worker 代理调用百度接口，
/// 请求带 HMAC-SHA256 签名（绕开客户端 TLS 指纹风控）：
/// `X-Auth-Token` / `X-Timestamp` / `X-Nonce` / `X-Signature`。
///
/// 另交付百度 PCS 稳定设备指纹 [BaiduPcsDeviceId]（契约敏感键
/// `baidu_local_pcs_device_id`，对齐 iOS `CloudDriveManager.baiduStableDeviceId()`）。
///
/// 协议调用经 [BaiduProxyTransport] 抽象注入（测试不依赖真实网络）；
/// 缺省 [HttpBaiduProxyTransport] 走核心层 `HttpClient`。
library;

import 'dart:convert';
import 'dart:math';

import '../../../core/network/http_client.dart';
import '../../../domain/entities/cloud/baidu_proxy.dart';
import '../local/prefs_manager.dart';

/// 百度代理传输接缝（可注入）。
abstract interface class BaiduProxyTransport {
  /// 向 `baseUrl + path` 发送签名后的 POST 请求，返回解码后的 JSON。
  ///
  /// 网络层失败应抛 [BaiduProxyException]。
  Future<Object?> postJson(
    String path,
    String body,
    Map<String, String> headers,
  );
}

/// 缺省接缝：代理未接入。
class UnavailableBaiduProxyTransport implements BaiduProxyTransport {
  /// 构造。
  const UnavailableBaiduProxyTransport();

  @override
  Future<Object?> postJson(
    String path,
    String body,
    Map<String, String> headers,
  ) async =>
      throw const BaiduProxyException('百度代理未接入');
}

/// 缺省传输：核心层 `HttpClient`（POST JSON + 签名头）。
class HttpBaiduProxyTransport implements BaiduProxyTransport {
  /// 构造（[client] 便于测试注入）。
  HttpBaiduProxyTransport({HttpClient? client}) : _client = client ?? HttpClient();

  final HttpClient _client;

  @override
  Future<Object?> postJson(
    String path,
    String body,
    Map<String, String> headers,
  ) async {
    // 必须原样发送已签名序列化的 body（经 `send` 的字符串 body 语义），
    // 不可走 `postJson`（其 `json` 参数会再次 jsonEncode，破坏签名一致性）。
    final HttpClientResponse res = await _client.send(
      'POST',
      Uri.parse('${BaiduProxyEndpoints.baseUrl}$path'),
      headers: headers,
      body: body,
    );
    if (res.text.isEmpty) return null;
    try {
      return jsonDecode(res.text);
    } on FormatException {
      return null;
    }
  }
}

/// 百度网盘专用代理客户端。
class BaiduProxyClient {
  /// 构造（[transport] / [signer] / [clock] / [nonceFactory] 供测试注入）。
  BaiduProxyClient({
    BaiduProxyTransport? transport,
    BaiduProxySigner signer = const BaiduProxySigner(),
    int Function()? clock,
    String Function()? nonceFactory,
  })  : _transport = transport ?? const UnavailableBaiduProxyTransport(),
        _signer = signer,
        _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
        _nonceFactory = nonceFactory ?? _defaultNonce;

  final BaiduProxyTransport _transport;
  final BaiduProxySigner _signer;
  final int Function() _clock;
  final String Function() _nonceFactory;

  /// 解析分享链接（对齐 iOS `parseShareLink(url:pwd:cookie:)`）。
  Future<BaiduProxyResponse> parseShareLink({
    required String url,
    String pwd = '',
    String cookie = '',
  }) =>
      _send(BaiduProxyEndpoints.parsePath, <String, dynamic>{
        'url': url,
        'pwd': pwd,
        'cookie': cookie,
      });

  /// 获取播放地址（对齐 iOS `getPlayURL(shareURL:pwd:fsId:cookie:pcsCookie:)`）。
  Future<BaiduProxyResponse> getPlayURL({
    required String shareURL,
    String pwd = '',
    String fsId = '',
    String cookie = '',
    String pcsCookie = '',
  }) =>
      _send(BaiduProxyEndpoints.playPath, <String, dynamic>{
        'url': shareURL,
        'pwd': pwd,
        'fs_id': fsId,
        'cookie': cookie,
        'pcs_cookie': pcsCookie,
      });

  /// 序列化 body → 生成签名头 → 发送 → 解析响应。
  Future<BaiduProxyResponse> _send(
    String path,
    Map<String, dynamic> params,
  ) async {
    final String body = jsonEncode(params);
    final String timestamp = '${_clock()}';
    final String nonce = _nonceFactory();
    final Map<String, String> headers = _signer.headers(
      path: path,
      timestamp: timestamp,
      nonce: nonce,
      body: body,
    );

    final Object? json = await _transport.postJson(path, body, headers);
    final BaiduProxyResponse response = BaiduProxyResponse.fromJson(json);
    if (!response.success) {
      throw BaiduProxyException(response.error ?? '百度代理请求失败');
    }
    return response;
  }

  static String _defaultNonce() {
    final Random r = Random.secure();
    final StringBuffer sb = StringBuffer();
    for (int i = 0; i < 32; i++) {
      sb.write(r.nextInt(16).toRadixString(16));
    }
    return sb.toString();
  }
}

/// 百度 PCS 稳定设备指纹（契约敏感键 `baidu_local_pcs_device_id`）。
///
/// 对齐 iOS `CloudDriveManager.baiduStableDeviceId()`：首次生成
/// **32 位大写 hex**（去横线 UUID 语义）并持久化，后续复用。
abstract final class BaiduPcsDeviceId {
  /// 契约键名。
  static const String key = 'baidu_local_pcs_device_id';

  /// 读取（不存在则生成并落安全存储）。
  ///
  /// [prefs] 缺省取 [PrefsManager.instance]；[generator] 供测试注入。
  static Future<String> ensure({
    PrefsManager? prefs,
    String Function()? generator,
  }) async {
    final PrefsManager manager = prefs ?? PrefsManager.instance;
    final String existing = await manager.getString(key);
    if (existing.isNotEmpty) return existing;
    final String generated = (generator ?? _generate)();
    await manager.set(key, generated);
    return generated;
  }

  static String _generate() {
    final Random r = Random.secure();
    final StringBuffer sb = StringBuffer();
    for (int i = 0; i < 32; i++) {
      sb.write(r.nextInt(16).toRadixString(16));
    }
    return sb.toString().toUpperCase();
  }
}
