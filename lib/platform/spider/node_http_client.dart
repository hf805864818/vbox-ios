/// 平台层：Node 桥 HTTP 客户端抽象 + 本机实现。
///
/// 对齐 iOS `NodeSpiderEngine`（`NodeSpiderEngine.swift:187-L226`）的桥接请求形态：
/// `POST http://127.0.0.1:<port>/spider/{nodeKey}/3/{action}` + 原生 JSON body。
/// 抽象注入点：测试注入 fake，避免真实端口依赖。
library;

import 'dart:convert';
import 'dart:io';

/// Node 桥响应（状态码 + 响应体）。
///
/// 状态码供桥引擎做 play→player 404 回退（对齐 iOS
/// `NodeSpiderError.bridge("HTTP \(statusCode)")` 判定）。
class NodeHttpResponse {
  const NodeHttpResponse({required this.statusCode, required this.body});

  /// HTTP 状态码。
  final int statusCode;

  /// 响应体（UTF-8 解码文本）。
  final String body;
}

/// Node 桥 HTTP 客户端（可注入）。
abstract class NodeHttpClient {
  /// POST [path]（如 `/spider/hanxiaoquan/3/home`），请求体 [body]（原生 JSON），
  /// 返回带状态码的响应。
  Future<NodeHttpResponse> post(String path, String body);

  /// 释放连接资源。
  Future<void> close();
}

/// 本机常驻 Node 进程客户端（`127.0.0.1:<port>`）。
class LocalNodeHttpClient implements NodeHttpClient {
  /// [port] 默认 58080（Node 源）；lx-music 用 58083。
  ///
  /// [timeout] 对齐 iOS `timeoutIntervalForRequest = 30`（NodeSpiderEngine.swift:48）。
  LocalNodeHttpClient({
    required this.port,
    this.timeout = const Duration(seconds: 30),
  });

  final int port;
  final Duration timeout;
  final HttpClient _client = HttpClient();

  @override
  Future<NodeHttpResponse> post(String path, String body) async {
    final HttpClientRequest req = await _client
        .postUrl(Uri.parse('http://127.0.0.1:$port$path'))
        .timeout(timeout);
    req.headers.contentType = ContentType.json;
    // 对齐 iOS `User-Agent: vbox/1.0`（NodeSpiderEngine.swift:202）。
    req.headers.set('User-Agent', 'vbox/1.0');
    req.write(body);
    final HttpClientResponse res = await req.close().timeout(timeout);
    final String text = await res.transform(utf8.decoder).join();
    return NodeHttpResponse(statusCode: res.statusCode, body: text);
  }

  @override
  Future<void> close() async => _client.close(force: true);
}
