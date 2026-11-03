/// PG 自动化配置存储单测（批次 F · F-09）。
///
/// 对齐基准（唯一真相源）：iOS `AliyunPgConfig`
/// （`vbox/Services/AliyunPgConfig.swift`）的 9 个 `pg_ali_*` UserDefaults 键；
/// Flutter 端经契约 `prefs_keys_v1.json`（`_group_quark_pg`）落 SharedPreferences。
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vbox/data/datasources/local/pg_auto_store.dart';
import 'package:vbox/data/datasources/local/prefs_manager.dart';
import 'package:vbox/domain/entities/cloud/pg_auto.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final PrefsManager pm = PrefsManager.instance;
  late PgAutoStore store;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    await pm.init();
  });

  setUp(() async {
    await pm.clearAll();
    store = PgAutoStore(pm);
  });

  test('空存储 load() = 契约缺省配置', () async {
    final PgAutoConfig c = await store.load();
    expect(c, PgAutoConfig.defaults);
  });

  test('save 后可跨实例读回（持久化）', () async {
    final PgAutoConfig config = PgAutoConfig.defaults.copyWith(
      enabled: true,
      isVip: true,
      threadLimit: 24,
      threadNight: 12,
      vodFlags: 'hd',
      transferDir: 'vbox_pg_temp',
      autoCleanup: true,
      cleanupDelaySeconds: 120,
      proxyPort: 10078,
    );
    await store.save(config);

    final PgAutoStore next = PgAutoStore(pm);
    expect(await next.load(), config);
  });

  test('9 个契约键全部落 userdefaults（明文可见，键名与契约一致）', () async {
    await store.save(
      PgAutoConfig.defaults.copyWith(
        enabled: true,
        isVip: true,
        threadLimit: 7,
        threadNight: 9,
        vodFlags: 'sd',
        transferDir: 'tmp_dir',
        autoCleanup: true,
        cleanupDelaySeconds: 30,
        proxyPort: 12345,
      ),
    );
    final SharedPreferences raw = await SharedPreferences.getInstance();
    expect(raw.getBool(PgAutoStore.enabledKey), isTrue);
    expect(raw.getBool(PgAutoStore.isVipKey), isTrue);
    expect(raw.getInt(PgAutoStore.threadLimitKey), 7);
    expect(raw.getInt(PgAutoStore.threadNightKey), 9);
    expect(raw.getString(PgAutoStore.vodFlagsKey), 'sd');
    expect(raw.getString(PgAutoStore.transferDirKey), 'tmp_dir');
    expect(raw.getBool(PgAutoStore.autoCleanupKey), isTrue);
    expect(raw.getInt(PgAutoStore.cleanupDelayKey), 30);
    expect(raw.getInt(PgAutoStore.proxyPortKey), 12345);
  });

  test('reset 后回归契约缺省', () async {
    await store.save(
      PgAutoConfig.defaults.copyWith(enabled: true, threadLimit: 40),
    );
    await store.reset();
    expect(await store.load(), PgAutoConfig.defaults);
  });

  test('部分键缺失时按契约缺省补齐', () async {
    await pm.set(PgAutoStore.enabledKey, true);
    await pm.set(PgAutoStore.vodFlagsKey, 'fhd');
    final PgAutoConfig c = await store.load();
    expect(c.enabled, isTrue);
    expect(c.vodFlags, 'fhd');
    expect(c.threadLimit, PgAutoConfig.defaults.threadLimit);
    expect(c.proxyPort, PgAutoConfig.defaults.proxyPort);
    expect(c.autoCleanup, isFalse);
  });

  test('allKeys 覆盖 9 个契约键（去重、无遗漏）', () {
    expect(PgAutoStore.allKeys.length, 9);
    expect(PgAutoStore.allKeys.toSet().length, 9);
    expect(PgAutoStore.allKeys, contains(PgAutoStore.cleanupDelayKey));
    expect(PgAutoStore.allKeys, contains(PgAutoStore.transferDirKey));
  });
}
