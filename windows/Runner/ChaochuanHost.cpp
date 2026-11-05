// 超传宿主原生能力（Windows），契约见 docs/native_host.md：
//   pickFiles / pickDirectory   IFileOpenDialog（主窗口为 owner），异步
//   openPath                    ShellExecuteW(open) / SHOpenFolderAndSelectItems（reveal），异步
//   takeIncomingFiles + 事件 incomingFiles
//                               待取队列：命令行参数、拖进主窗口（XAML 根元素 AllowDrop + StorageItems）、
//                               单实例转交（第二个进程把路径用 WM_COPYDATA 发给已运行实例的隐藏窗口）
//   interfaces                  GetAdaptersAddresses：已连接的 IPv4，跳过回环 / 隧道 / PPP / 虚拟网卡，有网关、Wi‑Fi / 以太网排前
//   setCloseToTray              Shell_NotifyIcon 托盘图标；开启时关闭主窗口只隐藏（AppWindow.Closing 取消）
//   showWindow / hideWindow
//   setLaunchAtLogin / getLaunchAtLogin   HKCU\...\Run 的 chaochuan 值
//   setContextMenu              HKCU\Software\Classes\*\shell\chaochuan 和 Directory\shell\chaochuan
// 进程级状态（队列、托盘、窗口钩子）放在本文件的静态变量里：引擎重载会重建模块，但这些要一直保留。
#include "pch.h"

#include <iphlpapi.h>
#include <shobjidl.h>
#include <winrt/Windows.Storage.h>

#include "AppHost.h"
#include "ChaochuanHost.h"
#include "LXEngine.h"
#include "LXLog.h"

