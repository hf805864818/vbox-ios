/// 数据层：Emby 媒体服务器配置客户端（批次 C，对齐 iOS
/// `vbox/Views/SettingsViews.swift` 的 `EmbyConfigService` L2531-L2628）。
///
/// 对接 Node 常驻系统 kstore bundle 的 `/website/api/emby/*` 路由（五接口，
/// 与 TVS 配置中心「Emby服务器」页一致）：
///   · `GET    /website/api/emby/config`   读取服务器列表 → `{code:0, data:{data:[...]}}`
///   · `PUT    /website/api/emby/config`   保存服务器列表，body `{data:[...]}`
///   · `PUT    /website/api/emby/choose`   设为默认，body `{index}`
///   · `POST   /website/api/emby/test`     测试登录，body `{index}`
///   · `DELETE /website/api/emby/:index`   删除服务器
///
/// 请求公共语义（1:1 对齐 iOS `EmbyConfigService.request`）：
///   · Node 未就绪时等待至多 15s（500ms 轮询）；期间崩溃 → 明确报错；
///   · 仅在有 body 时声明 `Content-Type: application/json`（避免 Fastify 对
///     GET/DELETE 空 body 判 "Body cannot be empty when content-type is set"）；
///   · 非 2xx → 透出 Fastify 错误体 `message` / `msg`；`code != 0` → 抛 `msg`。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../../platform/node/node_runtime_manager.dart';

/// Emby 服务器条目（对齐 iOS `EmbyServerItem`：字段名与 Node 端 JSON 一致）。
class EmbyServerItem {
  /// 构造。
  const EmbyServerItem({
    required this.servername,
    required this.serverurl,
    required this.username,
    required this.password,
    required this.choose,
  });

  /// 从 Node JSON 反序列化（缺省字段兜底空值，对齐 iOS `fetchServers`）。
  factory EmbyServerItem.fromJson(Map<String, dynamic> json) {
    return EmbyServerItem(
      servername: '${json['servername'] ?? ''}',
      serverurl: '${json['serverurl'] ?? ''}',
      username: '${json['username'] ?? ''}',
      password: '${json['password'] ?? ''}',
      choose: (json['choose'] is num) ? (json['choose'] as num).toInt() : 0,
    );
  }

  /// 服务器名称。
  final String servername;

  /// 服务器地址（如 `http://192.168.1.10:8096`）。
  final String serverurl;

  /// 用户名。
  final String username;

  /// 密码。
  final String password;

  /// 是否默认（1 = 默认，0 = 否）。
  final int choose;

  /// 序列化为 Node JSON（字段名 1:1，对齐 iOS `saveServers`）。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'servername': servername,
        'serverurl': serverurl,
        'username': username,
        'password': password,
        'choose': choose,
      };

  /// 复制（choose 等字段可覆写）。
  EmbyServerItem copyWith({int? choose}) => EmbyServerItem(
        servername: servername,
        serverurl: serverurl,
        username: username,
        password: password,
        choose: choose ?? this.choose,
      );
}

/// Emby 配置业务错误（对齐 iOS `EmbyConfigService.EmbyError`）。
class EmbyConfigException implements Exception {
  /// 构造。
  const EmbyConfigException(this.message);

  /// 可读错误信息（直接展示在 UI 消息行）。
  final String message;

  @override
  String toString() => message;
}

/// Emby 配置 HTTP 响应。
class EmbyHttpResponse {
  /// 构造。
  const EmbyHttpResponse({required this.statusCode, this.json = const <String, dynamic>{}});

  /// HTTP 状态码。
  final int statusCode;

  /// 解析后的 JSON 对象（非 JSON / 非对象为空）。
  final Map<String, dynamic> json;
}

/// Emby 配置传输接缝（可注入以便单测；抛 [EmbyConfigException] 表示连接失败）。
abstract interface class EmbyTransport {
  /// 发起 `[method] [path]` 请求（[body] 非空 → JSON body）。
  Future<EmbyHttpResponse> request(
    String method,
    String path, {
    Map<String, dynamic>? body,
  });
}

/// 本机常驻 Node 进程传输（等就绪 + 请求，对齐 iOS `EmbyConfigService.request`）。
class LocalEmbyTransport implements EmbyTransport {
  /// 构造。
  LocalEmbyTransport({this.timeout = const Duration(seconds: 15)});

  /// 单次请求超时（对齐 iOS `request.timeoutInterval = 15`）。
  final Duration timeout;

  final HttpClient _client = HttpClient();

