//
//  AppLogBridge.h
//  vbox
//
//  AppLogStore 的 ObjC 桥接层
//  供 PythonBridge.m / 其他 ObjC 代码调用
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 日志级别 (与 Swift LogLevel 对应)
typedef NS_ENUM(NSInteger, AppLogLevel) {
    AppLogLevelVerbose = 0,
    AppLogLevelInfo    = 1,
    AppLogLevelWarn    = 2,
    AppLogLevelError   = 3,
};

/// 日志模块 (与 Swift LogCategory 对应)
typedef NS_ENUM(NSInteger, AppLogCategory) {
    AppLogCategoryApp      = 0,
    AppLogCategorySpider   = 1,
    AppLogCategoryPlayer   = 2,
    AppLogCategoryCloud    = 3,
    AppLogCategoryProxy    = 4,
    AppLogCategoryNetwork  = 5,
    AppLogCategoryDB       = 6,
    AppLogCategoryDownload = 7,
    AppLogCategoryWelfare  = 8,
};

/// AppLogStore ObjC 桥接
/// 通过 NotificationCenter 转发给 Swift 的 AppLogStore
@interface AppLogBridge : NSObject

/// 追加一条日志 (线程安全)
+ (void)logWithLevel:(AppLogLevel)level
            category:(AppLogCategory)category
             message:(NSString *)message;

/// 便捷方法
+ (void)info:(AppLogCategory)category message:(NSString *)message;
+ (void)warn:(AppLogCategory)category message:(NSString *)message;
+ (void)error:(AppLogCategory)category message:(NSString *)message;
+ (void)verbose:(AppLogCategory)category message:(NSString *)message;

@end

NS_ASSUME_NONNULL_END
