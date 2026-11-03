/// 表现层 widget 测试：详情页（加载 / 失败重试 / 线路与剧集 / 播放入口）。
///
/// 注入假 [DetailPlaybackUseCases]（子类覆盖 loadDetail / resolvePlayUrl）；
/// 播放链路注入 `PlayerController.overrideForTest` 假控制器；无 IO、无原生依赖。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:vbox/core/errors/failures.dart';
import 'package:vbox/core/utils/result.dart';
import 'package:vbox/data/datasources/remote/douban_datasource.dart';
import 'package:vbox/data/models/download.dart';
import 'package:vbox/domain/entities/douban/douban_models.dart';
import 'package:vbox/domain/entities/player/player.dart';
import 'package:vbox/domain/entities/playback/playback.dart';
import 'package:vbox/domain/entities/remote_source/remote_source.dart';
import 'package:vbox/domain/entities/spider/spider.dart';
import 'package:vbox/domain/usecases/usecases.dart';
import 'package:vbox/platform/download/download.dart';
import 'package:vbox/platform/player/playback_route.dart';
import 'package:vbox/platform/player/player_channel_bridge.dart';
import 'package:vbox/platform/player/player_controller.dart';
import 'package:vbox/presentation/pages/player/player_page.dart';
import 'package:vbox/presentation/widgets/detail_page.dart';
import 'package:vbox/presentation/widgets/platform_async_image.dart';

import '../../support/fakes.dart';

// ─────────────── 测试替身 ───────────────

/// 假用例：覆盖详情加载与播放地址解析。
class _FakeDetailUseCases extends DetailPlaybackUseCases {
  _FakeDetailUseCases({this.detailResult, this.playerResult})
      : super(
          loadAllSources: () async =>
              const Success<AllSourcesContainer>(AllSourcesContainer()),
        );

  Future<Result<PlaybackDetail>> Function()? detailResult;
  Future<Result<PlayerContentResult>> Function()? playerResult;
  int loadCalls = 0;

  @override
  Future<Result<PlaybackDetail>> loadDetail({
    required String siteKey,
    required String vodId,
    int initialIndex = 0,
  }) {
    loadCalls++;
    final Future<Result<PlaybackDetail>> Function()? f = detailResult;
    if (f == null) {
      return Future<Result<PlaybackDetail>>.value(
        const Err<PlaybackDetail>(UnknownFailure('未注入 detailResult')),
      );
    }
    return f();
  }

  @override
  Future<Result<PlayerContentResult>> resolvePlayUrl({
    required PlaybackDetail detail,
    required PlaybackEpisode episode,
  }) {
    final Future<Result<PlayerContentResult>> Function()? f = playerResult;
    if (f == null) {
      return Future<Result<PlayerContentResult>>.value(
        Success<PlayerContentResult>(PlayerContentResult(url: episode.url)),
      );
    }
    return f();
  }
}

/// 假播放器控制器：记录 open/play 调用。
class _FakePlayerController extends PlayerController {
  _FakePlayerController()
      : super(
          bridge: _NoopBridge(),
          backendChain: const <PlayerBackend>[PlayerBackend.media3],
          selectInitialBackend: (_, PlaybackRoute route) => PlayerBackend.media3,
        );

  final List<String> calls = <String>[];
  String? openedUrl;

  @override
  Future<void> open(PlayerSource source, {PlaybackRoute? route}) async {
    calls.add('open');
    openedUrl = source.url;
  }

  @override
  Future<void> play() async => calls.add('play');
}

class _NoopBridge implements PlayerChannelBridge {
  @override
  Future<Object?> invoke(String method, [Object? arguments]) async => null;

  @override
  Stream<Map<String, Object?>> events() =>
      const Stream<Map<String, Object?>>.empty();

  @override
  Future<void> dispose() async {}
}

/// 瞬时完成的传输：m3u8 播放列表拉取返回 null（下载立即 failed，不触网）；
/// openStream 返回空流兜底（本用例不会走到直链流式路径）。
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

// ─────────────── 数据构造 ───────────────

/// 内存豆瓣数据源：只实现演职 / 大封面三个方法（详情页兜底链路，不触网）。
class _FakeDoubanDatasource extends DoubanDatasource {
  @override
  Future<String?> searchSubjectId(String name) async => 'sub-1';

