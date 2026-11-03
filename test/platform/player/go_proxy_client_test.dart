/// C-10 Go 代理绑定单测：启动/备用端口/降级直链/夸克路径标记/桥协议。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/platform/player/go_proxy_client.dart';

/// 内存假桥：记录调用、可注入按方法返回。
class FakeGoProxyBridge implements GoProxyBridge {
  final List<(String, Map<String, Object?>?)> calls =
      <(String, Map<String, Object?>?)>[];

  String Function(String method, Map<String, Object?>? arguments)? onInvoke;

  @override
  Future<String> invoke(String method, [Map<String, Object?>? arguments]) async {
    calls.add((method, arguments));
    final String Function(String, Map<String, Object?>?)? handler = onInvoke;
    if (handler != null) return handler(method, arguments);
    return 'ok';
  }
}

void main() {
  group('NoopGoProxyClient', () {
    test('降级直链语义', () async {
      const NoopGoProxyClient c = NoopGoProxyClient();
      expect(c.isRunning, isFalse);
      expect(await c.start(), startsWith('error:'));
      expect(
        await c.registerStream(
          upstreamUrl: 'http://up/1.m3u8',
          headers: const <String, String>{},
        ),
        'http://up/1.m3u8',
      );
      expect(
        await c.registerQuarkStream(
          upstreamUrl: 'http://up/2.m3u8',
          cookie: 'c=1',
        ),
        'http://up/2.m3u8',
      );
      expect(await c.status(), 'stopped');
      await c.stop();
      await c.clearCache();
    });
  });

  group('MethodChannelGoProxyClient', () {
    test('start 成功 → isRunning + 端口透传', () async {
      final FakeGoProxyBridge bridge = FakeGoProxyBridge();
      final MethodChannelGoProxyClient c =
          MethodChannelGoProxyClient(bridge: bridge);
      final String result = await c.start(port: 10078);
      expect(result, startsWith('ok'));
      expect(c.isRunning, isTrue);
      expect(bridge.calls.first.$1, 'start');
      expect(bridge.calls.first.$2?['port'], 10078);
    });

    test('start 失败 → 遍历备用端口', () async {
      final FakeGoProxyBridge bridge = FakeGoProxyBridge();
      bridge.onInvoke = (String method, Map<String, Object?>? args) {
        if (method == 'start') {
          final int port = (args?['port'] as num).toInt();
          return port == 18080 ? 'ok:18080' : 'error:port busy';
        }
        return 'ok';
      };
      final MethodChannelGoProxyClient c =
          MethodChannelGoProxyClient(bridge: bridge);
      final String result = await c.start();
      expect(result, 'ok:18080');
      expect(c.isRunning, isTrue);
      // 调用过备用端口
      expect(
        bridge.calls.map(((String, Map<String, Object?>?) call) => call.$2?['port']).toList(),
        containsAll(<Object?>[10079, 18080]),
      );
    });

    test('start 全失败 → 保持未运行', () async {
      final FakeGoProxyBridge bridge = FakeGoProxyBridge();
      bridge.onInvoke = (String method, Map<String, Object?>? _) =>
          method == 'start' ? 'error:no port' : 'ok';
      final MethodChannelGoProxyClient c =
          MethodChannelGoProxyClient(bridge: bridge);
      expect(await c.start(), 'error:no port');
      expect(c.isRunning, isFalse);
    });

    test('未运行时 registerStream 降级直链', () async {
      final FakeGoProxyBridge bridge = FakeGoProxyBridge();
      final MethodChannelGoProxyClient c =
          MethodChannelGoProxyClient(bridge: bridge);
      expect(
        await c.registerStream(
          upstreamUrl: 'http://up/1.m3u8',
          headers: const <String, String>{},
        ),
        'http://up/1.m3u8',
      );
      expect(bridge.calls, isEmpty);
    });

    test('registerStream 成功 → 本地代理地址；失败 → 降级直链', () async {
      final FakeGoProxyBridge bridge = FakeGoProxyBridge();
      bridge.onInvoke = (String method, Map<String, Object?>? _) {
        if (method == 'registerStream') return 'http://127.0.0.1:10078/play?id=abc';
        return 'ok';
      };
      final MethodChannelGoProxyClient c =
          MethodChannelGoProxyClient(bridge: bridge);
      await c.start();
      expect(
        await c.registerStream(
          upstreamUrl: 'http://up/1.m3u8',
          headers: const <String, String>{'Referer': 'https://aliyun.com/'},
        ),
        'http://127.0.0.1:10078/play?id=abc',
      );

      // 原生返回非代理地址 → 降级直链
      bridge.onInvoke = (String method, Map<String, Object?>? _) {
        if (method == 'registerStream') return 'error:invalid';
        return 'ok';
      };
      expect(
        await c.registerStream(
          upstreamUrl: 'http://up/2.m3u8',
          headers: const <String, String>{},
        ),
        'http://up/2.m3u8',
      );
    });

    test('registerQuarkStream 路径前缀标记 + 鉴权头', () async {
      final FakeGoProxyBridge bridge = FakeGoProxyBridge();
      bridge.onInvoke = (String method, Map<String, Object?>? _) {
        if (method == 'registerStream') return 'http://127.0.0.1:10078/play?id=q1';
        return 'ok';
      };
      final MethodChannelGoProxyClient c =
          MethodChannelGoProxyClient(bridge: bridge);
      await c.start();

      final String m3u8 = await c.registerQuarkStream(
        upstreamUrl: 'http://up/q.m3u8',
        cookie: 'video_auth=abc',
        deviceID: 'dev-1',
        source: 'v2-play-m3u8',
      );
      expect(m3u8, 'http://127.0.0.1:10078/quark-m3u8/play?id=q1');

      // 记录的头包含夸克鉴权（Cookie / UA / Referer / X-Device-Id）
      final Map<String, Object?>? args = bridge.calls.last.$2;
      final Map<String, Object?> headers =
          (args?['headers'] as Map).cast<String, Object?>();
      expect(headers['Cookie'], 'video_auth=abc');
      expect(headers['User-Agent'], kQuarkDesktopUA);
      expect(headers['X-Device-Id'], 'dev-1');
      expect(headers['Referer'], 'https://pan.quark.cn/');

      // 默认 source → quark-stream 前缀
      final String direct = await c.registerQuarkStream(
        upstreamUrl: 'http://up/d.mp4',
        cookie: 'c=2',
      );
      expect(direct, 'http://127.0.0.1:10078/quark-stream/play?id=q1');
    });

    test('status / clearCache / stop 桥协议', () async {
      final FakeGoProxyBridge bridge = FakeGoProxyBridge();
      bridge.onInvoke = (String method, Map<String, Object?>? _) {
        if (method == 'status') return 'running port=10078 streams=1';
        return 'ok';
      };
      final MethodChannelGoProxyClient c =
          MethodChannelGoProxyClient(bridge: bridge);
      await c.start();
      expect(await c.status(), contains('streams=1'));
      await c.clearCache();
      await c.stop();
      expect(c.isRunning, isFalse);
      expect(
        bridge.calls.map(((String, Map<String, Object?>?) call) => call.$1).toList(),
        containsAll(<String>['status', 'clearCache', 'stop']),
      );
    });
  });
}
