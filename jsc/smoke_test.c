/*
 * vbox JSC wrapper 冒烟测试（批次 Q · build-jsc.yml 内嵌步骤）。
 *
 * 不依赖 Dart/Flutter：直接链 jsc/wrapper.c 验证 vj_* ABI 语义——
 *   1. eval 表达式取回结果字符串（"1+1" → "2"）
 *   2. JS 异常消息带 Error/TypeError 前缀（契约 §5 错误检测）
 *   3. 空结果（undefined 字符串化）不崩溃
 *   4. 生命周期：freeContext → freeRuntime 无泄漏崩溃
 *
 * 编译（macOS，repo 根目录）：
 *   clang -O2 jsc/smoke_test.c jsc/wrapper.c -framework JavaScriptCore -o /tmp/smoke
 * 编译（Linux host 语法验证，无需 JSC 运行库）：
 *   gcc -std=c99 -fsyntax-only -I jsc/include jsc/smoke_test.c
 */
#include <stdio.h>
#include <string.h>

#include "wrapper.h"

static int failures = 0;

static void check(const char *name, int ok) {
    printf("%s %s\n", ok ? "✅" : "❌", name);
    if (!ok) failures++;
}

int main(void) {
    void *rt = vj_create_runtime();
    check("vj_create_runtime 哑元非 NULL", rt != NULL);

    void *ctx = vj_create_context(rt);
    check("vj_create_context 非 NULL", ctx != NULL);

    /* ① 表达式求值取回结果字符串 */
    const char *r = vj_eval(ctx, "1+1");
    check("eval '1+1' → '2'", r != NULL && strcmp(r, "2") == 0);
    if (r) vj_free_string(ctx, r);

    /* ② JS 异常 → TypeError 前缀（契约 §5） */
    const char *err = vj_eval(ctx, "null.foo");
    check("异常带 TypeError 前缀", err != NULL && strstr(err, "TypeError") != NULL);
    if (err) vj_free_string(ctx, err);

    /* ③ undefined 字符串化（非 NULL 非 crash） */
    const char *undef = vj_eval(ctx, "undefined");
    check("eval 'undefined' → 'undefined'",
          undef != NULL && strcmp(undef, "undefined") == 0);
    if (undef) vj_free_string(ctx, undef);

    /* ④ 空入参安全 */
    check("NULL script 安全", vj_eval(ctx, NULL) == NULL);

    /* ⑤ 生命周期顺序：先 context 后 runtime（对齐 vq_*） */
    vj_free_context(ctx);
    vj_free_runtime(rt);
    check("free 顺序无崩溃", 1);

    printf(failures == 0 ? "SMOKE PASS\n" : "SMOKE FAIL (%d)\n", failures);
    return failures == 0 ? 0 : 1;
}
