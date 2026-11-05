// 超传宿主原生能力（macOS 版，Lua：lx.native("chaochuanHost")，契约见 docs/native_host.md）：
//   pickFiles({ folder, multiple }, cb)   NSOpenPanel → { paths }（取消为空表）
//   pickDirectory({}, cb)                 选目录 → { path }（取消为空串）
//   openPath({ path, reveal }, cb)        默认程序打开 / Finder 里选中 → { ok }
//   takeIncomingFiles()                   取出并清空待处理文件（打开方式 / 拖到 Dock 图标 / 拖进窗口）→ { paths }
//   事件 incomingFiles { count }          有新的待取文件
//   interfaces()                          本机 IPv4（跳过回环 / VPN / AirDrop 等，en* 排前）→ { list = { { name, ip } } }
//   setCloseToTray({ enabled })           菜单栏图标 + 关窗口只隐藏 → { ok }
//   showWindow() / hideWindow()           → { ok }
//   setLaunchAtLogin({ enabled })         SMAppService.mainAppService → { ok, error? }
//   getLaunchAtLogin()                    → { enabled }
//   setContextMenu()                      macOS 不支持 → { supported = false, ok = false }
// 注意：布尔一律 @YES / @NO（@(表达式) 到 Lua 是数字 0 / 1，0 在 Lua 里为真）。
#import "ChaochuanHost.h"

#import <ServiceManagement/ServiceManagement.h>
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <objc/runtime.h>

#import "LXMacKit.h"

#pragma mark - 共享状态（跨引擎重载保留）

static NSMutableArray<NSString *> *gIncoming;   // 待 Lua 取走的文件路径
static __weak ChaochuanHost *gLiveHost;          // 最近由引擎创建的实例（用来 lx_emit）
static BOOL gCloseToTray;
static NSStatusItem *gStatusItem;

static NSMutableArray<NSString *> *IncomingQueue(void) {
    if (!gIncoming) gIncoming = [NSMutableArray array];
    return gIncoming;
}

static NSWindow *MainWindow(void) {
    id delegate = NSApp.delegate;
    if ([delegate isKindOfClass:LXAppDelegate.class]) {
        NSWindow *w = ((LXAppDelegate *)delegate).host.window;
        if (w) return w;
    }
    return NSApp.mainWindow ?: NSApp.keyWindow;
}

static NSString *StringArg(NSDictionary *args, NSString *key) {
    id v = [args isKindOfClass:NSDictionary.class] ? args[key] : nil;
    return [v isKindOfClass:NSString.class] ? v : @"";
}

static BOOL BoolArg(NSDictionary *args, NSString *key, BOOL fallback) {
    id v = [args isKindOfClass:NSDictionary.class] ? args[key] : nil;
    if ([v isKindOfClass:NSNumber.class]) return [v boolValue];
    if ([v isKindOfClass:NSString.class]) return [v boolValue];
    return fallback;
}

/// 拖放板上的文件 URL → 本机路径
static NSArray<NSString *> *FilePathsFromPasteboard(NSPasteboard *pb) {
    NSArray<NSURL *> *urls = [pb readObjectsForClasses:@[ NSURL.class ]
                                               options:@{ NSPasteboardURLReadingFileURLsOnlyKey: @YES }];
    NSMutableArray *paths = [NSMutableArray array];
    for (NSURL *u in urls) {
        if (u.isFileURL && u.path.length > 0) [paths addObject:u.path];
    }
    return paths;
}

#pragma mark - 主窗口拖放（运行时给主窗口生成子类，不碰引擎的视图层级；引擎内容视图照常收点击）

static NSDragOperation CCDraggingEntered(id self, SEL _cmd, id<NSDraggingInfo> info) {
    if (FilePathsFromPasteboard(info.draggingPasteboard).count > 0) return NSDragOperationCopy;
    IMP sup = class_getMethodImplementation(class_getSuperclass(object_getClass(self)), _cmd);
    return sup ? ((NSDragOperation(*)(id, SEL, id))sup)(self, _cmd, info) : NSDragOperationNone;
}

static BOOL CCPrepareForDrag(id self, SEL _cmd, id<NSDraggingInfo> info) {
    return FilePathsFromPasteboard(info.draggingPasteboard).count > 0;
}

