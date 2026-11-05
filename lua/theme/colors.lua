-- 超传配色。界面读这张表的字段（渲染时读，所以切换主题 / 配色后重渲染即生效）。
--   M.apply(themeMode, accent)：themeMode = "system" | "light" | "dark" | "oled"；accent = "red" | "blue" | "green" | "purple"
--   M.isDark：当前是否深色
-- 改色只改这里：BASE（浅色）/ DARK / OLED 是底色与文字，ACCENTS 是强调色（品牌色及其浅底 / 描边）。
local M = {}

local BASE = {
  ground = "#F6F4F3",       -- 页面底色
  surface = "#FFFFFF",      -- 卡片
  sunken = "#F1EDEC",       -- 分段控件槽、次级底
  segTrack = "#ECE7E6",     -- 页头分段控件槽
  line = "#ECE7E6",         -- 卡片描边
  divider = "#F4F1F0",      -- 行分隔线
  toggleOff = "#DDD6D4",
  dashed = "#DDD6D4",       -- 虚线框 / 未选中勾选框描边
  faint = "#CFC7C5",        -- 空状态图标
  barTrack = "#E9E3E2",     -- 进度条轨道
  tableHead = "#FAF8F8",    -- 表头底
  mask = "#1A171873",       -- 弹窗遮罩
  ink = "#1A1718",          -- 主文字
  ink2 = "#4A4442",         -- 次级文字 / 未选中导航
  muted = "#67615F",        -- 说明文字（白底对比度 > 4.5）
  ok = "#1F7A4D", okDot = "#23A26D", okTint = "#E7F5EE",
  star = "#E8A33D",
  onBrand = "#FFFFFF",      -- 品牌色上的文字
  -- 传输进度页（深色卡片，浅色 / 深色主题都用深色）
  dark = "#1A1718", darkTrack = "#2F292B", darkTrack2 = "#3A3436", darkButton = "#2A2527",
  darkMuted = "#BDB5B3", darkAccent = "#E8394A", darkPct = "#F4A6AF",
}

local DARK = {
  ground = "#141213", surface = "#1F1C1D", sunken = "#2A2627", segTrack = "#2A2627",
  line = "#2E2A2B", divider = "#2A2627", toggleOff = "#4A4442", dashed = "#4A4442", faint = "#4F4849",
  barTrack = "#3A3436", tableHead = "#252122", mask = "#000000A6",
  ink = "#F3EFEE", ink2 = "#CFC8C6", muted = "#A39C9A",
  ok = "#5CC48F", okDot = "#3FB57A", okTint = "#173326",
  star = "#F0B44C", onBrand = "#FFFFFF",
  dark = "#0E0C0D", darkTrack = "#2F292B", darkTrack2 = "#3A3436", darkButton = "#2A2527",
  darkMuted = "#BDB5B3", darkAccent = "#E8394A", darkPct = "#F4A6AF",
}

local OLED = {}
for k, v in pairs(DARK) do OLED[k] = v end
OLED.ground, OLED.surface, OLED.sunken, OLED.segTrack, OLED.line, OLED.divider, OLED.tableHead, OLED.dark =
  "#000000", "#0E0D0D", "#1A1818", "#1A1818", "#1F1C1D", "#1A1818", "#141313", "#000000"

-- 强调色：brand（按钮 / 选中）、brandStrong（强调文字）、brandTint（浅底）、brandLine（描边）、环形三层、深色主题下的对应值
local ACCENTS = {
  red =    { light = { "#D62839", "#B01E2E", "#FCEBED", "#E3B5BB", "#FDF0F2", "#FBE1E5", "#F6CBD1" },
             dark =  { "#E5394A", "#FF7A86", "#3A1C20", "#6B2B33", "#2A1A1C", "#3A1F23", "#4D252B" } },
  blue =   { light = { "#1F6FEB", "#1858C4", "#E8F0FE", "#B4CCF4", "#EEF4FE", "#DCE8FD", "#C5D9FB" },
             dark =  { "#3B82F6", "#8AB4FF", "#16243A", "#284270", "#152033", "#1A2A45", "#203558" } },
  green =  { light = { "#1E8E5A", "#167048", "#E6F5EE", "#B0DCC6", "#EDF8F2", "#D8F0E3", "#BFE6D1" },
             dark =  { "#2BAA6E", "#6FD3A0", "#132B20", "#21523B", "#122219", "#173024", "#1D3D2D" } },
  purple = { light = { "#7C3AED", "#6328C9", "#F1EAFE", "#CDB8F6", "#F5F0FE", "#E9DEFD", "#D9C6FB" },
             dark =  { "#8B5CF6", "#B79CFF", "#261A3D", "#43306E", "#1E1730", "#281E40", "#332652" } },
}
M.ACCENTS = { "red", "blue", "green", "purple" }

M.isDark = false
M.mode = "system"
M.accent = "red"

--- 系统当前是否深色（lx.screen.appearance）
local function systemDark()
  local ok, lx = pcall(require, "lx")
  if not ok then return false end
  local ok2, a = pcall(lx.screen.appearance)
  return ok2 and a == "dark"
end

function M.apply(mode, accent)
  M.mode = mode or M.mode
  M.accent = (accent and ACCENTS[accent]) and accent or M.accent
  local dark = M.mode == "dark" or M.mode == "oled" or (M.mode == "system" and systemDark())
  M.isDark = dark
  local base = (M.mode == "oled") and OLED or (dark and DARK or BASE)
  for k, v in pairs(base) do M[k] = v end
  local a = ACCENTS[M.accent][dark and "dark" or "light"]
  M.brand, M.brandStrong, M.brandTint, M.brandLine, M.ring1, M.ring2, M.ring3 = a[1], a[2], a[3], a[4], a[5], a[6], a[7]
  return M
end

--- 某个强调色的主色（设置里画色块用）
function M.swatch(accent) return ACCENTS[accent].light[1] end

M.apply("light", "red")
return M
