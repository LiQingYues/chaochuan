#import "AppDelegate.h"
#import "ChaochuanHost.h"

/// 场景委托：在引擎的 LXSceneDelegate 上加一层，把「用超传打开 / 拷贝到超传」进来的 file URL 交给 ChaochuanHost 排队，
/// 其它 URL（chaochuan:// 深链接）原样交给引擎
@interface ChaochuanSceneDelegate : LXSceneDelegate
@end

static NSArray<NSURL *> *CCFileURLs(NSSet<UIOpenURLContext *> *contexts) {
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (UIOpenURLContext *context in contexts) {
        if (context.URL.isFileURL) [urls addObject:context.URL];
    }
    return urls;
}

@implementation ChaochuanSceneDelegate

// 冷启动：文件 URL 在 connectionOptions.URLContexts 里（引擎也会把它记成 getInitialURL，Lua 侧只认 chaochuan:// 即可）
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    [ChaochuanHost enqueueIncomingURLs:CCFileURLs(options.URLContexts)];
    [super scene:scene willConnectToSession:session options:options];
}

// 运行中：文件 URL 进队列，其余交给引擎
- (void)scene:(UIScene *)scene openURLContexts:(NSSet<UIOpenURLContext *> *)URLContexts {
    [ChaochuanHost enqueueIncomingURLs:CCFileURLs(URLContexts)];
    NSSet *others = [URLContexts objectsPassingTest:^BOOL(UIOpenURLContext *context, BOOL *stop) { return !context.URL.isFileURL; }];
    if (others.count) [super scene:scene openURLContexts:others];
}

@end

@implementation AppDelegate

- (UISceneConfiguration *)application:(UIApplication *)application
    configurationForConnectingSceneSession:(UISceneSession *)session
                                   options:(UISceneConnectionOptions *)options {
    UISceneConfiguration *config = [super application:application configurationForConnectingSceneSession:session options:options];
    config.delegateClass = ChaochuanSceneDelegate.class;
    return config;
}

// 需要注册 App 自己的原生模块 / 组件时取消注释（热更新整体重启时也会再调用）。
// 更简单的方式：实现 LXExport 协议的类不用注册，Lua 里 lx.native("名字").方法() 直接调用（见 LXExport.h）。
// - (void)configureEngine:(LXEngine *)engine {
//     [engine registerModule:[MyModule new]];
// }

@end
