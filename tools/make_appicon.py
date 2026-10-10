#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成 iOS App 图标（1024x1024，RGB 无 alpha）。

⚠️ 两条硬性约束，踩过才知道：
 1. iOS 图标**不能带 alpha 通道** —— 透明区域会被合成成黑色，表现出来就是「纯黑图标」。
 2. 图标必须是满幅不透明方形，圆角由系统自己套，不要在这里画圆角。

只依赖标准库（zlib / struct），不装 Pillow 也能跑：
    python tools/make_appicon.py
"""
import os
import struct
import zlib

N = 1024                      # 画布边长
OUT = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "MediaManager", "Assets.xcassets", "AppIcon.appiconset", "AppIcon.png",
)

# 品牌主色（对齐 MediaManager/Theme 里的 Theme.brand = rgb(0.38, 0.48, 0.71)）
TOP = (122, 145, 200)         # 左上亮蓝
BOTTOM = (34, 42, 68)         # 右下深蓝


def lerp(a, b, t):
    return a + (b - a) * t


def write_png(path, rows, width, height):
    raw = b"".join(rows)

    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)  # 8bit, truecolor RGB
    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", header)
           + chunk(b"IDAT", zlib.compress(raw, 9))
           + chunk(b"IEND", b""))
    with open(path, "wb") as f:
        f.write(png)


def main():
    cx = cy = N / 2.0
    # 播放三角（向右）
    ax, ay = cx - 0.13 * N, cy - 0.21 * N
    bx, by = cx - 0.13 * N, cy + 0.21 * N
    px, py = cx + 0.19 * N, cy

    # 底部进度条
    bar_y0, bar_y1 = 0.755 * N, 0.795 * N
    bar_x0, bar_x1 = 0.27 * N, 0.73 * N
    bar_fill_x = bar_x0 + (bar_x1 - bar_x0) * 0.62

    inv = 1.0 / (2.0 * (N - 1))
    rows = []
    for y in range(N):
        row = bytearray([0])  # filter type 0
        for x in range(N):
            t = (x + y) * inv
            r = lerp(TOP[0], BOTTOM[0], t)
            g = lerp(TOP[1], BOTTOM[1], t)
            b = lerp(TOP[2], BOTTOM[2], t)

            # 播放三角：三个半平面同号即在内部
            d1 = (bx - ax) * (y - ay) - (by - ay) * (x - ax)
            d2 = (px - bx) * (y - by) - (py - by) * (x - bx)
            d3 = (ax - px) * (y - py) - (ay - py) * (x - px)
            if (d1 >= 0 and d2 >= 0 and d3 >= 0) or (d1 <= 0 and d2 <= 0 and d3 <= 0):
                r, g, b = 255.0, 255.0, 255.0
            elif bar_y0 <= y <= bar_y1 and bar_x0 <= x <= bar_x1:
                # 进度条：已播部分是实白，剩余部分半透明白
                a = 0.95 if x <= bar_fill_x else 0.28
                r = lerp(r, 255.0, a)
                g = lerp(g, 255.0, a)
                b = lerp(b, 255.0, a)

            row += bytes((int(r), int(g), int(b)))
        rows.append(bytes(row))

    write_png(OUT, rows, N, N)
    print("written:", OUT, os.path.getsize(OUT), "bytes")


if __name__ == "__main__":
    main()
