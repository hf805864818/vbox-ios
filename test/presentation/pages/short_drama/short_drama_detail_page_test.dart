/// 表现层 widget 测试：短剧详情专页（对齐 iOS `ShortDramaDetailView`）。
///
/// 注入假 [DetailPlaybackUseCases]（子类覆盖 loadDetail / resolvePlayUrl）；
/// 无 IO、无原生依赖。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:vbox/core/errors/failures.dart';
import 'package:vbox/core/utils/result.dart';
import 'package:vbox/domain/entities/playback/playback.dart';
import 'package:vbox/domain/entities/remote_source/remote_source.dart';
import 'package:vbox/domain/entities/spider/spider.dart';
import 'package:vbox/domain/usecases/usecases.dart';
import 'package:vbox/presentation/pages/short_drama/short_drama_detail_page.dart';
import 'package:vbox/presentation/pages/short_drama/short_drama_page.dart';

/// 假详情用例：loadDetail 返回注入结果（按源遍历语义等价）。
class _FakeDetailUseCases extends DetailPlaybackUseCases {
  _FakeDetailUseCases({this.detail})
      : super(
          loadAllSources: () async =>
              const Success<AllSourcesContainer>(AllSourcesContainer()),
        );

  final PlaybackDetail? detail;
  int loadCalls = 0;

  @override
  Future<Result<PlaybackDetail>> loadDetail({
    required String siteKey,
    required String vodId,
    int initialIndex = 0,
  }) async {
    loadCalls++;
    final PlaybackDetail? d = detail;
    if (d == null) {
      return const Err<PlaybackDetail>(UnknownFailure('未注入详情'));
    }
    return Success<PlaybackDetail>(d);
  }

  @override
  Future<Result<PlayerContentResult>> resolvePlayUrl({
    required PlaybackDetail detail,
    required PlaybackEpisode episode,
  }) async {
    return Success<PlayerContentResult>(PlayerContentResult(url: episode.url));
  }
}

ShortDramaSource source() => const ShortDramaSource(
      id: 's1_1',
      name: '站点1',
      siteKey: 's1',
      categoryId: '1',
      categoryName: '短剧',
    );

const VodItem drama = VodItem(vodId: '1', vodName: '测试短剧', vodPic: '');

PlaybackDetail detailWithEpisodes() => PlaybackDetail.fromVod(
      site: const SiteConfig(
        key: 's1',
        name: '站点1',
        type: 0,
        api: 'https://s1.example.com',
      ),
      vod: const VodItem(
        vodId: '1',
        vodName: '测试短剧',
        vodPic: '',
        vodContent: '剧情简介内容',
        vodPlayFrom: '线路1',
        vodPlayUrl: '第1集\$https://x/1.m3u8#第2集\$https://x/2.m3u8',
      ),
    );

Widget _app(_FakeDetailUseCases uc, {List<ShortDramaSource> sources = const <ShortDramaSource>[]}) {
  return MultiProvider(
    providers: <Provider<Object>>[
      Provider<DetailPlaybackUseCases>.value(value: uc),
    ],
    child: MaterialApp(
      home: ShortDramaDetailPage(drama: drama, sources: sources),
    ),
  );
}

void main() {
  testWidgets('加载成功：渲染封面信息 / 简介 / 选集 / 操作行', (WidgetTester tester) async {
    final _FakeDetailUseCases uc =
        _FakeDetailUseCases(detail: detailWithEpisodes());
    await tester.pumpWidget(_app(uc, sources: <ShortDramaSource>[source()]));
    // 封面占位为持续动画的 ProgressView，避免 pumpAndSettle（永不收敛）。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('短剧详情'), findsOneWidget);
    expect(find.text('测试短剧'), findsWidgets);
    expect(find.text('剧情简介'), findsOneWidget);
    expect(find.text('剧情简介内容'), findsOneWidget);
    expect(find.text('选集 (2集)'), findsOneWidget);
    expect(find.text('立即播放'), findsOneWidget);
    expect(find.text('下载'), findsOneWidget);
    expect(uc.loadCalls, greaterThan(0));
  });

  testWidgets('剧集为空且无源：显示「暂无播放地址」', (WidgetTester tester) async {
    final _FakeDetailUseCases uc = _FakeDetailUseCases();
    await tester.pumpWidget(_app(uc));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('暂无播放地址'), findsOneWidget);
    expect(find.text('立即播放'), findsNothing);
  });

  testWidgets('下载：打开选集弹窗（头部计数 + 全选 + 空选禁用态文案）',
      (WidgetTester tester) async {
    final _FakeDetailUseCases uc =
        _FakeDetailUseCases(detail: detailWithEpisodes());
    await tester.pumpWidget(_app(uc, sources: <ShortDramaSource>[source()]));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.text('下载'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('选择下载集数'), findsOneWidget);
    expect(find.text('共 2 集，已选 0 集'), findsOneWidget);
    expect(find.text('全选'), findsOneWidget);
    expect(find.text('下载选中(0)'), findsOneWidget);
  });
}
