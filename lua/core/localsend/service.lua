-- LocalSend v2.1 服务（发现 + 接收 + 发送 + 链接分享），纯 Lua，建在 lx.TcpServer / TcpSocket / UdpSocket 上。
-- 界面不直接用它：core/store 设置 M.hooks 接收事件、调用 M.send / M.respond… 驱动。
--
--   发现：UDP 组播 224.0.0.167:53317 发 announce；收到别人的 announce（需要引擎支持 multicast）就 POST /register 回应；
--        别人对我们的 announce 用 /register 回应 → 加入设备列表；另有 /24 子网 HTTP 扫描兜底（组播被路由器丢掉时）。
--   接收：prepare-upload（PIN / 快速保存 / 询问用户）→ upload 流式写 .part → 改名；cancel。纯文本消息直接展示并回 204。
--   发送：prepare-upload → 逐个 upload（io 分块读，等 drain 再写）→ 进度；401 要 PIN、403 拒绝、409 对方忙。
--   链接分享：prepare-download / download + 根路径的简易网页（浏览器下载，无需安装）。
local lx = require("lx")
local json = require("lx.json.json")
local http = require("core.localsend.http")
local P = require("core.localsend.protocol")

local M = {}

local API = P.API

M.hooks = {
  -- onDevices()                                  设备列表变了
  -- onIncoming(req, respond)                     有人要发文件：req = { peer, files = { {id, fileName, size, fileType} } }；respond(acceptedIds | nil)
  -- onIncomingCancelled()                        请求方在你决定前断开 / 取消
  -- onText(peer, text)                           收到纯文本消息
  -- onReceiveStart(session) / onReceiveProgress(session) / onReceiveDone(session, ok, err)
  -- onShareRequest(request, respond)             链接分享：浏览器请求下载，respond(true/false)
  -- onShareRequestsChanged()
  -- onLog(text)
}

M.config = {
  port = P.PORT,
  protocol = "http",          -- 服务端实际协议（start 时定：https = true 且能生成证书就是 "https"）
  https = true,               -- 加密：用自签证书提供 HTTPS（LocalSend 默认）
  quickSave = "favorites",    -- "off" | "favorites" | "all"
  requirePin = false, pin = nil,
  saveDir = nil,              -- 接收目录（start 时按平台给默认值）
  favorites = {},             -- fingerprint → true
  multicast = nil,            -- 组播地址（nil = 224.0.0.167）
  discoveryTimeout = 1000,    -- 子网扫描每个地址的超时（毫秒）
}

M.devices = {}                -- fingerprint → { fingerprint, alias, deviceModel, deviceType, ip, port, protocol, download, lastSeen }
M.running = false