namespace chaochuan {

namespace {

using namespace lxwin;

constexpr wchar_t kMutexName[] = L"Local\\chaochuan.single-instance.6f1c2a";
constexpr wchar_t kHiddenWindowClass[] = L"ChaochuanHostWindow";
constexpr ULONG_PTR kCopyDataPaths = 0x43484331;   // 'CHC1'
constexpr UINT kTrayMessage = WM_APP + 1;
constexpr UINT kTrayId = 1;
constexpr UINT kMenuShow = 1001;
constexpr UINT kMenuQuit = 1002;
constexpr wchar_t kRunKey[] = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
constexpr wchar_t kRunValue[] = L"chaochuan";
constexpr wchar_t kFileMenuKey[] = L"Software\\Classes\\*\\shell\\chaochuan";
constexpr wchar_t kDirMenuKey[] = L"Software\\Classes\\Directory\\shell\\chaochuan";

HANDLE g_mutex = nullptr;
HWND g_hidden = nullptr;
UINT g_taskbarCreated = 0;
std::vector<std::string> g_incoming;   // 待取文件（UTF-8 绝对路径）
bool g_trayEnabled = false;
bool g_trayAdded = false;
bool g_quitting = false;
bool g_wantHidden = false;
bool g_windowHooked = false;

class HostModule;
HostModule* g_module = nullptr;   // 当前引擎里的模块（引擎重载后换成新的）

// ---------------------------------------------------------------- 工具

std::wstring ExePath() {
    std::wstring buf(MAX_PATH, L'\0');
    for (;;) {
        DWORD n = GetModuleFileNameW(nullptr, buf.data(), (DWORD)buf.size());
        if (n == 0) return {};
        if (n < buf.size()) {
            buf.resize(n);
            return buf;
        }
        buf.resize(buf.size() * 2);
    }
}

std::wstring FullPath(std::wstring const& path) {
    DWORD n = GetFullPathNameW(path.c_str(), 0, nullptr, nullptr);
    if (n == 0) return path;
    std::wstring out(n, L'\0');
    n = GetFullPathNameW(path.c_str(), n, out.data(), nullptr);
    out.resize(n);
    return out;
}

bool PathExists(std::wstring const& path) {
    return GetFileAttributesW(path.c_str()) != INVALID_FILE_ATTRIBUTES;
}

/// 命令行里的文件 / 文件夹路径（跳过 exe 本身、URL、不存在的参数）
std::vector<std::wstring> CommandLinePaths() {
    std::vector<std::wstring> out;
    int argc = 0;
    LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    for (int i = 1; argv && i < argc; i++) {
        std::wstring arg = argv[i];
        if (arg.empty() || arg.find(L"://") != std::wstring::npos) continue;
        std::wstring full = FullPath(arg);
        if (PathExists(full)) out.push_back(full);
    }
    if (argv) LocalFree(argv);
    return out;
}

void Emit(std::string const& event, Fields const& payload);

void Enqueue(std::vector<std::wstring> const& paths) {
    if (paths.empty()) return;
    for (auto const& p : paths) g_incoming.push_back(Narrow(p));
    Emit("incomingFiles", Fields().Num("count", (double)g_incoming.size()));
}

HWND MainHwnd() {
    auto* host = AppHost::Current();
    return host ? host->Hwnd() : nullptr;
}

void ShowMainWindow() {
    g_wantHidden = false;
    HWND hwnd = MainHwnd();
    if (!hwnd) return;
    if (auto* host = AppHost::Current()) {
        try {
            host->Window().AppWindow().Show();
        } catch (...) {
        }
    }
    ShowWindow(hwnd, IsIconic(hwnd) ? SW_RESTORE : SW_SHOW);
    SetForegroundWindow(hwnd);
}

void HideMainWindow() {
    HWND hwnd = MainHwnd();
    if (!hwnd) return;
    if (auto* host = AppHost::Current()) {
        try {
            host->Window().AppWindow().Hide();
            return;
        } catch (...) {
        }
    }
    ShowWindow(hwnd, SW_HIDE);
}

// ---------------------------------------------------------------- 托盘

void AddTrayIcon() {
    if (g_trayAdded || !g_hidden) return;
    NOTIFYICONDATAW nid{};
    nid.cbSize = sizeof(nid);
    nid.hWnd = g_hidden;
    nid.uID = kTrayId;
    nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
    nid.uCallbackMessage = kTrayMessage;
    nid.hIcon = (HICON)LoadImageW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(1), IMAGE_ICON, GetSystemMetrics(SM_CXSMICON),
                                  GetSystemMetrics(SM_CYSMICON), LR_DEFAULTCOLOR);
    if (!nid.hIcon) nid.hIcon = LoadIconW(nullptr, IDI_APPLICATION);
    wcsncpy_s(nid.szTip, L"超传", _TRUNCATE);
    g_trayAdded = Shell_NotifyIconW(NIM_ADD, &nid) != FALSE;
    if (!g_trayAdded) LogWarn("托盘图标添加失败");
}

void RemoveTrayIcon() {
    if (!g_trayAdded) return;
    NOTIFYICONDATAW nid{};
    nid.cbSize = sizeof(nid);
    nid.hWnd = g_hidden;
    nid.uID = kTrayId;
    Shell_NotifyIconW(NIM_DELETE, &nid);
    g_trayAdded = false;
}

void QuitApp() {
    g_quitting = true;
    RemoveTrayIcon();
    if (auto* host = AppHost::Current()) {
        try {
            host->Window().Close();
        } catch (...) {
        }
    }
    try {
        mux::Application::Current().Exit();
    } catch (...) {
    }
}

void ShowTrayMenu() {
    HMENU menu = CreatePopupMenu();
    AppendMenuW(menu, MF_STRING, kMenuShow, L"显示超传");
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(menu, MF_STRING, kMenuQuit, L"退出超传");
    SetMenuDefaultItem(menu, kMenuShow, FALSE);
    POINT pt;
    GetCursorPos(&pt);
    SetForegroundWindow(g_hidden);   // 否则点菜单外面菜单不会消失
    UINT cmd = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_NONOTIFY, pt.x, pt.y, 0, g_hidden, nullptr);
    PostMessageW(g_hidden, WM_NULL, 0, 0);
    DestroyMenu(menu);
    if (cmd == kMenuShow) ShowMainWindow();
    else if (cmd == kMenuQuit) QuitApp();
}

// ---------------------------------------------------------------- 隐藏窗口（单实例转交 + 托盘回调）

