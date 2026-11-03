/// 推送播放页 widget 测试（批次 G · G-03）。
///
/// 对齐 iOS `PushPlayView.swift` + `AddPushPlayLinkView`：
/// 空态、添加流程（类型选择 / 自动识别 / 校验）、列表卡片、播放触发、
/// 编辑模式批量删除、清空确认、长按删除、详情页选集与播放。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/data/datasources/local/push_play_store.dart';
import 'package:vbox/domain/entities/cloud/cloud_drive.dart';
import 'package:vbox/domain/entities/push/push_play.dart';
import 'package:vbox/presentation/pages/push/push_play_detail_page.dart';
import 'package:vbox/presentation/pages/push/push_play_page.dart';

/// 播放回调记录器。
class _PlayRecorder {
  final List<String> titles = <String>[];
  final List<String> urls = <String>[];

  Future<void> call(String url, String title) async {
    urls.add(url);
    titles.add(title);
  }
}

/// 网盘展开回调记录器（E-12）。
class _CloudRecorder {
  final List<CloudDriveType> types = <CloudDriveType>[];
  final List<String> urls = <String>[];

  Future<void> call(CloudDriveType type, String url) async {
    types.add(type);
    urls.add(url);
  }
}

/// 内存态存储（prefs 为 null → 不落盘，适合 widget 测试）。
PushPlayStore _store() => PushPlayStore();

Widget _host(PushPlayStore store, {PushPlayHandler? onPlay}) {
  return MaterialApp(
    home: PushPlayPage(store: store, onPlay: onPlay),
  );
}

