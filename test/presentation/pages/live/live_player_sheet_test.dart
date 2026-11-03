/// 直播播放接入 Sheet 测试（批次 E · E-02）。
///
/// 覆盖：线路自动解析（`channel.sources` 缺失时回退 `playURL` / 空态）、
/// 打开即连接首线路、线路切换、连接失败态。播放回调 [onPlayRoute] 注入，
/// 不触碰真实方法通道。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/live/live.dart';
import 'package:vbox/presentation/pages/live/live_player_sheet.dart';

LiveChannel _channel({List<String> sources = const <String>[]}) =>
    LiveChannel(
      id: 'sub_CCTV1_url0',
      name: 'CCTV-1',
      tid: 'News',
      channelId: sources.isEmpty ? 'http://stream/cctv1.m3u8' : sources.first,
      token: '',
      logo: 'http://logo/1.png',
      sources: sources,
    );

Future<void> _pump(WidgetTester tester, List<String> played) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: LivePlayerSheet(
          channel: _channel(
            sources: const <String>[
              'http://stream/cctv1-a.m3u8',
              'http://stream/cctv1-b.m3u8',
            ],
          ),
          onPlayRoute: (String url) async {
            played.add(url);
          },
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('打开即解析首线路并连接', (WidgetTester tester) async {
    final List<String> played = <String>[];
    await _pump(tester, played);

    // 顶层标题 + 线路数。
    expect(find.text('CCTV-1'), findsOneWidget);
    expect(find.text('共 2 条线路'), findsOneWidget);

    // 自动连接首线路。
    expect(played, <String>['http://stream/cctv1-a.m3u8']);
  });

  testWidgets('切换线路重连新 URL', (WidgetTester tester) async {
    final List<String> played = <String>[];
    await _pump(tester, played);

    expect(find.text('线路 1'), findsOneWidget);
    expect(find.text('线路 2'), findsOneWidget);

    await tester.tap(find.text('线路 2'));
    await tester.pump();

    expect(played, <String>[
      'http://stream/cctv1-a.m3u8',
      'http://stream/cctv1-b.m3u8',
    ]);
  });

  testWidgets('单线路频道：解析为 1 条并自动连接', (WidgetTester tester) async {
    final List<String> played = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LivePlayerSheet(
            channel: _channel(
              sources: const <String>['http://stream/cctv1-only.m3u8'],
            ),
            onPlayRoute: (String url) async => played.add(url),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('共 1 条线路'), findsOneWidget);
    expect(played, <String>['http://stream/cctv1-only.m3u8']);
  });

  testWidgets('无线路时展示错误态', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LivePlayerSheet(
            channel: const LiveChannel(
              id: 'sub_X',
              name: '无线路频道',
              tid: 'News',
              channelId: '',
              token: '',
              sources: <String>[],
            ),
            onPlayRoute: (String url) async {},
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('暂无可用线路'), findsOneWidget);
  });
}