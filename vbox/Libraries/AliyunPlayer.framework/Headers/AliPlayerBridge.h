// AliPlayerBridge.h - Private header for AliPlayer ObjC API
// This header declares the subset of AliPlayer API that vbox uses.
// The actual implementation is in AliyunPlayer.framework binary.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - AVPUrlSource

@interface AVPUrlSource : NSObject
@property (nonatomic, copy) NSString *url;
@property (nonatomic, copy, nullable) NSString *uid;
@property (nonatomic, copy, nullable) NSString *userData;
@end

#pragma mark - AVPConfig

@interface AVPConfig : NSObject
@property (nonatomic, copy, nullable) NSString *referer;
@property (nonatomic, copy, nullable) NSDictionary<NSString *, NSString *> *httpHeaders;
@property (nonatomic, assign) NSInteger networkTimeout;
@property (nonatomic, assign) NSInteger maxDelayTime;
@property (nonatomic, assign) NSInteger highBufferDuration;
@property (nonatomic, assign) NSInteger startBufferDuration;
@property (nonatomic, assign) NSInteger maxBufferDuration;
@property (nonatomic, assign) NSInteger maxProbeSize;
@property (nonatomic, assign) NSInteger networkRetryCount;
@property (nonatomic, assign) BOOL enableLocalCache;
@property (nonatomic, assign) BOOL clearShowWhenStop;
@property (nonatomic, assign) NSInteger positionTimerIntervalMs;
@end

#pragma mark - AVPCacheConfig

@interface AVPCacheConfig : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic, assign) int64_t maxSizeMB;
@property (nonatomic, assign) int64_t maxDuration;
@end

#pragma mark - AVPErrorModel

@interface AVPErrorModel : NSObject
@property (nonatomic, assign) NSInteger code;
@property (nonatomic, copy) NSString *message;
@end

#pragma mark - AVPMediaInfo

@interface AVPMediaInfo : NSObject
@property (nonatomic, assign) int64_t duration;
@property (nonatomic, assign) int width;
@property (nonatomic, assign) int height;
@property (nonatomic, copy, nullable) NSString *title;
@end

#pragma mark - AVPTrackInfo

@interface AVPTrackInfo : NSObject
@property (nonatomic, assign) NSInteger trackIndex;
@property (nonatomic, assign) NSInteger trackBitrate;
@property (nonatomic, copy, nullable) NSString *trackLanguage;
@property (nonatomic, copy, nullable) NSString *trackDefinition;
@property (nonatomic, assign) BOOL trackIsSelected;
@end

#pragma mark - AVPDelegate

@protocol AVPDelegate <NSObject>
@optional
- (void)onPlayerEvent:(id)player eventCode:(NSInteger)eventCode;
- (void)onPlayerEvent:(id)player eventCode:(NSInteger)eventCode info:(NSString *)info;
- (void)onError:(id)player errorModel:(AVPErrorModel *)errorModel;
- (void)onPlayerStatusChanged:(id)player oldStatus:(NSInteger)oldStatus newStatus:(NSInteger)newStatus;
- (void)onPlayerEvent:(id)player eventWithString:(NSString *)eventStr description:(NSString *)description;
- (void)onVideoSizeChanged:(id)player width:(NSInteger)width height:(NSInteger)height;
- (void)onVideoRendered:(id)player timeMs:(int64_t)timeMs pts:(int64_t)pts;
- (void)onSeekDone:(id)player;
- (void)onSeiData:(id)player type:(NSInteger)type data:(NSData *)data;
- (void)onTrackChanged:(id)player info:(AVPTrackInfo *)info;
- (void)onTrackReady:(id)player info:(NSArray<AVPTrackInfo *> *)info;
- (void)onSubtitleShow:(id)player index:(NSInteger)index subtitle:(NSString *)subtitle;
- (void)onSubtitleHide:(id)player index:(NSInteger)index;
- (void)onSubtitleHeader:(id)player extHeader:(NSString *)extHeader index:(NSInteger)index;
- (void)onCaptureScreen:(id)player image:(UIImage *)image;
- (void)onSnapShot:(id)player image:(UIImage *)image;
- (void)onThumbnailReady:(id)player position:(int64_t)position;
- (void)onThumbnailGetSuccess:(id)player position:(int64_t)position from:(int64_t)from to:(int64_t)to image:(UIImage *)image;
- (void)onThumbnailGetFail:(id)player position:(int64_t)position msg:(NSString *)msg;
- (void)onBufferedPositionChanged:(id)player position:(int64_t)position;
- (void)onReportEventListener:(id)player type:(NSInteger)type value:(id)value;
@end