LRESULT CALLBACK HiddenWndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    if (msg == WM_COPYDATA) {
        auto* cds = reinterpret_cast<COPYDATASTRUCT const*>(lParam);
        if (cds && cds->dwData == kCopyDataPaths) {
            std::wstring text(static_cast<wchar_t const*>(cds->lpData), cds->cbData / sizeof(wchar_t));
            std::vector<std::wstring> paths;
            size_t start = 0;
            while (start <= text.size()) {
                size_t end = text.find(L'\n', start);
                if (end == std::wstring::npos) end = text.size();
                if (end > start) paths.push_back(text.substr(start, end - start));
                start = end + 1;
            }
            // 不在 SendMessage 里做重活（发送方在等）：投递回 UI 线程的消息队列
            auto* heap = new std::vector<std::wstring>(std::move(paths));
            PostMessageW(hwnd, WM_APP + 2, 0, reinterpret_cast<LPARAM>(heap));
            return TRUE;
        }
        return FALSE;
    }
    if (msg == WM_APP + 2) {
        std::unique_ptr<std::vector<std::wstring>> paths(reinterpret_cast<std::vector<std::wstring>*>(lParam));
        ShowMainWindow();
        Enqueue(*paths);
        return 0;
    }
    if (msg == kTrayMessage) {
        switch (LOWORD(lParam)) {
            case WM_LBUTTONUP:
            case WM_LBUTTONDBLCLK:
                ShowMainWindow();
                break;
            case WM_RBUTTONUP:
            case WM_CONTEXTMENU:
                ShowTrayMenu();
                break;
        }
        return 0;
    }
    if (g_taskbarCreated && msg == g_taskbarCreated) {
        // 资源管理器重启后托盘图标要重新加
        g_trayAdded = false;
        if (g_trayEnabled) AddTrayIcon();
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

void CreateHiddenWindow() {
    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = HiddenWndProc;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.lpszClassName = kHiddenWindowClass;
    RegisterClassExW(&wc);
    // 普通的隐藏顶层窗口（不是 HWND_MESSAGE）：托盘菜单需要它能成为前台窗口，第二个进程用 FindWindow 找它
    g_hidden = CreateWindowExW(WS_EX_TOOLWINDOW, kHiddenWindowClass, L"chaochuan", WS_POPUP, 0, 0, 0, 0, nullptr, nullptr,
                               wc.hInstance, nullptr);
    g_taskbarCreated = RegisterWindowMessageW(L"TaskbarCreated");
}

/// 把路径交给已运行的实例（等它的隐藏窗口出现，最多约 10 秒）
void ForwardToRunningInstance(std::vector<std::wstring> const& paths) {
    HWND target = nullptr;
    for (int i = 0; i < 100 && !target; i++) {
        target = FindWindowW(kHiddenWindowClass, nullptr);
        if (!target) Sleep(100);
    }
    if (!target) return;
    DWORD pid = 0;
    GetWindowThreadProcessId(target, &pid);
    if (pid) AllowSetForegroundWindow(pid);   // 让它能把主窗口带到前台
    std::wstring text;
    for (auto const& p : paths) {
        if (!text.empty()) text += L'\n';
        text += p;
    }
    COPYDATASTRUCT cds{};
    cds.dwData = kCopyDataPaths;
    cds.cbData = (DWORD)(text.size() * sizeof(wchar_t));
    cds.lpData = text.empty() ? nullptr : text.data();
    DWORD_PTR result = 0;
    SendMessageTimeoutW(target, WM_COPYDATA, 0, reinterpret_cast<LPARAM>(&cds), SMTO_ABORTIFHUNG, 10000, &result);
}

// ---------------------------------------------------------------- 主窗口钩子（关闭到托盘、拖拽）

winrt::fire_and_forget HandleDrop(mux::DragEventArgs args) {
    auto deferral = args.GetDeferral();
    auto queue = mud::DispatcherQueue::GetForCurrentThread();
    std::vector<std::wstring> paths;
    try {
        auto view = args.DataView();
        if (view.Contains(winrt::Windows::ApplicationModel::DataTransfer::StandardDataFormats::StorageItems())) {
            auto items = co_await view.GetStorageItemsAsync();
            for (auto const& item : items) {
                auto p = item.Path();
                if (!p.empty()) paths.emplace_back(p.c_str(), p.size());
            }
        }
    } catch (...) {
        LogWarn("读取拖入的文件失败");
    }
    deferral.Complete();
    if (paths.empty()) co_return;
    queue.TryEnqueue([paths = std::move(paths)] { Enqueue(paths); });
}

void HookMainWindow() {
    if (g_windowHooked) return;
    auto* host = AppHost::Current();
    if (!host || !host->Window()) return;
    g_windowHooked = true;
    auto window = host->Window();

    window.AppWindow().Closing([](mu::Windowing::AppWindow const& sender, mu::Windowing::AppWindowClosingEventArgs const& args) {
        if (g_trayEnabled && !g_quitting) {
            args.Cancel(true);
            sender.Hide();
        }
    });
    window.Closed([](auto const&, auto const&) { RemoveTrayIcon(); });

    // 拖拽：根元素接收（子元素处理过的事件也要，handledEventsToo）；没有背景时空白处收不到拖拽，补透明背景（Mica 照样透出）
    auto root = host->Root().try_as<muxc::Panel>();
    if (!root) return;
    if (!root.Background()) root.Background(muxm::SolidColorBrush(mu::Colors::Transparent()));
    root.AllowDrop(true);
    root.AddHandler(mux::UIElement::DragOverEvent(), winrt::box_value(mux::DragEventHandler([](auto const&, mux::DragEventArgs const& args) {
                        using winrt::Windows::ApplicationModel::DataTransfer::DataPackageOperation;
                        using winrt::Windows::ApplicationModel::DataTransfer::StandardDataFormats;
                        if (args.DataView().Contains(StandardDataFormats::StorageItems())) {
                            args.AcceptedOperation(DataPackageOperation::Copy);
                            args.DragUIOverride().Caption(L"用超传发送");
                            args.Handled(true);
                        }
                    })),
                    true);
    root.AddHandler(mux::UIElement::DropEvent(), winrt::box_value(mux::DragEventHandler([](auto const&, mux::DragEventArgs const& args) {
                        args.Handled(true);
                        HandleDrop(args);
                    })),
                    true);
}

// ---------------------------------------------------------------- 注册表

bool RegSetString(HKEY root, std::wstring const& key, wchar_t const* name, std::wstring const& value) {
    HKEY h = nullptr;
    if (RegCreateKeyExW(root, key.c_str(), 0, nullptr, 0, KEY_SET_VALUE, nullptr, &h, nullptr) != ERROR_SUCCESS) return false;
    LSTATUS st = RegSetValueExW(h, name, 0, REG_SZ, reinterpret_cast<BYTE const*>(value.c_str()),
                                (DWORD)((value.size() + 1) * sizeof(wchar_t)));
    RegCloseKey(h);
    return st == ERROR_SUCCESS;
}

std::optional<std::wstring> RegGetString(HKEY root, wchar_t const* key, wchar_t const* name) {
    DWORD size = 0;
    if (RegGetValueW(root, key, name, RRF_RT_REG_SZ, nullptr, nullptr, &size) != ERROR_SUCCESS) return std::nullopt;
    std::wstring out(size / sizeof(wchar_t), L'\0');
    if (RegGetValueW(root, key, name, RRF_RT_REG_SZ, nullptr, out.data(), &size) != ERROR_SUCCESS) return std::nullopt;
    out.resize(wcsnlen(out.c_str(), out.size()));
    return out;
}

std::wstring Quoted(std::wstring const& s) {
    return L"\"" + s + L"\"";
}

bool SetContextMenu(bool enabled) {
    std::wstring exe = ExePath();
    bool ok = true;
    for (auto key : {kFileMenuKey, kDirMenuKey}) {
        if (enabled) {
            ok = RegSetString(HKEY_CURRENT_USER, key, L"MUIVerb", L"用超传发送") && ok;
            ok = RegSetString(HKEY_CURRENT_USER, key, L"Icon", Quoted(exe)) && ok;
            ok = RegSetString(HKEY_CURRENT_USER, std::wstring(key) + L"\\command", nullptr, Quoted(exe) + L" \"%1\"") && ok;
        } else {
            LSTATUS st = RegDeleteTreeW(HKEY_CURRENT_USER, key);
            if (st == ERROR_SUCCESS) RegDeleteKeyW(HKEY_CURRENT_USER, key);
            ok = (st == ERROR_SUCCESS || st == ERROR_FILE_NOT_FOUND) && ok;
        }
    }
    SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST, nullptr, nullptr);
    return ok;
}

