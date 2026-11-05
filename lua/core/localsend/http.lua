-- 极简 HTTP/1.1（LocalSend 用）：建在 lx.TcpServer / lx.TcpSocket 上，请求 / 响应体都可以流式处理（大文件不进内存）。
--
--   服务端：local srv = http.Server { port = 53317, tls = false, onRequest = function(req, res) ... end }
--     req.method / path / query（已解码）/ headers（小写键）/ ip / contentLength
--     处理函数在「头部收齐」时调用；想流式收请求体就设 req.onData = fn(chunk)，请求体收完调 req.onEnd(body?)
--     （没设 onData 时请求体缓存起来，onEnd 收到完整字符串）。
--     res:send(status, body, headers) / res:json(status, value) / res:sendFile(path, size, contentType, name)
--   客户端：http.request({ url, method, headers, body | bodySize + bodySource, timeout }, function(res, err) end)
--     res = { status, headers, body }；bodySource(write, done)：分批调用 write(chunk) 返回 false 时等待 drain，再次被调用继续写
local lx = require("lx")
local json = require("lx.json.json")

local M = {}

local REASONS = { [200] = "OK", [204] = "No Content", [400] = "Bad Request", [401] = "Unauthorized", [403] = "Forbidden",
                  [404] = "Not Found", [409] = "Conflict", [429] = "Too Many Requests", [500] = "Internal Server Error" }

local function urldecode(s)
  s = s:gsub("+", " ")
  return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

function M.urlencode(s)
  return (tostring(s):gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end))
end

local function parseQuery(qs)
  local q = {}
  for pair in (qs or ""):gmatch("[^&]+") do
    local k, v = pair:match("^([^=]*)=?(.*)$")
    if k and k ~= "" then q[urldecode(k)] = urldecode(v or "") end
  end
  return q
end
M.parseQuery = parseQuery

