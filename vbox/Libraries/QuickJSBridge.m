#import "QuickJSBridge.h"
#import "quickjs.h"
#import "quickjs-libc.h"
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonCrypto.h>
#import <Security/Security.h>
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
    JSRuntime* runtime = (JSRuntime*)rt;
    if (runtime) {
        JS_RunGC(runtime);          // 先手动 GC，清理所有悬空对象
        JS_FreeRuntime(runtime);    // 再安全释放 runtime
    }
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

// ====== Crypto 桥接 — AES-CBC + MD5 + base64 ======

static JSValue js_aes_decrypt_func(JSContext *ctx, JSValueConst this_val,
                                    int argc, JSValueConst *argv) {
    if (argc < 2) return JS_ThrowTypeError(ctx, "aesDecrypt(encData, keyB64) needs 2 arguments");
    
    const char* enc_cstr = JS_ToCString(ctx, argv[0]);
    const char* key_cstr = JS_ToCString(ctx, argv[1]);
    NSString* encData = [NSString stringWithUTF8String:enc_cstr];
    NSString* keyB64 = [NSString stringWithUTF8String:key_cstr];
    JS_FreeCString(ctx, enc_cstr);
    JS_FreeCString(ctx, key_cstr);
    
    NSData* keyData = [[NSData alloc] initWithBase64EncodedString:keyB64 options:0];
    NSData* cipherData = [[NSData alloc] initWithBase64EncodedString:encData options:0];
    if (!keyData || !cipherData) return JS_NewString(ctx, "");
    
    size_t cryptLength = cipherData.length + kCCBlockSizeAES128;
    NSMutableData* cryptData = [NSMutableData dataWithLength:cryptLength];
    size_t numBytesDecrypted = 0;
    
    CCCryptorStatus status = CCCrypt(kCCDecrypt,
                                     kCCAlgorithmAES,
                                     kCCOptionPKCS7Padding,
                                     keyData.bytes, keyData.length,
                                     keyData.bytes,  // IV = key
                                     cipherData.bytes, cipherData.length,
                                     cryptData.mutableBytes, cryptLength,
                                     &numBytesDecrypted);
    
    if (status != kCCSuccess) return JS_NewString(ctx, "");
    cryptData.length = numBytesDecrypted;
    NSString* result = [[NSString alloc] initWithData:cryptData encoding:NSUTF8StringEncoding];
    return JS_NewString(ctx, result ? [result UTF8String] : "");
}

static JSValue js_md5_func(JSContext *ctx, JSValueConst this_val,
                            int argc, JSValueConst *argv) {
    if (argc < 1) return JS_NewString(ctx, "");
    const char* text_cstr = JS_ToCString(ctx, argv[0]);
    NSString* text = [NSString stringWithUTF8String:text_cstr];
    JS_FreeCString(ctx, text_cstr);
    
    NSData* data = [text dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_MD5_DIGEST_LENGTH];
    CC_MD5(data.bytes, (CC_LONG)data.length, digest);
    
    NSMutableString* hex = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return JS_NewString(ctx, [hex UTF8String]);
}

static JSValue js_b64_decode_func(JSContext *ctx, JSValueConst this_val,
                                   int argc, JSValueConst *argv) {
    if (argc < 1) return JS_NewString(ctx, "");
    const char* text_cstr = JS_ToCString(ctx, argv[0]);
    NSString* text = [NSString stringWithUTF8String:text_cstr];
    JS_FreeCString(ctx, text_cstr);
    
    NSData* data = [[NSData alloc] initWithBase64EncodedString:text options:0];
    if (!data) return JS_NewString(ctx, "");
    NSString* result = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return JS_NewString(ctx, result ? [result UTF8String] : "");
}

static JSValue js_b64_encode_func(JSContext *ctx, JSValueConst this_val,
                                   int argc, JSValueConst *argv) {
    if (argc < 1) return JS_NewString(ctx, "");
    const char* text_cstr = JS_ToCString(ctx, argv[0]);
    NSString* text = [NSString stringWithUTF8String:text_cstr];
    JS_FreeCString(ctx, text_cstr);
    
    NSData* data = [text dataUsingEncoding:NSUTF8StringEncoding];
    NSString* result = [data base64EncodedStringWithOptions:0];
    return JS_NewString(ctx, [result UTF8String]);
}

