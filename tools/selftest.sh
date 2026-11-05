#!/usr/bin/env bash
# LocalSend 核心回环自测：headless 平台 --net 模式（真实 socket），最多等 60 秒
set -e
SDK="${LX_SDK:?请先设置环境变量 LX_SDK 为 lx SDK 的路径}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$SDK/bin/cache/artifacts/headless/lx_headless" "$SDK/framework/lua" "$ROOT/lua" --quiet --entry "$ROOT/tools/localsend_selftest.lua" --net 60000
