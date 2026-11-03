/// 平台层：JavaScriptCore 原生 FFI 绑定抽象（批次 Q · Q-05，D6 主引擎）。
///
/// 对应原生侧：`jsc/wrapper.c`（纯 C，三端可编译，产物 `libvbox_jsc`）。
/// Dart 侧经 `dart:ffi` 加载动态库并调用 `vj_*` 符号，语义与 QuickJS 侧
/// `quickjs/wrapper.c` 的 `vq_*` 完全对齐（**三端同一 ABI**，Q-05 验收口径）：
/// - `eval` 迧行脚本并返回结果字符串；JS 异常时返回异常消息
///   （JSC 的 `Error` 对象 `toString()` 天然带 `Error: ` 前缀，满足契约 §5 检测）
/// - 返回值由原生库持有（JSC 侧为 `malloc` 缓冲），Dart 复制后由实现内部
///   调用 `vj_free_string` 释放
/// - JSC 无独立「运行时」概念（上下文即全局），`createRuntime` 返回哑元句柄，
///   `freeRuntime` 为 no-op —— 对上层引擎保持与 QuickJS 相同的生命周期形状
///
/// 分发（Q-01 评估结论）：
/// - macOS：链接系统 `JavaScriptCore.framework`（`build-jsc.yml` 产出 dylib）
/// - Windows：WinCairo JSC-only 自建 `vbox_jsc.dll`（MSVC，仅 x64）
/// - Android：JSC 预编译 `.so` + NDK 编译 wrapper（四 ABI）
///
/// 设计：`JsCoreNativeBridge` 抽象可注入 —— 单测使用 fake 实现（FFI mock），
/// 运行环境使用 [DartFfiJsCoreBridge]（加载失败时 `isAvailable == false`，
/// 工厂按 D6 自动降级 QuickJS 且降级可观测，见 B-05）。
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// 按平台解析动态库名（Android / Linux 用 .so，macOS .dylib，Windows .dll）。
String jsCoreLibraryName() => switch (Platform.operatingSystem) {
      'macos' => 'libvbox_jsc.dylib',
      'windows' => 'vbox_jsc.dll',
      _ => 'libvbox_jsc.so',
    };

/// JavaScriptCore 原生桥接口（FFI mock 与真实实现共用，形状对齐 QuickJS）。
abstract class JsCoreNativeBridge {
  /// 原生库是否已成功加载（false 时调用方应按 D6 降级 QuickJS）。
  bool get isAvailable;

  /// 创建运行时，返回不透明句柄（JSC 为哑元，恒非 0；失败返回 0）。
  int createRuntime();

  /// 创建全局上下文（`JSGlobalContextCreate`），失败返回 0。
  int createContext(int runtime);

  /// 释放上下文（`JSGlobalContextRelease`）。
  void freeContext(int context);

  /// 释放运行时（JSC no-op，保持 ABI 形状）。
  void freeRuntime(int runtime);

  /// 执行脚本并返回结果字符串；JS 异常时返回 `Error/TypeError/...` 前缀消息。
  String? eval(int context, String script);
}

/// `dart:ffi` 实现：加载 `libvbox_jsc` 动态库。
class DartFfiJsCoreBridge implements JsCoreNativeBridge {
  DartFfiJsCoreBridge({String? libraryName}) {
    try {
      _lib = DynamicLibrary.open(libraryName ?? jsCoreLibraryName());
    } on ArgumentError {
      // 库不存在（本机未打包 / 测试环境）→ isAvailable == false
      _lib = null;
    }
  }

  DynamicLibrary? _lib;

  late final Pointer<Void> Function() _createRuntime =
      _lib!.lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
          'vj_create_runtime');
  late final Pointer<Void> Function(Pointer<Void>) _createContext = _lib!
      .lookupFunction<Pointer<Void> Function(Pointer<Void>),
          Pointer<Void> Function(Pointer<Void>)>('vj_create_context');
  late final void Function(Pointer<Void>) _freeRuntime = _lib!
      .lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
          'vj_free_runtime');
  late final void Function(Pointer<Void>) _freeContext = _lib!
      .lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
          'vj_free_context');
  late final Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>) _eval = _lib!
      .lookupFunction<Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>),
          Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>)>('vj_eval');
  late final void Function(Pointer<Void>, Pointer<Utf8>) _freeString = _lib!
      .lookupFunction<Void Function(Pointer<Void>, Pointer<Utf8>),
          void Function(Pointer<Void>, Pointer<Utf8>)>('vj_free_string');

  @override
  bool get isAvailable => _lib != null;

  @override
  int createRuntime() {
    final Pointer<Void> p = _createRuntime();
    return p.address;
  }

  @override
  int createContext(int runtime) {
    final Pointer<Void> p = _createContext(Pointer<Void>.fromAddress(runtime));
    return p.address;
  }

  @override
  void freeContext(int context) {
    if (context != 0) {
      _freeContext(Pointer<Void>.fromAddress(context));
    }
  }

  @override
  void freeRuntime(int runtime) {
    if (runtime != 0) {
      _freeRuntime(Pointer<Void>.fromAddress(runtime));
    }
  }

  @override
  String? eval(int context, String script) {
    if (context == 0) return null;
    final Pointer<Utf8> scriptPtr = script.toNativeUtf8();
    final Pointer<Void> ctxPtr = Pointer<Void>.fromAddress(context);
    final Pointer<Utf8> resultPtr = _eval(ctxPtr, scriptPtr);
    malloc.free(scriptPtr); // toNativeUtf8 默认用 malloc 分配，立即释放
    if (resultPtr == nullptr) return null;
    final String result = resultPtr.toDartString();
    _freeString(ctxPtr, resultPtr); // 原生侧 free(malloc 缓冲)
    return result;
  }
}

/// 原生库不可用时的桥（`isAvailable == false`，所有调用为安全 no-op）。
///
/// 工厂（B-05）据此触发 D6 降级：QuickJS 顶替 + 降级可观测。
class UnavailableJsCoreBridge implements JsCoreNativeBridge {
  const UnavailableJsCoreBridge();

  @override
  bool get isAvailable => false;

  @override
  int createRuntime() => 0;

  @override
  int createContext(int runtime) => 0;

  @override
  void freeContext(int context) {}

  @override
  void freeRuntime(int runtime) {}

  @override
  String? eval(int context, String script) => null;
}
