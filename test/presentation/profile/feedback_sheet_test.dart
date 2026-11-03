/// 表现层单测：Bug 反馈弹窗（批次 G · G-09）。
///
/// 唯一真相源：iOS `ProfileView.swift` L669-L780（`feedbackSheet`）。
///   · 渲染（标题 / 标签 / placeholder / 禁用提交按钮）；
///   · 空标题禁用 → 可输入后提交 → 成功态；
///   · 提交失败 → 错误提示；
///   · 提交中 → 「提交中...」+ 禁用；
///   · 宫格入口 `showVboxFeedbackSheet` 弹出弹窗。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:vbox/data/datasources/remote/feedback_service.dart';
import 'package:vbox/presentation/pages/profile/feedback_sheet.dart';

/// 假传输：记录调用，可配置失败 / 挂起。
class _FakeTransport implements FeedbackSubmitTransport {
  String? lastTitle;
  String? lastBody;
  Object? error;
  Completer<void>? gate;

  @override
  Future<void> submit({required String title, required String body}) async {
    final Completer<void>? g = gate;
    if (g != null) await g.future;
    lastTitle = title;
    lastBody = body;
    final Object? e = error;
    if (e != null) throw e;
  }
}

/// 弹窗宿主（直接承载 [FeedbackSheet] 内容）。
Widget _host(FeedbackService service) {
  return MaterialApp(
    home: Scaffold(
      body: ChangeNotifierProvider<FeedbackService>.value(
        value: service,
        child: const FeedbackSheet(),
      ),
    ),
  );
}

void main() {
  testWidgets('渲染：标题 / 标签 / placeholder / 空标题禁用提交按钮', (WidgetTester tester) async {
    final _FakeTransport transport = _FakeTransport();
    await tester.pumpWidget(_host(FeedbackService(transport: transport)));

    expect(find.text('Bug 反馈'), findsOneWidget);
    expect(find.text('问题标题'), findsOneWidget);
    expect(find.text('详细描述'), findsOneWidget);
    expect(find.text('简要描述问题'), findsOneWidget);
    expect(find.text('请详细描述问题发生的场景、操作步骤等...'), findsOneWidget);
    expect(find.text('提交反馈'), findsOneWidget);

    // 空标题 → 点击不触发提交。
    await tester.tap(find.text('提交反馈'));
    await tester.pump();
    expect(transport.lastTitle, isNull);
    expect(find.text('提交反馈'), findsOneWidget);
  });

  testWidgets('输入标题 → 提交成功 → 成功态（绿勾 + 感谢文案 + 关闭）', (WidgetTester tester) async {
    final _FakeTransport transport = _FakeTransport();
    await tester.pumpWidget(_host(FeedbackService(transport: transport)));

    await tester.enterText(find.byType(TextField).first, '播放器黑屏');
    await tester.pump();
    await tester.tap(find.text('提交反馈'));
    await tester.pumpAndSettle();

    expect(transport.lastTitle, '播放器黑屏');
    expect(transport.lastBody, isNotNull);
    expect(transport.lastBody, contains('**设备信息**'));
    expect(find.text('提交成功'), findsOneWidget);
    expect(find.text('感谢你的反馈！'), findsOneWidget);
    expect(find.text('关闭'), findsOneWidget);
  });

  testWidgets('提交失败 → 表单保留 + 红色错误提示', (WidgetTester tester) async {
    final _FakeTransport transport = _FakeTransport()
      ..error = const FeedbackSubmitException('提交失败 (HTTP 422)');
    await tester.pumpWidget(_host(FeedbackService(transport: transport)));

    await tester.enterText(find.byType(TextField).first, '播放器黑屏');
    await tester.pump();
    await tester.tap(find.text('提交反馈'));
    await tester.pumpAndSettle();

    expect(find.text('提交失败 (HTTP 422)'), findsOneWidget);
    expect(find.text('提交反馈'), findsOneWidget);
    expect(find.text('提交成功'), findsNothing);
  });

  testWidgets('提交中：显示「提交中...」并禁用（防重复提交）', (WidgetTester tester) async {
    final Completer<void> gate = Completer<void>();
    final _FakeTransport transport = _FakeTransport()..gate = gate;
    await tester.pumpWidget(_host(FeedbackService(transport: transport)));

    await tester.enterText(find.byType(TextField).first, '播放器黑屏');
    await tester.pump();
    await tester.tap(find.text('提交反馈'));
    await tester.pump();

    expect(find.text('提交中...'), findsOneWidget);
    expect(find.text('提交反馈'), findsNothing);

    gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('提交成功'), findsOneWidget);
  });

  testWidgets('宫格入口 showVboxFeedbackSheet：弹出弹窗（含标题行）', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => Center(
              child: TextButton(
                onPressed: () => showVboxFeedbackSheet(
                  context,
                  service: FeedbackService(
                    transport: _FakeTransport(),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Bug 反馈'), findsOneWidget);
    expect(find.text('问题标题'), findsOneWidget);
    expect(find.text('提交反馈'), findsOneWidget);
  });
}