  @override
  Future<DoubanCredits> fetchCelebrities(String subjectId) async =>
      const DoubanCredits(
        actors: <DoubanCelebrity>[
          DoubanCelebrity(
            id: 'a1',
            name: '豆瓣演员',
            coverUrl: 'https://img.example.com/a.jpg',
            roles: <String>['演员'],
          ),
        ],
        directors: <DoubanCelebrity>[
          DoubanCelebrity(
            id: 'd1',
            name: '豆瓣导演',
            coverUrl: 'https://img.example.com/d.jpg',
            roles: <String>['导演'],
          ),
        ],
        subjectId: 'sub-1',
      );

  @override
  Future<String?> fetchWallpaperUrl(String subjectId) async => null;
}

VodItem vod({String? playUrl}) => VodItem.fromJson(<String, Object?>{
      'vod_id': '123',
      'vod_name': '示例片',
      'vod_pic': '',
      'vod_play_from': '线路1\$\$\$线路2',
      'vod_play_url': playUrl ??
          '第1集\$https://v.com/1.m3u8#第2集\$https://v.com/2.m3u8'
              '\$\$\$第1集\$https://v.com/3.m3u8',
    });

PlaybackDetail detail({String? playUrl, int initialIndex = 0}) =>
    PlaybackDetail.fromVod(
      site: SiteConfig.fromJson(<String, Object?>{
        'key': 's1',
        'name': '站点1',
        'type': 0,
      }),
      vod: vod(playUrl: playUrl),
      initialIndex: initialIndex,
    );

/// 带站点演员文本的详情（演职兜底链路测试用）。
PlaybackDetail detailWithActors() => PlaybackDetail.fromVod(
      site: SiteConfig.fromJson(<String, Object?>{
        'key': 's1',
        'name': '站点1',
        'type': 0,
      }),
      vod: vodWithActors(),
    );

/// 带站点演员文本的影片（验证演职兜底链路：站点文本不阻断豆瓣头像数据）。
VodItem vodWithActors() => VodItem.fromJson(<String, Object?>{
      'vod_id': '123',
      'vod_name': '示例片',
      'vod_pic': '',
      'vod_actor': '站点演员甲,站点演员乙',
      'vod_director': '站点导演',
      'vod_play_from': '线路1',
      'vod_play_url': '第1集\$https://v.com/1.m3u8',
    });

Widget _app(
  _FakeDetailUseCases uc, {
  int initialIndex = 0,
  DownloadManager? manager,
  DoubanUseCases? douban,
}) =>
    MultiProvider(
      providers: [
        Provider<DetailPlaybackUseCases>.value(value: uc),
        if (douban != null) Provider<DoubanUseCases>.value(value: douban),
        if (manager != null)
          ChangeNotifierProvider<DownloadManager>.value(value: manager),
      ],
      child: MaterialApp(
        home: DetailPage(
          siteKey: 's1',
          vodId: '123',
          initialIndex: initialIndex,
          title: '详情',
        ),
      ),
    );

