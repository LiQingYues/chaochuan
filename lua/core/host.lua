-- 宿主原生能力（契约见 docs/native_host.md）：文件选择、打开 / 定位文件、外部交给本 App 的文件、托盘、开机自启、右键菜单、网卡。
-- macOS / iOS / Android 走 lx.native("chaochuanHost")；Windows 的 C++ 宿主没有反射，走 lx.bridge.call("chaochuanHost", …)。
-- 宿主没有这个能力（旧安装包、headless 测试）时一律安全降级：同步方法返回 nil，异步方法回调 (nil, "unsupported")。
local lx = require("lx")

local M = {}

local NAME = "chaochuanHost"
local isWindows = lx.device.platform == "windows"

local function nativeProxy()
  if isWindows then return nil end
  local ok, exists = pcall(function() return lx.native.exists and lx.native.exists(NAME) end)
  if not ok or not exists then return nil end
  return lx.native(NAME)
end

--- 有没有宿主能力
function M.available()
  if isWindows then
    local ok, r = pcall(lx.bridge.call, NAME, "interfaces", {})
    return ok and type(r) == "table"
  end
  return nativeProxy() ~= nil
end

local function syncCall(method, args)
  args = args or {}
  if isWindows then
    local ok, r = pcall(lx.bridge.call, NAME, method, args)
    if not ok then return nil end
    return r == nil and {} or r   -- 空结果到 Lua 是 nil
  end
  local p = nativeProxy()
  if not p then return nil end
  local ok, r = pcall(function() return p[method](args) end)
  if not ok then lx.log.warn("[host] " .. method .. " 出错：" .. tostring(r)) end
  return ok and r or nil
end

local function asyncCall(method, args, cb)
  args = args or {}
  local function done(r, err)
    if cb then cb(r, err) end
  end
  if isWindows then
    -- Windows 宿主：没有字段的结果（如空的 paths）到 Lua 是 nil，按空表处理；出错才有 err
    local ok, err = pcall(lx.bridge.callAsync, NAME, method, args, function(r, e)
      if r == nil and e == nil then r = {} end
      done(r, e)
    end)
    if not ok then done(nil, tostring(err)) end
    return
  end
  local p = nativeProxy()
  if not p then return done(nil, "unsupported") end
  local ok, err = pcall(function() p[method](args, done) end)
  if not ok then done(nil, tostring(err)) end
end

local function supported(r) return type(r) == "table" and r.supported ~= false end

--- 数组结果按下标排好（Windows 的数组可能是 "1"、"2" 这样的字符串键，pairs 顺序不定）
local function asList(t)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return (tonumber(a) or 0) < (tonumber(b) or 0) end)
  local out = {}
  for _, k in ipairs(keys) do out[#out + 1] = t[k] end
  return out
end

-- ---------------------------------------------------------------- 文件

--- 选文件 / 文件夹：cb(paths | nil, err)；宿主不支持时 paths = nil
function M.pickFiles(opts, cb)
  asyncCall("pickFiles", { folder = opts and opts.folder == true, multiple = not (opts and opts.multiple == false) }, function(r, err)
    if type(r) == "table" and r.supported ~= false and not err then return cb(type(r.paths) == "table" and asList(r.paths) or {}) end
    cb(nil, err or "unsupported")
  end)
end

--- 选目录（桌面）：cb(path | nil)；取消时 path = ""
function M.pickDirectory(cb)
  asyncCall("pickDirectory", {}, function(r)
    if supported(r) and type(r.path) == "string" then return cb(r.path) end
    cb(nil)
  end)
end

--- 打开文件 / 在文件管理器里显示：cb(ok)
function M.openPath(path, reveal, cb)
  asyncCall("openPath", { path = path, reveal = reveal == true }, function(r)
    if cb then cb(type(r) == "table" and r.ok == true) end
  end)
end

--- 取出系统交给本 App 的文件（打开方式 / 分享 / 拖拽 / 右键菜单 / 命令行）
function M.takeIncomingFiles()
  local r = syncCall("takeIncomingFiles")
  local out = {}
  if type(r) == "table" and type(r.paths) == "table" then
    for _, p in ipairs(asList(r.paths)) do if type(p) == "string" then out[#out + 1] = p end end
  end
  return out
end

--- 订阅「有新文件交进来」：fn()；返回取消函数
function M.onIncomingFiles(fn)
  local ok, off
  if isWindows then
    ok, off = pcall(lx.bridge.on, NAME, "incomingFiles", function() fn() end)
  else
    local p = nativeProxy()
    if not p then return function() end end
    ok, off = pcall(function() return p:on("incomingFiles", function() fn() end) end)
  end
  return (ok and type(off) == "function") and off or function() end
end

--- 本机 IPv4 网卡：{ { name, ip } }；宿主不支持时 nil
function M.interfaces()
  local r = syncCall("interfaces")
  if type(r) == "table" and type(r.list) == "table" then
    local out = {}
    for _, it in ipairs(asList(r.list)) do if type(it) == "table" and it.ip then out[#out + 1] = it end end
    return out
  end
  return nil
end

-- ---------------------------------------------------------------- 桌面

function M.isDesktop()
  local p = lx.device.platform
  return p == "macos" or p == "windows"
end

local function desktopSync(method, args)
  if not M.isDesktop() then return nil end
  local r = syncCall(method, args)
  return supported(r) and r or nil
end

function M.setCloseToTray(on) return desktopSync("setCloseToTray", { enabled = on == true }) ~= nil end
function M.showWindow() desktopSync("showWindow") end
function M.hideWindow() desktopSync("hideWindow") end

--- 开机自启：返回 ok, err
function M.setLaunchAtLogin(on)
  local r = desktopSync("setLaunchAtLogin", { enabled = on == true })
  if not r then return false, "unsupported" end
  return r.ok ~= false, r.error
end

function M.getLaunchAtLogin()
  local r = desktopSync("getLaunchAtLogin")
  return r and r.enabled == true or false
end

--- 右键菜单（只有 Windows）：返回 ok
function M.contextMenuSupported() return isWindows end
function M.setContextMenu(on)
  local r = desktopSync("setContextMenu", { enabled = on == true })
  return r ~= nil and r.ok ~= false
end

return M
