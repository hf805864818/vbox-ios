#import "quickjs.h"
#import "quickjs-libc.h"
#import <Foundation/Foundation.h>

void* QJSBridge_createRuntime(void) {
    return JS_NewRuntime();
}

void* QJSBridge_createContext(void* rt) {
    JSContext* ctx = JS_NewContext((JSRuntime*)rt);
    js_std_add_helpers(ctx, 0, NULL);
    return ctx;
}

void QJSBridge_freeRuntime(void* rt) {
    JS_FreeRuntime((JSRuntime*)rt);
}

void QJSBridge_freeContext(void* ctx) {
    JS_FreeContext((JSContext*)ctx);
}

const char* QJSBridge_eval(void* ctx, const char* script) {
    JSValue result = JS_Eval((JSContext*)ctx, script, strlen(script), "<eval>", JS_EVAL_TYPE_GLOBAL);
    
    if (JS_IsException(result)) {
        JSValue exception = JS_GetException((JSContext*)ctx);
        const char* str = JS_ToCString((JSContext*)ctx, exception);
        JS_FreeValue((JSContext*)ctx, exception);
        JS_FreeValue((JSContext*)ctx, result);
        return str;
    }
    
    const char* str = JS_ToCString((JSContext*)ctx, result);
    JS_FreeValue((JSContext*)ctx, result);
    return str;
}

void QJSBridge_freeString(void* ctx, const char* str) {
    JS_FreeCString((JSContext*)ctx, str);
}
