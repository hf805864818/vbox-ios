/// 数据层：B 站扫码登录客户端（批次 F · F-05）。
///
/// 对齐 iOS `BiliAuthManager.swift` 的 Node 常驻系统调用链：
/// `start` → `poll`（2s 间隔）→（成功）`NodeCredentialSyncService.saveProfile()`
/// 回收 Cookie；`cancel` / `cookie` 为辅助入口。
///
/// 协议调用经 [BiliAuthTransport] 抽象注入（UI / 测试不依赖真实端口）；
/// 缺省 [LocalBiliAuthTransport] 走 `127.0.0.1:58080`（对齐 iOS
/// `NodeRuntimeManager.shared.baseURL`），3 次退避重试。
library;

import 'dart:convert';
import 'dart:io';

import '../../../domain/entities/cloud/bili_auth.dart';

/// B 站 Node 接口传输接缝（可注入）。
abstract interface class BiliAuthTransport {
  /// 发起 [method] 请求到 [path]，返回解析后的 JSON 对象。
  ///
  /// 失败（Node 未就绪 / 非 2xx / 非 JSON）抛 [BiliAuthException]。
  Future<Map<String, dynamic>> requestJson(
    String method,
    String path, {
    Map<String, dynamic>? body,
  });
}

/// 缺省接缝：Node 常驻系统未接入（对齐 iOS `nodeNotReady`）。
class UnavailableBiliAuthTransport implements BiliAuthTransport {
  /// 构造。
  const UnavailableBiliAuthTransport();

  @override
  Future<Map<String, dynamic>> requestJson(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async =>
      throw const BiliAuthException('Node 常驻系统未就绪');
}

/// 本机常驻 Node 进程客户端（`127.0.0.1:<port>`，默认 58080）。
///
/// 对齐 iOS `BiliAuthManager` 的 `URLSession` 调用：最多 3 次重试（0.5s 递增退避）。
/// 注意 B 站 `start` / `poll` 响应为**扁平结构**（无 `code == 0` 强校验由调用方完成），
/// 故此处仅校验 HTTP 2xx 与 JSON 可解析。
class LocalBiliAuthTransport implements BiliAuthTransport {
  /// 构造（[port] 默认 58080；[timeout] 单次超时；[attempts] 最大尝试次数）。
  LocalBiliAuthTransport({
    this.port = 58080,
    this.timeout = const Duration(seconds: 20),
    this.attempts = 3,
  });

  /// Node 端口。
  final int port;

  /// 单次请求超时。
  final Duration timeout;

  /// 最大尝试次数。
  final int attempts;

  final HttpClient _client = HttpClient();

  @override
  Future<Map<String, dynamic>> requestJson(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    BiliAuthException last = const BiliAuthException('未知错误');
    for (int attempt = 1; attempt <= attempts; attempt++) {
      try {
        final HttpClientRequest req = await _client
            .openUrl(method, Uri.parse('http://127.0.0.1:$port$path'))
            .timeout(timeout);
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body ?? <String, dynamic>{}));
        final HttpClientResponse res = await req.close().timeout(timeout);
        if (res.statusCode < 200 || res.statusCode >= 300) {
          throw BiliAuthException('HTTP ${res.statusCode}');
        }
        final String text = await res.transform(utf8.decoder).join();
        final Object? decoded =
            text.isEmpty ? <String, dynamic>{} : jsonDecode(text);
        if (decoded is! Map) {
          throw const BiliAuthException('响应解析失败');
        }
        return <String, dynamic>{
          for (final MapEntry<Object?, Object?> e in decoded.entries)
            e.key.toString(): e.value,
        };
      } catch (e) {
        last = e is BiliAuthException ? e : BiliAuthException('$e');
        if (attempt < attempts) {
          await Future<void>.delayed(Duration(milliseconds: 500 * attempt));
        }
      }
    }
    throw last;
  }

  /// 释放连接资源。
  void close() => _client.close(force: true);
}

/// 一次轮询的结果（对齐 iOS `pollLoginStatus` 解析出的三要素）。
typedef BiliPollResult = ({BiliAuthStatus status, bool terminal, String msg});

/// B 站扫码登录客户端。
class BiliAuthClient {
  /// 构造（[transport] 可注入；缺省本机 Node 客户端）。
  BiliAuthClient({BiliAuthTransport? transport})
      : _transport = transport ?? LocalBiliAuthTransport();

  final BiliAuthTransport _transport;

  /// Step 1：生成二维码（对齐 iOS `requestQrCode()`）。
  Future<BiliQrStart> startQrLogin() async {
    final Map<String, dynamic> json = await _transport.requestJson(
      'POST',
      BiliAuthPaths.start,
    );
    final Object? code = json['code'];
    final String msg = '${json['msg'] ?? ''}';
    final bool ok = code is int ? code == 0 : '${code ?? ''}' == '0';
    final Object? taskId = json['taskId'];
    if (!ok || taskId is! String || taskId.isEmpty) {
      throw BiliAuthException(
        msg.isEmpty ? '二维码数据格式异常' : msg,
      );
    }
    return BiliQrStart(
      taskId: taskId,
      qrUrl: '${json['qrUrl'] ?? ''}',
      qrImage: '${json['qrImage'] ?? ''}',
      msg: msg,
    );
  }

  /// Step 2：轮询一次扫码状态（对齐 iOS `pollLoginStatus(taskId:)`）。
  Future<BiliPollResult> pollQrLogin(String taskId) async {
    final Map<String, dynamic> json = await _transport.requestJson(
      'POST',
      BiliAuthPaths.poll,
      body: <String, dynamic>{
        'provider': BiliAuthPaths.provider,
        'taskId': taskId,
      },
    );
    final String msg = '${json['msg'] ?? ''}';
    return (
      status: BiliAuthStatus.fromWire('${json['status'] ?? ''}', msg: msg),
      terminal: json['terminal'] == true,
      msg: msg,
    );
  }

  /// 取消扫码任务（对齐 iOS `cancel()`；失败不抛，幂等）。
  Future<void> cancelQrLogin(String taskId) async {
    try {
      await _transport.requestJson(
        'POST',
        BiliAuthPaths.cancel,
        body: <String, dynamic>{
          'provider': BiliAuthPaths.provider,
          'taskId': taskId,
        },
      );
    } catch (_) {
      // 取消为幂等操作，失败不向上冒泡（对齐 iOS 容错）。
    }
  }

  /// 写入 B 站 Cookie（`PUT /website/api/bili/cookie`）。
  Future<void> saveCookie(String cookie) async {
    await _transport.requestJson(
      'PUT',
      BiliAuthPaths.cookie,
      body: <String, dynamic>{'cookie': cookie},
    );
  }

  /// 清除 B 站 Cookie（`DELETE /website/api/bili/cookie`）。
  Future<void> clearCookie() async {
    await _transport.requestJson('DELETE', BiliAuthPaths.cookie);
  }
}
