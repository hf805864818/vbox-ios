/// 领域层：One 平台 AES-128-CBC 加解密 + 密钥/IV 候选。
///
/// 对齐 iOS `OnePlatformService.swift` L132-L261：
/// - `aesKeyCandidates`（2 组，均 16 字节 hex）；
/// - `aesIVCandidates`（3 组，均 16 字节 hex）；
/// - `initialUserKeyCandidates`（3 组，注册场景的 sign userKey）；
/// - AES-128-CBC + PKCS7Padding（`CCCrypt` + `kCCOptionPKCS7Padding`）。
///
/// 密码学原语复用 `pointycastle`（与下载模块 m3u8 分片解密同一依赖），
/// 避免重复实现分组密码。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/api.dart' as pc;
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/cbc.dart';
import 'package:pointycastle/padded_block_cipher/padded_block_cipher_impl.dart';
import 'package:pointycastle/paddings/pkcs7.dart';

/// One 平台密钥/IV 工具 + AES-128-CBC 原语。
class OnePlatformCrypto {
  const OnePlatformCrypto._();

  /// AES 密钥候选（对齐 iOS `aesKeyCandidates`）。
  static const List<String> keyCandidates = <String>[
    '6d89c6d11f1a00dcfa5451fc6712a5532', // 阅姝阁 App 提取（16 字节）
    '30663438613465373765346138346630', // FLEX 旧版 key：「0f48a4e77e4a84f0」的 hex
  ];

  /// AES IV 候选（对齐 iOS `aesIVCandidates`）。
  static const List<String> ivCandidates = <String>[
    '0a010b05040f070917030106080c0d5b', // 固定 IV（FLEX 提取）
    '00000000000000000000000000000000', // 零 IV
    '6d89c6d11f1a00dcfa5451fc6712a5532', // 与 key 相同
  ];

  /// 注册场景的初始 userKey 候选（对齐 iOS `initialUserKeyCandidates`）。
  static const List<String> initialUserKeyCandidates = <String>[
    '6d89c6d11f1a00dc', // 新 key 前 16 位
    '6d89c6d11f1a00dcfa5451fc6712a5532', // 新 key 完整 32 位
    '0f48a4e77e4a84f0', // 旧版 key
  ];

  /// 十六进制字符串 → 字节；含非十六进制字符时返回 null。
  ///
  /// 对齐 iOS `Data(hexString:)`（见 `MDTVService.swift` L716-L731）：
  /// 取 `length ~/ 2` 组字节，**奇数长度时丢弃末位半字节**（如 33 位 hex
  /// 只解析前 32 位）——iOS 候选密钥中确有一组 33 位字符串，若按「奇数即
  /// 非法」处理会与 iOS 行为不一致。
  static List<int>? hexToBytes(String hex) {
    final String even = hex.length.isOdd ? hex.substring(0, hex.length - 1) : hex;
    final List<int> out = <int>[];
    for (var i = 0; i < even.length; i += 2) {
      final int? b = int.tryParse(even.substring(i, i + 2), radix: 16);
      if (b == null) return null;
      out.add(b);
    }
    return out;
  }

  /// MD5（hex，32 位小写；对齐 iOS `md5`）。
  static String md5Hex(List<int> bytes) => crypto.md5.convert(bytes).toString();

  /// AES-CBC 加密（PKCS7 填充）→ 密文字节；失败返回 null。
  static List<int>? cbcEncrypt(List<int> key, List<int> iv, List<int> data) {
    if (key.length != 16 && key.length != 24 && key.length != 32) return null;
    if (iv.length != 16) return null;
    final PaddedBlockCipherImpl padded = _cipher();
    padded.init(
      true,
      pc.PaddedBlockCipherParameters<pc.CipherParameters?, pc.CipherParameters?>(
        pc.ParametersWithIV<pc.KeyParameter>(
          pc.KeyParameter(Uint8List.fromList(key)),
          Uint8List.fromList(iv),
        ),
        null,
      ),
    );
    return padded.process(Uint8List.fromList(data));
  }

  /// AES-CBC 解密（去 PKCS7 填充）→ 明文字节；失败返回 null。
  static List<int>? cbcDecrypt(List<int> key, List<int> iv, List<int> data) {
    if (key.length != 16 && key.length != 24 && key.length != 32) return null;
    if (iv.length != 16 || data.isEmpty || data.length % 16 != 0) return null;
    final PaddedBlockCipherImpl padded = _cipher();
    padded.init(
      false,
      pc.PaddedBlockCipherParameters<pc.CipherParameters?, pc.CipherParameters?>(
        pc.ParametersWithIV<pc.KeyParameter>(
          pc.KeyParameter(Uint8List.fromList(key)),
          Uint8List.fromList(iv),
        ),
        null,
      ),
    );
    try {
      return padded.process(Uint8List.fromList(data));
    } catch (_) {
      // 密钥不匹配时 PKCS7 去填充非法：pointycastle 抛 `InvalidCipherTextException`
      // （继承自 `StateError`）或 `ArgumentError`，此处统一归一为 null，
      // 供上层遍历候选组合继续尝试。
      return null;
    }
  }

  static PaddedBlockCipherImpl _cipher() => PaddedBlockCipherImpl(
        PKCS7Padding(),
        CBCBlockCipher(AESEngine()),
      );

  /// 明文字符串 → Base64 密文（对齐 iOS `encrypt`）。
  static String? encryptBase64(String plaintext, List<int> key, List<int> iv) {
    final List<int>? enc = cbcEncrypt(key, iv, utf8.encode(plaintext));
    return enc == null ? null : base64Encode(enc);
  }

  /// Base64 密文 → 明文字符串（对齐 iOS `decrypt`）。
  static String? decryptBase64(String base64Str, List<int> key, List<int> iv) {
    final List<int>? data = tryBase64Decode(base64Str);
    if (data == null) return null;
    final List<int>? dec = cbcDecrypt(key, iv, data);
    return dec == null ? null : utf8.decode(dec, allowMalformed: true);
  }

  /// Base64 解码（容错；失败返回 null）。
  static List<int>? tryBase64Decode(String s) {
    try {
      return base64Decode(s.trim());
    } on FormatException {
      return null;
    }
  }
}