/*
 * vbox QuickJS FFI wrapper — 实现（G-03-B-1 / G-03-B-3）。
 *
 * 纯 C（C99），无平台框架依赖：Android（NDK）/ Windows（MSVC/mingw）/
 * macOS（clang）三端可直接编译。编译产物为动态库 `libvbox_quickjs`，
 * Dart 侧经 `dart:ffi`（`lib/platform/runtime/quickjs_ffi.dart`）加载。
 *
 * 语义对齐 iOS `vbox/Libraries/QuickJSBridge.m`（去 Foundation 依赖版）：
 *   · createRuntime / createContext / freeRuntime / freeContext / eval / freeString
 *   · 上下文创建时注册 `console.log / console.error / print` no-op
 *     （对齐 iOS `QJSSpiderEngine.setupBridge()`，避免蜘蛛脚本 console 调用抛错）
 *
 * G-03-B-3 · 同步 HTTP 桥（对齐 iOS QuickJSBridge.m `js_http_func` +
 * JSHTTPBridge.syncRequest 的「同步等待」语义）：
 *   蜘蛛脚本在 homeContent / categoryContent 内同步调用 `req(url, options)`，
 *   而 Dart FFI 的 eval 调用栈会阻塞 isolate 事件循环（无法同步发请求）。
 *   方案：eval 移入 worker 线程；脚本调 http() 时经宿主回调（Dart
 *   NativeCallable.listener）通知 Dart 异步发请求，完成后 Dart 调
 *   vq_http_complete 回写并唤醒 worker —— 对脚本保持同步语义，
 *   与 iOS「原生线程 eval + 信号量等待」同构。JS 侧返回**对象**
 *   {ok,status,content,url,headers,error}（对齐 iOS JSSpiderEngine 字典返回，
 *   脚本消费 resp.status / resp.content / resp.ok）。
 *
 * 线程模型：
 *   - 每 runtime 至多一个 worker 线程（惰性创建），独占 JSContext；
 *   - Dart 侧约定 evalAsync 未完成前不调同步 vq_eval（引擎串行 await）；
 *   - 槽字段（script/result/http_*）由 lock 保护；worker 在 http 等待期
 *     不持锁（避免与 Dart 回写路径死锁）；
 *   - Windows（_WIN32）以 Win32 原语（CRITICAL_SECTION / CreateSemaphore /
 *     CreateThread）实现同一模型，语义与 POSIX 分支等价（见下方可移植层）。
 */
/* Windows：GetTickCount64 需 _WIN32_WINNT ≥ 0x0600 才有声明；mingw 的 _mingw.h 会
 * 在首个标准头处把 _WIN32_WINNT 锁死为 0x502（无 GetTickCount64 声明 → 隐式声明
 * 返回 int，64 位刻度被截断）→ 必须在**任何** include 之前显式抬高（对齐 Win7+）。 */
#if defined(_WIN32) && !defined(_WIN32_WINNT)
#define _WIN32_WINNT 0x0601
#endif

/* clock_gettime / CLOCK_MONOTONIC / nanosleep（-std=c99 下需 POSIX 宏显式开启；
 * 必须置于所有系统头之前 —— features.h 首次被 include 时即锁定特性宏） */
#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif

#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#include "quickjs.h"
#include "wrapper.h"

#if defined(_WIN32)
#include <windows.h>
#else
#include <pthread.h>
#include <semaphore.h>
#include <time.h>
#endif

/* ── 线程 / 同步原语可移植层（POSIX pthread ↔ Win32）────────────────────────
 * 蜘蛛脚本的同步 http() 依赖「worker 线程 + 信号量等待」：eval 移出 isolate
 * 事件循环，脚本调 http() 时阻塞 worker，Dart 异步发请求后回写唤醒。
 * Windows 与 POSIX 语义等价，仅原语不同 —— 此前 Windows 走 VQ_NO_THREADS
 * 退化（submit 返回 0、http() 恒返回失败对象），导致桌面端切源分类无数据；
 * 现以 Win32 原语补齐（CRITICAL_SECTION / CreateSemaphore / CreateThread）。 */
#if defined(_WIN32)
typedef CRITICAL_SECTION vq_mutex_t;
typedef HANDLE vq_sem_t;
typedef HANDLE vq_thread_t;

