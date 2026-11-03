/// PG 自动化设置页 Widget 单测（批次 F · F-09）。
///
/// 对齐基准（唯一真相源）：iOS `AliyunPgQrLoginView.PgPlayConfigSection`
/// （`vbox/Views/AliyunPgQrLoginView.swift:158`）+ `AliyunPgConfig`
/// （`vbox/Services/AliyunPgConfig.swift`）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vbox/data/datasources/local/pg_auto_store.dart';
import 'package:vbox/data/datasources/local/prefs_manager.dart';
import 'package:vbox/domain/entities/cloud/pg_auto.dart';
import 'package:vbox/presentation/pages/cloud/pg_auto.dart';

Future<void> _pump(
  WidgetTester tester, {
  required PgAutoStore store,
  DateTime? now,
}) async {
  // 加高视口，使「当前生效」卡一并进入懒加载区间（避免 ListView 未构建）。
  tester.view.physicalSize = const Size(1200, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(home: PgAutoPage(store: store, now: now)),
  );
  await tester.pumpAndSettle();
}

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

  testWidgets('渲染三块设置 + 当前生效卡', (WidgetTester tester) async {
    await _pump(tester, store: store);

    expect(find.text('PG 自动化'), findsOneWidget);
    expect(find.text('PG 播放路链'), findsOneWidget);
    expect(find.text('播放参数'), findsOneWidget);
    expect(find.text('转存与清理'), findsOneWidget);
    expect(find.text('当前生效'), findsOneWidget);
    // 缺省非 VIP：线程恒为 1；画质回退原画 4K；转存目录回退缺省。
    // 画质 / 转存目录各出现两处（选择器或输入框 + 「当前生效」卡）。
    expect(find.text('1 线程'), findsOneWidget);
    expect(find.text('原画 4K'), findsNWidgets(2));
    expect(find.text('vbox_pg_temp'), findsNWidgets(2));
    expect(find.text('不自动清理'), findsOneWidget);
    expect(find.text('http://127.0.0.1:58090'), findsOneWidget);
    // 非 VIP 时线程 Stepper 不展示（对齐 iOS `if isVip { ... }`）。
    expect(
      find.byKey(const ValueKey<String>('pg_auto_thread_stepper_value')),
      findsNothing,
    );
  });

  testWidgets('开启 VIP 展示线程 Stepper，且加减生效', (WidgetTester tester) async {
    await _pump(
      tester,
      store: store,
      now: DateTime(2026, 10, 3, 12),
    );

    await tester.tap(find.byKey(const ValueKey<String>('pg_auto_vip')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('pg_auto_thread_stepper_value')),
      findsOneWidget,
    );
    // 契约缺省 threadLimit = 3。
    expect(find.text('3'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('pg_auto_thread_stepper_plus')),
    );
    await tester.pumpAndSettle();
    expect(find.text('4'), findsOneWidget);
    // 生效卡同步为 4 线程（白天取 threadLimit）。
    expect(find.text('4 线程'), findsOneWidget);
  });

  testWidgets('切换画质写入生效卡', (WidgetTester tester) async {
    await _pump(tester, store: store);

    await tester.tap(find.byKey(const ValueKey<String>('pg_auto_quality')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('高清 HD').last);
    await tester.pumpAndSettle();

    // 选择器与「当前生效」卡各一处。
    expect(find.text('高清 HD'), findsNWidgets(2));
  });

  testWidgets('保存：写入契约键 + 提示「PG 播放参数已更新」', (WidgetTester tester) async {
    await _pump(tester, store: store);

    await tester.tap(find.byKey(const ValueKey<String>('pg_auto_enabled')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('pg_auto_transfer_dir')),
      '我的转存',
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('pg_auto_auto_cleanup')),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('pg_auto_save')));
    await tester.pumpAndSettle();

    expect(find.text('PG 播放参数已更新'), findsOneWidget);

    final PgAutoConfig saved = await store.load();
    expect(saved.enabled, isTrue);
    expect(saved.autoCleanup, isTrue);
    expect(saved.transferDir, '我的转存');
    // 生效卡：启用 + 自动清理 → 显示延迟清理。
    expect(find.text('60 秒后清理'), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('夜间时段生效卡取夜间线程（注入 now）', (WidgetTester tester) async {
    await store.save(
      PgAutoConfig.defaults.copyWith(
        enabled: true,
        isVip: true,
        threadLimit: 32,
        threadNight: 16,
      ),
    );

    await _pump(tester, store: store, now: DateTime(2026, 10, 3, 20));
    expect(find.text('16 线程'), findsOneWidget);

    await _pump(tester, store: store, now: DateTime(2026, 10, 3, 12));
    expect(find.text('32 线程'), findsOneWidget);
  });

  testWidgets('恢复默认：回到契约缺省并提示', (WidgetTester tester) async {
    await store.save(
      PgAutoConfig.defaults.copyWith(enabled: true, threadLimit: 40),
    );
    await _pump(tester, store: store);
    expect((await store.load()).threadLimit, 40);

    await tester.tap(find.byKey(const ValueKey<String>('pg_auto_reset')));
    await tester.pumpAndSettle();

    expect(find.text('已恢复默认参数'), findsOneWidget);
    expect(await store.load(), PgAutoConfig.defaults);

    await tester.pump(const Duration(seconds: 3));
  });
}
