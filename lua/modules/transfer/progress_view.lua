-- 传输进度（发送 / 接收共用，桌面 / 移动共用）：总进度（百分比、速度、已传 / 总量、剩余时间）+ 每个文件的状态。
-- 左上角返回 = 收起（传输继续，导航栏 / 标签栏上方显示状态条，点它回来）；底部按钮 = 取消 / 完成。
-- 多设备发送显示「第 i / n 台」；失败显示原因；接收完成可以打开所在文件夹。
local lx = require("lx")
local t = require("i18n")
local C = require("theme.colors")
local ui = require("components.ui")
local store = require("core.store")
local View, Text, ScrollView = lx.View, lx.Text, lx.ScrollView
local MONO = ui.MONO

local function stats(tr)
  local pct = (tr.total or 0) > 0 and math.floor(tr.sent * 100 / tr.total) or (tr.done and 100 or 0)
  local remain = ((tr.speed or 0) > 0) and math.ceil((tr.total - tr.sent) / tr.speed) or 0
  return math.min(100, pct), remain
end

local function remainText(sec)
  if sec >= 3600 then return t("约 %d 小时", math.floor(sec / 3600)) end
  if sec >= 60 then return t("约 %d 分钟", math.ceil(sec / 60)) end
  return t("约 %d 秒", sec)
end

local function fileState(f)
  if f.state == "failed" then return t("失败"), C.brandStrong, C.brandLine, 1 end
  if f.state == "skipped" then return t("对方没接收"), C.muted, C.dashed, 0 end
  if (f.size or 0) == 0 and f.state == "done" then return t("已完成"), C.ok, C.okDot, 1 end
  if (f.size or 0) > 0 and (f.sent or 0) >= f.size then return t("已完成"), C.ok, C.okDot, 1 end
  if (f.sent or 0) > 0 then
    local p = f.sent / f.size
    return string.format("%d%%", math.floor(p * 100)), C.brandStrong, C.brand, p
  end
  return t("排队中"), C.muted, C.dashed, 0
end

local function FileRows(tr, compact)
  local rows = {}
  for i, f in ipairs(tr.files or {}) do
    local label, color, bar, p = fileState(f)
    rows[#rows + 1] = View { key = i,
      style = { flexDirection = "row", alignItems = "center", gap = compact and 12 or 14, minHeight = compact and 58 or 72,
                paddingHorizontal = compact and 0 or 20, borderBottomWidth = 1, borderColor = C.divider },
      ui.FileBadge { ext = f.ext, tint = f.tint, size = compact and 34 or 40 },
      View { style = { flex = 1, gap = compact and 6 or 8 },
        View { style = { flexDirection = "row", justifyContent = "space-between", gap = 8 },
          Text { style = { fontSize = compact and 13 or 14, fontWeight = "500", color = C.ink, flexShrink = 1 }, numberOfLines = 1, f.name },
          Text { style = { fontSize = compact and 12 or 13, fontWeight = "500", color = color }, label } },
        ui.Bar { progress = p, color = bar, height = compact and 4 or 6 } },
      not compact and Text { style = { width = 80, textAlign = "right", fontSize = 13, color = C.muted, fontFamily = MONO }, store.formatSize(f.size) } or nil,
    }
  end
  return rows
end

local function Stat(label, value, dark)
  return View { style = { flex = 1, gap = 2, alignItems = dark and "center" or "flex-start" },
    Text { style = { fontSize = dark and 11 or 12, color = C.darkMuted }, label },
    Text { style = { fontSize = dark and 16 or 20, fontWeight = dark and "normal" or "bold", color = "#FFFFFF", fontFamily = MONO }, numberOfLines = 1, value } }
end