static BOOL CCPerformDrag(id self, SEL _cmd, id<NSDraggingInfo> info) {
    NSArray *paths = FilePathsFromPasteboard(info.draggingPasteboard);
    if (paths.count == 0) return NO;
    [ChaochuanHost enqueueIncomingPaths:paths];
    [NSApp activateIgnoringOtherApps:YES];
    return YES;
}

static BOOL CCWantsPeriodicDraggingUpdates(id self, SEL _cmd) {
    return NO;
}

#pragma mark - 菜单栏图标（模板图：双箭头 »）

static NSImage *TrayImage(void) {
    NSImage *img = [NSImage imageWithSize:NSMakeSize(18, 18) flipped:NO drawingHandler:^BOOL(NSRect r) {
        NSBezierPath *p = [NSBezierPath bezierPath];
        p.lineWidth = 2.0;
        p.lineCapStyle = NSLineCapStyleRound;
        p.lineJoinStyle = NSLineJoinStyleRound;
        CGFloat xs[2] = { 3.5, 9.5 };
        for (int i = 0; i < 2; i++) {
            [p moveToPoint:NSMakePoint(xs[i], 3.5)];
            [p lineToPoint:NSMakePoint(xs[i] + 5.5, 9)];
            [p lineToPoint:NSMakePoint(xs[i], 14.5)];
        }
        [NSColor.blackColor setStroke];
        [p stroke];
        return YES;
    }];
    img.template = YES;
    return img;
}

@interface ChaochuanTrayTarget : NSObject
@end

@implementation ChaochuanTrayTarget
- (void)showApp:(id)sender { [ChaochuanHost showMainWindow]; }
- (void)quitApp:(id)sender { [NSApp terminate:nil]; }
@end

static ChaochuanTrayTarget *gTrayTarget;

static void InstallStatusItem(void) {
    if (gStatusItem) return;
    if (!gTrayTarget) gTrayTarget = [ChaochuanTrayTarget new];
    gStatusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSSquareStatusItemLength];
    gStatusItem.button.image = TrayImage();
    gStatusItem.button.toolTip = @"超传";
    NSMenu *menu = [NSMenu new];
    NSMenuItem *show = [[NSMenuItem alloc] initWithTitle:@"显示超传" action:@selector(showApp:) keyEquivalent:@""];
    show.target = gTrayTarget;
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"退出超传" action:@selector(quitApp:) keyEquivalent:@""];
    quit.target = gTrayTarget;
    [menu addItem:show];
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItem:quit];
    gStatusItem.menu = menu;
}

static void RemoveStatusItem(void) {
    if (!gStatusItem) return;
    [NSStatusBar.systemStatusBar removeStatusItem:gStatusItem];
    gStatusItem = nil;
}

#pragma mark -

@interface ChaochuanHost () <LXExport>
@end

@implementation ChaochuanHost
LX_EXPORT_AS(chaochuanHost)

+ (NSArray<NSString *> *)lxExportedMethods {
    return @[ @"pickFiles", @"pickDirectory", @"openPath", @"takeIncomingFiles", @"interfaces",
              @"setCloseToTray", @"showWindow", @"hideWindow", @"setLaunchAtLogin", @"getLaunchAtLogin",
              @"setContextMenu" ];
}

- (instancetype)initWithEngine:(LXEngine *)engine {
    if ((self = [super init])) gLiveHost = self;
    return self;
}

- (instancetype)init {
    if ((self = [super init])) gLiveHost = self;
    return self;
}

#pragma mark 类方法（AppDelegate 用）

+ (void)enqueueIncomingPaths:(NSArray<NSString *> *)paths {
    dispatch_block_t work = ^{
        NSMutableArray *queue = IncomingQueue();
        NSUInteger added = 0;
        for (NSString *p in paths) {
            if (![p isKindOfClass:NSString.class] || p.length == 0 || [queue containsObject:p]) continue;
            [queue addObject:p];
            added++;
        }
        if (added > 0) [gLiveHost lx_emit:@"incomingFiles" payload:@{ @"count": @(queue.count) }];
    };
    if (NSThread.isMainThread) work(); else dispatch_async(dispatch_get_main_queue(), work);
}

