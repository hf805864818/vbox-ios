/// 领域层：阿里 extscreen（PG / TV 端）加密链路（批次 F · F-04）。
///
/// 对齐 iOS `vbox/Services/ExtscreenCrypto.swift`（其本身从 Python `alitoken2.py`
/// 1:1 翻译），覆盖：
/// - **设备指纹**：`akv / apv / b / d / m / mac / n / t / wifiMac` 参数字典；
/// - **h() 字符变换** + **MD5 密钥派生**（`generate_key` / `generate_key_with_t`）；
/// - **AES-256-CBC 加解密**（PKCS7；明文按 key 排序紧凑 JSON）；
/// - **SHA-256 签名**（`compute_sign`）与请求头（`get_headers`）。
///
/// AES 原语复用 `MdtvAes`（同一套按 FIPS-197 自测的纯 Dart 实现），避免重复
/// 密码学代码；本文件只承载 extscreen 协议特有的派生与编解码逻辑。
library;

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;

import '../mdtv/mdtv_crypto.dart';

/// extscreen 加密错误（文案对齐 iOS `ExtscreenError`）。
class ExtscreenException implements Exception {
  /// 构造（[message] 为面向用户的文案）。
  const ExtscreenException(this.message);

  /// 面向用户的错误文案。
  final String message;

  @override
  String toString() => message;
}

/// extscreen 加密器。
///
/// [timestamp] 由 `GET /timestamp` 取得后注入；[uniqueId] 与 [wifiMac] 缺省随机
/// 生成（对齐 iOS 每次初始化生成一次）。
class ExtscreenCrypto {
  /// 构造。
  ExtscreenCrypto({
    required this.timestamp,
    String? uniqueId,
    String? wifiMac,
    Random? random,
  })  : uniqueId = uniqueId ?? _randomHex32(random ?? _rand),
        wifiMac = wifiMac ?? _randomWifiMac(random ?? _rand);

  /// 服务器时间戳（`GET /timestamp` 返回的整数转字符串）。
  final String timestamp;

  /// 设备唯一标识（32 位小写 hex）。
  final String uniqueId;

  /// 随机 12 位 wifiMac。
  final String wifiMac;

  // ── 设备参数（固定值，与 PG Python 端一致）─────────────
  static const String akv = '2.6.1143';
  static const String apv = '1.4.0.2';
  static const String brand = 'samsung';
  static const String model = 'SM-S908E';

  static final Random _rand = Random.secure();

  /// User-Agent（对齐 iOS `getHeaders`）。
  static const String userAgent =
      'Mozilla/5.0 (Linux; U; Android 15; zh-cn; SM-S908E Build/UKQ1.231108.001) '
      'AppleWebKit/533.1 (KHTML, like Gecko) Mobile Safari/533.1';

  /// Host（对齐 iOS `getHeaders`）。
  static const String host = 'api.extscreen.com';

  /// 设备参数字典（对齐 iOS `getParams()`）。
  Map<String, String> get params => <String, String>{
        'akv': akv,
        'apv': apv,
        'b': brand,
        'd': uniqueId,
        'm': model,
        'mac': '',
        'n': model,
        't': timestamp,
        'wifiMac': wifiMac,
      };

  // ── h() 字符变换 ───────────────────────────────────────

  /// 自定义字符变换（对应 Python `h(char_array, modifier)`）。
  ///
  /// 去重保序 → 从 [modifier] 第 8 位起取数值（不足 8 位取 0）→ 对 127 取模 →
  /// 逐字符 `abs(code - modVal - 1)`，小于 33 补 33。
  String h(String input, String modifier) {
    final Set<int> seen = <int>{};
    final List<int> unique = <int>[];
    for (final int code in input.codeUnits) {
      if (seen.add(code)) unique.add(code);
    }

    final String numericModifierStr =
        modifier.length > 7 ? modifier.substring(7) : '0';
    final int modVal = (int.tryParse(numericModifierStr) ?? 0) % 127;

    final StringBuffer result = StringBuffer();
    for (final int code in unique) {
      int newCode = (code - modVal - 1).abs();
      if (newCode < 33) newCode += 33;
      if (newCode > 0 && newCode < 256) {
        result.writeCharCode(newCode);
      }
    }
    return result.toString();
  }

  // ── 密钥生成 ───────────────────────────────────────────

  /// 使用 [timestamp] 生成 AES 密钥（对齐 `generateKey()`）。
  String generateKey() => generateKeyWithTimestamp(timestamp);

  /// 使用指定时间戳 [t] 生成 AES 密钥（对齐 `generateKey(withTimestamp:)`）。
  ///
  /// 参数按 key 升序拼接（排除 `t`）→ [h] 变换 → MD5 hex（32 字符，UTF-8 作
  /// AES-256 密钥）。
  String generateKeyWithTimestamp(String t) {
    final Map<String, String> p = params..['t'] = t;
    final List<String> keys = p.keys.toList()..sort();
    final String concatenated =
        keys.where((String k) => k != 't').map((String k) => p[k] ?? '').join();
    final String hashed = h(concatenated, t);
    return crypto.md5.convert(utf8.encode(hashed)).toString();
  }

