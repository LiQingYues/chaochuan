// 超传宿主原生能力（Lua：lx.native("chaochuanHost")，经 lua/core/host.lua 调用；约定见 docs/native_host.md）
//   pickFiles({ folder, multiple }, cb)   系统文件选择器（UIDocumentPickerViewController），选中内容复制到 tmp/picked/ → { paths }
//   openPath({ path, reveal }, cb)        系统预览（UIDocumentInteractionController），预览不了退回分享面板 → { ok }
//   takeIncomingFiles()                   取出并清空「用超传打开 / 拷贝到超传」进来的文件 → { paths }
//   事件 incomingFiles { count }          App 运行中有新的待取文件
//   interfaces()                          本机 IPv4（Wi‑Fi en0 排前面，跳过回环 / 蜂窝 / VPN）→ { list = { { name, ip } } }
//   桌面专用方法（pickDirectory / setCloseToTray / showWindow / hideWindow / setLaunchAtLogin / getLaunchAtLogin /
//   setContextMenu）在 iOS 上返回 { supported = false }
// 进来的文件由 AppDelegate.m 的 ChaochuanSceneDelegate 交给 +enqueueIncomingURLs:。
#import "ChaochuanHost.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <ifaddrs.h>
#include <arpa/inet.h>
#include <net/if.h>

// ---------------------------------------------------------------- 工具

static UIViewController *CCTopViewController(void) {
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.isKeyWindow) { window = w; break; }
            if (!window && w.rootViewController) window = w;
        }
        if (window.isKeyWindow) break;
    }
    UIViewController *vc = window.rootViewController;
    while (vc.presentedViewController && !vc.presentedViewController.isBeingDismissed) vc = vc.presentedViewController;
    return vc;
}

/// dir/name 不存在就用它，否则 name (1).ext、name (2).ext …
static NSURL *CCUniqueURL(NSURL *dir, NSString *name) {
    if (name.length == 0) name = @"file";
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *url = [dir URLByAppendingPathComponent:name];
    NSString *base = name.stringByDeletingPathExtension, *ext = name.pathExtension;
    for (NSInteger i = 1; [fm fileExistsAtPath:url.path]; i++) {
        NSString *n = [NSString stringWithFormat:@"%@ (%ld)", base, (long)i];
        if (ext.length) n = [n stringByAppendingPathExtension:ext];
        url = [dir URLByAppendingPathComponent:n];
    }
    return url;
}

/// tmp/<sub>/<uuid>/
static NSURL *CCFreshDir(NSString *sub) {
    NSURL *dir = [[[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES] URLByAppendingPathComponent:sub isDirectory:YES]
        URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

/// 把 src（文件或文件夹，可能是安全作用域 URL）复制进 dir，保留原名（重名加序号）。move = YES 时先尝试移动（src 是本 App 的临时副本）
static NSString *CCImport(NSURL *src, NSURL *dir, BOOL move) {
    BOOL scoped = [src startAccessingSecurityScopedResource];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *dst = CCUniqueURL(dir, src.lastPathComponent);
    NSError *err = nil;
    BOOL ok = move && [fm moveItemAtURL:src toURL:dst error:nil];
    if (!ok) {
        // 文件协调：iCloud 等文件提供方的文件可能还没下载
        __block BOOL copied = NO;
        __block NSError *copyErr = nil;
        NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
        [coordinator coordinateReadingItemAtURL:src options:NSFileCoordinatorReadingWithoutChanges error:&err byAccessor:^(NSURL *readURL) {
            copied = [fm copyItemAtURL:readURL toURL:dst error:&copyErr];
        }];
        ok = copied;
        if (!ok) NSLog(@"[chaochuanHost] 复制失败 %@：%@", src, copyErr ?: err);
    }
    if (scoped) [src stopAccessingSecurityScopedResource];
    return ok ? dst.path : nil;
}

static id CCUnsupported(void) { return @{ @"supported": @NO }; }

// ---------------------------------------------------------------- 文件选择器委托（选择器显示期间由 host 持有）

@interface CCPickerDelegate : NSObject <UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate>
@property (nonatomic, assign) BOOL folder;
@property (nonatomic, copy, nullable) LXCallback callback;
@property (nonatomic, copy, nullable) void (^finished)(void);
@end

@implementation CCPickerDelegate

- (void)finishWithPaths:(NSArray<NSString *> *)paths {
    LXCallback cb = self.callback;
    self.callback = nil;
    if (cb) cb(@{ @"paths": paths }, nil);
    if (self.finished) self.finished();
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    BOOL folder = self.folder;
    // 复制可能较慢（大文件 / 文件夹），放到后台
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSURL *dir = CCFreshDir(@"picked");
        NSMutableArray<NSString *> *paths = [NSMutableArray array];
        for (NSURL *url in urls) {
            NSString *p = CCImport(url, dir, !folder);
            if (p) [paths addObject:p];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ [self finishWithPaths:paths]; });
    });
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    [self finishWithPaths:@[]];
}

