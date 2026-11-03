/// 数据层：Node 常驻系统网盘解析客户端（批次 F · F-08）。
///
/// 对齐 iOS `vbox/Services/NodePanResolver.swift`：
/// - `resolveShare`：`POST /spider/push/4/detail`，body `{"id":["<分享链接>"]}`
///   → `{list:[{vod_id,vod_name,vod_play_url,…}]}`；
/// - `resolvePlay`：`POST /spider/push/4/play`，body `{"id":"<base64id>"}`
///   → `{parse:0,url,header:{…},format}`，相对路径补 `base`。
///
/// HTTP 失败映射（对齐 iOS `postJSON`）：502/503/404 → Node 未就绪；
/// 其余非 2xx 提取响应体可读信息（`message`/`msg`/`error`/`errMsg`）后抛业务错误。
library;

import 'dart:convert';
import 'dart:io';

import '../../../domain/entities/cloud/node_pan.dart';
import '../../../platform/node/node_runtime_manager.dart';

/// Node 解析 HTTP 响应。
class NodePanHttpResponse {
  /// 构造。
  const NodePanHttpResponse({
    required this.statusCode,
    this.json = const <String, dynamic>{},
    this.rawBody = '',
  });

  /// HTTP 状态码。
  final int statusCode;

  /// 解析后的 JSON 对象（非 JSON / 非对象为空）。
  final Map<String, dynamic> json;

  /// 原始响应体（错误信息兜底提取）。
  final String rawBody;
}

/// Node 解析传输接缝（可注入）。
abstract interface class NodePanTransport {
  /// 发起 `POST [path]`（JSON body），返回响应。
  ///
  /// 连接失败 / 超时抛 [NodePanException]（`nodeUnavailable`）。
  Future<NodePanHttpResponse> postJson(
    String path,
    Map<String, dynamic> body,
  );
}

/// 缺省接缝：Node 常驻系统未接入。
class UnavailableNodePanTransport implements NodePanTransport {
  /// 构造。
  const UnavailableNodePanTransport();

  @override
  Future<NodePanHttpResponse> postJson(
    String path,
    Map<String, dynamic> body,
  ) async =>
      throw const NodePanException.nodeUnavailable();
}

/// 本机常驻 Node 进程客户端（`127.0.0.1:<port>`，默认 58080）。
///
/// 对齐 iOS `NodePanResolver`：请求 30s 超时，不做重试（失败即上报）。
class LocalNodePanTransport implements NodePanTransport {
  /// 构造。
  LocalNodePanTransport({
    this.port = 58080,
    this.timeout = const Duration(seconds: 30),
  });

  /// Node 端口。
  final int port;

  /// 单次请求超时。
  final Duration timeout;

  final HttpClient _client = HttpClient();

  /// Node 基址（对齐 iOS `NodeRuntimeManager.shared.baseURL`）。
  String get baseUrl => 'http://127.0.0.1:$port';

  @override
  Future<NodePanHttpResponse> postJson(
    String path,
    Map<String, dynamic> body,
  ) async {
    try {
      final HttpClientRequest req =
          await _client.postUrl(Uri.parse('$baseUrl$path')).timeout(timeout);
      req.headers.contentType = ContentType.json;
      req.headers.set(HttpHeaders.userAgentHeader, 'vbox/1.0');
      req.write(jsonEncode(body));
      final HttpClientResponse res = await req.close().timeout(timeout);
      final String text = await res.transform(utf8.decoder).join();
      Map<String, dynamic> json = const <String, dynamic>{};
      if (text.isNotEmpty) {
        try {
          final Object? decoded = jsonDecode(text);
          if (decoded is Map) {
            json = <String, dynamic>{
              for (final MapEntry<Object?, Object?> e in decoded.entries)
                e.key.toString(): e.value,
            };
          }
        } on FormatException {
          json = const <String, dynamic>{};
        }
      }
      return NodePanHttpResponse(
        statusCode: res.statusCode,
        json: json,
        rawBody: text,
      );
    } on NodePanException {
      rethrow;
    } catch (_) {
      throw const NodePanException.nodeUnavailable();
    }
  }

  /// 释放连接资源。
  void close() => _client.close(force: true);
}

/// Node 常驻系统网盘解析客户端。
class NodePanClient {
  /// 构造（[transport] 可注入；缺省本机 Node 客户端）。
  NodePanClient({NodePanTransport? transport})
      : _transport = transport ?? LocalNodePanTransport();

  final NodePanTransport _transport;