+ (void)installDropTargetOnWindow:(NSWindow *)window {
    if (!window) return;
    Class cur = object_getClass(window);
    if ([NSStringFromClass(cur) hasPrefix:@"ChaochuanDrop_"]) return;
    NSString *name = [@"ChaochuanDrop_" stringByAppendingString:NSStringFromClass(cur)];
    Class sub = NSClassFromString(name);
    if (!sub) {
        sub = objc_allocateClassPair(cur, name.UTF8String, 0);
        if (!sub) return;
        class_addMethod(sub, @selector(draggingEntered:), (IMP)CCDraggingEntered, "Q@:@");
        class_addMethod(sub, @selector(draggingUpdated:), (IMP)CCDraggingEntered, "Q@:@");
        class_addMethod(sub, @selector(prepareForDragOperation:), (IMP)CCPrepareForDrag, "c@:@");
        class_addMethod(sub, @selector(performDragOperation:), (IMP)CCPerformDrag, "c@:@");
        class_addMethod(sub, @selector(wantsPeriodicDraggingUpdates), (IMP)CCWantsPeriodicDraggingUpdates, "c@:");
        objc_registerClassPair(sub);
    }
    object_setClass(window, sub);
    [window registerForDraggedTypes:@[ NSPasteboardTypeFileURL ]];
}

+ (BOOL)closeToTray {
    return gCloseToTray;
}