static void vq_mutex_init(vq_mutex_t *m) { InitializeCriticalSection(m); }
static void vq_mutex_destroy(vq_mutex_t *m) { DeleteCriticalSection(m); }
static void vq_mutex_lock(vq_mutex_t *m) { EnterCriticalSection(m); }
static void vq_mutex_unlock(vq_mutex_t *m) { LeaveCriticalSection(m); }

static void vq_sem_init(vq_sem_t *s) {
    *s = CreateSemaphoreW(NULL, 0, 0x7fffffff, NULL);
}
static void vq_sem_destroy(vq_sem_t *s) {
    if (*s != NULL) CloseHandle(*s);
}
static void vq_sem_post(vq_sem_t *s) { ReleaseSemaphore(*s, 1, NULL); }
static void vq_sem_wait(vq_sem_t *s) { WaitForSingleObject(*s, INFINITE); }
static void vq_sem_trywait(vq_sem_t *s) { WaitForSingleObject(*s, 0); }

static void *vq_worker_main(void *arg);
static DWORD WINAPI vq_worker_trampoline(LPVOID arg) {
    vq_worker_main(arg);
    return 0;
}
static int vq_thread_create(vq_thread_t *t, void *arg) {
    *t = CreateThread(NULL, 0, vq_worker_trampoline, arg, 0, NULL);
    return (*t == NULL) ? -1 : 0;
}
static void vq_thread_join(vq_thread_t *t) {
    if (*t != NULL) {
        WaitForSingleObject(*t, INFINITE);
        CloseHandle(*t);
        *t = NULL;
    }
}
#else
typedef pthread_t vq_thread_t;
typedef pthread_mutex_t vq_mutex_t;
typedef sem_t vq_sem_t;

static void vq_mutex_init(vq_mutex_t *m) { pthread_mutex_init(m, NULL); }
static void vq_mutex_destroy(vq_mutex_t *m) { pthread_mutex_destroy(m); }
static void vq_mutex_lock(vq_mutex_t *m) { pthread_mutex_lock(m); }
static void vq_mutex_unlock(vq_mutex_t *m) { pthread_mutex_unlock(m); }

static void vq_sem_init(vq_sem_t *s) { sem_init(s, 0, 0); }
static void vq_sem_destroy(vq_sem_t *s) { sem_destroy(s); }
static void vq_sem_post(vq_sem_t *s) { sem_post(s); }
static void vq_sem_wait(vq_sem_t *s) { sem_wait(s); }
static void vq_sem_trywait(vq_sem_t *s) { sem_trywait(s); }

static void *vq_worker_main(void *arg);
static int vq_thread_create(vq_thread_t *t, void *arg) {
    return pthread_create(t, NULL, vq_worker_main, arg);
}
static void vq_thread_join(vq_thread_t *t) { pthread_join(*t, NULL); }
#endif

/* ── console / print no-op（对齐 iOS setupBridge）────────────────────────── */

static JSValue vq_console_noop(JSContext *ctx, JSValueConst this_val,
                               int argc, JSValueConst *argv) {
    return JS_UNDEFINED;
}

static void vq_register_console(JSContext *ctx) {
    JSValue global = JS_GetGlobalObject(ctx);
    JSValue console = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, console, "log",
                      JS_NewCFunction(ctx, vq_console_noop, "log", 1));
    JS_SetPropertyStr(ctx, console, "error",
                      JS_NewCFunction(ctx, vq_console_noop, "error", 1));
    JS_SetPropertyStr(ctx, global, "console", console);
    JS_SetPropertyStr(ctx, global, "print",
                      JS_NewCFunction(ctx, vq_console_noop, "print", 1));
    JS_FreeValue(ctx, global);
    /* console / print 已由 global 对象持有，不得再单独释放（避免 use-after-free） */
}

/* ── runtime 内核结构 ───────────────────────────────────────────────────── */

