//
//  AppLogBridge.m
//  vbox
//  AppLogStore 的 ObjC 桥接实现
//  通过 NotificationCenter 转发给 Swift 的 AppLogStore
//

#import "AppLogBridge.h"

// 通知名称 (与 Swift 侧保持一致)
NSString * const AppLogBridgeDidAddLogNotification = @"AppLogBridgeDidAddLogNotification";

@implementation AppLogBridge

+ (void)logWithLevel:(AppLogLevel)level
            category:(AppLogCategory)category
             message:(NSString *)message {
    if (!message) return;
    
    NSDictionary *userInfo = @{
        @"level":    @(level),
        @"category": @(category),
        @"message":  message,
        @"timestamp": [NSDate date],
        @"thread":   [NSThread isMainThread] ? @"main" : @"bg"
    };
    
    [[NSNotificationCenter defaultCenter] postNotificationName:AppLogBridgeDidAddLogNotification
                                                        object:nil
                                                      userInfo:userInfo];
}

+ (void)info:(AppLogCategory)category message:(NSString *)message {
    [self logWithLevel:AppLogLevelInfo category:category message:message];
}

+ (void)warn:(AppLogCategory)category message:(NSString *)message {
    [self logWithLevel:AppLogLevelWarn category:category message:message];
}

+ (void)error:(AppLogCategory)category message:(NSString *)message {
    [self logWithLevel:AppLogLevelError category:category message:message];
}

+ (void)verbose:(AppLogCategory)category message:(NSString *)message {
    [self logWithLevel:AppLogLevelVerbose category:category message:message];
}

@end
