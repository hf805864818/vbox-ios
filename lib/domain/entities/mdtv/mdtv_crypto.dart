/// 领域层：麻豆平台（MDTV）AES 加解密 + 密钥/IV/模式候选。
///
/// 对齐 iOS `MDTVService.swift`：AES-128/192/256（CBC / CFB / CTR / OFB / ECB），
/// 以及密钥候选（hex + UTF-8 → hex + MD5/SHA1 前16字节）、IV 候选、模式候选。
///
/// 密码学原语自实现（S-box 运行时按 GF(2^8) 求逆 + 仿射变换生成，避免查表笔误），
/// 便于单测用 NIST/FIPS 已知答案向量锚定。仅用于麻豆平台加密协议。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

import 'mdtv_models.dart';

/// 纯 AES 分组密码（含 5 种工作模式）。
///
/// 密钥长度须为 16 / 24 / 32 字节，非法长度一律返回 null（对应 iOS CommonCrypto
/// 对非法 key 长度返回参数错误后被跳过）。
class MdtvAes {
  const MdtvAes._();

  // ── S-box（运行时生成）─────────────────────────────────

  static final List<int> _sbox = _buildSbox();
  static final List<int> _invSbox = _buildInvSbox(_sbox);

  static int _mul(int a, int b) {
    var p = 0;
    for (var i = 0; i < 8; i++) {
      if ((b & 1) != 0) p ^= a;
      final bool hi = (a & 0x80) != 0;
      a = (a << 1) & 0xff;
      if (hi) a ^= 0x1b;
      b >>= 1;
    }
    return p;
  }

  static int _rotl8(int v, int n) => ((v << n) | (v >> (8 - n))) & 0xff;

  /// GF(2^8) 乘法逆元（Fermat：a^254）。
  static int _gfInv(int a) {
    if (a == 0) return 0;
    var r = 1;
    var base = a;
    for (var e = 254; e > 0; e >>= 1) {
      if ((e & 1) != 0) r = _mul(r, base);
      base = _mul(base, base);
    }
    return r;
  }

  static List<int> _buildSbox() {
    final List<int> s = List<int>.filled(256, 0);
    for (var i = 0; i < 256; i++) {
      final int inv = _gfInv(i);
      s[i] = inv ^
          _rotl8(inv, 1) ^
          _rotl8(inv, 2) ^
          _rotl8(inv, 3) ^
          _rotl8(inv, 4) ^
          0x63;
    }
    return s;
  }

  static List<int> _buildInvSbox(List<int> s) {
    final List<int> inv = List<int>.filled(256, 0);
    for (var i = 0; i < 256; i++) {
      inv[s[i]] = i;
    }
    return inv;
  }

  // ── 密钥扩展 ───────────────────────────────────────────

  static List<int>? _roundKeys(List<int> key) {
    final int nk = key.length ~/ 4;
    if (nk != 4 && nk != 6 && nk != 8) return null;
    const int nb = 4;
    final int nr = nk + 6;
    final int totalWords = nb * (nr + 1);
    final List<int> w = List<int>.filled(totalWords * 4, 0);
    for (var i = 0; i < key.length; i++) {
      w[i] = key[i];
    }
    // Rcon：rcon[k] 对应第 k+1 轮（k = i/nk - 1 ∈ 0..9，AES-128/192/256 通用）。
    const List<int> rcon = <int>[0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36];
    for (var i = nk; i < totalWords; i++) {
      var t0 = w[(i - 1) * 4];
      var t1 = w[(i - 1) * 4 + 1];
      var t2 = w[(i - 1) * 4 + 2];
      var t3 = w[(i - 1) * 4 + 3];
      if (i % nk == 0) {
        final int tmp = t0;
        t0 = _sbox[t1] ^ rcon[i ~/ nk - 1];
        t1 = _sbox[t2];
        t2 = _sbox[t3];
        t3 = _sbox[tmp];
      } else if (nk > 6 && i % nk == 4) {
        t0 = _sbox[t0];
        t1 = _sbox[t1];
        t2 = _sbox[t2];
        t3 = _sbox[t3];
      }
      w[i * 4] = w[(i - nk) * 4] ^ t0;
      w[i * 4 + 1] = w[(i - nk) * 4 + 1] ^ t1;
      w[i * 4 + 2] = w[(i - nk) * 4 + 2] ^ t2;
      w[i * 4 + 3] = w[(i - nk) * 4 + 3] ^ t3;
    }
    return w;
  }

