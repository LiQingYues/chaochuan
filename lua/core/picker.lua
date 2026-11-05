-- 选择要发送的内容 → 统一成 { name, size, mime, path } 或 { text } 列表（回调 cb(items)）。
--   文件 / 文件夹：宿主的系统选择器（core/host：macOS NSOpenPanel、Windows IFileOpenDialog、iOS 文档选择器、Android SAF）；
--                  旧安装包没有宿主能力时退回 osascript / PowerShell（桌面）或相册（手机）
--   相册：lx.album；文本：输入框；粘贴：剪贴板
--   itemsFromPaths(paths)：系统交进来的路径（打开方式 / 分享 / 拖拽）→ items（文件夹展开成里面的文件）
local lx = require("lx")
local t = require("i18n")
local P = require("core.localsend.protocol")
local host = require("core.host")

local M = {}

local function shellQuote(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

--- 文件信息：优先 lx.fs.stat；读不到时用 io 兜底（取大小 / 判断目录）
local function statPath(path)
  local st = lx.fs.stat(path)
  if st then
    if type(st.isDir) == "number" then st.isDir = st.isDir ~= 0 end
    return st
  end
  local f = io.open(path, "rb")
  if not f then return nil end
  local ok, err = f:read(0)
  if ok == nil and err and tostring(err):lower():find("director") then f:close(); return { size = 0, isDir = true } end
  local size = f:seek("end")
  f:close()
  return { size = size or 0, isDir = false }
end
M.statPath = statPath

local function fileItem(path, relName)
  local st = statPath(path)
  if not st or st.isDir then return nil end
  local name = relName or lx.fs.basename(path)
  return { name = name, size = st.size, mime = P.mime(name), path = path }
end

--- 递归列出目录里的文件，名字带上相对路径（LocalSend 用 fileName 里的 "/" 表示子目录）
local function walk(dir, prefix, out)
  for _, name in ipairs(lx.fs.list(dir) or {}) do
    if name:sub(1, 1) ~= "." then
      local full = lx.fs.join(dir, name)
      local st = statPath(full)
      if st and st.isDir then walk(full, prefix .. name .. "/", out)
      elseif st then
        out[#out + 1] = { name = prefix .. name, size = st.size, mime = P.mime(name), path = full }
      end
    end
  end
  return out
end

--- 路径列表 → items（文件夹展开）
function M.itemsFromPaths(paths)
  local out = {}
  for _, path in ipairs(paths or {}) do
    path = tostring(path):gsub("[/\\]$", "")
    local st = statPath(path)
    if st and st.isDir then
      walk(path, lx.fs.basename(path) .. "/", out)
    elseif st then
      local it = fileItem(path)
      if it then out[#out + 1] = it end
    else
      lx.log.warn("[picker] 读不到文件信息：" .. path)
    end
  end
  return out
end

-- ---------------------------------------------------------------- 旧安装包的退路

local function popenLines(cmd)
  local errFile = os.tmpname()
  local ok, fh = pcall(io.popen, cmd .. " 2>" .. errFile)
  if not ok or not fh then return nil end
  local out = {}
  for line in fh:lines() do if line ~= "" then out[#out + 1] = line end end
  fh:close()
  local ef = io.open(errFile, "r")
  local err = ef and ef:read("a") or ""
  if ef then ef:close() end
  os.remove(errFile)
  if err ~= "" then lx.log.warn("[picker] " .. err) end
  return out
end

local function legacyDialog(folder)
  local p = lx.device.platform
  if p == "macos" then
    local script = folder
      and 'POSIX path of (choose folder)'
      or 'set fs to choose file with multiple selections allowed\nset out to ""\nrepeat with f in fs\nset out to out & POSIX path of f & linefeed\nend repeat\nreturn out'
    return popenLines("osascript -e " .. shellQuote(script))
  elseif p == "windows" then
    local ps = folder
      and "Add-Type -AssemblyName System.Windows.Forms; $d=New-Object System.Windows.Forms.FolderBrowserDialog; if($d.ShowDialog() -eq 'OK'){$d.SelectedPath}"
      or "Add-Type -AssemblyName System.Windows.Forms; $d=New-Object System.Windows.Forms.OpenFileDialog; $d.Multiselect=$true; if($d.ShowDialog() -eq 'OK'){$d.FileNames}"
    return popenLines('powershell -NoProfile -STA -Command "' .. ps .. '"')
  end
  return nil
end

local function pickAlbum(cb)
  lx.album.pick({ type = "all", limit = 50 }, function(items, err)
    local out = {}
    for _, m in ipairs(items or {}) do
      local name = lx.fs.basename(m.path)
      local st = statPath(m.path)
      out[#out + 1] = { name = name, size = m.size or (st and st.size) or 0, mime = m.mime or P.mime(name), path = m.path }
    end
    cb(out, err)
  end)
end

-- ---------------------------------------------------------------- 入口

--- kind："file" | "folder" | "media" | "text" | "paste"
function M.pick(kind, cb)
  if kind == "media" then return pickAlbum(cb) end
  if kind == "text" then
    return lx.dialog.prompt(t("发送文本"), t("输入要发送的文字"), function(v)
      if v and v ~= "" then cb({ { text = v, name = t("文本消息") } }) end
    end, { placeholder = t("文字、链接……") })
  end
  if kind == "paste" then
    local ok, text = pcall(lx.clipboard.get)
    if ok and text and text ~= "" then return cb({ { text = text, name = t("剪贴板") } }) end
    lx.dialog.toast(t("剪贴板是空的"))
    return
  end
  -- 文件 / 文件夹：宿主的系统选择器
  local folder = kind == "folder"
  host.pickFiles({ folder = folder, multiple = true }, function(paths, err)
    if paths then
      local items = M.itemsFromPaths(paths)
      if #paths > 0 and #items == 0 then lx.dialog.toast(folder and t("文件夹是空的") or t("读不到选中的文件")) end
      return cb(items)
    end
    -- 旧安装包：没有宿主能力
    lx.log.warn("[picker] 宿主选择器不可用：" .. tostring(err))
    local lines = legacyDialog(folder)
    if lines then return cb(M.itemsFromPaths(lines)) end
    if P.isMobile() then return pickAlbum(cb) end
    lx.dialog.toast(t("这个平台还不支持选择文件"))
  end)
end

return M
