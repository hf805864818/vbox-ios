/// 表现层单测：级联图片（批次 B）。
///
/// 覆盖：第一候选失败自动切第二候选、全部失败走 errorBuilder、
/// 候选为空直接占位、候选集变化后从头重试。
///
/// 说明：测试环境（`flutter_test`）把 `dart:io` HttpClient 统一挡成 400，
/// 因此每个候选都会"加载失败"，正好用来验证级联顺序。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/presentation/widgets/cascading_image.dart';
import 'package:vbox/presentation/widgets/platform_async_image.dart';

/// 让图片加载失败 + 帧后切换跑完。
Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('第一候选失败后切到第二候选', (WidgetTester tester) async {
    await tester.pumpWidget(_host(const CascadingImage(
      urls: <String?>['https://img.invalid/1.jpg', 'https://img.invalid/2.jpg'],
      timeout: Duration(seconds: 1),
    )));

    // 首帧：第一个候选。
    expect(find.byKey(const ValueKey<String>('https://img.invalid/1.jpg')),
        findsOneWidget);

    await _settle(tester);

    expect(find.byKey(const ValueKey<String>('https://img.invalid/2.jpg')),
        findsOneWidget);
    expect(find.byKey(const ValueKey<String>('https://img.invalid/1.jpg')),
        findsNothing);
  });

  testWidgets('候选为空时直接显示占位，不发请求', (WidgetTester tester) async {
    await tester.pumpWidget(_host(const CascadingImage(
      urls: <String?>[null, '   '],
    )));
    await _settle(tester);

    expect(find.byType(PlatformAsyncImage), findsNothing);
    expect(find.byIcon(Icons.movie_outlined), findsOneWidget);
  });

  testWidgets('全部候选失败后走 errorBuilder', (WidgetTester tester) async {
    int errors = 0;
    await tester.pumpWidget(_host(CascadingImage(
      urls: const <String?>['https://img.invalid/a.jpg'],
      timeout: const Duration(seconds: 1),
      errorBuilder: (BuildContext ctx, Object error, StackTrace? stack) {
        errors++;
        return const Text('全部失败');
      },
    )));
    await _settle(tester);

    expect(errors, greaterThan(0));
    expect(find.text('全部失败'), findsOneWidget);
  });

  testWidgets('候选集变化后从头重试', (WidgetTester tester) async {
    await tester.pumpWidget(_host(const CascadingImage(
      urls: <String?>['https://img.invalid/1.jpg', 'https://img.invalid/2.jpg'],
      timeout: Duration(seconds: 1),
    )));
    await _settle(tester);
    expect(find.byKey(const ValueKey<String>('https://img.invalid/2.jpg')),
        findsOneWidget);

    // 换一组候选（模拟切到另一部片子）。
    await tester.pumpWidget(_host(const CascadingImage(
      urls: <String?>['https://img.invalid/9.jpg'],
      timeout: Duration(seconds: 1),
    )));
    await tester.pump();

    expect(find.byKey(const ValueKey<String>('https://img.invalid/9.jpg')),
        findsOneWidget);
  });
}
