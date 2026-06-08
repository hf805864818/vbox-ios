#import "QuickJSBridge.h"
#import "quickjs.h"
#import "quickjs-libc.h"
#import <Foundation/Foundation.h>
#import <string.h>

void* QJSBridge_createRuntime(void) {
    return JS_NewRuntime();
}

void* QJSBridge_createContext(void* rt) {
    JSContext* ctx = JS_NewContext((JSRuntime*)rt);
    // js_std_add_helpers(ctx, 0, NULL); // Removed - may not be available in static lib
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

// ====== HTTP 桥接 — 简单版 ======
// JS 侧调用 http(urlStr, optionsStr)
// optionsStr 是 JSON 字符串: {"headers":{"key":"val"},"method":"GET","data":"...","timeout":10}
// 返回 JSON 字符串: {"ok":true/false,"status":200,"content":"...","error":"..."}

static JSValue js_http_func(JSContext *ctx, JSValueConst this_val,
                             int argc, JSValueConst *argv) {
    @autoreleasepool {
        if (argc < 1) return JS_ThrowTypeError(ctx, "http() needs at least 1 argument");
        
        // 获取 URL
        const char* url_cstr = JS_ToCString(ctx, argv[0]);
        NSString* urlStr = [NSString stringWithUTF8String:url_cstr];
        JS_FreeCString(ctx, url_cstr);
        if (!urlStr) return JS_NULL;
        
        NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
        [request setTimeoutInterval:8];
        
        // 解析 options JSON 字符串（第二个参数）
        if (argc >= 2 && JS_IsString(argv[1])) {
            const char* opts_cstr = JS_ToCString(ctx, argv[1]);
            NSString* optsStr = [NSString stringWithUTF8String:opts_cstr];
            JS_FreeCString(ctx, opts_cstr);
            
            NSData* optsData = [optsStr dataUsingEncoding:NSUTF8StringEncoding];
            if (optsData) {
                NSDictionary* opts = [NSJSONSerialization JSONObjectWithData:optsData options:0 error:nil];
                if ([opts isKindOfClass:[NSDictionary class]]) {
                    // headers
                    NSDictionary* headers = opts[@"headers"];
                    if ([headers isKindOfClass:[NSDictionary class]]) {
                        for (NSString* key in headers) {
                            [request setValue:headers[key] forHTTPHeaderField:key];
                        }
                    }
                    // method
                    NSString* method = opts[@"method"];
                    if (method) request.HTTPMethod = [method uppercaseString];
                    // data
                    NSString* data = opts[@"data"];
                    if (data) request.HTTPBody = [data dataUsingEncoding:NSUTF8StringEncoding];
                    // timeout
                    NSNumber* timeout = opts[@"timeout"];
                    if (timeout) request.timeoutInterval = [timeout doubleValue];
                }
            }
        }
        
        // 默认 UA
        if (![request valueForHTTPHeaderField:@"User-Agent"]) {
            [request setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15"
                forHTTPHeaderField:@"User-Agent"];
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
        
        // 构建 JSON 结果
        NSMutableDictionary* result = [NSMutableDictionary dictionary];
        BOOL ok = (connError == nil && httpResp.statusCode >= 200 && httpResp.statusCode < 400);
        result[@"ok"] = @(ok);
        result[@"status"] = @(httpResp ? httpResp.statusCode : 0);
        
        if (respData) {
            NSString* content = [[NSString alloc] initWithData:respData encoding:NSUTF8StringEncoding];
            if (!content) content = [[NSString alloc] initWithData:respData encoding:NSASCIIStringEncoding];
            result[@"content"] = content ?: @"";
        } else {
            result[@"content"] = @"";
        }
        
        if (connError) {
            result[@"error"] = connError.localizedDescription;
        }
        
        // headers
        NSMutableDictionary* respHeaders = [NSMutableDictionary dictionary];
        if (httpResp) {
            for (NSString* key in httpResp.allHeaderFields) {
                id val = httpResp.allHeaderFields[key];
                if ([val isKindOfClass:[NSString class]]) {
                    respHeaders[key] = val;
                }
            }
        }
        result[@"headers"] = respHeaders;
        
        NSData* jsonData = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
        NSString* jsonStr = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        
        return JS_NewString(ctx, [jsonStr UTF8String]);
    }
}

// 注册 http() 到全局 — JS 侧调用: http(url, JSON.stringify(options))
void QJSBridge_registerHTTP(void* ctx) {
    JSValue global = JS_GetGlobalObject((JSContext*)ctx);
    JSValue func = JS_NewCFunction((JSContext*)ctx, js_http_func, "http", 2);
    JS_SetPropertyStr((JSContext*)ctx, global, "http", func);
    JS_FreeValue((JSContext*)ctx, global);
}
