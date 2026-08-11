//
//  PythonWebViewBridge.h
//  vbox
//
//  Python ↔ WKWebView 桥接 — 头文件
//
//  功能: 向 Python 全局命名空间注册 webview_fetch() 函数
//        使 Python 蜘蛛脚本可以调用 WKWebView 绕过反爬验证
//
//  使用方式:
//    1. 在 PythonSpiderBridge 初始化后调用
//       [PythonWebViewBridge registerWebViewFetch];
//    2. Python 脚本中即可使用:
//       result = webview_fetch(url, js_code)
//
//  注意:
//    - 本模块依赖 Python.framework (CPython)
//    - 本模块依赖 Swift 的 PythonWebViewBridge 类
//      (需通过 Swift 桥接头引入: #import "vbox-Swift.h")
//    - 注册后 Python 环境会增加一个全局函数 webview_fetch
//      对现有脚本和功能无影响 (不调用就不执行)
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface PythonWebViewBridgeOC : NSObject

/// 向 Python 全局命名空间注册 webview_fetch 函数
///
/// 必须在 Py_Initialize() 之后调用
/// 注册后 Python 脚本中可直接调用:
///   result = webview_fetch(url, js_code)
///   result = webview_fetch(url, js_code, timeout_seconds)
///
/// 参数:
///   url: 要加载的页面 URL (字符串)
///   js_code: 页面加载完成后执行的 JS 提取代码 (字符串)
///   timeout_seconds: 超时时间 (整数, 可选, 默认 30 秒)
///
/// 返回值:
///   成功: JS 返回值经 JSON 解析后的 Python 对象 (dict/list/str/int 等)
///   失败: None, 可通过 webview_last_error() 获取错误信息
+ (void)registerWebViewFetch;

/// 获取最后一次 webview_fetch 的错误信息
/// (供 Python 脚本调试用)
+ (NSString *_Nullable)lastErrorMessage;

@end

NS_ASSUME_NONNULL_END
