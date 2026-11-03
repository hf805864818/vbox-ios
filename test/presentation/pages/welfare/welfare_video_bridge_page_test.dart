/// 呈现层单测：福利播放中转页（批次 H · H-03 续段）。
///
/// 对齐 iOS `FuliVideoBridgeView`：封面 + 标题 + 操作行（选集 / 播放 /
/// 线路 / 下载四胶囊）+ 线路 / 选集悬浮面板 + 解析浮层 + 下载选集 Sheet。
/// 覆盖：单线路 / 多线路渲染、选集面板、线路切换、播放解析成功与失败、
/// 错态重试、下载 Sheet 多选确认回补提示。
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vbox/data/models/download.dart';
import 'package:vbox/domain/entities/player/player.dart';
import 'package:vbox/domain/entities/welfare/fuli_models.dart';
import 'package:vbox/domain/services/fuli_base_service.dart';
import 'package:vbox/platform/download/download_manager.dart';
import 'package:vbox/platform/download/download_transport.dart';
import 'package:vbox/platform/player/play_url_parser.dart';
import 'package:vbox/platform/player/playback_route.dart';
import 'package:vbox/platform/player/player_channel_bridge.dart';
import 'package:vbox/platform/player/player_controller.dart';
import 'package:vbox/presentation/pages/player/player_page.dart';
import 'package:vbox/presentation/pages/welfare/welfare_video_bridge_page.dart';

import '../../../support/fakes.dart';

/// 瞬时完成的传输：任何请求返回 null / 空流（下载立即失败，不触网）。
class _InstantDownloadTransport implements DownloadTransport {
  @override
  Future<String?> fetchString(Uri uri, Map<String, String> headers) async =>
      null;

  @override
  Future<Uint8List?> fetchData(Uri uri, Map<String, String> headers) async =>
      null;

  @override
  Future<DownloadStreamResponse?> openStream(
    Uri uri,
    Map<String, String> headers,
  ) async =>
      const DownloadStreamResponse(
        statusCode: 200,
        totalBytes: 0,
        bytes: Stream<Uint8List>.empty(),
      );
}

/// 假服务：可配置详情与播放结果。
class _FakeFuliService extends FuliBaseService {
  _FakeFuliService({required this.detail, this.playerResult})
      : super(
          platformKey: 'demo',
          platformName: '演示平台',
          defaultHosts: const <String>['https://a.example.com'],
        );

  final FuliDetail detail;
  FuliPlayerResult? playerResult;

  @override
  String get currentHost => 'https://a.example.com';

  @override
  bool get isHostReady => true;

  @override
  void reprobe() {}

  @override
  void resetDomain() {}

  @override
  Future<FuliDetail> fetchDetail(String vodId) async => detail;

  @override
  Future<FuliPlayerResult> fetchPlayerURL(FuliEpisode episode) async {
    // 缺省忠实返回该集 URL（对齐基类按 URL 后缀判定 parse），
    // 注入 playerResult 时（如失败用例）优先返回。
    return playerResult ??
        FuliPlayerResult(
          url: episode.url,
          headers: const <String, String>{'Referer': 'https://a.example.com'},
          parse: 0,
        );
  }
}

/// 播放回调记录器。
class _PlayRecorder {
  final List<String> urls = <String>[];
  final List<Map<String, String>> headersList = <Map<String, String>>[];

  Future<void> call(String url, Map<String, String> headers) async {
    urls.add(url);
    headersList.add(headers);
  }
}

/// 假播放器控制器：不触真实方法通道，仅记录 open 的播放源与显式路由。
class _FakePlayerController extends PlayerController {
  _FakePlayerController()
      : super(
          bridge: MethodChannelPlayerBridge(),
          backendChain: const <PlayerBackend>[PlayerBackend.media3],
          selectInitialBackend:
              (PlayerSource s, PlaybackRoute r) => PlayerBackend.media3,
        );

  final List<PlayerSource> opened = <PlayerSource>[];
  final List<PlaybackRoute?> routes = <PlaybackRoute?>[];

  @override
  PlayerBackend? get backend => PlayerBackend.media3;

  @override
  Future<void> open(PlayerSource source, {PlaybackRoute? route}) async {
    opened.add(source);
    routes.add(route);
  }