// 下滑关闭（iOS 某些版本不回调 documentPickerWasCancelled）
- (void)presentationControllerDidDismiss:(UIPresentationController *)presentationController {
    [self finishWithPaths:@[]];
}

@end

// ---------------------------------------------------------------- ChaochuanHost

static NSMutableArray<NSString *> *gIncoming;
static NSHashTable<ChaochuanHost *> *gHosts;

@interface ChaochuanHost () <UIDocumentInteractionControllerDelegate>
@property (nonatomic, strong, nullable) CCPickerDelegate *picker;
@property (nonatomic, strong, nullable) UIDocumentInteractionController *docController;
@end

@implementation ChaochuanHost
LX_EXPORT_AS(chaochuanHost)

+ (void)initialize {
    if (self != ChaochuanHost.class) return;
    gIncoming = [NSMutableArray array];
    gHosts = [NSHashTable weakObjectsHashTable];
}

+ (NSArray<NSString *> *)lxExportedMethods {
    return @[ @"pickFiles", @"pickDirectory", @"openPath", @"takeIncomingFiles", @"interfaces",
              @"setCloseToTray", @"showWindow", @"hideWindow", @"setLaunchAtLogin", @"getLaunchAtLogin", @"setContextMenu" ];
}

- (instancetype)init {
    if ((self = [super init])) {
        @synchronized (ChaochuanHost.class) { [gHosts addObject:self]; }
    }
    return self;
}

// ---------------- 进来的文件

+ (void)enqueueIncomingURLs:(NSArray<NSURL *> *)urls {
    if (urls.count == 0) return;
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("chaochuan.incoming", DISPATCH_QUEUE_SERIAL); });
    // 复制放到后台串行队列（大文件不卡主线程，顺序保持）
    dispatch_async(queue, ^{ [self importIncomingURLs:urls]; });
}

+ (void)importIncomingURLs:(NSArray<NSURL *> *)urls {
    NSURL *dir = CCFreshDir(@"incoming");
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (NSURL *url in urls) {
        // 「拷贝到超传」的文件在 Documents/Inbox 里，属于本 App，移动过来；「原地打开」的是安全作用域 URL，复制
        BOOL ownInbox = [url.path containsString:@"/Documents/Inbox/"];
        NSString *p = CCImport(url, dir, ownInbox);
        if (p) [paths addObject:p];
    }
    if (paths.count == 0) return;
    NSUInteger count;
    NSArray<ChaochuanHost *> *hosts;
    @synchronized (ChaochuanHost.class) {
        [gIncoming addObjectsFromArray:paths];
        count = gIncoming.count;
        hosts = gHosts.allObjects;
    }
    for (ChaochuanHost *host in hosts) [host lx_emit:@"incomingFiles" payload:@{ @"count": @(count) }];
}

- (NSDictionary *)takeIncomingFiles {
    NSArray *paths;
    @synchronized (ChaochuanHost.class) {
        paths = [gIncoming copy];
        [gIncoming removeAllObjects];
    }
    return @{ @"paths": paths };
}

// ---------------- pickFiles

- (void)pickFiles:(NSDictionary *)args callback:(LXCallback)callback {
    BOOL folder = [args[@"folder"] respondsToSelector:@selector(boolValue)] && [args[@"folder"] boolValue];
    BOOL multiple = [args[@"multiple"] respondsToSelector:@selector(boolValue)] && [args[@"multiple"] boolValue];
    UIViewController *top = CCTopViewController();
    if (!top) { callback(@{ @"paths": @[] }, nil); return; }
    if (self.picker) [self.picker finishWithPaths:@[]];   // 上一次的还没结束（理论上不会）

    UIDocumentPickerViewController *vc = folder
        ? [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypeFolder ] asCopy:NO]
        : [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypeItem ] asCopy:YES];
    vc.allowsMultipleSelection = multiple;
    vc.shouldShowFileExtensions = YES;

    CCPickerDelegate *delegate = [CCPickerDelegate new];
    delegate.folder = folder;
    delegate.callback = callback;
    __weak typeof(self) weakSelf = self;
    __weak CCPickerDelegate *weakDelegate = delegate;
    delegate.finished = ^{
        __strong typeof(weakSelf) s = weakSelf;
        if (s && s.picker == weakDelegate) s.picker = nil;
    };
    self.picker = delegate;
    vc.delegate = delegate;
    vc.presentationController.delegate = delegate;
    [top presentViewController:vc animated:YES completion:nil];
}

