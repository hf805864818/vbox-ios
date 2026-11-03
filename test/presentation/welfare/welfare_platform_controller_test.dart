/// 呈现层单测：福利平台配置控制器（批次 H · H-01）。
///
/// 覆盖：开关默认值 / 幂等 bootstrap / 缓存恢复 + 后台刷新 / 刷新成败状态机 /
/// 开关落盘与恢复 / 清缓存复位。
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vbox/data/datasources/local/prefs_manager.dart';
import 'package:vbox/domain/entities/welfare/welfare.dart';
import 'package:vbox/presentation/welfare/welfare_platform_controller.dart';

import '../../support/fakes.dart';

const int kNow = 1700000000;

WelfarePlatformController build({
  InMemoryWelfarePlatformDatasource? datasource,
  InMemoryWelfarePlatformCache? cache,
  int now = kNow,
}) =>
    WelfarePlatformController(
      datasource: datasource ??
          InMemoryWelfarePlatformDatasource(
            config: buildWelfarePlatformConfig(),
          ),
      cache: cache ?? InMemoryWelfarePlatformCache(),
      prefs: PrefsManager.instance,
      nowSeconds: () => now,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    await PrefsManager.instance.init();
  });

  setUp(() async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    await p.clear();
  });

  group('bootstrap', () {
    test('开关默认开；bootstrap 触发一次后台刷新并加载成功', () async {
      final InMemoryWelfarePlatformDatasource ds =
          InMemoryWelfarePlatformDatasource(
        config: buildWelfarePlatformConfig(),
      );
      final WelfarePlatformController c = build(datasource: ds);

      await c.bootstrap();
      await pumpEventQueue();

      expect(c.switchEnabled, isTrue);
      expect(ds.fetchCount, 1);
      expect(c.loadState, WelfarePlatformLoadState.loaded);
      expect(c.totalPlatformCount, 4);
      expect(c.lastSuccessTimeSeconds, kNow);
      expect(c.lastConfigVersion, '2026.10.03.1');
    });

    test('幂等：重复 bootstrap 不再刷新', () async {
      final InMemoryWelfarePlatformDatasource ds =
          InMemoryWelfarePlatformDatasource(
        config: buildWelfarePlatformConfig(),
      );
      final WelfarePlatformController c = build(datasource: ds);

      await c.bootstrap();
      await pumpEventQueue();
      await c.bootstrap();
      await pumpEventQueue();

      expect(ds.fetchCount, 1);
    });

    test('开关关闭（已落盘）→ 不刷新', () async {
      await PrefsManager.instance.set(
        WelfarePlatformController.kSwitchEnabledKey,
        false,
      );
      final InMemoryWelfarePlatformDatasource ds =
          InMemoryWelfarePlatformDatasource(
        config: buildWelfarePlatformConfig(),
      );
      final WelfarePlatformController c = build(datasource: ds);

      await c.bootstrap();
      await pumpEventQueue();

      expect(c.switchEnabled, isFalse);
      expect(ds.fetchCount, 0);
    });

    test('先恢复磁盘缓存（首帧即有数据），再后台刷新', () async {
      final InMemoryWelfarePlatformCache cache = InMemoryWelfarePlatformCache(
        config: buildWelfarePlatformConfig(
          namesByCategory: <String, List<String>>{
            'video': <String>['旧平台'],
          },
        ),
      );
      final InMemoryWelfarePlatformDatasource ds =
          InMemoryWelfarePlatformDatasource(
        config: buildWelfarePlatformConfig(),
      );
      final WelfarePlatformController c = build(datasource: ds, cache: cache);

      await c.bootstrap();
      // bootstrap 返回时缓存已恢复（刷新尚未完成）。
      expect(c.config, isNotNull);
      expect(c.platformsIn(WelfarePlatformCategory.video).single.name, '旧平台');

      await pumpEventQueue();
      expect(c.totalPlatformCount, 4);
      expect(cache.config, isNotNull); // 刷新成功后回写缓存
    });
  });

  group('refresh', () {
    test('成功 → loaded + 记录成功时间 / 版本', () async {
      final WelfarePlatformController c = build();
      await c.refresh();

      expect(c.loadState, WelfarePlatformLoadState.loaded);
      expect(c.errorMessage, isNull);
      expect(c.lastSuccessTimeSeconds, kNow);
      expect(c.lastConfigVersion, '2026.10.03.1');
      expect(
        await PrefsManager.instance.getInt(
          WelfarePlatformController.kLastSuccessTimeKey,
        ),
        kNow,
      );
      expect(
        await PrefsManager.instance.get(
          WelfarePlatformController.kLastConfigVersionKey,
        ),
        '2026.10.03.1',
      );
    });

    test('失败 → failed + errorMessage，配置保持为 null', () async {
      final WelfarePlatformController c = build(
        datasource: InMemoryWelfarePlatformDatasource(),
      );
      await c.refresh();

      expect(c.loadState, WelfarePlatformLoadState.failed);
      expect(c.errorMessage, isNotNull);
      expect(c.config, isNull);
    });

    test('platformsIn：按分类过滤并保持升序', () async {
      final WelfarePlatformController c = build();
      await c.refresh();

      expect(
        c
            .platformsIn(WelfarePlatformCategory.video)
            .map((WelfarePlatform p) => p.name)
            .toList(),
        <String>['平台甲', '平台乙'],
      );
      expect(c.platformsIn(WelfarePlatformCategory.live).single.name, '直播甲');
      expect(c.platformsIn(WelfarePlatformCategory.comic).single.name, '漫画甲');
    });
  });

  group('开关 / 缓存', () {
    test('setSwitchEnabled 落盘 → 新控制器 bootstrap 读到关闭', () async {
      final InMemoryWelfarePlatformDatasource ds =
          InMemoryWelfarePlatformDatasource(
        config: buildWelfarePlatformConfig(),
      );
      final WelfarePlatformController c1 = build(datasource: ds);
      await c1.setSwitchEnabled(false);
      expect(c1.switchEnabled, isFalse);

      final InMemoryWelfarePlatformDatasource ds2 =
          InMemoryWelfarePlatformDatasource(
        config: buildWelfarePlatformConfig(),
      );
      final WelfarePlatformController c2 = build(datasource: ds2);
      await c2.bootstrap();
      await pumpEventQueue();

      expect(c2.switchEnabled, isFalse);
      expect(ds2.fetchCount, 0);
    });

    test('setSwitchEnabled 同值 → 不重复通知（no-op）', () async {
      final WelfarePlatformController c = build();
      int notifications = 0;
      c.addListener(() => notifications++);

      await c.setSwitchEnabled(true); // 默认即 true
      expect(notifications, 0);

      await c.setSwitchEnabled(false);
      expect(notifications, 1);
    });

    test('clearCache 复位内存状态与磁盘缓存', () async {
      final InMemoryWelfarePlatformCache cache = InMemoryWelfarePlatformCache();
      final WelfarePlatformController c = build(cache: cache);
      await c.refresh();
      expect(cache.config, isNotNull);

      await c.clearCache();

      expect(cache.config, isNull);
      expect(c.config, isNull);
      expect(c.loadState, WelfarePlatformLoadState.idle);
      expect(c.lastSuccessTimeSeconds, 0);
      expect(c.lastConfigVersion, isNull);
    });
  });
}