/// 个人中心页 widget 测试（批次 M · M-账1 推荐码 / M-账2 分享 / M-账3 头像）。
///
/// 对齐 iOS `ProfileView.swift`：
///   · `loginSection`（默认头像 / 点击登录）；
///   · `LoginSheetView`（账号 + 密码 + 上级推荐码）；
///   · `featureEntriesSection`（分享 vbox）。
///
/// 依赖以内存替身注入（`InMemorySettingsStore` / fake 仓储），不触库不触网。
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:vbox/domain/entities/library/library.dart';
import 'package:vbox/domain/usecases/usecases.dart';
import 'package:vbox/presentation/pages/profile/profile_page.dart';
import 'package:vbox/presentation/profile/session_controller.dart';
import 'package:vbox/presentation/welfare/welfare_controller.dart';

import '../../../support/fakes.dart';

/// 零延迟会话控制器（内存 store）。
SessionController _session() => SessionController(
      store: InMemorySettingsStore(),
      loginDelay: Duration.zero,
    );

/// 个人中心外壳（补足 build 期消费的 Provider：会话 / 福利 / 观看记录）。
Widget _host({
  required SessionController session,
  Future<void> Function(String url)? shareLauncher,
  Future<Uint8List?> Function()? avatarPicker,
}) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<SessionController>.value(value: session),
      ChangeNotifierProvider<WelfareController>.value(value: WelfareController()),
      Provider<HistoryUseCases>.value(
        value: HistoryUseCases(InMemoryHistoryRepository(const <HistoryItem>[])),
      ),
    ],
    child: MaterialApp(
      home: ProfilePage(
        shareLauncher: shareLauncher,
        avatarPicker: avatarPicker,
      ),
    ),
  );
}

void main() {
  testWidgets('M-账3：未登录默认头像使用软件图标资源（各端一致）',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host(session: _session()));
    await tester.pumpAndSettle();

    final Finder appIcon = find.byWidgetPredicate(
      (Widget w) =>
          w is Image &&
          w.image is AssetImage &&
          (w.image as AssetImage).assetName == ProfilePage.appIconAsset,
    );
    expect(appIcon, findsOneWidget);
  });

  testWidgets('M-账2：点击「分享vbox」→ 分享器收到软件下载地址',
      (WidgetTester tester) async {
    final List<String> shared = <String>[];
    await tester.pumpWidget(_host(
      session: _session(),
      shareLauncher: (String url) async => shared.add(url),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('分享vbox'));
    await tester.pumpAndSettle();

    expect(shared, hasLength(1));
    expect(shared.single, contains('releases/latest/download/vbox.ipa'));
  });

  testWidgets('W-福3：点击「查看更多 >」→ 进入完整观看记录页',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host(session: _session()));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('查看更多 >'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查看更多 >'));
    await tester.pumpAndSettle();

    // 新页 AppBar 标题 + 历史列表空态（内存仓储为空；文案对齐 iOS
    // `WatchHistoryView`：「暂无观看记录」）。
    expect(find.widgetWithText(AppBar, '观看记录'), findsOneWidget);
    expect(find.text('暂无观看记录'), findsOneWidget);
  });

  testWidgets('M-账1：登录弹窗含上级推荐码字段，提交后落库',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final SessionController session = _session();
    await tester.pumpWidget(_host(session: session));
    await tester.pumpAndSettle();

    // 未登录 → 点击登录打开弹窗。
    await tester.tap(find.text('点击登录'));
    await tester.pumpAndSettle();

    expect(find.text('上级推荐码（选填）'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, '账号'), '199114');
    await tester.enterText(find.widgetWithText(TextField, '密码'), 'abc');
    await tester.enterText(
      find.widgetWithText(TextField, '上级推荐码（选填）'),
      'VIP888',
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('登录 / 注册'));
    await tester.pumpAndSettle();

    expect(session.isLoggedIn, isTrue);
    expect(session.referral, 'VIP888');
  });
}