// ---------------------------------------------------------------- 文件选择 / 打开

std::vector<std::string> PickPaths(bool folder, bool multiple) {
    std::vector<std::string> out;
    winrt::com_ptr<IFileOpenDialog> dialog;
    if (FAILED(CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(dialog.put())))) return out;
    FILEOPENDIALOGOPTIONS options = 0;
    dialog->GetOptions(&options);
    options |= FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST | FOS_FILEMUSTEXIST | FOS_NOCHANGEDIR;
    if (folder) options |= FOS_PICKFOLDERS;
    if (multiple) options |= FOS_ALLOWMULTISELECT;
    dialog->SetOptions(options);
    dialog->SetTitle(folder ? L"选择文件夹" : L"选择文件");
    if (dialog->Show(MainHwnd()) != S_OK) return out;   // 取消：HRESULT_FROM_WIN32(ERROR_CANCELLED)
    winrt::com_ptr<IShellItemArray> items;
    if (FAILED(dialog->GetResults(items.put())) || !items) return out;
    DWORD count = 0;
    items->GetCount(&count);
    for (DWORD i = 0; i < count; i++) {
        winrt::com_ptr<IShellItem> item;
        if (FAILED(items->GetItemAt(i, item.put()))) continue;
        PWSTR path = nullptr;
        if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &path)) && path) {
            out.push_back(Narrow(path));
            CoTaskMemFree(path);
        }
    }
    return out;
}

