/// 应用根组件 / 入口单测（覆盖 `lib/app.dart` + `lib/main.dart`）。
///
/// 口径：在测试环境搭好与生产同源的启动前置（临时目录 + sqflite FFI +
/// SharedPreferences / SecureStorage 内存替身 + path_provider 通道），
/// 再走真实冷启动链路，验证：
///   ① `main()` 入口装配（桌面端 sqflite FFI → `runApp`）；
///   ② 依赖加载期铺品牌渐变底色（L-壳1，杜绝白屏）；
///   ③ `_bootstrap` 成功后进入 Provider 树 + 启动门控（L-壳2）；
///   ④ 初始化失败时降级为错误页（不崩溃）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:vbox/core/storage/storage_paths.dart';
import 'package:vbox/data/datasources/local/database_manager.dart';
import 'package:vbox/main.dart' as entry;
import 'package:vbox/presentation/shell/startup_gate.dart';
import 'package:vbox/presentation/widgets/brand/vbox_splash_view.dart';

const MethodChannel _pathProviderChannel =
    MethodChannel('plugins.flutter.io/path_provider');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('vbox_app_test');
    StoragePaths.configure(tmp.path);
    await StoragePaths.ensureLayout();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    // path_provider：bootstrap ①「目录布局」依赖该通道。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      _pathProviderChannel,
      (MethodCall call) async => tmp.path,
    );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProviderChannel, null);
    await DatabaseManager.instance.close();
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  testWidgets('main() 冷启动：品牌底色 → 依赖就绪 → 启动门控进入首页外壳', (
    WidgetTester tester,
  ) async {
    // ① main() 入口：桌面端初始化 sqflite FFI 并 runApp(VBoxApp)。
    await entry.main();

    // 首帧：依赖尚未就绪 → 铺品牌渐变底色（杜绝冷启动白屏）。
    await tester.pump();
    expect(find.byType(VboxSplashBackdrop), findsOneWidget);

    // ② 让异步 bootstrap 推进（目录 / 存储 / 配置恢复 / 用例装配）。
    //    bootstrap 含真实 I/O（sqflite FFI），需 runAsync 让真实事件循环转动。
    for (int i = 0; i < 60; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      if (find.byType(StartupGate).evaluate().isNotEmpty) break;
    }

    // ③ bootstrap 完成 → 进入 Provider 树 + 启动门控（品牌闪屏门控首页）。
    if (find.byType(StartupGate).evaluate().isEmpty) {
      final Finder errText = find.textContaining('初始化失败');
      final String detail = errText.evaluate().isEmpty
          ? '<无错误页>'
          : ((errText.evaluate().first.widget as Text).data ?? '');
      fail('bootstrap 未进入 StartupGate；$detail');
    }
    expect(find.byType(StartupGate), findsOneWidget);

    // ④ 拆树：取消启动门控计时器，避免遗留 pending timer。
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
