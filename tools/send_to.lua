-- 命令行发送（headless --net）：用超传的 LocalSend 核心把文本 / 文件发给某台设备，测试跨平台互传用。
--   LS_TARGET=192.168.31.118 LS_PROTO=http LS_TEXT="你好" tools/send_to.sh
--   LS_TARGET=192.168.31.118 LS_FILE=/path/to/file tools/send_to.sh
local lx = require("lx")
local service = require("core.localsend.service")

local target = os.getenv("LS_TARGET")
local proto = os.getenv("LS_PROTO") or "https"
local text, file = os.getenv("LS_TEXT"), os.getenv("LS_FILE")
local device = { ip = target, port = tonumber(os.getenv("LS_PORT") or "53317"), protocol = proto, alias = target }

local items
if text then
  items = { { text = text } }
else
  local st = lx.fs.stat(file or "")
  if not st then print("找不到文件 " .. tostring(file)); return lx.bridge.call("test", "netDone") end
  items = { { name = lx.fs.basename(file), size = st.size, path = file } }
end

local started = os.time()
local last = -1
print(string.format("发送到 %s://%s:%d …（对方需要点「接收」时请在对方屏幕上操作）", proto, target, device.port))
service.send(device, items, {
  onProgress = function(t)
    local pct = t.total > 0 and math.floor(t.sent * 100 / t.total) or 100
    if pct >= last + 10 then last = pct; print(string.format("  进度 %d%%（%d / %d 字节）", pct, t.sent, t.total)) end
  end,
  onDone = function(ok, reason)
    print(string.format("%s（%s，用时 %d 秒）", ok and "✓ 发送成功" or "✗ 发送失败", tostring(reason or "ok"), os.time() - started))
    lx.bridge.call("test", "netDone")
  end,
})