// ---------------- openPath

- (void)openPath:(NSDictionary *)args callback:(LXCallback)callback {
    NSString *path = [args[@"path"] isKindOfClass:NSString.class] ? args[@"path"] : @"";
    BOOL isDir = NO;
    if (path.length == 0 || ![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDir]) {
        callback(@{ @"ok": @NO }, nil);
        return;
    }
    UIViewController *top = CCTopViewController();
    if (!top) { callback(@{ @"ok": @NO }, nil); return; }
    NSURL *url = [NSURL fileURLWithPath:path isDirectory:isDir];

    if (!isDir) {
        UIDocumentInteractionController *doc = [UIDocumentInteractionController interactionControllerWithURL:url];
        doc.delegate = self;
        self.docController = doc;
        if ([doc presentPreviewAnimated:YES]) { callback(@{ @"ok": @YES }, nil); return; }
        self.docController = nil;
    }
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[ url ] applicationActivities:nil];
    UIPopoverPresentationController *popover = share.popoverPresentationController;
    if (popover) {   // iPad：从屏幕中间弹出
        popover.sourceView = top.view;
        popover.sourceRect = CGRectMake(CGRectGetMidX(top.view.bounds), CGRectGetMidY(top.view.bounds), 0, 0);
        popover.permittedArrowDirections = 0;
    }
    [top presentViewController:share animated:YES completion:nil];
    callback(@{ @"ok": @YES }, nil);
}

- (UIViewController *)documentInteractionControllerViewControllerForPreview:(UIDocumentInteractionController *)controller {
    return CCTopViewController();
}

- (void)documentInteractionControllerDidEndPreview:(UIDocumentInteractionController *)controller {
    if (self.docController == controller) self.docController = nil;
}

// ---------------- interfaces

- (NSDictionary *)interfaces {
    NSMutableArray *wifi = [NSMutableArray array], *others = [NSMutableArray array];
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) == 0) {
        for (struct ifaddrs *ifa = list; ifa; ifa = ifa->ifa_next) {
            if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET) continue;
            if (!(ifa->ifa_flags & IFF_UP) || (ifa->ifa_flags & IFF_LOOPBACK)) continue;
            NSString *name = [NSString stringWithUTF8String:ifa->ifa_name];
            BOOL skip = NO;
            for (NSString *prefix in @[ @"lo", @"pdp_ip", @"utun", @"ipsec", @"awdl", @"llw", @"bridge", @"tun", @"ppp", @"gif", @"stf", @"anpi", @"ap" ]) {
                if ([name hasPrefix:prefix]) { skip = YES; break; }
            }
            if (skip) continue;
            char buf[INET_ADDRSTRLEN] = {0};
            if (!inet_ntop(AF_INET, &((struct sockaddr_in *)ifa->ifa_addr)->sin_addr, buf, sizeof(buf))) continue;
            NSString *ip = [NSString stringWithUTF8String:buf];
            if ([ip hasPrefix:@"169.254."]) continue;   // 链路本地（没拿到 DHCP 地址）
            NSDictionary *item = @{ @"name": name, @"ip": ip };
            if ([name isEqualToString:@"en0"]) [wifi addObject:item];
            else [others addObject:item];
        }
        freeifaddrs(list);
    }
    [wifi addObjectsFromArray:others];
    return @{ @"list": wifi };
}

// ---------------- 桌面专用

- (void)pickDirectory:(NSDictionary *)args callback:(LXCallback)callback { callback(CCUnsupported(), nil); }
- (NSDictionary *)setCloseToTray:(NSDictionary *)args { return CCUnsupported(); }
- (NSDictionary *)showWindow { return CCUnsupported(); }
- (NSDictionary *)hideWindow { return CCUnsupported(); }
- (NSDictionary *)setLaunchAtLogin:(NSDictionary *)args { return CCUnsupported(); }
- (NSDictionary *)getLaunchAtLogin { return CCUnsupported(); }
- (NSDictionary *)setContextMenu:(NSDictionary *)args { return CCUnsupported(); }

@end
