/// 平台层：运行时（runtime）barrel 导出。
///
/// G-03-B：QuickJS FFI 原生绑定（`quickjs/wrapper.c` + Dart `dart:ffi` 抽象）。
/// 批次 Q（Q-05）：JSC FFI 原生绑定（`jsc/wrapper.c`，D6 主引擎）。
library;

export 'jsc_bridge_engine.dart';
export 'jsc_ffi.dart';
export 'quickjs_bridge_engine.dart';
export 'quickjs_ffi.dart';