  // ── 随机 IV ────────────────────────────────────────────

  /// 生成 [length] 位随机 IV 字符串 `[a-z0-9]`（对齐 `random_iv_str`）。
  String randomIv([int length = 16]) {
    const String chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final StringBuffer sb = StringBuffer();
    for (int i = 0; i < length; i++) {
      sb.write(chars[_rand.nextInt(chars.length)]);
    }
    return sb.toString();
  }

  // ── AES-256-CBC 加解密 ─────────────────────────────────

  /// 加密 JSON 对象（对齐 `encrypt(plain_obj)`）。
  ///
  /// 返回 `(iv, ciphertext)`：IV 为 16 位明文串，密文为 base64。
  ({String iv, String ciphertext}) encrypt(Map<String, dynamic> plainObj) {
    final List<int> keyBytes = utf8.encode(generateKey());
    final String ivStr = randomIv();
    final List<int> ivBytes = utf8.encode(ivStr);

    // 明文按 key 排序、无空格紧凑 JSON（对齐 `.sortedKeys` /
    // Python `separators=(',', ':')`）。
    final Map<String, dynamic> sorted = _sortedMap(plainObj);
    final List<int> plainBytes = utf8.encode(jsonEncode(sorted));

    final List<int>? cipher = MdtvAes.cbcEncrypt(keyBytes, ivBytes, plainBytes);
    if (cipher == null) {
      throw const ExtscreenException('AES 加密失败');
    }
    return (iv: ivStr, ciphertext: base64Encode(cipher));
  }

  /// 解密服务端响应（对齐 `decrypt(ciphertext:iv:t:)`）。
  ///
  /// [ivHex] 为服务端返回的 hex IV；[t] 为服务端时间戳（用于重建密钥）。
  String decrypt({
    required String ciphertextBase64,
    required String ivHex,
    String? t,
  }) {
    final List<int> keyBytes =
        utf8.encode(t != null ? generateKeyWithTimestamp(t) : generateKey());
    final List<int>? ivBytes = MdtvCrypto.hexToBytes(ivHex);
    if (ivBytes == null || ivBytes.length != 16) {
      throw const ExtscreenException('无效的 IV hex 格式');
    }

    final List<int> cipherBytes;
    try {
      cipherBytes = base64Decode(ciphertextBase64);
    } on FormatException {
      throw const ExtscreenException('无效的 Base64 编码');
    }

    final List<int>? plain = MdtvAes.cbcDecrypt(keyBytes, ivBytes, cipherBytes);
    if (plain == null) {
      throw const ExtscreenException('AES 解密失败');
    }
    try {
      return utf8.decode(plain);
    } on FormatException {
      throw const ExtscreenException('解密后数据不是有效的 UTF-8 字符串');
    }
  }

  // ── SHA-256 签名 ───────────────────────────────────────

  /// 计算签名（对齐 `computeSign(method:apiPath:)`）。
  ///
  /// [apiPath] 为不含 `/api` 前缀的路径（如 `/v2/qrcode`、`/v4/token`），
  /// 内部拼接为 `/api{apiPath}`。
  String computeSign({required String method, required String apiPath}) {
    final String fullApiPath = '/api$apiPath';
    final String key = generateKey();
    final String content =
        '$method-$fullApiPath-$timestamp-$uniqueId-$key';
    return crypto.sha256.convert(utf8.encode(content)).toString();
  }

  /// 构建 HTTP 请求头（对齐 `getHeaders(sign:)`）。
  Map<String, String> headers(String sign) => <String, String>{
        'User-Agent': userAgent,
        'Host': host,
        'Content-Type': 'application/json;',
        'akv': akv,
        'apv': apv,
        'b': brand,
        'd': uniqueId,
        'm': model,
        'n': model,
        't': timestamp,
        'wifiMac': wifiMac,
        'sign': sign,
      };

  // ── 随机工具 ───────────────────────────────────────────

  static String _randomHex32(Random r) {
    final StringBuffer sb = StringBuffer();
    for (int i = 0; i < 32; i++) {
      sb.write(r.nextInt(16).toRadixString(16));
    }
    return sb.toString();
  }

  static String _randomWifiMac(Random r) {
    // 12 位数字（首位非 0），对齐 iOS `Int.random(in: 100000000000...999999999999)`。
    final StringBuffer sb = StringBuffer()..write(1 + r.nextInt(9));
    for (int i = 0; i < 11; i++) {
      sb.write(r.nextInt(10));
    }
    return sb.toString();
  }

  static Map<String, dynamic> _sortedMap(Map<String, dynamic> input) {
    final List<String> keys = input.keys.toList()..sort();
    return <String, dynamic>{for (final String k in keys) k: input[k]};
  }
}
