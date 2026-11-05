-- 记录页（桌面 / 移动共用）：按天分组，搜索 + 全部 / 已发送 / 已接收筛选。
--   桌面每行：打开（文本是复制）、在文件夹中显示、删除记录；手机：点一行打开，长按弹出操作菜单。
local lx = require("lx")
local t = require("i18n")
local C = require("theme.colors")
local ui = require("components.ui")
local store = require("core.store")
local View, Text, ScrollView, TextInput = lx.View, lx.Text, lx.ScrollView, lx.TextInput

local function match(r, s)
  if s.historyFilter == 2 and r.dir ~= "out" then return false end
  if s.historyFilter == 3 and r.dir ~= "in" then return false end
  local q = (s.historyQuery or ""):lower()
  if q ~= "" and not ((r.name or ""):lower():find(q, 1, true) or (r.peer or ""):lower():find(q, 1, true)) then return false end
  return true
end

local function rowMenu(r)
  local actions, items = {}, {}
  if r.text then
    items[#items + 1] = t("复制文本"); actions[#items] = function() store.openHistory(r) end
  else
    items[#items + 1] = t("打开"); actions[#items] = function() store.openHistory(r) end
    if lx.device.platform ~= "ios" and lx.device.platform ~= "android" then
      items[#items + 1] = t("在文件夹中显示"); actions[#items] = function() store.revealHistory(r) end
    end
  end
  items[#items + 1] = t("删除这条记录"); actions[#items] = function() store.deleteHistory(r) end
  lx.dialog.actionSheet(r.name, items, function(i) if i and actions[i] then actions[i]() end end, t("取消"))
end

local function Row(r, idx, desktop, last)
  local out = r.dir == "out"
  return View { key = idx, testID = "history-" .. idx,
    onTap = (not desktop) and function() store.openHistory(r) end or nil,
    onLongPress = function() rowMenu(r) end,
    style = { flexDirection = "row", alignItems = "center", gap = desktop and 14 or 12, paddingVertical = 13, paddingHorizontal = desktop and 18 or 14,
              borderBottomWidth = last and 0 or 1, borderColor = C.divider },
    View { style = { width = 36, height = 36, borderRadius = 18, backgroundColor = out and C.brandTint or C.okTint, alignItems = "center", justifyContent = "center" },
      ui.Icon { name = out and "outgoing" or "incoming", size = 18, color = out and C.brandStrong or C.ok } },
    View { style = { flex = 1, gap = 2 },
      Text { style = { fontSize = 14, fontWeight = "500", color = C.ink }, numberOfLines = 1, r.name },
      Text { style = { fontSize = 12, color = C.muted }, numberOfLines = 1, (out and t("已发送") or t("已接收")) .. " · " .. (r.peer or "") .. " · " .. (r.size or "") } },
    Text { style = { fontSize = 13, color = C.muted, fontFamily = ui.MONO }, r.time },
    desktop and View { style = { flexDirection = "row", gap = 6 },
      ui.Button { title = r.text and t("复制") or t("打开"), height = 32, padX = 12, fontSize = 13, radius = 8, testID = "history-open-" .. idx,
                  onTap = function() store.openHistory(r) end },
      (not r.text) and ui.Button { icon = "folder", height = 32, radius = 8, testID = "history-reveal-" .. idx, onTap = function() store.revealHistory(r) end } or nil,
      ui.Button { icon = "trash", height = 32, radius = 8, testID = "history-delete-" .. idx, onTap = function() store.deleteHistory(r) end } } or nil,
  }
end

return lx.component(function(props)
  local s = store.state
  local desktop = props.desktop
  local groups, order = {}, {}
  for _, r in ipairs(s.history) do
    if match(r, s) then
      if not groups[r.day] then groups[r.day] = {}; order[#order + 1] = r.day end
      table.insert(groups[r.day], r)
    end
  end
  local sections, idx = {}, 0
  for _, day in ipairs(order) do
    local rows = {}
    for i, r in ipairs(groups[day]) do idx = idx + 1; rows[#rows + 1] = Row(r, idx, desktop, i == #groups[day]) end
    sections[#sections + 1] = View { key = day, style = { gap = 8 },
      ui.SectionTitle { text = day },
      View { style = { backgroundColor = C.surface, borderRadius = 16, borderWidth = desktop and 1 or 0, borderColor = C.line, overflow = "hidden" }, rows } }
  end
  if #sections == 0 then
    sections[1] = View { style = { alignItems = "center", paddingVertical = 60, gap = 10 },
      ui.Icon { name = "history", size = 36, color = C.faint },
      Text { style = { fontSize = 14, color = C.muted }, (s.historyQuery or "") ~= "" and t("没有匹配的记录") or t("还没有记录") },
      not store.pref("saveHistory") and Text { style = { fontSize = 12, color = C.muted }, t("「设置 › 接收 › 保存到记录」已关闭") } or nil }
  end

  local search = View { style = { flexDirection = "row", alignItems = "center", gap = 8, height = 38, paddingHorizontal = 12,
                                  width = desktop and 240 or nil, flex = (not desktop) and 1 or nil,
                                  backgroundColor = C.surface, borderWidth = 1, borderColor = C.line, borderRadius = 10 },
    ui.Icon { name = "search", size = 16, color = C.muted },
    TextInput { value = s.historyQuery, placeholder = t("搜索文件名或设备"), placeholderColor = C.muted, fontSize = 14, color = C.ink,
                style = { flex = 1 }, returnKeyType = "search", onChange = function(e) store.set({ historyQuery = e.value }) end } }
  local filter = ui.Segmented { items = { t("全部"), t("已发送"), t("已接收") }, index = s.historyFilter, height = 30,
                                onChange = function(i) store.set({ historyFilter = i }) end }
  local clear = ui.Button { title = desktop and t("清空记录") or nil, icon = (not desktop) and "trash" or nil, height = 38, padX = 14, fontSize = 13, radius = 10,
    testID = "clear-history", disabled = #s.history == 0,
    onTap = function()
      lx.dialog.confirm(t("清空记录"), t("只删除记录，不删除已保存的文件。"), function(ok) if ok then store.clearHistory() end end)
    end }

  if desktop then
    return ScrollView { style = { flex = 1 }, contentStyle = { paddingVertical = 30, paddingHorizontal = 40, gap = 18 },
      View { style = { flexDirection = "row", alignItems = "center", justifyContent = "space-between", gap = 16, flexWrap = "wrap", rowGap = 12 },
        Text { style = { fontSize = 28, fontWeight = "900", color = C.ink }, t("记录") },
        View { style = { flexDirection = "row", alignItems = "center", gap = 10 }, search, filter, clear } },
      sections }
  end
  return View { style = { flex = 1 },
    View { style = { paddingHorizontal = 20, paddingTop = 8, paddingBottom = 8, flexDirection = "row", alignItems = "center", justifyContent = "space-between" },
      Text { style = { fontSize = 22, fontWeight = "900", color = C.ink }, t("记录") },
      filter },
    View { style = { flexDirection = "row", gap = 8, paddingHorizontal = 16, paddingBottom = 8 }, search, clear },
    ScrollView { style = { flex = 1 }, contentStyle = { paddingHorizontal = 16, paddingBottom = 16, gap = 14 }, sections,
      #sections > 0 and #s.history > 0 and Text { style = { fontSize = 12, color = C.muted, textAlign = "center", marginTop = 4 }, t("点一条打开，长按更多操作") } or nil } }
end, "HistoryView")
