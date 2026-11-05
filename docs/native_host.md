# 宿主原生能力：`chaochuanHost`（四个平台同名同参）

lx 引擎没有的系统能力（文件选择器、托盘、开机自启、拖拽、「打开方式 / 分享到超传」…）由各平台宿主工程实现，
Lua 统一经 `lua/core/host.lua` 调用（不直接调原生）。

| 平台 | 实现位置 | Lua 侧怎么调 |
|---|---|---|
| macOS | `macos/Runner/ChaochuanHost.m`（`LXExport`，`LX_EXPORT_AS(chaochuanHost)`） | `lx.native("chaochuanHost")` |
| iOS | `ios/Runner/ChaochuanHost.m`（同上） | `lx.native("chaochuanHost")` |
| Android | `android/app/src/main/kotlin/com/chaochuan/chaochuan/ChaochuanHost.kt`（`@LXExport("chaochuanHost")`） | `lx.native("chaochuanHost")` |
| Windows | `windows/Runner/ChaochuanHost.{h,cpp}`（`lxwin::Module` 子类，名字 `chaochuanHost`，在 `Main.cpp` 的 `configureEngine` 里注册） | `lx.bridge.call("chaochuanHost", 方法, 参数, 回调)`，事件用 `lx.bridge.on("chaochuanHost", 事件, fn)` |

异步方法：最后一个参数是回调 `cb(result, err)`；`result` 一律是表。同步方法直接返回表 / 值。
路径一律是本机绝对路径（UTF-8）。不支持的方法返回 `{ supported = false }`，**不要抛错**。

## 所有平台

| 方法 | 类型 | 参数 → 结果 | 说明 |
|---|---|---|---|
| `pickFiles` | 异步 | `{ folder = bool, multiple = bool }` → `{ paths = { … } }` | 系统文件选择器；取消 → `paths = {}`。`folder = true` 选文件夹（返回文件夹路径，Lua 自己遍历）。**移动端**：iOS `UIDocumentPickerViewController`（`asCopy`），Android SAF `ACTION_OPEN_DOCUMENT`（多选）/ `ACTION_OPEN_DOCUMENT_TREE`；选中的内容**复制到 App 的临时目录**（保留原文件名，重名加序号），返回复制后的路径，保证 Lua 的 `io.open` 能读 |
| `pickDirectory` | 异步 | `{}` → `{ path = "…" }`（取消为空串） | 选择目录（桌面：改接收目录）。移动端返回 `{ supported = false }` |
| `openPath` | 异步 | `{ path, reveal = bool }` → `{ ok = bool }` | 桌面：`reveal = false` 用默认程序打开，`true` 在 Finder / 资源管理器里选中显示；目录直接打开。移动端：系统预览 / 分享面板（iOS `UIDocumentInteractionController` 或 `UIActivityViewController`，Android `ACTION_VIEW` + FileProvider，失败退回分享） |
| `takeIncomingFiles` | 同步 | `{}` → `{ paths = { … } }` | 取出（并清空）系统交给本 App 的文件：打开方式 / 分享 / 拖到窗口或 Dock 图标 / 右键菜单 / 命令行参数。启动时的也要排队，等 Lua 第一次取 |
| 事件 `incomingFiles` | 事件 | payload `{ count = n }` | 有新的待取文件时发（App 运行中）；Lua 收到后调 `takeIncomingFiles` |
| `interfaces` | 同步 | `{}` → `{ list = { { name = "en0", ip = "192.168.1.5" } } }` | 本机 IPv4（跳过回环、VPN：tun / ppp / utun / ipsec、蜂窝），Wi‑Fi / 以太网排前面 |

## 只有桌面（macOS / Windows），移动端返回 `{ supported = false }`

| 方法 | 类型 | 参数 → 结果 | 说明 |
|---|---|---|---|
| `setCloseToTray` | 同步 | `{ enabled = bool }` → `{ ok }` | 开：显示托盘 / 菜单栏图标（菜单：显示超传、退出），**关闭主窗口只隐藏、App 继续运行接收**；点托盘图标显示窗口。关：去掉图标，关窗口即退出（macOS 关最后一个窗口退出） |
| `showWindow` / `hideWindow` | 同步 | `{}` → `{ ok }` | 显示（并激活到前台）/ 隐藏主窗口 |
| `setLaunchAtLogin` | 同步 | `{ enabled = bool }` → `{ ok, error? }` | macOS 13+ `SMAppService.mainAppService`；Windows `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`（值为带引号的 exe 路径） |
| `getLaunchAtLogin` | 同步 | `{}` → `{ enabled = bool }` | 读系统真实状态 |
| `setContextMenu` | 同步 | `{ enabled = bool }` → `{ ok, supported }` | Windows：`HKCU\Software\Classes\*\shell\chaochuan` 和 `Directory\shell\chaochuan`，菜单文字「用超传发送」，图标为 exe，命令 `"exe" "%1"`。macOS 返回 `{ supported = false }`（macOS 用「打开方式 → 超传」和拖到 Dock 图标代替，总是可用） |
| 拖拽 | — | — | 文件 / 文件夹拖进主窗口 → 进入 `takeIncomingFiles` 队列并发 `incomingFiles` |
| 单实例（Windows） | — | — | 已在运行时再次启动（右键菜单 / 双击文件）：把命令行里的路径转交给已运行的实例（加入它的队列并显示窗口），新进程退出 |

## Info.plist / Manifest 要求

- macOS：`CFBundleDocumentTypes` 接受任何文件和文件夹（`public.item`、`public.folder`，`LSHandlerRank = Alternate`），这样 Finder「打开方式」里有超传；`application:openURLs:` 进队列。
- iOS：`CFBundleDocumentTypes`（`public.item`、`public.content`，`LSHandlerRank = Alternate`）+ `LSSupportsOpeningDocumentsInPlace` → 分享面板 / 「文件」App 里「用超传打开」；`openURL` / `scene:openURLContexts:` 里 **非 `chaochuan://` 的 file URL** 复制进临时目录后进队列（安全作用域 URL 要 `startAccessingSecurityScopedResource`）；`chaochuan://` 深链接照旧交给引擎。
- Android：`MainActivity` 加 intent-filter：`ACTION_SEND` / `ACTION_SEND_MULTIPLE`（`*/*`）、`ACTION_VIEW`（`*/*`，content / file）；`onCreate` 和 `onNewIntent` 里把 URI 复制到缓存目录后进队列。
