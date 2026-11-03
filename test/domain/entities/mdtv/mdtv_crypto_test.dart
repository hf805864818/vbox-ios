/// 领域层单测：MDTV AES 分组密码 + 各工作模式 + 密钥/IV/模式候选。
///
/// 锚点：
/// - FIPS-197（AES-128/192/256 单分组 KAT）验证 [MdtvAes.encryptBlock] /
///   [MdtvAes.decryptBlock] 核心正确；
/// - 各模式（CBC/CFB/CTR/OFB/ECB）加密→解密往返验证模式实现自洽；
/// - [MdtvCrypto] 候选生成 / 编解码 / 哈希工具行为。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/mdtv/mdtv.dart';

/// 便捷：十六进制字符串 → 字节（断言合法）。
List<int> hex(String s) => MdtvCrypto.hexToBytes(s)!;

void main() {
  group('AES 分组密码 FIPS-197 已知答案', () {
    const String pt = '00112233445566778899aabbccddeeff';

    test('AES-128 encryptBlock / decryptBlock', () {
      final List<int> key = hex('000102030405060708090a0b0c0d0e0f');
      final List<int> block = hex(pt);
      final List<int> ct = MdtvAes.encryptBlock(key, block)!;
      expect(MdtvCrypto.bytesToHex(ct), '69c4e0d86a7b0430d8cdb78070b4c55a');
      expect(MdtvAes.decryptBlock(key, ct), block);
    });

    test('AES-192 encryptBlock / decryptBlock', () {
      final List<int> key =
          hex('000102030405060708090a0b0c0d0e0f1011121314151617');
      final List<int> block = hex(pt);
      final List<int> ct = MdtvAes.encryptBlock(key, block)!;
      expect(MdtvCrypto.bytesToHex(ct), 'dda97ca4864cdfe06eaf70a0ec0d7191');
      expect(MdtvAes.decryptBlock(key, ct), block);
    });

    test('AES-256 encryptBlock / decryptBlock', () {
      final List<int> key = hex(
        '000102030405060708090a0b0c0d0e0f'
        '101112131415161718191a1b1c1d1e1f',
      );
      final List<int> block = hex(pt);
      final List<int> ct = MdtvAes.encryptBlock(key, block)!;
      expect(MdtvCrypto.bytesToHex(ct), '8ea2b7ca516745bfeafc49904b496089');
      expect(MdtvAes.decryptBlock(key, ct), block);
    });

    test('非法密钥长度 / 非 16 字节分组返回 null', () {
      expect(
        MdtvAes.encryptBlock(<int>[0, 1, 2], List<int>.filled(16, 0)),
        isNull,
      );
      expect(
        MdtvAes.encryptBlock(List<int>.filled(16, 0), List<int>.filled(15, 0)),
        isNull,
      );
      expect(
        MdtvAes.decryptBlock(<int>[0, 1, 2], List<int>.filled(16, 0)),
        isNull,
      );
    });
  });

  group('各模式（CBC/CFB/CTR/OFB/ECB）加密→解密往返', () {
    final List<int> key = hex('2b7e151628aed2a6abf7158809cf4f3c');
    final List<int> iv = List<int>.filled(16, 0x5a);

    List<int> enc(MdtvEncryptMode mode, List<int> data) {
      switch (mode) {
        case MdtvEncryptMode.cbc:
          return MdtvAes.cbcEncrypt(key, iv, data)!;
        case MdtvEncryptMode.cfb:
          return MdtvAes.cfbEncrypt(key, iv, data)!;
        case MdtvEncryptMode.ctr:
          return MdtvAes.ctrEncrypt(key, iv, data)!;
        case MdtvEncryptMode.ofb:
          return MdtvAes.ofbEncrypt(key, iv, data)!;
        case MdtvEncryptMode.ecb:
          return MdtvAes.ecbEncrypt(key, data)!;
      }
    }

    List<int> dec(MdtvEncryptMode mode, List<int> data) {
      switch (mode) {
        case MdtvEncryptMode.cbc:
          return MdtvAes.cbcDecrypt(key, iv, data)!;
        case MdtvEncryptMode.cfb:
          return MdtvAes.cfbDecrypt(key, iv, data)!;
        case MdtvEncryptMode.ctr:
          return MdtvAes.ctrDecrypt(key, iv, data)!;
        case MdtvEncryptMode.ofb:
          return MdtvAes.ofbDecrypt(key, iv, data)!;
        case MdtvEncryptMode.ecb:
          return MdtvAes.ecbDecrypt(key, data)!;
      }
    }

    test('多种长度（空/不足一块/整块/多块）加解密互逆', () {
      for (final int len in <int>[0, 1, 15, 16, 17, 33, 64]) {
        final List<int> plain =
            List<int>.generate(len, (int i) => (i * 7 + 3) & 0xff);
        for (final MdtvEncryptMode mode in MdtvCrypto.modeCandidates) {
          final List<int> cipher = enc(mode, plain);
          expect(dec(mode, cipher), plain,
              reason: 'mode=$mode len=$len 往返失败');
        }
      }
    });

    test('流式模式（CTR/OFB/CFB）密文长度等于明文（无填充）', () {
      final List<int> plain = List<int>.generate(20, (int i) => i);
      for (final MdtvEncryptMode mode in const <MdtvEncryptMode>[
        MdtvEncryptMode.ctr,
        MdtvEncryptMode.ofb,
        MdtvEncryptMode.cfb,
      ]) {
        expect(enc(mode, plain).length, 20, reason: 'mode=$mode');
      }
      // 块模式（CBC/ECB）带 PKCS7 填充，20 → 32
      expect(enc(MdtvEncryptMode.cbc, plain).length, 32);
      expect(enc(MdtvEncryptMode.ecb, plain).length, 32);
    });

    test('ECB 与单分组加密一致（16 字节输入 = 明文分组 + 填充分组）', () {
      final List<int> plain = List<int>.filled(16, 0x11);
      final List<int> ecb = MdtvAes.ecbEncrypt(key, plain)!;
      expect(ecb.length, 32);
      expect(ecb.sublist(0, 16), MdtvAes.encryptBlock(key, plain));
      expect(
        ecb.sublist(16),
        MdtvAes.encryptBlock(key, List<int>.filled(16, 16)),
      );
    });
  });

  group('MdtvCrypto 编解码与哈希', () {
    test('hexToBytes / bytesToHex 往返', () {
      expect(MdtvCrypto.hexToBytes('deadbeef'), <int>[0xde, 0xad, 0xbe, 0xef]);
      expect(MdtvCrypto.bytesToHex(<int>[0xde, 0xad, 0xbe, 0xef]), 'deadbeef');
    });

    test('非法十六进制 / 奇数长度返回 null', () {
      expect(MdtvCrypto.hexToBytes('zz'), isNull, reason: '非十六进制字符');
      expect(MdtvCrypto.hexToBytes('xyz'), isNull);
      expect(MdtvCrypto.hexToBytes('abc'), isNull, reason: '奇数长度');
      expect(MdtvCrypto.hexToBytes(''), isEmpty);
    });

    test('md5Hex / sha1HexPrefix32 已知答案（空输入）', () {
      expect(MdtvCrypto.md5Hex(const <int>[]), 'd41d8cd98f00b204e9800998ecf8427e');
      expect(
        MdtvCrypto.sha1HexPrefix32(const <int>[]),
        'da39a3ee5e6b4b0d3255bfef95601890',
      );
    });
  });

  group('密钥 / IV / 模式候选', () {
    test('modeCandidates 顺序：CFB → CBC → CTR → OFB → ECB', () {
      expect(MdtvCrypto.modeCandidates, const <MdtvEncryptMode>[
        MdtvEncryptMode.cfb,
        MdtvEncryptMode.cbc,
        MdtvEncryptMode.ctr,
        MdtvEncryptMode.ofb,
        MdtvEncryptMode.ecb,
      ]);
    });

    test('ivCandidates 首项为 iOS 默认 IV + 全零 IV', () {
      expect(MdtvCrypto.ivCandidates.first, '0a010b05040f070917030106080c0d5b');
      expect(MdtvCrypto.ivCandidates[1], '00000000000000000000000000000000');
    });

    test('keyCandidates 去重且升序', () {
      final List<String> keys = MdtvCrypto.keyCandidates;
      expect(keys.toSet().length, keys.length, reason: '存在重复候选');
      final List<String> sorted = List<String>.of(keys)..sort();
      expect(keys, sorted, reason: '候选未升序');
      expect(keys, isNotEmpty);
    });

    test('keyCandidates 含固定 hex 键与哈希键', () {
      expect(
        MdtvCrypto.keyCandidates,
        contains('368480924a6c78e2e8681551a7cf4c21'),
      );
      // 含 md5/sha1 前缀候选（JGDZMX）
      expect(
        MdtvCrypto.keyCandidates,
        contains(MdtvCrypto.md5Hex(utf8.encode('JGDZMX'))),
      );
      expect(
        MdtvCrypto.keyCandidates,
        contains(MdtvCrypto.sha1HexPrefix32(utf8.encode('JGDZMX'))),
      );
    });

    test('keyCandidates 至少含一个合法长度的密钥（16/24/32 字节）', () {
      final List<List<int>> valid = MdtvCrypto.keyCandidates
          .map(MdtvCrypto.hexToBytes)
          .whereType<List<int>>()
          .where((List<int> b) =>
              b.length == 16 || b.length == 24 || b.length == 32)
          .toList();
      expect(valid, isNotEmpty);
    });
  });
}