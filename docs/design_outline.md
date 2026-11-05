# 超传（lquicktransfer）— 大纲设计

> **已定（2026-11-05）**：App 名「超传」，品牌色红色；**与 LocalSend 协议 v2.1 兼容并覆盖其全部功能**（清单见 `docs/localsend_features.md`）；鸿蒙暂不做。
> 下文 §4 的自定义协议作废，改为 LocalSend 协议（端口 53317、组播 224.0.0.167、`/api/localsend/v2/*`、HTTPS 自签证书 + 指纹）；
> 断点续传等超出 LocalSend 的能力只在双方都是超传时启用（`/info` 里带扩展字段协商），对端是 LocalSend 时回落到标准流程。

> 结构：lx 引擎，Lua 写界面和业务，各平台宿主工程只链 lx SDK；重活放 `native/` 下的 C++ / libhv 模块，经 `lx.native` 给 Lua 调。
> 状态：大纲，待确认后再细化协议和逐模块设计。

---

## 1. 目标与范围

| | MVP（第一版） | 之后 |
|---|---|---|
| 平台 | Windows / macOS / iOS / Android（lx 宿主工程） | Harmony；Web 只做「浏览器收发页」（见 §4.5） |
| 发现 | 同一局域网自动发现设备 + 手动输 IP / 扫码连接 | 跨网段（热点 / 中继） |
| 传输 | 文件、多文件、文件夹、文本 / 剪贴板；断点续传；进度 / 速度 | 端到端加密强制开、增量同步、限速 |
| 安全 | 接收方确认弹窗；可信设备免确认；可选 PIN | TLS 证书指纹绑定 |
| 体验 | 发送队列、历史记录、收到后打开 / 定位 / 存相册 | 拖拽投递（桌面）、系统分享入口（iOS Share Extension / Android 分享） |

非目标：云端中转、账号体系、广域网穿透。

## 2. 技术选型与分工

```
┌──────────────── Lua（lua/）────────────────┐
│ 页面 / 组件 / 状态机 / 历史记录 / 设置       │   lx 组件、lx.storage、lx.db
│ modules/*  ←── 事件（发现、进度、请求）───┐  │
└───────────── lx.native("lqt") ───────────┼──┘
┌──────────── C++ 核心（native/lqt_core）──┼───┐
│ libhv 事件循环线程：                      │   │
│  • 发现：UDP 组播 announce / 应答        ─┘   │
│  • 控制 + 数据：HTTP/1.1 服务端 + 客户端      │
│  • 文件 IO：分块读写、.part、续传、校验        │
└──────────────────────────────────────────────┘
┌──────── 平台桥（ios/ macos/ android/ windows/）────────┐
│ 文件选择器、保存位置 / 相册、mDNS(Bonjour/NSD/DNS-SD)、 │
│ 后台保活、组播锁、本地网络权限、防火墙提示               │
└────────────────────────────────────────────────────────┘
```

**为什么数据面放 C++ 而不是纯 Lua**（查过引擎 `framework/types`）：

- `lx.fs.read` 只能整文件读进内存，没有按偏移 / 分块读写 → GB 级文件会爆内存；
- 引擎没有通用文件选择器（只有 `lx.album.pick` 选图片 / 视频），也没有 mDNS；
- 每块数据过 Lua 有拷贝 + GC 开销，跑不满千兆 / Wi‑Fi 6；
- 参考工程 `native/video_proxy` 已经验证了「libhv + 引擎同一份 OpenSSL，iOS/Android/macOS 都能编」这条路，直接复用其编译配置和 `tools/check_libhv_sync.sh`。

Lua 侧能直接用的：`lx.network.onChange`（切网重启发现）、`lx.device`（`ipv4`、设备名、平台）、`lx.qrcode` / `lx.scanner`（扫码连接）、`lx.system.share`、`lx.permission`、`lx.storage` / `lx.db`（历史、可信设备）、`lx.notify`（后台收到文件通知）。

## 3. 目录结构

