-- 全局状态（桌面 / 移动共用）：界面只读 store.state、调用这里的动作，状态变了发 "store.changed"。
-- 数据来自 core/localsend/service（LocalSend v2.1：发现、接收、发送、链接分享），系统能力来自 core/host，
-- 偏好与记录存 lx.storage（"prefs"）。
local lx = require("lx")
local t = require("i18n")
local C = require("theme.colors")
local layout = require("theme.layout")
local P = require("core.localsend.protocol")
local service = require("core.localsend.service")
local host = require("core.host")

local M = {}

local desktop = layout.isDesktop()

local ICON_BY_TYPE = { mobile = "phone", desktop = "laptop", web = "globe", headless = "monitor", server = "monitor" }
M.ICON_BY_TYPE = ICON_BY_TYPE
local QUICK = { "off", "favorites", "all" }
M.DEVICE_TYPES = { "mobile", "desktop", "web", "headless", "server" }
M.TIMEOUTS = { 500, 1000, 2000, 5000 }

-- ---------------------------------------------------------------- 偏好（持久化）

local prefs = lx.storage.get("prefs")
if type(prefs) ~= "table" then prefs = {} end
local function default(k, v) if prefs[k] == nil then prefs[k] = v end end
prefs.favorites = type(prefs.favorites) == "table" and prefs.favorites or {}
prefs.history = type(prefs.history) == "table" and prefs.history or {}
default("quickSave", 2); default("autoClose", true); default("saveToAlbum", true); default("saveHistory", true)
default("theme", "system"); default("accent", "red"); default("language", "system"); default("animations", true)
default("closeToTray", false); default("startHidden", false); default("contextMenu", false)
default("shareAutoAccept", false); default("discoveryTimeout", 1000); default("nic", "auto")
-- 旧版把中文写进了 settings：丢掉
prefs.settings = nil

local function savePrefs() pcall(lx.storage.set, "prefs", prefs) end
M.prefs = prefs

-- ---------------------------------------------------------------- 外观 / 语言

local function applyLanguage()
  t.set(prefs.language == "system" and t.systemLang() or prefs.language)
end

local function applyTheme()
  C.apply(prefs.theme, prefs.accent)
  -- 原生控件（开关、对话框、状态栏）跟着深浅色
  pcall(function()
    if lx.theme and lx.theme.set then lx.theme.set(prefs.theme == "system" and "system" or (C.isDark and "dark" or "light")) end
  end)
end

applyLanguage()
applyTheme()

-- ---------------------------------------------------------------- 状态

local function protocolOverrides()
  P.overrides.deviceType = prefs.deviceType
  P.overrides.deviceModel = prefs.deviceModel
  P.preferredIp = (prefs.nic ~= "auto") and prefs.nic or nil
end
protocolOverrides()

local function identity()
  local id = P.identity()
  local ip = P.localIPv4()
  return { alias = id.alias, model = P.deviceModel(), deviceType = P.deviceType(),
           tag = ip and ("#" .. ip:match("(%d+)$")) or "#—", ips = { ip or t("未连接网络") } }
end

M.state = {
  tab = desktop and "send" or "receive",
  page = nil,                  -- 子页面：about / troubleshoot / licenses / privacy（盖在主内容上，左上角返回）
  identity = identity(),
  port = prefs.port or P.PORT,
  online = true,
  encrypted = prefs.encrypted ~= false and lx.crypto.supportsSelfSignedCert == true,

  sendMode = 1,                -- 1 单个设备 2 多个设备 3 链接分享
  multiTargets = {},           -- 多设备模式下选中的设备 id → true
  onlyFavorites = false,       -- 设备列表只看收藏
  selection = {},
  scanning = false,
  devices = {},

  quickSave = prefs.quickSave, -- 1 关闭 2 仅收藏设备 3 所有人
  requirePin = prefs.requirePin == true,
  pin = prefs.pin,
  saveDir = prefs.saveDir or service.saveDir(),
  saveToAlbum = prefs.saveToAlbum,
  autoClose = prefs.autoClose,
  incoming = nil,
  textMessage = nil,
  transfer = nil,              -- 进行中 / 刚结束的传输；hidden = true 时进度页收起，界面上只显示一条状态
  shareLink = nil,

  history = {},
  historyFilter = 1,
  historyQuery = "",
}

local function changed() lx.events.emit("store.changed") end
M.changed = changed