  static void _addRoundKey(List<int> s, List<int> w, int round) {
    for (var i = 0; i < 16; i++) {
      s[i] ^= w[round * 16 + i];
    }
  }

  static void _subBytes(List<int> s) {
    for (var i = 0; i < 16; i++) {
      s[i] = _sbox[s[i]];
    }
  }

  static void _invSubBytes(List<int> s) {
    for (var i = 0; i < 16; i++) {
      s[i] = _invSbox[s[i]];
    }
  }

  static void _shiftRows(List<int> s) {
    final List<int> t = List<int>.filled(16, 0);
    for (var r = 0; r < 4; r++) {
      for (var c = 0; c < 4; c++) {
        t[c * 4 + r] = s[((c + r) & 3) * 4 + r];
      }
    }
    for (var i = 0; i < 16; i++) {
      s[i] = t[i];
    }
  }

  static void _invShiftRows(List<int> s) {
    final List<int> t = List<int>.filled(16, 0);
    for (var r = 0; r < 4; r++) {
      for (var c = 0; c < 4; c++) {
        t[((c + r) & 3) * 4 + r] = s[c * 4 + r];
      }
    }
    for (var i = 0; i < 16; i++) {
      s[i] = t[i];
    }
  }

  static void _mixColumns(List<int> s) {
    for (var c = 0; c < 4; c++) {
      final int a0 = s[c * 4];
      final int a1 = s[c * 4 + 1];
      final int a2 = s[c * 4 + 2];
      final int a3 = s[c * 4 + 3];
      s[c * 4] = _mul(a0, 2) ^ _mul(a1, 3) ^ a2 ^ a3;
      s[c * 4 + 1] = a0 ^ _mul(a1, 2) ^ _mul(a2, 3) ^ a3;
      s[c * 4 + 2] = a0 ^ a1 ^ _mul(a2, 2) ^ _mul(a3, 3);
      s[c * 4 + 3] = _mul(a0, 3) ^ a1 ^ a2 ^ _mul(a3, 2);
    }
  }

  static void _invMixColumns(List<int> s) {
    for (var c = 0; c < 4; c++) {
      final int a0 = s[c * 4];
      final int a1 = s[c * 4 + 1];
      final int a2 = s[c * 4 + 2];
      final int a3 = s[c * 4 + 3];
      s[c * 4] = _mul(a0, 0x0e) ^ _mul(a1, 0x0b) ^ _mul(a2, 0x0d) ^ _mul(a3, 0x09);
      s[c * 4 + 1] = _mul(a0, 0x09) ^ _mul(a1, 0x0e) ^ _mul(a2, 0x0b) ^ _mul(a3, 0x0d);
      s[c * 4 + 2] = _mul(a0, 0x0d) ^ _mul(a1, 0x09) ^ _mul(a2, 0x0e) ^ _mul(a3, 0x0b);
      s[c * 4 + 3] = _mul(a0, 0x0b) ^ _mul(a1, 0x0d) ^ _mul(a2, 0x09) ^ _mul(a3, 0x0e);
    }
  }

  /// 单分组加密（无填充；16 字节进、16 字节出）。
  static List<int>? encryptBlock(List<int> key, List<int> block) {
    if (block.length != 16) return null;
    final List<int>? w = _roundKeys(key);
    if (w == null) return null;
    final int nr = key.length ~/ 4 + 6;
    final List<int> s = List<int>.from(block);
    _addRoundKey(s, w, 0);
    for (var round = 1; round < nr; round++) {
      _subBytes(s);
      _shiftRows(s);
      _mixColumns(s);
      _addRoundKey(s, w, round);
    }
    _subBytes(s);
    _shiftRows(s);
    _addRoundKey(s, w, nr);
    return s;
  }

  /// 单分组解密（无填充；16 字节进、16 字节出）。
  static List<int>? decryptBlock(List<int> key, List<int> block) {
    if (block.length != 16) return null;
    final List<int>? w = _roundKeys(key);
    if (w == null) return null;
    final int nr = key.length ~/ 4 + 6;
    final List<int> s = List<int>.from(block);
    _addRoundKey(s, w, nr);
    for (var round = nr - 1; round >= 1; round--) {
      _invShiftRows(s);
      _invSubBytes(s);
      _addRoundKey(s, w, round);
      _invMixColumns(s);
    }
    _invShiftRows(s);
    _invSubBytes(s);
    _addRoundKey(s, w, 0);
    return s;
  }