  @override
  Future<void> play() async {}

  @override
  Future<void> togglePlay() async {}

  @override
  Future<void> seekTo(int positionMs) async {}

  @override
  Future<void> setSpeed(double speed) async {}

  @override
  Future<void> switchBackend(PlayerBackend backend) async {}

  @override
  Future<void> dispose() async {}
}

FuliVideo _video() => const FuliVideo(
      vodId: 'v1',
      vodName: '测试影片',
      vodPic: 'https://img.example.com/v1.jpg',
    );

/// 单线路单集。
FuliDetail _singleDetail() => const FuliDetail(
      vodId: 'v1',
      vodName: '测试影片',
      vodPic: 'https://img.example.com/v1.jpg',
      vodContent: '这是一段简介。',
      playFrom: '在线播放',
      episodes: <FuliEpisode>[
        FuliEpisode(name: '第1集', url: 'https://cdn.example.com/ep1.m3u8'),
      ],
    );

/// 多线路多集（`[线路名]` 前缀，对齐 `WelfareResultMapper` 输出）。
FuliDetail _multiLineDetail() => const FuliDetail(
      vodId: 'v1',
      vodName: '测试影片',
      vodPic: 'https://img.example.com/v1.jpg',
      vodContent: '多线路影片简介。',
      playFrom: r'线路1$$$线路2',
      episodes: <FuliEpisode>[
        FuliEpisode(name: '[线路1] 第1集', url: 'https://cdn.example.com/l1e1.m3u8'),
        FuliEpisode(name: '[线路1] 第2集', url: 'https://cdn.example.com/l1e2.m3u8'),
        FuliEpisode(name: '[线路2] 第1集', url: 'https://cdn.example.com/l2e1.m3u8'),
      ],
    );

Widget _page(
  _FakeFuliService service, {
  _PlayRecorder? recorder,
  PlayUrlParser? parser,
  DownloadManager? manager,
}) {
  return MaterialApp(
    home: WelfareVideoBridgePage(
      service: service,
      video: _video(),
      playUrlParser: parser,
      downloadManager: manager,
      onPlay: recorder == null
          ? null
          : (String url, Map<String, String> headers) =>
                recorder.call(url, headers),
    ),
  );
}

/// 内存 store + 瞬时传输的下载管理器（不触网 / 不落盘）。
DownloadManager _memoryManager(InMemoryDownloadStore store) => DownloadManager(
      store: store,
      transport: _InstantDownloadTransport(),
      downloadsDirectory: '/tmp/vbox_test/welfare_dl',
    );