  /// Node 就绪等待（对齐 iOS：最多 15s、500ms 轮询、崩溃即抛）。
  Future<void> _ensureNodeReady() async {
    final NodeRuntimeManager runtime = NodeRuntimeManager.instance;
    if (runtime.isSystemReady) return;
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 15));
    while (DateTime.now().isBefore(deadline)) {
      if (runtime.isSystemReady) return;
      if (runtime.isCrashed) {
        throw const EmbyConfigException('Node 常驻系统已崩溃，请重启 App');
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    throw const EmbyConfigException('Node 常驻系统未就绪');
  }

  @override
  Future<EmbyHttpResponse> request(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    await _ensureNodeReady();
    final String url =
        '${NodeRuntimeManager.instance.baseUrl}$path';
    try {
      final HttpClientRequest req =
          await _client.openUrl(method, Uri.parse(url)).timeout(timeout);
      // 仅在有 body 时声明 JSON（对齐 iOS：空 body 声明 Content-Type 会被
      // Fastify 判 "Body cannot be empty when content-type is set"）。
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
      }
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
      return EmbyHttpResponse(statusCode: res.statusCode, json: json);
    } on EmbyConfigException {
      rethrow;
    } on Exception {
      throw const EmbyConfigException('Node 地址无效或连接失败');
    }
  }

  /// 释放连接资源。
  void close() => _client.close(force: true);
}

/// Emby 配置客户端（五接口，对齐 iOS `EmbyConfigService`）。
class EmbyConfigClient {
  /// 构造（[transport] 可注入；缺省本机 Node 传输）。
  EmbyConfigClient({EmbyTransport? transport})
      : _transport = transport ?? LocalEmbyTransport();

  final EmbyTransport _transport;

  /// 读取服务器列表（`GET /website/api/emby/config` → `data.data`）。
  Future<List<EmbyServerItem>> fetchServers() async {
    final Map<String, dynamic> json = await _request('GET', '/website/api/emby/config');
    final Object? data = json['data'];
    final Object? rawList = data is Map ? data['data'] : null;
    if (rawList is! List) return const <EmbyServerItem>[];
    return <EmbyServerItem>[
      // servername 缺失的条目跳过（对齐 iOS compactMap guard）。
      for (final Object? item in rawList)
        if (item is Map && item['servername'] != null)
          EmbyServerItem.fromJson(<String, dynamic>{
            for (final MapEntry<Object?, Object?> e in item.entries)
              e.key.toString(): e.value,
          }),
    ];
  }

  /// 保存服务器列表（`PUT /website/api/emby/config`，body `{data:[...]}`）。
  Future<void> saveServers(List<EmbyServerItem> servers) async {
    await _request(
      'PUT',
      '/website/api/emby/config',
      body: <String, dynamic>{
        'data': <Map<String, dynamic>>[
          for (final EmbyServerItem s in servers) s.toJson(),
        ],
      },
    );
  }

  /// 设为默认服务器（`PUT /website/api/emby/choose`，body `{index}`）。
  Future<void> setDefault(int index) async {
    await _request(
      'PUT',
      '/website/api/emby/choose',
      body: <String, dynamic>{'index': index},
    );
  }

  /// 测试登录（`POST /website/api/emby/test`，body `{index}`）。
  Future<void> test(int index) async {
    await _request(
      'POST',
      '/website/api/emby/test',
      body: <String, dynamic>{'index': index},
    );
  }

  /// 删除服务器（`DELETE /website/api/emby/:index`）。
  Future<void> delete(int index) async {
    await _request('DELETE', '/website/api/emby/$index');
  }

  /// 通用请求 + 响应校验（对齐 iOS `request` 后半段：非 2xx 透出
  /// `message`/`msg`；`code != 0` 抛 `msg`）。
  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final EmbyHttpResponse res =
        await _transport.request(method, path, body: body);
    if (res.statusCode < 200 || res.statusCode > 299) {
      final String msg = _extractMessage(res.json);
      throw EmbyConfigException(
        msg.isNotEmpty ? msg : 'Node 返回异常状态码（HTTP ${res.statusCode}）',
      );
    }
    final Object? code = res.json['code'];
    if (code is num && code != 0) {
      final String msg = '${res.json['msg'] ?? ''}';
      throw EmbyConfigException(msg.isNotEmpty ? msg : '操作失败（code=$code）');
    }
    return res.json;
  }

  /// 从 Fastify 错误体提取可读信息（对齐 iOS：先 `message` 后 `msg`）。
  static String _extractMessage(Map<String, dynamic> json) {
    for (final String key in <String>['message', 'msg']) {
      final Object? v = json[key];
      if (v is String && v.isNotEmpty) return v;
    }
    return '';
  }
}
