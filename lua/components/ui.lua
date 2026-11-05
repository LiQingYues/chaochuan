-- 通用界面组件（桌面 / 移动共用）。颜色一律读 theme/colors 的字段（渲染时读，切换主题后重渲染即生效），文字由调用方用 t() 传入。
local lx = require("lx")
local C = require("theme.colors")
local layout = require("theme.layout")
local Icon = require("components.icon")
local View, Text = lx.View, lx.Text

local M = {}
M.Icon = Icon
M.MONO = layout.FONT_MONO

--- 卡片
M.Card = lx.component(function(props)
  return View { style = { { backgroundColor = C.surface, borderRadius = props.radius or 16, borderWidth = props.border == false and 0 or 1,
                            borderColor = C.line, padding = props.padding or 16, gap = props.gap or 12 }, props.style },
    props.children }
end, "Card")

--- 按钮：kind = "primary"（品牌色底）| "outline"（卡片底灰边）| "danger"（品牌色描边）| "soft"（浅灰底）| "ghost"（无底无边）
M.Button = lx.component(function(props)
  local kind = props.kind or "outline"
  local h = props.height or 40
  local bg, fg, border = C.surface, C.ink, C.line
  if kind == "primary" then bg, fg, border = C.brand, C.onBrand, C.brand
  elseif kind == "danger" then bg, fg, border = C.surface, C.brandStrong, C.brandLine
  elseif kind == "soft" then bg, fg, border = C.sunken, C.ink, C.sunken
  elseif kind == "ghost" then bg, fg, border = "transparent", C.brandStrong, "transparent" end
  if props.disabled then fg = C.muted end
  local iconOnly = props.icon and not props.title
  return View { testID = props.testID, onTap = (not props.disabled) and props.onTap or nil,
    style = { { height = h, paddingHorizontal = iconOnly and 0 or (props.padX or 16), width = iconOnly and h or nil,
                borderRadius = props.radius or 10, backgroundColor = bg, borderWidth = 1, borderColor = border,
                opacity = props.disabled and 0.6 or 1,
                flexDirection = "row", alignItems = "center", justifyContent = "center", gap = 6 }, props.style },
    props.icon and Icon { name = props.icon, size = props.iconSize or 16, color = fg, fill = props.iconFill } or nil,
    props.title and Text { style = { fontSize = props.fontSize or 14, fontWeight = (kind == "primary" or kind == "danger") and "bold" or "500", color = fg },
                           numberOfLines = 1, props.title } or nil,
  }
end, "Button")

--- 开关（品牌色）
M.Toggle = lx.component(function(props)
  return lx.Switch { testID = props.testID, value = props.value == true, activeColor = C.brand, disabled = props.disabled,
                     onChange = function(e) if props.onChange then props.onChange(e.value) end end }
end, "Toggle")

--- 勾选框
M.Check = lx.component(function(props)
  local on = props.value == true
  local s = props.size or 20
  return View { onTap = props.onTap, testID = props.testID,
    style = { width = s, height = s, borderRadius = props.round and s / 2 or 6, borderWidth = on and 0 or 1.5, borderColor = C.dashed,
              backgroundColor = on and C.brand or C.surface, alignItems = "center", justifyContent = "center", flexShrink = 0 },
    on and Icon { name = "check", size = math.floor(s * 0.7), color = C.onBrand, stroke = 2.6 } or nil }
end, "Check")

--- 分段控件：items = { "…", … }，index 从 1 开始；accent = true 时选中项文字用品牌色
M.Segmented = lx.component(function(props)
  local items = {}
  for i, title in ipairs(props.items) do
    local on = i == props.index
    items[#items + 1] = View { key = i, testID = props.testID and (props.testID .. "-" .. i) or nil,
      onTap = function() if props.onChange then props.onChange(i) end end,
      style = { flex = props.stretch and 1 or nil, height = props.height or 34, paddingHorizontal = 14, borderRadius = 9,
                alignItems = "center", justifyContent = "center",
                backgroundColor = on and C.surface or "transparent",
                shadowColor = on and "#000000" or nil, shadowOpacity = on and 0.08 or nil, shadowRadius = on and 2 or nil, shadowOffsetY = on and 1 or nil },
      Text { style = { fontSize = 13, fontWeight = on and "bold" or "normal", color = on and (props.accent and C.brandStrong or C.ink) or C.ink2 },
             numberOfLines = 1, title },
    }
  end
  return View { style = { { flexDirection = "row", padding = 4, gap = 2, borderRadius = 12, backgroundColor = props.track or C.segTrack }, props.style }, items }
end, "Segmented")

--- 文件类型角标
M.FileBadge = lx.component(function(props)
  local s = props.size or 40
  return View { style = { width = s, height = s, borderRadius = s * 0.26, backgroundColor = props.tint or C.ink2,
                          alignItems = "center", justifyContent = "center", flexShrink = 0 },
    Text { style = { fontSize = s >= 40 and 11 or 10, fontWeight = "bold", color = "#FFFFFF" }, props.ext or "" } }
end, "FileBadge")

