#!/usr/bin/env bash
# 命令行发送：见 tools/send_to.lua 顶部说明（最多等 180 秒，等对方点接收）
SDK="${LX_SDK:?请先设置环境变量 LX_SDK 为 lx SDK 的路径}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$SDK/bin/cache/artifacts/headless/lx_headless" "$SDK/framework/lua" "$ROOT/lua" --quiet --entry "$ROOT/tools/send_to.lua" --net "${LS_WAIT:-180000}" 2>&1 | grep -vE "^== |^\s*$"
