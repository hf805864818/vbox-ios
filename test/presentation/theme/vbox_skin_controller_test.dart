/// 呈现层单测：皮肤控制器（批次 A · A-03）。
///
/// 覆盖契约键读写（`app_skin_mode` / `app_skin_follows_system`）、
/// 「选择皮肤即关闭跟随系统」（对齐 iOS `selectSkin`）与热切换通知。
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vbox/data/datasources/local/prefs_manager.dart';
import 'package:vbox/presentation/theme/theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final PrefsManager pm = PrefsManager.instance;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    await pm.init();
  });

  setUp(() async {
    await pm.clearAll();
  });

  test('默认态对齐 iOS：light + 跟随系统', () {
    final VboxSkinController c = VboxSkinController();
    expect(c.skin, VboxSkin.light);
    expect(c.followsSystem, isTrue);
  });

  test('load：读契约键；followsSystem 未设置时按 iOS 默认 true', () async {
    await pm.set('app_skin_mode', 'frosted');
    // 未写 app_skin_follows_system（契约无默认值）
    final VboxSkinController c = VboxSkinController();
    await c.load(pm);
    expect(c.skin, VboxSkin.frosted);
    expect(c.followsSystem, isTrue);
  });

  test('load：显式 false 被尊重', () async {
    await pm.set('app_skin_mode', 'liquid');
    await pm.set('app_skin_follows_system', false);
    final VboxSkinController c = VboxSkinController();
    await c.load(pm);
    expect(c.skin, VboxSkin.liquid);
    expect(c.followsSystem, isFalse);
  });

  test('load：未知皮肤值回退 light', () async {
    await pm.set('app_skin_mode', 'unknown');
    final VboxSkinController c = VboxSkinController();
    await c.load(pm);
    expect(c.skin, VboxSkin.light);
  });

  test('selectSkin：切换皮肤 + 关闭跟随系统 + 持久化 + 通知', () async {
    final VboxSkinController c = VboxSkinController();
    await c.load(pm);
    int notified = 0;
    c.addListener(() => notified++);

    await c.selectSkin(VboxSkin.dark);

    expect(c.skin, VboxSkin.dark);
    expect(c.followsSystem, isFalse);
    expect(notified, 1);
    expect(await pm.getString('app_skin_mode'), 'dark');
    expect(await pm.getBool('app_skin_follows_system'), isFalse);
  });

  test('setFollowsSystem：持久化并通知；相同值不重复通知', () async {
    final VboxSkinController c = VboxSkinController();
    await c.load(pm);
    int notified = 0;
    c.addListener(() => notified++);

    await c.setFollowsSystem(false);
    expect(notified, 1);
    expect(await pm.getBool('app_skin_follows_system'), isFalse);

    await c.setFollowsSystem(false); // 幂等
    expect(notified, 1);
  });

  test('selectSkin：未见肤但跟随系统开启时仍切换（对齐 iOS）', () async {
    final VboxSkinController c = VboxSkinController();
    await c.load(pm);
    expect(c.followsSystem, isTrue);
    await c.selectSkin(VboxSkin.light); // 同一皮肤
    expect(c.followsSystem, isFalse); // 仍关闭跟随系统
  });
}