-- 发送页（桌面 / 移动共用）：选内容（文件 / 文件夹 / 图片视频 / 文本 / 粘贴）→ 已选清单（可逐个删）→ 发给附近设备。
-- 发送模式：单个设备（点设备直接发）/ 多个设备（勾选后一起发，依次传）/ 链接分享（浏览器下载）。
-- 设备行：点星标收藏；桌面可「只看收藏」；手机可「扫码连接」；都可以按 IP 添加。
local lx = require("lx")
local t = require("i18n")
local C = require("theme.colors")
local ui = require("components.ui")
local store = require("core.store")
local View, Text, ScrollView = lx.View, lx.Text, lx.ScrollView

local KINDS = {
  { key = "file", label = "文件", icon = "file" },
  { key = "folder", label = "文件夹", icon = "folder" },
  { key = "media", label = "图片视频", short = "相册", icon = "image" },
  { key = "text", label = "文本", icon = "text" },
  { key = "paste", label = "粘贴剪贴板", short = "粘贴", icon = "paste" },
}
local MODES = { "单个设备", "多个设备", "链接分享" }

local function modeNames() return { t(MODES[1]), t(MODES[2]), t(MODES[3]) } end

local function KindTiles(props)
  local tiles = {}
  for _, k in ipairs(KINDS) do
    tiles[#tiles + 1] = View { key = k.key, testID = "pick-" .. k.key, onTap = function() store.pick(k.key) end,
      style = { flex = 1, height = props.desktop and 92 or 76, borderRadius = props.desktop and 16 or 14, backgroundColor = C.surface,
                borderWidth = props.desktop and 1 or 0, borderColor = C.line, alignItems = "center", justifyContent = "center", gap = props.desktop and 8 or 6 },
      ui.IconTile { name = k.icon, size = props.desktop and 38 or 34, iconSize = props.desktop and 20 or 18 },
      Text { style = { fontSize = props.desktop and 14 or 12, fontWeight = "500", color = C.ink }, numberOfLines = 1,
             props.desktop and t(k.label) or t(k.short or k.label) } }
  end
  return View { style = { flexDirection = "row", gap = props.desktop and 12 or 8 }, tiles }
end