void main() {
  testWidgets('单线路：封面 + 标题 + 立即播放 + 下载，无选集/线路按钮',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      _page(_FakeFuliService(detail: _singleDetail())),
    );
    await tester.pumpAndSettle();

    expect(find.text('测试影片'), findsWidgets);
    // 简介在 800×600 测试视口下位于首屏之外，属 ListView 懒加载离屏区，
    // 用 skipOffstage 断言其在树中存在（真机竖屏首屏即可见）。
    expect(find.text('这是一段简介。', skipOffstage: false), findsOneWidget);
    expect(find.text('立即播放'), findsOneWidget);
    expect(find.text('下载'), findsOneWidget);
    expect(find.textContaining('选集('), findsNothing);
    expect(find.textContaining('线路('), findsNothing);
  });

  testWidgets('多线路：显示选集(n) 与线路(n) 胶囊', (WidgetTester tester) async {
    await tester.pumpWidget(
      _page(_FakeFuliService(detail: _multiLineDetail())),
    );
    await tester.pumpAndSettle();

    expect(find.text('选集(2)'), findsOneWidget);
    expect(find.text('线路(2)'), findsOneWidget);
    // 当前线路（线路1）默认选第 1 集。
    expect(find.text('播放第1集'), findsOneWidget);
  });

  testWidgets('选集面板：展开 → 点选集触发播放并关闭面板',
      (WidgetTester tester) async {
    final _PlayRecorder recorder = _PlayRecorder();
    await tester.pumpWidget(
      _page(_FakeFuliService(detail: _multiLineDetail()), recorder: recorder),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('选集(2)'));
    await tester.pumpAndSettle();

    // 面板标题 + 当前线路两集。
    expect(find.text('选集'), findsOneWidget);
    expect(find.text('第1集'), findsWidgets);
    expect(find.text('第2集'), findsOneWidget);

    await tester.tap(find.text('第2集'));
    await tester.pumpAndSettle();

    expect(find.text('选集'), findsNothing);
    expect(recorder.urls, hasLength(1));
    expect(recorder.urls.single, 'https://cdn.example.com/l1e2.m3u8');
  });

  testWidgets('线路面板：展开 → 切换线路后按新线路首集播放',
      (WidgetTester tester) async {
    final _PlayRecorder recorder = _PlayRecorder();
    await tester.pumpWidget(
      _page(_FakeFuliService(detail: _multiLineDetail()), recorder: recorder),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('线路(2)'));
    await tester.pumpAndSettle();

    expect(find.text('选择线路'), findsOneWidget);
    expect(find.text('线路1'), findsOneWidget);
    expect(find.text('线路2'), findsOneWidget);

    await tester.tap(find.text('线路2'));
    await tester.pumpAndSettle();

    expect(find.text('选择线路'), findsNothing);
    // 线路2 仅 1 集 → 播放按钮文案对齐 iOS：`currentEpisodes.count == 1 ? "立即播放"`。
    expect(find.text('立即播放'), findsOneWidget);

    await tester.tap(find.text('立即播放'));
    await tester.pumpAndSettle();
    expect(recorder.urls, hasLength(1));
    expect(recorder.urls.single, 'https://cdn.example.com/l2e1.m3u8');
  });

  testWidgets('点击封面播放按钮：解析成功并携请求头回调',
      (WidgetTester tester) async {
    final _PlayRecorder recorder = _PlayRecorder();
    await tester.pumpWidget(
      _page(_FakeFuliService(detail: _singleDetail()), recorder: recorder),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('立即播放'));
    await tester.pumpAndSettle();

    expect(recorder.urls, hasLength(1));
    // 单线路详情首集 URL（假服务忠实返回该集地址）。
    expect(recorder.urls.single, 'https://cdn.example.com/ep1.m3u8');
    expect(
      recorder.headersList.single['Referer'],
      'https://a.example.com',
    );
  });

  testWidgets('解析失败：展示浮层，取消关闭', (WidgetTester tester) async {
    final _FakeFuliService service = _FakeFuliService(
      detail: _singleDetail(),
      playerResult: const FuliPlayerResult(
        url: '',
        headers: <String, String>{},
        parse: 0,
      ),
    );
    final _PlayRecorder recorder = _PlayRecorder();
    await tester.pumpWidget(_page(service, recorder: recorder));
    await tester.pumpAndSettle();

    await tester.tap(find.text('立即播放'));
    await tester.pumpAndSettle();

    expect(find.text('播放地址解析失败'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    // 重试仍空 URL → 仍失败。
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('播放地址解析失败'), findsOneWidget);

    // 取消关闭浮层。
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('播放地址解析失败'), findsNothing);
    expect(recorder.urls, isEmpty);
  });

  testWidgets('空剧集错态：文案 + 重试按钮', (WidgetTester tester) async {
    await tester.pumpWidget(
      _page(
        _FakeFuliService(
          detail: const FuliDetail(
            vodId: 'v1',
            vodName: '测试影片',
            vodPic: '',
            vodContent: null,
            playFrom: '',
            episodes: <FuliEpisode>[],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('未解析到播放地址'), findsWidgets);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('下载 Sheet：4 列网格多选 → 确认 → 逐集解析入队 DownloadManager（W-福4）',
      (WidgetTester tester) async {
    final InMemoryDownloadStore store = InMemoryDownloadStore();
    final DownloadManager manager = _memoryManager(store);
    addTearDown(manager.dispose);

    await tester.pumpWidget(
      _page(_FakeFuliService(detail: _multiLineDetail()), manager: manager),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('下载'));
    await tester.pumpAndSettle();

    expect(find.text('选择下载集数'), findsOneWidget);
    expect(find.textContaining('共 2 集，已选 0 集'), findsOneWidget);
    expect(find.text('下载选中(0)'), findsOneWidget);

    // 选 2 集。
    await tester.tap(find.text('第1集'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('第2集'));
    await tester.pumpAndSettle();

    expect(find.textContaining('已选 2 集'), findsOneWidget);
    expect(find.text('下载选中(2)'), findsOneWidget);

    await tester.tap(find.text('下载选中(2)'));
    await tester.pumpAndSettle();

    expect(find.text('选择下载集数'), findsNothing);
    expect(find.text('已添加 2 集到下载'), findsOneWidget);

    // 字段对齐 iOS `handleBatchDownload`：`[福利]<平台名>` / `__fuli_welfare__:<key>`。
    expect(store.items, hasLength(2));
    final Download first = store.items.first;
    expect(first.name, '测试影片 第1集');
    expect(first.laiyuan, '[福利]演示平台');
    expect(first.engineKey, '__fuli_welfare__:demo');
    expect(first.sourceType, 'normal');
    expect(first.detailurl, 'v1');
    expect(first.vodId, 'v1');
    expect(first.jishu, 1);
    expect(first.playurl, 'https://cdn.example.com/l1e1.m3u8');

    // 放掉 2s 提示自动隐藏定时器，避免 teardown 报 pending timer。
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('parse=1：先经 PlayUrlParser 提取直链再交播放器（W-福5）',
      (WidgetTester tester) async {
    final _FakeFuliService service = _FakeFuliService(
      detail: _singleDetail(),
      playerResult: const FuliPlayerResult(
        url: 'https://page.example.com/play/123',
        headers: <String, String>{'Referer': 'https://a.example.com'},
        parse: 1,
      ),
    );
    final PlayUrlParser parser = PlayUrlParser(
      client: MockClient((http.Request request) async => http.Response(
            '<html><body><video src="https://cdn.example.com/real.m3u8"></video></body></html>',
            200,
            headers: <String, String>{'content-type': 'text/html'},
          )),
    );
    addTearDown(parser.dispose);

    final _PlayRecorder recorder = _PlayRecorder();
    await tester.pumpWidget(
      _page(service, recorder: recorder, parser: parser),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('立即播放'));
    await tester.pumpAndSettle();

    expect(recorder.urls, hasLength(1));
    expect(recorder.urls.single, 'https://cdn.example.com/real.m3u8');
    // headers 保留原始值（对齐 iOS：解析后仍用原 headers）。
    expect(recorder.headersList.single['Referer'], 'https://a.example.com');
  });

  testWidgets('parse=1 解析失败：回落原 URL 交播放器（W-福5）',
      (WidgetTester tester) async {
    final _FakeFuliService service = _FakeFuliService(
      detail: _singleDetail(),
      playerResult: const FuliPlayerResult(
        url: 'https://page.example.com/play/123',
        headers: <String, String>{},
        parse: 1,
      ),
    );
    // 播放页无直链 → parse 返回 null → 回落原 URL。
    final PlayUrlParser parser = PlayUrlParser(
      client: MockClient((http.Request request) async => http.Response(
            '<html><body>no playable url</body></html>',
            200,
            headers: <String, String>{'content-type': 'text/html'},
          )),
    );
    addTearDown(parser.dispose);

    final _PlayRecorder recorder = _PlayRecorder();
    await tester.pumpWidget(
      _page(service, recorder: recorder, parser: parser),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('立即播放'));
    await tester.pumpAndSettle();

    expect(recorder.urls, hasLength(1));
    expect(recorder.urls.single, 'https://page.example.com/play/123');
  });

  testWidgets('缺省播放：解析成功后进入全屏播放页 PlayerPage（对齐 iOS fullScreenCover）',
      (WidgetTester tester) async {
    final _FakePlayerController player = _FakePlayerController();
    PlayerController.overrideForTest(player);

    await tester.pumpWidget(_page(_FakeFuliService(detail: _singleDetail())));
    await tester.pumpAndSettle();

    await tester.tap(find.text('立即播放'));
    // 播放页进入后常驻加载层（转圈动画），不能用 pumpAndSettle（永不 settle）。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(PlayerPage), findsOneWidget);
    expect(player.opened, hasLength(1));
    expect(player.opened.single.url, 'https://cdn.example.com/ep1.m3u8');

    // 放掉播放页 5s 控制层自动隐藏定时器，避免 teardown 报 pending timer。
    await tester.pump(const Duration(seconds: 6));
  });
}
