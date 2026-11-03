/// 呈现层单测：福利漫画 / 套图长卷阅读器（UI-C1 · 漫画阅读器）。
///
/// 对齐 iOS `ComicDirectReaderView`（L185-L273）+ `MangaReaderView`（L21-L315）：
///   · 进入即加载详情 → 取首集 `images` → 呈现长卷（标题 + 页码 + 进度）；
///   · 无图 / 失败 → 明确错误态「未解析到套图图片」+ 重试；
///   · 有效 Referer 回退当前域名。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/welfare/fuli_models.dart';
import 'package:vbox/domain/services/fuli_base_service.dart';
import 'package:vbox/presentation/pages/welfare/welfare_comic_reader_page.dart';

/// 测试替身：固定返回详情的漫画服务。
class _FakeComicService extends FuliBaseService {
  _FakeComicService({
    required this.detail,
    this.referer,
  }) : super(
          platformKey: 'comic-1',
          platformName: '漫画平台',
          defaultHosts: const <String>['https://comic.example.com'],
        );

  final FuliDetail detail;
  final String? referer;

  @override
  FuliContentCategory get contentCategory => FuliContentCategory.comic;

  @override
  String? get imageReferer => referer;

  @override
  String get currentHost => 'https://comic.example.com';

  @override
  bool get isHostReady => true;

  @override
  Future<FuliDetail> fetchDetail(String vodId) async => detail;

  @override
  void reprobe() {}

  @override
  void resetDomain() {}
}

FuliDetail _detail(List<String> images) => FuliDetail(
      vodId: 'v1',
      vodName: '套图甲',
      vodPic: 'https://comic.example.com/cover.jpg',
      vodContent: null,
      playFrom: '',
      episodes: <FuliEpisode>[
        FuliEpisode(name: '第 1 话', url: '', images: images),
      ],
    );

const FuliVideo _video = FuliVideo(
  vodId: 'v1',
  vodName: '套图甲',
  vodPic: 'https://comic.example.com/cover.jpg',
);

Widget _page(FuliBaseService service) => MaterialApp(
      home: WelfareComicReaderPage(service: service, video: _video),
    );

void main() {
  testWidgets('有图片 → 呈现长卷阅读器（标题 + 页码 + 进度）', (WidgetTester tester) async {
    final FuliBaseService service = _FakeComicService(
      detail: _detail(<String>[
        'https://img.example.com/1.jpg',
        'https://img.example.com/2.jpg',
        'https://img.example.com/3.jpg',
      ]),
    );
    await tester.pumpWidget(_page(service));
    await tester.pumpAndSettle();

    expect(find.text('套图甲'), findsOneWidget);
    expect(find.textContaining('共 3 张'), findsOneWidget);
    // 无错误态。
    expect(find.text('未解析到套图图片'), findsNothing);
  });

  testWidgets('无图片 → 错误态「未解析到套图图片」+ 重试 + 返回', (WidgetTester tester) async {
    final FuliBaseService service =
        _FakeComicService(detail: _detail(const <String>[]));
    await tester.pumpWidget(_page(service));
    await tester.pumpAndSettle();

    expect(find.text('未解析到套图图片'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('返回'), findsOneWidget);
  });

  testWidgets('无 imageReferer 时有效 Referer 回退当前域名（不抛异常）',
      (WidgetTester tester) async {
    final FuliBaseService service = _FakeComicService(
      referer: null,
      detail: _detail(<String>['https://img.example.com/1.jpg']),
    );
    await tester.pumpWidget(_page(service));
    await tester.pumpAndSettle();

    expect(find.text('套图甲'), findsOneWidget);
    expect(find.textContaining('共 1 张'), findsOneWidget);
  });
}