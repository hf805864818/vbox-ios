//
//  WelfareRemoteAutoLoader.m
//  vbox
//
//  Phase 2 方案 A：完全不动现有代码 — App 启动自动激活
//  作用：通过 Objective-C runtime 的 +load 机制，在 App 启动早期自动调用
//        WelfareRemoteBootstrapGateway.shared.bootstrap()，完全不需要修改任何现有 .swift 文件。
//
//  实现原理：
//        Swift 6 禁止在 Swift 类中定义 class func load()，因此用 Objective-C 文件实现 +load。
//        +load 在类加载时（早于 main）会被调用。本文件定义 WelfareRemoteAutoLoader 类，
//        其 +load 方法会：
//        1. 仅在主 App target 中激活
//        2. dispatch_async 到主线程
//        3. 反射调用 WelfareRemoteBootstrapGateway.shared.bootstrap()
//
//  防御性设计：
//        - bootstrap() 内部已做幂等保护
//        - +load 在主线程之前调用，dispatch_async 到主线程执行
//        - 即使 +load 失败也不影响 App 启动（容错）
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface WelfareRemoteAutoLoader : NSObject
@end

@implementation WelfareRemoteAutoLoader

+ (void)load {
    // 防御：仅在主 App target 中激活，不在 widget/extension 中激活
    if (![[NSBundle mainBundle].bundlePath hasSuffix:@".app"]) {
        return;
    }

    // 在主线程异步执行 bootstrap（+load 阶段不能阻塞）
    dispatch_async(dispatch_get_main_queue(), ^{
        Class gatewayClass = NSClassFromString(@"WelfareRemoteBootstrapGateway");
        if (!gatewayClass) {
            NSLog(@"[WelfareRemote] ⚠️ WelfareRemoteBootstrapGateway 未找到");
            return;
        }

        id sharedInstance = [gatewayClass performSelector:@selector(shared)];
        if (!sharedInstance) {
            NSLog(@"[WelfareRemote] ⚠️ WelfareRemoteBootstrapGateway.shared 返回 nil");
            return;
        }

        [sharedInstance performSelector:@selector(bootstrap)];
        NSLog(@"[WelfareRemote] ✅ +load 已触发 bootstrap");
    });
}

@end
