-- 线性图标：24×24 网格、圆角描边，用 lx.Canvas 画（各平台一致，不依赖 SF Symbols / 位图）。
--   Icon { name = "send", size = 20, color = "#D62839", stroke = 1.8, fill = false }
-- 图标定义：path（SVG 子集：M m L l H h V v Z z）、circle、rrect、arc、ellipse、dot（实心小圆）
local lx = require("lx")

local pi = math.pi

local ICONS = {
  logo = { { "path", "M5 6l6 6-6 6M12 6l6 6-6 6" } },
  receive = { { "path", "M12 3v12M7 10l5 5 5-5M4 20h16" } },
  send = { { "path", "M21 3L10 14" }, { "path", "M21 3l-7 18-4-7-7-4z" } },
  history = { { "circle", 12, 12, 9 }, { "path", "M12 7v5l3 3" } },
  settings = { { "path", "M4 6h9M17 6h3M4 12h3M11 12h9M4 18h11M19 18h1" },
               { "circle", 15, 6, 2 }, { "circle", 9, 12, 2 }, { "circle", 17, 18, 2 } },
  file = { { "path", "M14 3H6v18h12V9zM14 3v6h6" } },
  folder = { { "path", "M3 6h6l2 2h10v11H3z" } },
  image = { { "rrect", 3, 3, 18, 18, 3 }, { "circle", 9, 9, 2 }, { "path", "M21 15l-5-5L5 21" } },
  text = { { "path", "M5 7V5h14v2M9 19h6M12 5v14" } },
  paste = { { "rrect", 8, 2, 8, 4, 1 }, { "path", "M16 4h3v18H5V4h3" } },
  laptop = { { "rrect", 4, 5, 16, 11, 1.5 }, { "path", "M2 19h20" } },
  phone = { { "rrect", 7, 2, 10, 20, 2 }, { "path", "M11 18h2" } },
  monitor = { { "rrect", 3, 4, 18, 12, 1.5 }, { "path", "M8 20h8M12 16v4" } },
  globe = { { "circle", 12, 12, 9 }, { "ellipse", 12, 12, 4, 9 }, { "path", "M3 12h18" } },
  star = { { "path", "M12 3l2.8 5.7 6.2.9-4.5 4.4 1 6.2L12 17.3 6.5 20.2l1-6.2L3 9.6l6.2-.9z" } },
  refresh = { { "arc", 12, 12, 8, pi * 0.05, pi * 1.75 }, { "path", "M20 4v6h-6" } },
  plus = { { "path", "M12 5v14M5 12h14" } },
  qr = { { "rrect", 3, 3, 7, 7, 1 }, { "rrect", 14, 3, 7, 7, 1 }, { "rrect", 3, 14, 7, 7, 1 },
         { "path", "M14 14h3v3h-3zM17 21h4v-4" } },
  scan = { { "path", "M4 8V4h4M16 4h4v4M20 16v4h-4M8 20H4v-4M4 12h16" } },
  close = { { "path", "M6 6l12 12M18 6L6 18" } },
  check = { { "path", "M5 12l5 5 9-10" } },
  lock = { { "rrect", 5, 11, 14, 10, 2 }, { "path", "M8 11V8M16 8v3" }, { "arc", 12, 8, 4, pi, pi * 2 } },
  wifi = { { "arc", 12, 20, 15, pi * 1.27, pi * 1.73 }, { "arc", 12, 20, 10, pi * 1.27, pi * 1.73 },
           { "arc", 12, 20, 5, pi * 1.27, pi * 1.73 }, { "dot", 12, 19.5, 1.2 } },
  chevronRight = { { "path", "M9 6l6 6-6 6" } },
  chevronLeft = { { "path", "M15 6l-6 6 6 6" } },
  chevronDown = { { "path", "M6 9l6 6 6-6" } },
  edit = { { "path", "M4 20h4L19 9l-4-4L4 16z" } },
  trash = { { "path", "M4 7h16M9 7V4h6v3M6 7l1 13h10l1-13" } },
  search = { { "circle", 11, 11, 7 }, { "path", "M20 20l-4-4" } },
  outgoing = { { "path", "M7 17L17 7M9 7h8v8" } },
  incoming = { { "path", "M17 7L7 17M15 17H7V9" } },
  link = { { "path", "M10 14l4-4" }, { "arc", 16.5, 7.5, 3.5, pi * 0.75, pi * 1.75 + pi * 0.5 },
           { "arc", 7.5, 16.5, 3.5, pi * -0.25, pi * 0.75 + pi * 0.5 } },
}

