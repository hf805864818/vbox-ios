#import "quickjs.h"
#import "quickjs-libc.h"
#import <Foundation/Foundation.h>

/// Objective-C 包装层，使 Swift 可以通过桥接头调用 QuickJS
/// 因为 Swift 无法直接调用可变参数的 C 函数

JSRuntime* _Nonnull QJSBridge_createRuntime(void) {
    return JS_NewRuntime();
}

JSContext* _Nonnull QJSBridge_createContext(JSRuntime* _Nonnull rt) {
    JSContext* ctx = JS_NewContext(rt);
    js_std_add_helpers(ctx, 0, NULL);
    return ctx;
}

void QJSBridge_freeRuntime(JSRuntime* _Nonnull rt) {
    JS_FreeRuntime(rt);
}

void QJSBridge_freeContext(JSContext* _Nonnull ctx) {
    JS_FreeContext(ctx);
}

const char* _Nullable QJSBridge_eval(JSContext* _Nonnull ctx, const char* _Nonnull script) {
    JSValue result = JS_Eval(ctx, script, strlen(script), "<eval>", JS_EVAL_TYPE_GLOBAL);
    
    if (JS_IsException(result)) {
        JSValue exception = JS_GetException(ctx);
        const char* str = JS_ToCString(ctx, exception);
        JS_FreeValue(ctx, exception);
        JS_FreeValue(ctx, result);
        return str;
    }
    
    const char* str = JS_ToCString(ctx, result);
    JS_FreeValue(ctx, result);
    return str;
}

void QJSBridge_freeString(JSContext* _Nonnull ctx, const char* _Nonnull str) {
    JS_FreeCString(ctx, str);
}
