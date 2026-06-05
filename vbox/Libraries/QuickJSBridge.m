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

// ====== HTTP 桥接 ======

// JS 侧的 http(url, options) 调用此函数
static JSValue js_http_func(JSContext *ctx, JSValueConst this_val,
                             int argc, JSValueConst *argv, int magic) {
    @autoreleasepool {
        if (argc < 1) return JS_ThrowTypeError(ctx, "http() 需要至少1个参数");
        
        // 获取 URL
        const char* url_cstr = JS_ToCString(ctx, argv[0]);
        NSString* urlStr = [NSString stringWithUTF8String:url_cstr];
        JS_FreeCString(ctx, url_cstr);
        
        if (!urlStr) return JS_NULL;
        
        // 构建请求
        NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
        [request setTimeoutInterval:15];
        
        // 解析 options（第二个参数）
        if (argc >= 2 && JS_IsObject(argv[1])) {
            JSValue headersVal = JS_GetPropertyStr(ctx, argv[1], "headers");
            if (JS_IsObject(headersVal)) {
                // 遍历 headers 对象
                JSPropertyEnum* tab;
                uint32_t len;
                JS_GetOwnPropertyNames(ctx, &tab, &len, headersVal, JS_GPN_STRINGIFY | JS_GPN_ENUM_ONLY);
                for (uint32_t i = 0; i < len; i++) {
                    JSValue val = JS_GetProperty(ctx, headersVal, tab[i].prop);
                    if (JS_IsString(val)) {
                        const char* v = JS_ToCString(ctx, val);
                        [request setValue:[NSString stringWithUTF8String:v]
                            forHTTPHeaderField:[NSString stringWithFormat:@"%s", tab[i].atom]];
                        JS_FreeCString(ctx, v);
                    }
                    JS_FreeValue(ctx, val);
                    JS_FreePropertyEnum(ctx, tab + i);
                }
                free(tab);
            }
            JS_FreeValue(ctx, headersVal);
            
            // 默认 UA
            if (![request valueForHTTPHeaderField:@"User-Agent"]) {
                [request setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15"
                    forHTTPHeaderField:@"User-Agent"];
            }
            
            // method
            JSValue methodVal = JS_GetPropertyStr(ctx, argv[1], "method");
            if (JS_IsString(methodVal)) {
                const char* m = JS_ToCString(ctx, methodVal);
                request.HTTPMethod = [NSString stringWithUTF8String:m];
                JS_FreeCString(ctx, m);
            }
            JS_FreeValue(ctx, methodVal);
            
            // data (POST body)
            JSValue dataVal = JS_GetPropertyStr(ctx, argv[1], "data");
            if (JS_IsString(dataVal)) {
                const char* d = JS_ToCString(ctx, dataVal);
                request.HTTPBody = [[NSString stringWithUTF8String:d] dataUsingEncoding:NSUTF8StringEncoding];
                JS_FreeCString(ctx, d);
            }
            JS_FreeValue(ctx, dataVal);
            
            // timeout
            JSValue timeoutVal = JS_GetPropertyStr(ctx, argv[1], "timeout");
            if (JS_IsNumber(timeoutVal)) {
                double t;
                JS_ToFloat64(ctx, &t, timeoutVal);
                if (t > 0) request.timeoutInterval = t;
            }
            JS_FreeValue(ctx, timeoutVal);
        }
        
        // 同步请求
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        __block NSData* respData = nil;
        __block NSHTTPURLResponse* httpResp = nil;
        __block NSError* connError = nil;
        
        NSURLSession* session = [NSURLSession sharedSession];
        NSURLSessionDataTask* task = [session dataTaskWithRequest:request
            completionHandler:^(NSData* data, NSURLResponse* resp, NSError* err) {
                respData = data;
                httpResp = (NSHTTPURLResponse*)resp;
                connError = err;
                dispatch_semaphore_signal(sem);
            }];
        [task resume];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)((request.timeoutInterval + 2) * NSEC_PER_SEC)));
        
        // 构建返回结果 { ok, status, content, headers }
        JSValue result = JS_NewObject(ctx);
        
        BOOL ok = (connError == nil && httpResp.statusCode >= 200 && httpResp.statusCode < 400);
        JS_SetPropertyStr(ctx, result, "ok", JS_NewBool(ctx, ok));
        JS_SetPropertyStr(ctx, result, "status", JS_NewInt32(ctx, (int32_t)httpResp.statusCode));
        
        if (respData) {
            NSString* content = [[NSString alloc] initWithData:respData encoding:NSUTF8StringEncoding];
            if (!content) content = [[NSString alloc] initWithData:respData encoding:NSASCIIStringEncoding];
            if (!content) content = @"";
            JS_SetPropertyStr(ctx, result, "content",
                JS_NewString(ctx, [content UTF8String]));
        } else {
            JS_SetPropertyStr(ctx, result, "content", JS_NewString(ctx, ""));
        }
        
        if (connError) {
            JS_SetPropertyStr(ctx, result, "error",
                JS_NewString(ctx, [[connError localizedDescription] UTF8String]));
        }
        
        // headers
        JSValue respHeaders = JS_NewObject(ctx);
        if (httpResp) {
            for (NSString* key in httpResp.allHeaderFields) {
                id val = httpResp.allHeaderFields[key];
                if ([val isKindOfClass:[NSString class]]) {
                    JS_SetPropertyStr(ctx, respHeaders, [key UTF8String],
                        JS_NewString(ctx, [(NSString*)val UTF8String]));
                }
            }
        }
        JS_SetPropertyStr(ctx, result, "headers", respHeaders);
        
        return result;
    }
}

// 注册 http() 到全局
void QJSBridge_registerHTTP(void* ctx) {
    JSValue global = JS_GetGlobalObject((JSContext*)ctx);
    JSValue func = JS_NewCFunctionMagic((JSContext*)ctx, js_http_func, "http", 2, JS_CFUNC_generic_magic, 0);
    JS_SetPropertyStr((JSContext*)ctx, global, "http", func);
    JS_FreeValue((JSContext*)ctx, global);
}
