/// TG 频道管理页 widget 测试（批次 G · G-04）。
///
/// 对齐 iOS `vbox/Views/TGChannelListView.swift`：
///   · 空态「暂无自定义频道」；自定义频道分组标题「自定义频道（N 个）」；
///   · 快捷添加常用频道（2 列网格，已添加项禁用）；
///   · 添加 Sheet（频道名称 + 频道 ID + 校验）；
///   · 编辑态删除频道。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/data/datasources/local/tg_search_config_store.dart';
import 'package:vbox/presentation/pages/settings/tg_channel_list_page.dart';

/// 内存态存储（prefs 为 null → 不落盘，适合 widget 测试）。
TGSearchConfigStore _store() => TGSearchConfigStore();

Widget _host(TGSearchConfigStore store) =>
    MaterialApp(home: TGChannelListPage(store: store));

void main() {
  testWidgets('空态：标题 + 「暂无自定义频道」+ 快捷添加分组（10 个预置）',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host(_store()));
    await tester.pumpAndSettle();

    expect(find.text('TG频道管理'), findsOneWidget);
    expect(find.text('暂无自定义频道'), findsOneWidget);
    expect(find.text('快捷添加常用频道'), findsOneWidget);
    expect(find.text('UC夸克资源'), findsOneWidget);
    expect(find.text('迅雷云盘'), findsOneWidget);
  });

  testWidgets('快捷添加：点预置频道 → 入列（分组标题 + 名称 + ID）',
      (WidgetTester tester) async {
    final TGSearchConfigStore store = _store();
    await tester.pumpWidget(_host(store));
    await tester.pumpAndSettle();

    await tester.tap(find.text('UC夸克资源'));
    await tester.pumpAndSettle();

    expect(store.channels, hasLength(1));
    expect(store.channels.single.channelId, 'ucquark');
    expect(find.text('自定义频道（1 个）'), findsOneWidget);
    expect(find.text('ucquark'), findsOneWidget);
    // 空态消失。
    expect(find.text('暂无自定义频道'), findsNothing);
  });

  testWidgets('快捷添加：已添加项禁用（不重复入列）', (WidgetTester tester) async {
    final TGSearchConfigStore store = _store();
    store.addChannel(name: 'UC夸克资源', channelId: 'ucquark');
    await tester.pumpWidget(_host(store));
    await tester.pumpAndSettle();

    // 网格内的预置按钮（禁用 → 点击不新增）。
    await tester.tap(
      find.descendant(
        of: find.byType(GridView),
        matching: find.text('UC夸克资源'),
      ),
    );
    await tester.pumpAndSettle();
    expect(store.channels, hasLength(1));
  });

  testWidgets('添加 Sheet：输入名称/ID → 添加 → 入列', (WidgetTester tester) async {
    final TGSearchConfigStore store = _store();
    await tester.pumpWidget(_host(store));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    expect(find.text('添加频道'), findsOneWidget);
    expect(find.text('频道 ID 是 t.me/s/ 后面的名称，不含 @ 符号'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, '如：UC夸克资源'),
      '自定义频道',
    );
    await tester.enterText(find.widgetWithText(TextField, '如：ucquark'), 'mychannel');
    await tester.pump();
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();

    expect(store.channels.single.name, '自定义频道');
    expect(store.channels.single.channelId, 'mychannel');
    expect(find.text('mychannel'), findsOneWidget);
  });

  testWidgets('添加 Sheet：频道 ID 为空 → 「添加」禁用', (WidgetTester tester) async {
    await tester.pumpWidget(_host(_store()));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();

    TextButton addButton() =>
        tester.widget<TextButton>(find.widgetWithText(TextButton, '添加'));
    expect(addButton().onPressed, isNull);

    await tester.enterText(find.widgetWithText(TextField, '如：ucquark'), 'x');
    await tester.pump();
    expect(addButton().onPressed, isNotNull);
  });

  testWidgets('编辑态：删除按钮移除频道 → 回到空态', (WidgetTester tester) async {
    final TGSearchConfigStore store = _store();
    store.addChannel(name: 'A', channelId: 'a');
    await tester.pumpWidget(_host(store));
    await tester.pumpAndSettle();

    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    expect(find.text('完成'), findsOneWidget);
    expect(find.byIcon(Icons.remove_circle), findsOneWidget);

    await tester.tap(find.byIcon(Icons.remove_circle));
    await tester.pumpAndSettle();

    expect(store.channels, isEmpty);
    expect(find.text('暂无自定义频道'), findsOneWidget);
  });

  testWidgets('无频道时「编辑」禁用', (WidgetTester tester) async {
    await tester.pumpWidget(_host(_store()));
    await tester.pumpAndSettle();

    final TextButton editButton =
        tester.widget<TextButton>(find.widgetWithText(TextButton, '编辑'));
    expect(editButton.onPressed, isNull);
  });
}