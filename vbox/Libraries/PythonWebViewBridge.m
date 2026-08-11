//
//  PythonWebViewBridge.m
//  vbox
//
//  Python ↔ WKWebView 桥接 — ObjC 实现
//
//  核心功能:
//    1. 用 Python C API 定义 PyWebView_Fetch C 函数
//    2. 将函数注册到 Python __main__ 模块的 globals 中
//    3. 调用 Swift 侧 PythonWebViewBridge 执行实际抓取
//    4. 将结果 JSON 解析为 Python 对象返回
//
//  调用链路:
//    Python: webview_fetch(url, js_code)
//      → C: PyWebView_Fetch(self, args)
//      → Swift: PythonWebViewBridge.fetchSync()
//      → WKWebView 加载页面 + 执行 JS
//      → 返回 JSON 字符串
//      → ObjC: json.loads() 转 Python 对象
//      → 返回给 Python
//
//  线程模型:
//    - Python 调用在后台线程 (pythonQueue)
//    - fetchSync 用 semaphore 同步等待 WebView (主线程)
//    - GIL 在整个调用期间持有 (和其他 Python 调用一致)
//

#import "PythonWebViewBridge.h"
#import <Python/Python.h>

// Swift 桥接头 — 项目名不同需修改
// 通常是 "项目名-Swift.h", 如 "vbox-Swift.h"
#import "vbox-Swift.h"

// 全局保存最后一次错误信息
static NSString * _Nullable g_lastErrorMessage = nil;

#pragma mark - Python C 函数

/// Python 函数: webview_fetch(url, js_code[, timeout_seconds])
///
/// 用 WKWebView 加载页面并执行 JS 提取数据
///
/// Python 用法:
///   result = webview_fetch('https://example.com', 'return document.title')
///   result = webview_fetch(url, js_code, 30)  # 指定超时 30 秒
///
/// 返回值:
///   成功: JS 执行结果 (自动 JSON 解析为 Python 对象)
///   失败: None, 错误信息通过 webview_last_error() 获取
static PyObject* PyWebView_Fetch(PyObject* self, PyObject* args) {
    const char* url = NULL;
    const char* jsCode = NULL;
    int timeout = 0;  // 0 = 使用默认值

    // 解析参数: (s, s, |i) — 两个必选字符串, 一个可选整数
    if (!PyArg_ParseTuple(args, "ss|i", &url, &jsCode, &timeout)) {
        PyErr_SetString(PyExc_TypeError, "webview_fetch(url, js_code[, timeout_seconds]): 参数错误");
        return NULL;
    }

    @autoreleasepool {
        // 调用 Swift 侧实现
        PythonWebViewResult* result = [[PythonWebViewBridge shared] fetchSync:[NSString stringWithUTF8String:url]
                                                                        jsCode:[NSString stringWithUTF8String:jsCode]
                                                                timeoutSeconds:timeout];

        if (result.success && result.jsonString) {
            // 成功: 用 json.loads 把 JSON 字符串转成 Python 对象
            const char* jsonStr = [result.jsonString UTF8String];

            // 导入 json 模块
            PyObject* jsonModule = PyImport_ImportModule("json");
            if (!jsonModule) {
                g_lastErrorMessage = @"无法导入 json 模块";
                PyErr_Clear();
                Py_RETURN_NONE;
            }

            // 获取 json.loads 函数
            PyObject* loadsFunc = PyObject_GetAttrString(jsonModule, "loads");
            Py_DECREF(jsonModule);
            if (!loadsFunc || !PyCallable_Check(loadsFunc)) {
                Py_XDECREF(loadsFunc);
                g_lastErrorMessage = @"json.loads 不可用";
                PyErr_Clear();
                Py_RETURN_NONE;
            }

            // 调用 json.loads(jsonStr)
            PyObject* jsonArg = PyUnicode_FromString(jsonStr);
            PyObject* pyResult = PyObject_CallFunctionObjArgs(loadsFunc, jsonArg, NULL);
            Py_DECREF(jsonArg);
            Py_DECREF(loadsFunc);

            if (pyResult) {
                g_lastErrorMessage = nil;
                return pyResult;
            } else {
                // JSON 解析失败, 清除错误, 返回原始字符串
                PyErr_Clear();
                g_lastErrorMessage = [NSString stringWithFormat:@"结果 JSON 解析失败: %s", jsonStr];
                // 返回原始 JSON 字符串作为回退
                return PyUnicode_FromString(jsonStr);
            }
        } else {
            // 失败: 保存错误信息, 返回 None
            g_lastErrorMessage = result.errorMessage ?: @"未知错误";
            Py_RETURN_NONE;
        }
    }
}

