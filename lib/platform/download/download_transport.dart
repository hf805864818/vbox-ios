/// 平台层：下载传输接缝（G-02）。
///
/// 对齐 iOS `DownloadManager` 的 `URLSession`（fetchString / fetchData / bytes 流式），
/// 但把传输能力抽象成可注入接缝——测试用内存假件注入，生产走 [DartIoDownloadTransport]。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// 流式响应（对齐 iOS `URLSession.bytes(for:)` 的 response + bytes 流）。
class DownloadStreamResponse {
  /// 构造。
  const DownloadStreamResponse({
    required this.statusCode,
    required this.totalBytes,
    required this.bytes,
  });

  /// 状态码。
  final int statusCode;

  /// 响应头给出的总大小（未知为 -1）。
  final int totalBytes;

  /// 响应体字节流。
  final Stream<Uint8List> bytes;
}

/// 下载传输接缝（fetchString / fetchData / 流式打开）。
abstract class DownloadTransport {
  /// 请求整个响应体为 UTF-8 文本（m3u8 播放列表 / AES key 用）。
  Future<String?> fetchString(Uri uri, Map<String, String> headers);

  /// 请求整个响应体为原始字节（TS 分片 / AES key 用）。
  Future<Uint8List?> fetchData(Uri uri, Map<String, String> headers);

  /// 打开流式响应（directFile 大文件下载用；支持取消）。
  Future<DownloadStreamResponse?> openStream(
    Uri uri,
    Map<String, String> headers,
  );
}

/// 默认传输实现：`dart:io` `HttpClient`（三端可用，支持流式 + 取消）。
class DartIoDownloadTransport implements DownloadTransport {
  /// 构造（[timeout] 单次请求超时；[client] 可注入 MockClient）。
  DartIoDownloadTransport({
    HttpClient? client,
    this.timeout = const Duration(seconds: 30),
  }) : _client = client ?? _defaultClient();

  static HttpClient _defaultClient() => HttpClient()
    ..connectionTimeout = const Duration(seconds: 15);

  final HttpClient _client;
  final Duration timeout;

  /// 关闭底层客户端（测试回收用）。
  void close() => _client.close(force: true);

  Future<HttpClientRequest> _newRequest(
    Uri uri,
    Map<String, String> headers,
  ) async {
    final HttpClientRequest req = await _client.getUrl(uri);
    headers.forEach((String k, String v) => req.headers.set(k, v));
    return req;
  }

  @override
  Future<String?> fetchString(Uri uri, Map<String, String> headers) async {
    final Uint8List? data = await fetchData(uri, headers);
    return data == null ? null : String.fromCharCodes(data);
  }

  @override
  Future<Uint8List?> fetchData(Uri uri, Map<String, String> headers) async {
    try {
      final HttpClientRequest req = await _newRequest(uri, headers);
      final HttpClientResponse res = await req.close().timeout(timeout);
      if (res.statusCode >= 400) {
        await res.drain<void>();
        return null;
      }
      final BytesBuilder bb = BytesBuilder(copy: false);
      await for (final List<int> chunk in res.timeout(timeout)) {
        bb.add(chunk);
      }
      return bb.takeBytes();
    } on IOException {
      return null;
    } on TimeoutException {
      return null;
    }
  }

  @override
  Future<DownloadStreamResponse?> openStream(
    Uri uri,
    Map<String, String> headers,
  ) async {
    try {
      final HttpClientRequest req = await _newRequest(uri, headers);
      final HttpClientResponse res = await req.close().timeout(timeout);
      if (res.statusCode >= 400) {
        await res.drain<void>();
        return null;
      }
      final int total = res.contentLength;
      return DownloadStreamResponse(
        statusCode: res.statusCode,
        totalBytes: total,
        bytes: res.timeout(timeout).map(Uint8List.fromList),
      );
    } on IOException {
      return null;
    } on TimeoutException {
      return null;
    }
  }
}