void main() {
  testWidgets('空态：图标 + 「暂无推送链接」+ 引导 + 「添加链接」按钮',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host(_store()));
    await tester.pumpAndSettle();

    expect(find.text('推送播放'), findsOneWidget);
    expect(find.text('暂无推送链接'), findsOneWidget);
    expect(find.text('点击右上角 + 添加网盘或播放链接'), findsOneWidget);
    expect(find.text('添加链接'), findsOneWidget);
  });

  testWidgets('添加流程：打开 sheet → 输入 URL → 自动识别 → 添加 → 列表出现',
      (WidgetTester tester) async {
    final PushPlayStore store = _store();
    await tester.pumpWidget(_host(store));
    await tester.pumpAndSettle();

    // 空态「添加链接」→ sheet。
    await tester.tap(find.text('添加链接'));
    await tester.pumpAndSettle();
    expect(find.text('链接地址'), findsOneWidget);

    // 输入直链 URL。
    await tester.enterText(
      find.widgetWithText(TextField, '粘贴网盘或视频链接'),
      'https://cdn.example.com/v.m3u8',
    );
    // 自动识别 → 直链。
    await tester.tap(find.text('自动识别类型'));
    await tester.pump();
    // 添加。
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();

    // 列表出现条目（默认标题「直链视频」+ 类型徽标 + URL）。
    expect(store.items, hasLength(1));
    expect(store.items.single.title, '直链视频');
    expect(store.items.single.type, PushPlayLinkType.direct);
    expect(find.text('直链视频'), findsOneWidget);
    expect(find.text('https://cdn.example.com/v.m3u8'), findsOneWidget);
    expect(find.text('直链播放'), findsOneWidget);
  });

  testWidgets('添加流程：空 URL 校验错误提示', (WidgetTester tester) async {
    await tester.pumpWidget(_host(_store()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('添加链接'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();

    expect(find.text('请输入链接地址'), findsOneWidget);
  });

  testWidgets('列表：最新在前 + 标题/URL/类型徽标/集数 + 播放按钮',
      (WidgetTester tester) async {
    final PushPlayStore store = _store();
    store.addItem(title: 'A', url: 'https://a.com/1', type: PushPlayLinkType.direct);
    store.addItem(title: 'B', url: 'https://b.com/2', type: PushPlayLinkType.web);
    // 给 A 写入剧集（对齐 updateItem）。
    final PushPlayItem itemA = store.items.last;
    store.updateItem(
      itemA,
      const <PushPlayEpisode>[
        PushPlayEpisode(name: '第1集', url: 'https://a.com/e1.m3u8'),
        PushPlayEpisode(name: '第2集', url: 'https://a.com/e2.m3u8'),
      ],
    );

    await tester.pumpWidget(_host(store));
    await tester.pumpAndSettle();

    // 最新（B）在前。
    final List<Text> titles = tester
        .widgetList<Text>(find.byType(Text))
        .where((Text t) => t.data == 'A' || t.data == 'B')
        .toList();
    expect(titles, hasLength(2));
    // A 的卡片在 B 下方：A 的纵向位置更大。
    final double dyA = tester.getTopLeft(find.text('A')).dy;
    final double dyB = tester.getTopLeft(find.text('B')).dy;
    expect(dyB, lessThan(dyA));

    // 类型徽标 + 集数。
    expect(find.text('网页解析'), findsOneWidget);
    expect(find.text('2 集'), findsOneWidget);
    // 播放按钮存在（IconButton 内；direct 类型图标盒同图标，需精确限定）。
    expect(
      find.widgetWithIcon(IconButton, Icons.play_circle_fill),
      findsNWidgets(2),
    );
  });

  testWidgets('播放：点击播放按钮 → 回调记录 title/url（G-03 接线）',
      (WidgetTester tester) async {
    final PushPlayStore store = _store();
    store.addItem(title: 'A', url: 'https://a.com/1', type: PushPlayLinkType.direct);
    final _PlayRecorder recorder = _PlayRecorder();
    await tester.pumpWidget(_host(store, onPlay: recorder.call));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithIcon(IconButton, Icons.play_circle_fill));
    await tester.pumpAndSettle();

    expect(recorder.urls, <String>['https://a.com/1']);
    expect(recorder.titles, <String>['A']);
  });

  testWidgets('编辑模式：更多菜单 → 批量删除 → 全选 → 删除选中 → 空态',
      (WidgetTester tester) async {
    final PushPlayStore store = _store();
    store.addItem(title: 'A', url: 'https://a.com/1', type: PushPlayLinkType.direct);
    store.addItem(title: 'B', url: 'https://b.com/2', type: PushPlayLinkType.web);
    await tester.pumpWidget(_host(store));
    await tester.pumpAndSettle();

    // 更多菜单 → 批量删除。
    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();
    await tester.tap(find.text('批量删除'));
    await tester.pumpAndSettle();

    // 编辑态：全选 + 完成 + 删除选中 (0)。
    expect(find.text('全选'), findsOneWidget);
    expect(find.text('完成'), findsOneWidget);
    expect(find.text('删除选中 (0)'), findsOneWidget);

    // 全选 → 删除选中 (2)。
    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    expect(find.text('删除选中 (2)'), findsOneWidget);

    await tester.tap(find.text('删除选中 (2)'));
    await tester.pumpAndSettle();

    expect(store.items, isEmpty);
    expect(find.text('暂无推送链接'), findsOneWidget);
  });

  testWidgets('清空全部：更多菜单 → 确认弹窗 → 空态', (WidgetTester tester) async {
    final PushPlayStore store = _store();
    store.addItem(title: 'A', url: 'https://a.com/1', type: PushPlayLinkType.direct);
    await tester.pumpWidget(_host(store));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空全部'));
    await tester.pumpAndSettle();

    expect(find.text('确认清空'), findsOneWidget);
    expect(find.textContaining('确定要清空所有 1 条推送链接吗'), findsOneWidget);

    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();

    expect(store.items, isEmpty);
    expect(find.text('暂无推送链接'), findsOneWidget);
  });

  testWidgets('长按删除：确认弹窗 → 删除单条', (WidgetTester tester) async {
    final PushPlayStore store = _store();
    store.addItem(title: 'A', url: 'https://a.com/1', type: PushPlayLinkType.direct);
    await tester.pumpWidget(_host(store));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('A'));
    await tester.pumpAndSettle();
    expect(find.text('删除推送链接'), findsOneWidget);

    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(store.items, isEmpty);
  });

  group('PushPlayDetailPage（对齐 iOS VideoDetailView 本地数据模式）', () {
    /// 详情页为纵向 ListView，放大测试视口确保封面后的按钮/宫格在首屏内。
    void tallViewport(WidgetTester tester) {
      tester.view.physicalSize = const Size(390, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
    }

    testWidgets('单集（无 episodes）：封面 + 立即播放', (WidgetTester tester) async {
      tallViewport(tester);
      final _PlayRecorder recorder = _PlayRecorder();
      await tester.pumpWidget(MaterialApp(
        home: PushPlayDetailPage(
          item: PushPlayItem(
            title: '直链视频',
            url: 'https://cdn.example.com/v.m3u8',
            type: PushPlayLinkType.direct,
            createdAt: DateTime.utc(2026, 1, 1),
          ),
          onPlay: recorder.call,
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('直链视频'), findsWidgets);
      expect(find.text('🎬 直链播放'), findsOneWidget);
      expect(find.text('立即播放'), findsOneWidget);

      await tester.tap(find.text('立即播放'));
      await tester.pumpAndSettle();
      expect(recorder.urls, <String>['https://cdn.example.com/v.m3u8']);
    });

    testWidgets('多集（episodes）：选集宫格 → 点击即播', (WidgetTester tester) async {
      tallViewport(tester);
      final _PlayRecorder recorder = _PlayRecorder();
      await tester.pumpWidget(MaterialApp(
        home: PushPlayDetailPage(
          item: PushPlayItem(
            title: '测试剧',
            url: 'https://a.com/1',
            type: PushPlayLinkType.direct,
            createdAt: DateTime.utc(2026, 1, 1),
            episodes: const <PushPlayEpisode>[
              PushPlayEpisode(name: '第1集', url: 'https://a.com/e1.m3u8'),
              PushPlayEpisode(name: '第2集', url: 'https://a.com/e2.m3u8'),
            ],
          ),
          onPlay: recorder.call,
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('剧集列表'), findsOneWidget);
      expect(find.text('第1集'), findsOneWidget);
      expect(find.text('第2集'), findsOneWidget);
      expect(find.text('播放第1集'), findsOneWidget);

      // 点第2集 → 播放该集。
      await tester.tap(find.text('第2集'));
      await tester.pumpAndSettle();
      expect(recorder.urls, <String>['https://a.com/e2.m3u8']);
      expect(recorder.titles, <String>['测试剧 第2集']);
    });

    testWidgets('E-12：网盘分享链接 → 「展开选集」回调（识别网盘类型）',
        (WidgetTester tester) async {
      tallViewport(tester);
      final _CloudRecorder recorder = _CloudRecorder();
      await tester.pumpWidget(MaterialApp(
        home: PushPlayDetailPage(
          item: PushPlayItem(
            title: '夸克分享',
            url: 'https://pan.quark.cn/s/abc123',
            type: PushPlayLinkType.cloud,
            createdAt: DateTime.utc(2026, 1, 1),
          ),
          onOpenCloudFiles: recorder.call,
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('展开选集'), findsOneWidget);
      expect(find.text('立即播放'), findsNothing);

      await tester.tap(find.text('展开选集'));
      await tester.pumpAndSettle();
      expect(recorder.types, <CloudDriveType>[CloudDriveType.quark]);
      expect(recorder.urls, <String>['https://pan.quark.cn/s/abc123']);
    });

    testWidgets('E-12：网盘类型无法识别 → 回退「立即播放」', (WidgetTester tester) async {
      tallViewport(tester);
      final _PlayRecorder play = _PlayRecorder();
      final _CloudRecorder cloud = _CloudRecorder();
      await tester.pumpWidget(MaterialApp(
        home: PushPlayDetailPage(
          item: PushPlayItem(
            title: '未知网盘',
            url: 'https://unknown.example.com/s/abc',
            type: PushPlayLinkType.cloud,
            createdAt: DateTime.utc(2026, 1, 1),
          ),
          onPlay: play.call,
          onOpenCloudFiles: cloud.call,
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('立即播放'), findsOneWidget);
      expect(find.text('展开选集'), findsNothing);

      await tester.tap(find.text('立即播放'));
      await tester.pumpAndSettle();
      expect(play.urls, <String>['https://unknown.example.com/s/abc']);
      expect(cloud.urls, isEmpty);
    });
  });
}
