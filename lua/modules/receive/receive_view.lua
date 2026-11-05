-- 接收页（桌面 / 移动共用）：本机身份（圆环主视觉，「动画效果」开时外圈呼吸）+ 快速保存 + PIN + 保存位置 + 扫码连接。
local lx = require("lx")
local t = require("i18n")
local C = require("theme.colors")
local ui = require("components.ui")
local store = require("core.store")
local View, Text, ScrollView = lx.View, lx.Text, lx.ScrollView

--- 圆环：三层同心圆 + 标志；animations 开时外两层呼吸（缩放）
local Beacon = lx.class("Beacon", lx.Component)

function Beacon:init(props)
  self.outer = lx.createRef()
  self.mid = lx.createRef()
end

function Beacon:startPulse()
  self:stopPulse()
  if not store.pref("animations") then return end
  pcall(function()
    self.anims = {
      lx.animate(self.outer, { scale = 1.05, opacity = 0.75 }, { duration = 1600, repeatCount = math.huge, autoreverse = true, easing = "easeInOut" }),
      lx.animate(self.mid, { scale = 1.04 }, { duration = 1600, delay = 300, repeatCount = math.huge, autoreverse = true, easing = "easeInOut" }),
    }
  end)
end

function Beacon:stopPulse()
  for _, a in ipairs(self.anims or {}) do pcall(a.stop, a) end
  self.anims = nil
  pcall(function() lx.animate.set(self.outer, { scale = 1, opacity = 1 }); lx.animate.set(self.mid, { scale = 1 }) end)
end

function Beacon:onMount() self.animOn = store.pref("animations"); self:startPulse() end
function Beacon:onUpdate()
  local on = store.pref("animations")
  if on ~= self.animOn then self.animOn = on; if on then self:startPulse() else self:stopPulse() end end
end
function Beacon:onUnmount() self:stopPulse() end

function Beacon:render()
  local r = self.props.desktop and { 300, 224, 152, 92 } or { 250, 186, 126, 78 }
  return View { style = { width = r[1], height = r[1], alignItems = "center", justifyContent = "center" },
    View { ref = self.outer, style = { position = "absolute", width = r[1], height = r[1], borderRadius = r[1] / 2, backgroundColor = C.ring1 } },
    View { ref = self.mid, style = { position = "absolute", width = r[2], height = r[2], borderRadius = r[2] / 2, backgroundColor = C.ring2 } },
    View { style = { width = r[3], height = r[3], borderRadius = r[3] / 2, backgroundColor = C.ring3, alignItems = "center", justifyContent = "center" },
      View { testID = "beacon", ui.Logo { size = r[4], glow = true } } } }
end

