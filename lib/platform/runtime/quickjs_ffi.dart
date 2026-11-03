/// 平台层：QuickJS 原生 FFI 绑定抽象（G-03-B-1）。
///
/// 对应原生侧：`quickjs/wrapper.c`（纯 C，三端可编译，产物 `libvbox_quickjs`）。
/// Dart 侧经 `dart:ffi` 加载动态库并调用 `vq_*` 符号，语义对齐 iOS
/// `vbox/Libraries/QuickJSBridge.m` + `QJSSpiderEngine.evaluateJS`：
/// - `eval` 返回 JS 表达式求值结果的字符串（异常时返回 Error 前缀消息）
/// - 返回值由原生库持有，Dart 复制后由实现内部调用 `vq_free_string` 释放
///
/// 设计：`QuickJsNativeBridge` 抽象可注入 —— 单测使用 fake 实现（FFI mock），
/// 运行环境使用 [DartFfiQuickJsBridge]（加载失败时 `isAvailable == false`）。
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// 按平台解析动态库名（Android / Linux 用 .so，macOS .dylib，Windows .dll）。
String quickJsLibraryName() => switch (Platform.operatingSystem) {
      'macos' => 'libvbox_quickjs.dylib',
      'windows' => 'vbox_quickjs.dll',
      _ => 'libvbox_quickjs.so',
    };

/// QuickJS 原生桥接口（FFI mock 与真实实现共用）。
abstract class QuickJsNativeBridge {
  /// 原生库是否已成功加载（false 时调用方应回退 / 抛错）。
  bool get isAvailable;

  /// 创建运行时，返回不透明句柄（原生指针地址；失败返回 0）。
  int createRuntime();

  /// 在 [runtime] 上创建上下文（含 console/print 注册），失败返回 0。
  int createContext(int runtime);

  /// 释放上下文（必须先于 runtime，对齐 iOS 清理顺序）。
  void freeContext(int context);

  /// 释放运行时（内部先 JS_RunGC）。
  void freeRuntime(int runtime);

  /// 执行脚本并返回结果字符串；异常时返回 `Error/TypeError/...` 前缀消息。
  String? eval(int context, String script);
}

/// 宿主桥事件处理器（G-03-B-3 · Dart 侧回调）。
///
/// - `event == 1`：eval 完成（url/optionsJson 为空串；随后调 [QuickJsAsyncNativeBridge.evalTakeResult]）
/// - `event == 2`：脚本 `http(url, options)` 请求（Dart 异步执行后调
///   [QuickJsAsyncNativeBridge.httpComplete] 回写，reqId 对应）
typedef QuickJsHostEventHandler = void Function(
    int event, int reqId, String url, String optionsJson);

/// C 侧宿主回调原生签名（`wrapper.h` `VqHostCallback`）。
typedef VqHostCallbackNative = Void Function(
    Pointer<Void> rt,
    Int32 event,
    Int32 reqId,
    Pointer<Utf8> url,
    Pointer<Utf8> optionsJson);

/// 异步能力桥接口（G-03-B-3 · worker 线程 + 同步 HTTP 桥的 Dart 绑定）。
///
/// 独立于 [QuickJsNativeBridge]：引擎按 `is QuickJsAsyncNativeBridge`
/// 探测能力，未实现时回退同步 eval（脚本内 http() 不可用的旧语义）。
/// 真实实现为 [DartFfiQuickJsBridge]；单测注入 fake 模拟 worker 行为。
abstract class QuickJsAsyncNativeBridge {
  /// 注册宿主回调，返回句柄（0 = 不支持）；[handler] 在 isolate 事件循环执行。
  int setHostBridge(int runtime, QuickJsHostEventHandler handler);

  /// 释放 [handle] 对应的宿主回调（NativeCallable.listener 需 close 防 isolate 泄漏）。
  void closeHostBridge(int handle);