```
lquicktransfer/
├── lx.json / lx.lock          # 名称、id、版本、platforms: [android, ios, macos, windows]
├── README.md                  # 运行命令 + 目录规范
├── docs/                      # 设计文档（本文件、protocol.md、platform_notes.md）
├── lua/
│   ├── main.lua               # 入口：install 平台层 → 启动 core → 打开主页
│   ├── platform/              # 平台适配层（require("platform.xxx") 注入各平台实现）
│   ├── core/
│   │   ├── lqt.lua            # lx.native("lqt") 的薄封装 + 事件分发（不支持时降级提示）
│   │   ├── identity.lua       # 本机 deviceId / 设备名 / 头像色 / 证书指纹
│   │   ├── discovery.lua      # 设备列表（合并组播 + mDNS + 手动），上下线、超时剔除
│   │   ├── transfer.lua       # 发送 / 接收任务状态机、队列、重试、续传
│   │   ├── trust.lua          # 可信设备、PIN
│   │   ├── history.lua        # 传输记录（lx.db）
│   │   └── settings.lua       # 接收目录、自动接收、设备名、端口
│   ├── components/            # device_card、progress_row、file_icon、empty_state、qr_view…
│   ├── modules/
│   │   ├── main/              # main_page + views/tab_bar（发送 / 接收 / 记录 / 设置）
│   │   ├── send/              # send_page：选文件 / 文本 → 选设备 → 发送；views/picker_sheet
│   │   ├── receive/           # 接收确认弹窗、接收中列表、本机二维码
│   │   ├── history/           # 记录页：打开、定位、重发、删除
│   │   ├── connect/           # 手动 IP / 扫码连接
│   │   └── setting/           # 设置页
│   ├── theme/ i18n/ res/ fonts/
├── native/
│   ├── third_party/libhv      # 与引擎版本一致
│   └── lqt_core/              # C++：lqt_core.h（纯 C 接口）+ discovery / server / client / fileio
├── ios/  macos/  android/  windows/   # 宿主工程 + 平台桥（LqtBridge.m / .kt / .cpp）
└── tools/                     # 协议对拍 / 压测脚本（如 python 版对端，方便单测）
```

## 4. 协议设计（概要，细节放 `docs/protocol.md`）

### 4.1 设备身份

- `deviceId`：首次启动生成的 UUID，存 `lx.storage`；
- `alias`（设备名，可改）、`platform`、`model`、`port`、`protocolVersion`、`fingerprint`（自签证书 SHA‑256，MVP 可为空）。

### 4.2 发现（三路并行，Lua 合并去重）

| 方式 | 说明 | 平台注意 |
|---|---|---|
| UDP 组播 | `224.0.0.167:<端口>` 发 announce JSON，收到的设备单播回 HTTP `/register` 或 UDP 应答；每 5s 心跳，15s 无响应下线 | **iOS 组播需 Apple 审批的 `com.apple.developer.networking.multicast` 权限**；Android 要 `WifiManager.MulticastLock` |
| mDNS / DNS‑SD | 服务类型 `_lqt._tcp`，TXT 带 id / alias / fp | iOS/macOS `NWBrowser`（只需 `NSBonjourServices` + `NSLocalNetworkUsageDescription`，不用审批）、Android `NsdManager`、Windows `DnsServiceBrowse` |
| 手动 / 扫码 | 二维码内容 `lqt://ip:port?id=..&fp=..`；手输 IP 走 `GET /api/v1/info` 探测 | 兜底：AP 隔离、组播被路由器丢弃时 |

> iOS 上建议 **mDNS 为主**，组播权限批下来再打开；其它平台组播 + mDNS 双开。

### 4.3 传输（HTTP/1.1，接收方起服务）

选 HTTP 而不是自定义 TCP 帧：调试方便（curl 就能测）、浏览器能直接当对端（§4.5）、libhv 现成、续传用 Range / offset 天然表达。

```
发送方                                   接收方
POST /api/v1/prepare  {sender, files[{id,name,size,type,sha?}]}
                                       → 弹确认（可信设备自动同意）
           ← 200 {sessionId, accepted:[fileId], tokens{fileId:token}, offsets{fileId:已收字节}}
PUT  /api/v1/upload?session&file&token&offset=N   (body 流式，从 offset 续传)
           ← 200 / 409(offset 不符，返回正确 offset)
POST /api/v1/cancel?session                       （任一方取消）
GET  /api/v1/info                                 （探测 / 手动连接）
```

- 文件写 `<接收目录>/.lqt/<sessionId>/<name>.part`，完成后校验大小（可选哈希）再改名，重名自动加 `(1)`；
- 并发：同时 3 个文件，小文件（< 1MB）打包一次请求减少握手；单个大文件一条流；
- 文本 / 剪贴板：`prepare` 里带 `text` 字段，不走 upload；
- 进度：C++ 每 200ms 汇总一次推给 Lua（字节数、速度），不逐块回调。

### 4.4 安全

- MVP：接收确认 + 可信设备列表 + 每文件一次性 token；
- 加密：自签证书 + HTTPS，指纹通过 mDNS TXT / 二维码交换，首连时比对（TOFU），可信后固定；默认开或关待定（见 §8）。

