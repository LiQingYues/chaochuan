-- 导航：桌面左侧导航栏、手机底部标签栏，以及「传输收起后的状态条」（点它回到进度页）。
local lx = require("lx")
local t = require("i18n")
local C = require("theme.colors")
local ui = require("components.ui")
local store = require("core.store")
local View, Text = lx.View, lx.Text

local M = {}

M.TABS = {
  { key = "receive", title = "接收", icon = "receive" },
  { key = "send", title = "发送", icon = "send" },
  { key = "history", title = "记录", icon = "history" },
  { key = "settings", title = "设置", icon = "settings" },
}

local function select(key) store.set({ tab = key, page = false }) end

--- 收起的传输：一句话状态 + 百分比
local function transferSummary(tr)
  local pct = (tr.total and tr.total > 0) and math.floor((tr.sent or 0) * 100 / tr.total) or 0
  local who = tr.peer and tr.peer.alias or ""
  if tr.done then
    if tr.failed then return t("传输失败：%s", tr.error or ""), 100 end
    return (tr.dir == "out") and t("已发给 %s", who) or t("已收到 %s 的文件", who), 100
  end
  if tr.waiting then return t("等待 %s 接收…", who), 0 end
  local queue = (tr.queueTotal and tr.queueTotal > 1) and (" (" .. (tr.queueIndex or 1) .. "/" .. tr.queueTotal .. ")") or ""
  return ((tr.dir == "out") and t("正在发送给 %s", who) or t("正在接收 · 来自 %s", who)) .. queue, pct
end
M.transferSummary = transferSummary

--- 状态条（手机：标签栏上方；桌面：内容区顶部）
M.TransferStrip = lx.component(function(props)
  local tr = store.state.transfer
  if not tr or not tr.hidden or not tr.peer then return nil end
  local text, pct = transferSummary(tr)
  return View { testID = "transfer-strip", onTap = store.showTransfer,
    style = { marginHorizontal = props.desktop and 40 or 12, marginTop = props.desktop and 16 or 0, marginBottom = props.desktop and 0 or 8,
              borderRadius = 14, backgroundColor = C.dark, paddingVertical = 10, paddingHorizontal = 14, gap = 8 },
    View { style = { flexDirection = "row", alignItems = "center", gap = 10 },
      ui.Icon { name = tr.dir == "out" and "send" or "receive", size = 18, color = "#FFFFFF" },
      Text { style = { flex = 1, fontSize = 13, fontWeight = "500", color = "#FFFFFF" }, numberOfLines = 1, text },
      Text { style = { fontSize = 13, color = C.darkPct, fontFamily = ui.MONO }, pct .. "%" },
      ui.Icon { name = "chevronRight", size = 16, color = C.darkMuted } },
    ui.Bar { progress = pct / 100, height = 4, track = C.darkTrack2, color = tr.failed and C.darkMuted or C.darkAccent },
  }
end, "TransferStrip")

M.Sidebar = lx.component(function()
  local s = store.state
  local items = {}
  for _, tab in ipairs(M.TABS) do
    local on = s.tab == tab.key and not s.page
    local badge
    if tab.key == "send" and s.transfer and s.transfer.peer and s.transfer.dir == "out" and not s.transfer.done then
      local pct = math.floor((s.transfer.sent or 0) * 100 / math.max(1, s.transfer.total or 1))
      badge = View { onTap = store.showTransfer, style = { marginLeft = "auto", paddingHorizontal = 8, paddingVertical = 1, borderRadius = 999, backgroundColor = C.brand },
        Text { style = { fontSize = 12, color = C.onBrand }, pct .. "%" } }
    elseif tab.key == "receive" and s.transfer and s.transfer.peer and s.transfer.dir == "in" and not s.transfer.done then
      local pct = math.floor((s.transfer.sent or 0) * 100 / math.max(1, s.transfer.total or 1))
      badge = View { onTap = store.showTransfer, style = { marginLeft = "auto", paddingHorizontal = 8, paddingVertical = 1, borderRadius = 999, backgroundColor = C.okDot },
        Text { style = { fontSize = 12, color = "#FFFFFF" }, pct .. "%" } }
    end
    items[#items + 1] = View { key = tab.key, testID = "nav-" .. tab.key, onTap = function() select(tab.key) end,
      style = { flexDirection = "row", alignItems = "center", gap = 12, height = 44, paddingHorizontal = 14, borderRadius = 10,
                backgroundColor = on and C.brandTint or "transparent" },
      ui.Icon { name = tab.icon, size = 20, color = on and C.brandStrong or C.ink2 },
      Text { style = { fontSize = 15, fontWeight = on and "bold" or "500", color = on and C.brandStrong or C.ink2 }, t(tab.title) },
      badge }
  end
  return View { style = { width = 236, backgroundColor = C.surface, borderRightWidth = 1, borderColor = C.line,
                          paddingTop = lx.device.platform == "macos" and 52 or 28, paddingHorizontal = 16, paddingBottom = 20, gap = 6 },
    View { style = { flexDirection = "row", alignItems = "center", gap = 10, paddingHorizontal = 10, paddingBottom = 26 },
      ui.Logo { size = 38 },
      Text { style = { fontSize = 22, fontWeight = "900", letterSpacing = 1, color = C.ink }, t("超传") } },
    items,
    View { style = { flex = 1 } },
    View { onTap = function() select("receive") end, style = { borderRadius = 14, backgroundColor = C.ground, padding = 14, gap = 6 },
      View { style = { flexDirection = "row", alignItems = "center", gap = 8 },
        View { style = { width = 8, height = 8, borderRadius = 4, backgroundColor = s.online and C.okDot or C.toggleOff } },
        Text { style = { fontSize = 13, fontWeight = "500", color = s.online and C.ok or C.muted }, s.online and t("在线 · 可被发现") or t("接收已关闭") } },
      Text { style = { fontSize = 15, fontWeight = "bold", color = C.ink }, numberOfLines = 1, s.identity.alias },
      Text { style = { fontSize = 12, color = C.muted, fontFamily = ui.MONO }, numberOfLines = 1, s.identity.ips[1] .. " · " .. s.port } },
  }
end, "Sidebar")

M.TabBar = lx.component(function(props)
  local s = store.state
  local items = {}
  for _, tab in ipairs(M.TABS) do
    local on = s.tab == tab.key and not s.page
    items[#items + 1] = View { key = tab.key, testID = "tab-" .. tab.key, onTap = function() select(tab.key) end,
      style = { flex = 1, alignItems = "center", justifyContent = "center", gap = 3, paddingTop = 8 },
      ui.Icon { name = tab.icon, size = 24, color = on and C.brand or C.muted, stroke = on and 2.1 or 1.8 },
      Text { style = { fontSize = 11, fontWeight = on and "bold" or "normal", color = on and C.brand or C.muted }, t(tab.title) } }
  end
  return View { style = { flexDirection = "row", backgroundColor = C.surface, borderTopWidth = 1, borderColor = C.line,
                          paddingBottom = math.max(props.safeBottom or 0, 8), height = 56 + math.max(props.safeBottom or 0, 8) },
    items }
end, "TabBar")

return M
