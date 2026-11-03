/// 核心层：HTTP 响应体解码（契约 §4.2 探测链唯一实现）。
///
/// 唯一真相源：`contract/docs/abi_v1.md` §4.2
/// 逆向来源：iOS `vbox/Services/JSHTTPBridge.swift`
///
/// 探测链（必须逐级复刻）：
/// ```
/// ① 响应头 Content-Type 的 charset
/// ② UTF-8 尝试 → 若 meta 声明非 UTF-8，用 meta charset 重新解码
/// ③ 前 4096 字节 ASCII 探测 meta charset
/// ④ 兜底链：GBK → GB2312 → Big5 → ISO-8859-1
/// ⑤ 全部失败 → base64 编码返回
/// ```
///
/// ⚠️ 契约实现说明（已在方案文档登记为待确认项）：
/// ④ 的末位 `ISO-8859-1` 是**全域映射**（任意字节序列都能解码成功），
/// 因此 ⑤ 在纯 Dart 语义下**不可达**——实践中不会触发 base64 兜底。
/// 此处保留 ⑤ 作为防御性分支，行为与契约文本一致；若需真正触发，
/// 需契约方明确「④ 失败」的判定标准（例如乱码率阈值）。
library;

import 'dart:convert';
import 'dart:typed_data';

import '../utils/charset.dart'
    show decodeBytesWith, normalizeCharset, sniffMetaCharset, sniffMetaCharsetFromText;

/// ④ 兜底链顺序（契约 §4.2）。
const List<String> kDecoderFallbackChain = <String>[
  'gbk',
  'gb2312',
  'big5',
  'latin1',
];

/// 按契约 §4.2 的探测链解码响应体。
///
/// 返回 `(文本, 是否使用 base64 兜底)`。
(String, bool) decodeResponseBody(
  Uint8List bytes, {
  String? contentTypeCharset,
  String? metaCharsetOverride,
}) {
  // ① 响应头 charset 优先
  if (contentTypeCharset != null) {
    final String cs = normalizeCharset(contentTypeCharset);
    final String? out = decodeBytesWith(bytes, cs);
    if (out != null) return (out, false);
  }

  // ② UTF-8 尝试；若 meta 声明非 UTF-8，用 meta charset 重新解码。
  //    meta 来源：调用方显式 [metaCharsetOverride] 优先，
  //    否则从 UTF-8 解码文本自探（对齐 iOS decodeText ② 级语义）
  final String? utf8Out = decodeBytesWith(bytes, 'utf-8');
  if (utf8Out != null) {
    final String? override =
        metaCharsetOverride ?? sniffMetaCharsetFromText(utf8Out);
    if (override != null) {
      final String meta = normalizeCharset(override);
      if (meta != 'utf-8') {
        final String? re = decodeBytesWith(bytes, meta);
        if (re != null) return (re, false);
      }
    }
    return (utf8Out, false);
  }

  // ③ 前 4096 字节 ASCII 区探测 meta charset
  final String? sniffed = sniffMetaCharset(bytes);
  if (sniffed != null) {
    final String? out = decodeBytesWith(bytes, normalizeCharset(sniffed));
    if (out != null) return (out, false);
  }

  // ④ 兜底链
  for (final String cs in kDecoderFallbackChain) {
    final String? out = decodeBytesWith(bytes, cs);
    if (out != null) return (out, false);
  }

  // ⑤ 全失败 → base64（防御性分支，见文件头说明）
  return (base64.encode(bytes), true);
}
