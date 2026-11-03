/// 网盘文件列表页 Widget 单测（批次 F · F-07）。
///
/// 对齐基准（唯一真相源）：iOS 播放链「多文件列表 + 转存 + 清理队列」面
/// （`vbox/Services/CloudDriveManager.swift`）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vbox/data/datasources/local/cloud_drive_cleanup_queue_store.dart';
import 'package:vbox/data/datasources/local/prefs_manager.dart';
import 'package:vbox/domain/entities/cloud/cloud_drive.dart';
import 'package:vbox/domain/entities/cloud/cloud_drive_files.dart';
import 'package:vbox/domain/entities/cloud/cloud_play_item.dart';
import 'package:vbox/domain/entities/cloud/node_pan.dart';
import 'package:vbox/domain/entities/player/player.dart';
import 'package:vbox/platform/player/pan_player.dart';
import 'package:vbox/platform/player/player_channel_bridge.dart';
import 'package:vbox/platform/player/player_controller.dart';
import 'package:vbox/platform/player/playback_route.dart';
import 'package:vbox/presentation/pages/cloud/files.dart';
import 'package:vbox/presentation/pages/cloud/files_controller.dart';
import 'package:vbox/presentation/pages/player/player_page.dart';

/// 假播放器控制器（避免播放页走真实平台通道）。
class _StubBridge implements PlayerChannelBridge {
  @override
  Future<Object?> invoke(String method, [Object? arguments]) async => null;

  @override
  Stream<Map<String, Object?>> events() =>
      const Stream<Map<String, Object?>>.empty();

  @override
  Future<void> dispose() async {}
}

class _FakePlayerController extends PlayerController {
  _FakePlayerController()
      : super(
          bridge: _StubBridge(),
          backendChain: const <PlayerBackend>[PlayerBackend.media3],
          selectInitialBackend: (_, PlaybackRoute route) => PlayerBackend.media3,
        );

  @override
  Future<void> open(PlayerSource source, {PlaybackRoute? route}) async {}

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> seekTo(int positionMs) async {}

  @override
  Future<void> setSpeed(double speed) async {}

  @override
  Future<void> setVolume(double volume) async {}
}

/// 假网盘播放编排：覆盖分享解析（C-盘2）与取链（F-08 接播放页）。
class _FakePanPlayer extends PanPlayer {
  _FakePanPlayer(this.share, {this.prepared});

  final NodePanShare share;

  /// 取链返回值（null → 交由默认实现报错）。
  final CloudPlayItem? prepared;

  int resolveCalls = 0;
  int prepareCalls = 0;

  /// 最近一次 `resolveShare` 收到的分享链接（校验 F-P27 剥离 fragment）。
  String? lastResolveShareUrl;

  /// 最近一次 `prepare` 收到的条目（校验 F-P27 定位到指定剧集）。
  NodePanEntry? lastPrepareEntry;

  @override
  Future<NodePanShare> resolveShare(CloudDriveType type, String shareUrl) async {
    resolveCalls++;
    lastResolveShareUrl = shareUrl;
    return share;
  }

  @override
  Future<CloudPlayItem> prepare({
    required CloudDriveType type,
    required String shareUrl,
    required NodePanEntry entry,
    String? sourceKey,
    String? routePreference,
    DateTime? now,
  }) async {
    prepareCalls++;
    lastPrepareEntry = entry;
    if (prepared == null) {
      throw const PanPlayException('未预置取链结果');
    }
    return prepared!;
  }
}

/// 内存目录列举替身（parentId → 条目）。
class _FakeLister implements CloudDriveFileLister {
  _FakeLister(this.tree);

  final Map<String, List<CloudDriveFileEntry>> tree;
  final List<String> calls = <String>[];

  @override
  Future<List<CloudDriveFileEntry>> list({
    required CloudDriveType drive,
    required String parentId,
  }) async {
    calls.add(parentId);
    return List<CloudDriveFileEntry>.of(
      tree[parentId] ?? const <CloudDriveFileEntry>[],
    );
  }
}