-- 把 "M5 6l6 6-6 6" 拆成 { "M", 5, 6, "l", 6, 6, -6, 6 }
local function tokenize(d)
  local out, i, n = {}, 1, #d
  while i <= n do
    local c = d:sub(i, i)
    if c:match("%a") then
      out[#out + 1] = c; i = i + 1
    elseif c:match("[%s,]") then
      i = i + 1
    else
      local s, e = d:find("^%-?%d*%.?%d+", i)
      if not s then error("icon path: 无法解析 " .. d:sub(i)) end
      out[#out + 1] = tonumber(d:sub(s, e)); i = e + 1
    end
  end
  return out
end

local parsed = {}
local function tracePath(ctx, d, k)
  local toks = parsed[d]
  if not toks then toks = tokenize(d); parsed[d] = toks end
  local x, y, sx, sy, cmd = 0, 0, 0, 0, nil
  local i = 1
  local function num() local v = toks[i]; i = i + 1; return v end
  while i <= #toks do
    if type(toks[i]) == "string" then cmd = toks[i]; i = i + 1 end
    if cmd == "M" or cmd == "m" then
      local a, b = num(), num()
      if cmd == "m" then a, b = x + a, y + b end
      x, y, sx, sy = a, b, a, b
      ctx:moveTo(x * k, y * k)
      cmd = (cmd == "m") and "l" or "L"   -- 后续坐标对按 lineTo
    elseif cmd == "L" or cmd == "l" then
      local a, b = num(), num()
      if cmd == "l" then a, b = x + a, y + b end
      x, y = a, b; ctx:lineTo(x * k, y * k)
    elseif cmd == "H" or cmd == "h" then
      local a = num(); x = (cmd == "h") and x + a or a; ctx:lineTo(x * k, y * k)
    elseif cmd == "V" or cmd == "v" then
      local b = num(); y = (cmd == "v") and y + b or b; ctx:lineTo(x * k, y * k)
    elseif cmd == "Z" or cmd == "z" then
      ctx:closePath(); x, y = sx, sy
    else
      error("icon path: 不支持的命令 " .. tostring(cmd))
    end
  end
end

local function draw(ctx, name, w, color, stroke, fill)
  local def = ICONS[name] or ICONS.file
  local k = w / 24
  ctx.strokeStyle = color
  ctx.fillStyle = color
  ctx.lineWidth = stroke * k
  ctx.lineCap = "round"
  ctx.lineJoin = "round"
  for _, op in ipairs(def) do
    local kind = op[1]
    ctx:beginPath()
    if kind == "path" then
      tracePath(ctx, op[2], k)
    elseif kind == "circle" then
      ctx:arc(op[2] * k, op[3] * k, op[4] * k, 0, pi * 2)
    elseif kind == "dot" then
      ctx:arc(op[2] * k, op[3] * k, op[4] * k, 0, pi * 2); ctx:fill()
    elseif kind == "rrect" then
      ctx:roundRect(op[2] * k, op[3] * k, op[4] * k, op[5] * k, op[6] * k)
    elseif kind == "arc" then
      ctx:arc(op[2] * k, op[3] * k, op[4] * k, op[5], op[6])
    elseif kind == "ellipse" then
      ctx:ellipse(op[2] * k, op[3] * k, op[4] * k, op[5] * k, 0, 0, pi * 2)
    end
    if kind ~= "dot" then
      if fill then ctx:fill() end
      ctx:stroke()
    end
  end
end

local Icon = lx.component(function(props)
  local size = props.size or 20
  local name, color = props.name, props.color or "#1A1718"
  local stroke, fill = props.stroke or 1.8, props.fill == true
  -- 图标只负责画，点击交给外层：画布会吃掉触摸，所以外面包一层 pointerEvents = "none" 的 View，整块不参与命中测试
  return lx.View { pointerEvents = "none", style = { width = size, height = size, flexShrink = 0 },
    lx.Canvas {
      pointerEvents = "none",
      style = { width = size, height = size },
      deps = { name, color, stroke, fill, size },
      onDraw = function(ctx, w) draw(ctx, name, w, color, stroke, fill) end,
    } }
end, "Icon")

return Icon