local function Selection(props)
  local s = store.state
  local n = #s.selection
  local items = {}
  local maxShown = props.desktop and 8 or 20
  for i, f in ipairs(s.selection) do
    if i > maxShown then break end
    items[#items + 1] = ui.SelectionChip { key = (f.path or f.text or "") .. i, item = f, compact = not props.desktop,
      sizeText = f.text and t("文本") or store.formatSize(f.size), testID = "remove-" .. i,
      onRemove = function() store.removeSelection(i) end }
  end
  local extra = n > maxShown and Text { style = { fontSize = 13, color = C.muted, alignSelf = "center" }, t("还有 %d 项", n - maxShown) } or nil
  local body
  if n == 0 then
    body = Text { style = { fontSize = 13, color = C.muted }, props.desktop and t("还没选内容：点上面的入口，或者把文件 / 文件夹拖进窗口") or t("还没选内容：点上面的入口，或在别的 App 里分享到超传") }
  elseif props.desktop then
    local rows = {}
    for i = 1, #items, 2 do
      rows[#rows + 1] = View { key = i, style = { flexDirection = "row", gap = 10 }, items[i], items[i + 1] or View { style = { flex = 1 } } }
    end
    body = View { style = { gap = 10 }, rows, extra }
  else
    items[#items + 1] = View { key = "add", onTap = function() store.pick("file") end,
      style = { width = 58, height = 58, borderRadius = 10, borderWidth = 1.5, borderColor = C.dashed, alignItems = "center", justifyContent = "center" },
      ui.Icon { name = "plus", size = 20, color = C.muted } }
    body = ScrollView { horizontal = true, showsIndicator = false, contentStyle = { flexDirection = "row", gap = 10, paddingTop = 6, paddingRight = 6 }, items }
  end
  return ui.Card { border = props.desktop, padding = props.desktop and 16 or 14, gap = props.desktop and 12 or 10,
    View { style = { flexDirection = "row", justifyContent = "space-between", alignItems = "center" },
      View { style = { flexDirection = "row", alignItems = "baseline", gap = 6 },
        Text { testID = "selection-count", style = { fontSize = props.desktop and 15 or 14, fontWeight = "bold", color = C.ink }, t("已选 %d 项", n) },
        Text { style = { fontSize = 13, color = C.muted }, "· " .. store.formatSize(store.selectionTotal()) } },
      n > 0 and ui.Button { title = t("清空"), kind = props.desktop and "outline" or "soft", height = 32, padX = 12, fontSize = 13, radius = 8,
                            testID = "clear-selection", onTap = store.clearSelection } or nil },
    body,
  }
end

local function addByIp()
  lx.dialog.prompt(t("按 IP 添加设备"), t("输入对方的 IP（如 192.168.1.5）、IP:端口 或 #尾号"), function(value)
    if value and value ~= "" then store.addByAddress(value) end
  end, { placeholder = "192.168.1.5" })
end

local function Devices(props)
  local s = store.state
  local multi = s.sendMode == 2
  local rows = {}
  for _, d in ipairs(store.visibleDevices()) do
    rows[#rows + 1] = ui.DeviceRow { key = d.id, device = d, icon = store.deviceIcon(d), compact = not props.desktop,
      checkable = multi, checked = multi and s.multiTargets[d.id] == true,
      style = props.desktop and { width = "48.9%" } or nil,
      onTap = function() store.sendTo(d) end,
      onFavorite = function() store.toggleFavorite(d.id) end }
  end
  local btns
  if props.desktop then
    btns = {
      ui.Button { key = "scan", icon = "refresh", title = s.scanning and t("搜索中…") or t("扫描网络"), height = 34, padX = 12, fontSize = 13, radius = 9,
                  testID = "rescan", onTap = store.rescan },
      ui.Button { key = "ip", icon = "plus", title = t("按 IP 添加"), height = 34, padX = 12, fontSize = 13, radius = 9, testID = "add-ip", onTap = addByIp },
      ui.Button { key = "fav", icon = "star", iconFill = s.onlyFavorites, title = s.onlyFavorites and t("全部设备") or t("只看收藏"),
                  kind = s.onlyFavorites and "soft" or "outline", height = 34, padX = 12, fontSize = 13, radius = 9, testID = "only-fav",
                  onTap = store.toggleOnlyFavorites },
    }
  else
    btns = {
      ui.Button { key = "scan", icon = "refresh", height = 40, radius = 11, iconSize = 18, testID = "rescan", onTap = store.rescan },
      ui.Button { key = "ip", icon = "plus", height = 40, radius = 11, iconSize = 18, testID = "add-ip", onTap = addByIp },
      ui.Button { key = "qr", icon = "scan", height = 40, radius = 11, iconSize = 18, testID = "scan-qr", onTap = store.scanToConnect },
    }
  end
  local empty = View { style = { alignItems = "center", paddingVertical = 36, paddingHorizontal = 16, gap = 8, backgroundColor = C.surface, borderRadius = 16 },
    ui.Icon { name = "wifi", size = 28, color = C.faint },
    Text { style = { fontSize = 14, color = C.muted }, s.onlyFavorites and t("没有在线的收藏设备") or (s.scanning and t("正在寻找附近的设备…") or t("附近没有设备")) },
    Text { style = { fontSize = 12, color = C.muted, textAlign = "center" }, t("对方打开超传或 LocalSend、连同一个 Wi‑Fi 即可；找不到可以按 IP 添加") } }
  return View { style = { gap = props.desktop and 12 or 8 },
    View { style = { flexDirection = "row", justifyContent = "space-between", alignItems = "center", gap = 8 },
      View { style = { flexDirection = "row", alignItems = "center", gap = 10, flexShrink = 1 },
        Text { style = { fontSize = props.desktop and 17 or 15, fontWeight = "bold", color = C.ink, marginLeft = props.desktop and 0 or 4 }, t("附近设备") },
        s.scanning and ui.Pill { text = t("正在搜索"), tone = "brand", dot = true } or nil },
      View { style = { flexDirection = "row", gap = props.desktop and 8 or 6 }, btns } },
    multi and Text { style = { fontSize = 12, color = C.muted, marginLeft = 4 }, t("点设备勾选，再点下面的按钮依次发送") } or nil,
    #rows == 0 and empty
      or View { style = props.desktop and { flexDirection = "row", flexWrap = "wrap", justifyContent = "space-between", rowGap = 12 } or { gap = 8 }, rows },
    multi and ui.Button { kind = "primary", icon = "send", height = 48, radius = 14, fontSize = 15, testID = "send-multi",
      title = store.multiTargetCount() > 0 and t("发送给 %d 台设备", store.multiTargetCount()) or t("先勾选设备"),
      disabled = store.multiTargetCount() == 0 or #s.selection == 0, onTap = store.sendToSelected } or nil,
  }
end

return lx.component(function(props)
  local s = store.state
  local desktop = props.desktop
  local header
  if desktop then
    header = View { style = { flexDirection = "row", alignItems = "flex-end", justifyContent = "space-between", gap = 24, flexWrap = "wrap", rowGap = 12 },
      View { style = { gap = 4, flexShrink = 1 },
        Text { style = { fontSize = 28, fontWeight = "900", color = C.ink }, t("发送") },
        Text { style = { fontSize = 14, color = C.muted }, t("选好内容，点一下附近的设备就发出去了。也可以直接把文件拖进窗口。") } },
      ui.Segmented { items = modeNames(), index = s.sendMode, testID = "mode", onChange = function(i) store.set({ sendMode = i }) end } }
  else
    header = View { style = { paddingHorizontal = 20, paddingTop = 8, paddingBottom = 8, flexDirection = "row", alignItems = "center", justifyContent = "space-between" },
      Text { style = { fontSize = 22, fontWeight = "900", color = C.ink }, t("发送") },
      View { testID = "mode", onTap = function()
          lx.dialog.actionSheet(t("发送模式"), modeNames(), function(i) if i then store.set({ sendMode = i }) end end, t("取消"))
        end,
        style = { height = 36, paddingHorizontal = 12, borderRadius = 10, backgroundColor = C.surface, flexDirection = "row", alignItems = "center", gap = 4 },
        Text { style = { fontSize = 13, fontWeight = "500", color = C.ink }, modeNames()[s.sendMode] },
        ui.Icon { name = "chevronDown", size = 14, color = C.ink } } }
  end
  local body = {
    KindTiles { desktop = desktop },
    Selection { desktop = desktop },
    s.sendMode == 3
      and ui.Card { border = desktop, gap = 10,
            Text { style = { fontSize = 15, fontWeight = "bold", color = C.ink }, t("通过链接分享") },
            Text { style = { fontSize = 13, color = C.muted, lineHeight = 20 }, t("生成一个网址，同一网络下的任何设备用浏览器打开就能下载，不用装超传。可以设 PIN，每个访问请求都要你同意。") },
            ui.Button { kind = "primary", icon = "link", title = t("生成分享链接"), height = 48, radius = 14, fontSize = 15, testID = "start-share",
                        disabled = #s.selection == 0, onTap = store.startShareLink } }
      or Devices { desktop = desktop },
  }
  if desktop then
    return ScrollView { style = { flex = 1 }, contentStyle = { paddingVertical = 30, paddingHorizontal = 40, gap = 22 }, header, body }
  end
  return View { style = { flex = 1 }, header,
    ScrollView { style = { flex = 1 }, contentStyle = { paddingHorizontal = 16, paddingTop = 6, paddingBottom = 16, gap = 14 }, body } }
end, "SendView")
