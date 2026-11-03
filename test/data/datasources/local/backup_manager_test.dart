/// 数据层单测：#10 —— `backup_manager.dart`（AES-256-GCM + PBKDF2）。
///
/// 重点：
///   ① 加密参数**逐项对齐** `contract/docs/backup_v1.md`（改了就不兼容 iOS）；
///   ② 加解密往返、错误口令、版本过高、格式非法等错误路径；
///   ③ 互通向量：按文档参数**独立**派生密钥构造信封，验证解密路径可读。
library;

import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/data/datasources/local/backup_manager.dart';

BackupMeta _meta() => const BackupMeta(
      appName: 'VBox',
      appVersion: '3.1621.0',
      createdAt: 1700000000,
      account: 'acc',
      username: 'user',
      device: 'dev',
    );

void main() {
  final BackupManager mgr = BackupManager.instance;

  group('加密参数对齐契约（不得改动）', () {
    test('常量逐项', () {
      expect(BackupManager.supportedSchemaVersion, 1);
      expect(BackupManager.pbkdf2Iterations, 100000);
      expect(BackupManager.saltLength, 16);
      expect(BackupManager.ivLength, 12);
      expect(BackupManager.keyLength, 32);
      expect(BackupManager.tagLength, 16);
      expect(BackupManager.cipherName, 'AES-256-GCM');
      expect(BackupManager.kdfName, 'PBKDF2-HMAC-SHA256');
    });

    test('BackupCategory：9 类，仅网盘凭据敏感且默认不勾选', () {
      expect(BackupCategory.values.length, 9);
      final Set<BackupCategory> sensitive = BackupCategory.values
          .where((BackupCategory c) => c.isSensitive)
          .toSet();
      expect(sensitive, <BackupCategory>{BackupCategory.cloudCredentials});
      for (final BackupCategory c in BackupCategory.values) {
        expect(c.defaultOn, !c.isSensitive, reason: c.name);
      }
    });
  });

  group('类目标签与冲突策略（B4 契约 §3 / §8）', () {
    test('9 个类目均有中文名与副标题，且互不重复', () {
      final Set<String> labels =
          BackupCategory.values.map((BackupCategory c) => c.label).toSet();
      final Set<String> subtitles =
          BackupCategory.values.map((BackupCategory c) => c.subtitle).toSet();
      expect(labels.length, 9);
      expect(subtitles.length, 9);
      expect(BackupCategory.watchHistory.label, '观看记录');
      expect(BackupCategory.cloudCredentials.label, '网盘凭据');
    });

    test('ConflictStrategy 两值 + 中文名 + fromName 回退 merge', () {
      expect(ConflictStrategy.values.length, 2);
      expect(ConflictStrategy.merge.label, '合并');
      expect(ConflictStrategy.overwrite.label, '覆盖');
      expect(ConflictStrategy.fromName('overwrite'), ConflictStrategy.overwrite);
      expect(ConflictStrategy.fromName('merge'), ConflictStrategy.merge);
      expect(ConflictStrategy.fromName(null), ConflictStrategy.merge);
      expect(ConflictStrategy.fromName('未知'), ConflictStrategy.merge);
    });
  });

  group('加密/解密往返', () {
    test('无口令 → 未加密信封；可还原原文', () async {
      const String plain = '{"history":[1,2,3]}';
      final BackupEnvelope env =
          await mgr.encrypt(plaintextJson: plain, meta: _meta());
      expect(env.encrypted, isFalse);
      expect(env.cipher, isNull);
      expect(env.salt, isNull);
      expect(env.payload, base64.encode(utf8.encode(plain)));
      expect(await mgr.decrypt(envelope: env), plain);
    });

    test('空口令同样走未加密模式', () async {
      final BackupEnvelope env = await mgr.encrypt(
          plaintextJson: '{}', meta: _meta(), password: '');
      expect(env.encrypted, isFalse);
    });

    test('有口令 → 加密信封，字段长度符合契约，可还原原文', () async {
      const String plain = '{"favorites":["a","b"]}';
      final BackupEnvelope env = await mgr.encrypt(
          plaintextJson: plain, meta: _meta(), password: 'p@ss');
      expect(env.encrypted, isTrue);
      expect(env.cipher, BackupManager.cipherName);
      expect(env.kdf, BackupManager.kdfName);
      expect(base64.decode(env.salt!).length, BackupManager.saltLength);
      expect(base64.decode(env.iv!).length, BackupManager.ivLength);
      expect(base64.decode(env.authTag!).length, BackupManager.tagLength);
      expect(await mgr.decrypt(envelope: env, password: 'p@ss'), plain);
    });

    test('同一明文两次加密产生不同 salt/iv/密文（随机性）', () async {
      final BackupEnvelope a = await mgr.encrypt(
          plaintextJson: 'x', meta: _meta(), password: 'p');
      final BackupEnvelope b = await mgr.encrypt(
          plaintextJson: 'x', meta: _meta(), password: 'p');
      expect(a.salt, isNot(b.salt));
      expect(a.iv, isNot(b.iv));
      expect(a.payload, isNot(b.payload));
      expect(await mgr.decrypt(envelope: b, password: 'p'), 'x');
    });

    test('UTF-8 多字节口令（按字节而非字符处理）', () async {
      final BackupEnvelope env = await mgr.encrypt(
          plaintextJson: '{"k":"中文"}', meta: _meta(), password: '口令密码');
      expect(await mgr.decrypt(envelope: env, password: '口令密码'),
          '{"k":"中文"}');
    });
  });

  group('错误路径', () {
    test('错误口令 → WrongPasswordException', () async {
      final BackupEnvelope env = await mgr.encrypt(
          plaintextJson: '{}', meta: _meta(), password: 'right');
      expect(
        () => mgr.decrypt(envelope: env, password: 'wrong'),
        throwsA(isA<WrongPasswordException>()),
      );
    });

    test('加密信封但未提供口令 → EmptyPasswordException', () async {
      final BackupEnvelope env = await mgr.encrypt(
          plaintextJson: '{}', meta: _meta(), password: 'p');
      expect(
        () => mgr.decrypt(envelope: env),
        throwsA(isA<EmptyPasswordException>()),
      );
    });

    test('schemaVersion 高于支持版本 → SchemaTooNewException', () async {
      final BackupEnvelope env = BackupEnvelope(
        schemaVersion: BackupManager.supportedSchemaVersion + 1,
        meta: _meta(),
        encrypted: false,
        payload: base64.encode(utf8.encode('{}')),
      );
      expect(
        () => mgr.decrypt(envelope: env),
        throwsA(isA<SchemaTooNewException>()),
      );
    });

    test('加密信封缺 salt/iv/authTag → InvalidFormatException', () {
      final BackupEnvelope env = BackupEnvelope(
        meta: _meta(),
        encrypted: true,
        payload: base64.encode(<int>[1, 2, 3]),
      );
      expect(
        () => mgr.decrypt(envelope: env, password: 'p'),
        throwsA(isA<InvalidFormatException>()),
      );
    });

    test('空口令派生密钥 → EmptyPasswordException（encrypt 侧拦截）', () async {
      // encrypt 对空口令走未加密；此处验证 deriveKey 的守卫经 decrypt 暴露
      final BackupEnvelope env = BackupEnvelope(
        meta: _meta(),
        encrypted: true,
        salt: base64.encode(List<int>.filled(16, 0)),
        iv: base64.encode(List<int>.filled(12, 0)),
        authTag: base64.encode(List<int>.filled(16, 0)),
        payload: base64.encode(<int>[0]),
      );
      expect(
        () => mgr.decrypt(envelope: env, password: ''),
        throwsA(isA<EmptyPasswordException>()),
      );
    });

    test('版本检查优先于未加密直通', () {
      final BackupEnvelope env = BackupEnvelope(
        schemaVersion: 99,
        meta: _meta(),
        encrypted: false,
        payload: base64.encode(utf8.encode('{}')),
      );
      expect(() => mgr.decrypt(envelope: env),
          throwsA(isA<SchemaTooNewException>()));
    });
  });

  group('信封编解码', () {
    test('encode → decode 往返（含 meta 与可选字段）', () async {
      final BackupEnvelope env = await mgr.encrypt(
          plaintextJson: '{"a":1}', meta: _meta(), password: 'p');
      final BackupEnvelope back = mgr.decode(mgr.encode(env));
      expect(back.schemaVersion, env.schemaVersion);
      expect(back.encrypted, isTrue);
      expect(back.cipher, env.cipher);
      expect(back.kdf, env.kdf);
      expect(back.salt, env.salt);
      expect(back.iv, env.iv);
      expect(back.authTag, env.authTag);
      expect(back.payload, env.payload);
      expect(back.meta.appName, 'VBox');
      expect(back.meta.createdAt, 1700000000);
      expect(await mgr.decrypt(envelope: back, password: 'p'), '{"a":1}');
    });

    test('未加密信封的 encode 省略可选字段', () async {
      final BackupEnvelope env =
          await mgr.encrypt(plaintextJson: '{}', meta: _meta());
      final Map<String, Object?> j =
          jsonDecode(mgr.encode(env)) as Map<String, Object?>;
      expect(j.containsKey('cipher'), isFalse);
      expect(j.containsKey('salt'), isFalse);
      expect(j.containsKey('iv'), isFalse);
      expect(j.containsKey('authTag'), isFalse);
      expect(j['encrypted'], isFalse);
    });

    test('decode 非法输入 → InvalidFormatException', () {
      expect(() => mgr.decode('not json'),
          throwsA(isA<InvalidFormatException>()));
      expect(() => mgr.decode('[1,2,3]'),
          throwsA(isA<InvalidFormatException>()));
    });

    test('BackupMeta.fromJson 缺字段回退默认', () {
      final BackupMeta m = BackupMeta.fromJson(<String, Object?>{});
      expect(m.appName, '');
      expect(m.appVersion, '');
      expect(m.createdAt, 0);
      expect(m.device, '');
    });

    test('BackupEnvelope.fromJson 缺字段回退默认', () {
      final BackupEnvelope e = BackupEnvelope.fromJson(<String, Object?>{});
      expect(e.schemaVersion, 1);
      expect(e.encrypted, isFalse);
      expect(e.payload, '');
    });
  });

  group('互通向量（按文档参数独立构造，验证解密可读）', () {
    test('独立派生密钥 + 固定 salt/iv 构造信封 → decrypt 成功', () async {
      const String plain = '{"sources":[{"name":"源A"}]}';
      const String password = 'shared-pass';
      final List<int> salt = List<int>.generate(16, (int i) => i);
      final List<int> iv = List<int>.generate(12, (int i) => 200 + i);

      // 独立实现（不借用 BackupManager.instance 的加密路径）
      final Pbkdf2 pbkdf2 = Pbkdf2(
        macAlgorithm: Hmac.sha256(),
        iterations: BackupManager.pbkdf2Iterations,
        bits: BackupManager.keyLength * 8,
      );
      final SecretKey key =
          await pbkdf2.deriveKeyFromPassword(password: password, nonce: salt);
      final SecretBox box = await AesGcm.with256bits()
          .encrypt(utf8.encode(plain), secretKey: key, nonce: iv);

      final BackupEnvelope env = BackupEnvelope(
        meta: _meta(),
        encrypted: true,
        cipher: BackupManager.cipherName,
        kdf: BackupManager.kdfName,
        salt: base64.encode(salt),
        iv: base64.encode(iv),
        authTag: base64.encode(box.mac.bytes),
        payload: base64.encode(box.cipherText),
      );
      expect(await mgr.decrypt(envelope: env, password: password), plain);
      // 信封也应经 encode/decode 稳定传递后可解
      expect(
        await mgr.decrypt(envelope: mgr.decode(mgr.encode(env)), password: password),
        plain,
      );
    });
  });
}