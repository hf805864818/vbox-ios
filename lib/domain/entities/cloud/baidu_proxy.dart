/// 领域层：百度网盘专用代理（批次 F · F-05）。
///
/// 对齐 iOS `BaiduProxyClient.swift` —— 通过 Cloudflare Worker 代理调用百度
/// 网盘接口，请求带 **HMAC-SHA256 签名**（用于绕开客户端 TLS 指纹风控）：
///
///   message   = path + timestamp + nonce + bodyString
///   signature = HMAC-SHA256(secret, message) 的小写 hex
///   headers   = X-Auth-Token / X-Timestamp / X-Nonce / X-Signature
///
/// 本文件只承载**纯领域**逻辑（签名 / 请求头 / 响应模型 / 端点常量），
/// 网络调用见 `data/datasources/remote/baidu_proxy_client.dart`。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

/// 百度代理端点与鉴权常量（对齐 iOS `BaiduProxyClient` 配置）。
abstract final class BaiduProxyEndpoints {
  /// Worker 代理基址。
  static const String baseUrl = 'https://vbox.ltd';

  /// 鉴权令牌（`X-Auth-Token`）。
  static const String token = '199114';

  /// HMAC 密钥（须与 Worker 端一致）。
  static const String secret = 'vbox-baidu-secret-2026-change-me';

  /// 解析分享链接。
  static const String parsePath = '/api/baidu/parse';

  /// 获取播放地址。
  static const String playPath = '/api/baidu/play';
}

/// 百度代理签名器（对齐 iOS `sendRequest` 的签名段）。
class BaiduProxySigner {
  /// 构造（[secret] 便于测试注入；缺省取 [BaiduProxyEndpoints.secret]）。
  const BaiduProxySigner({this.secret = BaiduProxyEndpoints.secret});

  /// HMAC 密钥。
  final String secret;

  /// 计算签名：`HMAC-SHA256(path + timestamp + nonce + body)` 小写 hex。
  String sign({
    required String path,
    required String timestamp,
    required String nonce,
    required String body,
  }) {
    final String message = '$path$timestamp$nonce$body';
    final crypto.Hmac mac =
        crypto.Hmac(crypto.sha256, utf8.encode(secret));
    return mac.convert(utf8.encode(message)).toString();
  }

  /// 构建鉴权请求头（不含 `Content-Type`，由传输层补齐）。
  Map<String, String> headers({
    required String path,
    required String timestamp,
    required String nonce,
    required String body,
  }) =>
      <String, String>{
        'X-Auth-Token': BaiduProxyEndpoints.token,
        'X-Timestamp': timestamp,
        'X-Nonce': nonce,
        'X-Signature': sign(
          path: path,
          timestamp: timestamp,
          nonce: nonce,
          body: body,
        ),
      };
}

/// Worker 返回的播放数据（对齐 iOS `BaiduProxyPlayData`）。
class BaiduProxyPlayData {
  /// 构造。
  const BaiduProxyPlayData({
    required this.url,
    required this.type,
    this.fileName,
    this.quality,
    this.headers,
  });

  /// 播放地址。
  final String url;

  /// 文件类型。
  final String type;

  /// 文件名（`file_name`）。
  final String? fileName;

  /// 清晰度。
  final String? quality;

  /// 播放所需请求头。
  final Map<String, String>? headers;

  /// 由 JSON 解析（缺 `url` / `type` 返回 null）。
  static BaiduProxyPlayData? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final Object? url = json['url'];
    final Object? type = json['type'];
    if (url is! String || url.isEmpty || type is! String) return null;
    final Object? rawHeaders = json['headers'];
    return BaiduProxyPlayData(
      url: url,
      type: type,
      fileName: json['file_name'] as String?,
      quality: json['quality'] as String?,
      headers: rawHeaders is Map
          ? <String, String>{
              for (final MapEntry<Object?, Object?> e in rawHeaders.entries)
                e.key.toString(): e.value.toString(),
            }
          : null,
    );
  }
}

/// Worker 顶层响应（对齐 iOS `BaiduProxyResponse`）。
class BaiduProxyResponse {
  /// 构造。
  const BaiduProxyResponse({required this.success, this.data, this.error});

  /// 是否成功。
  final bool success;

  /// 播放数据（`success` 时可能存在）。
  final BaiduProxyPlayData? data;

  /// 错误文案。
  final String? error;

  /// 由 JSON 解析（非对象返回「解析失败」响应）。
  static BaiduProxyResponse fromJson(Object? json) {
    if (json is! Map) {
      return const BaiduProxyResponse(success: false, error: '无效的 JSON 响应');
    }
    final Object? error = json['error'];
    return BaiduProxyResponse(
      success: json['success'] == true,
      data: BaiduProxyPlayData.tryFromJson(json['data']),
      error: error is String && error.isNotEmpty ? error : null,
    );
  }
}

/// 百度代理错误（文案对齐 iOS `NSError(domain:"BaiduProxy")`）。
class BaiduProxyException implements Exception {
  /// 构造。
  const BaiduProxyException(this.message, {this.statusCode});

  /// 面向用户的错误文案。
  final String message;

  /// HTTP 状态码（网络层错误时为 null）。
  final int? statusCode;

  @override
  String toString() => message;
}
