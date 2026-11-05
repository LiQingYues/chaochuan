#!/usr/bin/env bash
# 命令行接收端：见 tools/recv_server.lua 顶部说明（LS_WAIT 毫秒，默认 10 分钟）
SDK="${LX_SDK:?请先设置环境变量 LX_SDK 为 lx SDK 的路径}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$SDK/bin/cache/artifacts/headless/lx_headless" "$SDK/framework/lua" "$ROOT/lua" --quiet --entry "$ROOT/tools/recv_server.lua" --net "${LS_WAIT:-600000}" 2>&1 | grep -vE "^== |^\s*$"
