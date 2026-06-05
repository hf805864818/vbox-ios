#import <Foundation/Foundation.h>
#import <string.h>

// 不透明指针 — Swift 侧用 UnsafeMutableRawPointer
void* _Nonnull QJSBridge_createRuntime(void);
void* _Nonnull QJSBridge_createContext(void* _Nonnull rt);
void QJSBridge_freeRuntime(void* _Nonnull rt);
void QJSBridge_freeContext(void* _Nonnull ctx);

const char* _Nullable QJSBridge_eval(void* _Nonnull ctx, const char* _Nonnull script);
void QJSBridge_freeString(void* _Nonnull ctx, const char* _Nonnull str);

// 注册 http() 全局函数 — 让 JS 蜘蛛可以发网络请求
void QJSBridge_registerHTTP(void* _Nonnull ctx);
