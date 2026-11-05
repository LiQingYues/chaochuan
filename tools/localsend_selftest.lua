-- LocalSend 核心自测（真实 socket，本机回环），在 headless 平台的 --net 模式下跑（lx test 不收网络事件）：
--   tools/selftest.sh
-- 场景依次执行，每个场景 done(ok, msg)；全部结束调 test.netDone 提前退出，打印 PASS / FAIL。
local lx = require("lx")

local service = require("core.localsend.service")
local http = require("core.localsend.http")
local P = require("core.localsend.protocol")

local tmp = lx.fs.join(lx.fs.paths.temp, "chaochuan_selftest")
lx.fs.remove(tmp)
lx.fs.mkdir(tmp)

local results, scenarios = {}, {}
local function scenario(name, fn) scenarios[#scenarios + 1] = { name = name, fn = fn } end

local function selfDevice()
  return { ip = "127.0.0.1", port = service.listenPort, protocol = service.config.protocol, alias = "自己", fingerprint = "self" }
end
local function base() return service.config.protocol .. "://127.0.0.1:" .. service.listenPort end

local function reset()
  service.hooks = {}
  service.config.quickSave = "all"
  service.config.requirePin, service.config.pin = false, nil
end

scenario("服务协议符合预期（LS_HTTP=1 时 http，否则 https）", function(done)
  local want = os.getenv("LS_HTTP") == "1" and "http" or "https"
  done(service.config.protocol == want and (want == "http" or P.fingerprint() == P.activeFingerprint),
       "protocol " .. service.config.protocol .. " fp " .. tostring(P.activeFingerprint))
end)

scenario("GET /info 返回本机身份", function(done)
  http.request({ url = base() .. P.API .. "/info" }, function(res, err)
    if not res then return done(false, err) end
    done(res.status == 200 and res.json and res.json.version == "2.1" and res.json.fingerprint == P.fingerprint(),
         "status " .. tostring(res.status) .. " body " .. tostring(res.body))
  end)
end)

scenario("POST /register 加入设备表", function(done)
  http.postJSON(base() .. P.API .. "/register",
    { alias = "对端", version = "2.1", deviceModel = "Test", deviceType = "desktop", fingerprint = "peer-fp", port = 53317, protocol = "http" },
    function(status)
      local d = service.devices["peer-fp"]
      done(status == 200 and d and d.alias == "对端" and d.ip == "127.0.0.1", "status " .. tostring(status))
    end)
end)

scenario("发送两个文件（自动接收，含子目录），内容一致", function(done)
  local a, b = tmp .. "/a.bin", tmp .. "/b.txt"
  local big = string.rep("0123456789abcdef", 4 * 1024 * 1024 / 16 * 5)   -- 20 MB，走多批 drain
  lx.fs.write(a, big)
  lx.fs.write(b, "hello 超传")
  local progressCalls = 0
  service.send(selfDevice(), {
    { name = "a.bin", size = #big, path = a },
    { name = "目录/b.txt", size = #"hello 超传", path = b },
  }, {
    onProgress = function() progressCalls = progressCalls + 1 end,
    onDone = function(ok, reason)
      local gotA = lx.fs.read(tmp .. "/recv/a.bin")
      local gotB = lx.fs.read(tmp .. "/recv/目录/b.txt")
      done(ok and gotA == big and gotB == "hello 超传",
           string.format("ok=%s reason=%s a=%s b=%s progress=%d", tostring(ok), tostring(reason),
             tostring(gotA and #gotA), tostring(gotB), progressCalls))
    end,
  })
end)

scenario("询问用户后拒绝 → 发送方 rejected", function(done)
  service.config.quickSave = "off"
  local asked
  service.hooks.onIncoming = function(req, respond) asked = req; respond(nil) end
  lx.fs.write(tmp .. "/x.txt", "x")
  service.send(selfDevice(), { { name = "x.txt", size = 1, path = tmp .. "/x.txt" } }, {
    onDone = function(ok, reason) done(asked ~= nil and ok == false and reason == "rejected", "reason " .. tostring(reason)) end,
  })
end)

scenario("询问用户后只接收部分文件", function(done)
  service.config.quickSave = "off"
  service.hooks.onIncoming = function(req, respond)
    local ids = {}
    for _, f in ipairs(req.files) do if f.fileName == "keep.txt" then ids[#ids + 1] = f.id end end
    respond(ids)
  end
  lx.fs.write(tmp .. "/keep.txt", "keep")
  lx.fs.write(tmp .. "/skip.txt", "skip")
  service.send(selfDevice(), {
    { name = "keep.txt", size = 4, path = tmp .. "/keep.txt" },
    { name = "skip.txt", size = 4, path = tmp .. "/skip.txt" },
  }, {
    onDone = function(ok, reason)
      done(ok and lx.fs.read(tmp .. "/recv/keep.txt") == "keep" and not lx.fs.exists(tmp .. "/recv/skip.txt"), "reason " .. tostring(reason))
    end,
  })
end)

scenario("需要 PIN：401 后输入正确 PIN 成功", function(done)
  service.config.requirePin, service.config.pin = true, "1234"
  lx.fs.write(tmp .. "/p.txt", "pin")
  local askedPin = false
  service.send(selfDevice(), { { name = "p.txt", size = 3, path = tmp .. "/p.txt" } }, {
    onNeedPin = function(retry) askedPin = true; retry("1234") end,
    onDone = function(ok, reason) done(askedPin and ok and lx.fs.read(tmp .. "/recv/p.txt") == "pin", "reason " .. tostring(reason)) end,
  })
end)

scenario("纯文本消息：接收端展示，回 204", function(done)
  local text
  service.hooks.onText = function(_, s) text = s end
  service.send(selfDevice(), { { text = "你好，LocalSend" } }, {
    onDone = function(ok, reason) done(ok and text == "你好，LocalSend", "text " .. tostring(text) .. " reason " .. tostring(reason)) end,
  })
end)

scenario("重名文件自动改名", function(done)
  lx.fs.write(tmp .. "/dup.txt", "second")
  lx.fs.write(tmp .. "/recv/dup.txt", "first")
  service.send(selfDevice(), { { name = "dup.txt", size = 6, path = tmp .. "/dup.txt" } }, {
    onDone = function(ok)
      done(ok and lx.fs.read(tmp .. "/recv/dup.txt") == "first" and lx.fs.read(tmp .. "/recv/dup (1).txt") == "second", "")
    end,
  })
end)

scenario("链接分享：prepare-download + download", function(done)
  local path = tmp .. "/share.txt"
  lx.fs.write(path, "shared content")
  service.startShare({ { name = "share.txt", size = 14, path = path } }, { autoAccept = true })
  http.postJSON(base() .. P.API .. "/prepare-download", nil, function(status, body)
    if status ~= 200 then return done(false, "prepare " .. tostring(status)) end
    local fileId = next(body.files)
    http.request({ url = base() .. P.API .. "/download?sessionId=" .. body.sessionId .. "&fileId=" .. fileId }, function(res, err)
      service.stopShare()
      done(res and res.status == 200 and res.body == "shared content", "download " .. tostring(res and res.status or err))
    end)
  end)
end)

scenario("链接分享：网页首页可访问", function(done)
  service.startShare({ { name = "share.txt", size = 14, path = tmp .. "/share.txt" } }, {})
  http.request({ url = base() .. "/" }, function(res)
    service.stopShare()
    done(res and res.status == 200 and res.body:find("prepare-download", 1, true) ~= nil, "status " .. tostring(res and res.status))
  end)
end)

scenario("HTTPS 时分享链接走单独的 HTTP 端口（浏览器不报证书警告）", function(done)
  if service.config.protocol ~= "https" then return done(true, "http 模式跳过") end
  local path = tmp .. "/share2.txt"
  lx.fs.write(path, "via http share port")
  service.startShare({ { name = "share2.txt", size = 19, path = path } }, { autoAccept = true })
  local url = service.shareUrl()
  if not url:match("^http://") then service.stopShare(); return done(false, "shareUrl = " .. url) end
  local base2 = "http://127.0.0.1:" .. tostring(service.sharePort)
  http.request({ url = base2 .. "/" }, function(page)
    if not (page and page.status == 200) then service.stopShare(); return done(false, "page " .. tostring(page and page.status)) end
    http.postJSON(base2 .. P.API .. "/prepare-download", nil, function(status, body)
      if status ~= 200 then service.stopShare(); return done(false, "prepare " .. tostring(status)) end
      local fileId = next(body.files)
      http.request({ url = base2 .. P.API .. "/download?sessionId=" .. body.sessionId .. "&fileId=" .. fileId }, function(res)
        service.stopShare()
        done(res and res.status == 200 and res.body == "via http share port", "download " .. tostring(res and res.status))
      end)
    end)
  end)
end)

-- ---------------------------------------------------------------- 执行

local function finish()
  local pass = 0
  for _, r in ipairs(results) do
    print(string.format("%s %s%s", r.ok and "✓" or "✗", r.name, r.ok and "" or ("  — " .. tostring(r.msg))))
    if r.ok then pass = pass + 1 end
  end
  print(string.format("%s  %d/%d 通过", pass == #results and "PASS" or "FAIL", pass, #results))
  service.stop()
  lx.fs.remove(tmp)
  lx.bridge.call("test", "netDone")
end

local idx = 0
local function nextScenario()
  idx = idx + 1
  local s = scenarios[idx]
  if not s then return finish() end
  reset()
  local finished = false
  local ok, err = pcall(s.fn, function(passed, msg)
    if finished then return end
    finished = true
    results[#results + 1] = { name = s.name, ok = passed and true or false, msg = msg }
    nextScenario()
  end)
  if not ok then
    finished = true
    results[#results + 1] = { name = s.name, ok = false, msg = err }
    nextScenario()
  end
end

-- 服务开始监听后（listening 事件，真实网络事件）开始跑场景
service.onListen = function() nextScenario() end
service.start({ port = 0, saveDir = tmp .. "/recv", quickSave = "all", https = os.getenv("LS_HTTP") ~= "1" })
