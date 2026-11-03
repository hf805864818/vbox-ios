/// 节目单 Sheet 测试（批次 E · E-03）。
///
/// 覆盖：缺省空态（对齐 iOS 接口失效）+ 三档日期胶囊、注入数据后的节目列表、
/// 切换日期触发重新拉取。[fetchEpg] 注入，不触碰真实网络。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/live/live.dart';
import 'package:vbox/presentation/pages/live/epg_sheet.dart';

LiveChannel _channel() => const LiveChannel(
      id: 'sub_CCTV1_url0',
      name: 'CCTV-1',
      tid: 'News',
      channelId: 'http://stream/cctv1.m3u8',
      token: '',
      sources: <String>['http://stream/cctv1.m3u8'],
    );

Future<void> _pump(WidgetTester tester, {EpgFetchHandler? fetchEpg}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: EpgSheet(channel: _channel(), fetchEpg: fetchEpg),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('缺省（接口失效）展示空态与三档日期', (WidgetTester tester) async {
    await _pump(tester);

    expect(find.text('CCTV-1 节目单'), findsOneWidget);
    expect(find.text('今天'), findsOneWidget);
    expect(find.text('昨天'), findsOneWidget);
    expect(find.text('前天'), findsOneWidget);
    expect(find.text('暂无节目单'), findsOneWidget);
  });

  testWidgets('注入数据渲染时间 + 标题列表', (WidgetTester tester) async {
    await _pump(
      tester,
      fetchEpg: (LiveChannel channel, EpgDay day) async => const <EpgProgram>[
        EpgProgram(time: '00:17', title: '今日说法'),
        EpgProgram(time: '01:02', title: '新闻联播'),
      ],
    );

    expect(find.text('暂无节目单'), findsNothing);
    expect(find.text('00:17'), findsOneWidget);
    expect(find.text('今日说法'), findsOneWidget);
    expect(find.text('01:02'), findsOneWidget);
    expect(find.text('新闻联播'), findsOneWidget);
  });

  testWidgets('切换日期触发重新拉取', (WidgetTester tester) async {
    final List<EpgDay> requested = <EpgDay>[];
    await _pump(
      tester,
      fetchEpg: (LiveChannel channel, EpgDay day) async {
        requested.add(day);
        return const <EpgProgram>[];
      },
    );

    expect(requested, <EpgDay>[EpgDay.today]);

    await tester.tap(find.text('昨天'));
    await tester.pump();
    await tester.pump();

    expect(requested, <EpgDay>[EpgDay.today, EpgDay.yesterday]);
  });
}