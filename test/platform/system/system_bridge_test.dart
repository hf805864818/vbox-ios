/// G-02-C：MethodChannelSystemBridge 通道调用与异常安全回退。
///
/// 覆盖：`com.vbox.system/system` 通道三方法转发、结果映射（仅严格 true 为 TV）、
/// `MissingPluginException` / `PlatformException` 安全回退 false（不抛）。
/// 使用 `TestDefaultBinaryMessenger` mock 原生通道，无真实插件依赖。
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/platform/system/system_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MethodChannel channel;
  late MethodChannelSystemBridge bridge;

  setUp(() {
    channel = const MethodChannel(MethodChannelSystemBridge.defaultChannelName);
    bridge = MethodChannelSystemBridge();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  void mockHandler(Future<Object?> Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
  }

  group('MethodChannelSystemBridge（com.vbox.system/system）', () {
    test('默认通道名与 Android SystemPlugin 一致', () {
      expect(
        MethodChannelSystemBridge.defaultChannelName,
        'com.vbox.system/system',
      );
    });

    test('三方法名按序正确转发（getUiModeType / hasLeanbackFeature / hasTouchscreen）', () async {
      final List<String> methods = <String>[];
      mockHandler((MethodCall call) async {
        methods.add(call.method);
        return true;
      });
      await bridge.getUiModeType();
      await bridge.hasLeanbackFeature();
      await bridge.hasTouchscreen();
      expect(
        methods,
        <String>['getUiModeType', 'hasLeanbackFeature', 'hasTouchscreen'],
      );
    });
  });

  group('结果映射', () {
    test('原生返回 true → true', () async {
      mockHandler((MethodCall _) async => true);
      expect(await bridge.getUiModeType(), isTrue);
    });

    test('原生返回 false → false', () async {
      mockHandler((MethodCall _) async => false);
      expect(await bridge.hasLeanbackFeature(), isFalse);
    });

    test('原生返回非布尔值 → false（仅严格 true 判 TV）', () async {
      mockHandler((MethodCall _) async => 'TV');
      expect(await bridge.getUiModeType(), isFalse);
    });
  });

  group('异常安全回退（不抛，非 TV）', () {
    test('MissingPluginException → false（桌面 / 测试环境无原生插件）', () async {
      mockHandler((MethodCall _) async => throw MissingPluginException('nope'));
      expect(await bridge.getUiModeType(), isFalse);
    });

    test('PlatformException → false', () async {
      mockHandler((MethodCall _) async => throw PlatformException(code: 'E_X'));
      expect(await bridge.hasTouchscreen(), isFalse);
    });
  });
}
