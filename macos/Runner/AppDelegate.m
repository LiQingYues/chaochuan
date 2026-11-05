#import "AppDelegate.h"

#import "ChaochuanHost.h"

@implementation AppDelegate

// 需要注册 App 自己的原生模块 / 组件时取消注释（⌘R 重载、热更新整体重启时也会再调用）。
// 更简单的方式：实现 LXExport 协议的类不用注册，Lua 里 lx.native("名字").方法() 直接调用（见 LXExport.h）。
// - (void)configureEngine:(LXEngine *)engine {
//     [engine registerModule:[MyModule new]];
// }

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [super applicationDidFinishLaunching:notification];
    // 文件 / 文件夹拖进主窗口 → takeIncomingFiles 队列（chaochuanHost）
    [ChaochuanHost installDropTargetOnWindow:self.host.window];
}

// Finder「打开方式 → 超传」/ 拖到 Dock 图标：文件进队列（启动时的先排队，等 Lua 第一次取）。
// chaochuan:// 深链接一般走 LXLinkingModule 注册的 kAEGetURL，万一到了这里也转给它。
- (void)application:(NSApplication *)application openURLs:(NSArray<NSURL *> *)urls {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (NSURL *url in urls) {
        if (url.isFileURL) {
            if (url.path.length) [paths addObject:url.path];
        } else {
            [LXLinkingModule handleURL:url source:@"scheme"];
        }
    }
    if (paths.count) {
        [ChaochuanHost enqueueIncomingPaths:paths];
        if (self.host.window) [ChaochuanHost showMainWindow];
    }
}

// 菜单栏图标开着（setCloseToTray）时关窗口只隐藏，App 继续接收；关着时关最后一个窗口即退出
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return !ChaochuanHost.closeToTray;
}

// 点 Dock 图标：窗口被关 / 隐藏了就显示出来（父类只在没有可见窗口时 makeKeyAndOrderFront）
- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
    if (!flag) [ChaochuanHost showMainWindow];
    return YES;
}

@end
