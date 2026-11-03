/// 呈现层单测：香蕉秀短视频竖屏全屏播放器。
///
/// 对齐 iOS `YBoxBananaShortPlayerView`：进入即播放当前项，底部信息区展示
/// 作者 / 标题 / `当前/总数` / 只读进度条 / 倍速组；左上返回按钮。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/player/player.dart';
import 'package:vbox/domain/services/banana_xjsp_service.dart';
import 'package:vbox/platform/player/player_channel_bridge.dart';
import 'package:vbox/platform/player/player_controller.dart';
import 'package:vbox/platform/player/playback_route.dart';
import 'package:vbox/platform/spider/spider_http_bridge.dart';
import 'package:vbox/presentation/pages/welfare/banana_short_player_page.dart';

/// 假传输：命中关键字返回既定 JSON（未命中 → 404）。
class _FakeTransport implements SpiderHttpTransport {
  _FakeTransport(this.routes);

  final Map<String, String> routes;

  @override
  Future<SpiderTransportResponse> send(SpiderTransportRequest request) async {
    final String url = request.url.toString();
    for (final MapEntry<String, String> e in routes.entries) {
      if (url.contains(e.key)) {
        return SpiderTransportResponse(
          status: 200,
          headers: <String, String>{
            'content-type': 'application/json; charset=utf-8',
          },
          bodyBytes: utf8.encode(e.value),
        );
      }
    }
    return const SpiderTransportResponse(
      status: 404,
      headers: <String, String>{},
      bodyBytes: <int>[],
    );
  }
}

/// 空通道桥（不被真实调用）。
class _NoopBridge implements PlayerChannelBridge {
  @override
  Future<Object?> invoke(String method, [Object? arguments]) async => null;

  @override
  Stream<Map<String, Object?>> events() =>
      const Stream<Map<String, Object?>>.empty();

  @override
  Future<void> dispose() async {}
}

/// 假播放器控制器：记录倍速调用。
class _FakePlayerController extends PlayerController {
  _FakePlayerController()
      : super(
          bridge: _NoopBridge(),
          backendChain: const <PlayerBackend>[PlayerBackend.media3],
          selectInitialBackend: (_, PlaybackRoute route) => PlayerBackend.media3,
        );

  final List<double> speeds = <double>[];
  bool played = false;

  @override
  Future<void> open(PlayerSource source, {PlaybackRoute? route}) async {}

  @override
  Future<void> play() async => played = true;

  @override
  Future<void> pause() async {}

  @override
  Future<void> seekTo(int positionMs) async {}

  @override
  Future<void> setSpeed(double speed) async => speeds.add(speed);

  @override
  Future<void> setVolume(double volume) async {}
}

const String _categoriesPath = '/vod/listing-0-0-0-0-0-0-0-0-0-1';
const String _categoriesJson =
    '{"retcode":0,"data":{"categories":[{"cateid":"9","catename":"国产精品"}]}}';

/// 短视频列表（两行，含作者昵称）。
const String _miniJson = '{"retcode":0,"data":{"rows":['
    '{"vodrow":{"vodid":"mv1","title":"短视频一","coverpic":"https://img.m1.jpg",'
    '"duration":"00:15"},'
    '"user":{"nickname":"作者甲"}},'
    '{"vodrow":{"vodid":"mv2","title":"短视频二","coverpic":"https://img.m2.jpg"},'
    '"user":{"nickname":"作者乙"}}]}}';

BananaXjspFuliService _service(Map<String, String> routes) =>
    BananaXjspFuliService(
      bridge: SpiderHttpBridge(transport: _FakeTransport(routes)),
    );

Widget _host(BananaShortPlayerPage page) => MaterialApp(home: page);

/// 推进若干帧以完成异步加载（页面含常驻转圈动画，不能 pumpAndSettle）。
Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  testWidgets('进入即播放当前项：作者 / 标题 / 计数 / 倍速组可见',
      (WidgetTester tester) async {
    final BananaXjspFuliService service = _service(<String, String>{
      '/minivod/reqlist': _miniJson,
      '/minivod/reqplay/mv1':
          '{"retcode":0,"data":{"httpurl":"https://cdn.example.com/m1.m3u8"}}',
      _categoriesPath: _categoriesJson,
    });
    final _FakePlayerController player = _FakePlayerController();

    await tester.pumpWidget(_host(
      BananaShortPlayerPage(service: service, controller: player),
    ));
    await _settle(tester);

    // 倍速组（对齐 iOS `[1.0,1.25,1.5,2.0]` + `%.2fx`）。
    expect(find.text('1.00x'), findsOneWidget);
    expect(find.text('1.25x'), findsOneWidget);
    expect(find.text('1.50x'), findsOneWidget);
    expect(find.text('2.00x'), findsOneWidget);
    // 底部信息区：作者 + 标题 + 当前/总数（2 条 < 10 → 无 `+`）。
    expect(find.text('作者甲'), findsOneWidget);
    expect(find.text('短视频一'), findsOneWidget);
    expect(find.text('1/2'), findsOneWidget);
    // 左上返回按钮。
    expect(find.byIcon(Icons.chevron_left), findsOneWidget);
    // 已起播（对齐 iOS 进入即播放）。
    expect(player.played, isTrue);
  });

  testWidgets('点击倍速 → 设置播放速率', (WidgetTester tester) async {
    final BananaXjspFuliService service = _service(<String, String>{
      '/minivod/reqlist': _miniJson,
      '/minivod/reqplay/mv1':
          '{"retcode":0,"data":{"httpurl":"https://cdn.example.com/m1.m3u8"}}',
      _categoriesPath: _categoriesJson,
    });
    final _FakePlayerController player = _FakePlayerController();

    await tester.pumpWidget(_host(
      BananaShortPlayerPage(service: service, controller: player),
    ));
    await _settle(tester);

    await tester.tap(find.text('1.50x'));
    await tester.pump();

    expect(player.speeds.last, 1.5);
  });
}