#pragma mark - AliPlayerPictureInPictureDelegate

@protocol AliPlayerPictureInPictureDelegate <NSObject>
@optional
- (void)pictureInPictureControllerWillStartPictureInPicture:(id)controller;
- (void)pictureInPictureControllerDidStartPictureInPicture:(id)controller;
- (void)pictureInPictureControllerWillStopPictureInPicture:(id)controller;
- (void)pictureInPictureControllerDidStopPictureInPicture:(id)controller;
- (void)pictureInPictureController:(id)controller failedToStartPictureInPictureWithError:(NSError *)error;
- (void)pictureInPictureController:(id)controller restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:(void (^)(BOOL))completionHandler;
@end

#pragma mark - AliPlayer

@interface AliPlayer : NSObject

// Source
- (void)setUrlSource:(AVPUrlSource *)source;
- (void)setAuthSource:(id)source;
- (void)setStsSource:(id)source;
- (void)setMpsSource:(id)source;

// Config
- (void)setConfig:(AVPConfig *)config;
- (AVPConfig *)getConfig;

// Cache
- (void)setCacheConfig:(AVPCacheConfig *)cacheConfig;

// View
- (void)setPlayerView:(UIView *)view;
- (UIView *)playerView;

// Playback control
- (void)prepare;
- (void)start;
- (void)pause;
- (void)stop;
- (void)reset;
- (void)reload;
- (void)destroy;
- (void)seekToTime:(int64_t)timeMs seekMode:(NSInteger)seekMode;
- (void)setStartTime:(int64_t)timeMs seekMode:(NSInteger)seekMode;
- (void)setRate:(float)rate;
- (void)setVolume:(float)volume;
- (void)setMuted:(BOOL)muted;
- (BOOL)isMuted;
- (void)setLoop:(BOOL)loop;
- (BOOL)isLoop;
- (void)setAutoPlay:(BOOL)autoPlay;
- (BOOL)isAutoPlay;
- (void)setScalingMode:(NSInteger)scalingMode;

// State
- (int64_t)duration;
- (int64_t)currentPosition;
- (int64_t)bufferedPosition;
- (NSInteger)playerState;
- (BOOL)isPlaying;
- (int)width;
- (int)height;

// Delegate
- (void)setDelegate:(id<AVPDelegate>)delegate;
- (id<AVPDelegate>)delegate;

// PiP
- (void)setPictureInPictureEnable:(BOOL)enable;
- (BOOL)isPictureInPictureEnable;
- (void)setPictureInPictureShowMode:(NSInteger)mode;
- (void)setPictureinPictureDelegate:(id<AliPlayerPictureInPictureDelegate>)delegate;

// Media info
- (AVPMediaInfo *)getMediaInfo;

// Track
- (NSArray<AVPTrackInfo *> *)getCurrentTrack:(NSInteger)trackType;
- (void)selectTrack:(NSInteger)trackIndex;

// Snapshot
- (void)snapshot;

// Tracing
- (void)setTraceID:(NSString *)traceId;

// Other
- (void)becomeActive;
- (void)resignActive;
- (void)redraw;
- (void)clearScreen;

// Class methods
+ (NSString *)getSDKVersion;
+ (BOOL)isFeatureSupport:(NSInteger)feature;

@end

#pragma mark - AliPlayerGlobalSettings

@interface AliPlayerGlobalSettings : NSObject
+ (void)setEnableLog:(BOOL)enable;
+ (void)setUserAgent:(NSString *)userAgent;
@end

NS_ASSUME_NONNULL_END