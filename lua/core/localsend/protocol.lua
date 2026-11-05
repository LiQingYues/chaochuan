-- LocalSend 协议 v2.1 常量与本机身份（别名 / 指纹 / 设备类型），以及 MIME、文件名工具。
-- 协议说明：https://github.com/localsend/protocol （字段名、状态码与之逐一对应，改动前先对照）
local lx = require("lx")

local M = {}

M.VERSION = "2.1"
M.PORT = 53317
M.MULTICAST = "224.0.0.167"
M.API = "/api/localsend/v2"

-- ---------------------------------------------------------------- 本机身份

local ADJ = { "安静的", "敏捷的", "勇敢的", "明亮的", "机灵的", "温柔的", "快乐的", "清爽的", "沉稳的", "好奇的", "灵巧的", "坚定的" }
local NOUN = { "银杏", "红隼", "海豚", "青松", "云雀", "灯塔", "白鹭", "山茶", "雪豹", "竹林", "橘子", "鲸鱼" }

local function randomAlias()
  math.randomseed(os.time() + math.floor((lx.timer.now and lx.timer.now() or 0) % 100000))
  return ADJ[math.random(#ADJ)] .. NOUN[math.random(#NOUN)]
end

function M.isMobile()
  local p = lx.device.platform
  return p == "ios" or p == "android"
end

--- 设置里可以覆盖设备类型 / 型号（LocalSend 同款），store 写入 M.overrides
M.overrides = {}

function M.deviceType() return M.overrides.deviceType or (M.isMobile() and "mobile" or "desktop") end

function M.deviceModel()
  if M.overrides.deviceModel and M.overrides.deviceModel ~= "" then return M.overrides.deviceModel end
  local d = lx.device
  local name = d.modelName or d.model
  if not name or name == "" then name = d.osName or d.platform end
  return name
end

--- 本机身份：首次生成后存 lx.storage（别名可改；指纹在 http 模式下是随机串，LocalSend 只用它判重）
function M.identity()
  local id = lx.storage.get("ls.identity")
  if type(id) ~= "table" or not id.fingerprint then
    id = { alias = randomAlias(), fingerprint = lx.crypto.toHex(lx.crypto.randomBytes(32)) }
    lx.storage.set("ls.identity", id)
  end
  return id
end

--- 重新生成身份（新别名 + 新指纹；https 证书也重新生成）
function M.resetIdentity()
  lx.storage.remove("ls.identity")
  lx.storage.remove("ls.cert")
  M.activeFingerprint = nil
  return M.identity()
end

function M.saveAlias(alias)
  local id = M.identity()
  id.alias = alias
  lx.storage.set("ls.identity", id)
end

-- ---------------------------------------------------------------- HTTPS 证书

M.activeFingerprint = nil   -- https 时 = 证书 SHA-256（LocalSend 约定）；http 时用 identity 里的随机串

--- 当前对外用的指纹
function M.fingerprint() return M.activeFingerprint or M.identity().fingerprint end

--- 本机自签证书：首次生成（RSA 2048，约 0.1~1 秒），之后复用。返回 certPath, keyPath, fingerprint；不支持时 nil, err
function M.ensureCert()
  if not lx.crypto.supportsSelfSignedCert then return nil, "当前平台不支持生成证书" end
  local dir = lx.fs.join(lx.fs.paths.documents, ".chaochuan")
  local cert, key = lx.fs.join(dir, "cert.pem"), lx.fs.join(dir, "key.pem")
  local saved = lx.storage.get("ls.cert")
  if type(saved) == "table" and saved.fingerprint and lx.fs.exists(cert) and lx.fs.exists(key) then
    return cert, key, saved.fingerprint
  end
  lx.fs.mkdir(dir)
  local fp, err = lx.crypto.selfSignedCert(cert, key, "超传", 3650)
  if not fp then return nil, err end
  lx.storage.set("ls.cert", { fingerprint = fp })
  return cert, key, fp
end

--- info（/info、/register、prepare-* 里的 info 字段）
function M.info(port, protocol, withPort)
  local id = M.identity()
  local t = { alias = id.alias, version = M.VERSION, deviceModel = M.deviceModel(), deviceType = M.deviceType(),
              fingerprint = M.fingerprint(), download = true, app = "chaochuan" }   -- app：非标准字段，LocalSend 忽略；用来区分超传 / LocalSend
  if withPort then t.port = port; t.protocol = protocol end
  return t
end

-- ---------------------------------------------------------------- 网络

M.lanIp = nil   -- Wi‑Fi 网卡的地址（refreshLanIp 异步取到）；有 VPN 时 device.getNetwork 可能给出 tun 网卡地址

--- 刷新 Wi‑Fi 地址：cb(ip | nil)
function M.refreshLanIp(cb)
  -- 宿主的 interfaces（各平台，按 Wi‑Fi / 以太网优先排好序）
  local okHost, list = pcall(function() return require("core.host").interfaces() end)
  if okHost and type(list) == "table" and list[1] and list[1].ip then
    M.lanIp = list[1].ip
    if cb then cb(M.lanIp) end
    return
  end
  -- Android 旧包：宿主的 ChaochuanNetBridge 直接读 Wi‑Fi 网卡地址（开 VPN 时系统 API 只给 tun 地址）
  if lx.native.exists and lx.native.exists("chaochuanNet") then
    local ok, ip = pcall(function() return lx.native("chaochuanNet").lanIPv4() end)
    if ok and type(ip) == "string" and ip:match("^%d+%.%d+%.%d+%.%d+$") then
      M.lanIp = ip
      if cb then cb(ip) end
      return
    end
  end
  local ok = pcall(lx.wifi.getInfo, function(info)
    local ip = type(info) == "table" and info.ip
    if type(ip) == "string" and ip:match("^%d+%.%d+%.%d+%.%d+$") and ip ~= "0.0.0.0" then M.lanIp = ip end
    if cb then cb(M.lanIp) end
  end, { location = false })
  if not ok and cb then cb(M.lanIp) end
end

--- 本机 IPv4（优先 Wi‑Fi 网卡；取不到时 nil）
M.preferredIp = nil   -- 设置里选定的网卡地址（nil = 自动）

function M.localIPv4()
  if M.preferredIp then return M.preferredIp end
  if M.lanIp then return M.lanIp end
  local ok, info = pcall(lx.device.getNetwork)
  if ok and type(info) == "table" and info.ipv4 and info.ipv4 ~= "" then return info.ipv4 end
  return nil
end

-- ---------------------------------------------------------------- 文件

local MIME = {
  jpg = "image/jpeg", jpeg = "image/jpeg", png = "image/png", gif = "image/gif", webp = "image/webp", heic = "image/heic", bmp = "image/bmp",
  mp4 = "video/mp4", mov = "video/quicktime", mkv = "video/x-matroska", avi = "video/x-msvideo",
  mp3 = "audio/mpeg", m4a = "audio/mp4", wav = "audio/wav", flac = "audio/flac",
  pdf = "application/pdf", zip = "application/zip", apk = "application/vnd.android.package-archive",
  txt = "text/plain", md = "text/markdown", json = "application/json", html = "text/html",
  doc = "application/msword", docx = "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  xls = "application/vnd.ms-excel", xlsx = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  ppt = "application/vnd.ms-powerpoint", pptx = "application/vnd.openxmlformats-officedocument.presentationml.presentation",
}

function M.ext(name) return ((name or ""):match("%.([%w]+)$") or ""):lower() end

function M.mime(name) return MIME[M.ext(name)] or "application/octet-stream" end

--- 文件角标：扩展名大写（最多 4 个字符）+ 颜色
local TINT = { image = "#2F7D6D", video = "#6B5B95", audio = "#B5651D", text = "#4A4442", pdf = "#D62839", zip = "#6B5B95" }
function M.badge(name, mime)
  mime = mime or M.mime(name)
  local ext = M.ext(name):upper()
  if ext == "" then ext = "FILE" end
  local kind = mime:match("^(%a+)/") or ""
  local tint = TINT[kind] or (mime:find("pdf") and TINT.pdf) or (mime:find("zip") and TINT.zip) or "#2C5C9E"
  if mime:find("^text/") then tint = TINT.text end
  return ext:sub(1, 4), tint
end

--- 接收端：把对方给的文件名变成安全的相对路径（允许子目录，去掉 .. / 绝对路径 / 非法字符）
function M.safeRelativePath(name)
  local parts = {}
  for seg in tostring(name or "file"):gsub("\\", "/"):gmatch("[^/]+") do
    seg = seg:gsub("[%c<>:\"|%?%*]", "_")
    if seg ~= "." and seg ~= ".." and seg ~= "" then parts[#parts + 1] = seg end
  end
  if #parts == 0 then parts[1] = "file" end
  return table.concat(parts, "/")
end

--- 目录里不重名：a.txt → a (1).txt
function M.uniquePath(dir, rel)
  local path = dir .. "/" .. rel
  if not lx.fs.exists(path) then return path end
  local base, ext = rel:match("^(.*)(%.[^./]+)$")
  if not base then base, ext = rel, "" end
  for i = 1, 9999 do
    local p = string.format("%s/%s (%d)%s", dir, base, i, ext)
    if not lx.fs.exists(p) then return p end
  end
  return path
end

return M
