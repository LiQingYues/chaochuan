-- 接收请求（LocalSend prepare-upload 到达时弹出；桌面 / 移动共用内容）：来源设备、文件勾选（可只收一部分）、
-- 自动接收此设备、拒绝 / 接收。桌面是居中弹窗，手机是底部弹出面板。另含「收到文本消息」浮卡。
local lx = require("lx")
local t = require("i18n")
local C = require("theme.colors")
local ui = require("components.ui")
local store = require("core.store")
local View, Text, ScrollView = lx.View, lx.Text, lx.ScrollView

local M = {}

local function Body(props)
  local inc = store.state.incoming
  local desktop = props.desktop
  local count, total = 0, 0
  for _, f in ipairs(inc.files) do if f.on then count = count + 1; total = total + f.size end end
  local rows = {}
  for i, f in ipairs(inc.files) do
    rows[#rows + 1] = View { key = i, testID = "incoming-file-" .. i, onTap = function() store.toggleIncomingFile(i) end,
      style = { flexDirection = "row", alignItems = "center", gap = desktop and 12 or 10, minHeight = desktop and 54 or 52,
                paddingHorizontal = desktop and 14 or 0, borderTopWidth = (desktop or i > 1) and 1 or 0, borderColor = desktop and C.divider or C.line },
      desktop and ui.Check { value = f.on } or nil,
      ui.FileBadge { ext = f.ext, tint = f.tint, size = 34 },
      View { style = { flex = 1, gap = 1 },
        Text { style = { fontSize = 14, color = C.ink }, numberOfLines = 1, f.name },
        not desktop and Text { style = { fontSize = 12, color = C.muted }, store.formatSize(f.size) } or nil },
      desktop and Text { style = { fontSize = 13, color = C.muted }, store.formatSize(f.size) } or ui.Check { value = f.on } }
  end
  local allOn = count == #inc.files
  return {
    View { style = { flexDirection = "row", alignItems = "center", gap = desktop and 16 or 12 },
      ui.IconTile { name = store.ICON_BY_TYPE[inc.peer.deviceType] or "phone", size = desktop and 56 or 50, radius = 16, iconSize = 28 },
      View { style = { flex = 1, gap = 3 },
        Text { style = { fontSize = desktop and 20 or 18, fontWeight = "900", color = C.ink }, t("%s 想发给你 %d 个文件", inc.peer.alias, #inc.files) },
        Text { style = { fontSize = 12, color = C.muted }, numberOfLines = 1,
          (inc.peer.model ~= "" and (inc.peer.model .. " · ") or "") .. (desktop and inc.peer.ip or inc.peer.tag) .. " · " .. t("已选 %s", store.formatSize(total)) } } },
    View { style = { borderRadius = desktop and 14 or 16, borderWidth = desktop and 1 or 0, borderColor = C.line,
                     backgroundColor = desktop and C.surface or C.ground, overflow = "hidden", paddingHorizontal = desktop and 0 or 14 },
      View { style = { flexDirection = "row", alignItems = "center", justifyContent = "space-between", paddingHorizontal = desktop and 14 or 0,
                       height = 40, backgroundColor = desktop and C.tableHead or "transparent" },
        Text { style = { fontSize = 13, color = C.ink2 }, t("选择要接收的文件") },
        Text { testID = "select-all", onTap = store.selectAllIncoming, style = { fontSize = 13, fontWeight = "500", color = C.brandStrong },
               allOn and t("全不选") or t("全选") } },
      ScrollView { style = { maxHeight = desktop and 280 or 260 }, rows } },
    View { style = { flexDirection = "row", alignItems = "center", justifyContent = "space-between", gap = 8 },
      Text { style = { fontSize = desktop and 13 or 14, color = desktop and C.muted or C.ink, flexShrink = 1 }, numberOfLines = 1,
        desktop and t("保存到 %s", store.state.saveDir or "") or t("图片和视频存到相册") },
      not desktop and ui.Toggle { value = store.state.saveToAlbum, onChange = function(v) store.set({ saveToAlbum = v }) end } or nil },
    View { testID = "trust", onTap = function() inc.trust = not inc.trust; store.changed() end, style = { flexDirection = "row", alignItems = "center", gap = 8 },
      ui.Check { value = inc.trust },
      Text { style = { fontSize = 13, color = C.ink2 }, t("以后自动接收这台设备（加入收藏）") } },
    View { style = { flexDirection = "row", gap = 10, justifyContent = desktop and "flex-end" or "space-between" },
      ui.Button { title = t("拒绝"), kind = desktop and "outline" or "soft", height = desktop and 44 or 52, radius = desktop and 12 or 14, fontSize = desktop and 15 or 16,
                  style = (not desktop) and { flex = 1 } or nil, testID = "decline", onTap = store.declineIncoming },
      ui.Button { title = count == 0 and t("先勾选文件") or (allOn and t("全部接收") or t("接收 %d 个", count)), kind = "primary", disabled = count == 0,
                  height = desktop and 44 or 52, radius = desktop and 12 or 14, fontSize = desktop and 15 or 16,
                  style = (not desktop) and { flex = 1 } or nil, testID = "accept", onTap = store.acceptIncoming } },
  }
end

M.Dialog = lx.component(function(props)
  if not store.state.incoming then return nil end
  local desktop = props.desktop
  local mask = { position = "absolute", left = 0, right = 0, top = 0, bottom = 0, backgroundColor = C.mask }
  if desktop then
    return View { style = { mask, { alignItems = "center", justifyContent = "center" } },
      View { style = { width = 540, backgroundColor = C.surface, borderRadius = 24, paddingVertical = 26, paddingHorizontal = 28, gap = 16,
                       shadowColor = "#000000", shadowOpacity = 0.3, shadowRadius = 40, shadowOffsetY = 30 },
        Body { desktop = true } } }
  end
  return View { style = mask,
    View { style = { flex = 1 } },
    View { style = { backgroundColor = C.surface, borderRadius = 26,
                     paddingTop = 10, paddingHorizontal = 20, paddingBottom = (props.safeBottom or 0) + 20, gap = 16 },
      View { style = { alignSelf = "center", width = 40, height = 5, borderRadius = 3, backgroundColor = C.dashed } },
      Body {} } }
end, "IncomingDialog")

--- 收到文本消息
M.TextToast = lx.component(function(props)
  local msg = store.state.textMessage
  if not msg then return nil end
  local close = store.dismissText
  local url = msg.text:match("https?://[%w%-%._~:/%?#%[%]@!%$&'%(%)%*%+,;=%%]+")
  return View { style = { position = "absolute", top = (props.safeTop or 0) + (props.desktop and 64 or 8), right = props.desktop and 24 or 12,
                          left = (not props.desktop) and 12 or nil, width = props.desktop and 340 or nil,
                          backgroundColor = C.surface, borderRadius = 16, paddingVertical = 14, paddingHorizontal = 16, gap = 8,
                          borderWidth = 1, borderColor = C.line,
                          shadowColor = "#000000", shadowOpacity = 0.2, shadowRadius = 16, shadowOffsetY = 12 },
    View { style = { flexDirection = "row", alignItems = "center", gap = 8 },
      ui.Icon { name = "text", size = 16, color = C.brand },
      Text { style = { fontSize = 13, color = C.muted, flex = 1 }, numberOfLines = 1, t("%s 发来一段文本", msg.from) },
      View { testID = "text-toast-close", onTap = close, style = { width = 32, height = 32, marginRight = -8, marginVertical = -8,
                                                                    alignItems = "center", justifyContent = "center", borderRadius = 8 },
        ui.Icon { name = "close", size = 16, color = C.muted } } },
    ScrollView { style = { maxHeight = 200, backgroundColor = C.ground, borderRadius = 10 },
      Text { style = { fontSize = 14, color = C.ink, lineHeight = 22, paddingVertical = 10, paddingHorizontal = 12 }, msg.text } },
    View { style = { flexDirection = "row", gap = 8, justifyContent = "flex-end" },
      url and ui.Button { title = t("打开链接"), height = 32, padX = 12, fontSize = 13, radius = 8, onTap = function()
          pcall(lx.linking.open, url); close() end } or nil,
      ui.Button { title = t("复制"), kind = "primary", height = 32, padX = 12, fontSize = 13, radius = 8, onTap = function()
          pcall(lx.clipboard.set, msg.text); lx.dialog.toast(t("已复制")); close() end } } }
end, "TextToast")

return M