typedef struct VqRuntime {
    JSRuntime *rt;
    JSContext *ctx;

    /* worker（eval 执行线程，http 等待不被 isolate 阻塞的关键） */
    int worker_started;
    int quit;
    char *script;        /* 待执行脚本（submit → worker） */
    char *result;        /* eval 结果堆缓冲（worker → Dart take） */
    int result_ready;
    int busy;            /* worker 正在 eval（同步 vq_eval 防御位） */

    /* 宿主桥（Dart listener） */
    VqHostCallback host_cb;

    /* HTTP 请求槽（worker ⇆ Dart 单飞：worker 阻塞等待期间槽独占） */
    int req_seq;         /* 请求序号发生器 */
    char *http_url;
    char *http_opts;
    int http_req_id;     /* 本次挂起请求的 id */
    char *http_response; /* Dart 回写的完整响应 JSON */
    int http_resolved;

    vq_thread_t worker;
    vq_mutex_t lock;
    vq_sem_t job_sem;    /* Dart → worker：有新任务 */
    vq_sem_t http_sem;   /* Dart → worker：http 已回写 */
} VqRuntime;

static char *vq_strdup(const char *s) {
    if (s == NULL) return NULL;
    const size_t n = strlen(s) + 1;
    char *p = (char *)malloc(n);
    if (p != NULL) memcpy(p, s, n);
    return p;
}

static void vq_free_char(char *p) {
    free(p);
}

/* 毫秒睡眠（等待循环用） */
static void vq_sleep_ms(int ms) {
#if defined(_WIN32)
    Sleep((DWORD)ms);
#else
    struct timespec ts;
    ts.tv_sec = (time_t)(ms / 1000);
    ts.tv_nsec = (long)(ms % 1000) * 1000000L;
    nanosleep(&ts, NULL);
#endif
}

static int64_t vq_now_ms(void) {
#if defined(_WIN32)
    return (int64_t)GetTickCount64();
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
#endif
}

/* ── worker 主循环 ──────────────────────────────────────────────────────── */

static char *vq_eval_internal(JSContext *ctx, const char *script);
static void vq_register_http(JSContext *ctx);

static void *vq_worker_main(void *arg) {
    VqRuntime *r = (VqRuntime *)arg;
    /* 关键：重置栈深度检查基址（QuickJS 在 JS_NewRuntime 线程记录栈顶，
     * worker 线程栈位于完全不同的地址区域 —— 不重置则 js_check_stack_overflow
     * 对任何 eval 直接误判 stack overflow，脚本全量抛异常）。 */
    JS_UpdateStackTop(r->rt);
    while (1) {
        vq_sem_wait(&r->job_sem);
        vq_mutex_lock(&r->lock);
        if (r->quit) {
            vq_mutex_unlock(&r->lock);
            break;
        }
        char *script = r->script;
        r->script = NULL;
        r->busy = 1;
        vq_mutex_unlock(&r->lock);

        char *result = NULL;
        if (script != NULL) {
            /* eval 期间不持锁：worker 独占 JSContext；http 等待需放锁 */
            result = vq_eval_internal(r->ctx, script); /* 堆缓冲，直接接管 */
            vq_free_char(script);
        }

        vq_mutex_lock(&r->lock);
        r->busy = 0;
        if (r->result != NULL) free(r->result); /* 上一结果未被取走（防御） */
        r->result = result;
        r->result_ready = (result != NULL);
        const int quitting = r->quit;
        vq_mutex_unlock(&r->lock);

        /* 通知 Dart：eval 完成（listener 投递，不阻塞） */
        if (!quitting && r->host_cb != NULL) {
            r->host_cb(r, 1, 0, NULL, NULL);
        }
        if (quitting) break;
    }
    return NULL;
}

/* ── 运行时 / 上下文 ────────────────────────────────────────────────────── */

void *vq_create_runtime(void) {
    VqRuntime *r = (VqRuntime *)calloc(1, sizeof(VqRuntime));
    if (r == NULL) return NULL;
    r->rt = JS_NewRuntime();
    if (r->rt == NULL) {
        free(r);
        return NULL;
    }
    vq_mutex_init(&r->lock);
    vq_sem_init(&r->job_sem);
    vq_sem_init(&r->http_sem);
    return r; /* 对外句柄即 VqRuntime*（opaque） */
}

void *vq_create_context(void *rt) {
    VqRuntime *r = (VqRuntime *)rt;
    if (r == NULL || r->rt == NULL) return NULL;
    JSContext *ctx = JS_NewContext(r->rt);
    if (ctx != NULL) {
        vq_register_console(ctx);
        vq_register_http(ctx); /* http/req 全局桥（prelude 据此派生 req 别名） */
        JS_SetContextOpaque(ctx, r); /* http C 函数回取 VqRuntime* */
        r->ctx = ctx;
    }
    return ctx;
}