local function Identity(props)
  local s = store.state
  local id = s.identity
  local chips = {}
  for _, ip in ipairs(id.ips) do
    chips[#chips + 1] = ui.Pill { key = ip, text = ip, tone = "gray", mono = true, fontSize = 13 }
  end
  local typeName = ({ mobile = t("手机"), desktop = t("桌面设备"), web = t("网页"), headless = t("无界面"), server = t("服务器") })[id.deviceType] or ""
  return View { style = { alignItems = "center", gap = props.desktop and 8 or 6 },
    View { style = { flexDirection = "row", alignItems = "center", gap = 10 },
      Text { testID = "alias", style = { fontSize = props.desktop and 34 or 28, fontWeight = "900", color = C.ink }, numberOfLines = 1, id.alias },
      ui.Button { icon = "edit", kind = "soft", height = 34, radius = 9, testID = "rename",
        onTap = function() require("modules.setting.setting_view").renameDevice() end } },
    Text { style = { fontSize = 13, color = C.muted, textAlign = "center" },
      id.model .. " · " .. typeName .. " · " .. id.tag .. " · " .. t("端口 %d", s.port) },
    View { style = { flexDirection = "row", gap = 8, marginTop = 4, flexWrap = "wrap", justifyContent = "center" },
      s.online and ui.Pill { text = t("在线，等待接收"), dot = true } or ui.Pill { text = t("接收已关闭"), tone = "gray" },
      props.desktop and chips or nil,
      s.encrypted and ui.Pill { text = t("已加密"), icon = "lock" } or ui.Pill { text = t("未加密（HTTP）"), tone = "gray" },
    },
  }
end

local function QuickSave(props)
  return ui.Card { gap = 10, border = props.desktop,
    View { style = { flexDirection = "row", justifyContent = "space-between", alignItems = "center", gap = 8 },
      Text { style = { fontSize = 15, fontWeight = "bold", color = C.ink }, t("快速保存") },
      Text { style = { fontSize = 12, color = C.muted, flexShrink = 1, textAlign = "right" }, numberOfLines = 1, t("开启后免确认直接保存") } },
    ui.Segmented { items = { t("关闭"), t("仅收藏设备"), t("所有人") }, index = store.state.quickSave, testID = "quicksave",
      stretch = true, accent = true, track = C.sunken, height = 36,
      onChange = function(i) store.set({ quickSave = i }) end },
  }
end

local function Options(props)
  local s = store.state
  local dirName = s.saveDir and lx.fs.basename(s.saveDir) or "—"
  return ui.Card { padding = 0, gap = 0, border = props.desktop, style = { paddingHorizontal = props.desktop and 18 or 14 },
    ui.SettingRow { label = t("需要 PIN 才能接收"), hint = s.requirePin and t("当前 PIN：%s", s.pin or "") or nil,
                    toggle = s.requirePin, onToggle = store.toggleRequirePin, height = 52, testID = "require-pin" },
    ui.SettingRow { label = t("保存到"), value = props.desktop and dirName
                      or (lx.device.platform == "ios" and t("「文件」App › 超传") or (s.saveDir and s.saveDir:find("/Download/") and t("下载 › 超传") or dirName)), height = 52,
                    onTap = props.desktop and store.chooseSaveDir or function() store.openPath(s.saveDir) end, testID = "save-dir",
                    right = props.desktop and View { style = { flexDirection = "row", alignItems = "center", gap = 8 },
                      Text { style = { fontSize = 13, color = C.muted, maxWidth = 150 }, numberOfLines = 1, dirName },
                      ui.Button { title = t("打开"), height = 30, padX = 10, fontSize = 12, radius = 8, onTap = function() store.openPath(s.saveDir) end },
                      ui.Button { title = t("更改"), height = 30, padX = 10, fontSize = 12, radius = 8, onTap = store.chooseSaveDir } } or nil,
                    last = true } }
end

local function qrText()
  local s = store.state
  return string.format("chaochuan://%s:%d", s.identity.ips[1] or "", s.port)
end

local function QrCard(props)
  local ok, path = pcall(lx.qrcode.image, qrText(), { size = 320, color = "#1A1718", background = "#FFFFFF", margin = 1 })
  local size = props.big and 200 or 90
  return ui.Card { border = props.desktop, style = { flexDirection = props.big and "column" or "row", alignItems = "center" }, gap = 16,
    View { style = { width = size + 14, height = size + 14, borderRadius = 12, borderWidth = 1, borderColor = C.line, padding = 6,
                     backgroundColor = "#FFFFFF", alignItems = "center", justifyContent = "center" },
      ok and lx.Image { src = path, style = { width = size, height = size } } or ui.Icon { name = "qr", size = 48, color = "#1A1718" } },
    View { style = { flex = props.big and nil or 1, gap = 6, alignItems = props.big and "center" or "flex-start" },
      Text { style = { fontSize = 15, fontWeight = "bold", color = C.ink }, t("扫码连接") },
      Text { style = { fontSize = 13, color = C.muted, lineHeight = 20, textAlign = props.big and "center" or "left" },
        t("搜不到设备时，在对方的超传里点「扫码连接」扫这个码，或者手动输入下面的地址。") },
      Text { style = { fontSize = 13, color = C.ink2, fontFamily = ui.MONO }, (store.state.identity.ips[1] or "") .. ":" .. store.state.port } },
  }
end

return lx.component(function(props)
  local s = store.state
  if props.desktop then
    return View { style = { flex = 1, flexDirection = "row", gap = 24, padding = 30, paddingHorizontal = 40 },
      View { style = { flex = 1, backgroundColor = C.surface, borderRadius = 22, borderWidth = 1, borderColor = C.line,
                       alignItems = "center", justifyContent = "center", gap = 22, overflow = "hidden" },
        View { style = { position = "absolute", top = 22, left = 24, right = 24, flexDirection = "row", justifyContent = "space-between", alignItems = "center" },
          Text { style = { fontSize = 28, fontWeight = "900", color = C.ink }, t("接收") },
          View { style = { flexDirection = "row", alignItems = "center", gap = 10 },
            Text { style = { fontSize = 14, color = C.ink2 }, t("接收开关") },
            ui.Toggle { value = s.online, testID = "online", onChange = function(v) store.set({ online = v }) end } } },
        Beacon { desktop = true },
        Identity { desktop = true },
      },
      ScrollView { style = { width = 340 }, contentStyle = { gap = 16 },
        QuickSave { desktop = true },
        Options { desktop = true },
        QrCard { desktop = true },
        View { style = { minHeight = 130, backgroundColor = C.surface, borderRadius = 18, borderWidth = 1, borderColor = C.brandLine,
                         alignItems = "center", justifyContent = "center", gap = 6, padding = 16 },
          ui.Icon { name = "wifi", size = 26, color = C.brand },
          Text { style = { fontSize = 13, color = C.muted }, t("等待其他设备发送…") },
          Text { style = { fontSize = 13, color = C.muted, textAlign = "center" }, t("超传与 LocalSend 设备都能互传") } },
      },
    }
  end
  return View { style = { flex = 1 },
    View { style = { paddingHorizontal = 20, paddingTop = 8, paddingBottom = 8, flexDirection = "row", alignItems = "center", justifyContent = "space-between" },
      View { style = { flexDirection = "row", alignItems = "center", gap = 8 },
        ui.Logo { size = 32 },
        Text { style = { fontSize = 22, fontWeight = "900", color = C.ink }, t("接收") } },
      View { style = { flexDirection = "row", gap = 8, alignItems = "center" },
        ui.Toggle { value = s.online, testID = "online", onChange = function(v) store.set({ online = v }) end },
        ui.Button { icon = s.showQr and "close" or "qr", kind = "outline", height = 44, radius = 12, iconSize = 20, testID = "show-qr",
          onTap = function() store.set({ showQr = not s.showQr }) end } } },
    ScrollView { style = { flex = 1 }, contentStyle = { paddingHorizontal = 20, paddingTop = 8, paddingBottom = 16, alignItems = "center", gap = 18 },
      s.showQr and View { style = { alignSelf = "stretch" }, QrCard { big = true } } or Beacon {},
      Identity {},
      View { style = { alignSelf = "stretch", gap = 12 }, QuickSave {}, Options {} },
    },
  }
end, "ReceiveView")
