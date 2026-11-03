/// 直播控制器单测：源持久化 / 订阅源拉取解析 / 本地频道 / M3U 导出。
///
/// 无真实 IO：注入 MockClient（`package:http/testing`），持久化走
/// `SharedPreferences.setMockInitialValues`。
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vbox/core/network/http_client.dart';
import 'package:vbox/data/datasources/local/prefs_manager.dart';
import 'package:vbox/domain/entities/live/live.dart';
import 'package:vbox/presentation/pages/live/live_tv_controller.dart';

const String _m3uFixture = '#EXTM3U\n'
    '#EXTINF:-1 tvg-logo="http://logo/1.png" group-title="News",CCTV-1\n'
    'http://stream/cctv1.m3u8\n'
    '#EXTINF:-1 group-title="News",CCTV-2\n'
    'http://stream/cctv2.m3u8\n'
    '#EXTINF:-1 group-title="Sports",CCTV-5\n'
    'http://stream/cctv5.m3u8\n';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final PrefsManager pm = PrefsManager.instance;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    await pm.init();
  });

  setUp(() async {
    await pm.clearAll();
  });

  LiveTvController buildController({
    Future<http.Response> Function(http.Request)? handler,
  }) {
    final MockClient client = MockClient(
      handler ?? (http.Request _) async => http.Response('', 404),
    );
    return LiveTvController(client: HttpClient(inner: client));
  }

  group('初始化', () {
    test('默认源为 defaultM3U，分类/自定义源为空', () async {
      final LiveTvController c = buildController();
      await c.init();
      expect(c.currentSource.id, LiveSourceType.defaultM3U.id);
      expect(c.customSources, isEmpty);
      expect(c.categories, isEmpty);
      expect(c.subscribeChannels, isEmpty);
      expect(c.isInitialized, isTrue);
    });
  });

  group('自定义源', () {
    test('addCustomSource 加入 availableSources', () async {
      final LiveTvController c = buildController();
      await c.init();
      await c.addCustomSource('测试源', 'http://example.com/tv.m3u');
      expect(c.customSources.length, 1);
      expect(c.availableSources.length, 3); // 默认2 + 自定义1
      expect(c.availableSources.last.name, '测试源');
    });

    test('removeCustomSourceAt 删除并持久化', () async {
      final LiveTvController c = buildController();
      await c.init();
      await c.addCustomSource('测试源', 'http://example.com/tv.m3u');
      await c.removeCustomSourceAt(0);
      expect(c.customSources, isEmpty);
    });

    test('自定义源跨实例持久化', () async {
      final LiveTvController a = buildController();
      await a.init();
      await a.addCustomSource('持久源', 'http://example.com/p.m3u');

      final LiveTvController b = buildController();
      await b.init();
      expect(b.customSources.length, 1);
      expect(b.customSources.first.name, '持久源');
    });
  });

  group('订阅源拉取与解析', () {
    test('fetchSubscribeChannels：M3U 解析出频道与分类', () async {
      final LiveTvController c = buildController(
        handler: (http.Request _) async => http.Response(_m3uFixture, 200),
      );
      await c.init();
      await c.fetchSubscribeChannels('http://example.com/tv.m3u');

      expect(c.lastError, isNull);
      expect(c.categories.length, 2);
      expect(c.categories.map((e) => e.name), containsAll(<String>['News', 'Sports']));
      expect(c.subscribeChannels.length, 3);

      final List<LiveChannel> news = c.channelsForGroup('News');
      expect(news.length, 2);
      expect(news.first.name, 'CCTV-1');
      expect(news.first.logo, 'http://logo/1.png');
    });

    test('fetchSubscribeChannels：HTTP 非 2xx 记录错误', () async {
      final LiveTvController c = buildController(
        handler: (http.Request _) async => http.Response('', 500),
      );
      await c.init();
      await c.fetchSubscribeChannels('http://example.com/fail.m3u');
      expect(c.lastError, isNotNull);
      expect(c.subscribeChannels, isEmpty);
    });

    test('TXT 源自动判定（非 EXTM3U 前缀）', () async {
      final LiveTvController c = buildController(
        handler: (http.Request _) async =>
            http.Response.bytes(utf8.encode('央视,CCTV-1,http://a.m3u8\n'), 200),
      );
      await c.init();
      await c.fetchSubscribeChannels('http://example.com/tv.txt');
      expect(c.subscribeChannels.length, 1);
      expect(c.subscribeChannels.first.group, '央视');
    });
  });

  group('本地频道', () {
    test('addLocalChannels + switchSource(local://) 载入本地频道', () async {
      final LiveTvController c = buildController();
      await c.init();
      await c.addLocalChannels('我的本地源', const <SubscribeChannel>[
        SubscribeChannel(name: '台A', url: 'http://a', group: '组'),
      ]);

      final List<LiveSourceType> locals = c.availableSources
          .where((LiveSourceType s) => s.url == 'local://我的本地源')
          .toList();
      expect(locals, hasLength(1));

      await c.switchSource(locals.first);
      expect(c.categories.length, 1);
      expect(c.categories.first.name, '组');
      expect(c.channelsForGroup('组').first.name, '台A');
    });
  });

  group('M3U 导出', () {
    test('exportM3U 输出含 EXTM3U 头与分组标记', () {
      final LiveTvController c = buildController();
      final String out = c.exportM3U(const <SubscribeChannel>[
        SubscribeChannel(name: 'CCTV-1', url: 'http://a', group: '央视'),
      ]);
      expect(out, startsWith('#EXTM3U\n'));
      expect(out, contains('group-title="央视"'));
      expect(out, contains('CCTV-1'));
      expect(out, contains('http://a'));
    });
  });
}