#import <UIKit/UIKit.h>
#import "LXKit.h"

NS_ASSUME_NONNULL_BEGIN

/// 超传宿主原生能力（Lua：lx.native("chaochuanHost")），见 ChaochuanHost.m / docs/native_host.md
@interface ChaochuanHost : NSObject <LXExport>
/// 系统交给本 App 的文件（打开方式 / 分享 / 拷贝到超传）：复制进 tmp/incoming/ 后排队，并给 Lua 发 incomingFiles 事件
+ (void)enqueueIncomingURLs:(NSArray<NSURL *> *)urls;
@end

NS_ASSUME_NONNULL_END
