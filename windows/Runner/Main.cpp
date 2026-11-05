// 入口：通用逻辑（窗口、WinUI、加载 Lua、F5 重载、热更新……）都在 LXWinKit（lxwin::RunApp），这里只填 App 的配置。
#include <windows.h>

#include "LXAppConfig.h"

#include "ChaochuanHost.h"

// Runner.vcxproj 编译前生成（$(IntDir)lx_app_config.h，UTF-8）：LX_APP_ID / LX_APP_NAME / LX_DEV_FRAMEWORK_DIR / LX_DEV_APP_DIR
#include "lx_app_config.h"

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
    // 单实例：已有超传在运行时把命令行里的路径（右键菜单 / 打开方式）转交给它，本进程不建界面直接退出
    if (!chaochuan::StartupSingleInstance()) return 0;
    lxwin::AppConfig config;
    config.id = LX_APP_ID;
    config.name = LX_APP_NAME;
#ifdef _DEBUG
    // 开发模式：错误浮层、F5 / Ctrl+R 重载、热更新、断点调试、Debug 自动化端口；直接读电脑上的源码目录
    config.development = true;
    config.devFrameworkDir = LX_DEV_FRAMEWORK_DIR;
    config.devAppDir = LX_DEV_APP_DIR;
#endif
    // 注册 App 自己的原生模块（F5 重载、热更新整体重启时也会再调用）：chaochuanHost（docs/native_host.md）
    config.configureEngine = [](lxwin::Engine& engine) { chaochuan::RegisterHost(engine); };
    return lxwin::RunApp(std::move(config));
}
