-- 设置页（桌面 / 移动共用，分组与 LocalSend 设置页对应）。每一项都真正生效（store 里对应的 set* 动作）。
--   桌面三栏：通用 + 桌面 | 接收 + 发送 + 其它 | 网络；手机单列：本机卡片 + 接收 / 通用 / 网络 / 发送 / 其它
--   「其它」里的四项打开子页面（modules/setting/pages.lua）。
local lx = require("lx")
local t = require("i18n")
local C = require("theme.colors")
local ui = require("components.ui")
local store = require("core.store")
local host = require("core.host")
local View, Text, ScrollView = lx.View, lx.Text, lx.ScrollView

local M = {}

local THEMES = { { "system", "跟随系统" }, { "light", "浅色" }, { "dark", "深色" }, { "oled", "OLED 纯黑" } }
local ACCENT_NAMES = { red = "超传红", blue = "海蓝", green = "松绿", purple = "雾紫" }
local LANGS = { { "system", "跟随系统" }, { "zh", "简体中文" }, { "en", "English" } }
local TYPE_NAMES = { mobile = "手机", desktop = "桌面", web = "网页", headless = "无界面", server = "服务器" }

local function nameOf(list, key)
  for _, it in ipairs(list) do if it[1] == key then return t(it[2]) end end
  return key
end

local function choose(title, list, onPick)
  local names = {}
  for i, it in ipairs(list) do names[i] = t(it[2]) end
  lx.dialog.actionSheet(title, names, function(i) if i then onPick(list[i][1]) end end, t("取消"))
end

function M.renameDevice()
  lx.dialog.prompt(t("设备名"), t("附近的设备会看到这个名字"), function(v)
    if v and v ~= "" then store.rename(v) end
  end, { value = store.state.identity.alias })
end

local function AccentSwatches()
  local items = {}
  for _, a in ipairs(C.ACCENTS) do
    local on = store.pref("accent") == a
    items[#items + 1] = View { key = a, testID = "accent-" .. a, onTap = function() store.setAccent(a) end,
      style = { width = 26, height = 26, borderRadius = 13, backgroundColor = C.swatch(a), alignItems = "center", justifyContent = "center",
                borderWidth = on and 3 or 0, borderColor = C.surface, shadowColor = C.swatch(a), shadowOpacity = on and 0.6 or 0, shadowRadius = 4 },
      on and ui.Icon { name = "check", size = 14, color = "#FFFFFF", stroke = 3 } or nil }
  end
  return View { style = { flexDirection = "row", gap = 10 }, items }
end