  // ── PKCS7 填充 ─────────────────────────────────────────

  static List<int> _pkcs7Pad(List<int> data) {
    final int padLen = 16 - (data.length % 16);
    return <int>[...data, ...List<int>.filled(padLen, padLen)];
  }

  static List<int>? _pkcs7Unpad(List<int> data) {
    if (data.isEmpty) return null;
    final int padLen = data[data.length - 1];
    if (padLen < 1 || padLen > 16 || data.length < padLen) return null;
    for (var i = 0; i < padLen; i++) {
      if (data[data.length - 1 - i] != padLen) return null;
    }
    return data.sublist(0, data.length - padLen);
  }

  // ── ECB ────────────────────────────────────────────────

  static List<int>? ecbEncrypt(List<int> key, List<int> data) {
    final List<int>? w = _roundKeys(key);
    if (w == null) return null;
    final int nr = key.length ~/ 4 + 6;
    final List<int> padded = _pkcs7Pad(data);
    final List<int> out = <int>[];
    for (var off = 0; off < padded.length; off += 16) {
      final List<int> s = List<int>.from(padded.sublist(off, off + 16));
      _encryptInPlace(s, w, nr);
      out.addAll(s);
    }
    return out;
  }

  static List<int>? ecbDecrypt(List<int> key, List<int> data) {
    final List<int>? w = _roundKeys(key);
    if (w == null || data.isEmpty || data.length % 16 != 0) return null;
    final int nr = key.length ~/ 4 + 6;
    final List<int> out = <int>[];
    for (var off = 0; off < data.length; off += 16) {
      final List<int> s = List<int>.from(data.sublist(off, off + 16));
      _decryptInPlace(s, w, nr);
      out.addAll(s);
    }
    return _pkcs7Unpad(out);
  }

  // ── CBC ────────────────────────────────────────────────

  static List<int>? cbcEncrypt(List<int> key, List<int> iv, List<int> data) {
    if (iv.length != 16) return null;
    final List<int>? w = _roundKeys(key);
    if (w == null) return null;
    final int nr = key.length ~/ 4 + 6;
    final List<int> padded = _pkcs7Pad(data);
    List<int> prev = List<int>.from(iv);
    final List<int> out = <int>[];
    for (var off = 0; off < padded.length; off += 16) {
      final List<int> s = List<int>.generate(
          16, (int i) => padded[off + i] ^ prev[i]);
      _encryptInPlace(s, w, nr);
      out.addAll(s);
      prev = s;
    }
    return out;
  }

  static List<int>? cbcDecrypt(List<int> key, List<int> iv, List<int> data) {
    if (iv.length != 16) return null;
    final List<int>? w = _roundKeys(key);
    if (w == null || data.isEmpty || data.length % 16 != 0) return null;
    final int nr = key.length ~/ 4 + 6;
    List<int> prev = List<int>.from(iv);
    final List<int> out = <int>[];
    for (var off = 0; off < data.length; off += 16) {
      final List<int> cipher = data.sublist(off, off + 16);
      final List<int> s = List<int>.from(cipher);
      _decryptInPlace(s, w, nr);
      for (var i = 0; i < 16; i++) {
        out.add(s[i] ^ prev[i]);
      }
      prev = cipher;
    }
    return _pkcs7Unpad(out);
  }

  // ── CFB128 ─────────────────────────────────────────────

  static List<int>? cfbEncrypt(List<int> key, List<int> iv, List<int> data) {
    return _cfbProcess(key, iv, data, decrypt: false);
  }

  static List<int>? cfbDecrypt(List<int> key, List<int> iv, List<int> data) {
    return _cfbProcess(key, iv, data, decrypt: true);
  }

  static List<int>? _cfbProcess(
      List<int> key, List<int> iv, List<int> data, {required bool decrypt}) {
    if (iv.length != 16) return null;
    final List<int>? w = _roundKeys(key);
    if (w == null) return null;
    final int nr = key.length ~/ 4 + 6;
    final List<int> prev = List<int>.from(iv);
    final List<int> out = <int>[];
    for (var off = 0; off < data.length; off += 16) {
      final List<int> keystream = List<int>.from(prev);
      _encryptInPlace(keystream, w, nr);
      final int n = (data.length - off) < 16 ? (data.length - off) : 16;
      final List<int> block = List<int>.filled(16, 0);
      for (var i = 0; i < n; i++) {
        final int b = data[off + i] ^ keystream[i];
        out.add(b);
        block[i] = decrypt ? data[off + i] : b;
      }
      // 反馈下一分组（末段部分分组无下一段，不影响正确性）。
      for (var i = 0; i < 16; i++) {
        prev[i] = i < n ? block[i] : keystream[i];
      }
    }
    return out;
  }

