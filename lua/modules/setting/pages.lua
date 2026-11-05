-- 设置 › 其它 的子页面：故障排除、开源许可、隐私政策、关于超传。盖在主内容区上，左上角返回（store.closePage）。
local lx = require("lx")
local t = require("i18n")
local C = require("theme.colors")
local ui = require("components.ui")
local store = require("core.store")
local P = require("core.localsend.protocol")
local View, Text, ScrollView = lx.View, lx.Text, lx.ScrollView

local M = {}

M.VERSION = (lx.device.app and lx.device.app.version and lx.device.app.version ~= "" and lx.device.app.version) or "1.0.0"

local function Para(text, opts)
  opts = opts or {}
  return Text { style = { fontSize = opts.size or 14, color = opts.color or C.ink2, lineHeight = opts.lineHeight or 22, fontWeight = opts.bold and "bold" or nil }, text }
end

local function Section(title, children)
  return ui.Card { gap = 10, View { style = { flexDirection = "row", alignItems = "center", gap = 8 },
    Text { style = { fontSize = 16, fontWeight = "bold", color = C.ink }, title } }, children }
end

-- ---------------------------------------------------------------- 故障排除

local function Troubleshoot()
  local s = store.state
  local items = {
    { t("两台设备要连同一个网络"), t("确认都连着同一个 Wi‑Fi（或同一个路由器的网线）。手机开了「个人热点」时，电脑连到这个热点也可以。访客网络、公共 Wi‑Fi 通常会隔离设备，换到主网络。") },
    { t("关掉 VPN / 代理 / 加速器"), t("VPN 会接管局域网流量，设备互相看不见。传文件时先暂时关掉。") },
    { t("允许防火墙放行"), lx.device.platform == "windows"
        and t("Windows 第一次运行时会询问是否允许超传访问网络，「专用」和「公用」都要勾上。也可以在「Windows 安全中心 › 防火墙 › 允许应用通过防火墙」里勾选超传。360、火绒等安全软件的网络防护也要放行。")
        or t("macOS：系统设置 › 网络 › 防火墙 如果开着，要允许超传接收传入连接。") },
    { t("iPhone / iPad：允许「本地网络」"), t("设置 › 隐私与安全性 › 本地网络 里打开超传。第一次打开时弹出的询问如果点了「不允许」，就到这里改。") },
    { t("路由器的「AP 隔离」"), t("有的路由器开了「AP 隔离 / 客户端隔离」，同一个 Wi‑Fi 的设备也互相访问不了。在路由器后台关掉，或者用手动添加 IP 的方式试试。") },
    { t("还是找不到：手动添加"), t("在对方的「接收」页看 IP 地址（本机是 %s:%d），然后在「发送」页点「按 IP 添加」输入。手机也可以点「扫码连接」扫对方接收页的二维码。", s.identity.ips[1] or "-", s.port) },
    { t("能发现但发送失败"), t("对方可能开了「需要 PIN」或正在接收别的文件；大文件传一半断开通常是 Wi‑Fi 不稳定或设备进入了休眠，传输时保持亮屏、靠近路由器。") },
  }
  local out = {}
  for i, it in ipairs(items) do
    out[#out + 1] = Section(i .. ". " .. it[1], { Para(it[2]) })
  end
  out[#out + 1] = ui.Card { gap = 8,
    Text { style = { fontSize = 14, fontWeight = "bold", color = C.ink }, t("本机网络信息") },
    Para(t("地址：%s，端口：%d，协议：%s", s.identity.ips[1] or "-", s.port, s.encrypted and "HTTPS" or "HTTP"), { size = 13 }),
    Para(t("设备名：%s · 指纹：%s…", s.identity.alias, (P.fingerprint() or ""):sub(1, 16)), { size = 13 }),
    ui.Button { title = t("重新扫描附近设备"), icon = "refresh", height = 40, radius = 10, onTap = function() store.rescan(); store.closePage(); store.set({ tab = "send" }) end } }
  return out
end

-- ---------------------------------------------------------------- 开源许可

local LICENSES = {
  { "LocalSend Protocol", "MIT", "Copyright (c) 2022 Tien Do Nam", "https://github.com/localsend/protocol" },
  { "Lua 5.4", "MIT", "Copyright (c) 1994–2024 Lua.org, PUC-Rio", "https://www.lua.org" },
  { "libhv", "BSD 3-Clause", "Copyright (c) 2020, ithewei", "https://github.com/ithewei/libhv" },
  { "OpenSSL", "Apache License 2.0", "Copyright (c) 1998–2025 The OpenSSL Project Authors", "https://www.openssl.org" },
  { "Yoga", "MIT", "Copyright (c) Meta Platforms, Inc. and affiliates", "https://github.com/facebook/yoga" },
  { "lua-cjson", "MIT", "Copyright (c) 2010–2012 Mark Pulford", "https://github.com/mpx/lua-cjson" },
  { "lua-protobuf", "MIT", "Copyright (c) 2018 Xavier Wang", "https://github.com/starwing/lua-protobuf" },
  { "miniz", "MIT", "Copyright 2013–2014 RAD Game Tools and Valve Software; 2010–2014 Rich Geldreich and Tenacious Software LLC", "https://github.com/richgel999/miniz" },
  { "QR Code generator", "MIT", "Copyright (c) Project Nayuki", "https://www.nayuki.io/page/qr-code-generator-library" },
  { "SQLite", "Public Domain", "The SQLite authors", "https://sqlite.org" },
  { "Windows App SDK / WinUI 3", "MIT", "Copyright (c) Microsoft Corporation", "https://github.com/microsoft/WindowsAppSDK" },
  { "AndroidX", "Apache License 2.0", "Copyright (c) The Android Open Source Project", "https://developer.android.com/jetpack/androidx" },
  { "Noto / PingFang / Segoe UI", t("系统字体"), t("由操作系统提供，不随超传分发"), "" },
}

local function Licenses()
  local rows = {}
  for i, l in ipairs(LICENSES) do
    rows[#rows + 1] = View { key = i, onTap = l[4] ~= "" and function() pcall(lx.linking.open, l[4]) end or nil,
      style = { paddingVertical = 12, gap = 3, borderBottomWidth = i < #LICENSES and 1 or 0, borderColor = C.divider },
      View { style = { flexDirection = "row", justifyContent = "space-between", gap = 8 },
        Text { style = { fontSize = 14, fontWeight = "bold", color = C.ink, flexShrink = 1 }, l[1] },
        ui.Pill { text = l[2], tone = "gray" } },
      Text { style = { fontSize = 12, color = C.muted, lineHeight = 18 }, l[3] },
      l[4] ~= "" and Text { style = { fontSize = 12, color = C.brandStrong }, l[4] } or nil }
  end
  return {
    Para(t("超传使用了下面这些开源软件，感谢它们的作者。点一项可以打开项目主页查看完整许可证。"), { size = 13 }),
    ui.Card { gap = 0, padding = 0, style = { paddingHorizontal = 16 }, rows },
  }
end

-- ---------------------------------------------------------------- 隐私政策

local function Privacy()
  local items = {
    { t("不收集任何个人数据"), t("超传没有账号、没有服务器，也不包含任何统计、广告或崩溃上报 SDK。我们不收集、不上传、不出售你的任何数据。") },
    { t("文件只在局域网内直接传输"), t("文件在你的设备之间通过本地网络点对点传输，不经过任何云端。默认使用 HTTPS 加密（每台设备生成自己的证书）。") },
    { t("保存在本机的数据"), t("设备名、收藏的设备、传输记录和设置只保存在本机，卸载即删除。收到的文件保存在你选择的目录里。") },
    { t("对局域网可见的信息"), t("接收服务开启时，同一网络里的设备能看到本机的设备名、型号、设备类型和 IP 地址（这是被发现所必需的）。不想被看到时可以在「接收」页关掉接收开关。") },
    { t("权限的用途"), t("本地网络：发现设备、收发文件；相册：选择要发送的照片视频、保存收到的照片视频；相机：扫码连接；通知：收到文件时提醒。只在用到时申请。") },
    { t("链接分享"), t("开启链接分享时，同一网络里打开链接的浏览器可以下载你选择的文件，每个请求都需要你同意（除非你打开了自动同意），并可设置 PIN。停止分享后链接立即失效。") },
  }
  local out = { Para(t("更新日期：2026 年 11 月 6 日"), { size = 12, color = C.muted }) }
  for _, it in ipairs(items) do out[#out + 1] = Section(it[1], { Para(it[2]) }) end
  return out
end

-- ---------------------------------------------------------------- 关于

local function About()
  local s = store.state
  local platformName = ({ macos = "macOS", windows = "Windows", ios = "iOS", android = "Android" })[lx.device.platform] or lx.device.platform
  return {
    View { style = { alignItems = "center", gap = 10, paddingVertical = 20 },
      ui.Logo { size = 84, glow = true },
      Text { style = { fontSize = 26, fontWeight = "900", color = C.ink }, t("超传") },
      Text { style = { fontSize = 14, color = C.muted }, t("版本 %s · %s", M.VERSION, platformName) },
      Text { style = { fontSize = 14, color = C.ink2, textAlign = "center", lineHeight = 22 }, t("局域网里最快的文件互传。不用登录，不走云端，手机电脑互传。") } },
    ui.Card { gap = 0, padding = 0, style = { paddingHorizontal = 16 },
      ui.SettingRow { label = t("兼容协议"), value = "LocalSend v" .. P.VERSION },
      ui.SettingRow { label = t("本机"), value = s.identity.alias .. " · " .. (s.identity.ips[1] or "-") },
      ui.SettingRow { label = t("支持平台"), value = "Windows · macOS · iOS · Android" },
      ui.SettingRow { label = t("开源许可"), onTap = function() store.openPage("licenses") end },
      ui.SettingRow { label = t("隐私政策"), onTap = function() store.openPage("privacy") end, last = true } },
    Para(t("超传可以和 LocalSend 互相发现、互相收发文件。"), { size = 12, color = C.muted }),
  }
end

M.TITLES = { troubleshoot = "故障排除", licenses = "开源许可", privacy = "隐私政策", about = "关于超传" }
local BUILDERS = { troubleshoot = Troubleshoot, licenses = Licenses, privacy = Privacy, about = About }

M.View = lx.component(function(props)
  local page = store.state.page
  local build = page and BUILDERS[page]
  if not build then return nil end
  local desktop = props.desktop
  return View { style = { position = "absolute", left = 0, right = 0, top = 0, bottom = 0, backgroundColor = C.ground,
                          paddingTop = (props.safeTop or 0) + (desktop and 30 or 8), paddingHorizontal = desktop and 40 or 16,
                          paddingBottom = props.safeBottom or 0, alignItems = desktop and "center" or "stretch" },
    View { style = { flex = 1, width = desktop and 680 or nil, maxWidth = desktop and "100%" or nil, gap = 14 },
      ui.PageHeader { title = t(M.TITLES[page]), desktop = desktop, onBack = store.closePage },
      ScrollView { style = { flex = 1 }, contentStyle = { gap = 12, paddingBottom = 24 }, build() } } }
end, "SettingPages")

return M
