/// conformance 测试：双引擎 ABI 一致性（fixture ↔ Dart 实现）。
///
/// 消费 `conformance/fixtures/engine_abi_v1.json`，验证：
///   1. `SpiderEngineType` 枚举 rawValue 与 fixture 一一对应；
///   2. D6 降级链：JSC 不可用 → 自动降级 QuickJS，且降级可观测
///      （onLog 携 fixture 声明的事件标记）；
///   3. JSC 可用 → 保持 JSC 主引擎（不触发降级）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/spider/engine_type.dart';
import 'package:vbox/domain/entities/spider/spider_engine.dart';
import 'package:vbox/platform/runtime/jsc_ffi.dart';
import 'package:vbox/platform/runtime/quickjs_ffi.dart';
import 'package:vbox/platform/spider/spider_engine_factory.dart';

/// 可用 JSC 桥（FFI mock，仅用于工厂分派）。
class _AvailableJsCoreBridge implements JsCoreNativeBridge {
  @override
  bool get isAvailable => true;

  @override
  int createRuntime() => 1;

  @override
  int createContext(int runtime) => 2;

  @override
  void freeContext(int context) {}

  @override
  void freeRuntime(int runtime) {}

  @override
  String? eval(int context, String script) => '';
}

/// 可用 QuickJS 桥（FFI mock，仅用于工厂分派）。
class _AvailableQuickJsBridge implements QuickJsNativeBridge {
  @override
  bool get isAvailable => true;

  @override
  int createRuntime() => 1;

  @override
  int createContext(int runtime) => 2;

  @override
  void freeContext(int context) {}

  @override
  void freeRuntime(int runtime) {}

  @override
  String? eval(int context, String script) {
    if (script == 'typeof globalThis.__JS_SPIDER__') return 'object';
    return '';
  }
}

void main() {
  final Map<String, Object?> fixture =
      (jsonDecode(File('conformance/fixtures/engine_abi_v1.json').readAsStringSync())
              as Map)
          .cast<String, Object?>();

  test('引擎类型 rawValue 与 fixture engines 一一对应', () {
    final List<Object?> engines = (fixture['engines'] as List).cast<Object?>();
    expect(engines.length, SpiderEngineType.values.length);
    for (final Object? e in engines) {
      final Map<String, Object?> m = (e as Map).cast<String, Object?>();
      final String typeName = m['type'] as String;
      final String raw = m['rawValue'] as String;
      final SpiderEngineType? t = SpiderEngineType.fromRawValue(raw);
      expect(t, isNotNull, reason: 'raw=$raw 无法解析');
      expect(t!.name, typeName, reason: 'raw=$raw');
      expect(t.rawValue, raw);
    }
  });

  test('D6 降级：JSC 不可用 → QuickJS 顶替且降级可观测', () {
    final List<String> markers =
        ((fixture['fallback'] as Map)['markers'] as List).cast<String>();
    final List<String> logs = <String>[];

    final SpiderEngine engine = const SpiderEngineFactory().create(
      SpiderEngineType.javaScriptCore,
      jsCoreBridge: const UnavailableJsCoreBridge(),
      quickJsBridge: _AvailableQuickJsBridge(),
      siteKey: 'js_x',
      onLog: logs.add,
    );

    expect(engine.engineType, SpiderEngineType.quickJS,
        reason: 'JSC 不可用应自动降级 QuickJS');
    final String joined = logs.join('\n');
    for (final String marker in markers) {
      expect(joined, contains(marker), reason: '缺降级标记 $marker');
    }
  });

  test('JSC 可用 → 保持 JSC 主引擎（不触发降级）', () {
    final SpiderEngine engine = const SpiderEngineFactory().create(
      SpiderEngineType.javaScriptCore,
      jsCoreBridge: _AvailableJsCoreBridge(),
      quickJsBridge: _AvailableQuickJsBridge(),
      siteKey: 'js_x',
    );
    expect(engine.engineType, SpiderEngineType.javaScriptCore);
  });
}