--- 图标方块（品牌浅底 / 灰底）
M.IconTile = lx.component(function(props)
  local s = props.size or 38
  local red = props.tone ~= "gray"
  return View { style = { width = s, height = s, borderRadius = props.radius or s * 0.32,
                          backgroundColor = props.bg or (red and C.brandTint or C.sunken),
                          alignItems = "center", justifyContent = "center", flexShrink = 0 },
    Icon { name = props.name, size = props.iconSize or math.floor(s * 0.5), color = props.color or (red and C.brand or C.ink) } }
end, "IconTile")

--- 品牌标志
M.Logo = lx.component(function(props)
  local s = props.size or 38
  return View { style = { width = s, height = s, borderRadius = s * 0.3, backgroundColor = C.brand,
                          alignItems = "center", justifyContent = "center", flexShrink = 0,
                          shadowColor = props.glow and C.brand or nil, shadowOpacity = props.glow and 0.32 or nil,
                          shadowRadius = props.glow and 14 or nil, shadowOffsetY = props.glow and 8 or nil },
    Icon { name = "logo", size = math.floor(s * 0.56), color = C.onBrand, stroke = 2.5 } }
end, "Logo")

--- 区块标题
M.SectionTitle = lx.component(function(props)
  return Text { style = { fontSize = props.size or 13, fontWeight = "bold", color = props.color or C.muted, marginLeft = 4 }, props.text }
end, "SectionTitle")

--- 小胶囊标签：tone = ok | brand | gray
M.Pill = lx.component(function(props)
  local tone = props.tone or "ok"
  local fg, bg = C.ok, C.okTint
  if tone == "brand" then fg, bg = C.brandStrong, C.brandTint
  elseif tone == "gray" then fg, bg = C.ink2, C.sunken end
  return View { onTap = props.onTap,
    style = { { flexDirection = "row", alignItems = "center", gap = 5, paddingHorizontal = 10, paddingVertical = 4,
                borderRadius = 999, backgroundColor = bg, alignSelf = "flex-start" }, props.style },
    props.dot and View { style = { width = 7, height = 7, borderRadius = 4, backgroundColor = tone == "ok" and C.okDot or C.brand } } or nil,
    props.icon and Icon { name = props.icon, size = 14, color = fg } or nil,
    Text { style = { fontSize = props.fontSize or 12, fontWeight = "500", color = fg, fontFamily = props.mono and M.MONO or nil }, props.text },
  }
end, "Pill")

--- 设备行：图标 + 别名（收藏星标 / LocalSend 标记）+ 型号 · #标签；右侧发送箭头或勾选框（多设备模式）；星标按钮切换收藏
M.DeviceRow = lx.component(function(props)
  local d = props.device
  local compact = props.compact
  local right
  if props.checkable then
    right = M.Check { value = props.checked, size = 24, round = true }
  elseif compact then
    right = Icon { name = "send", size = 18, color = C.brand }
  else
    right = View { style = { width = 40, height = 40, borderRadius = 12, backgroundColor = C.brand, alignItems = "center", justifyContent = "center" },
      Icon { name = "send", size = 18, color = C.onBrand } }
  end
  return View { testID = "device-" .. tostring(d.id), onTap = props.onTap, onLongPress = props.onLongPress,
    style = { { flexDirection = "row", alignItems = "center", gap = compact and 12 or 14,
                paddingVertical = compact and 12 or 14, paddingHorizontal = compact and 14 or 16,
                borderRadius = 16, backgroundColor = C.surface, borderWidth = (props.checked and 2) or (compact and 0 or 1),
                borderColor = props.checked and C.brand or C.line }, props.style },
    M.IconTile { name = props.icon or "phone", tone = "gray", size = compact and 44 or 48, radius = 14, iconSize = 22 },
    View { style = { flex = 1, gap = 3 },
      View { style = { flexDirection = "row", alignItems = "center", gap = 6 },
        Text { style = { fontSize = 15, fontWeight = "bold", color = C.ink, flexShrink = 1 }, numberOfLines = 1, d.alias },
        d.localsend and View { style = { borderWidth = 1, borderColor = C.dashed, borderRadius = 5, paddingHorizontal = 5 },
          Text { style = { fontSize = 10, color = C.ink2 }, "LocalSend" } } or nil,
      },
      View { style = { flexDirection = "row", alignItems = "center" },
        Text { style = { fontSize = compact and 12 or 13, color = C.muted, flexShrink = 1 }, numberOfLines = 1, (d.model ~= "" and (d.model .. " · ") or "") },
        Text { style = { fontSize = compact and 12 or 13, color = C.muted, fontFamily = M.MONO }, d.tag } },
    },
    View { testID = "fav-" .. tostring(d.id), onTap = props.onFavorite, style = { width = 36, height = 36, alignItems = "center", justifyContent = "center" },
      Icon { name = "star", size = 18, color = d.fav and C.star or C.faint, fill = d.fav } },
    right,
  }
end, "DeviceRow")

