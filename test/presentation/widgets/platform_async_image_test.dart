/// 图片加载组件单测（批次 A · A-10）。
///
/// 验收：缓存（Flutter 内建 imageCache）/ 占位 / 失败态可用；平台封面分支
/// [PlatformAsyncImage.coverFor] URL 归一。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/presentation/theme/theme.dart';
import 'package:vbox/presentation/widgets/platform_async_image.dart';
import 'package:vbox/presentation/widgets/vbox/vbox.dart';

Widget _host(Widget child) => MaterialApp(
      theme: VboxTheme.build(skin: VboxSkin.light, brightness: Brightness.light),
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  group('coverFor（平台封面分支）', () {
    test('null / 空白 → null（走占位态，不发请求）', () {
      expect(PlatformAsyncImage.coverFor(null), isNull);
      expect(PlatformAsyncImage.coverFor(''), isNull);
      expect(PlatformAsyncImage.coverFor('   '), isNull);
    });

    test('http:// 升迁 https://（防混合内容拦截）', () {
      expect(
        PlatformAsyncImage.coverFor('http://a.com/x.png'),
        'https://a.com/x.png',
      );
      expect(
        PlatformAsyncImage.coverFor('  http://a.com/x.png  '),
        'https://a.com/x.png',
      );
    });

    test('https / 其他协议原样透传', () {
      expect(
        PlatformAsyncImage.coverFor('https://a.com/x.png'),
        'https://a.com/x.png',
      );
      expect(
        PlatformAsyncImage.coverFor('data:image/png;base64,AAA'),
        'data:image/png;base64,AAA',
      );
    });
  });

  group('parseHeaderSuffix（@key=value 后缀，对齐 iOS）', () {
    test('无后缀原样透传', () {
      final ParsedImageUrl r =
          PlatformAsyncImage.parseHeaderSuffix('https://a.com/x.png');
      expect(r.url, 'https://a.com/x.png');
      expect(r.headers, isEmpty);
    });

    test('拆分 UA / Referer 后缀', () {
      final ParsedImageUrl r = PlatformAsyncImage.parseHeaderSuffix(
        'https://a.com/x.png@User-Agent=Mozilla@Referer=https://r.com/',
      );
      expect(r.url, 'https://a.com/x.png');
      expect(r.headers['User-Agent'], 'Mozilla');
      expect(r.headers['Referer'], 'https://r.com/');
    });

    test('SSL 绕过标记单独解析', () {
      final ParsedImageUrl r = PlatformAsyncImage.parseHeaderSuffix(
        'https://a.com/x.png@X-VBox-SSL-Bypass=1',
      );
      expect(r.url, 'https://a.com/x.png');
      expect(r.headers['X-VBox-SSL-Bypass'], '1');
    });
  });

  group('sourceCover（防盗链工厂，对齐 iOS）', () {
    test('referer 为空 → 不附加任何后缀', () {
      final PlatformAsyncImage img =
          PlatformAsyncImage.sourceCover('https://a.com/x.png');
      expect(img.url, 'https://a.com/x.png');
    });

    test('注入 UA / Referer / SSL 绕过后缀', () {
      final PlatformAsyncImage img = PlatformAsyncImage.sourceCover(
        'https://a.com/x.png',
        referer: 'https://r.com',
        sslBypass: true,
      );
      final ParsedImageUrl parsed =
          PlatformAsyncImage.parseHeaderSuffix(img.url!);
      expect(parsed.url, 'https://a.com/x.png');
      expect(parsed.headers['Referer'], 'https://r.com/');
      expect(parsed.headers['User-Agent'], kPlatformImageDefaultUA);
      expect(parsed.headers['X-VBox-SSL-Bypass'], '1');
    });
  });

  group('doubanHeadersFor（豆瓣/TMDB 封面防盗链，对齐 iOS DoubanImageProxyServer）', () {
    test('命中 doubanio.com → 注入 Referer / UA / Accept', () {
      final Map<String, String> headers = PlatformAsyncImage.doubanHeadersFor(
        'https://img1.doubanio.com/view/photo/s_ratio_poster/public/p1.jpg',
      );
      expect(headers['Referer'], 'https://movie.douban.com/');
      expect(headers['User-Agent'], contains('AppleWebKit'));
      expect(headers['Accept'], contains('image/webp'));
    });

    test('命中 douban.com / tmdb 主机同样注入', () {
      expect(
        PlatformAsyncImage.doubanHeadersFor('https://img9.douban.com/pic/x.jpg'),
        containsPair('Referer', 'https://movie.douban.com/'),
      );
      expect(
        PlatformAsyncImage.doubanHeadersFor('https://image.tmdb.org/t/p/w500/a.jpg'),
        containsPair('Referer', 'https://movie.douban.com/'),
      );
      expect(
        PlatformAsyncImage.doubanHeadersFor('https://media.themoviedb.org/t/p/w500/b.jpg'),
        isNotEmpty,
      );
    });

    test('非豆瓣主机 → 空表（不影响其他图片）', () {
      expect(PlatformAsyncImage.doubanHeadersFor('https://a.com/x.png'), isEmpty);
      expect(PlatformAsyncImage.doubanHeadersFor('data:image/png;base64,AAA'), isEmpty);
      expect(PlatformAsyncImage.doubanHeadersFor('not-a-url'), isEmpty);
    });
  });

  group('data: 内嵌图（对齐 iOS loadDataImage）', () {
    testWidgets('data:image 前缀 → Image.memory 渲染', (WidgetTester tester) async {
      // 1×1 透明 PNG。
      const String b64 =
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
      await tester.pumpWidget(
        _host(
          const SizedBox(
            width: 120,
            height: 180,
            child: PlatformAsyncImage(url: 'data:image/png;base64,$b64'),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(Image), findsOneWidget);
      final Image image = tester.widget<Image>(find.byType(Image));
      expect(image.image, isA<MemoryImage>());
    });

    testWidgets('非法 base64 → 回退占位', (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(
          const SizedBox(
            width: 120,
            height: 180,
            child: PlatformAsyncImage(url: 'data:image/png;base64,@@@'),
          ),
        ),
      );
      expect(find.byType(Image), findsNothing);
      expect(find.byIcon(Icons.movie_outlined), findsOneWidget);
    });
  });

  group('占位 / 失败态', () {
    testWidgets('URL 为 null：直接占位态（无 Image 节点）', (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(
          const SizedBox(
            width: 120,
            height: 180,
            child: PlatformAsyncImage(url: null),
          ),
        ),
      );
      expect(find.byType(Image), findsNothing);
      expect(find.byIcon(Icons.movie_outlined), findsOneWidget);
    });

    testWidgets('URL 为空串：占位态', (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(
          const SizedBox(
            width: 120,
            height: 180,
            child: PlatformAsyncImage(url: ''),
          ),
        ),
      );
      expect(find.byType(Image), findsNothing);
      expect(find.byIcon(Icons.movie_outlined), findsOneWidget);
    });

    testWidgets('网络加载失败：失败态兜底为占位', (WidgetTester tester) async {
      // flutter_test 默认拦截真实 HTTP（返回 400）→ errorBuilder 兜底。
      await tester.pumpWidget(
        _host(
          const SizedBox(
            width: 120,
            height: 180,
            child: PlatformAsyncImage(url: 'https://example.com/nope.png'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.movie_outlined), findsOneWidget);
    });

    testWidgets('自定义占位组件生效', (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(
          const SizedBox(
            width: 120,
            height: 180,
            child: PlatformAsyncImage(
              url: null,
              placeholder: Text('自定义占位'),
            ),
          ),
        ),
      );
      expect(find.text('自定义占位'), findsOneWidget);
      expect(find.byIcon(Icons.movie_outlined), findsNothing);
    });
  });

  group('字节拉取分支（豆瓣防盗链，修复 418）', () {
    testWidgets('豆瓣封面不经 Image.network（改用 HttpClient+set 取字节）',
        (WidgetTester tester) async {
      // `Image.network(headers:)` 用 `HttpHeaders.add` 追加 User-Agent，与 Dart
      // 内建默认 UA 形成双值，豆瓣 CDN 返回 418。修复后豆瓣封面走字节拉取分支，
      // 故不会出现 `Image.network` 生成的 `Image` 节点（测试环境网络被拦截 →
      // 落到占位兜底）。
      await tester.pumpWidget(
        _host(
          const SizedBox(
            width: 120,
            height: 180,
            child: PlatformAsyncImage(
              url: 'https://img1.doubanio.com/view/photo/s_ratio_poster/public/p1.jpg',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsNothing);
      expect(find.byIcon(Icons.movie_outlined), findsOneWidget);
    });
  });

  group('海报卡收敛（A-10 接线）', () {
    testWidgets('VboxPosterCard 占位态复用 PlatformAsyncImage', (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(
          const SizedBox(
            width: 120,
            child: VboxPosterCard(title: '无封面'),
          ),
        ),
      );
      expect(find.byType(PlatformAsyncImage), findsOneWidget);
      expect(find.byIcon(Icons.movie_outlined), findsOneWidget);
      expect(find.text('无封面'), findsOneWidget);
    });
  });
}