-- 命令行接收端（headless --net）：起一个自动接收的 LocalSend 服务，测大文件 / 跨设备用。
--   LS_PORT=53400 LS_DIR=/tmp/recv tools/recv_server.sh        （LS_HTTP=1 用 http；默认 https）
-- 每秒打印一次接收进度；会话结束打印结果。
local lx = require("lx")
local service = require("core.localsend.service")

local port = tonumber(os.getenv("LS_PORT") or "53400")
local dir = os.getenv("LS_DIR") or lx.fs.join(lx.fs.paths.temp, "recv")
local lastPrint, lastBytes, lastT = 0, 0, os.time()

service.hooks = {
  onReceiveStart = function(s) print(string.format("开始接收：%d 个文件，共 %d 字节，来自 %s", #s.order, s.total, s.peer.alias or "?")) end,
  onReceiveProgress = function(s)
    local now = os.time()
    if now ~= lastPrint then
      lastPrint = now
      print(string.format("  %3d%%  %d / %d  %.1f MB/s", math.floor(s.received * 100 / math.max(1, s.total)), s.received, s.total,
        (s.received - lastBytes) / 1e6 / math.max(1, now - lastT)))
      lastBytes, lastT = s.received, now
    end
  end,
  onReceiveDone = function(s, ok, err)
    print(string.format("%s：收到 %d / %d 字节%s", ok and "✓ 接收完成" or "✗ 接收中断", s.received, s.total, err and ("（" .. err .. "）") or ""))
    for _, id in ipairs(s.order) do local f = s.files[id]; print("    " .. f.fileName .. "  " .. f.state .. "  " .. f.received .. "/" .. f.size) end
  end,
  onLog = function(text) print("[log] " .. text) end,
}
service.onListen = function(p) print("接收服务已启动，端口 " .. p .. "，保存到 " .. dir) end
service.start({ port = port, saveDir = dir, quickSave = "all", https = os.getenv("LS_HTTP") ~= "1" })
