/*
 * vbox JavaScriptCore FFI wrapper — 实现（批次 Q · Q-05，D6 主引擎）。
 *
 * 纯 C（C99）包装 JSC C API（<JavaScriptCore/JavaScriptCore.h>），
 * 无平台框架依赖：macOS（clang + 系统 framework）/ Windows（MSVC +
 * WinCairo JSC-only）/ Android（NDK + JSC 预编译 .so）三端可编译。
 * 编译产物为动态库 `libvbox_jsc`，Dart 侧经 `dart:ffi`
 * （`lib/platform/runtime/jsc_ffi.dart`）加载。
 *
 * 语义对齐 `quickjs/wrapper.c` 的 `vq_*`（三端同一 ABI）：
 *   · createRuntime / createContext / freeRuntime / freeContext / eval / freeString
 *   · eval 异常消息（Error / TypeError / ... 前缀）→ 契约 §5 错误检测
 *   · console / print 不在此注册（B-05a 改由 `SpiderJsGlobals.prelude`
 *     在 JS 层注入，与引擎无关，避免双重定义）
 */
#include <stdlib.h>
#include <string.h>

/*
 * 注意：include 的是 C API 主头 `JavaScript.h` 而非伞头 `JavaScriptCore.h` ——
 * 后者拉入 `JSStringRefCF.h`（依赖 CoreFoundation，Android/Windows 无该框架）。
 * 三端头文件来源：
 *   · macOS：系统 `JavaScriptCore.framework/Headers`（自带 JavaScript.h）
 *   · Android：`jsc/include/JavaScriptCore/`（Q-02 vendor，源自 jsc-android
 *     r250231 的 dist/include，Apple BSD-2 声明保留）
 *   · Windows：WinCairo JSC-only 产物自带（Q-03）
 */
#include <JavaScriptCore/JavaScript.h>

#include "wrapper.h"

/* ── 运行时 / 上下文 ────────────────────────────────────────────────────── */

void *vj_create_runtime(void) {
    /* JSC 无独立运行时（上下文即全局）：哑元非 NULL，保持 vq_* 形状 */
    return (void *)1;
}

void *vj_create_context(void *rt) {
    (void)rt; /* 运行时哑元，不参与上下文创建 */
    return JSGlobalContextCreate(NULL);
}

void vj_free_context(void *ctx) {
    if (ctx != NULL) {
        JSGlobalContextRelease((JSGlobalContextRef)ctx);
    }
}

void vj_free_runtime(void *rt) {
    (void)rt; /* JSC no-op（上下文释放时 GC 自行回收） */
}

/* ── 脚本执行 ───────────────────────────────────────────────────────────── */

const char *vj_eval(void *ctx, const char *script) {
    JSGlobalContextRef context = (JSGlobalContextRef)ctx;
    if (context == NULL || script == NULL) {
        return NULL;
    }

    JSStringRef scriptRef = JSStringCreateWithUTF8CString(script);
    JSValueRef exception = NULL;
    JSValueRef result =
        JSEvaluateScript(context, scriptRef, NULL, NULL, 0, &exception);
    JSStringRelease(scriptRef);

    /* 异常优先：Error/TypeError/... 的 toString 天然带前缀（契约 §5） */
    JSValueRef value = (exception != NULL) ? exception : result;
    if (value == NULL) {
        return NULL;
    }

    JSStringRef strRef = JSValueToStringCopy(context, value, NULL);
    if (strRef == NULL) {
        return NULL;
    }
    size_t maxLen = JSStringGetMaximumUTF8CStringSize(strRef);
    char *buf = (char *)malloc(maxLen);
    if (buf == NULL) {
        JSStringRelease(strRef);
        return NULL;
    }
    JSStringGetUTF8CString(strRef, buf, maxLen);
    JSStringRelease(strRef);
    return buf; /* 调用方复制后经 vj_free_string 释放 */
}

void vj_free_string(void *ctx, const char *str) {
    (void)ctx; /* JSC 无 per-context 字符串池（malloc 缓冲直接 free） */
    if (str != NULL) {
        free((void *)str);
    }
}
