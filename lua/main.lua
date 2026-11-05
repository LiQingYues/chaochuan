-- 入口：超传（局域网传输，兼容 LocalSend 协议 v2.1）。桌面 / 移动共用一套代码，主框架见 modules/main/main_page.lua。
local lx = require("lx")

---@class App: lx.App
local App = lx.class("ChaochuanApp", lx.App)
App.home = require("modules.main.main_page")

function App:onLaunch()
  lx.log("超传 启动，lx 版本", lx.version, "平台", lx.device.platform)
  pcall(lx.linking.config, { prefixes = { "chaochuan://" } })
  -- LocalSend 服务：HTTP 53317 + UDP 组播发现
  local ok, err = pcall(require("core.store").start)
  if not ok then lx.log.error("启动传输服务失败：" .. tostring(err)) end
end

lx.run(App)
