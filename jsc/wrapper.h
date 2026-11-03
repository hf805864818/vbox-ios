/*
 * vbox JavaScriptCore FFI wrapper — 头文件（批次 Q · Q-05，D6 主引擎）。
 *
 * 与 `quickjs/wrapper.h` 的 `vq_*` 保持**同一 ABI 形状**（三端同一 ABI，
 * Q-05 验收口径），Dart 侧经 `dart:ffi` 加载 `libvbox_jsc`
 * （.so / .dll / .dylib，见 `lib/platform/runtime/jsc_ffi.dart`）调用。
 *
 * 平台差异（Q-01 评估结论 `docs/评估_JSC_Windows可行性.md`）：
 * - macOS：链接系统 `JavaScriptCore.framework`（零第三方源码）
 * - Windows：WinCairo JSC-only 自建（MSVC，仅 x64，LGPL-2.1 动态链接合规）
 * - Android：JSC 预编译 `.so` + NDK 编译本 wrapper（四 ABI）
 *
 * 生命周期约定（对齐 QuickJS 侧）：
 *   1. 先 `vj_free_context` 释放 JSGlobalContext（触发 GC 回收）
 *   2. 再 `vj_free_runtime`（JSC 无独立运行时，no-op）
 */
#ifndef VBOX_JSC_WRAPPER_H
#define VBOX_JSC_WRAPPER_H

#if defined(_WIN32)
#define VJ_EXPORT __declspec(dllexport)
#else
#define VJ_EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

/*
 * 创建「运行时」（JSC 无独立运行时概念 —— 上下文即全局）。
 * 返回哑元非 NULL 指针（保持与 vq_* 相同的生命周期形状）；
 * Dart 侧以 int 句柄持有地址，0 视为失败。
 */
VJ_EXPORT void *vj_create_runtime(void);

/* 创建全局上下文（`JSGlobalContextCreate(NULL)`，内置默认全局对象类）。 */
VJ_EXPORT void *vj_create_context(void *rt);

/* 释放上下文（`JSGlobalContextRelease`）。 */
VJ_EXPORT void vj_free_context(void *ctx);

/* 释放「运行时」（JSC no-op，保持 ABI 形状）。 */
VJ_EXPORT void vj_free_runtime(void *rt);

/*
 * 执行脚本（`JSEvaluateScript`，thisObject = NULL → global）。
 * - 返回结果值的字符串化（`JSValueToStringCopy`，如 JSON 字符串 / "undefined"）；
 * - 异常时返回异常消息（JSC `Error` 对象 toString 天然带 `Error: ` 前缀，
 *   与契约 §5 错误检测规则一致）；
 * - 返回值为本库 `malloc` 的缓冲，Dart 侧复制后必须调用 `vj_free_string` 释放。
 */
VJ_EXPORT const char *vj_eval(void *ctx, const char *script);
VJ_EXPORT void vj_free_string(void *ctx, const char *str);

#ifdef __cplusplus
}
#endif

#endif /* VBOX_JSC_WRAPPER_H */
