/// 表现层 widget 测试：下载管理浮层 UI（G-02 UI）。
///
/// 覆盖三件套（对齐 iOS `DownloadOverlayViews.swift`）：
///   ① 胶囊通知：postCapsule 显示 / 5s 自动消失；
///   ② 悬浮按键：有记录显示 / 无记录隐藏 / 点击打开管理弹窗；
///   ③ 管理弹窗：空态、分组列表（下载中/已暂停/已完成/失败）、
///      暂停/继续/重试/删除、清空已完成/清空全部。
///
/// 注入 [InMemoryDownloadStore]（内存 store）+ [_HangingTransport] +
/// [_DirectUrlResolver]（下载停在 downloading，不触网 / 落盘），
/// 保证中间状态确定性可断言。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:vbox/core/storage/storage_paths.dart';
import 'package:vbox/data/models/download.dart';
import 'package:vbox/platform/download/download.dart';
import 'package:vbox/presentation/widgets/download/download_overlay_widgets.dart';

import '../../support/fakes.dart';

Download _record(
  int id,
  String name, {
  DownloadStatus status = DownloadStatus.pending,
  double progress = 0,
  String laiyuan = '站点1',
  int fileSize = 0,
  int downloadedSize = 0,
}) =>
    Download(
      id: id,
      name: name,
      laiyuan: laiyuan,
      status: status,
      progress: progress,
      fileSize: fileSize,
      downloadedSize: downloadedSize,
      addedAt: 1000 + id,
    );

/// 永不完成的传输：让下载停在 downloading，便于断言中间 UI 状态。
class _HangingTransport implements DownloadTransport {
  @override
  Future<String?> fetchString(Uri uri, Map<String, String> headers) =>
      Completer<String?>().future;

  @override
  Future<Uint8List?> fetchData(Uri uri, Map<String, String> headers) =>
      Completer<Uint8List?>().future;

  @override
  Future<DownloadStreamResponse?> openStream(
    Uri uri,
    Map<String, String> headers,
  ) =>
      Completer<DownloadStreamResponse?>().future;
}

/// 固定返回直链（directFile），配合 [_HangingTransport] 停在 downloading。
class _DirectUrlResolver implements DownloadUrlResolver {
  @override
  Future<ResolvedDownloadUrl> resolve(Download record) async =>
      const ResolvedDownloadUrl(
        url: 'https://example.com/video.mp4',
        headers: <String, String>{},
        type: DownloadType.directFile,
      );
}

