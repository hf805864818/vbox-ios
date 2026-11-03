/// One 平台加密工具单测：hex 解析（含奇数长度截断）+ AES-128-CBC 往返 + MD5。
///
/// 对齐口径：iOS `Data(hexString:)`（`MDTVService.swift` L716-L731）——
/// 按 `length ~/ 2` 组解析，奇数长度丢弃末位半字节。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/one_platform/one_platform.dart';

void main() {
  group('hexToBytes', () {
    test('偶数长度正常解析', () {
      expect(
        OnePlatformCrypto.hexToBytes('0f48a4e77e4a84f0'),
        <int>[0x0f, 0x48, 0xa4, 0xe7, 0x7e, 0x4a, 0x84, 0xf0],
      );
    });

    test('奇数长度丢弃末位半字节（对齐 iOS Data(hexString:)）', () {
      final List<int>? odd =
          OnePlatformCrypto.hexToBytes('6d89c6d11f1a00dcfa5451fc6712a5532');
      expect(odd, isNotNull);
      expect(odd!.length, 16);
      expect(
        odd,
        OnePlatformCrypto.hexToBytes('6d89c6d11f1a00dcfa5451fc6712a553'),
      );
    });

    test('含非十六进制字符返回 null', () {
      expect(OnePlatformCrypto.hexToBytes('zz'), isNull);
    });

    test('空串返回空列表', () {
      expect(OnePlatformCrypto.hexToBytes(''), isEmpty);
    });
  });

  group('候选常量', () {
    test('key 候选均可解析为 16/24/32 字节', () {
      for (final String hex in OnePlatformCrypto.keyCandidates) {
        final List<int>? b = OnePlatformCrypto.hexToBytes(hex);
        expect(b, isNotNull);
        expect(<int>[16, 24, 32].contains(b!.length), isTrue,
            reason: '非法密钥长度：$hex');
      }
    });

    test('iv 候选均可解析为 16 字节', () {
      for (final String hex in OnePlatformCrypto.ivCandidates) {
        final List<int>? b = OnePlatformCrypto.hexToBytes(hex);
        expect(b, isNotNull);
        expect(b!.length, 16, reason: '非法 IV 长度：$hex');
      }
    });

    test('key[0] 与 iv[2] 为 33 位（触发截断路径）', () {
      expect(OnePlatformCrypto.keyCandidates[0].length, 33);
      expect(OnePlatformCrypto.ivCandidates[2].length, 33);
      expect(
        OnePlatformCrypto.hexToBytes(OnePlatformCrypto.keyCandidates[0]),
        OnePlatformCrypto.hexToBytes(OnePlatformCrypto.ivCandidates[2]),
      );
    });
  });

  group('AES-128-CBC', () {
    test('加解密往返 + base64', () {
      final List<int> key =
          OnePlatformCrypto.hexToBytes(OnePlatformCrypto.keyCandidates[0])!;
      final List<int> iv =
          OnePlatformCrypto.hexToBytes(OnePlatformCrypto.ivCandidates[0])!;
      const String plain = '{"code":0,"data":{"rows":[]}}';
      final String? b64 = OnePlatformCrypto.encryptBase64(plain, key, iv);
      expect(b64, isNotNull);
      expect(OnePlatformCrypto.decryptBase64(b64!, key, iv), plain);
    });

    test('错误密钥解密返回 null（填充非法归一）', () {
      final List<int> key =
          OnePlatformCrypto.hexToBytes(OnePlatformCrypto.keyCandidates[0])!;
      final List<int> iv =
          OnePlatformCrypto.hexToBytes(OnePlatformCrypto.ivCandidates[0])!;
      final String b64 =
          OnePlatformCrypto.encryptBase64('hello world', key, iv)!;
      final List<int> wrongKey =
          OnePlatformCrypto.hexToBytes('ffffffffffffffffffffffffffffffff')!;
      // 大多数错误密钥会命中非法填充 → null；偶发合法填充也解不出原文。
      final String? dec =
          OnePlatformCrypto.decryptBase64(b64, wrongKey, iv);
      expect(dec, anyOf(isNull, isNot('hello world')));
    });

    test('非法 key / iv 长度返回 null', () {
      expect(
        OnePlatformCrypto.cbcEncrypt(
            <int>[1, 2, 3], List<int>.filled(16, 0), utf8.encode('x')),
        isNull,
      );
      final List<int> key =
          OnePlatformCrypto.hexToBytes(OnePlatformCrypto.keyCandidates[1])!;
      expect(
        OnePlatformCrypto.cbcEncrypt(key, <int>[1, 2, 3], utf8.encode('x')),
        isNull,
      );
    });

    test('decryptBase64 非法 base64 返回 null', () {
      final List<int> key =
          OnePlatformCrypto.hexToBytes(OnePlatformCrypto.keyCandidates[1])!;
      final List<int> iv =
          OnePlatformCrypto.hexToBytes(OnePlatformCrypto.ivCandidates[0])!;
      expect(
        OnePlatformCrypto.decryptBase64('!!!not-base64!!!', key, iv),
        isNull,
      );
    });
  });

  group('md5Hex', () {
    test('输出 32 位小写十六进制', () {
      expect(
        OnePlatformCrypto.md5Hex(utf8.encode('abc')),
        '900150983cd24fb0d6963f7d28e17f72',
      );
    });
  });
}