bool OpenPath(std::wstring const& path, bool reveal) {
    if (path.empty() || !PathExists(path)) return false;
    if (reveal) {
        PIDLIST_ABSOLUTE pidl = nullptr;
        if (SUCCEEDED(SHParseDisplayName(path.c_str(), nullptr, &pidl, 0, nullptr)) && pidl) {
            HRESULT hr = SHOpenFolderAndSelectItems(pidl, 0, nullptr, 0);
            CoTaskMemFree(pidl);
            if (SUCCEEDED(hr)) return true;
        }
        // 退回 explorer /select
        std::wstring args = L"/select," + Quoted(path);
        return (INT_PTR)ShellExecuteW(nullptr, L"open", L"explorer.exe", args.c_str(), nullptr, SW_SHOWNORMAL) > 32;
    }
    return (INT_PTR)ShellExecuteW(MainHwnd(), L"open", path.c_str(), nullptr, nullptr, SW_SHOWNORMAL) > 32;
}

// ---------------------------------------------------------------- 网卡

struct Iface {
    std::string name, ip;
    int rank;
};

bool LooksVirtual(std::wstring s) {
    for (auto& c : s) c = (wchar_t)towlower(c);
    static const wchar_t* words[] = {L"tap", L"vpn", L"virtual", L"hyper-v", L"wsl", L"vmware", L"virtualbox", L"vethernet",
                                     L"loopback", L"tunnel", L"wireguard", L"zerotier", L"tailscale", L"pseudo", L"teredo"};
    for (auto w : words) {
        if (s.find(w) != std::wstring::npos) return true;
    }
    return false;
}

std::vector<Iface> Interfaces() {
    std::vector<Iface> out;
    ULONG size = 16 * 1024;
    std::vector<BYTE> buf;
    ULONG ret = ERROR_BUFFER_OVERFLOW;
    ULONG flags = GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER | GAA_FLAG_INCLUDE_GATEWAYS;
    for (int tries = 0; tries < 3 && ret == ERROR_BUFFER_OVERFLOW; tries++) {
        buf.resize(size);
        ret = GetAdaptersAddresses(AF_INET, flags, nullptr, reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buf.data()), &size);
    }
    if (ret != NO_ERROR) return out;
    for (auto* a = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buf.data()); a; a = a->Next) {
        if (a->OperStatus != IfOperStatusUp) continue;
        if (a->IfType == IF_TYPE_SOFTWARE_LOOPBACK || a->IfType == IF_TYPE_PPP || a->IfType == IF_TYPE_TUNNEL) continue;
        std::wstring friendly = a->FriendlyName ? a->FriendlyName : L"";
        std::wstring desc = a->Description ? a->Description : L"";
        if (LooksVirtual(friendly) || LooksVirtual(desc)) continue;
        int rank = (a->IfType == IF_TYPE_IEEE80211 || a->IfType == IF_TYPE_ETHERNET_CSMACD) ? 0 : 1;
        if (!a->FirstGatewayAddress) rank += 2;
        for (auto* u = a->FirstUnicastAddress; u; u = u->Next) {
            auto* sa = u->Address.lpSockaddr;
            if (!sa || sa->sa_family != AF_INET) continue;
            auto const& in = reinterpret_cast<sockaddr_in*>(sa)->sin_addr;
            uint8_t b0 = in.S_un.S_un_b.s_b1, b1 = in.S_un.S_un_b.s_b2;
            if (b0 == 127 || (b0 == 169 && b1 == 254)) continue;   // 回环、链路本地（APIPA）
            char ip[INET_ADDRSTRLEN] = {};
            inet_ntop(AF_INET, &in, ip, sizeof(ip));
            out.push_back({Narrow(friendly), ip, rank});
        }
    }
    std::stable_sort(out.begin(), out.end(), [](Iface const& a, Iface const& b) { return a.rank < b.rank; });
    return out;
}

// ---------------------------------------------------------------- 模块

class HostModule : public Module {
public:
    HostModule() : Module("chaochuanHost") { g_module = this; }
    ~HostModule() override {
        if (g_module == this) g_module = nullptr;
    }