### 4.5 Web（之后）

lx 的 Web 平台 `supportsTcp = false`，不能当完整客户端。改为：接收方 C++ 服务额外提供一个静态页（`GET /`），同网段任何浏览器扫码打开即可上传 / 下载，不装 App 也能用。

## 5. 平台差异（`docs/platform_notes.md` 展开）

| 事项 | iOS | Android | macOS | Windows |
|---|---|---|---|---|
| 选文件 | `UIDocumentPicker` + 相册（`lx.album`） | SAF `ACTION_OPEN_DOCUMENT`（拿 `content://`，C++ 通过 fd 读） | `NSOpenPanel` + 拖拽 | `IFileOpenDialog` + 拖拽 |
| 保存 | App Documents（「文件」App 可见：`UIFileSharingEnabled`）/ 存相册 | `Download/LQuickTransfer`（MediaStore） | `~/Downloads/LQuickTransfer` | `%USERPROFILE%\Downloads\LQuickTransfer` |
| 后台 | 前台为主；切后台申请 `beginBackgroundTask` 续约，超时暂停待续传 | 前台服务 + 通知（`FOREGROUND_SERVICE_DATA_SYNC`） | 无限制 | 无限制 |
| 权限 | 本地网络权限弹窗（首次发现时触发）、相册 | 通知、组播锁；Android 13+ 媒体权限 | 沙盒：`network.server/client`、用户选择文件读写 | 首次监听触发防火墙提示（安装包里预加规则） |
| 发现 | mDNS 为主 | 组播 + NSD | 组播 + Bonjour | 组播 + DNS‑SD |

## 6. C++ 核心接口草案（`native/lqt_core/lqt_core.h`）

```c
int  lqt_start(const char *configJson);          // 启动事件循环：监听端口、设备信息、接收目录；返回端口
void lqt_stop(void);
void lqt_set_event_cb(void (*cb)(const char *eventJson));   // device_up/down, incoming_request, progress, done, error
void lqt_discovery_start(void); void lqt_discovery_stop(void);
void lqt_probe(const char *host, int port);      // 手动连接
int  lqt_send(const char *taskJson);             // 发起发送，返回 taskId（文件来源：路径 / 平台 fd）
void lqt_respond(const char *sessionId, const char *acceptJson);   // 接收方确认 / 拒绝（可部分接收）
void lqt_cancel(int taskId);
```

平台桥把它包成 `lx.native("lqt")`，事件经 `lqt:on("event", fn)` 到 Lua。

## 7. 页面草图

- **发送**：上半部选内容（文件 / 相册 / 文件夹 / 文本 四个入口，已选列表可删），下半部附近设备网格（实时出现 / 消失），点设备即发；
- **接收**：本机名 + IP + 二维码，「正在接收」列表；收到请求弹底部弹窗（来源设备、文件数、总大小、接收 / 拒绝 / 总是信任）；
- **记录**：按时间分组，发送 / 接收两个方向，点开打开文件或定位；
- **设置**：设备名、接收目录（桌面端可改）、自动接收可信设备、加密开关、端口、语言 / 深色模式。

## 8. 里程碑

| 阶段 | 内容 | 验收 |
|---|---|---|
| M0 | `lx create` 骨架、目录规范 README、lx.json 加 windows；接入 libhv 编译 | 四端空白 App 能跑 |
| M1 | C++：HTTP 服务端 / 客户端 + 分块文件 IO + 续传；tools/ 下 Python 对端做单测 | 桌面两端互传 5GB 文件，断网恢复后续传成功 |
| M2 | 发现：组播 + mDNS + 手动 / 扫码；Lua 设备列表 | 四端互相看得到，切 Wi‑Fi 自动刷新 |
| M3 | UI 全流程 + 确认弹窗 + 历史 + 设置 | 手机 ↔ 电脑完整收发 |
| M4 | 平台补齐：选文件 / 保存 / 后台 / 权限 / 防火墙 | 各平台真机清单走查 |
| M5 | HTTPS + 指纹、Web 收发页、系统分享入口 | — |

## 9. 待确认的问题

1. App 名称 / 包 id（如 `com.xxx.lqt`）、品牌色；
2. 是否需要和现有工具（LocalSend 等）协议兼容？——兼容意味着照搬对方协议，不兼容则按上面自定义；
3. 加密默认开还是关（开：首连要比指纹，体验多一步；关：同网段可被嗅探）；
4. iOS 是否去申请组播权限（不申请则 iOS 只靠 mDNS + 扫码）；
5. 是否要 Harmony / Web 收发页进 MVP。