void vq_free_runtime(void *rt) {
    VqRuntime *r = (VqRuntime *)rt;
    if (r == NULL) return;

    /* 停 worker：置 quit → 唤醒（若 worker 在 http 等待中会先中断等待、
     * 完成当前 eval，再取到 quit 信号退出）。Dart 侧约定 free 前无
     * in-flight eval，实际 join 立即返回。 */
    vq_mutex_lock(&r->lock);
    r->quit = 1;
    vq_mutex_unlock(&r->lock);
    if (r->worker_started) {
        vq_sem_post(&r->job_sem);
        vq_thread_join(&r->worker);
    }
    vq_sem_destroy(&r->job_sem);
    vq_sem_destroy(&r->http_sem);
    vq_mutex_destroy(&r->lock);

    if (r->rt != NULL) {
        JS_RunGC(r->rt);       /* 先手动 GC，清理所有悬空对象 */
        JS_FreeRuntime(r->rt); /* 再安全释放 runtime */
    }
    vq_free_char(r->script);
    vq_free_char(r->result);
    vq_free_char(r->http_url);
    vq_free_char(r->http_opts);
    vq_free_char(r->http_response);
    free(r);
}

void vq_free_context(void *ctx) {
    if (ctx != NULL) {
        JS_FreeContext((JSContext *)ctx);
    }
}

/* ── 脚本执行 ───────────────────────────────────────────────────────────── */

/* eval 执行（返回堆缓冲，调用方 free；返回内容为 JSON 或异常消息）。
 *
 * 关键：必须**先复制** JS_ToCString 结果再 JS_FreeValue/JS_FreeCString ——
 * 短字符串（≤14 字节 ASCII，如 "2"、"object"）的 ToCString 指针直接指向
 * JSString 内联数据，FreeValue 会使引用计数归零并释放该内存，先返回后
 * 复制是 use-after-free（worker 桥首测 1+1 返回空串即此因）。 */
static char *vq_eval_internal(JSContext *ctx, const char *script) {
    JSValue result = JS_Eval(ctx, script, strlen(script), "<vbox-eval>",
                             JS_EVAL_TYPE_GLOBAL);
    char *out = NULL;
    if (JS_IsException(result)) {
        JSValue exception = JS_GetException(ctx);
        const char *str = JS_ToCString(ctx, exception);
        out = vq_strdup(str == NULL ? "" : str);
        JS_FreeCString(ctx, str);
        JS_FreeValue(ctx, exception);
        JS_FreeValue(ctx, result);
        return out; /* 异常消息：Error / TypeError / ... 前缀 */
    }
    const char *str = JS_ToCString(ctx, result);
    out = vq_strdup(str == NULL ? "" : str);
    JS_FreeCString(ctx, str);
    JS_FreeValue(ctx, result);
    return out;
}

/* 结果为堆缓冲（vq_eval_internal 已复制）；Dart 复制后调 vq_free_buffer 释放。
 * （vq_free_string 已废弃为 no-op：无法区分堆指针与 JS 内部指针。） */
const char *vq_eval(void *ctx, const char *script) {
    JSContext *js_ctx = (JSContext *)ctx;
    VqRuntime *r =
        (VqRuntime *)JS_GetContextOpaque(js_ctx);
    /* 防御：worker 正在 eval 时拒绝并发同步 eval（Dart 侧约定串行，
     * 此分支仅为异常调用兜底，返回错误消息而非崩溃）。 */
    if (r != NULL) {
        vq_mutex_lock(&r->lock);
        const int busy = r->busy;
        vq_mutex_unlock(&r->lock);
        if (busy) return vq_strdup("Error: QuickJS runtime busy（eval 与 evalAsync 并发）");
    }
    return vq_eval_internal(js_ctx, script);
}

/* 已废弃（no-op）：eval 结果改走堆缓冲 + vq_free_buffer。保留符号以兼容
 * 旧版 Dart 侧二进制（其 eval 调 vq_free_string 不再是正确释放路径，
 * 需同步升级 Dart 侧；见 quickjs_ffi.dart eval 的 _freeBuffer 优先分派）。 */
