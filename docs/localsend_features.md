# LocalSend 功能对照清单（超传需全部覆盖）

> 依据 LocalSend 公开的协议文档（protocol v2.1）与应用功能整理。「界面」列指向设计稿里的画板。
> 实现时以 LocalSend 官方仓库 `localsend/protocol` 的 README 为准逐字段核对。

## 1. 协议兼容（必须逐字段一致）

| 项 | LocalSend 规定 | 超传 |
|---|---|---|
| 端口 | TCP/UDP 53317（可改） | 同 |
| 组播发现 | UDP 组播 `224.0.0.167:53317`，announce JSON：`alias, version("2.1"), deviceModel, deviceType(mobile/desktop/web/headless/server), fingerprint, port, protocol(http/https), download, announce` | 同；收到 announce 后用 `POST /api/localsend/v2/register` 回应（失败再 UDP 回） |
| HTTP 发现兜底 | 组播不通时对本网段 /24 逐个 `POST /register` 扫描 | 同（「扫描网络」按钮） |
| 加密 | HTTPS + 自签证书，`fingerprint` = 证书 SHA-256；关加密时 fingerprint 为随机串、走 http | 同 |
| 上传 | `POST /api/localsend/v2/prepare-upload`（info + files 元数据，可带 `?pin=`）→ 返回 `sessionId` + 每个文件 `token`；`POST /upload?sessionId&fileId&token` 二进制 body；`POST /cancel?sessionId` | 同 |
| 状态码 | 204 对方不要任何文件 / 401 PIN 错 / 403 拒绝 / 409 已有会话 / 429 太多请求 | 同 |
| 下载（反向） | `POST /api/localsend/v2/prepare-download`（`?sessionId&pin`）+ `GET /download?sessionId&fileId`，用于「通过链接分享」与浏览器下载 | 同，含内置网页 |
| 信息 | `GET /api/localsend/v2/info` | 同；超传扩展字段 `x-chuanchuan: {resume:true,...}` |
| v1 | 旧版 `/api/localsend/v1/*` | 只做 v2 接收端兼容 v1 发现（待定） |

## 2. 功能清单

### 发现与设备
- [ ] 自动发现附近设备（组播），设备卡片显示别名、型号、类型图标、#hashtag（IP 末段）
- [ ] 手动刷新 / 扫描网络（HTTP 子网扫描）
- [ ] 通过 IP 或 #hashtag 手动添加设备
- [ ] 收藏设备（星标，置顶；可编辑收藏别名）
- [ ] 本机别名（随机生成「形容词 + 名词」，可改）、设备类型、型号可改
- [ ] 多网卡：选择 / 白名单 / 黑名单网卡；显示本机全部 IP

### 发送
- [ ] 选择：文件、文件夹、媒体（相册）、文本、粘贴（剪贴板）
- [ ] 已选清单：缩略图、删除单个、清空、编辑（重命名文本）
- [ ] 发送模式：单个接收方 / 多个接收方（依次）/ 通过链接分享
- [ ] 通过链接分享：起本地网页（`http(s)://ip:53317`），可设 PIN、可自动接受请求，显示请求列表
- [ ] 桌面拖拽文件到窗口发送；移动端系统分享入口（iOS Share Extension / Android ACTION_SEND）
- [ ] 发送中进度页：总进度、每个文件状态（排队 / 发送中 / 完成 / 跳过 / 失败）、速度、剩余时间、取消
- [ ] 对方需 PIN 时弹输入框

### 接收
- [ ] 接收页：本机身份（别名、IP、端口）、在线 / 离线开关（服务启停）
- [ ] 快速保存：关闭 / 仅收藏设备 / 全部（自动接受）
- [ ] 需要 PIN 才能接收
- [ ] 接收请求弹窗：来源设备、文件列表（可勾选部分接收）、接受 / 拒绝
- [ ] 文本消息：直接显示内容、复制、打开链接
- [ ] 保存目录可选；媒体可自动存相册（移动端）；保存后打开 / 打开所在文件夹
- [ ] 接收完成自动关闭进度页（设置项）

### 记录
- [ ] 历史记录：时间、方向、对方、文件名、大小；打开、打开文件夹、复制文本、删除记录、清空

### 设置（对照 LocalSend 设置页分组）
- [ ] 通用：主题（跟随系统 / 浅色 / 深色）、配色（品牌红 / 跟随系统强调色 / OLED 纯黑）、语言、动画开关
- [ ] 桌面：关闭时最小化到托盘、开机自启、启动时隐藏、Windows 右键「用超传发送」
- [ ] 接收：快速保存、收藏设备快速保存、需要 PIN、保存目录、存到相册、完成后自动关闭、保存到历史
- [ ] 发送：分享链接自动接受
- [ ] 网络：服务器启停 / 重启、别名、设备类型、型号、端口、网卡、发现超时、加密、组播地址
- [ ] 其它：关于、开源许可、隐私政策、故障排除（防火墙 / AP 隔离 / 网卡指引）、检查更新

### 其它
- [ ] 桌面托盘图标与菜单（显示窗口 / 接收开关 / 退出）
- [ ] 系统通知：收到请求 / 完成
- [ ] 命令行 / 无界面模式（headless，deviceType=headless）——优先级低
- [ ] 多语言（中 / 英起步）
