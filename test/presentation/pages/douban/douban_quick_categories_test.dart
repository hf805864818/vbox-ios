/// UI-A1：豆瓣首页快捷分类胶囊（对齐 iOS `CategoryTilesView`）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/douban/douban_models.dart';
import 'package:vbox/presentation/pages/douban/douban_quick_categories.dart';
import 'package:vbox/presentation/theme/theme.dart';

/// 胶囊行宿主。
Widget _host({String? activeType, required ValueChanged<DoubanQuickTile> onTap}) =>
    MaterialApp(
      theme: VboxTheme.build(skin: VboxSkin.light, brightness: Brightness.light),
      home: Scaffold(
        body: DoubanQuickCategories(activeType: activeType, onTileTap: onTap),
      ),
    );

void main() {
  group('DoubanQuickCategories', () {
    test('quickTiles 6 固定项 + 顺序对齐 iOS CategoryTilesView', () {
      // iOS DoubanHomeView.swift L380-L382：movie/tv/variety/top250/animation/hot。
      expect(
        DoubanCategory.quickTiles
            .map((DoubanQuickTile t) => t.category.type)
            .toList(),
        <String>['movie', 'tv', 'variety', 'top250', 'animation', 'hot'],
      );
      expect(
        DoubanCategory.quickTiles.map((DoubanQuickTile t) => t.name).toList(),
        <String>['电影', '剧集', '综艺', '榜单', '动漫', '热门'],
      );
      // 数据映射对齐 iOS fetchDoubanCategoryData 分支。
      expect(DoubanCategory.top250.collectionId, 'movie_top250');
      expect(DoubanCategory.hot.collectionId, 'movie_showing');
      // top250 / hot 不进入分类浏览页现有 5 分类。
      expect(
        DoubanCategory.all.map((DoubanCategory c) => c.type).toList(),
        <String>['movie', 'tv', 'variety', 'animation', 'documentary'],
      );
    });

    testWidgets('渲染 6 个胶囊（emoji + 名称）', (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(activeType: null, onTap: (_) {}),
      );
      expect(find.text('🎬'), findsOneWidget);
      expect(find.text('📺'), findsOneWidget);
      expect(find.text('🎭'), findsOneWidget);
      expect(find.text('🏆'), findsOneWidget);
      expect(find.text('🎨'), findsOneWidget);
      expect(find.text('🔥'), findsOneWidget);
      for (final String name in <String>['电影', '剧集', '综艺', '榜单', '动漫', '热门']) {
        expect(find.text(name), findsOneWidget);
      }
    });

    testWidgets('点击回调带回对应分类', (WidgetTester tester) async {
      DoubanQuickTile? picked;
      await tester.pumpWidget(
        _host(activeType: null, onTap: (DoubanQuickTile t) => picked = t),
      );
      await tester.tap(find.text('榜单'));
      expect(picked?.category.type, 'top250');
      await tester.tap(find.text('热门'));
      expect(picked?.category.type, 'hot');
    });

    testWidgets('选中态：activeType 匹配项白字高亮（对齐 iOS #34C759）',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(activeType: 'movie', onTap: (_) {}),
      );
      await tester.pumpAndSettle();

      Text title = tester.widget<Text>(find.text('电影'));
      expect(title.style?.color, Colors.white, reason: '选中项应为白字');

      title = tester.widget<Text>(find.text('剧集'));
      expect(title.style?.color, isNot(Colors.white), reason: '未选中项应为主题前景色');
    });
  });
}
