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

@end

NS_ASSUME_NONNULL_END