// ====== 新增 crypto 函数（仅新增，不修改已有函数） ======

// AES-ECB 解密 (base64密文, base64密钥 → UTF-8字符串)
static JSValue js_aes_decrypt_ecb_func(JSContext *ctx, JSValueConst this_val,
                                        int argc, JSValueConst *argv) {
    if (argc < 2) return JS_ThrowTypeError(ctx, "aesDecryptECB needs 2 arguments");
    
    const char* enc_cstr = JS_ToCString(ctx, argv[0]);
    const char* key_cstr = JS_ToCString(ctx, argv[1]);
    NSString* encDataB64 = [NSString stringWithUTF8String:enc_cstr];
    NSString* keyB64 = [NSString stringWithUTF8String:key_cstr];
    JS_FreeCString(ctx, enc_cstr);
    JS_FreeCString(ctx, key_cstr);
    
    NSData* keyData = [[NSData alloc] initWithBase64EncodedString:keyB64 options:0];
    NSData* cipherData = [[NSData alloc] initWithBase64EncodedString:encDataB64 options:0];
    if (!keyData || !cipherData) return JS_NewString(ctx, "");
    
    size_t cryptLength = cipherData.length + kCCBlockSizeAES128;
    NSMutableData* cryptData = [NSMutableData dataWithLength:cryptLength];
    size_t numBytesDecrypted = 0;
    
    CCCryptorStatus status = CCCrypt(kCCDecrypt,
                                     kCCAlgorithmAES,
                                     kCCOptionPKCS7Padding | kCCOptionECBMode,
                                     keyData.bytes, keyData.length,
                                     NULL,  // ECB 无 IV
                                     cipherData.bytes, cipherData.length,
                                     cryptData.mutableBytes, cryptLength,
                                     &numBytesDecrypted);
    
    if (status != kCCSuccess) return JS_NewString(ctx, "");
    cryptData.length = numBytesDecrypted;
    NSString* result = [[NSString alloc] initWithData:cryptData encoding:NSUTF8StringEncoding];
    return JS_NewString(ctx, result ? [result UTF8String] : "");
}