local function Ring(pct)
  return lx.Canvas { pointerEvents = "none", style = { width = 220, height = 220 }, deps = { pct, C.darkAccent },
    onDraw = function(ctx, w, h)
      local cx, cy, r = w / 2, h / 2, w / 2 - 14
      ctx.lineWidth = 14; ctx.lineCap = "round"
      ctx.strokeStyle = C.darkTrack
      ctx:beginPath(); ctx:arc(cx, cy, r, 0, math.pi * 2); ctx:stroke()
      if pct > 0 then
        ctx.strokeStyle = C.darkAccent
        ctx:beginPath(); ctx:arc(cx, cy, r, -math.pi / 2, -math.pi / 2 + math.pi * 2 * pct / 100); ctx:stroke()
      end
    end }
end

local function titles(tr)
  local verb = tr.dir == "out" and t("发送") or t("接收")
  local who = tr.peer.alias or ""
  local queue = (tr.queueTotal and tr.queueTotal > 1) and t("（第 %d / %d 台）", tr.queueIndex or 1, tr.queueTotal) or ""
  if tr.done and tr.failed then return t("%s失败", verb), tr.error or "" end
  if tr.done then return t("%s完成", verb), (tr.dir == "out" and t("已发给 %s", who) or t("来自 %s", who)) .. queue end
  if tr.waiting then return t("等待对方接收…"), t("%s 需要在对方设备上点「接收」", who) .. queue end
  return tr.dir == "out" and t("正在发送") or t("正在接收"), (tr.dir == "out" and t("发给 %s", who) or t("来自 %s", who)) .. queue
end

local function actionButtons(tr, desktop)
  local h = desktop and 44 or 50
  if tr.done then
    local btns = {}
    if tr.dir == "in" and tr.savedTo and not tr.failed then
      btns[#btns + 1] = ui.Button { key = "open", title = t("打开文件夹"), height = h, radius = 14, fontSize = 15,
                                    style = (not desktop) and { flex = 1 } or nil, onTap = function() store.openPath(tr.savedTo, true) end }
    end
    btns[#btns + 1] = ui.Button { key = "done", title = t("完成"), kind = "primary", height = h, radius = 14, fontSize = 15, testID = "transfer-done",
                                  style = (not desktop) and { flex = 1 } or nil, onTap = store.hideTransfer }
    return btns
  end
  return { ui.Button { key = "cancel", title = tr.dir == "out" and t("取消发送") or t("取消接收"), kind = "danger", height = h, radius = 14, fontSize = 15,
                       style = (not desktop) and { flex = 1 } or nil, testID = "cancel-transfer",
                       onTap = function()
                         lx.dialog.confirm(t("取消传输？"), t("已经传完的文件会保留，没传完的会丢弃。"), function(ok)
                           if ok then store.cancelTransfer() end
                         end, { ok = t("取消传输"), cancel = t("继续") })
                       end } }
end

