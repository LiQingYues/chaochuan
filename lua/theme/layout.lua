-- 桌面版 / 移动版判定：macOS、Windows（以及宽屏 Web）走桌面布局（侧边栏），iOS / Android 走移动布局（底部标签栏）
local lx = require("lx")

local M = {}

M.force = nil   -- 测试用：true / false 强制桌面 / 移动布局

function M.isDesktop()
  if M.force ~= nil then return M.force end
  local p = lx.device.platform
  if p == "macos" or p == "windows" then return true end
  if p == "web" then
    local ok, size = pcall(lx.screen.size)
    return ok and size and size.width >= 900 or false
  end
  return false
end

M.FONT_MONO = (lx.device.platform == "windows") and "Consolas" or "Menlo"

return M
