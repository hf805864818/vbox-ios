/// 日志查看页 widget 测试（批次 S-设4：模块分类筛选）。
///
/// 对齐 iOS `LogViewerView`：级别分段 + **模块分类**（`LogCategory.allCases`）
/// + 关键字，三者联动过滤内存环形缓冲。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/core/utils/logger.dart';
import 'package:vbox/presentation/widgets/log_viewer_page.dart';

void main() {
  setUp(() {
    AppLog.clear();
    AppLog.configure(enabled: true, minLevel: LogLevel.debug);
  });
  tearDown(AppLog.clear);

  testWidgets('S-设4：模块筛选栏按分类过滤日志条目', (WidgetTester tester) async {
    // 加宽视口，确保「模块分类」一整排 chip 均在可视区内可点。
    tester.view.physicalSize = const Size(1800, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 两条不同模块的日志（分类由 tag 推断）。
    AppLog.info('network', 'net-line');
    AppLog.info('music', 'music-line');

    await tester.pumpWidget(const MaterialApp(home: LogViewerPage()));
    await tester.pumpAndSettle();

    expect(find.text('net-line'), findsOneWidget);
    expect(find.text('music-line'), findsOneWidget);

    // 选中「网络」模块 → 仅网络条目可见。
    await tester.tap(find.widgetWithText(FilterChip, '网络'));
    await tester.pumpAndSettle();
    expect(find.text('net-line'), findsOneWidget);
    expect(find.text('music-line'), findsNothing);

    // 回到「全部模块」→ 两条均可见。
    await tester.tap(find.widgetWithText(FilterChip, '全部模块'));
    await tester.pumpAndSettle();
    expect(find.text('net-line'), findsOneWidget);
    expect(find.text('music-line'), findsOneWidget);
  });
}
