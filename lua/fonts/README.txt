把 App 用的字体文件（.ttf / .otf）放在这个目录，随 Lua 代码一起打包，各平台启动时自动注册。
用法：lx.Text { style = { fontFamily = "文件名（不含扩展名）或字体家族名" }, "..." }，见 SDK 的 docs/styling.md。
注意字体许可（推荐 SIL OFL 等可再分发的开源字体）。