Future<void> _pump(
  WidgetTester tester, {
  required CloudDriveFileLister lister,
  required CloudDriveCleanupQueueStore store,
  CloudDriveType drive = CloudDriveType.quark,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: CloudDriveFilesPage(
        driveType: drive,
        lister: lister,
        cleanupStore: store,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final PrefsManager pm = PrefsManager.instance;
  late CloudDriveCleanupQueueStore store;
  late _FakeLister lister;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    await pm.init();
  });

  setUp(() async {
    await pm.clearAll();
    store = CloudDriveCleanupQueueStore(pm);
    lister = _FakeLister(<String, List<CloudDriveFileEntry>>{
      '': <CloudDriveFileEntry>[
        const CloudDriveFileEntry(fileId: 'dir_1', name: '季风剧场', isFolder: true),
        const CloudDriveFileEntry(fileId: 'v_1', name: 'EP01.mp4', size: 2048),
      ],
      'dir_1': <CloudDriveFileEntry>[
        const CloudDriveFileEntry(fileId: 'v_2', name: 'EP02.mkv', size: 1048576),
      ],
    });
  });

  testWidgets('顶栏 + 面包屑 + 文件夹优先条目列表', (WidgetTester tester) async {
    await _pump(tester, lister: lister, store: store);

    expect(find.text('夸克网盘 文件列表'), findsOneWidget);
    expect(find.text('夸克网盘'), findsOneWidget);
    // 文件夹在前（compareTo 排序）。
    expect(find.text('季风剧场'), findsOneWidget);
    expect(find.text('EP01.mp4'), findsOneWidget);
    expect(find.text('2.0 KB'), findsOneWidget);
    expect(lister.calls, <String>['']);
  });

  testWidgets('点击文件夹进入子目录并更新面包屑', (WidgetTester tester) async {
    await _pump(tester, lister: lister, store: store);

    await tester.tap(find.text('季风剧场'));
    await tester.pumpAndSettle();

    expect(lister.calls, <String>['', 'dir_1']);
    expect(find.text('夸克网盘 / 季风剧场'), findsOneWidget);
    expect(find.text('EP02.mkv'), findsOneWidget);
  });

  testWidgets('点击文件转存入清理队列；重复点击命中去重', (WidgetTester tester) async {
    await _pump(tester, lister: lister, store: store);

    expect(find.text('暂无待清理项'), findsOneWidget);

    await tester.tap(find.text('EP01.mp4'));
    await tester.pumpAndSettle();
    expect(await store.count(), 1);
    expect(find.text('待清理 1 项'), findsOneWidget);

    await tester.tap(find.text('EP01.mp4'));
    await tester.pumpAndSettle();
    // 去重：仍只有 1 条，并提示已在队列中。
    expect(await store.count(), 1);
    expect(find.text('该文件已在清理队列中'), findsOneWidget);

    // 放掉 VboxToast 的 2s 自动关闭定时器，避免 teardown 报 pending timer。
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('未到期时「立即清理」提示无可清理项', (WidgetTester tester) async {
    await _pump(tester, lister: lister, store: store);

    await tester.tap(find.text('EP01.mp4'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('cloud_cleanup_now')));
    await tester.pumpAndSettle();

    expect(await store.count(), 1);
    expect(find.text('暂无可清理项（未到期）'), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('已到期条目「立即清理」移除并清空队列', (WidgetTester tester) async {
    await store.enqueue(
      drive: CloudDriveType.quark.id,
      tokenName: '',
      fileIds: <String>['v_1'],
      delay: Duration.zero,
      now: DateTime.now().subtract(const Duration(minutes: 5)),
    );

    await _pump(tester, lister: lister, store: store);
    expect(find.text('待清理 1 项'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('cloud_cleanup_now')));
    await tester.pumpAndSettle();

    expect(await store.count(), 0);
    expect(find.text('已清理 1 项'), findsOneWidget);
    expect(find.text('暂无待清理项'), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('空目录展示占位文案', (WidgetTester tester) async {
    await _pump(
      tester,
      lister: _FakeLister(<String, List<CloudDriveFileEntry>>{}),
      store: store,
    );
    expect(find.text('当前目录没有文件'), findsOneWidget);
  });

  testWidgets('列举器缺省未接入时报错文案', (WidgetTester tester) async {
    final CloudDriveFilesController controller = CloudDriveFilesController(
      driveType: CloudDriveType.quark,
      cleanupStore: store,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: CloudDriveFilesPage(
          driveType: CloudDriveType.quark,
          controller: controller,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('尚未接入'), findsOneWidget);
  });

  test('分享模式：resolveShare → 文件条目 + 标题（C-盘2）', () async {
    final _FakePanPlayer pan = _FakePanPlayer(
      const NodePanShare(title: '季风剧场', entries: <NodePanEntry>[
        NodePanEntry(playID: 'p1', name: 'EP01.mp4'),
        NodePanEntry(playID: 'p2', name: 'EP02.mp4'),
      ]),
    );
    final CloudDriveFilesController c = CloudDriveFilesController(
      driveType: CloudDriveType.one15,
      cleanupStore: store,
      shareUrl: 'https://share/abc',
      panPlayer: pan,
    );
    await c.load();

    expect(c.isShareMode, isTrue);
    expect(c.title, '季风剧场');
    expect(c.breadcrumb, '季风剧场');
    expect(c.entries.map((CloudDriveFileEntry e) => e.name).toList(),
        <String>['EP01.mp4', 'EP02.mp4']);
    expect(await c.goUp(), isFalse); // 分享模式无目录层级
    expect(pan.resolveCalls, 1);
  });

  test('分享模式：vbox fragment 剥离 + 定位下标（F-P27 消费端）', () async {
    final _FakePanPlayer pan = _FakePanPlayer(
      const NodePanShare(title: '季风剧场', entries: <NodePanEntry>[
        NodePanEntry(playID: 'p1', name: 'EP01.mp4'),
        NodePanEntry(playID: 'p2', name: 'EP02.mp4'),
      ]),
    );
    final CloudDriveFilesController c = CloudDriveFilesController(
      driveType: CloudDriveType.one15,
      cleanupStore: store,
      shareUrl: 'https://share/abc#vbox_fid=p2',
      panPlayer: pan,
    );
    await c.load();

    // 解析前剥离 vbox fragment，只把干净分享链接交给网盘链路。
    expect(pan.lastResolveShareUrl, 'https://share/abc');
    expect(c.fragment.fid, 'p2');
    // 定位到用户点击的第 2 条（而非首条）。
    expect(c.locatedIndex, 1);
  });

  test('分享模式：无 vbox fragment → locatedIndex = -1（不自动定位）', () async {
    final _FakePanPlayer pan = _FakePanPlayer(
      const NodePanShare(title: '季风剧场', entries: <NodePanEntry>[
        NodePanEntry(playID: 'p1', name: 'EP01.mp4'),
      ]),
    );
    final CloudDriveFilesController c = CloudDriveFilesController(
      driveType: CloudDriveType.one15,
      cleanupStore: store,
      shareUrl: 'https://share/abc',
      panPlayer: pan,
    );
    await c.load();

    expect(c.fragment.isEmpty, isTrue);
    expect(c.locatedIndex, -1);
  });

  test('分享模式：未注入 PanPlayer → 报错文案', () async {
    final CloudDriveFilesController c = CloudDriveFilesController(
      driveType: CloudDriveType.one15,
      cleanupStore: store,
      shareUrl: 'https://share/abc',
    );
    await c.load();
    expect(c.error, contains('尚未接入'));
    expect(c.entries, isEmpty);
  });

  testWidgets('分享模式页面：渲染条目 + 隐藏清理队列卡', (WidgetTester tester) async {
    final _FakePanPlayer pan = _FakePanPlayer(
      const NodePanShare(title: '季风剧场', entries: <NodePanEntry>[
        NodePanEntry(playID: 'p1', name: 'EP01.mp4'),
      ]),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: CloudDriveFilesPage(
          driveType: CloudDriveType.one15,
          shareUrl: 'https://share/abc',
          panPlayer: pan,
          cleanupStore: store,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('季风剧场'), findsOneWidget);
    expect(find.text('EP01.mp4'), findsOneWidget);
    expect(find.text('清理队列'), findsNothing);
    expect(find.text('当前目录没有文件'), findsNothing);
  });

  testWidgets('分享模式：多视频文件 → 进入播放页并带选集列表（点选即播 + 选集切换）',
      (WidgetTester tester) async {
    PlayerController.overrideForTest(_FakePlayerController());
    final _FakePanPlayer pan = _FakePanPlayer(
      const NodePanShare(title: '季风剧场', entries: <NodePanEntry>[
        NodePanEntry(playID: 'p1', name: 'EP01.mp4'),
        NodePanEntry(playID: 'p2', name: 'EP02.mp4'),
      ]),
      prepared: CloudPlayItem(
        provider: CloudDriveType.one15.id,
        sourceKey: 'p1',
        fileName: 'EP01.mp4',
        playURL: 'https://cdn.example/ep1.m3u8',
        updatedAt: DateTime(2026, 10, 5),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: CloudDriveFilesPage(
          driveType: CloudDriveType.one15,
          shareUrl: 'https://share/abc',
          panPlayer: pan,
          cleanupStore: store,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('EP01.mp4'));
    // 播放页进入后常驻加载层（转圈动画），不能用 pumpAndSettle（永不 settle）。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final PlayerPage page = tester.widget<PlayerPage>(find.byType(PlayerPage));
    expect(
      page.episodes.map((e) => e.name).toList(),
      <String>['EP01.mp4', 'EP02.mp4'],
    );
    expect(page.episodes.first.fileId, 'p1');
    expect(page.initialEpisodeIndex, 0);
    expect(page.onResolveEpisode, isNotNull);
    expect(page.route, PlaybackRoute.pan);

    // 排空播放页计时器（自动隐藏 + 加载层）。
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('分享模式：仅一个视频文件 → 单文件播放（不引入选集）',
      (WidgetTester tester) async {
    PlayerController.overrideForTest(_FakePlayerController());
    final _FakePanPlayer pan = _FakePanPlayer(
      const NodePanShare(title: '季风剧场', entries: <NodePanEntry>[
        NodePanEntry(playID: 'p1', name: 'EP01.mp4'),
      ]),
      prepared: CloudPlayItem(
        provider: CloudDriveType.one15.id,
        sourceKey: 'p1',
        fileName: 'EP01.mp4',
        playURL: 'https://cdn.example/ep1.m3u8',
        updatedAt: DateTime(2026, 10, 5),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: CloudDriveFilesPage(
          driveType: CloudDriveType.one15,
          shareUrl: 'https://share/abc',
          panPlayer: pan,
          cleanupStore: store,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('EP01.mp4'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final PlayerPage page = tester.widget<PlayerPage>(find.byType(PlayerPage));
    expect(page.episodes, isEmpty);
    expect(page.onResolveEpisode, isNull);

    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('分享模式：vbox fragment 定位 → 自动播放指定条目（F-P27 消费端）',
      (WidgetTester tester) async {
    final _FakePanPlayer pan = _FakePanPlayer(
      const NodePanShare(title: '季风剧场', entries: <NodePanEntry>[
        NodePanEntry(playID: 'p1', name: 'EP01.mp4'),
        NodePanEntry(playID: 'p2', name: 'EP02.mp4'),
      ]),
      // 取链返回空地址 → resolveEntry 抛错，不进入播放页（仅校验定位到指定条目）。
      prepared: CloudPlayItem(
        provider: CloudDriveType.one15.id,
        sourceKey: 'p2',
        fileName: 'EP02.mp4',
        updatedAt: DateTime(2026, 10, 5),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: CloudDriveFilesPage(
          driveType: CloudDriveType.one15,
          shareUrl: 'https://share/abc#vbox_fid=p2',
          panPlayer: pan,
          cleanupStore: store,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 加载完即自动定位：取链条目的 playID 为 fragment 指定的第 2 条（非首条）。
    expect(pan.lastPrepareEntry?.playID, 'p2');
    expect(pan.lastResolveShareUrl, 'https://share/abc');

    // 排空 VboxToast（取链空地址提示）的自动关闭计时器。
    await tester.pump(const Duration(seconds: 5));
  });

  test('分享模式：resolveEntry 取链返回播放源（F-08 接播放页）', () async {
    final CloudPlayItem item = CloudPlayItem(
      provider: CloudDriveType.one15.id,
      sourceKey: 'p1',
      fileName: 'EP01.mp4',
      playURL: 'https://cdn.example/x.m3u8',
      headers: const <String, String>{'Referer': 'https://pan.example'},
      updatedAt: DateTime(2026, 10, 5),
    );
    final _FakePanPlayer pan = _FakePanPlayer(
      const NodePanShare(title: '季风剧场', entries: <NodePanEntry>[]),
      prepared: item,
    );
    final CloudDriveFilesController c = CloudDriveFilesController(
      driveType: CloudDriveType.one15,
      cleanupStore: store,
      shareUrl: 'https://share/abc',
      panPlayer: pan,
    );

    final CloudPlayItem out = await c.resolveEntry(
      const CloudDriveFileEntry(fileId: 'p1', name: 'EP01.mp4'),
    );

    expect(out.playURL, 'https://cdn.example/x.m3u8');
    expect(out.headers['Referer'], 'https://pan.example');
    expect(pan.prepareCalls, 1);
  });

  test('分享模式：取链为空地址 → 报错「播放地址为空」', () async {
    final _FakePanPlayer pan = _FakePanPlayer(
      const NodePanShare(title: '季风剧场', entries: <NodePanEntry>[]),
      prepared: CloudPlayItem(
        provider: CloudDriveType.one15.id,
        sourceKey: 'p1',
        fileName: 'EP01.mp4',
        updatedAt: DateTime(2026, 10, 5),
      ),
    );
    final CloudDriveFilesController c = CloudDriveFilesController(
      driveType: CloudDriveType.one15,
      cleanupStore: store,
      shareUrl: 'https://share/abc',
      panPlayer: pan,
    );

    await expectLater(
      c.resolveEntry(const CloudDriveFileEntry(fileId: 'p1', name: 'EP01.mp4')),
      throwsA(
        isA<PanPlayException>().having(
          (PanPlayException e) => e.message,
          'message',
          '播放地址为空',
        ),
      ),
    );
  });

  test('分享模式：未注入 PanPlayer → resolveEntry 报「尚未接入」', () async {
    final CloudDriveFilesController c = CloudDriveFilesController(
      driveType: CloudDriveType.one15,
      cleanupStore: store,
      shareUrl: 'https://share/abc',
    );

    await expectLater(
      c.resolveEntry(const CloudDriveFileEntry(fileId: 'p1', name: 'EP01.mp4')),
      throwsA(
        isA<CloudDriveFilesException>().having(
          (CloudDriveFilesException e) => e.message,
          'message',
          contains('尚未接入'),
        ),
      ),
    );
  });
}
