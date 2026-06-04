#import <Foundation/Foundation.h>

// QuickJS 运行时和上下文
typedef void JSRuntime;
typedef void JSContext;

// 创建/释放
JSRuntime* _Nonnull QJSBridge_createRuntime(void);
JSContext* _Nonnull QJSBridge_createContext(JSRuntime* _Nonnull rt);
void QJSBridge_freeRuntime(JSRuntime* _Nonnull rt);
void QJSBridge_freeContext(JSContext* _Nonnull ctx);

// 执行 JS
const char* _Nullable QJSBridge_eval(JSContext* _Nonnull ctx, const char* _Nonnull script);
void QJSBridge_freeString(JSContext* _Nonnull ctx, const char* _Nonnull str);