function M.set(patch)
  for k, v in pairs(patch) do M.state[k] = v end
  if patch.quickSave then prefs.quickSave = patch.quickSave; service.config.quickSave = QUICK[patch.quickSave]; savePrefs() end
  if patch.autoClose ~= nil then prefs.autoClose = patch.autoClose; savePrefs() end
  if patch.saveToAlbum ~= nil then prefs.saveToAlbum = patch.saveToAlbum; savePrefs() end
  if patch.online ~= nil then service.receiving = patch.online end
  if patch.encrypted ~= nil then
    if patch.encrypted and not lx.crypto.supportsSelfSignedCert then
      M.state.encrypted = false
      lx.dialog.toast(t("这个平台还不能生成证书，接收先用 HTTP；发送到加密设备不受影响"))
    else
      prefs.encrypted = patch.encrypted; savePrefs()
      if service.running then service.restart({ https = patch.encrypted }); M.state.encrypted = service.config.protocol == "https" end
    end
  end
  changed()
end

function M.dismissText()
  M.state.textMessage = nil
  changed()
end

function M.openPage(name) M.state.page = name; changed() end
function M.closePage() M.state.page = nil; changed() end

-- ---------------------------------------------------------------- 设置（每项都真正生效）

--- 读设置值（界面用）
function M.pref(key) return prefs[key] end

function M.setTheme(mode) prefs.theme = mode; savePrefs(); applyTheme(); changed() end
function M.setAccent(a) prefs.accent = a; savePrefs(); applyTheme(); changed() end
function M.setLanguage(code)
  prefs.language = code; savePrefs(); applyLanguage()
  M.state.identity = identity(); M.loadHistory(); changed()
end
function M.setAnimations(on) prefs.animations = on == true; savePrefs(); changed() end
function M.setSaveHistory(on) prefs.saveHistory = on == true; savePrefs(); changed() end
function M.setShareAutoAccept(on) prefs.shareAutoAccept = on == true; savePrefs(); changed() end

--- 外观：系统深浅色变化时（跟随系统）重新套用
function M.onSystemAppearance()
  if prefs.theme == "system" then applyTheme(); changed() end
end

-- 桌面
function M.setCloseToTray(on)
  if not host.setCloseToTray(on) then lx.dialog.toast(t("当前安装包不支持托盘，请更新到最新版本")); return end
  prefs.closeToTray = on == true
  if not on and prefs.startHidden then prefs.startHidden = false end   -- 没有托盘就不能「启动时隐藏」（会找不到窗口）
  savePrefs(); changed()
end

function M.launchAtLogin() return host.getLaunchAtLogin() end
function M.setLaunchAtLogin(on)
  local ok, err = host.setLaunchAtLogin(on)
  if not ok then lx.dialog.toast(t("设置开机启动失败") .. (err and ("：" .. tostring(err)) or "")) end
  changed()
end

function M.setStartHidden(on)
  prefs.startHidden = on == true
  if on and not prefs.closeToTray then M.setCloseToTray(true) end   -- 隐藏启动需要托盘图标把窗口找回来
  savePrefs(); changed()
end

function M.setContextMenu(on)
  if not host.setContextMenu(on) then lx.dialog.toast(t("设置右键菜单失败")); return end
  prefs.contextMenu = on == true; savePrefs(); changed()
end

-- 接收
function M.chooseSaveDir()
  if not host.isDesktop() then return M.openPath(M.state.saveDir) end
  host.pickDirectory(function(path)
    if not path or path == "" then return end
    prefs.saveDir = path; savePrefs()
    service.config.saveDir = path
    M.state.saveDir = path
    lx.dialog.toast(t("接收的文件将保存到 %s", path))
    changed()
  end)
end

function M.resetSaveDir()
  prefs.saveDir = nil; savePrefs()
  service.config.saveDir = nil
  M.state.saveDir = service.saveDir()
  changed()
end

