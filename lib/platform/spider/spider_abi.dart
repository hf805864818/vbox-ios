/// 平台层：Spider ABI 编解码（对齐契约 §7「ABI 消息示例」）。
///
/// 唯一真相源：`contract/docs/abi_v1.md` §7（请求/响应/错误响应）
/// 纯 Dart 无 IO 依赖，可直接单测。
library;

import 'dart:convert';

import '../../domain/entities/spider/spider_engine.dart';

/// ABI 响应（`ok/data/error/logs/elapsedMs`）。
class AbiResponse {
  const AbiResponse({
    required this.ok,
    this.data,
    this.logs = const <String>[],
    this.elapsedMs,
    this.errorCode,
    this.errorMessage,
  });

  final bool ok;

  /// 成功时数据（`data`）。
  final Map<String, Object?>? data;

  /// 日志（`logs`）。
  final List<String> logs;

  /// 耗时毫秒（`elapsedMs`）。
  final int? elapsedMs;

  /// 错误码（`error.code`，形如 `E_REGISTER`）。
  final String? errorCode;

  /// 错误信息（`error.message`）。
  final String? errorMessage;

  factory AbiResponse.fromJson(Map<String, Object?> j) {
    // 软解码（对齐 iOS `NodeSpiderEngine` 的 `JSONSerialization as?` 语义）：
    // Node 宿主的蜘蛛脚本可能把 data/error 返回为 JSON 字符串而非对象，
    // 硬 cast 会抛 `type 'String' is not a subtype of type 'Map<String, Object?>?'`，
    // 这里对字符串做二次解码兜底，非 Map 非 String 时静默置空。
    final Map<String, Object?>? err = _softDecodeObject(j['error']);
    final Map<String, Object?>? data = _softDecodeObject(j['data']);
    return AbiResponse(
      ok: j['ok'] == true,
      data: data,
      logs: (j['logs'] as List?)?.map((e) => e.toString()).toList() ??
          const <String>[],
      elapsedMs: (j['elapsedMs'] as num?)?.toInt(),
      errorCode: err?['code']?.toString(),
      errorMessage: err?['message']?.toString(),
    );
  }

  /// 信封字段软解码：Map → cast；String（JSON）→ 解码；其它 → null。
  static Map<String, Object?>? _softDecodeObject(Object? raw) {
    if (raw is Map) return raw.cast<String, Object?>();
    if (raw is String) {
      final String trimmed = raw.trim();
      if (trimmed.isEmpty || !trimmed.startsWith('{')) return null;
      try {
        final Object? decoded = jsonDecode(trimmed);
        if (decoded is Map) return decoded.cast<String, Object?>();
      } on FormatException {
        return null;
      }
    }
    return null;
  }
}

/// Spider ABI 编解码器。
class SpiderAbiCodec {
  const SpiderAbiCodec({this.timeoutMs = 15000});

  /// 契约 HTTP 默认超时 15s。
  final int timeoutMs;

  /// 组装 ABI 请求（契约 §7.1）。
  Map<String, Object?> encodeRequest(
    String op,
    Map<String, Object?> params, {
    String? siteKey,
    String? engineType,
    String? baseUrl,
    String? requestId,
  }) {
    return <String, Object?>{
      'op': op,
      'params': params,
      'ctx': <String, Object?>{
        if (siteKey != null) 'siteKey': siteKey,
        if (engineType != null) 'engineType': engineType,
        if (baseUrl != null) 'baseUrl': baseUrl,
        'timeoutMs': timeoutMs,
        if (requestId != null) 'requestId': requestId,
      },
    };
  }

  /// 解码 ABI 响应；失败时抛出 [SpiderException]（错误码映射见 §5.1）。
  AbiResponse decodeResponse(String raw) {
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      throw SpiderException(SpiderErrorCode.protocol, 'ABI 响应非 JSON: $raw');
    }
    if (decoded is! Map<String, Object?>) {
      throw const SpiderException(SpiderErrorCode.protocol, 'ABI 响应结构无效');
    }
    final AbiResponse r =
        AbiResponse.fromJson(decoded.cast<String, Object?>());
    if (!r.ok) {
      throw SpiderException(
        mapErrorCode(r.errorCode),
        r.errorMessage ?? '引擎错误 ${r.errorCode ?? '未知'}',
      );
    }
    return r;
  }

  /// 错误码映射（契约 §5.1 建议值 → [SpiderErrorCode]）。
  static SpiderErrorCode mapErrorCode(String? code) => switch (code) {
        'E_REGISTER' => SpiderErrorCode.register,
        'E_SCRIPT_LOAD' => SpiderErrorCode.scriptLoad,
        'E_PROTOCOL' => SpiderErrorCode.protocol,
        'E_TIMEOUT' => SpiderErrorCode.timeout,
        'E_RUNTIME' => SpiderErrorCode.runtime,
        'E_UNSUPPORTED' => SpiderErrorCode.unsupported,
        // 契约无取消错误码，归为协议异常
        'E_CANCELLED' => SpiderErrorCode.protocol,
        _ => SpiderErrorCode.protocol,
      };
}