local function parseHead(head)
  local lines = {}
  for line in head:gmatch("([^\r\n]*)\r\n") do lines[#lines + 1] = line end
  local first = table.remove(lines, 1) or ""
  local headers = {}
  for _, line in ipairs(lines) do
    local k, v = line:match("^([^:]+):%s*(.*)$")
    if k then headers[k:lower()] = v end
  end
  return first, headers
end

-- ---------------------------------------------------------------- 消息体解析（Content-Length / chunked / 读到关闭）

--- 增量解析器：feed(data)；onHead(first, headers) 返回 bodyMode（"length" n / "chunked" / "close" / "none"）
local function Parser(handlers)
  local p = { buf = "", phase = "head" }
  local remaining, chunkLeft = 0, nil

  local function finishMessage()
    p.phase = "head"
    handlers.onEnd()
  end

  function p.feed(data)
    p.buf = p.buf .. data
    while true do
      if p.phase == "head" then
        local e = p.buf:find("\r\n\r\n", 1, true)
        if not e then
          if #p.buf > 64 * 1024 then handlers.onError("请求头过大") end
          return
        end
        local head = p.buf:sub(1, e + 3)
        p.buf = p.buf:sub(e + 4)
        local first, headers = parseHead(head)
        local mode, n = handlers.onHead(first, headers)
        if mode == "length" and n > 0 then p.phase = "length"; remaining = n
        elseif mode == "chunked" then p.phase = "chunked"; chunkLeft = nil
        elseif mode == "close" then p.phase = "close"
        else finishMessage() end
      elseif p.phase == "length" then
        if #p.buf == 0 then return end
        local take = math.min(remaining, #p.buf)
        local chunk = (take == #p.buf) and p.buf or p.buf:sub(1, take)
        p.buf = (take == #p.buf) and "" or p.buf:sub(take + 1)
        remaining = remaining - take
        handlers.onData(chunk)
        if remaining == 0 then finishMessage() end
      elseif p.phase == "chunked" then
        -- chunkLeft：nil = 等块大小行；> 0 = 块数据剩余；0 = 等块尾 CRLF；-1 = 等结尾空行（不支持 trailer 字段）
        if chunkLeft == nil then
          local e = p.buf:find("\r\n", 1, true)
          if not e then return end
          local size = tonumber((p.buf:sub(1, e - 1):match("^%x+")), 16) or 0
          p.buf = p.buf:sub(e + 2)
          chunkLeft = (size == 0) and -1 or size
        elseif chunkLeft == -1 then
          if #p.buf < 2 then return end
          p.buf = p.buf:sub(3); chunkLeft = nil
          finishMessage()
        elseif chunkLeft == 0 then
          if #p.buf < 2 then return end
          p.buf = p.buf:sub(3); chunkLeft = nil
        else
          if #p.buf == 0 then return end
          local take = math.min(chunkLeft, #p.buf)
          handlers.onData(p.buf:sub(1, take))
          p.buf = p.buf:sub(take + 1)
          chunkLeft = chunkLeft - take
        end
      elseif p.phase == "close" then
        if #p.buf > 0 then handlers.onData(p.buf); p.buf = "" end
        return
      else
        return
      end
    end
  end

  function p.closed()
    if p.phase == "close" then finishMessage() end
  end

  return p
end

local function bodyMode(headers)
  local te = (headers["transfer-encoding"] or ""):lower()
  if te:find("chunked", 1, true) then return "chunked" end
  local n = tonumber(headers["content-length"])
  if n then return "length", math.floor(n) end
  return nil
end

-- ---------------------------------------------------------------- 服务端

local function headerBlock(status, headers)
  local out = { string.format("HTTP/1.1 %d %s\r\n", status, REASONS[status] or "OK") }
  for k, v in pairs(headers) do out[#out + 1] = k .. ": " .. tostring(v) .. "\r\n" end
  out[#out + 1] = "\r\n"
  return table.concat(out)
end

local function Response(conn, onDone)
  local res = { sent = false }
  function res.send(_, status, body, headers)
    if res.sent or not conn.connected then return end
    res.sent = true
    body = body or ""
    headers = headers or {}
    headers["Content-Length"] = #body
    headers["Connection"] = headers["Connection"] or "keep-alive"
    conn:send(headerBlock(status, headers) .. body)
    onDone()
  end
  function res.json(self, status, value)
    self:send(status, json.encode(value), { ["Content-Type"] = "application/json; charset=utf-8" })
  end
  function res.sendFile(_, path, size, contentType, name)
    if res.sent or not conn.connected then return end
    res.sent = true
    local headers = { ["Content-Length"] = size, ["Content-Type"] = contentType or "application/octet-stream", ["Connection"] = "close" }
    if name then headers["Content-Disposition"] = "attachment; filename*=UTF-8''" .. M.urlencode(name) end
    conn:send(headerBlock(200, headers))
    conn:sendFile(path, 0, size)
    onDone()
  end
  return res
end

--- opts: port, tls, cert, key, onRequest(req, res), onListening(port), onError(msg)
function M.Server(opts)
  local srv = { conns = {} }
  local server = lx.TcpServer({ port = opts.port or 0, tls = opts.tls, cert = opts.cert, key = opts.key })
  srv.socket = server

  server:on("listening", function(port) srv.port = port; if opts.onListening then opts.onListening(port) end end)
  server:on("error", function(msg) if opts.onError then opts.onError(msg) end end)
  server:on("connection", function(conn)
    local ip = (conn.peer or ""):match("^%[?([^%]]+)%]?:%d+$") or conn.peer
    local state = {}
    local parser
    parser = Parser({
      onHead = function(first, headers)
        local method, target = first:match("^(%u+)%s+(%S+)")
        local path, qs = (target or "/"):match("^([^?]*)%??(.*)$")
        local req = { method = method or "GET", path = path, query = parseQuery(qs), headers = headers, ip = ip, conn = conn }
        local mode, n = bodyMode(headers)
        req.contentLength = n
        local parts = {}
        state.req, state.parts = req, parts
        state.res = Response(conn, function() end)
        local ok, err = pcall(opts.onRequest, req, state.res)
        if not ok then
          lx.log.error("[http] 处理请求出错：" .. tostring(err))
          state.res:send(500, "internal error")
        end
        if mode == "length" then return "length", n end
        if mode == "chunked" then return "chunked" end
        return "none"
      end,
      onData = function(chunk)
        local req = state.req
        if req.onData then req.onData(chunk) else table.insert(state.parts, chunk) end
      end,
      onEnd = function()
        local req = state.req
        if req and req.onEnd then
          local ok, err = pcall(req.onEnd, (not req.onData) and table.concat(state.parts) or nil)
          if not ok then
            lx.log.error("[http] 处理请求体出错：" .. tostring(err))
            state.res:send(500, "internal error")
          end
        end
      end,
      onError = function(msg) conn:close() end,
    })
    srv.conns[conn] = state
    state.parser = parser
  end)
  server:on("message", function(conn, data)
    local st = srv.conns[conn]
    if st then st.parser.feed(data) end
  end)
  server:on("drain", function(conn)
    local st = srv.conns[conn]
    if st and st.req and st.req.onDrain then st.req.onDrain() end
  end)
  server:on("disconnect", function(conn)
    local st = srv.conns[conn]
    srv.conns[conn] = nil
    if st and st.req and st.req.onAbort and not (st.res and st.res.sent) then pcall(st.req.onAbort) end
  end)

  function srv.close() server:close() end
  return srv
end

-- ---------------------------------------------------------------- 客户端

local socketMod = require("lx.net.socket")

--- req: url, method, headers, body（字符串）| bodySize + bodySource(write, done), timeout（毫秒，连上前 + 等响应）
--- cb(res, err)；返回句柄 { cancel = fn }
function M.request(req, cb)
  local scheme, host, port, target = req.url:match("^(https?)://([^/:]+):?(%d*)(.*)$")
  if not scheme then cb(nil, "无效地址 " .. tostring(req.url)); return { cancel = function() end } end
  port = tonumber(port) or (scheme == "https" and 443 or 80)
  if target == "" then target = "/" end

  local done = false
  local sock
  local timer
  local function finish(res, err)
    if done then return end
    done = true
    if timer then lx.timer.clearTimeout(timer) end
    if sock then pcall(sock.close, sock) end
    cb(res, err)
  end

  sock = lx.TcpSocket(host, port, { tls = scheme == "https", verify = false, connectTimeout = req.connectTimeout or req.timeout or 5000 })
  local res = { headers = {} }
  local parts = {}
  local parser = Parser({
    onHead = function(first, headers)
      res.status = tonumber(first:match("^HTTP/%d%.%d%s+(%d+)")) or 0
      res.headers = headers
      local mode, n = bodyMode(headers)
      if mode == "length" then return "length", n end
      if mode == "chunked" then return "chunked" end
      if res.status == 204 or res.status == 304 or req.method == "HEAD" then return "none" end
      return "close"
    end,
    onData = function(chunk) parts[#parts + 1] = chunk end,
    onEnd = function()
      res.body = table.concat(parts)
      local ct = res.headers["content-type"] or ""
      if ct:find("json", 1, true) and #res.body > 0 then res.json = json.tryDecode(res.body) end
      finish(res)
    end,
    onError = function(msg) finish(nil, msg) end,
  })

  local headers = { ["Host"] = host .. ":" .. port, ["Connection"] = "close", ["User-Agent"] = "chaochuan" }
  for k, v in pairs(req.headers or {}) do headers[k] = v end
  local body = req.body
  if body ~= nil then headers["Content-Length"] = #body
  elseif req.bodySize then headers["Content-Length"] = req.bodySize end
  local head = { (req.method or "GET") .. " " .. target .. " HTTP/1.1\r\n" }
  for k, v in pairs(headers) do head[#head + 1] = k .. ": " .. tostring(v) .. "\r\n" end
  head[#head + 1] = "\r\n"

  -- 流式上传（流控）：libhv 一条连接的发送队列超过 16 MB 会直接断开连接，所以必须限住「在途」数据量。
  --   · 每批读满 BATCH 字节拼成「一次」send：原生每清空一次发送队列发一个 drain，一批一次 send 才对得上一个 drain
  --     （以前每 256 KB 一次 send，一批 16 个 drain，每个 drain 又发一批，队列指数增长，几百 MB 后被 libhv 断开）
  --   · inFlight：发出一批后等它的 drain 再发下一批；请求头那次 send 的 drain 可能晚到，最多同时两批在途（< 16 MB）
  --   · 旧原生库没有客户端 drain：按定时器限速（每 20 ms 一批 512 KB，约 25 MB/s）
  local pump
  if req.bodySource then
    local clientDrain = socketMod.supportsClientDrain
    local BATCH = clientDrain and (2 * 1024 * 1024) or (512 * 1024)
    local inFlight = false
    pump = function()
      if done or inFlight then return end
      local parts, n, finished = {}, 0, false
      while n < BATCH do
        local chunk, eof = req.bodySource()
        if chunk and #chunk > 0 then parts[#parts + 1] = chunk; n = n + #chunk end
        if eof then finished = true; break end
        if not chunk then break end
      end
      if n > 0 then
        sock:send(#parts == 1 and parts[1] or table.concat(parts))
        inFlight = clientDrain
      end
      if finished then pump = nil; return end
      if not clientDrain then lx.timer.setTimeout(function() if pump then pump() end end, 20) end
    end
    sock:on("drain", function()
      inFlight = false
      if pump then pump() end
    end)
  end

  sock:on("open", function()
    sock:send(table.concat(head) .. (body or ""))
    if pump then pump() end
  end)
  sock:on("message", function(data) parser.feed(data) end)
  sock:on("close", function(err)
    if done then return end
    if parser.closed then parser.closed() end
    if not done then finish(res.status and res or nil, err or "连接已关闭") end
  end)
  sock:on("error", function(msg) if not res.status then finish(nil, msg) end end)

  if req.timeout then
    timer = lx.timer.setTimeout(function() finish(nil, "超时") end, req.timeout)
  end
  return { cancel = function() finish(nil, "已取消") end, socket = sock }
end

--- JSON 便捷：post(url, value, cb(status, json, res))
function M.postJSON(url, value, cb, timeout)
  return M.request({ url = url, method = "POST", headers = { ["Content-Type"] = "application/json" },
                     body = value ~= nil and json.encode(value) or "", timeout = timeout or 8000 }, function(res, err)
    if not res then return cb(nil, nil, err) end
    cb(res.status, res.json, res)
  end)
end

return M