void vq_free_string(void *ctx, const char *str) {
    (void)ctx;
    (void)str;
}

void vq_free_buffer(void *p) {
    free(p);
}

/* ── 宿主桥：eval 提交 / 结果取回 ───────────────────────────────────────── */

void vq_set_host_bridge(void *rt, VqHostCallback cb) {
    VqRuntime *r = (VqRuntime *)rt;
    if (r != NULL) r->host_cb = cb;
}

int vq_eval_submit(void *rt, const char *script) {
    VqRuntime *r = (VqRuntime *)rt;
    if (r == NULL || script == NULL) return 0;
    vq_mutex_lock(&r->lock);
    if (r->script != NULL) { /* 上一个任务尚未被 worker 取走 */
        vq_mutex_unlock(&r->lock);
        return 0;
    }
    r->script = vq_strdup(script);
    if (r->script == NULL) {
        vq_mutex_unlock(&r->lock);
        return 0;
    }
    if (!r->worker_started) {
        if (vq_thread_create(&r->worker, r) != 0) {
            vq_free_char(r->script);
            r->script = NULL;
            vq_mutex_unlock(&r->lock);
            return 0;
        }
        r->worker_started = 1;
    }
    vq_mutex_unlock(&r->lock);
    vq_sem_post(&r->job_sem);
    return 1;
}

const char *vq_eval_take_result(void *rt) {
    VqRuntime *r = (VqRuntime *)rt;
    if (r == NULL) return NULL;
    vq_mutex_lock(&r->lock);
    char *out = r->result;
    r->result = NULL;
    r->result_ready = 0;
    vq_mutex_unlock(&r->lock);
    return out; /* Dart 复制后调 vq_free_buffer */
}

/* ── HTTP 桥（worker 线程执行的 JS C 函数）────────────────────────────── */

/* 失败对象（对齐 iOS 字典形状：ok/status/content/url/error/headers）。 */
static JSValue vq_http_fail(JSContext *ctx, const char *url, const char *err) {
    JSValue obj = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, obj, "ok", JS_FALSE);
    JS_SetPropertyStr(ctx, obj, "status", JS_NewInt32(ctx, 0));
    JS_SetPropertyStr(ctx, obj, "content", JS_NewString(ctx, ""));
    JS_SetPropertyStr(ctx, obj, "url", JS_NewString(ctx, url == NULL ? "" : url));
    JS_SetPropertyStr(ctx, obj, "headers", JS_NewObject(ctx));
    JS_SetPropertyStr(ctx, obj, "error",
                      JS_NewString(ctx, err == NULL ? "http bridge unavailable" : err));
    return obj;
}

/* Dart 回写等待上限（Dart HTTP 自身有超时，此为防挂死兜底）。 */
#define VQ_HTTP_WAIT_MS 45000
#define VQ_HTTP_POLL_MS 25

