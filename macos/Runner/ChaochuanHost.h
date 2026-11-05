// 超传宿主原生能力（macOS）：给 AppDelegate 用的类方法。Lua 侧接口见 docs/native_host.md 和 ChaochuanHost.m。
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface ChaochuanHost : NSObject
/// 系统交给本 App 的文件（打开方式 / 拖到 Dock 图标 / 拖进窗口）进队列，并通知 Lua（incomingFiles）
+ (void)enqueueIncomingPaths:(NSArray<NSString *> *)paths;
/// 主窗口注册文件拖放（App 启动、主窗口建好后调用一次）
+ (void)installDropTargetOnWindow:(NSWindow *)window;
/// 关闭主窗口只隐藏（菜单栏图标开着）
+ (BOOL)closeToTray;
/// 显示并激活主窗口
+ (void)showMainWindow;
@end

NS_ASSUME_NONNULL_END