return lx.component(function(props)
  local tr = store.state.transfer
  if not tr or tr.hidden or not tr.peer then return nil end
  local pct, remain = stats(tr)
  local title, sub = titles(tr)
  local speed = (tr.done or tr.waiting) and "—" or (store.formatSize(tr.speed or 0) .. "/s")
  local remainStr = (tr.done or tr.waiting) and "—" or remainText(remain)

  if props.desktop then
    return View { style = { flex = 1, paddingVertical = 30, paddingHorizontal = 40, gap = 20, backgroundColor = C.ground },
      View { style = { flexDirection = "row", alignItems = "center", gap = 14 },
        ui.Button { icon = "chevronLeft", height = 38, radius = 10, iconSize = 20, testID = "transfer-back", onTap = store.hideTransfer },
        View { style = { flex = 1, gap = 2 },
          Text { style = { fontSize = 24, fontWeight = "900", color = C.ink }, numberOfLines = 1, title },
          Text { style = { fontSize = 13, color = C.muted }, numberOfLines = 1, sub } },
        store.state.encrypted and ui.Pill { text = t("HTTPS 加密"), icon = "lock", fontSize = 13 } or nil },
      View { style = { backgroundColor = C.dark, borderRadius = 22, paddingVertical = 28, paddingHorizontal = 32, flexDirection = "row", alignItems = "center", gap = 40 },
        View { style = { flexDirection = "row", alignItems = "baseline", gap = 4 },
          Text { testID = "pct", style = { fontSize = 84, fontWeight = "900", color = "#FFFFFF", fontFamily = MONO }, tostring(pct) },
          Text { style = { fontSize = 28, fontWeight = "bold", color = C.darkPct }, "%" } },
        View { style = { flex = 1, gap = 14 },
          ui.Bar { progress = pct / 100, height = 12, track = C.darkTrack2, color = tr.failed and C.darkMuted or C.darkAccent },
          View { style = { flexDirection = "row", gap = 16 },
            Stat(t("速度"), speed),
            Stat(t("已传 / 总量"), store.formatSize(tr.sent or 0) .. " / " .. store.formatSize(tr.total or 0)),
            Stat(t("剩余时间"), remainStr) } } },
      ScrollView { style = { flex = 1, backgroundColor = C.surface, borderRadius = 18, borderWidth = 1, borderColor = C.line }, FileRows(tr, false) },
      View { style = { flexDirection = "row", alignItems = "center", justifyContent = "space-between" },
        View { onTap = function() store.set({ autoClose = not store.state.autoClose }) end, style = { flexDirection = "row", alignItems = "center", gap = 8 },
          ui.Toggle { value = store.state.autoClose, onChange = function(v) store.set({ autoClose = v }) end },
          Text { style = { fontSize = 13, color = C.ink2 }, t("完成后自动关闭") } },
        View { style = { flexDirection = "row", gap = 10 }, actionButtons(tr, true) } },
    }
  end

  local safe = props.safeTop or 0
  return View { style = { position = "absolute", left = 0, right = 0, top = 0, bottom = 0, backgroundColor = C.dark },
    View { style = { paddingTop = safe + 8, paddingHorizontal = 16, flexDirection = "row", alignItems = "center", gap = 10 },
      View { testID = "transfer-back", onTap = store.hideTransfer, style = { width = 44, height = 44, borderRadius = 12, backgroundColor = C.darkButton, alignItems = "center", justifyContent = "center" },
        ui.Icon { name = "chevronDown", size = 20, color = "#FFFFFF" } },
      View { style = { flex = 1, alignItems = "center", marginRight = 54 },
        Text { style = { fontSize = 17, fontWeight = "bold", color = "#FFFFFF" }, numberOfLines = 1, title },
        Text { style = { fontSize = 12, color = C.darkMuted }, numberOfLines = 1, sub } } },
    View { style = { alignItems = "center", paddingTop = 26, gap = 18 },
      View { style = { width = 220, height = 220 },
        Ring(pct),
        View { style = { position = "absolute", left = 0, right = 0, top = 0, bottom = 0, alignItems = "center", justifyContent = "center" },
          View { style = { flexDirection = "row", alignItems = "baseline" },
            Text { testID = "pct", style = { fontSize = 58, color = "#FFFFFF", fontFamily = MONO }, tostring(pct) },
            Text { style = { fontSize = 22, color = C.darkPct }, "%" } },
          Text { style = { fontSize = 13, color = C.darkMuted }, t("共 %d 个文件", #(tr.files or {})) } } },
      View { style = { flexDirection = "row", alignSelf = "stretch", paddingHorizontal = 16 },
        Stat(t("速度"), speed, true), Stat(tr.dir == "out" and t("已发") or t("已收"), store.formatSize(tr.sent or 0), true), Stat(t("剩余"), remainStr, true) } },
    View { style = { flex = 1, marginTop = 16, marginHorizontal = 12, backgroundColor = C.surface,
                     borderRadius = 22, paddingHorizontal = 16, paddingTop = 8, paddingBottom = (props.safeBottom or 0) + 12 },
      ScrollView { style = { flex = 1 }, FileRows(tr, true) },
      View { style = { marginTop = 12, flexDirection = "row", gap = 10 }, actionButtons(tr, false) } },
  }
end, "ProgressView")