  // ── CTR ────────────────────────────────────────────────

  static List<int>? ctrEncrypt(List<int> key, List<int> iv, List<int> data) =>
      _ctrProcess(key, iv, data);

  static List<int>? ctrDecrypt(List<int> key, List<int> iv, List<int> data) =>
      _ctrProcess(key, iv, data);

  static List<int>? _ctrProcess(List<int> key, List<int> iv, List<int> data) {
    if (iv.length != 16) return null;
    final List<int>? w = _roundKeys(key);
    if (w == null) return null;
    final int nr = key.length ~/ 4 + 6;
    final List<int> counter = List<int>.from(iv);
    final List<int> out = <int>[];
    for (var off = 0; off < data.length; off += 16) {
      final List<int> keystream = List<int>.from(counter);
      _encryptInPlace(keystream, w, nr);
      final int n = (data.length - off) < 16 ? (data.length - off) : 16;
      for (var i = 0; i < n; i++) {
        out.add(data[off + i] ^ keystream[i]);
      }
      _incrementCounter(counter);
    }
    return out;
  }

  static void _incrementCounter(List<int> c) {
    for (var i = c.length - 1; i >= 0; i--) {
      c[i] = (c[i] + 1) & 0xff;
      if (c[i] != 0) break;
    }
  }

  // ── OFB ────────────────────────────────────────────────

  static List<int>? ofbEncrypt(List<int> key, List<int> iv, List<int> data) =>
      _ofbProcess(key, iv, data);

  static List<int>? ofbDecrypt(List<int> key, List<int> iv, List<int> data) =>
      _ofbProcess(key, iv, data);

  static List<int>? _ofbProcess(List<int> key, List<int> iv, List<int> data) {
    if (iv.length != 16) return null;
    final List<int>? w = _roundKeys(key);
    if (w == null) return null;
    final int nr = key.length ~/ 4 + 6;
    List<int> block = List<int>.from(iv);
    final List<int> out = <int>[];
    for (var off = 0; off < data.length; off += 16) {
      final List<int> keystream = List<int>.from(block);
      _encryptInPlace(keystream, w, nr);
      final int n = (data.length - off) < 16 ? (data.length - off) : 16;
      for (var i = 0; i < n; i++) {
        out.add(data[off + i] ^ keystream[i]);
      }
      block = keystream;
    }
    return out;
  }

  // ── 分组内联加/解密（复用以减少拷贝）──────────────────

  static void _encryptInPlace(List<int> s, List<int> w, int nr) {
    _addRoundKey(s, w, 0);
    for (var round = 1; round < nr; round++) {
      _subBytes(s);
      _shiftRows(s);
      _mixColumns(s);
      _addRoundKey(s, w, round);
    }
    _subBytes(s);
    _shiftRows(s);
    _addRoundKey(s, w, nr);
  }

  static void _decryptInPlace(List<int> s, List<int> w, int nr) {
    _addRoundKey(s, w, nr);
    for (var round = nr - 1; round >= 1; round--) {
      _invShiftRows(s);
      _invSubBytes(s);
      _addRoundKey(s, w, round);
      _invMixColumns(s);
    }
    _invShiftRows(s);
    _invSubBytes(s);
    _addRoundKey(s, w, 0);
  }
}

/// 字节 / 十六进制 / 哈希工具 + MDTV 密钥/IV/模式候选。
class MdtvCrypto {
  const MdtvCrypto._();

  // ── 编解码工具 ─────────────────────────────────────────