static JSValue vq_http_func(JSContext *ctx, JSValueConst this_val,
                            int argc, JSValueConst *argv) {
    JSContext *js_ctx = (JSContext *)ctx;
    VqRuntime *r = (VqRuntime *)JS_GetContextOpaque(js_ctx);

    /* ① URL（对齐 iOS：缺参抛 TypeError） */
    const char *url_c = NULL;
    if (argc >= 1) url_c = JS_ToCString(js_ctx, argv[0]);
    if (url_c == NULL) {
        return JS_ThrowTypeError(js_ctx, "http() needs at least 1 argument");
    }

    /* ② options：对象 → JSON 字符串；字符串 → 直用（对齐 iOS optionsStr 约定） */
    char *opts_heap = NULL;
    const char *opts_c = NULL;
    if (argc >= 2 && !JS_IsUndefined(argv[1]) && !JS_IsNull(argv[1])) {
        if (JS_IsString(argv[1])) {
            opts_c = JS_ToCString(js_ctx, argv[1]);
        } else {
            JSValue s = JS_JSONStringify(js_ctx, argv[1], JS_UNDEFINED, JS_UNDEFINED);
            if (!JS_IsException(s)) {
                opts_c = JS_ToCString(js_ctx, s);
                if (opts_c != NULL) opts_heap = vq_strdup(opts_c);
                JS_FreeCString(js_ctx, opts_c);
                opts_c = NULL;
                JS_FreeValue(js_ctx, s);
            } else {
                JS_FreeValue(js_ctx, s); /* 序列化失败 → 无 options（默认 GET） */
            }
        }
    }

    if (r == NULL || r->host_cb == NULL) {
        if (opts_heap != NULL) vq_free_char(opts_heap);
        if (url_c != NULL) JS_FreeCString(js_ctx, url_c);
        return vq_http_fail(js_ctx, NULL, "宿主桥未注册（Dart 侧未 set_host_bridge）");
    }

    /* ③ 登记请求槽并通知 Dart（listener 投递；worker 随后阻塞等待） */
    int my_id;
    char *url_owned = vq_strdup(url_c);
    char *opts_owned = opts_heap != NULL ? opts_heap : (opts_c != NULL ? vq_strdup(opts_c) : NULL);
    if (url_c != NULL) JS_FreeCString(js_ctx, url_c);

    vq_mutex_lock(&r->lock);
    vq_free_char(r->http_url);
    vq_free_char(r->http_opts);
    r->http_url = url_owned;
    r->http_opts = opts_owned;
    r->http_req_id = ++r->req_seq;
    r->http_resolved = 0;
    my_id = r->http_req_id;
    const VqHostCallback cb = r->host_cb;
    vq_mutex_unlock(&r->lock);

    /* 用局部持有的指针通知 Dart（r->http_url 解锁后读是数据竞争；
     * 两指针在等待期间不被释放——worker 阻塞、Dart 回写只写 http_response） */
    cb(r, 2, my_id, url_owned, opts_owned);

    /* ④ 同步等待 Dart 回写（iOS 信号量等待的等价物；有界防挂死） */
    const int64_t deadline = vq_now_ms() + VQ_HTTP_WAIT_MS;
    char *response = NULL;
    int quitting = 0;
    while (1) {
        vq_mutex_lock(&r->lock);
        const int resolved = (r->http_resolved && r->http_req_id == my_id);
        quitting = r->quit;
        if (resolved) {
            response = r->http_response;
            r->http_response = NULL;
        }
        vq_mutex_unlock(&r->lock);
        if (resolved || quitting) break;
        if (vq_now_ms() > deadline) break;
        vq_sem_trywait(&r->http_sem); /* 唤醒信号（resolved 轮询为主，信号消抖） */
        vq_sleep_ms(VQ_HTTP_POLL_MS);
    }

    if (response == NULL) {
        return vq_http_fail(js_ctx, r->http_url,
                            quitting ? "请求被取消" : "请求超时（bridge 等待上限）");
    }

    /* ⑤ 响应 JSON → JS 对象（对齐 iOS JSSpiderEngine 字典返回） */
    JSValue obj = JS_ParseJSON(js_ctx, response, strlen(response), "<http-resp>");
    vq_free_char(response);
    if (JS_IsException(obj)) {
        JSValue exc = JS_GetException(js_ctx);
        JS_FreeValue(js_ctx, exc);
        return vq_http_fail(js_ctx, r->http_url, "响应 JSON 解析失败");
    }
    return obj;
}

/* http/req 全局注册（createContext 时随 console 一起装；prelude 的
 * `if (typeof g.http === 'function')` 分支据此生效并派生 req 别名）。 */
static void vq_register_http(JSContext *ctx) {
    JSValue global = JS_GetGlobalObject(ctx);
    JS_SetPropertyStr(ctx, global, "http",
                      JS_NewCFunction(ctx, vq_http_func, "http", 2));
    JS_FreeValue(ctx, global);
    /* 函数已由 global 持有，不单独释放 */
}

int vq_http_complete(void *rt, int req_id, const char *response_json) {
    VqRuntime *r = (VqRuntime *)rt;
    if (r == NULL || response_json == NULL) return 0;
    vq_mutex_lock(&r->lock);
    if (req_id != r->http_req_id || r->http_resolved) {
        vq_mutex_unlock(&r->lock);
        return 0; /* 过期请求（超时后迟到回写）/ 重复回写 */
    }
    vq_free_char(r->http_response);
    r->http_response = vq_strdup(response_json);
    r->http_resolved = (r->http_response != NULL);
    vq_mutex_unlock(&r->lock);
    vq_sem_post(&r->http_sem);
    return r->http_resolved ? 1 : 0;
}
