#import <Foundation/Foundation.h>

// 不透明指针 — Swift 侧用 UnsafeMutableRawPointer
void* _Nonnull QJSBridge_createRuntime(void);
void* _Nonnull QJSBridge_createContext(void* _Nonnull rt);
void QJSBridge_freeRuntime(void* _Nonnull rt);
void QJSBridge_freeContext(void* _Nonnull ctx);

const char* _Nullable QJSBridge_eval(void* _Nonnull ctx, const char* _Nonnull script);
void QJSBridge_freeString(void* _Nonnull ctx, const char* _Nonnull str);
