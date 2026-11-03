/*
 * vbox QuickJS FFI wrapper — 头文件（G-03-B-1）。
 *
 * 对齐 iOS `vbox/Libraries/QuickJSBridge.h` 的语义，但为**纯 C 实现**（无
 * Foundation / 平台框架依赖），Android / Windows / macOS 三端可编译；
 * Dart 侧经 `dart:ffi` 加载 `libvbox_quickjs`（.so / .dll / .dylib）调用。
 *
 * 生命周期约定（与 iOS QJSSpiderEngine.deinit 相同）：
 *   1. 先 `vq_free_context` 释放 context（级联释放 global 及其属性）
 *   2. 再 `vq_free_runtime` 释放 runtime（内部先 JS_RunGC）
 * 顺序颠倒会导致 JS_FreeRuntime 断言失败。
 */
#ifndef VBOX_QUICKJS_WRAPPER_H
#define VBOX_QUICKJS_WRAPPER_H

#if defined(_WIN32)
#define VQ_EXPORT __declspec(dllexport)
#else
#define VQ_EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* 创建 / 释放运行时与上下文（不透明指针，Dart 侧以 int 句柄持有地址）。 */
VQ_EXPORT void *vq_create_runtime(void);
VQ_EXPORT void *vq_create_context(void *rt);
VQ_EXPORT void vq_free_runtime(void *rt);
VQ_EXPORT void vq_free_context(void *ctx);

/*
 * 执行脚本（JS_EVAL_TYPE_GLOBAL）。
 * - 返回堆缓冲：JSON 字符串或异常消息（Error / TypeError / ReferenceError /
 *   SyntaxError 前缀，与契约 §5 错误检测规则一致）；
 * - Dart 侧复制后必须调用 `vq_free_buffer` 释放；
 * - `vq_free_string` 已废弃（no-op，勿再用于 eval 结果）。
 */
VQ_EXPORT const char *vq_eval(void *ctx, const char *script);
VQ_EXPORT void vq_free_string(void *ctx, const char *str);

/*
 * ── 宿主桥（G-03-B-3 · JS 同步 HTTP 的 Dart 回调实现）─────────────────────
 *
 * 背景：蜘蛛脚本在 homeContent / categoryContent 等操作里**同步调用**
 * `req(url, options)`（对齐 iOS JSHTTPBridge / QuickJSBridge.m 的同步 HTTP 桥）。
 * Dart FFI 侧无法在 eval 调用栈内同步发请求（isolate 事件循环被阻塞），
 * 故将 eval 移入 worker 线程执行：脚本调用 http() 时经宿主回调通知 Dart
 * 异步发请求，完成后 Dart 回写结果并唤醒 worker 继续执行 —— 对脚本
 * 保持同步语义（iOS 同款模型：原生线程 eval + 信号量等待）。
 *
 * 事件回调（Dart 经 NativeCallable.listener 注册，在 Dart isolate 事件循环执行）：
 *   event 1 = eval 完成（Dart 应随后调 vq_eval_take_result 取走结果）
 *   event 2 = HTTP 请求（Dart 应异步执行后调 vq_http_complete 回写）
 */
typedef void (*VqHostCallback)(void *rt, int event, int req_id,
                               const char *url, const char *options_json);

/* 注册宿主回调（必须在 vq_eval_submit 之前；rt 生命周期内可更新）。 */
VQ_EXPORT void vq_set_host_bridge(void *rt, VqHostCallback cb);

/*
 * 投递脚本到 worker 线程执行（非阻塞，立即返回）。
 * 返回 1 = 已投递（完成时经 event 1 通知）；0 = 无线程支持 / 忙碌，
 * 调用方应回退同步 vq_eval（此时 http 桥不可用）。
 */
VQ_EXPORT int vq_eval_submit(void *rt, const char *script);

/* 取走 eval 结果（仅 event 1 之后调用一次）：返回堆缓冲，Dart 复制后
 * 必须调 vq_free_buffer 释放；未完成返回 NULL。 */
VQ_EXPORT const char *vq_eval_take_result(void *rt);

/*
 * Dart 回写 HTTP 响应（req_id 对应 event 2 的请求）。
 * [response_json] 为完整响应对象 JSON：
 *   {"ok":bool,"status":int,"content":"...","url":"...","headers":{...},"error":"..."}
 * C 侧仅存槽并唤醒 worker，由 JS 侧 JS_ParseJSON 还原为对象
 * （对齐 iOS JSSpiderEngine 的字典返回：resp.status / resp.content / resp.ok）。
 * 返回 1 = 已受理（req_id 匹配）；0 = 忽略（过期请求 / 无桥）。
 */
VQ_EXPORT int vq_http_complete(void *rt, int req_id, const char *response_json);

/* 释放 vq_eval_take_result 返回的缓冲。 */
VQ_EXPORT void vq_free_buffer(void *p);

#ifdef __cplusplus
}
#endif

#endif /* VBOX_QUICKJS_WRAPPER_H */
