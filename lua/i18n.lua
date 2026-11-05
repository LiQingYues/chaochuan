-- 多语言：t("中文原文", ...) → 当前语言的文字（带参数时按 string.format 填）。
-- 以中文原文为键：中文界面直接用原文；英文查 EN 表，没有翻译时退回中文（并在 Debug 下记一次日志，方便补漏）。
--   require("i18n").set("en") / .lang / .LANGS
local M = {}

M.LANGS = { { code = "zh", name = "简体中文" }, { code = "en", name = "English" } }
M.lang = "zh"

local EN = require("i18n_en")
local missing = {}

function M.set(code)
  M.lang = (code == "en") and "en" or "zh"
end

--- 跟随系统：系统语言是中文用中文，否则英文
function M.systemLang()
  local ok, lx = pcall(require, "lx")
  local loc = ok and lx.device and lx.device.locale and lx.device.locale.language or "zh"
  return tostring(loc):lower():find("^zh") and "zh" or "en"
end

local function translate(s)
  if M.lang ~= "en" then return s end
  local e = EN[s]
  if e then return e end
  if not missing[s] then
    missing[s] = true
    local ok, lx = pcall(require, "lx")
    if ok and lx.hot and lx.hot.enabled then lx.log.warn("[i18n] 缺少英文：" .. s) end
  end
  return s
end

setmetatable(M, { __call = function(_, s, ...)
  local out = translate(s)
  if select("#", ...) > 0 then return string.format(out, ...) end
  return out
end })

return M