  /// 投递脚本到 worker 线程执行（非阻塞）。
  /// 返回 false = 无线程支持 / 忙碌，调用方应回退同步 eval。
  bool evalSubmit(int runtime, String script);

  /// 取走 eval 结果（仅 event 1 之后调用一次；未完成返回 null）。
  String? evalTakeResult(int runtime);

  /// 回写 HTTP 响应（[responseJson] 形状：
  /// `{"ok":bool,"status":int,"content":"...","url":"...","headers":{...},"error":"..."}`）。
  bool httpComplete(int runtime, int reqId, String responseJson);
}

/// `dart:ffi` 实现：加载 `libvbox_quickjs` 动态库。
class DartFfiQuickJsBridge implements QuickJsNativeBridge, QuickJsAsyncNativeBridge {
  DartFfiQuickJsBridge({String? libraryName}) {
    try {
      _lib = DynamicLibrary.open(libraryName ?? quickJsLibraryName());
    } on ArgumentError {
      // 库不存在（本机未打包 / 测试环境）→ isAvailable == false
      _lib = null;
    }
  }

  DynamicLibrary? _lib;

  late final Pointer<Void> Function() _createRuntime =
      _lib!.lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
          'vq_create_runtime');
  late final Pointer<Void> Function(Pointer<Void>) _createContext = _lib!
      .lookupFunction<Pointer<Void> Function(Pointer<Void>),
          Pointer<Void> Function(Pointer<Void>)>('vq_create_context');
  late final void Function(Pointer<Void>) _freeRuntime = _lib!
      .lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
          'vq_free_runtime');
  late final void Function(Pointer<Void>) _freeContext = _lib!
      .lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
          'vq_free_context');
  late final Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>) _eval = _lib!
      .lookupFunction<Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>),
          Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>)>('vq_eval');
  late final void Function(Pointer<Void>, Pointer<Utf8>) _freeString = _lib!
      .lookupFunction<Void Function(Pointer<Void>, Pointer<Utf8>),
          void Function(Pointer<Void>, Pointer<Utf8>)>('vq_free_string');

  // ── G-03-B-3：宿主桥符号（老版 wrapper 无这些符号 → 可选探测降级） ──
  // lookupFunction<nativeSig, dartSig>（返回 dartSig，变量类型即 Dart 签名）
  late final void Function(Pointer<Void>,
          Pointer<NativeFunction<VqHostCallbackNative>>)? _setHostBridge =
      _optional(() => _lib!.lookupFunction<
              Void Function(Pointer<Void>,
                  Pointer<NativeFunction<VqHostCallbackNative>>),
              void Function(Pointer<Void>,
                  Pointer<NativeFunction<VqHostCallbackNative>>)>(
          'vq_set_host_bridge'));
  late final int Function(Pointer<Void>, Pointer<Utf8>)? _evalSubmit =
      _optional(() => _lib!.lookupFunction<
              Int32 Function(Pointer<Void>, Pointer<Utf8>),
              int Function(Pointer<Void>, Pointer<Utf8>)>('vq_eval_submit'));
  late final Pointer<Utf8> Function(Pointer<Void>)? _evalTakeResult =
      _optional(() => _lib!.lookupFunction<
              Pointer<Utf8> Function(Pointer<Void>),
              Pointer<Utf8> Function(Pointer<Void>)>('vq_eval_take_result'));
  late final int Function(Pointer<Void>, int, Pointer<Utf8>)? _httpComplete =
      _optional(() => _lib!.lookupFunction<
              Int32 Function(Pointer<Void>, Int32, Pointer<Utf8>),
              int Function(Pointer<Void>, int, Pointer<Utf8>)>(
          'vq_http_complete'));
  late final void Function(Pointer<Void>)? _freeBuffer = _optional(() =>
      _lib!.lookupFunction<Void Function(Pointer<Void>),
          void Function(Pointer<Void>)>('vq_free_buffer'));

  /// 可选符号探测（旧版动态库缺失符号时返回 null，异步桥静默降级）。
  T? _optional<T extends Function>(T Function() lookup) {
    if (_lib == null) return null;
    try {
      return lookup();
    } on ArgumentError {
      return null;
    }
  }

  /// 宿主回调句柄 → callable（setHostBridge 分配，closeHostBridge 释放）。
  final Map<int, NativeCallable<VqHostCallbackNative>> _hostCallables =
      <int, NativeCallable<VqHostCallbackNative>>{};
  int _hostCallableSeq = 0;

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
    // 新版 wrapper：eval 返回堆缓冲 → vq_free_buffer；
    // 老版（无宿主桥符号）：JS 内部指针 → vq_free_string（JS_FreeCString）
    if (_freeBuffer != null) {
      _freeBuffer(Pointer<Void>.fromAddress(resultPtr.address));
    } else {
      _freeString(ctxPtr, resultPtr);
    }
    return result;
  }

  // ── QuickJsAsyncNativeBridge（G-03-B-3 · 宿主桥绑定） ────────────────────

  @override
  int setHostBridge(int runtime, QuickJsHostEventHandler handler) {
    final void Function(Pointer<Void>,
            Pointer<NativeFunction<VqHostCallbackNative>>)? register =
        _setHostBridge;
    if (register == null) return 0; // 老版动态库无宿主桥符号
    final NativeCallable<VqHostCallbackNative> callable =
        NativeCallable<VqHostCallbackNative>.listener(
      (Pointer<Void> rt, int event, int reqId, Pointer<Utf8> url,
          Pointer<Utf8> optionsJson) {
        // listener 在 isolate 事件循环执行；指针仅回调期间有效 → 立即复制
        final String u = url == nullptr ? '' : url.toDartString();
        final String o =
            optionsJson == nullptr ? '' : optionsJson.toDartString();
        handler(event, reqId, u, o);
      },
    );
    register(Pointer<Void>.fromAddress(runtime), callable.nativeFunction);
    final int handle = ++_hostCallableSeq;
    _hostCallables[handle] = callable;
    return handle;
  }

  @override
  void closeHostBridge(int handle) {
    final NativeCallable<VqHostCallbackNative>? callable =
        _hostCallables.remove(handle);
    callable?.close();
  }

  @override
  bool evalSubmit(int runtime, String script) {
    final int Function(Pointer<Void>, Pointer<Utf8>)? submit = _evalSubmit;
    if (submit == null || runtime == 0) return false;
    final Pointer<Utf8> scriptPtr = script.toNativeUtf8();
    final int ok = submit(Pointer<Void>.fromAddress(runtime), scriptPtr);
    malloc.free(scriptPtr);
    return ok != 0;
  }

  @override
  String? evalTakeResult(int runtime) {
    final Pointer<Utf8> Function(Pointer<Void>)? take = _evalTakeResult;
    if (take == null || runtime == 0) return null;
    final Pointer<Utf8> ptr = take(Pointer<Void>.fromAddress(runtime));
    if (ptr == nullptr) return null;
    final String result = ptr.toDartString();
    _freeBuffer?.call(Pointer<Void>.fromAddress(ptr.address));
    return result;
  }

  @override
  bool httpComplete(int runtime, int reqId, String responseJson) {
    final int Function(Pointer<Void>, int, Pointer<Utf8>)? complete =
        _httpComplete;
    if (complete == null || runtime == 0) return false;
    final Pointer<Utf8> respPtr = responseJson.toNativeUtf8();
    final int ok = complete(
        Pointer<Void>.fromAddress(runtime), reqId, respPtr);
    malloc.free(respPtr);
    return ok != 0;
  }
}

/// 原生库不可用时的桥（`isAvailable == false`，所有调用为安全 no-op）。
///
/// 引擎在 `isAvailable == false` 时抛 `SpiderException(unimplemented)`，
/// 使未打包原生库的环境（CI 单测 / 开发机）可安全降级。
class UnavailableQuickJsBridge implements QuickJsNativeBridge {
  const UnavailableQuickJsBridge();

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