    bool Invoke(std::string const& method, Call& call) override {
        HookMainWindow();
        if (method == "pickFiles" || method == "pickDirectory") {
            Promise promise = call.Defer();
            if (!promise) return true;
            bool dir = method == "pickDirectory";
            bool folder = dir || call.Flag("folder");
            bool multiple = !dir && call.Flag("multiple");
            // 模态对话框有自己的消息循环：不在 Lua 调用里直接弹，投递到下一轮
            engine->Post([promise, dir, folder, multiple] {
                auto paths = PickPaths(folder, multiple);
                Fields f;
                if (dir) {
                    f.Str("path", paths.empty() ? std::string() : paths[0]);
                } else {
                    for (size_t i = 0; i < paths.size(); i++) f.Str("paths." + std::to_string(i + 1), paths[i]);
                }
                promise.Resolve(f);
            });
        } else if (method == "openPath") {
            Promise promise = call.Defer();
            if (!promise) return true;
            std::wstring path = Widen(call.Str("path"));
            bool reveal = call.Flag("reveal");
            engine->Post([promise, path, reveal] { promise.Resolve(Fields().Bool("ok", OpenPath(path, reveal))); });
        } else if (method == "takeIncomingFiles") {
            Fields f;
            for (size_t i = 0; i < g_incoming.size(); i++) f.Str("paths." + std::to_string(i + 1), g_incoming[i]);
            g_incoming.clear();
            call.SetFields(f);
        } else if (method == "interfaces") {
            Fields f;
            auto list = Interfaces();
            for (size_t i = 0; i < list.size(); i++) {
                std::string k = "list." + std::to_string(i + 1);
                f.Str(k + ".name", list[i].name);
                f.Str(k + ".ip", list[i].ip);
            }
            call.SetFields(f);
        } else if (method == "setCloseToTray") {
            g_trayEnabled = call.Flag("enabled");
            if (g_trayEnabled) AddTrayIcon();
            else RemoveTrayIcon();
            call.SetFields(Fields().Bool("ok", !g_trayEnabled || g_trayAdded));
        } else if (method == "showWindow") {
            ShowMainWindow();
            call.SetFields(Fields().Bool("ok", true));
        } else if (method == "hideWindow") {
            g_wantHidden = true;
            HideMainWindow();
            // 启动时（main.lua 里）调用：宿主随后才激活窗口，下一轮再藏一次
            engine->Post([] {
                if (g_wantHidden) HideMainWindow();
            });
            call.SetFields(Fields().Bool("ok", true));
        } else if (method == "setLaunchAtLogin") {
            bool enabled = call.Flag("enabled");
            bool ok;
            if (enabled) {
                ok = RegSetString(HKEY_CURRENT_USER, kRunKey, kRunValue, Quoted(ExePath()));
            } else {
                LSTATUS st = RegDeleteKeyValueW(HKEY_CURRENT_USER, kRunKey, kRunValue);
                ok = st == ERROR_SUCCESS || st == ERROR_FILE_NOT_FOUND;
            }
            Fields f;
            f.Bool("ok", ok);
            if (!ok) f.Str("error", "写注册表失败");
            call.SetFields(f);
        } else if (method == "getLaunchAtLogin") {
            auto v = RegGetString(HKEY_CURRENT_USER, kRunKey, kRunValue);
            call.SetFields(Fields().Bool("enabled", v.has_value() && !v->empty()));
        } else if (method == "setContextMenu") {
            bool ok = SetContextMenu(call.Flag("enabled"));
            call.SetFields(Fields().Bool("ok", ok).Bool("supported", true));
        } else {
            return false;
        }
        return true;
    }
};

void Emit(std::string const& event, Fields const& payload) {
    if (g_module) g_module->Emit(event, payload);
}

}  // namespace

bool StartupSingleInstance() {
    auto paths = CommandLinePaths();
    g_mutex = CreateMutexW(nullptr, TRUE, kMutexName);
    if (g_mutex && GetLastError() == ERROR_ALREADY_EXISTS) {
        ForwardToRunningInstance(paths);
        CloseHandle(g_mutex);
        g_mutex = nullptr;
        return false;
    }
    for (auto const& p : paths) g_incoming.push_back(Narrow(p));
    CreateHiddenWindow();
    return true;
}

void RegisterHost(lxwin::Engine& engine) {
    engine.RegisterModule(std::make_unique<HostModule>());
}

}  // namespace chaochuan
