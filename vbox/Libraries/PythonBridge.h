//
//  PythonBridge.h
//  vbox
//
//  ObjC 桥接层 —— 连接 Swift 和 CPython 解释器
//  用于执行 Python Spider 脚本
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface PythonSpiderBridge : NSObject

/// 初始化 Python 解释器（整个 App 生命周期只调一次，线程安全）
+ (void)initializePythonIfNeeded;

/// 执行 Python Spider 脚本的指定方法
/// @param scriptPath 本地 .py 文件绝对路径
/// @param functionName 方法名: "homeContent"|"categoryContent"|"detailContent"|"searchContent"|"playerContent"
/// @param argsJSON JSON 格式参数字符串 (可为 nil)
/// @return Python 方法返回的 JSON 字符串，失败返回 nil
+ (nullable NSString *)callSpider:(NSString *)scriptPath
                         function:(NSString *)functionName
                             args:(nullable NSString *)argsJSON;

/// 销毁 Python 解释器（App 退出时调用）
+ (void)finalizePython;

/// 检查 Python 是否已初始化
+ (BOOL)isPythonInitialized;

/// 执行 Python Spider 脚本的指定方法（带全局变量注入）
/// @param scriptPath 本地 .py 文件绝对路径
/// @param injectDict 要注入到脚本 globals 字典的键值对（字符串/数字/布尔/数组等基础类型）
/// @param functionName 方法名
/// @param argsJSON JSON 格式参数字符串 (可为 nil)
/// @return Python 方法返回的 JSON 字符串，失败返回 nil
+ (nullable NSString *)callSpider:(NSString *)scriptPath
                     injectDict:(nullable NSDictionary *)injectDict
                       function:(NSString *)functionName
                           args:(nullable NSString *)argsJSON;

/// 调用 Spider 的 localProxy 方法（返回二进制数据，不走 JSON 序列化）
/// @param scriptPath 本地 .py 文件绝对路径
/// @param injectDict 注入上下文（域名/代理等）
/// @param argsJSON JSON 格式参数（包含 type/url 等字段）
/// @return NSDictionary: { "status": Int, "contentType": String, "data": NSData }，失败返回 nil
+ (nullable NSDictionary *)callLocalProxy:(NSString *)scriptPath
                              injectDict:(nullable NSDictionary *)injectDict
                                    args:(nullable NSString *)argsJSON;

@end

NS_ASSUME_NONNULL_END
