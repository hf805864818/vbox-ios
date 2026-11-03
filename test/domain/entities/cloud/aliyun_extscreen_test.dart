/// 领域层单测：阿里 extscreen 加密链路（批次 F · F-04）。
///
/// 对齐 iOS `ExtscreenCrypto.swift`：设备指纹 / h() / MD5 密钥派生 /
/// AES-256-CBC / SHA-256 签名 / 请求头。固定输入下的密钥与签名为**回归锚点**。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/cloud/aliyun_extscreen.dart';

void main() {
  ExtscreenCrypto crypto() => ExtscreenCrypto(
        timestamp: '1700000000000',
        uniqueId: 'a1b2c3d4e5f60718293a4b5c6d7e8f90',
        wifiMac: '123456789012',
      );

  group('设备指纹（params）', () {
    test('9 项参数与固定设备值对齐 iOS getParams', () {
      final Map<String, String> p = crypto().params;
      expect(p.keys.toSet(), <String>{
        'akv', 'apv', 'b', 'd', 'm', 'mac', 'n', 't', 'wifiMac',
      });
      expect(p['akv'], '2.6.1143');
      expect(p['apv'], '1.4.0.2');
      expect(p['b'], 'samsung');
      expect(p['m'], 'SM-S908E');
      expect(p['n'], 'SM-S908E');
      expect(p['mac'], '');
      expect(p['d'], 'a1b2c3d4e5f60718293a4b5c6d7e8f90');
      expect(p['wifiMac'], '123456789012');
      expect(p['t'], '1700000000000');
    });

    test('缺省随机 uniqueId 为 32 位小写 hex / wifiMac 为 12 位数字', () {
      final ExtscreenCrypto c = ExtscreenCrypto(timestamp: '1');
      expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(c.uniqueId), isTrue);
      expect(RegExp(r'^\d{12}$').hasMatch(c.wifiMac), isTrue);
    });
  });

  group('h() 字符变换', () {
    test('去重保持顺序', () {
      expect(crypto().h('aabbc', '1700000000000').length, 3);
    });

    test('modifier 不足 8 位时取 0（modVal = 0）', () {
      // '0000000' 取第 8 位起为空 → 0 → 逐字符 -1。
      expect(crypto().h('abc', '1234567'), '`ab');
    });

    test('固定输入回归锚点', () {
      expect(
        crypto().h('abcdefghijklmnopqrstuvwxyz0123456789', '1700000000000'),
        '`abcdefghijklmnopqrstuvwxy/012345678',
      );
    });
  });

  group('MD5 密钥派生', () {
    test('32 位 hex 且固定输入回归锚点', () {
      final String key = crypto().generateKey();
      expect(key.length, 32);
      expect(key, '4d3eadfc6b77c240a2f65caa2e0fa455');
    });

    test('generateKey == generateKeyWithTimestamp(timestamp)', () {
      final ExtscreenCrypto c = crypto();
      expect(c.generateKey(), c.generateKeyWithTimestamp(c.timestamp));
    });

    test('指定时间戳派生（回归锚点）', () {
      expect(
        crypto().generateKeyWithTimestamp('1700000000999'),
        'b2dcf98d290fa23048b008d3e65e544c',
      );
    });

    test('不同时间戳派生不同密钥', () {
      final ExtscreenCrypto c = crypto();
      expect(
        c.generateKeyWithTimestamp('1700000000001'),
        isNot(c.generateKeyWithTimestamp('1700000000002')),
      );
    });
  });

  group('AES-256-CBC 加解密', () {
    test('往返一致（含中文 / 嵌套）', () {
      final ExtscreenCrypto c = crypto();
      final ({String iv, String ciphertext}) enc = c.encrypt(<String, dynamic>{
        'scopes': 'user:base,file:all:read,file:all:write',
        'width': 500,
        'height': 500,
        'note': '扫码登录',
      });
      expect(enc.iv.length, 16);
      expect(RegExp(r'^[a-z0-9]{16}$').hasMatch(enc.iv), isTrue);
      final String plain = c.decrypt(
        ciphertextBase64: enc.ciphertext,
        ivHex: _hex(enc.iv),
      );
      expect(plain, contains('"note":"扫码登录"'));
      expect(plain, contains('"height":500'));
    });

    test('明文按 key 升序紧凑序列化', () {
      final ExtscreenCrypto c = crypto();
      final ({String iv, String ciphertext}) enc =
          c.encrypt(<String, dynamic>{'b': 2, 'a': 1});
      final String plain = c.decrypt(
        ciphertextBase64: enc.ciphertext,
        ivHex: _hex(enc.iv),
      );
      expect(plain, '{"a":1,"b":2}');
    });

    test('随机 IV：两次加密 IV 不同', () {
      final ExtscreenCrypto c = crypto();
      expect(
        c.encrypt(<String, dynamic>{'a': 1}).iv,
        isNot(c.encrypt(<String, dynamic>{'a': 1}).iv),
      );
    });

    test('服务端时间戳重建密钥解密', () {
      // 服务端与客户端共享同一设备指纹，仅时间戳不同；密钥由设备参数 + t 派生。
      const String serverT = '1700000000888';
      final ExtscreenCrypto server = ExtscreenCrypto(
        timestamp: serverT,
        uniqueId: 'a1b2c3d4e5f60718293a4b5c6d7e8f90',
        wifiMac: '123456789012',
      );
      final ({String iv, String ciphertext}) enc =
          server.encrypt(<String, dynamic>{'sid': 'abc'});
      // 客户端时间戳不同，但用响应 t 重建密钥。
      final String plain = crypto().decrypt(
        ciphertextBase64: enc.ciphertext,
        ivHex: _hex(enc.iv),
        t: serverT,
      );
      expect(plain, contains('"sid":"abc"'));
    });

    test('非法 IV / Base64 抛错', () {
      final ExtscreenCrypto c = crypto();
      expect(
        () => c.decrypt(ciphertextBase64: 'AAAA', ivHex: 'zz'),
        throwsA(isA<ExtscreenException>()),
      );
      expect(
        () => c.decrypt(ciphertextBase64: '!!!', ivHex: _hex('0123456789abcdef')),
        throwsA(isA<ExtscreenException>()),
      );
    });
  });

  group('SHA-256 签名与请求头', () {
    test('64 位 hex 且固定输入回归锚点', () {
      final String sign = crypto().computeSign(method: 'POST', apiPath: '/v2/qrcode');
      expect(sign.length, 64);
      expect(sign, '53cb7d704dbd30f2458075fdf298628cfaec5dfc62b8c5d7df5511e2d06f1d00');
    });

    test('method / apiPath 变化签名变化', () {
      final ExtscreenCrypto c = crypto();
      expect(
        c.computeSign(method: 'POST', apiPath: '/v2/qrcode'),
        isNot(c.computeSign(method: 'GET', apiPath: '/v2/qrcode')),
      );
      expect(
        c.computeSign(method: 'POST', apiPath: '/v2/qrcode'),
        isNot(c.computeSign(method: 'POST', apiPath: '/v4/token')),
      );
    });

    test('请求头含签名与固定字段', () {
      final ExtscreenCrypto c = crypto();
      final Map<String, String> h = c.headers('SIGN');
      expect(h['Host'], 'api.extscreen.com');
      expect(h['Content-Type'], 'application/json;');
      expect(h['akv'], '2.6.1143');
      expect(h['apv'], '1.4.0.2');
      expect(h['b'], 'samsung');
      expect(h['d'], c.uniqueId);
      expect(h['m'], 'SM-S908E');
      expect(h['n'], 'SM-S908E');
      expect(h['t'], c.timestamp);
      expect(h['wifiMac'], c.wifiMac);
      expect(h['sign'], 'SIGN');
      expect(h['User-Agent'], contains('SM-S908E'));
    });
  });
}

/// IV 明文串 → hex（服务端 IV 为 hex 格式）。
String _hex(String s) =>
    s.codeUnits.map((int c) => c.toRadixString(16).padLeft(2, '0')).join();