--- 设置行：label（+ 说明）+ 开关 / 值 + 箭头 / 自定义右侧
M.SettingRow = lx.component(function(props)
  local right
  if props.toggle ~= nil then
    right = M.Toggle { value = props.toggle, onChange = props.onToggle, disabled = props.disabled, testID = props.testID }
  elseif props.right then
    right = props.right
  else
    right = View { style = { flexDirection = "row", alignItems = "center", gap = 2, flexShrink = 1, maxWidth = "60%" },
      props.value and Text { style = { fontSize = 13, color = C.muted, fontFamily = props.mono and M.MONO or nil, textAlign = "right", flexShrink = 1 },
                             numberOfLines = 1, props.value } or nil,
      (props.onTap and not props.noArrow) and Icon { name = "chevronRight", size = 14, color = C.muted } or nil }
  end
  return View { testID = props.toggle == nil and props.testID or nil, onTap = props.onTap,
    style = { flexDirection = "row", alignItems = "center", justifyContent = "space-between", gap = 10,
              minHeight = props.height or 46, paddingVertical = props.hint and 8 or 0,
              borderBottomWidth = props.last and 0 or 1, borderColor = C.divider, opacity = props.disabled and 0.5 or 1 },
    View { style = { flexShrink = 1, gap = 2 },
      Text { style = { fontSize = 14, color = C.ink }, props.label },
      props.hint and Text { style = { fontSize = 12, color = C.muted, lineHeight = 17 }, props.hint } or nil },
    right,
  }
end, "SettingRow")

--- 设置分组：标题 + 卡片里的若干行（rows 为 SettingRow 的 props；nil 项跳过）
M.SettingGroup = lx.component(function(props)
  local list = {}
  for _, r in pairs(props.rows) do if r then list[#list + 1] = r end end
  table.sort(list, function(a, b) return (a.order or 0) < (b.order or 0) end)
  local rows = {}
  for i, r in ipairs(list) do
    r.key = r.label
    r.last = i == #list
    rows[#rows + 1] = M.SettingRow(r)
  end
  return View { style = { { gap = 8 }, props.style },
    M.SectionTitle { text = props.title, size = 12 },
    View { style = { backgroundColor = C.surface, borderRadius = 16, borderWidth = props.flat and 0 or 1, borderColor = C.line, paddingHorizontal = 14 }, rows },
  }
end, "SettingGroup")

--- 进度条（flexGrow 分比例）
M.Bar = lx.component(function(props)
  local p = math.max(0, math.min(1, props.progress or 0))
  local h = props.height or 6
  return View { style = { height = h, alignSelf = "stretch", flexDirection = "row", borderRadius = h / 2,
                          backgroundColor = props.track or C.barTrack, overflow = "hidden" },
    p > 0 and View { style = { flexGrow = p, flexBasis = 0, height = h, borderRadius = h / 2, backgroundColor = props.color or C.brand } } or nil,
    p < 1 and View { style = { flexGrow = 1 - p, flexBasis = 0, height = h } } or nil }
end, "Bar")

--- 子页面的头：返回按钮 + 标题
M.PageHeader = lx.component(function(props)
  return View { style = { flexDirection = "row", alignItems = "center", gap = 10, paddingTop = props.paddingTop or 0 },
    View { testID = "page-back", onTap = props.onBack,
      style = { width = 40, height = 40, borderRadius = 12, backgroundColor = C.surface, borderWidth = 1, borderColor = C.line,
                alignItems = "center", justifyContent = "center" },
      Icon { name = "chevronLeft", size = 20, color = C.ink } },
    Text { style = { fontSize = props.desktop and 24 or 20, fontWeight = "900", color = C.ink, flexShrink = 1 }, numberOfLines = 1, props.title },
    View { style = { flex = 1 } },
    props.right,
  }
end, "PageHeader")

--- 已选内容的小卡（带删除按钮）
M.SelectionChip = lx.component(function(props)
  local f = props.item
  local remove = View { testID = props.testID, onTap = props.onRemove,
    style = { position = "absolute", top = -6, right = -6, width = 22, height = 22, borderRadius = 11, backgroundColor = C.ink2,
              alignItems = "center", justifyContent = "center", borderWidth = 2, borderColor = C.surface },
    Icon { name = "close", size = 12, color = C.surface, stroke = 2.6 } }
  if props.compact then
    return View { style = { width = 58, height = 58 },
      M.FileBadge { ext = f.ext, tint = f.tint, size = 58 }, remove }
  end
  return View { style = { flex = 1, minWidth = 0 },
    View { style = { flexDirection = "row", alignItems = "center", gap = 10, padding = 10, borderRadius = 12, backgroundColor = C.ground },
      M.FileBadge { ext = f.ext, tint = f.tint },
      View { style = { flex = 1, gap = 2 },
        Text { style = { fontSize = 13, fontWeight = "500", color = C.ink }, numberOfLines = 1, f.text and f.text or f.name },
        Text { style = { fontSize = 12, color = C.muted }, props.sizeText } } },
    remove }
end, "SelectionChip")

return M
