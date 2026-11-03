/// 平台层单测：Android Chaquopy 运行时通道桥（Wave G · RT-运1）。
///
/// 覆盖：`com.vbox.python/python` 通道名与 Android `PythonPlugin.CHANNEL` 一致；
/// `launch` / `request` / `shutdown` 的参数透传；通道未注册
/// （`MissingPluginException`）→ `E_UNIMPLEMENTED` 降级；原生 `E_TIMEOUT` → 超时错误；
/// 以及 [PythonBridgeEngine] 注入通道运行时后的 ABI 端到端解码（不依赖真实 python3）。
/// 使用 `TestDefaultBinaryMessenger` mock 原生通道，无真实插件依赖。
library;

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/spider/spider_engine.dart';
import 'package:vbox/domain/entities/spider/spider_models.dart';
import 'package:vbox/platform/spider/python_bridge_engine.dart';
import 'package:vbox/platform/spider/python_runtime.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel =
      MethodChannel(ChannelPythonRuntime.channelName);

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  void mockHandler(Future<Object?> Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
  }

  group('ChannelPythonRuntime（com.vbox.python/python）', () {
    test('通道名与 Android PythonPlugin.CHANNEL 一致', () {
      expect(ChannelPythonRuntime.channelName, 'com.vbox.python/python');
    });

    test('launch 透传 script / timeoutMs；roundTrip 透传 line', () async {
      final List<MethodCall> calls = <MethodCall>[];
      mockHandler((MethodCall call) async {
        calls.add(call);
        return switch (call.method) {
          'launch' => null,
          'request' => '{"ok":true,"data":{},"logs":[]}',
          _ => null,
        };
      });

      final ChannelPythonRuntime rt =
          ChannelPythonRuntime(timeout: const Duration(seconds: 7));
      await rt.launch('print("READY")');
      final String resp = await rt.roundTrip('{"op":"homeContent"}');

      expect(resp, '{"ok":true,"data":{},"logs":[]}');
      expect(calls.map((MethodCall c) => c.method), <String>[
        'launch',
        'request',
      ]);
      expect(
        (calls[0].arguments as Map)['timeoutMs'],
        7000,
        reason: 'launch 超时应为 timeout 的毫秒值',
      );
      expect((calls[1].arguments as Map)['line'], '{"op":"homeContent"}');
    });

    test('shutdown 容错：通道未注册（MissingPluginException）不抛', () async {
      final ChannelPythonRuntime rt = ChannelPythonRuntime();
      await expectLater(rt.shutdown(), completes);
    });

    test('通道未注册 → launch 抛 E_UNIMPLEMENTED（降级提示，不 crash）', () async {
      final ChannelPythonRuntime rt = ChannelPythonRuntime();
      await expectLater(
        rt.launch('print("READY")'),
        throwsA(
          isA<SpiderException>().having(
            (SpiderException e) => e.code,
            'code',
            SpiderErrorCode.unimplemented,
          ),
        ),
      );
    });

    test('原生 E_TIMEOUT → roundTrip 抛超时错误', () async {
      mockHandler((MethodCall call) async {
        if (call.method == 'request') {
          throw PlatformException(code: 'E_TIMEOUT', message: 'Python 桥响应超时');
        }
        return null;
      });

      final ChannelPythonRuntime rt = ChannelPythonRuntime();
      await expectLater(
        rt.roundTrip('{"op":"searchContent"}'),
        throwsA(
          isA<SpiderException>().having(
            (SpiderException e) => e.code,
            'code',
            SpiderErrorCode.timeout,
          ),
        ),
      );
    });

    test('原生 E_PY_RUNTIME → roundTrip 抛运行时错误', () async {
      mockHandler((MethodCall call) async {
        if (call.method == 'request') {
          throw PlatformException(code: 'E_PY_RUNTIME', message: '脚本已退出');
        }
        return null;
      });

      final ChannelPythonRuntime rt = ChannelPythonRuntime();
      await expectLater(
        rt.roundTrip('{"op":"searchContent"}'),
        throwsA(
          isA<SpiderException>().having(
            (SpiderException e) => e.code,
            'code',
            SpiderErrorCode.runtime,
          ),
        ),
      );
    });
  });

  group('PythonBridgeEngine（注入 Chaquopy 运行时）', () {
    test('loadScript → searchContent 端到端解码（不依赖真实 python3）', () async {
      mockHandler((MethodCall call) async {
        if (call.method == 'request') {
          return jsonEncode(<String, Object?>{
            'ok': true,
            'data': <String, Object?>{
              'page': 1,
              'pagecount': 5,
              'list': <Object?>[
                <String, Object?>{'vod_id': '2001', 'vod_name': '测试影片'},
              ],
            },
            'logs': <String>[],
            'elapsedMs': 1,
          });
        }
        return null;
      });

      final PythonBridgeEngine engine = PythonBridgeEngine(
        runtime: ChannelPythonRuntime(),
      );
      try {
        await engine.loadScript('print("READY")');
        await engine.registerSpider();
        expect(engine.isSpiderReady, isTrue);

        final SearchContentResult r = await engine.callSearchContent('测试', 1);
        expect(r.page, 1);
        expect(r.pagecount, 5);
        expect(r.list, hasLength(1));
        expect(r.list!.first.vodId, '2001');
      } finally {
        await engine.dispose();
      }
    });
  });
}