local function groups(desktop)
  local s = store.state
  local p = store.pref
  local G = {}
  local quick = { t("关闭"), t("仅收藏设备"), t("所有人") }

  G.general = { title = t("通用"), rows = {
    { order = 1, label = t("主题"), value = nameOf(THEMES, p("theme")), testID = "set-theme",
      onTap = function() choose(t("主题"), THEMES, store.setTheme) end },
    { order = 2, label = t("强调色"), hint = t(ACCENT_NAMES[p("accent")] or ""), right = AccentSwatches() },
    { order = 3, label = t("语言"), value = nameOf(LANGS, p("language")), testID = "set-language",
      onTap = function() choose(t("语言"), LANGS, store.setLanguage) end },
    { order = 4, label = t("动画效果"), hint = t("接收页的呼吸圆环"), toggle = p("animations"), onToggle = store.setAnimations },
  } }

  if desktop then
    local rows = {
      { order = 1, label = t("关闭窗口时缩到托盘"), hint = lx.device.platform == "macos" and t("菜单栏显示图标，关掉窗口后继续接收") or t("任务栏通知区显示图标，关掉窗口后继续接收"),
        toggle = p("closeToTray"), onToggle = store.setCloseToTray, testID = "set-tray" },
      { order = 2, label = t("开机自动启动"), toggle = store.launchAtLogin(), onToggle = store.setLaunchAtLogin, testID = "set-autostart" },
      { order = 3, label = t("启动时隐藏到托盘"), hint = t("打开后需要从托盘图标唤出窗口"), toggle = p("startHidden"), onToggle = store.setStartHidden, testID = "set-start-hidden" },
    }
    if host.contextMenuSupported() then
      rows[#rows + 1] = { order = 4, label = t("右键菜单「用超传发送」"), hint = t("在资源管理器里右键文件 / 文件夹直接发送"),
                          toggle = p("contextMenu"), onToggle = store.setContextMenu, testID = "set-context-menu" }
    else
      rows[#rows + 1] = { order = 4, label = t("从 Finder 发送"), hint = t("右键文件 › 打开方式 › 超传，或把文件拖到程序坞里的超传图标") }
    end
    G.desktop = { title = t("桌面"), rows = rows }
  end

  local dirRow
  if desktop then
    dirRow = { order = 3, label = t("保存目录"), hint = s.saveDir, value = t("更改"), onTap = store.chooseSaveDir, testID = "set-save-dir" }
  else
    dirRow = { order = 3, label = t("保存位置"),
               hint = lx.device.platform == "ios" and t("「文件」App › 我的 iPhone › 超传") or s.saveDir,
               value = t("打开"), onTap = function() store.openPath(s.saveDir) end }
  end
  G.receive = { title = t("接收"), rows = {
    { order = 1, label = t("快速保存"), hint = t("不弹确认直接保存"), value = quick[s.quickSave], testID = "set-quicksave",
      onTap = function() lx.dialog.actionSheet(t("快速保存"), quick, function(i) if i then store.set({ quickSave = i }) end end, t("取消")) end },
    { order = 2, label = t("需要 PIN"), hint = s.requirePin and t("当前 PIN：%s（点这里修改）", s.pin or "") or t("对方发送前要输入 PIN"),
      toggle = s.requirePin, onToggle = store.toggleRequirePin, testID = "set-pin" },
    dirRow,
    (desktop and store.pref("saveDir")) and { order = 4, label = t("恢复默认保存目录"), onTap = store.resetSaveDir } or nil,
    (not desktop) and { order = 5, label = t("图片视频存到相册"), toggle = s.saveToAlbum, onToggle = function(v) store.set({ saveToAlbum = v }) end } or nil,
    { order = 6, label = t("完成后自动关闭进度页"), toggle = s.autoClose, onToggle = function(v) store.set({ autoClose = v }) end },
    { order = 7, label = t("保存到记录"), toggle = p("saveHistory"), onToggle = store.setSaveHistory },
  } }
  -- 需要 PIN 开着时点标题可以改 PIN
  if s.requirePin then G.receive.rows[2].onTap = function() store.toggleRequirePin(true) end end

  G.send = { title = t("发送"), rows = {
    { order = 1, label = t("链接分享自动同意请求"), hint = t("浏览器打开链接后不用逐个确认"), toggle = p("shareAutoAccept"), onToggle = store.setShareAutoAccept },
  } }

  local nicValue = (p("nic") == "auto") and t("自动") or p("nic")
  G.network = { title = t("网络"), rows = {
    { order = 1, label = t("接收服务"), hint = s.online and t("运行中 · %s", s.encrypted and "HTTPS" or "HTTP") or t("已关闭，别人发现不了本机"),
      toggle = s.online, onToggle = function(v) store.set({ online = v }) end, testID = "set-online" },
    { order = 2, label = t("设备名"), value = s.identity.alias, onTap = M.renameDevice, testID = "set-alias" },
    { order = 3, label = t("设备类型"), value = t(TYPE_NAMES[s.identity.deviceType] or s.identity.deviceType),
      onTap = function()
        local list = {}
        for _, k in ipairs(store.DEVICE_TYPES) do list[#list + 1] = { k, TYPE_NAMES[k] } end
        choose(t("设备类型"), list, store.setDeviceType)
      end },
    { order = 4, label = t("设备型号"), value = s.identity.model,
      onTap = function()
        lx.dialog.prompt(t("设备型号"), t("别人看到的型号；留空恢复默认"), function(v) if v ~= nil then store.setDeviceModel(v) end end, { value = s.identity.model })
      end },
    { order = 5, label = t("端口"), value = tostring(s.port), mono = true,
      onTap = function()
        lx.dialog.prompt(t("端口"), t("默认 53317（LocalSend 标准端口）"), function(v) if v and v ~= "" then store.setPort(v) end end, { value = tostring(s.port) })
      end },
    { order = 6, label = t("网卡"), value = nicValue, hint = s.identity.ips[1],
      onTap = function()
        local list = { { "auto", "自动" } }
        for _, it in ipairs(store.interfaces()) do list[#list + 1] = { it.ip, it.name .. "  " .. it.ip } end
        choose(t("对外使用的网卡"), list, store.setNic)
      end },
    { order = 7, label = t("发现超时"), value = t("%d 毫秒", p("discoveryTimeout") or 1000),
      onTap = function()
        local list = {}
        for _, ms in ipairs(store.TIMEOUTS) do list[#list + 1] = { ms, t("%d 毫秒", ms) } end
        choose(t("扫描网络时每个地址等多久"), list, store.setDiscoveryTimeout)
      end },
    { order = 8, label = t("加密（HTTPS）"), hint = lx.crypto.supportsSelfSignedCert and t("与 LocalSend 一致的自签证书") or t("这个平台暂不支持，接收用 HTTP"),
      toggle = s.encrypted, onToggle = function(v) store.set({ encrypted = v }) end, disabled = not lx.crypto.supportsSelfSignedCert },
    { order = 9, label = t("组播地址"), value = p("multicast") or "224.0.0.167", mono = true,
      onTap = function()
        lx.dialog.prompt(t("组播地址"), t("默认 224.0.0.167；要和其它设备一致才能互相发现"), function(v) if v and v ~= "" then store.setMulticast(v) end end,
          { value = p("multicast") or "224.0.0.167" })
      end },
    { order = 10, label = t("重新生成设备身份"), hint = t("换一个新名字和指纹，别人那边的收藏会失效"),
      onTap = function()
        lx.dialog.confirm(t("重新生成设备身份？"), t("会换一个新的设备名和指纹，其它设备上对本机的收藏会失效。"), function(ok) if ok then store.resetIdentity() end end)
      end },
  } }

  G.other = { title = t("其它"), rows = {
    { order = 1, label = t("连不上？故障排除"), onTap = function() store.openPage("troubleshoot") end, testID = "page-troubleshoot" },
    { order = 2, label = t("开源许可"), onTap = function() store.openPage("licenses") end, testID = "page-licenses" },
    { order = 3, label = t("隐私政策"), onTap = function() store.openPage("privacy") end, testID = "page-privacy" },
    { order = 4, label = t("关于超传"), value = require("modules.setting.pages").VERSION, onTap = function() store.openPage("about") end, testID = "page-about" },
  } }
  return G
end

M.View = lx.component(function(props)
  local G = groups(props.desktop)
  if props.desktop then
    local function col(list)
      local out = {}
      for _, g in ipairs(list) do out[#out + 1] = ui.SettingGroup { key = g.title, title = g.title, rows = g.rows } end
      return View { style = { flex = 1, minWidth = 260, gap = 16 }, out }
    end
    return ScrollView { style = { flex = 1 }, contentStyle = { paddingVertical = 30, paddingHorizontal = 40, gap = 18 },
      Text { style = { fontSize = 28, fontWeight = "900", color = C.ink }, t("设置") },
      View { style = { flexDirection = "row", gap = 16, alignItems = "flex-start", flexWrap = "wrap" },
        col({ G.general, G.desktop }), col({ G.receive, G.send, G.other }), col({ G.network }) } }
  end
  local id = store.state.identity
  local list = {}
  for _, g in ipairs({ G.receive, G.general, G.network, G.send, G.other }) do
    list[#list + 1] = ui.SettingGroup { key = g.title, title = g.title, rows = g.rows, flat = true }
  end
  return View { style = { flex = 1 },
    View { style = { paddingHorizontal = 20, paddingTop = 8, paddingBottom = 8 },
      Text { style = { fontSize = 22, fontWeight = "900", color = C.ink }, t("设置") } },
    ScrollView { style = { flex = 1 }, contentStyle = { paddingHorizontal = 16, paddingTop = 6, paddingBottom = 24, gap = 14 },
      View { style = { backgroundColor = C.brand, borderRadius = 18, paddingVertical = 14, paddingHorizontal = 16, flexDirection = "row", alignItems = "center", gap = 12 },
        View { style = { width = 46, height = 46, borderRadius = 14, backgroundColor = "#FFFFFF2E", alignItems = "center", justifyContent = "center" },
          ui.Icon { name = store.ICON_BY_TYPE[id.deviceType] or "phone", size = 24, color = "#FFFFFF" } },
        View { style = { flex = 1, gap = 2 },
          Text { style = { fontSize = 17, fontWeight = "bold", color = "#FFFFFF" }, numberOfLines = 1, id.alias },
          Text { style = { fontSize = 12, color = "#FFFFFFCC" }, numberOfLines = 1, id.model .. " · " .. t(TYPE_NAMES[id.deviceType] or "") .. " · " .. id.tag } },
        View { onTap = M.renameDevice, style = { height = 34, paddingHorizontal = 12, borderRadius = 10, backgroundColor = "#FFFFFF", justifyContent = "center" },
          Text { style = { fontSize = 13, fontWeight = "bold", color = C.brandStrong }, t("改名") } } },
      list } }
end, "SettingView")

return M