/// 弹窗宿主：MaterialApp + Navigator + DownloadManager + 悬浮按键。
///
/// 悬浮按键与「打开」按钮同栈，且悬浮按键自身全尺寸占位（内部 Positioned
/// 定位气泡），点击中心按钮不受遮挡。
Widget _host(DownloadManager manager, {Widget? home}) => MultiProvider(
      providers: [
        ChangeNotifierProvider<DownloadManager>.value(value: manager),
      ],
      child: MaterialApp(
        home: home ??
            Builder(
              builder: (BuildContext context) => Scaffold(
                body: Stack(
                  children: <Widget>[
                    Center(
                      child: TextButton(
                        onPressed: () => showDownloadManagementPopup(context),
                        child: const Text('打开'),
                      ),
                    ),
                    FloatingVideoDownloadButton(
                      onTap: () => showDownloadManagementPopup(context),
                    ),
                  ],
                ),
              ),
            ),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // DownloadManager 构造默认取 StoragePaths.downloadDir，需先注入根目录。
    StoragePaths.configure('/tmp/vbox_test');
  });

  group('① 下载胶囊通知', () {
    testWidgets('postCapsule 后显示，5s 自动消失', (WidgetTester tester) async {
      final DownloadManager manager = DownloadManager(store: InMemoryDownloadStore());
      addTearDown(manager.dispose);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<DownloadManager>.value(value: manager),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: Stack(
                children: <Widget>[DownloadCapsuleNotification()],
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // 未发送消息：不显示
      expect(find.textContaining('已添加'), findsNothing);

      manager.postCapsule(
        text: '已添加「示例片 第1集」到下载',
        icon: 'arrow.down.circle.fill',
        type: DownloadCapsuleType.info,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.textContaining('已添加「示例片'), findsOneWidget);

      // 5s 后自动消失
      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.textContaining('已添加「示例片'), findsNothing);
    });
  });

  group('①b 播放器内胶囊通知（对齐 iOS PlayerCapsuleNotification）', () {
    testWidgets('postCapsule 后顶部显示，5s 自动消失', (WidgetTester tester) async {
      final DownloadManager manager = DownloadManager(store: InMemoryDownloadStore());
      addTearDown(manager.dispose);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<DownloadManager>.value(value: manager),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: Stack(
                children: <Widget>[PlayerCapsuleNotification()],
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // 未发送消息：不显示
      expect(find.textContaining('已添加'), findsNothing);

      manager.postCapsule(
        text: '已添加「示例片 第1集」到下载',
        icon: 'arrow.down.circle.fill',
        type: DownloadCapsuleType.info,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.textContaining('已添加「示例片'), findsOneWidget);

      // 5s 后自动消失
      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.textContaining('已添加「示例片'), findsNothing);
    });
  });

  group('② 悬浮下载按键', () {
    testWidgets('无记录隐藏，有记录显示', (WidgetTester tester) async {
      final DownloadManager manager = DownloadManager(
        store: InMemoryDownloadStore(),
        transport: _HangingTransport(),
        urlResolver: _DirectUrlResolver(),
      );
      addTearDown(manager.dispose);
      await tester.pumpWidget(_host(manager));
      await tester.pump();

      expect(find.byType(FloatingVideoDownloadButton), findsOneWidget);
      // 无记录 → 内部 shrink，无气泡
      expect(find.byType(CircularProgressIndicator), findsNothing);

      await manager.enqueue(
        _record(1, '示例片 第1集', status: DownloadStatus.pending),
      );
      await tester.pump();
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsWidgets);
    });

    testWidgets('点击打开下载管理弹窗', (WidgetTester tester) async {
      final DownloadManager manager = DownloadManager(
        store: InMemoryDownloadStore(),
        transport: _HangingTransport(),
        urlResolver: _DirectUrlResolver(),
      );
      addTearDown(manager.dispose);
      await manager.enqueue(
        _record(1, '示例片 第1集',
            status: DownloadStatus.downloading, progress: 0.5),
      );

      await tester.pumpWidget(_host(manager));
      await tester.pump();

      // 悬浮按键全尺寸占位 → 点击其内部气泡（唯一 GestureDetector）。
      await tester.tap(find.descendant(
        of: find.byType(FloatingVideoDownloadButton),
        matching: find.byType(GestureDetector),
      ));
      await tester.pumpAndSettle();

      expect(find.text('下载管理'), findsOneWidget);
      expect(find.textContaining('下载中 (1)'), findsOneWidget);
    });

    testWidgets('关闭悬浮后按键隐藏（hideFloatingButton）', (WidgetTester tester) async {
      final DownloadManager manager = DownloadManager(
        store: InMemoryDownloadStore(),
        transport: _HangingTransport(),
        urlResolver: _DirectUrlResolver(),
      );
      addTearDown(manager.dispose);
      await manager.enqueue(
        _record(1, '示例片 第1集', status: DownloadStatus.pending),
      );

      await tester.pumpWidget(_host(manager));
      await tester.pump();
      await tester.pump();

      manager.hideFloatingButton();
      await tester.pump();

      // widget 仍在树中，但内部渲染 shrink → 无气泡
      expect(find.byType(FloatingVideoDownloadButton), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });

  group('③ 下载管理弹窗', () {
    // 弹窗内容较多时提高视口高度，避免 ListView 懒加载导致底部行未构建。
    void useTallViewport(WidgetTester tester) {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
    }

    testWidgets('空态：暂无下载内容', (WidgetTester tester) async {
      useTallViewport(tester);
      final DownloadManager manager = DownloadManager(store: InMemoryDownloadStore());
      addTearDown(manager.dispose);
      await tester.pumpWidget(_host(manager));
      await tester.pump();

      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();

      expect(find.text('下载管理'), findsOneWidget);
      expect(find.text('暂无下载内容'), findsOneWidget);
      // 空态下清空按钮禁用
      final TextButton clearCompleted = tester.widget<TextButton>(
        find.widgetWithText(TextButton, '清空已完成'),
      );
      expect(clearCompleted.onPressed, isNull);
    });

    testWidgets('分组列表：下载中 / 已暂停 / 已完成 / 失败', (WidgetTester tester) async {
      useTallViewport(tester);
      final DownloadManager manager = DownloadManager(
        store: InMemoryDownloadStore(<Download>[
          _record(1, '下载中甲', status: DownloadStatus.downloading, progress: 0.4),
          _record(2, '等待乙', status: DownloadStatus.pending),
          _record(3, '暂停丙', status: DownloadStatus.paused, progress: 0.6),
          _record(4, '完成丁', status: DownloadStatus.completed, fileSize: 2048),
          _record(5, '失败戊', status: DownloadStatus.failed),
        ]),
      );
      addTearDown(manager.dispose);
      // 构造不自动加载 → 显式刷新（对齐 iOS 启动时 reloadActiveDownloads）。
      await manager.reloadActiveDownloads();
      await tester.pumpWidget(_host(manager));
      await tester.pump();

      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();

      expect(find.text('下载中 (2)'), findsOneWidget);
      expect(find.text('已暂停 (1)'), findsOneWidget);
      expect(find.text('已完成 (1)'), findsOneWidget);
      expect(find.text('下载失败 (1)'), findsOneWidget);

      expect(find.text('下载中甲'), findsOneWidget);
      expect(find.text('等待乙'), findsOneWidget);
      expect(find.text('暂停丙'), findsOneWidget);
      expect(find.text('完成丁'), findsOneWidget);
      expect(find.text('失败戊'), findsOneWidget);

      // 完成行显示大小（2KB）
      expect(find.text('· 2.0 KB'), findsOneWidget);
    });

    testWidgets('暂停 / 继续切换', (WidgetTester tester) async {
      useTallViewport(tester);
      final InMemoryDownloadStore store = InMemoryDownloadStore(
        <Download>[
          _record(1, '进行中', status: DownloadStatus.downloading, progress: 0.3),
        ],
      );
      final DownloadManager manager = DownloadManager(
        store: store,
        transport: _HangingTransport(),
        urlResolver: _DirectUrlResolver(),
      );
      addTearDown(manager.dispose);
      await manager.reloadActiveDownloads();
      await tester.pumpWidget(_host(manager));
      await tester.pump();

      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();

      // 暂停
      await tester.tap(find.byTooltip('暂停'));
      await tester.pumpAndSettle();
      expect(store.items.first.status, DownloadStatus.paused);
      expect(find.text('已暂停 (1)'), findsOneWidget);

      // 继续 → 重新入队，下载停在 downloading（悬挂传输）
      await tester.tap(find.byTooltip('继续'));
      await tester.pumpAndSettle();
      expect(store.items.first.status, DownloadStatus.downloading);
      expect(find.text('下载中 (1)'), findsOneWidget);
      expect(find.text('已暂停 (1)'), findsNothing);
    });

    testWidgets('失败行重试', (WidgetTester tester) async {
      useTallViewport(tester);
      final InMemoryDownloadStore store = InMemoryDownloadStore(
        <Download>[_record(1, '失败项', status: DownloadStatus.failed)],
      );
      final DownloadManager manager = DownloadManager(
        store: store,
        transport: _HangingTransport(),
        urlResolver: _DirectUrlResolver(),
      );
      addTearDown(manager.dispose);
      await manager.reloadActiveDownloads();
      await tester.pumpWidget(_host(manager));
      await tester.pump();

      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();

      // 重试 → 重新入队，下载停在 downloading（悬挂传输）
      await tester.tap(find.byTooltip('重试'));
      await tester.pumpAndSettle();
      expect(store.items.first.status, DownloadStatus.downloading);
      expect(find.text('下载中 (1)'), findsOneWidget);
      expect(find.text('下载失败'), findsNothing);
    });

    testWidgets('失败行删除 → 空态', (WidgetTester tester) async {
      useTallViewport(tester);
      final InMemoryDownloadStore store = InMemoryDownloadStore(
        <Download>[_record(1, '失败项', status: DownloadStatus.failed)],
      );
      final DownloadManager manager = DownloadManager(store: store);
      addTearDown(manager.dispose);
      await manager.reloadActiveDownloads();
      await tester.pumpWidget(_host(manager));
      await tester.pump();

      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();

      // 删除 → 记录清空 → 空态
      await tester.tap(find.byTooltip('删除'));
      await tester.pumpAndSettle();
      expect(store.items, isEmpty);
      expect(find.text('暂无下载内容'), findsOneWidget);
    });

    testWidgets('清空已完成 / 清空全部', (WidgetTester tester) async {
      useTallViewport(tester);
      final InMemoryDownloadStore store = InMemoryDownloadStore(
        <Download>[
          _record(1, '进行中', status: DownloadStatus.downloading),
          _record(2, '已完成', status: DownloadStatus.completed, fileSize: 1024),
        ],
      );
      final DownloadManager manager = DownloadManager(store: store);
      addTearDown(manager.dispose);
      await manager.reloadActiveDownloads();
      await tester.pumpWidget(_host(manager));
      await tester.pump();

      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();

      // 清空已完成
      await tester.tap(find.widgetWithText(TextButton, '清空已完成'));
      await tester.pumpAndSettle();
      expect(store.items.map((Download d) => d.name), <String>['进行中']);
      expect(find.text('已完成 (0)'), findsNothing);

      // 清空全部
      await tester.tap(find.widgetWithText(TextButton, '清空全部'));
      await tester.pumpAndSettle();
      expect(store.items, isEmpty);
      expect(find.text('暂无下载内容'), findsOneWidget);
    });
  });
}