-- 网络
function M.rename(alias)
  alias = (alias or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if alias == "" then return end
  P.saveAlias(alias)
  M.state.identity.alias = alias
  service.announceNow()
  changed()
end

function M.setDeviceType(tp) prefs.deviceType = tp; savePrefs(); protocolOverrides(); M.state.identity = identity(); service.announceNow(); changed() end
function M.setDeviceModel(model)
  model = (model or ""):gsub("^%s+", ""):gsub("%s+$", "")
  prefs.deviceModel = model ~= "" and model or nil
  savePrefs(); protocolOverrides(); M.state.identity = identity(); service.announceNow(); changed()
end

local function restartService()
  if service.running then
    service.restart({ port = prefs.port or P.PORT, multicast = prefs.multicast or P.MULTICAST })
    M.state.encrypted = service.config.protocol == "https"
  end
  M.state.port = prefs.port or P.PORT
  changed()
end

function M.setPort(v)
  local n = math.floor(tonumber(v) or 0)
  if n < 1024 or n > 65535 then lx.dialog.toast(t("端口要在 1024–65535 之间")); return end
  prefs.port = (n ~= P.PORT) and n or nil; savePrefs(); restartService()
  if n ~= P.PORT then lx.dialog.toast(t("改了端口后，其它设备要按 IP:端口 手动添加才能找到本机")) end
end

function M.setMulticast(v)
  v = (v or ""):gsub("%s", "")
  local a = tonumber(v:match("^(%d+)%.%d+%.%d+%.%d+$") or "")
  if not a or a < 224 or a > 239 then lx.dialog.toast(t("组播地址要在 224.0.0.0–239.255.255.255 之间")); return end
  prefs.multicast = (v ~= P.MULTICAST) and v or nil; savePrefs(); restartService()
end

function M.setDiscoveryTimeout(ms) prefs.discoveryTimeout = ms; savePrefs(); service.config.discoveryTimeout = ms; changed() end

--- 网卡：auto 或某个 IP（对外公布 / 扫描网段 / 分享链接用这个地址）
function M.interfaces() return host.interfaces() or {} end
function M.setNic(ip)
  prefs.nic = ip or "auto"; savePrefs(); protocolOverrides()
  M.state.identity = identity()
  M.rescan()
end

function M.resetIdentity()
  P.resetIdentity()
  M.state.identity = identity()
  restartService()
end

-- ---------------------------------------------------------------- 工具

function M.formatSize(bytes)
  if type(bytes) ~= "number" then return tostring(bytes) end
  local units = { "B", "KB", "MB", "GB", "TB" }
  local i = 1
  while bytes >= 1000 and i < #units do bytes = bytes / 1000; i = i + 1 end
  if i <= 2 then return string.format("%d %s", math.floor(bytes + 0.5), units[i]) end
  local fmt = bytes >= 100 and "%.0f %s" or (bytes >= 10 and "%.1f %s" or "%.2f %s")
  return string.format(fmt, bytes, units[i])
end

function M.selectionTotal()
  local sum = 0
  for _, f in ipairs(M.state.selection) do sum = sum + (tonumber(f.size) or 0) end
  return sum
end

function M.deviceIcon(d) return ICON_BY_TYPE[d.deviceType] or "monitor" end

local function badgeItem(it)
  local ext, tint
  if it.text then ext, tint = "TXT", "#4A4442" else ext, tint = P.badge(it.name, it.mime) end
  it.ext, it.tint = ext, tint
  if it.text then it.size = #it.text end
  return it
end

--- 打开文件 / 在文件管理器里显示。路径不存在时：目录先建出来，文件给提示
function M.openPath(path, reveal)
  if not path or path == "" then return end
  local isDir = lx.fs.isDir(path)
  if not isDir and not lx.fs.exists(path) then
    if reveal then path, reveal = lx.fs.dirname(path), false; isDir = true
    else lx.dialog.toast(t("文件已不存在（可能被移动或删除了）")); return end
  end
  if isDir then pcall(lx.fs.mkdir, path) end
  if host.available() then
    host.openPath(path, reveal, function(ok)
      if not ok then lx.dialog.toast(t("打不开这个文件")) end
    end)
    return
  end
  -- 旧安装包（没有宿主能力）的退路
  local p = lx.device.platform
  local function shell(cmd) pcall(function() local fh = io.popen(cmd); if fh then fh:close() end end) end
  local function q(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
  if p == "macos" then shell((reveal and "open -R " or "open ") .. q(path))
  elseif p == "windows" then shell(reveal and ('explorer /select,"' .. path .. '"') or ('start "" "' .. path .. '"'))
  else pcall(lx.system.share, { files = { path } }) end
end

-- ---------------------------------------------------------------- 设备

local function refreshDevices()
  local list = {}
  for fp, d in pairs(service.devices) do
    list[#list + 1] = { id = fp, alias = d.alias, model = d.deviceModel or "", deviceType = d.deviceType, fav = prefs.favorites[fp] == true,
                        tag = d.ip and ("#" .. (d.ip:match("(%d+)$") or "")) or "", localsend = d.app ~= "chaochuan", raw = d }
  end
  table.sort(list, function(a, b)
    if a.fav ~= b.fav then return a.fav end
    return (a.alias or "") < (b.alias or "")
  end)
  M.state.devices = list
  -- 多设备模式里已经离线的设备取消勾选
  for id in pairs(M.state.multiTargets) do if not service.devices[id] then M.state.multiTargets[id] = nil end end
end

function M.visibleDevices()
  if not M.state.onlyFavorites then return M.state.devices end
  local out = {}
  for _, d in ipairs(M.state.devices) do if d.fav then out[#out + 1] = d end end
  return out
end

function M.toggleFavorite(id)
  prefs.favorites[id] = (not prefs.favorites[id]) and true or nil
  savePrefs()
  refreshDevices()
  lx.dialog.toast(prefs.favorites[id] and t("已收藏") or t("已取消收藏"))
  changed()
end

function M.toggleOnlyFavorites() M.state.onlyFavorites = not M.state.onlyFavorites; changed() end

function M.rescan()
  M.state.scanning = true
  changed()
  service.forgetStale(prefs.favorites)
  refreshDevices()
  service.announceNow()
  service.scan(function()
    M.state.scanning = false
    changed()
  end)
end

--- 按 IP（或 #尾号、IP:端口、chaochuan://IP:端口）手动添加：GET /info（先 https 再 http）
function M.addByAddress(text)
  local s = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
  s = s:gsub("^chaochuan://", ""):gsub("^https?://", ""):gsub("[/?].*$", "")
  if s:match("^#%d+$") then
    local mine = P.localIPv4()
    if mine then s = mine:match("^(%d+%.%d+%.%d+%.)") .. s:sub(2) end
  end
  local hostName, port = s:match("^([^:]+):?(%d*)$")
  if not hostName or hostName == "" then lx.dialog.toast(t("地址格式不对")); return end
  port = tonumber(port) or P.PORT
  local http = require("core.localsend.http")
  local function try(proto, nextProto)
    http.request({ url = string.format("%s://%s:%d%s/info", proto, hostName, port, P.API), timeout = 3000 }, function(res, err)
      if res and res.status == 200 and type(res.json) == "table" and res.json.fingerprint then
        local info = res.json
        http.postJSON(string.format("%s://%s:%d%s/register", proto, hostName, port, P.API), P.info(service.config.port, service.config.protocol, true), function() end, 3000)
        service.devices[info.fingerprint] = { fingerprint = info.fingerprint, alias = info.alias, deviceModel = info.deviceModel,
          deviceType = info.deviceType, ip = hostName, port = port, protocol = proto, download = info.download, app = info.app, lastSeen = os.time() }
        refreshDevices(); changed()
        lx.dialog.toast(t("已添加 %s", info.alias or hostName))
      elseif nextProto then
        try(nextProto, nil)
      else
        lx.dialog.toast(t("连不上 %s（%s）", hostName, tostring(err or (res and res.status))))
      end
    end)
  end
  try("https", "http")
end

--- 扫码连接（手机）：扫对方「接收」页的二维码
function M.scanToConnect()
  if not (lx.scanner and lx.scanner.isAvailable and lx.scanner.isAvailable()) then
    lx.dialog.toast(t("这台设备不能扫码")); return
  end
  lx.scanner.scan(function(r)
    local text = type(r) == "table" and (r.text or r.value) or r
    if type(text) ~= "string" or text == "" then return end
    if text:match("^chaochuan://") or text:match("^%d+%.%d+%.%d+%.%d+") or text:match("^https?://%d+%.%d+%.%d+%.%d+") then
      M.addByAddress(text)
    else
      lx.dialog.toast(t("不是超传的二维码"))
    end
  end)
end

-- ---------------------------------------------------------------- 选择要发送的内容

local function addItems(items)
  local n = 0
  for _, it in ipairs(items or {}) do
    -- 同一个文件不重复添加
    local dup = false
    if it.path then for _, s in ipairs(M.state.selection) do if s.path == it.path then dup = true break end end end
    if not dup then table.insert(M.state.selection, badgeItem(it)); n = n + 1 end
  end
  return n
end

function M.pick(kind)
  require("core.picker").pick(kind, function(items)
    addItems(items)
    changed()
  end)
end

function M.removeSelection(i)
  table.remove(M.state.selection, i)
  changed()
end

function M.clearSelection()
  M.state.selection = {}
  changed()
end

--- 系统交进来的文件（打开方式 / 分享 / 拖拽 / 右键菜单）：加入待发送，切到发送页
function M.takeIncomingFiles()
  local paths = host.takeIncomingFiles()
  if #paths == 0 then return end
  local items = require("core.picker").itemsFromPaths(paths)
  local n = addItems(items)
  if n > 0 then
    M.state.tab = "send"
    M.state.page = nil
    host.showWindow()
    lx.dialog.toast(t("已添加 %d 项，选一台设备发送", n))
  end
  changed()
end

-- ---------------------------------------------------------------- 记录

local function speedMeter()
  local samples = {}
  return function(bytes)
    local now = lx.timer.now()
    samples[#samples + 1] = { now, bytes }
    while #samples > 2 and now - samples[1][1] > 1500 do table.remove(samples, 1) end
    local first = samples[1]
    local dt = (now - first[1]) / 1000
    return dt > 0.2 and (bytes - first[2]) / dt or 0
  end
end

--- rec：dir、files（{ name, size, path, text }）、peer、total
local function addHistory(rec)
  if not prefs.saveHistory then return end
  rec.ts = os.time()
  table.insert(prefs.history, 1, rec)
  while #prefs.history > 300 do table.remove(prefs.history) end
  savePrefs()
  M.loadHistory()
end

function M.loadHistory()
  local today, yesterday = os.date("%Y-%m-%d"), os.date("%Y-%m-%d", os.time() - 86400)
  local rows = {}
  for _, r in ipairs(prefs.history) do
    local d = os.date("%Y-%m-%d", r.ts or 0)
    local files = r.files or { { name = r.name, path = r.path, text = r.text } }   -- 兼容旧记录
    local first = files[1] or {}
    local isText = first.text ~= nil and #files == 1
    local name = isText and first.text or (#files > 1 and t("%s 等 %d 个文件", first.name or "", #files) or (first.name or ""))
    rows[#rows + 1] = {
      day = d == today and t("今天") or (d == yesterday and t("昨天") or d), time = os.date("%H:%M", r.ts or 0),
      dir = r.dir, name = name, peer = r.peer, size = isText and t("文本") or (r.total and M.formatSize(r.total) or (r.size or "")),
      text = isText and first.text or nil, path = first.path, files = files, rec = r,
    }
  end
  M.state.history = rows
end

function M.deleteHistory(row)
  for i, r in ipairs(prefs.history) do if r == row.rec then table.remove(prefs.history, i) break end end
  savePrefs(); M.loadHistory(); changed()
end

function M.clearHistory()
  prefs.history = {}
  savePrefs(); M.loadHistory(); changed()
end

--- 记录里的「打开」：文本复制；单个文件用默认程序打开；多个文件打开所在文件夹
function M.openHistory(row)
  if row.text then
    pcall(lx.clipboard.set, row.text); lx.dialog.toast(t("已复制")); return
  end
  local files = row.files or {}
  if #files == 1 and files[1].path then return M.openPath(files[1].path, false) end
  local p = files[1] and files[1].path
  if p then return M.openPath(lx.fs.dirname(p), false) end
  M.openPath(M.state.saveDir, false)
end

--- 记录里的「文件夹」：在文件管理器里选中（发送的显示原文件位置，接收的显示保存位置）
function M.revealHistory(row)
  local p = row.files and row.files[1] and row.files[1].path
  if p then return M.openPath(p, true) end
  M.openPath(row.dir == "in" and M.state.saveDir or nil, false)
end

-- ---------------------------------------------------------------- 发送

local sending          -- 当前发送的句柄
local sendQueue = {}   -- 多设备：还没发的设备

function M.toggleMultiTarget(id)
  M.state.multiTargets[id] = (not M.state.multiTargets[id]) and true or nil
  changed()
end

function M.multiTargetCount()
  local n = 0
  for _ in pairs(M.state.multiTargets) do n = n + 1 end
  return n
end

local function finishTransfer(tr)
  if prefs.autoClose and not tr.failed then
    lx.timer.setTimeout(function()
      if M.state.transfer == tr then M.state.transfer = nil; changed() end
    end, tr.hidden and 3000 or 1500)
  end
end

local function sendOne(d, items, onAllDone)
  local meter = speedMeter()
  local tfiles = {}
  local total = 0
  for _, it in ipairs(items) do
    tfiles[#tfiles + 1] = { name = it.text and t("文本消息") or it.name, ext = it.ext, tint = it.tint, size = it.size or 0, sent = 0 }
    total = total + (it.size or 0)
  end
  local prev = M.state.transfer
  local tr = { dir = "out", peer = { alias = d.alias }, files = tfiles, total = total, sent = 0, speed = 0, done = false, waiting = true,
               hidden = prev and prev.hidden or false, queueIndex = prev and prev.queueIndex, queueTotal = prev and prev.queueTotal }
  M.state.transfer = tr
  changed()
  sending = service.send(d, items, {
    onProgress = function(p)
      if M.state.transfer ~= tr then return end
      tr.waiting = false
      for i, f in ipairs(p.files) do
        if tr.files[i] then tr.files[i].sent = f.sent; tr.files[i].state = f.state end
      end
      tr.sent = p.sent
      tr.speed = meter(p.sent)
      changed()
    end,
    onNeedPin = function(retry)
      lx.dialog.prompt(t("需要 PIN"), t("%s 设置了接收 PIN", d.alias or ""), function(v) retry(v) end, { placeholder = "PIN" })
    end,
    onDone = function(ok, reason)
      sending = nil
      if M.state.transfer ~= tr then return end
      local hist = {}
      for i, it in ipairs(items) do
        if not tr.files[i] or tr.files[i].state ~= "failed" then hist[#hist + 1] = { name = it.name, size = it.size, path = it.path, text = it.text } end
      end
      if ok then
        tr.done = true; tr.sent = tr.total; tr.speed = 0
        addHistory({ dir = "out", files = hist, peer = d.alias, total = tr.total })
      elseif reason == "cancelled" then
        M.state.transfer = nil
        sendQueue = {}
      else
        tr.done = true; tr.failed = true; tr.speed = 0
        tr.error = ({ rejected = t("对方拒绝了"), busy = t("对方正在接收别的文件，稍后再试") })[reason] or tostring(reason)
        if #hist > 0 and tr.sent > 0 then addHistory({ dir = "out", files = hist, peer = d.alias, total = tr.sent }) end
        lx.dialog.toast(t("发给 %s 失败：%s", d.alias or "", tr.error))
      end
      changed()
      if onAllDone then onAllDone(ok, reason) end
    end,
  })
end

local function nextInQueue()
  local d = table.remove(sendQueue, 1)
  local items = {}
  for _, it in ipairs(M.state.selection) do items[#items + 1] = it end
  if not d or #items == 0 then
    local tr = M.state.transfer
    if tr then finishTransfer(tr) end
    return
  end
  local tr = M.state.transfer
  local idx = (tr and tr.queueIndex or 0) + 1
  if tr then tr.queueIndex = idx end
  sendOne(d, items, function(ok, reason)
    if reason == "cancelled" then return end
    lx.timer.setTimeout(nextInQueue, #sendQueue > 0 and 600 or 0)
  end)
  if M.state.transfer then M.state.transfer.queueIndex = idx end
end

function M.sendTo(device)
  if #M.state.selection == 0 then
    lx.dialog.toast(t("先选择要发送的内容"))
    return
  end
  if M.state.transfer and not M.state.transfer.done then
    lx.dialog.toast(t("正在传输中，完成后再发"))
    M.showTransfer()
    return
  end
  if M.state.sendMode == 3 then return M.startShareLink() end
  if M.state.sendMode == 2 and device then
    -- 多设备模式：点设备是勾选，用底部按钮一起发
    return M.toggleMultiTarget(device.id)
  end
  local d = device and (device.raw or device)
  sendQueue = { d }
  M.state.transfer = { queueIndex = 0, queueTotal = 1, hidden = false }
  nextInQueue()
end

--- 多设备：依次发给勾选的设备
function M.sendToSelected()
  if #M.state.selection == 0 then lx.dialog.toast(t("先选择要发送的内容")); return end
  sendQueue = {}
  for _, d in ipairs(M.state.devices) do
    if M.state.multiTargets[d.id] then sendQueue[#sendQueue + 1] = d.raw end
  end
  if #sendQueue == 0 then lx.dialog.toast(t("先勾选要发送的设备")); return end
  M.state.transfer = { queueIndex = 0, queueTotal = #sendQueue, hidden = false }
  nextInQueue()
end

function M.cancelTransfer()
  local tr = M.state.transfer
  if not tr then return end
  sendQueue = {}
  if tr.dir == "out" then
    if sending then sending.cancel() end
  else
    service.cancelReceive()
  end
  M.state.transfer = nil
  changed()
end

--- 收起进度页（传输继续，界面上显示状态条，点它回来）
function M.hideTransfer()
  local tr = M.state.transfer
  if not tr then return end
  if tr.done then M.state.transfer = nil else tr.hidden = true end
  changed()
end

function M.showTransfer()
  if M.state.transfer then M.state.transfer.hidden = false; changed() end
end

M.closeTransfer = M.hideTransfer

-- ---------------------------------------------------------------- 接收

local incomingRespond

function M.toggleIncomingFile(i)
  local f = M.state.incoming and M.state.incoming.files[i]
  if f then f.on = not f.on; changed() end
end

function M.selectAllIncoming()
  local inc = M.state.incoming
  if not inc then return end
  local all = true
  for _, f in ipairs(inc.files) do if not f.on then all = false end end
  for _, f in ipairs(inc.files) do f.on = not all end
  changed()
end

function M.acceptIncoming()
  local inc = M.state.incoming
  if not inc then return end
  M.state.incoming = nil
  if inc.trust and inc.peer.fingerprint then prefs.favorites[inc.peer.fingerprint] = true; savePrefs(); refreshDevices() end
  local ids = {}
  for _, f in ipairs(inc.files) do if f.on then ids[#ids + 1] = f.id end end
  if incomingRespond then incomingRespond(ids); incomingRespond = nil end
  changed()
end

function M.declineIncoming()
  M.state.incoming = nil
  if incomingRespond then incomingRespond(nil); incomingRespond = nil end
  changed()
end

local function peerView(p)
  return { alias = p.alias or t("未知设备"), model = p.deviceModel or "", deviceType = p.deviceType or "desktop",
           tag = p.ip and ("#" .. (p.ip:match("(%d+)$") or "")) or "", ip = p.ip or "", fingerprint = p.fingerprint }
end

-- ---------------------------------------------------------------- 链接分享

local shareResponders = {}

function M.startShareLink()
  local items = {}
  for _, it in ipairs(M.state.selection) do if it.path then items[#items + 1] = it end end
  if #items == 0 then lx.dialog.toast(t("链接分享只能分享文件，先选择文件")); return end
  local pin = string.format("%04d", math.random(0, 9999))
  local sh = service.startShare(items, { pin = pin, autoAccept = prefs.shareAutoAccept })
  M.state.shareLink = { url = service.shareUrl(), pin = pin, requirePin = true, autoAccept = sh.autoAccept, requests = sh.requests }
  changed()
end

function M.setShareOption(key, value)
  local sl = M.state.shareLink
  if not sl then return end
  sl[key] = value
  service.updateShare({ pin = sl.requirePin and sl.pin or nil, autoAccept = sl.autoAccept })
  changed()
end

function M.stopShareLink()
  service.stopShare()
  M.state.shareLink = nil
  shareResponders = {}
  changed()
end

function M.answerShareRequest(id, ok)
  local respond = shareResponders[id]
  shareResponders[id] = nil
  if respond then respond(ok) end
  changed()
end

-- ---------------------------------------------------------------- PIN

function M.setPin(pin)
  prefs.pin = pin; prefs.requirePin = pin ~= nil and pin ~= ""
  M.state.pin = prefs.pin; M.state.requirePin = prefs.requirePin
  service.config.pin = prefs.pin; service.config.requirePin = prefs.requirePin
  savePrefs(); changed()
end

function M.toggleRequirePin(on)
  if on then
    lx.dialog.prompt(t("设置接收 PIN"), t("对方发送前需要输入这个 PIN"), function(v)
      if v and v ~= "" then M.setPin(v) end
    end, { placeholder = t("4–8 位数字") })
  else
    M.setPin(nil)
  end
end

-- ---------------------------------------------------------------- 接上服务

local recvMeter

service.hooks = {
  onDevices = function() refreshDevices(); changed() end,
  onIncoming = function(req, respond)
    incomingRespond = respond
    local files = {}
    for _, f in ipairs(req.files) do
      files[#files + 1] = badgeItem({ id = f.id, name = f.fileName, size = f.size, mime = f.fileType, on = true })
    end
    M.state.incoming = { peer = peerView(req.peer), files = files, trust = false }
    host.showWindow()
    pcall(function()
      if lx.notify and lx.notify.show then
        lx.notify.show({ title = t("超传"), body = t("%s 想发给你 %d 个文件", req.peer.alias or t("有人"), #files) })
      end
    end)
    changed()
  end,
  onIncomingCancelled = function()
    incomingRespond = nil
    if M.state.incoming then M.state.incoming = nil; lx.dialog.toast(t("对方取消了发送")); changed() end
  end,
  onText = function(peer, text)
    M.state.textMessage = { from = peer.alias or t("未知设备"), text = text }
    host.showWindow()
    addHistory({ dir = "in", files = { { name = t("文本消息"), text = text } }, peer = peer.alias })
    changed()
  end,
  onReceiveStart = function(s)
    recvMeter = speedMeter()
    local files = {}
    for _, id in ipairs(s.order) do
      local f = s.files[id]
      local ext, tint = P.badge(f.fileName, f.fileType)
      files[#files + 1] = { id = id, name = f.fileName, ext = ext, tint = tint, size = f.size, sent = 0 }
    end
    M.state.transfer = { dir = "in", peer = peerView(s.peer), files = files, total = s.total, sent = 0, speed = 0, done = false }
    changed()
  end,
  onReceiveProgress = function(s)
    local tr = M.state.transfer
    if not tr or tr.dir ~= "in" then return end
    for _, f in ipairs(tr.files) do
      local sf = s.files[f.id]
      if sf then f.sent = sf.received; f.state = sf.state end
    end
    tr.sent = s.received
    tr.speed = recvMeter and recvMeter(s.received) or 0
    changed()
  end,
  onReceiveDone = function(s, ok, err)
    local tr = M.state.transfer
    local hist = {}
    for _, id in ipairs(s.order) do
      local f = s.files[id]
      if f.state == "done" then
        hist[#hist + 1] = { name = f.fileName, size = f.size, path = f.path }
        if P.isMobile() and M.state.saveToAlbum and ((f.fileType or ""):match("^image/") or (f.fileType or ""):match("^video/")) then pcall(lx.album.save, f.path) end
      end
    end
    if #hist > 0 then addHistory({ dir = "in", files = hist, peer = s.peer.alias, total = s.received }) end
    if tr and tr.dir == "in" then
      tr.done = true; tr.speed = 0
      if ok then
        tr.sent = tr.total
        tr.savedTo = hist[1] and hist[1].path
        finishTransfer(tr)
      else
        tr.failed = true; tr.error = err or t("接收中断")
        lx.dialog.toast(tr.error)
      end
    end
    changed()
  end,
  onShareRequest = function(request, respond)
    shareResponders[request.id] = respond
    changed()
  end,
  onShareRequestsChanged = function() changed() end,
  onServerError = function(msg)
    lx.dialog.toast(t("接收服务启动失败：%s（端口 %d 被占用？）", tostring(msg), service.config.port or P.PORT))
  end,
}

--- 启动（main.lua 在 onLaunch 里调用；测试不调用）
function M.start()
  service.config.quickSave = QUICK[M.state.quickSave] or "favorites"
  service.config.requirePin = M.state.requirePin
  service.config.pin = M.state.pin
  service.config.favorites = prefs.favorites
  service.config.saveDir = prefs.saveDir
  service.config.https = M.state.encrypted
  service.config.port = prefs.port or P.PORT
  service.config.multicast = prefs.multicast or P.MULTICAST
  service.config.discoveryTimeout = prefs.discoveryTimeout
  P.refreshLanIp(function() M.state.identity = identity(); changed() end)
  service.start()
  M.state.encrypted = service.config.protocol == "https"
  M.state.saveDir = service.saveDir()
  M.state.scanning = true
  lx.timer.setTimeout(function() M.state.scanning = false; changed() end, 6000)
  pcall(lx.network.onChange, function()
    P.lanIp = nil
    P.refreshLanIp(function() M.state.identity = identity(); M.rescan() end)
  end)
  -- 桌面：托盘 / 启动时隐藏 / 右键菜单与系统状态对齐
  if host.isDesktop() then
    if prefs.closeToTray then host.setCloseToTray(true) end
    if prefs.startHidden and prefs.closeToTray then host.hideWindow() end
    if host.contextMenuSupported() and prefs.contextMenu then host.setContextMenu(true) end
  end
  -- 系统交给本 App 的文件（启动时带进来的 + 之后的）
  host.onIncomingFiles(function() M.takeIncomingFiles() end)
  lx.timer.setTimeout(M.takeIncomingFiles, 300)
  pcall(lx.events.on, "app.foreground", M.takeIncomingFiles)
  changed()
end

M.loadHistory()

return M
