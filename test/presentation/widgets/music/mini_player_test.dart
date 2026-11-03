/// 音乐迷你播放器组件单测（批次 G · G-01 首段）。
///
/// 对齐基准（唯一真相源）：iOS `MiniPlayerBar`
/// （`vbox/Views/MusicPlayerViews.swift:11`）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vbox/data/datasources/local/music_queue_store.dart';
import 'package:vbox/data/datasources/local/prefs_manager.dart';
import 'package:vbox/domain/entities/music/music.dart';
import 'package:vbox/platform/player/music_player.dart';
import 'package:vbox/presentation/widgets/music/mini_player.dart';

MusicQueueItem _item(String id) {
  return MusicQueueItem(
    id: id,
    name: '歌$id',
    artist: '来源',
    coverURL: 'https://c/$id.jpg',
    playURL: 'https://p/$id.mp3',
    sourceName: '测试源',
    engineKey: 'lx_test',
  );
}

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

  Future<MusicPlayerController> pump(
    WidgetTester tester, {
    required List<MusicQueueItem> items,
    VoidCallback? onExpand,
  }) async {
    final MusicPlayerController controller = MusicPlayerController(
      store: MusicQueueStore(pm),
      engine: const UnavailableMusicAudioEngine(),
    );
    if (items.isNotEmpty) {
      await controller.setQueue(items);
    }
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: <Widget>[
              Positioned.fill(
                child: MiniPlayerBar(controller: controller, onExpand: onExpand),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  testWidgets('无歌曲时不渲染浮层', (WidgetTester tester) async {
    await pump(tester, items: const <MusicQueueItem>[]);
    expect(find.byKey(const ValueKey<String>('mini_player_bar')), findsNothing);
  });

  testWidgets('有歌曲时展示歌名 + 播放/下一首控件', (WidgetTester tester) async {
    await pump(tester, items: <MusicQueueItem>[_item('1'), _item('2')]);
    expect(find.text('歌1'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('mini_player_play_pause')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey<String>('mini_player_next')), findsOneWidget);
    // 播放中 → 暂停图标
    expect(find.byIcon(Icons.pause_circle_filled), findsOneWidget);
  });

  testWidgets('单曲队列时下一首禁用', (WidgetTester tester) async {
    await pump(tester, items: <MusicQueueItem>[_item('1')]);
    final IconButton next = tester.widget<IconButton>(
      find.byKey(const ValueKey<String>('mini_player_next')),
    );
    expect(next.onPressed, isNull);
  });

  testWidgets('点击播放/暂停切换图标', (WidgetTester tester) async {
    await pump(tester, items: <MusicQueueItem>[_item('1'), _item('2')]);
    await tester.tap(find.byKey(const ValueKey<String>('mini_player_play_pause')));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.play_circle_fill), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('mini_player_play_pause')));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.pause_circle_filled), findsOneWidget);
  });

  testWidgets('点击下一首切歌', (WidgetTester tester) async {
    await pump(tester, items: <MusicQueueItem>[_item('1'), _item('2')]);
    await tester.tap(find.byKey(const ValueKey<String>('mini_player_next')));
    await tester.pumpAndSettle();
    expect(find.text('歌2'), findsOneWidget);
  });

  testWidgets('右滑折叠为胶囊，点击胶囊展开', (WidgetTester tester) async {
    await pump(tester, items: <MusicQueueItem>[_item('1'), _item('2')]);
    await tester.drag(
      find.byKey(const ValueKey<String>('mini_player_bar')),
      const Offset(120, 0),
    );
    await tester.pumpAndSettle();
    // 折叠态隐藏播放/下一首控件
    expect(
      find.byKey(const ValueKey<String>('mini_player_play_pause')),
      findsNothing,
    );

    await tester.tap(find.byKey(const ValueKey<String>('mini_player_bar')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('mini_player_play_pause')),
      findsOneWidget,
    );
  });

  testWidgets('左滑浮现关闭钮，点击关闭清空队列', (WidgetTester tester) async {
    final MusicPlayerController controller =
        await pump(tester, items: <MusicQueueItem>[_item('1'), _item('2')]);

    await tester.drag(
      find.byKey(const ValueKey<String>('mini_player_bar')),
      const Offset(-90, 0),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('mini_player_close')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('mini_player_close')));
    await tester.pumpAndSettle();
    expect(controller.hasQueue, isFalse);
    expect(find.byKey(const ValueKey<String>('mini_player_bar')), findsNothing);
  });

  testWidgets('点击主体触发展开回调', (WidgetTester tester) async {
    bool expanded = false;
    await pump(
      tester,
      items: <MusicQueueItem>[_item('1'), _item('2')],
      onExpand: () => expanded = true,
    );
    await tester.tap(find.text('歌1'));
    await tester.pumpAndSettle();
    expect(expanded, isTrue);
  });
}
