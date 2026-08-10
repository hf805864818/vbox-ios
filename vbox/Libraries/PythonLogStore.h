//
//  PythonLogStore.h
//  vbox
//
//  开发用: PythonBridge 日志集中存储 (ObjC 单例, 线程安全)
//  供 Swift 悬浮窗 + 导出使用
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface PythonLogStore : NSObject

/// 单例
+ (instancetype)shared;

/// 便捷类方法: 追加日志 (供 ObjC 调用)
+ (void)appendLog:(NSString *)message;

/// 添加一条日志 (线程安全)
- (void)addLog:(NSString *)message;

/// 当前日志条数
@property (nonatomic, readonly) NSUInteger count;

/// 获取最新 N 条
- (NSArray<NSString *> *)recentLogs:(NSUInteger)limit;

/// 全部日志
- (NSArray<NSString *> *)allLogs;

/// 清空日志
- (void)clearLogs;

/// 是否已开启收集 (只有开启才收集, 默认 NO)
@property (nonatomic, assign) BOOL enabled;

/// 导出所有日志到 Documents, 返回文件路径 (失败返回 nil)
- (nullable NSString *)exportToDocuments;

/// 导出所有日志为 zip 到 Documents, 返回 zip 文件路径 (失败返回 nil)
- (nullable NSString *)exportToZip;

/// 日志变化通知 (悬浮窗监听刷新)
extern NSNotificationName const PythonLogStoreDidUpdateNotification;

@end

NS_ASSUME_NONNULL_END