local function log(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
  local text = table.concat(parts, " ")
  lx.log("[localsend] " .. text)
  if M.hooks.onLog then pcall(M.hooks.onLog, text) end
end

local function hook(name, ...)
  local fn = M.hooks[name]
  if fn then
    local ok, err = pcall(fn, ...)
    if not ok then lx.log.error("[localsend] hook " .. name .. " 出错：" .. tostring(err)) end
  end
end

local function myInfo(withPort) return P.info(M.config.port, M.config.protocol, withPort) end
local function myFingerprint() return P.fingerprint() end

-- ---------------------------------------------------------------- 设备表

local function upsertDevice(info, ip)
  if type(info) ~= "table" or not info.fingerprint or info.fingerprint == myFingerprint() then return nil end
  local d = M.devices[info.fingerprint] or {}
  d.fingerprint = info.fingerprint
  d.alias = info.alias or d.alias or "未知设备"
  d.deviceModel = info.deviceModel or d.deviceModel
  d.deviceType = info.deviceType or d.deviceType or "desktop"
  d.ip = ip or d.ip
  d.port = tonumber(info.port) or d.port or P.PORT
  d.protocol = info.protocol or d.protocol or "https"
  d.download = info.download == true
  d.version = info.version or d.version
  d.app = info.app or d.app
  d.lastSeen = os.time()
  local isNew = M.devices[info.fingerprint] == nil
  M.devices[info.fingerprint] = d
  if isNew then log("发现设备", d.alias, d.ip .. ":" .. d.port, d.protocol) end
  hook("onDevices")
  return d
end

local function baseUrl(d) return string.format("%s://%s:%d", d.protocol or "https", d.ip, d.port or P.PORT) end

-- ---------------------------------------------------------------- 发现

local udp
local announceTimers = {}

local function announce(isAnnounce)
  if not udp then return end
  local msg = myInfo(true)
  msg.announce = isAnnounce ~= false
  msg.announcement = msg.announce   -- v1 兼容字段
  pcall(udp.send, udp, json.encode(msg), M.config.multicast or P.MULTICAST, P.PORT)
end

--- 回应别人的 announce：先 HTTP /register，失败再 UDP 发 announce=false
local function answerAnnounce(info, ip)
  local d = { ip = ip, port = tonumber(info.port) or P.PORT, protocol = info.protocol or "https" }
  http.postJSON(baseUrl(d) .. API .. "/register", myInfo(true), function(status)
    if status ~= 200 then announce(false) end
  end, 3000)
end

local function startUdp()
  local socketMod = require("lx.net.socket")
  udp = lx.UdpSocket({ port = P.PORT, multicast = M.config.multicast or P.MULTICAST })
  udp:on("message", function(data, host)
    local info = json.tryDecode(data)
    if type(info) ~= "table" or not info.fingerprint or info.fingerprint == myFingerprint() then return end
    upsertDevice(info, host)
    if info.announce == true or info.announcement == true then answerAnnounce(info, host) end
  end)
  udp:on("error", function(msg) log("UDP：", msg) end)
  if not socketMod.supportsMulticast then
    log("当前引擎库不支持加入组播组：只能被动被别人发现 + 子网扫描（升级引擎库后自动启用）")
  end
end

--- 发 announce（启动时连发几次，刷新时再发）
function M.announceNow()
  for _, t in ipairs(announceTimers) do lx.timer.clearTimeout(t) end
  announceTimers = {}
  for _, delay in ipairs({ 0, 300, 1500 }) do
    announceTimers[#announceTimers + 1] = lx.timer.setTimeout(function() announce(true) end, delay)
  end
end

--- 子网扫描（/24）：对每个地址 POST /register，先 http 失败再 https。onDone(找到的数量)
local scanning = false
function M.scan(onDone)
  if scanning then return end
  local ip = P.localIPv4()
  if not ip then if onDone then onDone(0) end return end
  local prefix = ip:match("^(%d+%.%d+%.%d+%.)%d+$")
  if not prefix then if onDone then onDone(0) end return end
  scanning = true
  local queue = {}
  for i = 1, 254 do
    local target = prefix .. i
    if target ~= ip then queue[#queue + 1] = target end
  end
  local active, found, idx = 0, 0, 0
  local body = myInfo(true)
  local function nextOne()
    if idx >= #queue then
      if active == 0 and scanning then scanning = false; if onDone then onDone(found) end end
      return
    end
    idx = idx + 1
    local target = queue[idx]
    active = active + 1
    local function try(protocol, fallback)
      http.postJSON(protocol .. "://" .. target .. ":" .. P.PORT .. API .. "/register", body, function(status, info)
        if status == 200 and type(info) == "table" then
          info.protocol = info.protocol or protocol
          info.port = info.port or P.PORT
          if upsertDevice(info, target) then found = found + 1 end
          active = active - 1; nextOne()
        elseif fallback and status == nil then
          try(fallback, nil)
        else
          active = active - 1; nextOne()
        end
      end, M.config.discoveryTimeout or 1000)
    end
    try("http", "https")
  end
  for _ = 1, 48 do nextOne() end
end

--- 清空设备表（keep 里的设备留着，如收藏的）
function M.forgetStale(keep)
  for fp, _ in pairs(M.devices) do
    if not (keep and keep[fp]) then M.devices[fp] = nil end
  end
  hook("onDevices")
end

-- ---------------------------------------------------------------- 接收

local inbound = nil             -- 当前接收会话（LocalSend 同时只接一个）
local pendingAsk = nil          -- 正在询问用户的 prepare-upload

local function newId() return (lx.crypto.uuid():gsub("-", "")) end

local androidDir
local function defaultSaveDir()
  local p = lx.device.platform
  if p == "macos" then return (os.getenv("HOME") or lx.fs.paths.documents) .. "/Downloads/超传" end
  if p == "windows" then return (os.getenv("USERPROFILE") or lx.fs.paths.documents) .. "\\Downloads\\超传" end
  if p == "android" then
    -- 公共「下载/超传」（文件管理器里看得到）；写不进去时（老系统 / 权限）退回 App 自己的目录
    if androidDir == nil then
      androidDir = false
      local ext = lx.fs.paths.externalDocuments
      if ext and ext ~= "" then
        local dir = lx.fs.join(lx.fs.dirname(ext), "Download", "超传")
        pcall(lx.fs.mkdir, dir)
        local probe = lx.fs.join(dir, ".chaochuan_probe")
        local f = io.open(probe, "wb")
        if f then f:close(); os.remove(probe); androidDir = dir end
      end
    end
    if androidDir then return androidDir end
  end
  return lx.fs.join(lx.fs.paths.documents, "超传")
end

local function pinOk(req)
  if not M.config.requirePin then return true end
  return req.query.pin ~= nil and req.query.pin == M.config.pin
end

local function isTextOnly(files)
  local list = {}
  for _, f in pairs(files) do list[#list + 1] = f end
  return #list == 1 and (list[1].fileType or ""):find("^text/") and type(list[1].preview) == "string" and list[1] or nil
end

local function handlePrepareUpload(req, res)
  req.onEnd = function(body)
    local data = json.tryDecode(body or "")
    if type(data) ~= "table" or type(data.info) ~= "table" or type(data.files) ~= "table" then return res:send(400, "bad request") end
    if not pinOk(req) then return res:json(401, { message = "PIN required" }) end
    if inbound and not inbound.done then return res:json(409, { message = "Blocked by another session" }) end
    if pendingAsk then return res:json(409, { message = "Blocked by another session" }) end
    local peer = upsertDevice(data.info, req.ip) or { alias = data.info.alias or "未知设备", deviceModel = data.info.deviceModel,
                                                      deviceType = data.info.deviceType, fingerprint = data.info.fingerprint, ip = req.ip }

    -- 单条文本：直接展示，回 204（LocalSend 行为）
    local text = isTextOnly(data.files)
    if text then
      hook("onText", peer, text.preview)
      return res:send(204, "")
    end

    local files = {}
    for id, f in pairs(data.files) do
      files[#files + 1] = { id = f.id or id, fileName = f.fileName or id, size = tonumber(f.size) or 0, fileType = f.fileType, sha256 = f.sha256 }
    end
    table.sort(files, function(a, b) return a.fileName < b.fileName end)

    local function accept(ids)
      pendingAsk = nil
      if not ids then return res:json(403, { message = "Rejected" }) end
      if #ids == 0 then return res:send(204, "") end
      local session = { id = newId(), peer = peer, ip = req.ip, files = {}, order = {}, total = 0, received = 0, startedAt = os.time() }
      local tokens = {}
      local want = {}
      for _, id in ipairs(ids) do want[id] = true end
      for _, f in ipairs(files) do
        if want[f.id] then
          local token = newId()
          tokens[f.id] = token
          session.files[f.id] = { id = f.id, fileName = f.fileName, size = f.size, fileType = f.fileType, token = token, received = 0, state = "waiting" }
          session.order[#session.order + 1] = f.id
          session.total = session.total + f.size
        end
      end
      inbound = session
      hook("onReceiveStart", session)
      res:json(200, { sessionId = session.id, files = tokens })
    end

    local q = M.config.quickSave
    local fav = data.info.fingerprint and M.config.favorites[data.info.fingerprint]
    if q == "all" or (q == "favorites" and fav) then
      local ids = {}
      for _, f in ipairs(files) do ids[#ids + 1] = f.id end
      return accept(ids)
    end
    pendingAsk = { res = res }
    req.onAbort = function()
      if pendingAsk and pendingAsk.res == res then pendingAsk = nil; hook("onIncomingCancelled") end
    end
    hook("onIncoming", { peer = peer, files = files }, function(ids)
      if pendingAsk and pendingAsk.res == res then accept(ids) end
    end)
  end
end

local function finishInbound(ok, err)
  local s = inbound
  if not s or s.done then return end
  s.done = true
  hook("onReceiveDone", s, ok, err)
end

local function handleUpload(req, res)
  local q = req.query
  local s = inbound
  if not s or s.done or q.sessionId ~= s.id then return res:json(403, { message = "Invalid session" }) end
  local f = s.files[q.fileId or ""]
  if not f or f.token ~= q.token then return res:json(403, { message = "Invalid token" }) end
  if req.ip ~= s.ip then return res:json(403, { message = "Invalid IP" }) end

  local dir = M.config.saveDir or defaultSaveDir()
  local rel = P.safeRelativePath(f.fileName)
  local final = P.uniquePath(dir, rel)
  lx.fs.mkdir(lx.fs.dirname(final))
  local part = final .. ".part"
  local fh, err = io.open(part, "wb")
  if not fh then
    log("无法写入", part, err)
    req.onData = function() end   -- 丢弃请求体，不缓存
    req.onEnd = function() res:json(500, { message = "Cannot write file" }) end
    return
  end
  f.state = "receiving"
  f.path = final
  local lastHook = 0
  req.onData = function(chunk)
    if not fh then return end
    fh:write(chunk)
    f.received = f.received + #chunk
    s.received = s.received + #chunk
    local now = lx.timer.now()
    if now - lastHook > 150 then lastHook = now; hook("onReceiveProgress", s) end
  end
  req.onEnd = function()
    if fh then fh:close(); fh = nil end
    local ok, mvErr = pcall(lx.fs.move, part, final)
    if not ok then
      f.state = "failed"; log("改名失败", mvErr)
      res:json(500, { message = "Cannot save file" })
    else
      f.state = "done"
      res:send(200, "")
    end
    hook("onReceiveProgress", s)
    local allDone = true
    for _, id in ipairs(s.order) do if s.files[id].state ~= "done" and s.files[id].state ~= "failed" then allDone = false end end
    if allDone then finishInbound(true) end
  end
  req.onAbort = function()
    if fh then fh:close(); fh = nil end
    pcall(lx.fs.remove, part)
    f.state = "failed"
    hook("onReceiveProgress", s)
    -- 发送方断开：结束这次接收（以前界面一直停在半截的进度上）
    finishInbound(false, "连接中断：" .. f.fileName .. " 只收到 " .. f.received .. " / " .. f.size .. " 字节")
  end
end

local function handleCancel(req, res)
  if inbound and req.query.sessionId == inbound.id then
    finishInbound(false, "对方已取消")
  elseif pendingAsk then
    pendingAsk = nil
    hook("onIncomingCancelled")
  end
  res:send(200, "")
end

--- 本机取消正在接收的会话
function M.cancelReceive()
  if inbound and not inbound.done then
    local s = inbound
    finishInbound(false, "已取消")
    -- 通知发送方（尽力而为）
    if s.peer and s.peer.ip then
      http.request({ url = baseUrl(s.peer) .. API .. "/cancel?sessionId=" .. s.id, method = "POST", body = "", timeout = 3000 }, function() end)
    end
  end
end

-- ---------------------------------------------------------------- 链接分享（prepare-download / download）

local share = nil   -- { id, files = { [id] = { id, fileName, size, fileType, path } }, order, pin, autoAccept, clients = { [sessionId] = {...} }, requests = {...} }

function M.startShare(items, opts)
  share = { id = newId(), files = {}, order = {}, pin = opts and opts.pin, autoAccept = opts and opts.autoAccept, clients = {}, requests = {} }
  for _, it in ipairs(items) do
    if it.path then
      local id = newId()
      share.files[id] = { id = id, fileName = it.name, size = it.size, fileType = it.mime or P.mime(it.name), path = it.path }
      share.order[#share.order + 1] = id
    end
  end
  return share
end

function M.updateShare(opts)
  if not share then return end
  for k, v in pairs(opts) do share[k] = v end
end

function M.stopShare() share = nil end

local SHARE_PAGE = [[<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>超传 · 下载</title><style>
body{margin:0;font-family:-apple-system,"PingFang SC","Microsoft YaHei",sans-serif;background:#F6F4F3;color:#1A1718}
main{max-width:560px;margin:0 auto;padding:32px 16px}h1{font-size:24px;margin:0 0 4px}p{color:#67615F;margin:0 0 20px}
.card{background:#fff;border-radius:16px;padding:6px 16px}.row{display:flex;align-items:center;gap:12px;padding:12px 0;border-bottom:1px solid #F4F1F0}
.row:last-child{border:0}.name{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.size{color:#67615F;font-size:13px}
a.btn{background:#D62839;color:#fff;text-decoration:none;border-radius:10px;padding:8px 14px;font-weight:600;font-size:14px}
.msg{padding:24px 0;text-align:center;color:#67615F}</style></head><body><main>
<h1>超传</h1><p id="from">正在连接…</p><div class="card" id="list"><div class="msg">等待对方同意…</div></div></main><script>
async function load(pin){const q=pin?('?pin='+encodeURIComponent(pin)):'';
const r=await fetch('/api/localsend/v2/prepare-download'+q,{method:'POST'});
if(r.status===401){const p=prompt('请输入 PIN');if(p!==null)return load(p);return}
if(r.status!==200){document.getElementById('list').innerHTML='<div class="msg">对方拒绝了请求（'+r.status+'）</div>';return}
const d=await r.json();document.getElementById('from').textContent='来自 '+d.info.alias+'（'+(d.info.deviceModel||'')+'）';
const L=document.getElementById('list');L.innerHTML='';
for(const id in d.files){const f=d.files[id];const row=document.createElement('div');row.className='row';
const n=document.createElement('div');n.className='name';n.textContent=f.fileName;
const s=document.createElement('div');s.className='size';s.textContent=(f.size/1e6).toFixed(1)+' MB';
const a=document.createElement('a');a.className='btn';a.textContent='下载';
a.href='/api/localsend/v2/download?sessionId='+d.sessionId+'&fileId='+encodeURIComponent(id);a.download=f.fileName;
row.append(n,s,a);L.append(row)}}
load();</script></body></html>]]

local function handlePrepareDownload(req, res)
  req.onEnd = function()
    if not share then return res:json(403, { message = "No share" }) end
    if share.pin and share.pin ~= "" and req.query.pin ~= share.pin then return res:json(401, { message = "PIN required" }) end
    local function grant()
      local sid = newId()
      share.clients[sid] = { ip = req.ip }
      local files = {}
      for _, id in ipairs(share.order) do
        local f = share.files[id]
        files[id] = { id = id, fileName = f.fileName, size = f.size, fileType = f.fileType }
      end
      res:json(200, { info = myInfo(false), sessionId = sid, files = files })
    end
    local ua = req.headers["user-agent"] or ""
    local client = (ua:find("Edg/") and "Edge") or (ua:find("Chrome/") and "Chrome") or (ua:find("Firefox/") and "Firefox")
                   or (ua:find("Safari/") and "Safari") or "浏览器"
    local os_ = (ua:find("Windows") and "Windows") or (ua:find("iPhone") and "iPhone") or (ua:find("iPad") and "iPad")
                or (ua:find("Android") and "Android") or (ua:find("Mac OS") and "Mac") or ""
    local request = { id = #share.requests + 1, client = client .. (os_ ~= "" and (" · " .. os_) or ""), ip = req.ip, state = "pending", downloaded = 0 }
    table.insert(share.requests, request)
    if share.autoAccept then
      request.state = "accepted"; hook("onShareRequestsChanged"); return grant()
    end
    req.onAbort = function() if request.state == "pending" then request.state = "gone"; hook("onShareRequestsChanged") end end
    hook("onShareRequest", request, function(ok)
      if request.state ~= "pending" then return end
      request.state = ok and "accepted" or "declined"
      hook("onShareRequestsChanged")
      if ok then grant() else res:json(403, { message = "Rejected" }) end
    end)
  end
end

local function handleDownload(req, res)
  if not share then return res:send(403, "") end
  local c = share.clients[req.query.sessionId or ""]
  local f = share.files[req.query.fileId or ""]
  if not c or not f or c.ip ~= req.ip then return res:send(403, "") end
  for _, r in ipairs(share.requests) do
    if r.ip == req.ip and r.state == "accepted" then r.downloaded = (r.downloaded or 0) + 1; r.state = "done" end
  end
  hook("onShareRequestsChanged")
  res:sendFile(f.path, f.size, f.fileType, f.fileName)
end

-- ---------------------------------------------------------------- 服务端路由

local server

--- 链接分享专用的 http 服务（只开网页和下载接口）：主服务是 https 时，浏览器打开自签证书会报不安全，所以另开 http 端口
local shareServer
local function onShareRequest(req, res)
  local p, m = req.path, req.method
  if p == API .. "/prepare-download" and m == "POST" then return handlePrepareDownload(req, res) end
  if p == API .. "/download" and m == "GET" then return handleDownload(req, res) end
  if (p == "/" or p == "/index.html") and m == "GET" then
    if not share then return res:send(404, "超传：当前没有分享", { ["Content-Type"] = "text/plain; charset=utf-8" }) end
    return res:send(200, SHARE_PAGE, { ["Content-Type"] = "text/html; charset=utf-8" })
  end
  return res:send(404, "not found")
end

--- 分享链接（浏览器打开的地址）
function M.shareUrl()
  local ip = P.localIPv4() or "0.0.0.0"
  if M.config.protocol == "https" and M.sharePort then return "http://" .. ip .. ":" .. M.sharePort end
  return M.config.protocol .. "://" .. ip .. ":" .. (M.listenPort or M.config.port)
end

local function onRequest(req, res)
  local p, m = req.path, req.method
  if m == "OPTIONS" then return res:send(204, "", { ["Access-Control-Allow-Origin"] = "*" }) end
  if (p == API .. "/info" or p == "/api/localsend/v1/info") and m == "GET" then
    return res:json(200, myInfo(false))
  elseif p == API .. "/register" and m == "POST" then
    req.onEnd = function(body)
      local info = json.tryDecode(body or "")
      if type(info) == "table" then upsertDevice(info, req.ip) end
      res:json(200, myInfo(false))
    end
  elseif p == API .. "/prepare-upload" and m == "POST" then
    if not M.receiving then return res:json(403, { message = "Receiving disabled" }) end
    return handlePrepareUpload(req, res)
  elseif p == API .. "/upload" and m == "POST" then
    return handleUpload(req, res)
  elseif p == API .. "/cancel" and m == "POST" then
    req.onEnd = function() handleCancel(req, res) end
  elseif p == API .. "/prepare-download" and m == "POST" then
    return handlePrepareDownload(req, res)
  elseif p == API .. "/download" and m == "GET" then
    return handleDownload(req, res)
  elseif (p == "/" or p == "/index.html") and m == "GET" then
    if not share then return res:send(404, "超传：当前没有分享", { ["Content-Type"] = "text/plain; charset=utf-8" }) end
    return res:send(200, SHARE_PAGE, { ["Content-Type"] = "text/html; charset=utf-8" })
  else
    return res:send(404, "not found")
  end
end

-- ---------------------------------------------------------------- 发送

--- 发送给设备。items：{ { name, size, mime, path } | { text } }；cb：
---   onProgress(t)  t = { files = { {id, name, size, sent, state} }, total, sent }
---   onNeedPin(retry(pin))  对方要 PIN
---   onDone(ok, reason)     reason："rejected" / "busy" / "cancelled" / 错误文字；文本发完 ok = true
--- 返回 { cancel = fn }
function M.send(device, items, cb)
  local files, byId, order = {}, {}, {}
  for _, it in ipairs(items) do
    local id = newId()
    local entry
    if it.text then
      entry = { id = id, fileName = (it.name or "message") .. ".txt", size = #it.text, fileType = "text/plain", preview = it.text }
    else
      entry = { id = id, fileName = it.name, size = it.size or 0, fileType = it.mime or P.mime(it.name) }
    end
    files[id] = entry
    byId[id] = { id = id, name = entry.fileName, size = entry.size, sent = 0, state = "waiting", path = it.path, text = it.text }
    order[#order + 1] = id
  end
  local t = { files = {}, total = 0, sent = 0 }
  for _, id in ipairs(order) do t.files[#t.files + 1] = byId[id]; t.total = t.total + byId[id].size end

  local cancelled, current, sessionId = false, nil, nil
  local base = baseUrl(device)
  local function progress() if cb.onProgress then cb.onProgress(t) end end
  local function done(ok, reason) if cb.onDone then cb.onDone(ok, reason) end end

  local function uploadNext(tokens, i)
    if cancelled then return end
    local id = order[i]
    if not id then
      -- 有文件失败就不能报成功（以前只要走完一轮就 done(true)，断一半也显示「发送成功」）
      local failed = 0
      for _, fid in ipairs(order) do if byId[fid].state == "failed" then failed = failed + 1 end end
      if failed > 0 then return done(false, failed == #order and "发送中断（连接断开）" or (failed .. " 个文件发送失败")) end
      return done(true)
    end
    local f = byId[id]
    local token = tokens[id]
    if not token then f.state = "skipped"; progress(); return uploadNext(tokens, i + 1) end
    f.state = "sending"; progress()
    local fh, src
    if f.text then
      local sent = false
      src = function() if sent then return nil, true end sent = true return f.text, true end
    else
      fh = io.open(f.path, "rb")
      if not fh then f.state = "failed"; progress(); return uploadNext(tokens, i + 1) end
      src = function()
        local chunk = fh:read(256 * 1024)
        if not chunk then fh:close(); fh = nil; return nil, true end
        f.sent = f.sent + #chunk; t.sent = t.sent + #chunk
        return chunk, false
      end
    end
    local lastTick = 0
    local wrapped = function()
      local c, eof = src()
      local now = lx.timer.now()
      if now - lastTick > 150 then lastTick = now; progress() end
      return c, eof
    end
    local url = string.format("%s%s/upload?sessionId=%s&fileId=%s&token=%s", base, API, http.urlencode(sessionId), http.urlencode(id), http.urlencode(token))
    current = http.request({ url = url, method = "POST", headers = { ["Content-Type"] = "application/octet-stream" },
                             bodySize = f.size, bodySource = wrapped, connectTimeout = 5000 }, function(res, err)
      if fh then fh:close(); fh = nil end
      current = nil
      if cancelled then return end
      if res and res.status == 200 then
        if f.text then t.sent = t.sent + f.size; f.sent = f.size end
        f.state = "done"
      else
        f.state = "failed"
        log("上传失败", f.name, res and res.status or err)
      end
      progress()
      uploadNext(tokens, i + 1)
    end)
  end

  local function prepare(pin)
    local url = base .. API .. "/prepare-upload" .. (pin and ("?pin=" .. http.urlencode(pin)) or "")
    current = http.postJSON(url, { info = myInfo(true), files = files }, function(status, body, res)
      current = nil
      if cancelled then return end
      if status == 200 and type(body) == "table" and body.sessionId then
        sessionId = body.sessionId
        uploadNext(body.files or {}, 1)
      elseif status == 204 then
        for _, f in pairs(byId) do f.state = "done"; f.sent = f.size end
        t.sent = t.total; progress(); done(true)
      elseif status == 401 then
        if cb.onNeedPin then cb.onNeedPin(function(p) if p then prepare(p) else done(false, "cancelled") end end)
        else done(false, "需要 PIN") end
      elseif status == 403 then done(false, "rejected")
      elseif status == 409 then done(false, "busy")
      elseif status == 429 then done(false, "对方请求太频繁，稍后再试")
      else done(false, status and ("对方返回 " .. status) or (res or "连接失败")) end
    end, 120000)   -- 对方可能要点「接收」，最多等 2 分钟
  end
  prepare(nil)

  return {
    cancel = function()
      if cancelled then return end
      cancelled = true
      if current then current.cancel() end
      if sessionId then
        http.request({ url = base .. API .. "/cancel?sessionId=" .. sessionId, method = "POST", body = "", timeout = 3000 }, function() end)
      end
      done(false, "cancelled")
    end,
  }
end

-- ---------------------------------------------------------------- 启停

M.receiving = true

function M.start(opts)
  for k, v in pairs(opts or {}) do M.config[k] = v end
  M.config.saveDir = M.config.saveDir or defaultSaveDir()
  if M.running then return end
  M.running = true
  -- HTTPS：自签证书（指纹 = 证书哈希）；生成失败 / 平台不支持时退回 http
  local cert, key, fp
  if M.config.https then
    local c, k, f = P.ensureCert()
    if c then cert, key, fp = c, k, f else log("HTTPS 不可用，改用 http：", k) end
  end
  M.config.protocol = cert and "https" or "http"
  P.activeFingerprint = fp
  server = http.Server({
    port = M.config.port,
    tls = cert ~= nil, cert = cert, key = key,
    onRequest = onRequest,
    onListening = function(port) M.listenPort = port; if M.onListen then M.onListen(port) end; log(M.config.protocol:upper() .. " 服务已启动，端口", port, "保存到", M.config.saveDir) end,
    onError = function(msg) log("HTTP 服务出错：", msg); hook("onServerError", msg) end,
  })
  if cert then
    shareServer = http.Server({
      port = (M.config.port or P.PORT) + 1,
      onRequest = onShareRequest,
      onListening = function(port) M.sharePort = port end,
      onError = function(msg) log("分享网页服务出错：", msg) end,
    })
  end
  local ok, err = pcall(startUdp)
  if not ok then log("UDP 启动失败：", err) end
  M.announceNow()
  lx.timer.setTimeout(function() M.scan() end, 2000)
end

function M.stop()
  if not M.running then return end
  M.running = false
  if server then pcall(server.close); server = nil end
  if shareServer then pcall(shareServer.close); shareServer = nil; M.sharePort = nil end
  if udp then pcall(udp.close, udp); udp = nil end
end

--- 改配置后重启（如切换加密）
function M.restart(opts)
  M.stop()
  M.listenPort = nil
  M.start(opts)
end

function M.saveDir() return M.config.saveDir or defaultSaveDir() end

return M