// SHA256 哈希 (文本 → hex字符串)
static JSValue js_sha256_func(JSContext *ctx, JSValueConst this_val,
                               int argc, JSValueConst *argv) {
    if (argc < 1) return JS_NewString(ctx, "");
    const char* text_cstr = JS_ToCString(ctx, argv[0]);
    NSString* text = [NSString stringWithUTF8String:text_cstr];
    JS_FreeCString(ctx, text_cstr);
    
    NSData* data = [text dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    
    NSMutableString* hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return JS_NewString(ctx, [hex UTF8String]);
}

// HMAC-SHA256 (key, message → base64字符串)
static JSValue js_hmac_sha256_func(JSContext *ctx, JSValueConst this_val,
                                    int argc, JSValueConst *argv) {
    if (argc < 2) return JS_NewString(ctx, "");
    const char* key_cstr = JS_ToCString(ctx, argv[0]);
    const char* msg_cstr = JS_ToCString(ctx, argv[1]);
    NSString* keyStr = [NSString stringWithUTF8String:key_cstr];
    NSString* msgStr = [NSString stringWithUTF8String:msg_cstr];
    JS_FreeCString(ctx, key_cstr);
    JS_FreeCString(ctx, msg_cstr);
    
    NSData* keyData = [keyStr dataUsingEncoding:NSUTF8StringEncoding];
    NSData* msgData = [msgStr dataUsingEncoding:NSUTF8StringEncoding];
    
    unsigned char hmac[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, keyData.bytes, keyData.length,
           msgData.bytes, msgData.length, hmac);
    
    NSData* hmacData = [NSData dataWithBytes:hmac length:CC_SHA256_DIGEST_LENGTH];
    NSString* result = [hmacData base64EncodedStringWithOptions:0];
    return JS_NewString(ctx, [result UTF8String]);
}

// RSA-SHA256 签名 (message, privateKeyBase64 → base64签名)
static JSValue js_rsa_sign_func(JSContext *ctx, JSValueConst this_val,
                                 int argc, JSValueConst *argv) {
    if (argc < 2) return JS_NewString(ctx, "");
    const char* msg_cstr = JS_ToCString(ctx, argv[0]);
    const char* key_cstr = JS_ToCString(ctx, argv[1]);
    NSString* message = [NSString stringWithUTF8String:msg_cstr];
    NSString* keyB64 = [NSString stringWithUTF8String:key_cstr];
    JS_FreeCString(ctx, msg_cstr);
    JS_FreeCString(ctx, key_cstr);
    
    // 清理 key（去除换行和空格）
    NSString* cleanKey = [keyB64 stringByReplacingOccurrencesOfString:@"\n" withString:@""];
    cleanKey = [cleanKey stringByReplacingOccurrencesOfString:@" " withString:@""];
    cleanKey = [cleanKey stringByReplacingOccurrencesOfString:@"\r" withString:@""];
    
    NSData* keyData = [[NSData alloc] initWithBase64EncodedString:cleanKey options:0];
    if (!keyData) return JS_NewString(ctx, "");
    
    NSData* msgData = [message dataUsingEncoding:NSUTF8StringEncoding];
    
    NSDictionary* attributes = @{
        (__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeRSA,
        (__bridge id)kSecAttrKeyClass: (__bridge id)kSecAttrKeyClassPrivate
    };
    CFErrorRef error = NULL;
    
    // 尝试 PKCS#8
    SecKeyRef secKey = SecKeyCreateWithData((__bridge CFDataRef)keyData,
                                              (__bridge CFDictionaryRef)attributes,
                                              &error);
    
    // 如果失败，尝试 PKCS#1（去掉前26字节头部）
    if (!secKey && keyData.length > 26) {
        if (error) { CFRelease(error); error = NULL; }
        NSData* pkcs1Data = [keyData subdataWithRange:NSMakeRange(26, keyData.length - 26)];
        secKey = SecKeyCreateWithData((__bridge CFDataRef)pkcs1Data,
                                       (__bridge CFDictionaryRef)attributes,
                                       &error);
    }
    
    if (!secKey) {
        if (error) CFRelease(error);
        return JS_NewString(ctx, "");
    }
    
    CFDataRef signature = SecKeyCreateSignature(secKey,
                                                  kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA256,
                                                  (__bridge CFDataRef)msgData,
                                                  &error);
    CFRelease(secKey);
    
    if (!signature) {
        if (error) CFRelease(error);
        return JS_NewString(ctx, "");
    }
    
    NSData* sigData = (__bridge_transfer NSData*)signature;
    NSString* result = [sigData base64EncodedStringWithOptions:0];
    return JS_NewString(ctx, [result UTF8String]);
}

// UUID v4 生成
static JSValue js_uuid_func(JSContext *ctx, JSValueConst this_val,
                             int argc, JSValueConst *argv) {
    NSString* uuid = [[NSUUID UUID] UUIDString].lowercaseString;
    return JS_NewString(ctx, [uuid UTF8String]);
}

// Hex 字符串转 Base64
static JSValue js_hex_to_b64_func(JSContext *ctx, JSValueConst this_val,
                                   int argc, JSValueConst *argv) {
    if (argc < 1) return JS_NewString(ctx, "");
    const char* hex_cstr = JS_ToCString(ctx, argv[0]);
    NSString* hexStr = [NSString stringWithUTF8String:hex_cstr];
    JS_FreeCString(ctx, hex_cstr);
    
    hexStr = [hexStr stringByReplacingOccurrencesOfString:@" " withString:@""];
    hexStr = [hexStr stringByReplacingOccurrencesOfString:@"\n" withString:@""];
    hexStr = [hexStr stringByReplacingOccurrencesOfString:@"\r" withString:@""];
    
    NSMutableData* data = [NSMutableData data];
    const char* hex = [hexStr UTF8String];
    size_t len = strlen(hex);
    for (size_t i = 0; i + 1 < len; i += 2) {
        char buf[3] = {hex[i], hex[i+1], 0};
        unsigned int byte = 0;
        sscanf(buf, "%02x", &byte);
        [data appendBytes:&byte length:1];
    }
    
    NSString* result = [data base64EncodedStringWithOptions:0];
    return JS_NewString(ctx, [result UTF8String]);
}

void QJSBridge_registerCrypto(void* ctx) {
    JSContext* jsCtx = (JSContext*)ctx;
    
    // 创建 crypto 对象
    JSValue cryptoObj = JS_NewObject(jsCtx);
    
    // AES 子对象（新增 decryptECB，保留原有 decrypt）
    JSValue aesObj = JS_NewObject(jsCtx);
    JSValue aesDecryptFunc = JS_NewCFunction(jsCtx, js_aes_decrypt_func, "decrypt", 2);
    JSValue aesDecryptECBFunc = JS_NewCFunction(jsCtx, js_aes_decrypt_ecb_func, "decryptECB", 2);
    JS_SetPropertyStr(jsCtx, aesObj, "decrypt", aesDecryptFunc);
    JS_SetPropertyStr(jsCtx, aesObj, "decryptECB", aesDecryptECBFunc);
    JS_SetPropertyStr(jsCtx, cryptoObj, "AES", aesObj);
    
    // RSA 子对象（新增）
    JSValue rsaObj = JS_NewObject(jsCtx);
    JSValue rsaSignFunc = JS_NewCFunction(jsCtx, js_rsa_sign_func, "sign", 2);
    JS_SetPropertyStr(jsCtx, rsaObj, "sign", rsaSignFunc);
    JS_SetPropertyStr(jsCtx, cryptoObj, "RSA", rsaObj);
    
    // MD5（保留原有）
    JSValue md5Func = JS_NewCFunction(jsCtx, js_md5_func, "MD5", 1);
    JS_SetPropertyStr(jsCtx, cryptoObj, "MD5", md5Func);
    
    // SHA256（新增）
    JSValue sha256Func = JS_NewCFunction(jsCtx, js_sha256_func, "SHA256", 1);
    JS_SetPropertyStr(jsCtx, cryptoObj, "SHA256", sha256Func);
    
    // HMAC 子对象（新增）
    JSValue hmacObj = JS_NewObject(jsCtx);
    JSValue hmacSha256Func = JS_NewCFunction(jsCtx, js_hmac_sha256_func, "SHA256", 2);
    JS_SetPropertyStr(jsCtx, hmacObj, "SHA256", hmacSha256Func);
    JS_SetPropertyStr(jsCtx, cryptoObj, "HMAC", hmacObj);
    
    // base64 子对象（保留原有）
    JSValue b64Obj = JS_NewObject(jsCtx);
    JSValue b64DecodeFunc = JS_NewCFunction(jsCtx, js_b64_decode_func, "decode", 1);
    JSValue b64EncodeFunc = JS_NewCFunction(jsCtx, js_b64_encode_func, "encode", 1);
    JS_SetPropertyStr(jsCtx, b64Obj, "decode", b64DecodeFunc);
    JS_SetPropertyStr(jsCtx, b64Obj, "encode", b64EncodeFunc);
    JS_SetPropertyStr(jsCtx, cryptoObj, "base64", b64Obj);
    
    // hex 子对象（新增）
    JSValue hexObj = JS_NewObject(jsCtx);
    JSValue hexToB64Func = JS_NewCFunction(jsCtx, js_hex_to_b64_func, "toBase64", 1);
    JS_SetPropertyStr(jsCtx, hexObj, "toBase64", hexToB64Func);
    JS_SetPropertyStr(jsCtx, cryptoObj, "hex", hexObj);
    
    // uuid（新增）
    JSValue uuidFunc = JS_NewCFunction(jsCtx, js_uuid_func, "uuid", 0);
    JS_SetPropertyStr(jsCtx, cryptoObj, "uuid", uuidFunc);
    
    // 注册到全局
    // 注意：JS_SetPropertyStr 不增加 ref count，它直接接管值的所有权
    // 因此 cryptoObj 在 SetPropertyStr 之后不能再被 JS_FreeValue 释放，
    // 否则 global 对象会持有悬空指针，导致 JS_FreeContext 时触发 use-after-free
    JSValue global = JS_GetGlobalObject(jsCtx);
    JS_SetPropertyStr(jsCtx, global, "crypto", cryptoObj);
    JS_FreeValue(jsCtx, global);
    // cryptoObj 已由 global 对象持有，不需要（也不能）额外释放
}
