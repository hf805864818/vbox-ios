/// 领域层：蜘蛛 HTTP 桥接（编码探测 + 请求参数）。
///
/// 唯一真相源：`contract/docs/abi_v1.md` §4「HTTP 回调协议」
/// 逆向来源：iOS `vbox/Services/JSHTTPBridge.swift`
///
/// ⚠️ 编码探测链必须复刻（契约 §4.2）：
/// ```
/// ① 响应头 Content-Type 的 charset
/// ② UTF-8 尝试 → 若 meta 声明非 UTF-8，用 meta charset 重新解码
/// ③ 前 4096 字节 ASCII 探测 meta charset
/// ④ 兜底链：GBK → GB2312 → Big5 → ISO-8859-1
/// ⑤ 全部失败 → base64 编码返回
/// ```
library;

import 'dart:typed_data';

// ─────────────────────────────────────────────────────────
// 实现迁至核心层（消除契约逻辑双份漂移）
//
// 契约 §4.2 的编码探测链唯一实现位于：
//   lib/core/utils/charset.dart              —— 字符集原语 + 码表注册
//   lib/core/network/http_body_decoder.dart  —— 探测链与 base64 兜底
// 此处 re-export，保持 `spider.dart` barrel 对外符号（normalizeCharset /
// charsetFromContentType / sniffMetaCharset / registerCharsetTables /
// decodeResponseBody）不变。
// ─────────────────────────────────────────────────────────

export '../../../core/network/http_body_decoder.dart';
export '../../../core/utils/charset.dart';

/// HTTP 请求参数（对齐契约 §4.1）。
class SpiderHttpRequest {
  const SpiderHttpRequest({
    required this.url,
    this.headers = const <String, String>{},
    this.method = 'GET',
    this.data,
    this.timeoutSeconds = defaultTimeout,
    this.sslBypass = false,
  });

  /// HTTP 默认超时（契约 §6：15 秒）。
  static const double defaultTimeout = 15.0;

  final String url;
  final Map<String, String> headers;
  final String method;

  /// POST body。
  final String? data;
  final double timeoutSeconds;

  /// SSL 绕过（仅福利 JS Spider 使用，契约 §4.3）。
  final bool sslBypass;
}

/// HTTP 响应。
class SpiderHttpResponse {
  const SpiderHttpResponse({
    required this.status,
    required this.headers,
    required this.body,
    this.rawBytes,
  });

  final int status;
  final Map<String, String> headers;

  /// 已按编码探测链解码的文本。
  final String body;

  /// 原始字节（供 `getBytes` 类调用）。
  final Uint8List? rawBytes;
}