/// Python 函数: webview_last_error()
///
/// 返回最后一次 webview_fetch 的错误信息
/// 用于调试
static PyObject* PyWebView_LastError(PyObject* self, PyObject* args) {
    if (g_lastErrorMessage) {
        return PyUnicode_FromString([g_lastErrorMessage UTF8String]);
    }
    Py_RETURN_NONE;
}

#pragma mark - 方法表

/// webview_fetch 方法定义
static PyMethodDef WebViewMethods[] = {
    {
        "webview_fetch",         // Python 函数名
        PyWebView_Fetch,         // C 函数指针
        METH_VARARGS,            // 参数传递方式 (位置参数)
        "webview_fetch(url, js_code[, timeout_seconds]) -> object\n"
        "用 WKWebView 加载页面并执行 JS 提取数据。\n"
        "参数:\n"
        "  url: 要加载的页面 URL\n"
        "  js_code: 页面加载完成后执行的 JS 代码, return 返回值会被 JSON 解析\n"
        "  timeout_seconds: 超时时间 (秒), 默认 30 秒\n"
        "返回:\n"
        "  成功: JS 返回值 (Python dict/list/str 等)\n"
        "  失败: None, 可通过 webview_last_error() 查看错误"
    },
    {
        "webview_last_error",    // Python 函数名
        PyWebView_LastError,     // C 函数指针
        METH_NOARGS,             // 无参数
        "webview_last_error() -> str or None\n"
        "返回最后一次 webview_fetch 的错误信息"
    },
    {NULL, NULL, 0, NULL}  // 哨兵
};

#pragma mark - 注册实现

@implementation PythonWebViewBridgeOC

+ (void)registerWebViewFetch {
    // 获取 __main__ 模块
    PyObject* mainModule = PyImport_AddModule("__main__");
    if (!mainModule) {
        NSLog(@"[PythonWebViewBridge] 错误: 无法获取 __main__ 模块");
        return;
    }

    // 获取 globals 字典
    PyObject* globals = PyModule_GetDict(mainModule);
    if (!globals) {
        NSLog(@"[PythonWebViewBridge] 错误: 无法获取 __main__.__dict__");
        return;
    }

    // 注册 webview_fetch 函数
    // 注意: 这里不创建新模块, 而是直接把函数加到 __main__ 的 globals 中
    // 这样 Python 脚本里可以直接调用, 不需要 import
    int registeredCount = 0;

    for (int i = 0; WebViewMethods[i].ml_name != NULL; i++) {
        PyObject* func = PyCFunction_NewEx(&WebViewMethods[i], NULL, NULL);
        if (func) {
            const char* name = WebViewMethods[i].ml_name;
            if (PyDict_SetItemString(globals, name, func) == 0) {
                registeredCount++;
                NSLog(@"[PythonWebViewBridge] 已注册全局函数: %s", name);
            } else {
                NSLog(@"[PythonWebViewBridge] 注册失败: %s", name);
                PyErr_Clear();
            }
            Py_DECREF(func);
        }
    }

    NSLog(@"[PythonWebViewBridge] 注册完成, 共 %d 个全局函数", registeredCount);
}

+ (NSString *)lastErrorMessage {
    return g_lastErrorMessage;
}

@end
