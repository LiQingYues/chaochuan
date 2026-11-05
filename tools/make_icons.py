#!/usr/bin/env python3
"""超传 App 图标：画源图（icon/）→ 用 SDK 的 tools/icons.py 生成各平台尺寸，写进本项目的宿主工程。

  python3 tools/make_icons.py

图形与界面设计稿一致：品牌红（#E5394A → #C21F30 斜向渐变）+ 白色圆头双箭头「»」。
"""
import importlib.util
import json
import os
import sys

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SDK = os.environ.get("LX_SDK")
if not SDK:
    sys.exit("请先设置环境变量 LX_SDK 为 lx SDK 的路径")
ICON = os.path.join(ROOT, "icon")
S = 1024


def red_gradient(size):
    """左上 #E5394A → 右下 #C21F30"""
    a, b = (0xE5, 0x39, 0x4A), (0xC2, 0x1F, 0x30)
    img = Image.new("RGB", (size, size))
    px = img.load()
    for y in range(size):
        for x in range(size):
            t = (x + y) / (2 * (size - 1))
            px[x, y] = tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))
    return img


def chevrons(size, scale, color=(255, 255, 255, 255)):
    """双箭头 »：两条圆头折线（24 网格里的 M5 6l6 6-6 6 / M12 6l6 6-6 6），scale = 图形占画布的比例"""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    box = size * scale
    k = box / 24
    ox = (size - box) / 2 + 0.5 * k   # 图形视觉居中（右边箭尖略重，往右挪半格）
    oy = (size - box) / 2
    w = max(2, int(2.6 * k))
    for x0 in (5, 12):
        pts = [(ox + x0 * k, oy + 6 * k), (ox + (x0 + 6) * k, oy + 12 * k), (ox + x0 * k, oy + 18 * k)]
        d.line(pts, fill=color, width=w, joint="curve")
        for p in pts:   # 圆头
            r = w / 2
            d.ellipse([p[0] - r, p[1] - r, p[0] + r, p[1] + r], fill=color)
    return img


def main():
    os.makedirs(ICON, exist_ok=True)
    bg = red_gradient(S)
    full = bg.convert("RGBA")
    full.alpha_composite(chevrons(S, 0.62))
    full.convert("RGB").save(os.path.join(ICON, "app_icon.png"))
    bg.save(os.path.join(ICON, "app_icon_background.png"))
    chevrons(S, 0.46).save(os.path.join(ICON, "app_icon_foreground.png"))      # 自适应图标：主体在 66% 安全区内
    chevrons(S, 0.80).save(os.path.join(ICON, "notification_icon.png"))
    with open(os.path.join(ICON, "icon.json"), "w", encoding="utf-8") as fp:
        json.dump({"notificationColor": "#D62839"}, fp)

    spec = importlib.util.spec_from_file_location("lx_icons", os.path.join(SDK, "tools", "icons.py"))
    icons = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(icons)
    # 指向本项目的宿主工程
    icons.IOS_ASSETS = os.path.join(ROOT, "ios", "Runner", "Assets.xcassets")
    icons.MAC_ASSETS = os.path.join(ROOT, "macos", "Runner", "Assets.xcassets")
    icons.ANDROID_RES = os.path.join(ROOT, "android", "app", "src", "main", "res")
    icons.WINDOWS_ICO = os.path.join(ROOT, "windows", "Runner", "Assets", "app.ico")
    sys.argv = ["icons.py", ROOT]
    icons.main()


if __name__ == "__main__":
    main()
