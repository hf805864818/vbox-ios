//
//  PythonLogStore.m
//  vbox
//
//  开发用: PythonBridge 日志集中存储
//

#import "PythonLogStore.h"

NSNotificationName const PythonLogStoreDidUpdateNotification = @"PythonLogStoreDidUpdateNotification";

static const NSUInteger kMaxLogCount = 2000;

@interface PythonLogStore ()
@property (nonatomic, strong) NSMutableArray<NSString *> *logs;
@property (nonatomic, strong) NSLock *lock;
@end

@implementation PythonLogStore

+ (instancetype)shared {
    static PythonLogStore *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _logs = [NSMutableArray array];
        _lock = [NSLock new];
        _enabled = NO;
    }
    return self;
}

+ (void)appendLog:(NSString *)message {
    [[self shared] addLog:message];
}

- (void)addLog:(NSString *)message {
    if (!self.enabled) return;
    [self appendLogInternal:message];
}

- (void)appendLogInternal:(NSString *)message {
    static NSDateFormatter *fmt = nil;
    static dispatch_once_t fmtOnce;
    dispatch_once(&fmtOnce, ^{
        fmt = [NSDateFormatter new];
        fmt.dateFormat = @"HH:mm:ss.SSS";
    });
    NSString *ts = [fmt stringFromDate:[NSDate date]];
    NSString *entry = [NSString stringWithFormat:@"[%@] %@", ts, message];

    [self.lock lock];
    [self.logs addObject:entry];
    if (self.logs.count > kMaxLogCount) {
        [self.logs removeObjectsInRange:NSMakeRange(0, self.logs.count - kMaxLogCount)];
    }
    [self.lock unlock];

    // 通知悬浮窗刷新 (主线程)
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:PythonLogStoreDidUpdateNotification object:nil];
    });
}

- (NSUInteger)count {
    [self.lock lock];
    NSUInteger c = self.logs.count;
    [self.lock unlock];
    return c;
}

- (NSArray<NSString *> *)recentLogs:(NSUInteger)limit {
    [self.lock lock];
    NSUInteger total = self.logs.count;
    if (total == 0) { [self.lock unlock]; return @[]; }
    NSUInteger start = total > limit ? total - limit : 0;
    NSArray *r = [self.logs subarrayWithRange:NSMakeRange(start, total - start)];
    [self.lock unlock];
    return r;
}

- (NSArray<NSString *> *)allLogs {
    [self.lock lock];
    NSArray *r = [self.logs copy];
    [self.lock unlock];
    return r;
}

- (void)clearLogs {
    [self.lock lock];
    [self.logs removeAllObjects];
    [self.lock unlock];
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:PythonLogStoreDidUpdateNotification object:nil];
    });
}

- (NSString *)exportToDocuments {
    [self.lock lock];
    NSArray *snapshot = [self.logs copy];
    [self.lock unlock];

    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (paths.count == 0) return nil;
    NSString *docs = paths.firstObject;
    static NSDateFormatter *efmt = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        efmt = [NSDateFormatter new];
        efmt.dateFormat = @"yyyyMMdd_HHmmss";
    });
    NSString *fileName = [NSString stringWithFormat:@"python_logs_%@.txt", [efmt stringFromDate:[NSDate date]]];
    NSString *path = [docs stringByAppendingPathComponent:fileName];
    NSString *content = [snapshot componentsJoinedByString:@"\n"];
    NSError *error = nil;
    BOOL ok = [content writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error];
    return ok ? path : nil;
}

@end
