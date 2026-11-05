// 超传宿主原生能力（Windows）：lxwin::Module「chaochuanHost」，契约见 docs/native_host.md。
//   文件选择 / 打开、待取文件队列（命令行、拖拽、单实例转交）、网卡、托盘、开机自启、右键菜单。
// 头文件只做前置声明，Main.cpp 不用引入 WinUI / LXWinKit 的头。
#pragma once

namespace lxwin {
class Engine;
}

namespace chaochuan {

/// 进程启动最早期调用（RunApp 之前）：单实例检查。已有实例在运行时把命令行里的路径转交给它并返回 false（本进程应直接退出）；
/// 否则把命令行路径放进待取队列、创建隐藏的消息窗口（接收转交 / 托盘回调），返回 true
bool StartupSingleInstance();

/// configureEngine 里调用：注册 chaochuanHost 模块（F5 重载 / 热更新整体重启会再次调用）
void RegisterHost(lxwin::Engine& engine);

}  // namespace chaochuan
