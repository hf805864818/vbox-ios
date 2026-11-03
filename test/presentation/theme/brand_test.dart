/// 品牌资源单测（批次 A · A-13）。
///
/// 验收：字体渲染生效（品牌字体可加载、字标按 `VboxBrand` 渲染）；
/// assets 非空（字母图资源可解析）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/presentation/theme/brand.dart';
import 'package:vbox/presentation/theme/theme.dart';
import 'package:vbox/presentation/widgets/brand/brand_logo.dart';

void main() {
  group('VboxBrand 常量', () {
    test('字体族 / 字母图 / 字标齐备', () {
      expect(VboxBrand.fontFamily, 'VboxBrand');
      expect(VboxBrand.splashLogoAsset, 'assets/splash/vbox_letter.png');
      expect(VboxBrand.wordmark, 'vbox');
    });
  });

  group('assets 非空（A-13 验收）', () {
    test('字体资源存在且非空', () async {
      final ByteData bytes =
          await rootBundle.load('assets/fonts/VboxBrand-Bold.otf');
      expect(bytes.lengthInBytes, greaterThan(0));
    });

    test('启动页字母图存在且非空', () async {
      final ByteData bytes = await rootBundle.load(VboxBrand.splashLogoAsset);
      expect(bytes.lengthInBytes, greaterThan(0));
    });
  });

  group('字体渲染生效（A-13 验收）', () {
    testWidgets('VboxBrand 字体可加载并渲染字标', (WidgetTester tester) async {
      final ByteData bytes =
          await rootBundle.load('assets/fonts/VboxBrand-Bold.otf');
      final FontLoader loader = FontLoader(VboxBrand.fontFamily);
      loader.addFont(Future<ByteData>.value(bytes));
      await tester.runAsync(() => loader.load());

      await tester.pumpWidget(
        MaterialApp(
          theme: VboxTheme.build(
            skin: VboxSkin.light,
            brightness: Brightness.light,
          ),
          home: const Scaffold(
            body: Text(
              VboxBrand.wordmark,
              style: TextStyle(
                fontFamily: VboxBrand.fontFamily,
                fontSize: 24,
              ),
            ),
          ),
        ),
      );
      expect(find.text(VboxBrand.wordmark), findsOneWidget);
    });
  });

  group('BrandLogo 组件', () {
    testWidgets('渲染字母图 + 字标', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: VboxTheme.build(
            skin: VboxSkin.light,
            brightness: Brightness.light,
          ),
          home: const Scaffold(body: BrandLogo(size: 96)),
        ),
      );
      expect(find.byType(Image), findsOneWidget);
      expect(find.text(VboxBrand.wordmark), findsOneWidget);
    });

    testWidgets('showWordmark=false 仅字母图', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: VboxTheme.build(
            skin: VboxSkin.light,
            brightness: Brightness.light,
          ),
          home: const Scaffold(body: BrandLogo(size: 96, showWordmark: false)),
        ),
      );
      expect(find.byType(Image), findsOneWidget);
      expect(find.text(VboxBrand.wordmark), findsNothing);
    });
  });
}