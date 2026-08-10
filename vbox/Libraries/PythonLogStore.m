//
//  PythonLogStore.m
//  vbox
//
//  开发用: PythonBridge 日志集中存储
//

#import "PythonLogStore.h"
#import <zlib.h>   // libz: deflateInit2/deflate/crc32 等 (libz.tbd 已链接)

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

- (NSString *)exportToZip {
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
    NSString *timestamp = [efmt stringFromDate:[NSDate date]];

    // 1. 先写 txt 到临时目录
    NSString *txtFileName = [NSString stringWithFormat:@"python_logs_%@.txt", timestamp];
    NSString *tmpTxt = [NSTemporaryDirectory() stringByAppendingPathComponent:txtFileName];
    NSString *content = [snapshot componentsJoinedByString:@"\n"];
    NSError *error = nil;
    if (![content writeToFile:tmpTxt atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
        return nil;
    }

    // 2. 压缩为 zip
    NSString *zipFileName = [NSString stringWithFormat:@"python_logs_%@.zip", timestamp];
    NSString *zipPath = [docs stringByAppendingPathComponent:zipFileName];

    // 删除旧 zip (如果存在)
    [[NSFileManager defaultManager] removeItemAtPath:zipPath error:nil];

    // 读取文件数据用于压缩
    NSData *fileData = [NSData dataWithContentsOfFile:tmpTxt];
    if (!fileData) {
        // 回退: 直接复制 txt
        NSString *txtPath = [docs stringByAppendingPathComponent:txtFileName];
        [content writeToFile:txtPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return txtPath;
    }

    // ★ 计算 CRC32 — 必须基于原始未压缩数据 (ZIP 规范要求)
    uLong crc = crc32(0L, Z_NULL, 0);
    crc = crc32(crc, (const Bytef *)fileData.bytes, (uInt)fileData.length);

    // 压缩数据 (raw deflate, 无 zlib 头)
    NSData *compressedData = [self deflateData:fileData];
    if (compressedData) {
        // 构建最小 zip 文件结构
        NSData *zipData = [self buildZipWithData:compressedData
                                        fileName:txtFileName
                                    originalSize:fileData.length
                                     originalCRC:(uint32_t)crc];
        if (zipData && [zipData writeToFile:zipPath atomically:YES]) {
            // 清理临时文件
            [[NSFileManager defaultManager] removeItemAtPath:tmpTxt error:nil];
            return zipPath;
        }
    }

    // 最终回退: 直接保存 txt
    NSString *txtPath = [docs stringByAppendingPathComponent:txtFileName];
    [content writeToFile:txtPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:tmpTxt error:nil];
    return txtPath;
}

#pragma mark - Zip Helpers

/// 使用 libz raw deflate 压缩数据 (无 zlib header, 用于 ZIP)
- (NSData *)deflateData:(NSData *)data {
    if (data.length == 0) return nil;
    z_stream strm;
    memset(&strm, 0, sizeof(strm));
    strm.next_in = (Bytef *)data.bytes;
    strm.avail_in = (uInt)data.length;

    // -15: raw deflate (no zlib/zlib header), 8: mem level, Z_DEFAULT_STRATEGY
    if (deflateInit2(&strm, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY) != Z_OK) {
        return nil;
    }

    NSMutableData *output = [NSMutableData dataWithCapacity:data.length / 2];
    Bytef buffer[16384];
    int ret;

    // ★ 正确的 deflate 循环: Z_FINISH 表示一次性压缩全部输入
    // 每次 deflate 后检查 avail_out, 将产出的数据追加到 output
    // ret == Z_OK 表示输出缓冲区已满, 需要继续; Z_STREAM_END 表示完成
    do {
        strm.next_out = buffer;
        strm.avail_out = sizeof(buffer);
        ret = deflate(&strm, Z_FINISH);
        NSUInteger written = sizeof(buffer) - strm.avail_out;
        if (written > 0) {
            [output appendBytes:buffer length:written];
        }
    } while (ret == Z_OK);

    deflateEnd(&strm);

    if (ret != Z_STREAM_END) {
        return nil;
    }
    return output;
}

/// 构建最小 zip 文件 (单文件, raw deflate)
- (NSData *)buildZipWithData:(NSData *)compressedData
                    fileName:(NSString *)fileName
                originalSize:(NSUInteger)originalSize
                 originalCRC:(uint32_t)crc {
    // 构建 local file header + compressed data + central directory + EOCD
    // 参考 ZIP File Format Specification
    NSData *nameData = [fileName dataUsingEncoding:NSUTF8StringEncoding];

    uint16_t modTime = 0;
    uint16_t modDate = 0x21;  // 2020-01-01
    uint32_t originalSize32 = (uint32_t)originalSize;  // ★ NSUInteger → uint32_t

    NSMutableData *zip = [NSMutableData data];

    // === Local file header (30 bytes + filename) ===
    uint32_t localSig = 0x04034b50;
    uint16_t versionNeeded = 20;
    uint16_t flags = 0x0800;  // bit 11: UTF-8 filename
    uint16_t compression = 8;  // deflate
    uint32_t compressedSize = (uint32_t)compressedData.length;
    uint16_t nameLen = (uint16_t)nameData.length;
    uint16_t extraLen = 0;

    [zip appendBytes:&localSig length:4];
    [zip appendBytes:&versionNeeded length:2];
    [zip appendBytes:&flags length:2];
    [zip appendBytes:&compression length:2];
    [zip appendBytes:&modTime length:2];
    [zip appendBytes:&modDate length:2];
    [zip appendBytes:&crc length:4];            // CRC32 of original (uncompressed) data
    [zip appendBytes:&compressedSize length:4];
    [zip appendBytes:&originalSize32 length:4]; // ★ uint32_t (not NSUInteger)
    [zip appendBytes:&nameLen length:2];
    [zip appendBytes:&extraLen length:2];
    [zip appendData:nameData];
    [zip appendData:compressedData];

    // === Central directory header (46 bytes + filename) ===
    NSUInteger cdStart = zip.length;  // central directory 起始偏移

    uint32_t cdSig = 0x02014b50;
    uint16_t versionMade = 20;
    uint16_t extAttr = 0;
    uint16_t extraLen2 = 0;
    uint16_t commentLen = 0;
    uint16_t diskNum = 0;
    uint16_t intAttr = 0;
    uint32_t localHeaderOffset = 0;

    [zip appendBytes:&cdSig length:4];
    [zip appendBytes:&versionMade length:2];
    [zip appendBytes:&versionNeeded length:2];
    [zip appendBytes:&flags length:2];
    [zip appendBytes:&compression length:2];
    [zip appendBytes:&modTime length:2];
    [zip appendBytes:&modDate length:2];
    [zip appendBytes:&crc length:4];
    [zip appendBytes:&compressedSize length:4];
    [zip appendBytes:&originalSize32 length:4]; // ★ uint32_t (not NSUInteger)
    [zip appendBytes:&nameLen length:2];
    [zip appendBytes:&extraLen2 length:2];
    [zip appendBytes:&commentLen length:2];
    [zip appendBytes:&diskNum length:2];
    [zip appendBytes:&intAttr length:2];
    [zip appendBytes:&extAttr length:2];
    [zip appendBytes:&localHeaderOffset length:4];
    [zip appendData:nameData];

    NSUInteger cdSize = zip.length - cdStart;

    // === End of central directory (22 bytes) ===
    uint32_t eocdSig = 0x06054b50;
    uint16_t numEntries = 1;
    uint32_t cdSize32 = (uint32_t)cdSize;       // ★ 4 字节 (不是 2 字节)
    uint32_t cdOffset32 = (uint32_t)cdStart;   // ★ 4 字节 (不是 2 字节)

    [zip appendBytes:&eocdSig length:4];
    [zip appendBytes:&diskNum length:2];
    [zip appendBytes:&diskNum length:2];
    [zip appendBytes:&numEntries length:2];
    [zip appendBytes:&numEntries length:2];
    [zip appendBytes:&cdSize32 length:4];       // ★ 4 字节
    [zip appendBytes:&cdOffset32 length:4];     // ★ 4 字节
    [zip appendBytes:&commentLen length:2];

    return zip;
}

@end
