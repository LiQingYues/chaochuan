# 超传

局域网传输 App，兼容 LocalSend 协议 v2.1（端口 53317、组播 224.0.0.167），支持 Windows / macOS / iOS / Android。
用 lx 引擎开发：界面和业务用 Lua 写（`lua/`），**桌面和移动共用一套代码**，各平台宿主工程（`ios/`、`android/`、`macos/`、`windows/`）只链接 lx SDK 编好的库。

```bash
export PATH="$PATH:<lx SDK 路径>/bin"
lx devices                 # 看有哪些设备 / 平台可以运行
lx run -d macos            # 桌面版（侧边栏布局）；-d ios / android / windows
lx test                    # headless 测试：桌面 / 移动两种布局都跑
lx build android           # 安装包：build/android/chaochuan-release.apk
```

- `lx.json`：名字、应用 id（`com.chaochuan.chaochuan`）、版本号。改完 `lx sync`。
- 设计：`docs/design_outline.md`（大纲）、`docs/localsend_features.md`（LocalSend 协议兼容与功能清单）、
  界面设计稿 https://claude.ai/artifact/LniKZcLhNj3SNLiiVrtwxn。

## 桌面 / 移动怎么共用

- `theme/layout.lua` 的 `isDesktop()`：macOS / Windows（宽屏 Web）走桌面布局，iOS / Android 走移动布局。
- 只有外框不同：`modules/main/main_page.lua` 桌面是「左侧导航栏 + 内容区、接收请求居中弹窗」，手机是「内容区 + 底部标签栏、接收请求底部弹出、进度整屏」。
- 每个页面的视图只写一份，收 `desktop` 参数调整排版（列数、尺寸、哪些桌面专属设置项显示）。

## 目录规范（lua/）

| 目录 | 放什么 |
|---|---|
| `theme/` | `colors`（品牌红等配色，和设计稿一致）、`layout`（桌面 / 移动判定、等宽字体） |
| `components/` | 跨模块通用组件：`icon`（Canvas 画的线性图标，24 网格，SVG 子集路径）、`ui`（Card / Button / Toggle / Segmented / FileBadge / DeviceRow / SettingGroup / Bar …） |
| `core/` | 与界面无关的基础设施：`store`（全局状态 + 动作，变化发 `store.changed`）。之后的 LocalSend 核心封装（`lqt.lua`、`discovery`、`transfer` …）也放这里 |
| `modules/<模块>/` | 业务模块，视图叫 `*_view.lua`：`main`（主框架 + `views/nav` 侧边栏 / 标签栏）、`send`、`receive`（接收页 + `incoming_view` 接收请求 / 文本消息）、`transfer`（进度）、`history`、`setting`、`share_link`（链接分享） |
| `test/`（项目根） | `*_test.lua`，`lx test` 运行 |

## 传输核心（`lua/core/localsend/`，纯 Lua）

| 文件 | 内容 |
|---|---|
| `protocol.lua` | LocalSend v2.1 常量（53317、224.0.0.167、`/api/localsend/v2`）、本机身份（别名 / 指纹存 lx.storage）、MIME、安全文件名 |
| `http.lua` | 建在 lx.TcpServer / TcpSocket 上的 HTTP/1.1：请求 / 响应体流式（Content-Length / chunked），上传等 `drain` 再写下一批 |
| `service.lua` | 发现（组播 announce + `/register` 回应 + /24 子网扫描）、接收（prepare-upload / upload / cancel，PIN、快速保存、部分接收、纯文本 204）、发送、链接分享（prepare-download / download + 浏览器网页） |
| `../picker.lua` | 选内容：桌面系统对话框（osascript / PowerShell），手机相册；文本 / 剪贴板 |

- 依赖引擎新能力（2026-11-05 加进 `多平台app引擎`）：TCP 客户端 `drain` 事件、UDP `multicast` 选项（`core/src/lx_net.cpp`），
  `lx.crypto.selfSignedCert`（`core/src/lx_hash.c`，OpenSSL 生成 RSA 2048 自签证书）。旧引擎库自动降级（定时限速发送、不收组播、接收用 http）。
- 加密：默认 HTTPS（证书首次启动生成，存 `Documents/.chaochuan/`，指纹 = 证书 SHA-256，与 LocalSend 一致）；设置里可关。
  Windows 引擎默认用 SChannel、没有 OpenSSL，生成不了证书 → 接收用 http（发往 https 设备不受影响）。
- Android：`MainActivity` 持有 Wi‑Fi 组播锁（否则收不到组播）；`ChaochuanNetBridge`（`lx.native("chaochuanNet").lanIPv4()`）
  直接读 Wi‑Fi 网卡地址——手机开着 VPN 时系统 API 只给 tun 地址。
- 图标：`python3 tools/make_icons.py`（画 `icon/` 源图 → 用 SDK 的 icons.py 生成 iOS / macOS / Android / Windows 各尺寸）。
- 自测：`tools/selftest.sh`（headless `--net`，真实 socket 回环，默认走 HTTPS，`LS_HTTP=1` 走 http；11 个场景：info / register / 20 MB 多文件 / 拒绝 / 部分接收 / PIN / 文本 / 重名 / 链接分享下载与网页）。`lx test` 只测界面（不收网络事件）。
- 还没做：手机端文档选择器、iOS 组播权限申请、多个设备依次发送、Windows 实机验证。