  static List<int>? hexToBytes(String hex) {
    if (hex.length % 2 != 0) return null;
    final List<int> out = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      final int? b = int.tryParse(hex.substring(i, i + 2), radix: 16);
      if (b == null) return null;
      out.add(b);
    }
    return out;
  }

  static String bytesToHex(List<int> bytes) =>
      bytes.map((int b) => b.toRadixString(16).padLeft(2, '0')).join();

  static String md5Hex(List<int> bytes) => crypto.md5.convert(bytes).toString();

  static String sha1HexPrefix32(List<int> bytes) =>
      crypto.sha1.convert(bytes).toString().substring(0, 32);

  /// 左对齐填充到目标长度（对齐 iOS `String.ljust`，默认往右补 `pad`）。
  static String _ljust(String s, int length, String pad) {
    if (s.length >= length || pad.isEmpty) return s;
    final int padCount = (length - s.length) ~/ pad.length + 1;
    final String padding = pad * padCount;
    return s + padding.substring(0, length - s.length);
  }

  // ── 密钥候选（对齐 iOS aesKeyCandidates）───────────────

  static const List<String> _hexKeys = <String>[
    '368480924a6c78e2e8681551a7cf4c21',
    '563e8eeef42931cc858dc0d1080f4f6f',
    '7a7352fa6ff2d4f238ec81eb0a62b81d',
    'd20a1be77c3d3c41b2a5accaee1ce549',
    '31a92ee2029fd10d901b113e990710f0',
    'db7c2abf62e35e668076bead208b0000',
    '30663438613465373765346138346630',
  ];

  static const List<String> _utf8Keys = <String>[
    'JGDZMX', 'mdtv', 'MdTv', 'MDTV',
    'madou', 'Madou', 'MADOU',
    'jiamidi', 'jiaguidi',
    'jiami', 'jiag',
    'encrypt', 'decrypt',
    'aeskey', 'aes_key',
    'secret', 'password',
    'keykeykeykeykeyk',
    'secretsecretsecr',
    '0123456789abcdef',
    'abcdefghijklmnopqrst',
    '1234567890123456',
    '0f48a4e77e4a84f0',
    '6d89c6d11f1a00dcfa5451fc6712a5532',
  ];

  static const List<String> _hashKeywords = <String>[
    'JGDZMX', 'mdtv', 'MdTv', 'MDTV',
    'madou', 'Madou', 'MADOU',
    'jiamidi', 'jiaguidi',
    'encrypt', 'decrypt', 'aeskey',
    'mdtv_key', 'mdtv_secret', 'mdtv_aes',
    'JGDZMX_key', 'JGDZMX_secret',
  ];

  /// 密钥候选（去重 + 升序，对齐 iOS `Array(Set()).sorted()`）。
  static final List<String> keyCandidates = _buildKeyCandidates();

  static List<String> _buildKeyCandidates() {
    final List<String> candidates = <String>[..._hexKeys];
    for (final String key in _utf8Keys) {
      final String hex = bytesToHex(utf8.encode(key));
      candidates.add(hex);
      candidates.add(_ljust(hex, 32, '0'));
      if (key.length < 16) {
        final String repeated =
            (key * ((16 ~/ key.length) + 1)).substring(0, 16);
        candidates.add(bytesToHex(utf8.encode(repeated)));
      }
    }
    for (final String kw in _hashKeywords) {
      final List<int> bytes = utf8.encode(kw);
      candidates.add(md5Hex(bytes));
      candidates.add(sha1HexPrefix32(bytes));
    }
    final Set<String> seen = <String>{};
    final List<String> dedup = <String>[];
    for (final String c in candidates) {
      if (seen.add(c)) dedup.add(c);
    }
    dedup.sort();
    return dedup;
  }

  /// IV 候选（对齐 iOS aesIVCandidates）。
  static final List<String> ivCandidates = _buildIvCandidates();

  static List<String> _buildIvCandidates() {
    final List<String> candidates = <String>[
      '0a010b05040f070917030106080c0d5b',
      '00000000000000000000000000000000',
    ];
    const List<String> ivStrings = <String>['JGDZMX', 'mdtv', 'MadTv', 'MDTV'];
    for (final String s in ivStrings) {
      candidates.add(_ljust(bytesToHex(utf8.encode(s)), 32, '0').substring(0, 32));
    }
    return candidates;
  }

  /// 模式候选（按优先级：CFB 优先，对齐 iOS modeCandidates）。
  static const List<MdtvEncryptMode> modeCandidates = <MdtvEncryptMode>[
    MdtvEncryptMode.cfb,
    MdtvEncryptMode.cbc,
    MdtvEncryptMode.ctr,
    MdtvEncryptMode.ofb,
    MdtvEncryptMode.ecb,
  ];
}