+ (void)showMainWindow {
    NSWindow *w = MainWindow();
    [NSApp unhide:nil];
    if (w.isMiniaturized) [w deminiaturize:nil];
    [w makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

#pragma mark 文件选择

- (void)runPanel:(NSOpenPanel *)panel completion:(void (^)(NSArray<NSURL *> *urls))completion {
    [NSApp activateIgnoringOtherApps:YES];
    NSWindow *w = MainWindow();
    void (^done)(NSModalResponse) = ^(NSModalResponse r) {
        completion(r == NSModalResponseOK ? panel.URLs : @[]);
    };
    if (w.isVisible && !w.attachedSheet) [panel beginSheetModalForWindow:w completionHandler:done];
    else [panel beginWithCompletionHandler:done];
}

- (void)pickFiles:(NSDictionary *)args callback:(LXCallback)callback {
    BOOL folder = BoolArg(args, @"folder", NO);
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = !folder;
    panel.canChooseDirectories = folder;
    panel.allowsMultipleSelection = BoolArg(args, @"multiple", !folder);
    panel.resolvesAliases = YES;
    panel.prompt = folder ? @"选择文件夹" : @"选择";
    [self runPanel:panel completion:^(NSArray<NSURL *> *urls) {
        NSMutableArray *paths = [NSMutableArray array];
        for (NSURL *u in urls) if (u.path.length) [paths addObject:u.path];
        callback(@{ @"paths": paths }, nil);
    }];
}

- (void)pickDirectory:(NSDictionary *)args callback:(LXCallback)callback {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = NO;
    panel.canChooseDirectories = YES;
    panel.canCreateDirectories = YES;
    panel.allowsMultipleSelection = NO;
    panel.prompt = @"选择";
    NSString *current = StringArg(args, @"path");
    if (current.length) panel.directoryURL = [NSURL fileURLWithPath:current isDirectory:YES];
    [self runPanel:panel completion:^(NSArray<NSURL *> *urls) {
        callback(@{ @"path": urls.firstObject.path ?: @"" }, nil);
    }];
}

#pragma mark 打开 / 显示文件

- (void)openPath:(NSDictionary *)args callback:(LXCallback)callback {
    NSString *path = StringArg(args, @"path");
    if (path.length == 0 || ![NSFileManager.defaultManager fileExistsAtPath:path]) {
        callback(@{ @"ok": @NO }, nil);
        return;
    }
    NSURL *url = [NSURL fileURLWithPath:path];
    BOOL ok;
    if (BoolArg(args, @"reveal", NO)) {
        [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[ url ]];
        ok = YES;
    } else {
        ok = [NSWorkspace.sharedWorkspace openURL:url];
    }
    callback(@{ @"ok": ok ? @YES : @NO }, nil);
}

#pragma mark 传入文件

- (NSDictionary *)takeIncomingFiles:(NSDictionary *)args {
    gLiveHost = self;
    NSArray *paths = [IncomingQueue() copy];
    [IncomingQueue() removeAllObjects];
    return @{ @"paths": paths };
}

#pragma mark 网卡

- (NSDictionary *)interfaces:(NSDictionary *)args {
    NSMutableArray<NSDictionary *> *list = [NSMutableArray array];
    struct ifaddrs *addrs = NULL;
    if (getifaddrs(&addrs) == 0) {
        NSArray *skip = @[ @"lo", @"utun", @"tun", @"tap", @"ipsec", @"ppp", @"bridge", @"awdl", @"llw",
                           @"gif", @"stf", @"anpi", @"vmnet", @"pdp_ip" ];
        NSMutableSet *seen = [NSMutableSet set];
        for (struct ifaddrs *a = addrs; a; a = a->ifa_next) {
            if (!a->ifa_addr || a->ifa_addr->sa_family != AF_INET) continue;
            if (!(a->ifa_flags & IFF_UP) || (a->ifa_flags & IFF_LOOPBACK)) continue;
            NSString *name = @(a->ifa_name);
            BOOL bad = NO;
            for (NSString *pre in skip) if ([name hasPrefix:pre]) { bad = YES; break; }
            if (bad) continue;
            char buf[INET_ADDRSTRLEN] = {0};
            const struct sockaddr_in *sin = (const struct sockaddr_in *)a->ifa_addr;
            if (!inet_ntop(AF_INET, &sin->sin_addr, buf, sizeof buf)) continue;
            NSString *ip = @(buf);
            if ([ip hasPrefix:@"169.254."] || [ip hasPrefix:@"127."]) continue;
            NSString *key = [NSString stringWithFormat:@"%@|%@", name, ip];
            if ([seen containsObject:key]) continue;
            [seen addObject:key];
            [list addObject:@{ @"name": name, @"ip": ip }];
        }
        freeifaddrs(addrs);
    }
    [list sortWithOptions:NSSortStable usingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        BOOL ea = [a[@"name"] hasPrefix:@"en"], eb = [b[@"name"] hasPrefix:@"en"];
        if (ea != eb) return ea ? NSOrderedAscending : NSOrderedDescending;
        if (ea) return [a[@"name"] compare:b[@"name"] options:NSNumericSearch];
        return NSOrderedSame;
    }];
    return @{ @"list": list };
}

#pragma mark 托盘 / 窗口

- (NSDictionary *)setCloseToTray:(NSDictionary *)args {
    gCloseToTray = BoolArg(args, @"enabled", NO);
    if (gCloseToTray) InstallStatusItem(); else RemoveStatusItem();
    return @{ @"ok": @YES };
}

- (NSDictionary *)showWindow:(NSDictionary *)args {
    [ChaochuanHost showMainWindow];
    return @{ @"ok": @YES };
}

- (NSDictionary *)hideWindow:(NSDictionary *)args {
    NSWindow *w = MainWindow();
    if (!w) return @{ @"ok": @NO };
    [w orderOut:nil];
    return @{ @"ok": @YES };
}

#pragma mark 开机自启

- (NSDictionary *)setLaunchAtLogin:(NSDictionary *)args {
    BOOL enabled = BoolArg(args, @"enabled", NO);
    if (@available(macOS 13.0, *)) {
        SMAppService *svc = SMAppService.mainAppService;
        NSError *error = nil;
        BOOL ok;
        if (enabled) {
            ok = svc.status == SMAppServiceStatusEnabled || [svc registerAndReturnError:&error];
        } else {
            ok = svc.status == SMAppServiceStatusNotRegistered || svc.status == SMAppServiceStatusNotFound
                 || [svc unregisterAndReturnError:&error];
        }
        if (ok && enabled && svc.status == SMAppServiceStatusRequiresApproval) {
            return @{ @"ok": @NO, @"error": @"需要在「系统设置 → 通用 → 登录项」里允许超传" };
        }
        if (!ok) return @{ @"ok": @NO, @"error": error.localizedDescription ?: @"设置开机自启失败" };
        return @{ @"ok": @YES };
    }
    return @{ @"ok": @NO, @"supported": @NO, @"error": @"需要 macOS 13 或更高版本" };
}

- (NSDictionary *)getLaunchAtLogin:(NSDictionary *)args {
    if (@available(macOS 13.0, *)) {
        return @{ @"enabled": SMAppService.mainAppService.status == SMAppServiceStatusEnabled ? @YES : @NO };
    }
    return @{ @"enabled": @NO, @"supported": @NO };
}

#pragma mark 右键菜单（Windows 才有）

- (NSDictionary *)setContextMenu:(NSDictionary *)args {
    return @{ @"supported": @NO, @"ok": @NO };
}

@end
