-- 链接分享（LocalSend「通过链接分享」，prepare-download / download 接口）：同网段任何浏览器打开链接即可下载，无需安装。
-- 二维码 + 链接、访问 PIN、自动同意、浏览器的访问请求列表、停止分享。桌面 / 移动共用（桌面居中限宽）。
-- 主服务是 HTTPS 时，分享网页走单独的 HTTP 端口（浏览器打开自签证书会报不安全）。
local lx = require("lx")
local t = require("i18n")
local C = require("theme.colors")
local ui = require("components.ui")
local store = require("core.store")
local View, Text, ScrollView = lx.View, lx.Text, lx.ScrollView

return lx.component(function(props)
  local link = store.state.shareLink
  if not link then return nil end
  local desktop = props.desktop
  local ok, qr = pcall(lx.qrcode.image, link.url, { size = 320, color = "#1A1718", background = "#FFFFFF", margin = 1 })

  local reqs = {}
  for i, r in ipairs(link.requests) do
    local right
    if r.state == "gone" then
      right = ui.Pill { text = t("已离开"), tone = "gray" }
    elseif r.state == "pending" then
      right = View { style = { flexDirection = "row", gap = 8 },
        ui.Button { icon = "close", kind = "soft", height = 36, radius = 10, testID = "share-decline-" .. r.id, onTap = function() store.answerShareRequest(r.id, false) end },
        ui.Button { icon = "check", kind = "primary", height = 36, radius = 10, testID = "share-accept-" .. r.id, onTap = function() store.answerShareRequest(r.id, true) end } }
    elseif r.state == "done" then
      right = ui.Pill { text = t("已下载 %d 个", r.downloaded or 0) }
    elseif r.state == "accepted" then
      right = ui.Pill { text = t("已同意") }
    else
      right = ui.Pill { text = t("已拒绝"), tone = "gray" }
    end
    reqs[#reqs + 1] = View { key = r.id,
      style = { flexDirection = "row", alignItems = "center", gap = 10, minHeight = 58, borderBottomWidth = i < #link.requests and 1 or 0, borderColor = C.divider },
      ui.IconTile { name = "globe", tone = "gray", size = 36, radius = 10, iconSize = 18 },
      View { style = { flex = 1 },
        Text { style = { fontSize = 14, fontWeight = "500", color = C.ink }, r.client },
        Text { style = { fontSize = 12, color = C.muted, fontFamily = ui.MONO }, r.ip } },
      right }
  end
  if #reqs == 0 then
    reqs[1] = Text { style = { fontSize = 13, color = C.muted, paddingVertical = 16, textAlign = "center" }, t("还没有人打开链接") }
  end

  local content = {
    View { style = { backgroundColor = C.surface, borderRadius = 20, padding = 18, alignItems = "center", gap = 12 },
      Text { style = { fontSize = 13, color = C.muted, textAlign = "center" }, t("同一网络下的任何设备，用浏览器打开即可下载，无需安装") },
      View { style = { width = 168, height = 168, borderRadius = 14, borderWidth = 1, borderColor = C.line, padding = 10, backgroundColor = "#FFFFFF",
                       alignItems = "center", justifyContent = "center" },
        ok and lx.Image { src = qr, style = { width = 146, height = 146 } } or ui.Icon { name = "qr", size = 80, color = "#1A1718" } },
      View { style = { flexDirection = "row", alignSelf = "stretch", gap = 8 },
        View { style = { flex = 1, height = 44, borderRadius = 12, backgroundColor = C.ground, alignItems = "center", justifyContent = "center", paddingHorizontal = 8 },
          Text { style = { fontSize = 14, color = C.ink, fontFamily = ui.MONO }, numberOfLines = 1, link.url } },
        ui.Button { title = t("复制"), kind = "primary", height = 44, radius = 12, onTap = function()
            pcall(lx.clipboard.set, link.url); lx.dialog.toast(t("已复制链接")) end } } },
    View { style = { backgroundColor = C.surface, borderRadius = 18, paddingHorizontal = 16 },
      View { style = { flexDirection = "row", alignItems = "center", justifyContent = "space-between", minHeight = 50, borderBottomWidth = 1, borderColor = C.divider },
        Text { style = { fontSize = 14, color = C.ink }, t("访问需要 PIN") },
        View { style = { flexDirection = "row", alignItems = "center", gap = 10 },
          link.requirePin and Text { style = { fontSize = 15, letterSpacing = 3, color = C.brandStrong, fontFamily = ui.MONO }, link.pin } or nil,
          ui.Toggle { value = link.requirePin, onChange = function(v) store.setShareOption("requirePin", v) end } } },
      View { style = { flexDirection = "row", alignItems = "center", justifyContent = "space-between", minHeight = 50 },
        Text { style = { fontSize = 14, color = C.ink }, t("自动同意访问请求") },
        ui.Toggle { value = link.autoAccept, onChange = function(v) store.setShareOption("autoAccept", v) end } } },
    View { style = { gap = 8 },
      ui.SectionTitle { text = t("访问请求") },
      View { style = { backgroundColor = C.surface, borderRadius = 18, paddingHorizontal = 14 }, reqs } },
  }

  local stop = ui.Button { title = t("停止分享"), kind = "danger", height = 52, radius = 14, fontSize = 15, testID = "stop-share", onTap = store.stopShareLink }
  return View { style = { position = "absolute", left = 0, right = 0, top = 0, bottom = 0, backgroundColor = C.ground,
                          paddingTop = (props.safeTop or 0) + (desktop and 30 or 8), paddingBottom = (props.safeBottom or 0) + (desktop and 30 or 16),
                          paddingHorizontal = 16, alignItems = desktop and "center" or "stretch" },
    View { style = { flex = 1, width = desktop and 520 or nil, gap = 12 },
      ui.PageHeader { title = t("链接分享"), desktop = desktop, onBack = store.stopShareLink,
        right = Text { style = { fontSize = 12, color = C.muted }, t("%d 个文件 · %s", #store.state.selection, store.formatSize(store.selectionTotal())) } },
      ScrollView { style = { flex = 1 }, contentStyle = { gap = 12, paddingTop = 4 }, content },
      stop } }
end, "ShareLinkView")