  /// 解析分享链接 → 可播放条目列表（对齐 iOS `resolveShare`）。
  Future<NodePanShare> resolveShare(String shareUrl) async {
    final String clean = _cleanShareUrl(shareUrl);
    if (clean.isEmpty) {
      throw const NodePanException(NodePanErrorKind.invalidShareURL);
    }
    final NodePanHttpResponse res = await _postWithWarmup(
      NodePanPaths.detail,
      <String, dynamic>{
        'id': <String>[clean],
      },
    );
    _ensureOk(res);

    final List<dynamic> list = res.json['list'] as List<dynamic>? ??
        const <dynamic>[];
    final String msg = '${res.json['msg'] ?? ''}';
    if (msg.isNotEmpty && list.isEmpty) {
      throw NodePanException(NodePanErrorKind.nodeRejected, msg);
    }
    final Object? first = list.isEmpty ? null : list.first;
    if (first is! Map) {
      throw const NodePanException(
        NodePanErrorKind.nodeRejected,
        '未解析到可播放网盘资源',
      );
    }
    final String title = '${first['vod_name'] ?? ''}'.trim();
    final String playUrl = '${first['vod_play_url'] ?? ''}';
    final List<NodePanEntry> entries = NodePanParser.parsePlayUrl(playUrl);
    if (entries.isEmpty) {
      throw const NodePanException(
        NodePanErrorKind.nodeRejected,
        '分享内未找到可播放视频',
      );
    }
    return NodePanShare(
      title: title.isEmpty ? '网盘资源' : title,
      entries: entries,
    );
  }

  /// 用 playID 换取播放地址（对齐 iOS `resolvePlay`）。
  Future<NodePanPlayData> resolvePlay(String playID) async {
    if (playID.isEmpty) {
      throw const NodePanException(NodePanErrorKind.nodeRejected, '播放参数无效');
    }
    final NodePanHttpResponse res = await _postWithWarmup(
      NodePanPaths.play,
      <String, dynamic>{'id': playID},
    );
    _ensureOk(res);

    String url = '${res.json['url'] ?? ''}';
    if (url.isEmpty) {
      final String msg = '${res.json['msg'] ?? res.json['error'] ?? ''}';
      throw NodePanException(
        NodePanErrorKind.nodeRejected,
        msg.isEmpty ? '播放地址为空' : msg,
      );
    }
    // bundle 内部代理可能返回相对路径，补全 base 后再交给播放器。
    if (url.startsWith('/')) {
      url = '${_baseUrl()}$url';
    }
    final Map<String, dynamic> rawHeaders =
        res.json['header'] is Map ? res.json['header'] as Map<String, dynamic> : const <String, dynamic>{};
    final Map<String, String> headers = <String, String>{
      for (final MapEntry<String, dynamic> e in rawHeaders.entries)
        e.key: '${e.value}',
    };
    final Object? format = res.json['format'];
    return NodePanPlayData(
      url: url,
      headers: headers,
      format: format is String && format.isNotEmpty ? format : null,
    );
  }

  String _baseUrl() => _transport is LocalNodePanTransport
      ? _transport.baseUrl
      : 'http://127.0.0.1:58080';

  /// 路由预热短重试（问题 5）：bundle spider 路由刚就绪前可能返回 404 / 502 /
  /// 503，此时 Node **进程**虽已在（横幅显示「就绪」），但解析端点尚未预热完成。
  /// 短重试等待其预热，耗尽后才由 [_ensureOk] 报 `nodeUnavailable`，使解析侧口径
  /// 与横幅口径一致（避免「横幅就绪 + 解析报未就绪」的矛盾）。
  static const int _routeWarmupRetries = 4;
  static const Duration _routeWarmupDelay = Duration(milliseconds: 700);

  Future<NodePanHttpResponse> _postWithWarmup(
    String path,
    Map<String, dynamic> body,
  ) async {
    NodePanHttpResponse res = await _transport.postJson(path, body);
    for (int i = 1;
        i <= _routeWarmupRetries && _isRouteWarmingUp(res.statusCode);
        i++) {
      await Future<void>.delayed(_routeWarmupDelay);
      res = await _transport.postJson(path, body);
    }
    return res;
  }

  static bool _isRouteWarmingUp(int statusCode) =>
      statusCode == 404 || statusCode == 502 || statusCode == 503;

  /// 清洗分享链接（去首尾空白与零宽字符，对齐 iOS）。
  static String _cleanShareUrl(String url) => url
      .trim()
      .replaceAll('\u200B', '')
      .replaceAll('\uFEFF', '');

  /// 非 2xx 映射（对齐 iOS `postJSON`）。
  static void _ensureOk(NodePanHttpResponse res) {
    final int code = res.statusCode;
    if (code >= 200 && code < 300) return;
    if (code == 502 || code == 503 || code == 404) {
      // 附带运行时管理的失败详情（如端口顶包的可操作文案），避免通用
      // 「未就绪」文案吞掉「重启电脑/结束进程」指引。
      throw NodePanException.nodeUnavailable(
        NodeRuntimeManager.instance.lastError ?? '',
      );
    }
    final String detail = _extractErrorMessage(res);
    throw NodePanException(
      NodePanErrorKind.nodeRejected,
      detail.isEmpty ? 'HTTP $code' : '$detail（HTTP $code）',
    );
  }

  /// 从响应体提取可读错误（对齐 iOS `extractErrorMessage`）。
  static String _extractErrorMessage(NodePanHttpResponse res) {
    for (final String key in <String>['message', 'msg', 'error', 'errMsg']) {
      final Object? v = res.json[key];
      if (v is String && v.isNotEmpty) return v;
    }
    final String raw = res.rawBody.trim();
    return raw.length > 200 ? raw.substring(0, 200) : raw;
  }
}
