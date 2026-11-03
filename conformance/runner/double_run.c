/*
 * vbox 双引擎双跑 harness（批次 Q · Q-06，conformance double-run）。
 *
 * 引擎无关：经编译期宏 API_PREFIX 选择链接 quickjs/wrapper.c（vq_*）还是
 * jsc/wrapper.c（vj_*），二者 ABI 形状一致（Q-05 验收口径）。
 * 从 stdin 逐行读取 JS 脚本（每行一条），在**同一上下文**中顺序执行，
 * 每行输出 `<行号>=<结果字符串>`；脚本含副作用（如定义 __JS_SPIDER__）
 * 可跨行累积。
 *
 * 编译（QuickJS，Linux/macOS）：
 *   cc -O2 -DAPI_PREFIX=vq_ double_run.c quickjs/wrapper.c \
 *      quickjs/quickjs-2024-01-13/quickjs.c ...（见 double_run.py）
 * 编译（JSC，macOS）：
 *   clang -O2 -DAPI_PREFIX=vj_ double_run.c jsc/wrapper.c \
 *      -framework JavaScriptCore
 */
#include <stdio.h>
#include <string.h>

#define CAT_IMPL(a, b) a##b
#define CAT(a, b) CAT_IMPL(a, b)

#ifndef API_PREFIX
#define API_PREFIX vq_
#endif

void *CAT(API_PREFIX, create_runtime)(void);
void *CAT(API_PREFIX, create_context)(void *);
void CAT(API_PREFIX, free_runtime)(void *);
void CAT(API_PREFIX, free_context)(void *);
const char *CAT(API_PREFIX, eval)(void *, const char *);
void CAT(API_PREFIX, free_string)(void *, const char *);

int main(void) {
    void *rt = CAT(API_PREFIX, create_runtime)();
    void *ctx = CAT(API_PREFIX, create_context)(rt);
    if (ctx == NULL) {
        fprintf(stderr, "context create failed\n");
        return 2;
    }

    char line[8192];
    int idx = 0;
    while (fgets(line, sizeof line, stdin) != NULL) {
        size_t n = strlen(line);
        while (n > 0 && (line[n - 1] == '\n' || line[n - 1] == '\r')) {
            line[--n] = '\0';
        }
        const char *r = CAT(API_PREFIX, eval)(ctx, line);
        printf("%d=%s\n", idx, r != NULL ? r : "");
        if (r != NULL) {
            CAT(API_PREFIX, free_string)(ctx, r);
        }
        idx++;
    }

    CAT(API_PREFIX, free_context)(ctx);
    CAT(API_PREFIX, free_runtime)(rt);
    return 0;
}