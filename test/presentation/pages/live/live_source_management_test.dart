/// 直播源选择器 Widget 测试（批次 E · E-04）。
///
/// 通过注入预加载控制器（MockClient）+ fake 文件桥，验证添加/删除/
/// 导入入口与交互，不触碰真实文件选择/分享通道。
library;

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vbox/core/network/http_client.dart';
import 'package:vbox/data/datasources/local/prefs_manager.dart';
import 'package:vbox/presentation/pages/live/import_export.dart';
import 'package:vbox/presentation/pages/live/live_tv_controller.dart';
import 'package:vbox/presentation/pages/live/live_tv_page.dart';

const String _m3u = '#EXTM3U\n'
    '#EXTINF:-1 group-title="News",CCTV-1\n'
    'http://stream/cctv1.m3u8\n';

const String _sourceUrl = 'http://example.com/tv.m3u';

LiveTvController _loadedController() => LiveTvController(
      client: HttpClient(
        inner: MockClient((http.Request _) async => http.Response(_m3u, 200)),
      ),
    );

Future<LiveTvController> _pumpPage(
  WidgetTester tester, {
  LiveFileBridge? bridge,
}) async {
  final LiveTvController controller = _loadedController();
  addTearDown(controller.dispose);
  await controller.fetchSubscribeChannels(_sourceUrl);
  await tester.pumpWidget(MaterialApp(
    home: LiveTVPage(controller: controller, fileBridge: bridge),
  ));
  await tester.pumpAndSettle();
  return controller;
}

Future<void> _openSourceSheet(WidgetTester tester) async {
  // 源切换入口：右下角天线浮动按钮（对齐 iOS `LiveTVView`）。
  await tester.tap(find.byIcon(Icons.settings_input_antenna));
  await tester.pumpAndSettle();
}

class _FakeBridge implements LiveFileBridge {
  _FakeBridge(this.file);

  final SelectedLiveFile? file;
  final List<String> shared = <String>[];

  @override
  Future<SelectedLiveFile?> pickTextFile() async => file;

  @override
  Future<void> shareFile(String path) async => shared.add(path);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    await PrefsManager.instance.init();
  });

  setUp(() async {
    await PrefsManager.instance.clearAll();
  });

  testWidgets('源选择器展示添加/导入入口', (WidgetTester tester) async {
    await _pumpPage(tester);
    await _openSourceSheet(tester);

    expect(find.text('选择直播源 2'), findsOneWidget);
    expect(find.text('添加自定义源'), findsOneWidget);
    expect(find.text('导入本地直播文件'), findsOneWidget);
    expect(find.textContaining('支持导入 M3U'), findsOneWidget);
  });

  testWidgets('添加自定义源后写入列表', (WidgetTester tester) async {
    final LiveTvController controller = await _pumpPage(tester);
    await _openSourceSheet(tester);

    await tester.tap(find.text('添加自定义源'));
    await tester.pumpAndSettle();

    expect(find.text('源名称'), findsOneWidget);
    expect(find.text('M3U/TXT URL'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, '测试源');
    await tester.enterText(
        find.byType(TextField).last, 'http://example.com/tv.m3u');
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();

    expect(find.text('测试源'), findsOneWidget);
    expect(find.text('选择直播源 3'), findsOneWidget);
    expect(controller.customSources.length, 1);
  });

  testWidgets('删除自定义源从列表移除', (WidgetTester tester) async {
    final LiveTvController controller = await _pumpPage(tester);
    await controller.addCustomSource('测试源', 'http://example.com/tv.m3u');

    await _openSourceSheet(tester);
    expect(find.text('测试源'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();

    expect(controller.customSources, isEmpty);
    expect(find.text('测试源'), findsNothing);
  });

  testWidgets('导入本地源解析并切换关闭浮层', (WidgetTester tester) async {
    final _FakeBridge bridge = _FakeBridge(const SelectedLiveFile(
      name: '我的本地',
      content: '央视,CCTV-1,http://a.m3u8\n',
      path: '/tmp/x.txt',
    ));
    final LiveTvController controller = await _pumpPage(tester, bridge: bridge);
    await _openSourceSheet(tester);

    await tester.tap(find.text('导入本地直播文件'));
    await tester.pumpAndSettle();

    expect(controller.currentSource.url, 'local://我的本地');
    expect(controller.categories, isNotEmpty);
    expect(find.text('添加自定义源'), findsNothing); // 浮层已关闭
    expect(bridge.shared, isEmpty);
  });
}