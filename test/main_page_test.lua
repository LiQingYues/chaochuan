-- 主框架冒烟测试（不起网络服务）：桌面 / 移动两种布局下四个标签能渲染；发送 / 接收请求 / 链接分享的界面流程能走通。
-- 传输核心本身的协议测试在 tools/selftest.sh（headless --net，真实 socket）。
local lx = require("lx")
local t = lx.test
local layout = require("theme.layout")

local function fresh(desktop)
  layout.force = desktop
  for name in pairs(package.loaded) do
    if name:match("^core%.") or name:match("^modules%.") or name:match("^components%.") then package.loaded[name] = nil end
  end
  local store = require("core.store")
  local service = require("core.localsend.service")
  -- 假设备 + 假发送（按定时器推进进度）
  service.devices = { fp1 = { fingerprint = "fp1", alias = "测试手机", deviceModel = "Phone", deviceType = "mobile", ip = "10.0.0.2", port = 53317, protocol = "http" } }
  service.hooks.onDevices()
  service.send = function(_, items, cb)
    local total = 0
    for _, it in ipairs(items) do total = total + (it.size or 0) end
    local tf = {}
    for _, it in ipairs(items) do tf[#tf + 1] = { name = it.name, size = it.size or 0, sent = it.size or 0, state = "done" } end
    lx.timer.setTimeout(function() cb.onProgress({ files = tf, total = total, sent = total }); cb.onDone(true) end, 500)
    return { cancel = function() cb.onDone(false, "cancelled") end }
  end
  return store, require("modules.main.main_page"), service
end

for _, desktop in ipairs({ false, true }) do
  local label = desktop and "桌面" or "移动"
  describe(label .. "布局", function()
    it("四个标签都能渲染", function()
      local store, MainPage = fresh(desktop)
      local screen = t.mount(MainPage)
      for _, tab in ipairs({ "receive", "send", "history", "settings" }) do
        store.set({ tab = tab })
        t.settle()
      end
      expect(#screen:getAllByText("设置") >= 1).toBe(true)
    end)

    it("选设备发送，完成", function()
      local store, MainPage = fresh(desktop)
      local screen = t.mount(MainPage)
      store.state.selection = { { name = "a.txt", size = 10, ext = "TXT", tint = "#000000", path = "/tmp/a.txt" } }
      store.set({ tab = "send", autoClose = false })
      t.settle()
      screen:getByTestID("device-fp1"):tap()
      expect(store.state.transfer).toBeDefined()
      t.advance(1000)
      expect(store.state.transfer.done).toBe(true)
      expect(screen:getByText("完成")).toBeDefined()
    end)

    it("收到请求，取消一个文件后接收", function()
      local store, MainPage, service = fresh(desktop)
      local screen = t.mount(MainPage)
      local accepted
      service.hooks.onIncoming({ peer = { alias = "对方", deviceModel = "Mac", deviceType = "desktop", ip = "10.0.0.3", fingerprint = "fp9" },
        files = { { id = "1", fileName = "a.txt", size = 3 }, { id = "2", fileName = "b.txt", size = 4 } } },
        function(ids) accepted = ids end)
      t.settle()
      screen:getByTestID("incoming-file-2"):tap()
      screen:getByTestID("accept"):tap()
      expect(store.state.incoming).toBeNil()
      expect(#accepted).toBe(1)
      expect(accepted[1]).toBe("1")
    end)

    it("链接分享页能打开和关闭", function()
      local store, MainPage = fresh(desktop)
      local screen = t.mount(MainPage)
      store.state.selection = { { name = "a.txt", size = 10, ext = "TXT", tint = "#000000", path = "/tmp/a.txt" } }
      store.startShareLink()
      t.settle()
      expect(screen:getByText("停止分享")).toBeDefined()
      screen:getByText("停止分享"):tap()
      expect(store.state.shareLink).toBeNil()
    end)
  end)
end

describe("文本消息浮卡", function()
  for _, desktop in ipairs({ false, true }) do
    it((desktop and "桌面" or "移动") .. "：点 × 能关闭", function()
      layout.force = desktop
      for name in pairs(package.loaded) do
        if name:match("^core%.") or name:match("^modules%.") or name:match("^components%.") then package.loaded[name] = nil end
      end
      local store = require("core.store")
      local screen = t.mount(require("modules.main.main_page"))
      store.set({ textMessage = { from = "手机", text = "hello" } })
      t.settle()
      screen:getByTestID("text-toast-close"):tap()
      expect(store.state.textMessage).toBeNil()
      expect(screen:queryByText("hello")).toBeNil()
    end)
  end
end)

-- ---------------------------------------------------------------- 新功能
local function freshWith(desktop)
  local store, MainPage, service = fresh(desktop)
  service.devices.fp2 = { fingerprint = "fp2", alias = "测试电脑", deviceModel = "PC", deviceType = "desktop", ip = "10.0.0.3", port = 53317, protocol = "http" }
  service.hooks.onDevices()
  return store, MainPage, service
end

for _, desktop in ipairs({ false, true }) do
  local label = desktop and "桌面" or "移动"
  describe(label .. "：完善后的功能", function()
    it("传输中返回 = 收起，状态条点回进度页", function()
      local store, MainPage, service = freshWith(desktop)
      local finish
      service.send = function(_, _, cb) finish = cb; return { cancel = function() cb.onDone(false, "cancelled") end } end
      local screen = t.mount(MainPage)
      store.state.selection = { { name = "a.txt", size = 10, ext = "TXT", tint = "#000000", path = "/tmp/a.txt" } }
      store.set({ tab = "send" })
      t.settle()
      screen:getByTestID("device-fp1"):tap()
      t.settle()
      screen:getByTestID("transfer-back"):tap()
      expect(store.state.transfer.hidden).toBe(true)
      expect(screen:getByTestID("transfer-strip")).toBeDefined()
      screen:getByTestID("transfer-strip"):tap()
      expect(store.state.transfer.hidden).toBe(false)
      finish.onProgress({ files = { { name = "a.txt", size = 10, sent = 10, state = "done" } }, total = 10, sent = 10 })
      finish.onDone(true)
      t.settle()
      expect(store.state.transfer.done).toBe(true)
    end)

    it("多设备：勾选两台依次发送", function()
      local store, MainPage, service = freshWith(desktop)
      local targets = {}
      service.send = function(d, _, cb)
        targets[#targets + 1] = d.alias
        lx.timer.setTimeout(function() cb.onDone(true) end, 100)
        return { cancel = function() end }
      end
      local screen = t.mount(MainPage)
      store.state.selection = { { name = "a.txt", size = 10, ext = "TXT", tint = "#000000", path = "/tmp/a.txt" } }
      store.set({ tab = "send", sendMode = 2 })
      t.settle()
      screen:getByTestID("device-fp1"):tap()
      screen:getByTestID("device-fp2"):tap()
      expect(store.multiTargetCount()).toBe(2)
      screen:getByTestID("send-multi"):tap()
      t.advance(3000)
      expect(#targets).toBe(2)
      t.advance(10000)   -- 把「完成后自动关闭」等定时器在本用例里跑完，不留给下一个用例
    end)

    it("已选内容可以逐个删除", function()
      local store, MainPage = freshWith(desktop)
      local screen = t.mount(MainPage)
      store.state.selection = { { name = "a.txt", size = 1, ext = "TXT", tint = "#000000", path = "/a" }, { name = "b.txt", size = 1, ext = "TXT", tint = "#000000", path = "/b" } }
      store.set({ tab = "send" })
      t.settle()
      screen:getByTestID("remove-1"):tap()
      expect(#store.state.selection).toBe(1)
      expect(store.state.selection[1].name).toBe("b.txt")
    end)

    it("星标收藏 + 只看收藏", function()
      local store, MainPage = freshWith(desktop)
      local screen = t.mount(MainPage)
      store.set({ tab = "send" })
      t.settle()
      screen:getByTestID("fav-fp2"):tap()
      expect(store.prefs.favorites.fp2).toBe(true)
      store.toggleOnlyFavorites()
      t.settle()
      expect(#store.visibleDevices()).toBe(1)
      store.toggleFavorite("fp2")
    end)

    it("设置 › 其它：四个子页面能打开、能返回", function()
      local store, MainPage = freshWith(desktop)
      local screen = t.mount(MainPage)
      store.set({ tab = "settings" })
      t.settle()
      for _, id in ipairs({ "troubleshoot", "licenses", "privacy", "about" }) do
        screen:getByTestID("page-" .. id):tap()
        expect(store.state.page).toBe(id)
        screen:getByTestID("page-back"):tap()
        expect(store.state.page).toBeNil()
      end
    end)

    it("深色 / OLED / 英文都能渲染四个标签", function()
      local store, MainPage = freshWith(desktop)
      local screen = t.mount(MainPage)
      for _, theme in ipairs({ "dark", "oled", "light" }) do
        store.setTheme(theme)
        store.setLanguage(theme == "light" and "zh" or "en")
        for _, tab in ipairs({ "receive", "send", "history", "settings" }) do
          store.set({ tab = tab })
          t.settle()
        end
      end
      store.setLanguage("en")
      store.set({ tab = "settings" })
      t.settle()
      expect(#screen:getAllByText("Settings") >= 1).toBe(true)
      store.setLanguage("system"); store.setTheme("system")
    end)

    it("记录：打开 / 文件夹按钮调用宿主", function()
      local store, MainPage = freshWith(desktop)
      local host = require("core.host")
      local opened = {}
      host.available = function() return true end
      host.openPath = function(p, reveal, cb) opened[#opened + 1] = { p, reveal }; if cb then cb(true) end end
      local dir = lx.fs.join(lx.fs.paths.temp, "hist_test")
      lx.fs.write(lx.fs.join(dir, "x.txt"), "x")
      store.prefs.history = { { dir = "in", ts = os.time(), peer = "对方", total = 1, files = { { name = "x.txt", size = 1, path = lx.fs.join(dir, "x.txt") } } } }
      store.prefs.saveHistory = true
      store.loadHistory()
      local screen = t.mount(MainPage)
      store.set({ tab = "history" })
      t.settle()
      if desktop then
        screen:getByTestID("history-open-1"):tap()
        screen:getByTestID("history-reveal-1"):tap()
        expect(#opened).toBe(2)
        expect(opened[2][2]).toBe(true)
      else
        screen:getByTestID("history-1"):tap()
        expect(#opened).toBe(1)
      end
      lx.fs.remove(dir)
      store.prefs.history = {}
    end)
  end)
end

describe("设置项真正生效", function()
  it("端口 / 设备型号 / 设备类型 / 发现超时", function()
    local store = fresh(true)
    local P = require("core.localsend.protocol")
    local service = require("core.localsend.service")
    store.setDeviceModel("我的测试机")
    expect(P.deviceModel()).toBe("我的测试机")
    store.setDeviceType("server")
    expect(P.info(53317, "https", true).deviceType).toBe("server")
    store.setDiscoveryTimeout(2000)
    expect(service.config.discoveryTimeout).toBe(2000)
    store.setPort("80")
    expect(store.state.port).toBe(53317)
    store.setDeviceModel(""); store.setDeviceType(nil)
  end)
end)