void main() {
  late _FakePlayerController player;

  setUp(() {
    player = _FakePlayerController();
    PlayerController.overrideForTest(player);
  });

  testWidgets('加载中：显示进度圈，完成后展示详情', (WidgetTester tester) async {
    final Completer<Result<PlaybackDetail>> completer =
        Completer<Result<PlaybackDetail>>();
    final _FakeDetailUseCases uc =
        _FakeDetailUseCases(detailResult: () => completer.future);
    await tester.pumpWidget(_app(uc));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    completer.complete(Success<PlaybackDetail>(detail()));
    await tester.pumpAndSettle();
    // Hero 大标题（无 TMDB logo 时以片名兜底）+ 下方 14pt 片名 = 2 处（对齐 iOS）。
    expect(find.text('示例片'), findsNWidgets(2));
  });

  testWidgets('加载失败：错误提示 + 重试后恢复', (WidgetTester tester) async {
    final _FakeDetailUseCases uc = _FakeDetailUseCases(
      detailResult: () async =>
          const Err<PlaybackDetail>(NetworkFailure('断网')),
    );
    await tester.pumpWidget(_app(uc));
    await tester.pumpAndSettle();

    expect(find.textContaining('断网'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    uc.detailResult = () async => Success<PlaybackDetail>(detail());
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(uc.loadCalls, 2);
    // Hero 大标题（无 TMDB logo 时以片名兜底）+ 下方 14pt 片名 = 2 处（对齐 iOS）。
    expect(find.text('示例片'), findsNWidgets(2));
  });

  testWidgets('加载成功：影片信息 / 线路 / 剧集 / 播放按钮', (WidgetTester tester) async {
    final _FakeDetailUseCases uc = _FakeDetailUseCases(
      detailResult: () async => Success<PlaybackDetail>(detail()),
    );
    await tester.pumpWidget(_app(uc));
    await tester.pumpAndSettle();

    // Hero 大标题（无 TMDB logo 时以片名兜底）+ 下方 14pt 片名 = 2 处（对齐 iOS）。
    expect(find.text('示例片'), findsNWidgets(2));
    expect(find.text('线路1'), findsOneWidget);
    expect(find.text('线路2'), findsOneWidget);
    expect(find.text('第1集'), findsOneWidget);
    expect(find.text('第2集'), findsOneWidget);
    expect(find.text('立即播放'), findsOneWidget);
  });

  testWidgets('线路切换：仅显示该线路剧集', (WidgetTester tester) async {
    final _FakeDetailUseCases uc = _FakeDetailUseCases(
      detailResult: () async => Success<PlaybackDetail>(detail()),
    );
    await tester.pumpWidget(_app(uc));
    await tester.pumpAndSettle();

    // 初始线路1：第1集 + 第2集
    expect(find.text('第1集'), findsOneWidget);
    expect(find.text('第2集'), findsOneWidget);

    // Hero 大标题使内容整体下移，线路胶囊可能落在视口外 → 先滚动到可见再点。
    await tester.ensureVisible(find.text('线路2'));
    await tester.tap(find.text('线路2'));
    await tester.pumpAndSettle();

    expect(find.text('第2集'), findsNothing);
    expect(find.text('第1集'), findsOneWidget);
  });

  testWidgets('续播入口：initialIndex 指向的剧集高亮', (WidgetTester tester) async {
    final _FakeDetailUseCases uc = _FakeDetailUseCases(
      detailResult: () async =>
          Success<PlaybackDetail>(detail(initialIndex: 1)),
    );
    await tester.pumpWidget(_app(uc, initialIndex: 1));
    await tester.pumpAndSettle();

    // 选中集以 `detailSelected` 描边高亮（`_EpisodeCell`：selected → BorderSide，
    // 未选中 → BorderSide.none），宫格内应恰好 1 处高亮（对齐 iOS 续播定位）。
    expect(
      find.descendant(
        of: find.byType(GridView),
        matching: find.byWidgetPredicate((Widget w) {
          if (w is! Material) return false;
          final ShapeBorder? shape = w.shape;
          return shape is RoundedRectangleBorder &&
              shape.side != BorderSide.none;
        }),
      ),
      findsOneWidget,
    );
  });

  testWidgets('点击播放：解析 → 进入全屏播放页并 open/play', (WidgetTester tester) async {
    final _FakeDetailUseCases uc = _FakeDetailUseCases(
      detailResult: () async => Success<PlaybackDetail>(detail()),
    );
    await tester.pumpWidget(_app(uc));
    await tester.pumpAndSettle();

    await tester.tap(find.text('立即播放'));
    // 播放页进入后常驻加载层（转圈动画），不能用 pumpAndSettle（永不 settle）；
    // 用有界 pump 完成导航转场与首轮异步（open/play）。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // Wave A · R-渲2：不在详情页直接起播，而是进入全屏播放页。
    expect(find.byType(PlayerPage), findsOneWidget);
    expect(player.calls, <String>['open', 'play']);
    expect(player.openedUrl, 'https://v.com/1.m3u8');

    // 排空播放页控制层自动隐藏计时器（避免测试结束仍有 pending timer）。
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('解析失败：先进入播放器，播放器内给出错误提示（可返回）',
      (WidgetTester tester) async {
    final _FakeDetailUseCases uc = _FakeDetailUseCases(
      detailResult: () async => Success<PlaybackDetail>(detail()),
      playerResult: () async =>
          const Err<PlayerContentResult>(ParseFailure('无法解析')),
    );
    await tester.pumpWidget(_app(uc));
    await tester.pumpAndSettle();

    await tester.tap(find.text('立即播放'));
    // 问题4：先 push 播放器（立即呈现），解析下沉到播放器内；失败后收起加载层
    // 并在播放器内给出错误提示（对齐 iOS 先 present 后 resolve）。
    // 播放页进入后有常驻加载层动画，不能用 pumpAndSettle（永不 settle）。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 已进入播放器，但解析失败 → 未 open/play。
    expect(find.byType(PlayerPage), findsOneWidget);
    expect(player.calls, isEmpty);
    expect(find.text('加载失败'), findsOneWidget);
    // 错误提示同时以「原因文案」与「调试日志（加载失败：<原因>）」两处出现，
    // 故按精确文案断言（textContaining 会同时命中日志行，得到 2 个 widget）。
    expect(find.text('解析失败，请重试'), findsOneWidget);
    expect(find.text('返回'), findsOneWidget);

    // 排空播放页控制层自动隐藏计时器（避免测试结束仍有 pending timer）。
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('无剧集：播放按钮禁用', (WidgetTester tester) async {
    final _FakeDetailUseCases uc = _FakeDetailUseCases(
      detailResult: () async => Success<PlaybackDetail>(detail(playUrl: '')),
    );
    await tester.pumpWidget(_app(uc));
    await tester.pumpAndSettle();

    expect(find.text('暂无剧集'), findsOneWidget);
    await tester.tap(find.text('立即播放'));
    await tester.pumpAndSettle();
    expect(player.calls, isEmpty);
  });

  testWidgets('下载：剧集展开弹窗多选 → 确认 → 入队 DownloadManager（G-02 接线）',
      (WidgetTester tester) async {
    final _FakeDetailUseCases uc = _FakeDetailUseCases(
      detailResult: () async => Success<PlaybackDetail>(detail()),
    );
    final InMemoryDownloadStore store = InMemoryDownloadStore();
    final DownloadManager manager = DownloadManager(
      store: store,
      transport: _InstantDownloadTransport(),
      downloadsDirectory: '/tmp/vbox_test/dl',
    );
    addTearDown(manager.dispose);
    await tester.pumpWidget(_app(uc, manager: manager));
    await tester.pumpAndSettle();

    // 展开弹窗的下载多选模式（对齐 iOS `EpisodeExpandPopup`：↓ 图标进入多选）。
    await tester.tap(find.byIcon(Icons.download_outlined).first);
    await tester.pumpAndSettle();

    // 单选第1集 → 头部打勾提交（对齐 iOS `checkmark.circle.fill` 提交下载）。
    await tester.tap(find.text('第1集').last);
    await tester.pump();
    await tester.tap(find.byIcon(Icons.check_circle).first);
    await tester.pumpAndSettle();

    // 记录已入队（字段对齐 iOS handleBatchDownload）
    expect(store.items, hasLength(1));
    final Download saved = store.items.single;
    expect(saved.name, '示例片 第1集');
    expect(saved.laiyuan, '站点1');
    expect(saved.detailurl, '123');
    expect(saved.jishu, 1);
    expect(saved.playurl, 'https://v.com/1.m3u8');
    expect(find.textContaining('已添加 1 集到下载'), findsOneWidget);
    // 排空第一个 SnackBar（等其关闭动画结束），否则会遮挡底部剧集头部按钮。
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    // 再次打开：勾选两集 → 确认 → 两集全部入队（累计 3 条）。
    // 先隐藏悬浮下载气泡（首次入队后 activeDownloads 含已完成记录，气泡
    // 常驻右下；ensureVisible 后恰好遮住剧集头部按钮中心，tap 会被气泡
    // 拦截误开下载管理弹窗。对齐 iOS：气泡可拖动/关闭以避开页面内容）。
    manager.hideFloatingButton();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byIcon(Icons.download_outlined).first);
    await tester.tap(find.byIcon(Icons.download_outlined).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('第1集').last);
    await tester.pump();
    await tester.tap(find.text('第2集').last);
    await tester.pump();
    await tester.tap(find.byIcon(Icons.check_circle).first);
    await tester.pumpAndSettle();

    expect(store.items, hasLength(3));
    expect(
      store.items.map((Download d) => d.playurl).toSet(),
      containsAll(<String>['https://v.com/1.m3u8', 'https://v.com/2.m3u8']),
    );
    expect(find.textContaining('已添加 2 集到下载'), findsOneWidget);

    // 排空 SnackBar 自动关闭计时器
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('剧集宫格：点击集数直接起播该集（对齐 iOS handleEpisodeSelect）',
      (WidgetTester tester) async {
    final _FakeDetailUseCases uc = _FakeDetailUseCases(
      detailResult: () async => Success<PlaybackDetail>(detail()),
    );
    await tester.pumpWidget(_app(uc));
    await tester.pumpAndSettle();

    // 宫格在首屏下方 → 先滚动到可见再点。
    await tester.ensureVisible(find.text('第2集'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('第2集'));
    // 播放页进入后常驻加载层（转圈动画），不能用 pumpAndSettle（永不 settle）；
    // 用有界 pump 完成导航转场与首轮异步（open/play）。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(player.calls, containsAll(<String>['open', 'play']));
    expect(player.openedUrl, 'https://v.com/2.m3u8');

    // 排空播放页控制层自动隐藏计时器（避免测试结束仍有 pending timer）。
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('剧集宫格：集数多时内部可上下滑动（对齐 iOS maxHeight 300 滚动区）',
      (WidgetTester tester) async {
    final String playUrl = List<String>.generate(
      200,
      (int i) => '第${i + 1}集\$https://v.com/${i + 1}.m3u8',
    ).join('#');
    final _FakeDetailUseCases uc = _FakeDetailUseCases(
      detailResult: () async => Success<PlaybackDetail>(detail(playUrl: playUrl)),
    );
    await tester.pumpWidget(_app(uc));
    await tester.pumpAndSettle();

    // 宫格先滚入视口（外层页面滚动），尾部集数超出 300pt 滚动区不可见。
    await tester.ensureVisible(find.text('第1集'));
    await tester.pumpAndSettle();
    expect(find.text('第1集'), findsOneWidget);
    expect(find.text('第200集'), findsNothing);

    // 在宫格内上滑 → 尾部集数滑入（宫格独立滚动生效）。
    await tester.drag(find.text('第1集'), const Offset(0, -400));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(GridView), const Offset(0, -400));
    await tester.pumpAndSettle();

    expect(find.text('第200集'), findsOneWidget);
  });

  testWidgets('演职人员：豆瓣兜底写入头像卡，站点文本不阻断也不兜底',
      (WidgetTester tester) async {
    final _FakeDetailUseCases uc = _FakeDetailUseCases(
      detailResult: () async => Success<PlaybackDetail>(detailWithActors()),
    );
    await tester.pumpWidget(_app(
      uc,
      douban: DoubanUseCases(datasource: _FakeDoubanDatasource()),
    ));
    await tester.pumpAndSettle();

    // 豆瓣演职显示（带头像）。
    expect(find.text('豆瓣演员'), findsOneWidget);
    expect(find.text('豆瓣导演'), findsOneWidget);
    // 演员头像 + 导演头像两张卡（vod_pic 为空 → 无背景图干扰）。
    expect(find.byType(PlatformAsyncImage), findsNWidgets(2));
    // 站点文本不兜底（对齐 iOS：两边皆无才隐藏，有豆瓣则只显示豆瓣）。
    expect(find.text('站点演员甲'), findsNothing);
    expect(find.text('站点导演'), findsNothing);
  });

  testWidgets('演职人员：无 TMDB / 豆瓣数据时整块隐藏（对齐 iOS castSection）',
      (WidgetTester tester) async {
    final _FakeDetailUseCases uc = _FakeDetailUseCases(
      detailResult: () async => Success<PlaybackDetail>(detailWithActors()),
    );
    await tester.pumpWidget(_app(uc));
    await tester.pumpAndSettle();

    expect(find.text('全部'), findsNothing);
    expect(find.text('站点演员甲'), findsNothing);
    expect(find.byType(PlatformAsyncImage), findsNothing);
  });
}
