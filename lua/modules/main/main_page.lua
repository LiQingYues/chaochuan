-- 主框架（桌面 / 移动共用一个页面）：
--   桌面（macOS / Windows）：左侧导航栏 + 内容区；传输进度替换内容区；接收请求是居中弹窗。
--   手机（iOS / Android）：内容区 + 底部标签栏；传输进度、链接分享、设置子页面整屏盖上；接收请求从底部弹出。
-- 传输进度收起后，内容区上方（桌面）/ 标签栏上方（手机）显示状态条，点它回到进度页。
-- 内容都来自 modules/* 的同一套视图，只按 desktop 参数调整排版。状态在 core/store，变化时整页重渲染（diff 后只下发变化）。
local lx = require("lx")
local C = require("theme.colors")
local layout = require("theme.layout")
local store = require("core.store")
local nav = require("modules.main.views.nav")
local ReceiveView = require("modules.receive.receive_view")
local Incoming = require("modules.receive.incoming_view")
local SendView = require("modules.send.send_view")
local ProgressView = require("modules.transfer.progress_view")
local HistoryView = require("modules.history.history_view")
local Setting = require("modules.setting.setting_view")
local Pages = require("modules.setting.pages")
local ShareLinkView = require("modules.share_link.share_link_view")
local View = lx.View

---@class MainPage: lx.Page
local MainPage = lx.class("MainPage", lx.Page)
MainPage.options = { navigationBarHidden = true, edgeToEdge = true, swipeBack = false, statusBarStyle = "dark" }

function MainPage:onCreate()
  self.state = { rev = 0 }
  local function rerender() if not self.destroyed then self:setState({ rev = self.state.rev + 1 }) end end
  self.offs = { lx.events.on("store.changed", rerender) }
  local ok, off = pcall(lx.screen.on, "safeArea", rerender)
  if ok and off then self.offs[#self.offs + 1] = off end
  -- 跟随系统深浅色
  local ok2, off2 = pcall(lx.screen.on, "appearance", function() store.onSystemAppearance() end)
  if ok2 and off2 then self.offs[#self.offs + 1] = off2 end
  if not layout.isDesktop() then
    -- iOS 冷启动首帧安全区读到 0：每帧看一眼，取到非 0 就重渲染一次（最多 2 秒）
    local frames, stop = 0, nil
    stop = lx.timer.onFrame(function()
      frames = frames + 1
      local okSafe, sa = pcall(lx.screen.safeArea)
      if (okSafe and sa and (sa.top or 0) > 0) or frames > 120 then
        stop(); rerender()
      end
    end)
  end
end

function MainPage:onDestroy()
  self.destroyed = true
  for _, off in ipairs(self.offs or {}) do off() end
end

local function content(tab, desktop)
  if tab == "receive" then return ReceiveView { desktop = desktop } end
  if tab == "send" then return SendView { desktop = desktop } end
  if tab == "history" then return HistoryView { desktop = desktop } end
  return Setting.View { desktop = desktop }
end

function MainPage:render()
  local s = store.state
  local desktop = layout.isDesktop()
  local tr = s.transfer
  local showProgress = tr and tr.peer and not tr.hidden
  -- 状态栏：深色进度页 / 深色主题用浅色字
  local barStyle = ((showProgress and not desktop) or C.isDark) and "light" or "dark"
  if self.barStyle ~= barStyle then
    self.barStyle = barStyle
    pcall(self.setStatusBarStyle, self, barStyle)
  end
  if desktop then
    local main = showProgress and ProgressView { desktop = true } or content(s.tab, true)
    return View { style = { flex = 1, flexDirection = "row", backgroundColor = C.ground },
      nav.Sidebar {},
      View { style = { flex = 1 },
        (not showProgress) and nav.TransferStrip { desktop = true } or nil,
        View { style = { flex = 1 }, main },
        Pages.View { desktop = true },
        ShareLinkView { desktop = true } },
      Incoming.Dialog { desktop = true },
      Incoming.TextToast { desktop = true },
    }
  end
  local ok, safe = pcall(lx.screen.safeArea)
  safe = ok and safe or { top = 0, bottom = 0 }
  return View { style = { flex = 1, backgroundColor = C.ground },
    View { style = { flex = 1, paddingTop = safe.top }, content(s.tab, false) },
    nav.TransferStrip {},
    nav.TabBar { safeBottom = safe.bottom },
    Pages.View { safeTop = safe.top, safeBottom = safe.bottom },
    ProgressView { safeTop = safe.top, safeBottom = safe.bottom },
    ShareLinkView { safeTop = safe.top, safeBottom = safe.bottom },
    Incoming.Dialog { safeBottom = safe.bottom },
    Incoming.TextToast { safeTop = safe.top },
  }
end

return MainPage
