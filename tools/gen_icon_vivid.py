#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成「颜色更丰富」的 iOS App 图标候选（1024x1024 RGB 无 alpha）。

沿用 gen_icon_candidates.py 的 3x 超采样 + numpy 渐变，保留核心识别元素
（白卡 + 播放三角 + 斜置叠卡），只把单色蓝紫换成多色渐变。

运行：
  D:/manager-platform/task-service/scripts/.venv/Scripts/python.exe tools/gen_icon_vivid.py
"""
import os
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

S = 1024
SS = 3
CS = S * SS
OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "icon_candidates")
os.makedirs(OUT_DIR, exist_ok=True)


def scaled(pts):
    return [(int(x * CS), int(y * CS)) for x, y in pts]


def rect(box):
    return tuple(int(v * CS) for v in box)


def gradient3(c1, c2, c3, glows=()):
    ys, xs = np.mgrid[0:S, 0:S]
    t = (xs + ys) / (2.0 * (S - 1))
    arr = np.zeros((S, S, 3), dtype=np.float64)
    for i in range(3):
        arr[:, :, i] = np.where(t < 0.5,
                                c1[i] * (1 - 2 * t) + c2[i] * (2 * t),
                                c2[i] * (2 - 2 * t) + c3[i] * (2 * t - 1))
    for gx, gy, strength, radius in glows:
        d = np.sqrt((xs - gx * S) ** 2 + (ys - gy * S) ** 2) / (radius * S)
        g = strength * np.exp(-(d ** 2) * 2.0)
        for i in range(3):
            arr[:, :, i] += g
    return np.clip(arr, 0, 255)


def new_fg():
    return Image.new("RGBA", (CS, CS), (0, 0, 0, 0))


def add_shadow(fg, draw_fn, blur, offset=(0, 0), alpha=105):
    sh = Image.new("RGBA", (CS, CS), (0, 0, 0, 0))
    draw_fn(ImageDraw.Draw(sh), (0, 0, 0, alpha), offset)
    sh = sh.filter(ImageFilter.GaussianBlur(radius=blur * CS))
    fg.alpha_composite(sh)


def composite(fg, bg):
    small = fg.resize((S, S), Image.LANCZOS)
    a = np.asarray(small)[:, :, 3:4].astype(np.float64) / 255.0
    c = np.asarray(small)[:, :, :3].astype(np.float64)
    return Image.fromarray(np.clip(c * a + bg * (1 - a), 0, 255).astype(np.uint8), "RGB")


def triangle(d, color, offset=(0, 0), scale=1.0, cx=0.5, cy=0.5):
    pts = [(cx - 0.115, cy - 0.17), (cx - 0.115, cy + 0.17), (cx + 0.155, cy)]
    pts = [(cx + (x - cx) * scale + offset[0], cy + (y - cy) * scale + offset[1]) for x, y in pts]
    d.polygon(scaled(pts), fill=color)


def tri_gradient(fg, cx, cy, scale, colors):
    """三角内从左到右多段渐变。"""
    mask = Image.new("L", (CS, CS), 0)
    triangle(ImageDraw.Draw(mask), 255, scale=scale, cx=cx, cy=cy)
    ys, xs = np.mgrid[0:CS, 0:CS]
    t = np.clip((xs / CS - (cx - 0.115 * scale)) / (0.27 * scale), 0, 1)
    arr = np.zeros((CS, CS, 4), dtype=np.uint8)
    for i in range(3):
        vals = np.array([c[i] for c in colors], dtype=float)
        arr[:, :, i] = np.interp(t, np.linspace(0, 1, len(colors)), vals).astype(np.uint8)
    arr[:, :, 3] = np.asarray(mask)
    fg.alpha_composite(Image.fromarray(arr, "RGBA"))


def white_card(fg, cx=0.50, cy=0.50, w=0.56, h=0.68):
    d = ImageDraw.Draw(fg)
    d.rounded_rectangle(rect((cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2)),
                        radius=int(0.085 * CS), fill=(250, 251, 255, 255))


def card_shadow(fg, cx=0.50, cy=0.50, w=0.56, h=0.68):
    def fn(d, color, off):
        d.rounded_rectangle(rect((cx - w / 2 + off[0], cy - h / 2 + off[1],
                                  cx + w / 2 + off[0], cy + h / 2 + off[1])),
                            radius=int(0.085 * CS), fill=color)
    add_shadow(fg, fn, blur=0.030, offset=(0, 0.022), alpha=110)


# ---------- A 极光：青 → 蓝 → 紫 ----------
def make_aurora():
    bg = gradient3((18, 178, 168), (58, 104, 224), (176, 64, 214),
                   glows=[(0.24, 0.18, 30, 0.55), (0.80, 0.84, 20, 0.48)])
    fg = new_fg()
    card_shadow(fg)
    white_card(fg)
    tri_gradient(fg, 0.50, 0.495, 1.0, [(14, 186, 132), (48, 130, 246), (162, 92, 246)])
    return composite(fg, bg)


# ---------- B 日落：金 → 橙粉 → 紫 ----------
def make_sunset():
    bg = gradient3((252, 190, 72), (242, 86, 112), (112, 58, 206),
                   glows=[(0.22, 0.20, 34, 0.50), (0.78, 0.80, 18, 0.42)])
    fg = new_fg()
    card_shadow(fg)
    white_card(fg)
    tri_gradient(fg, 0.50, 0.495, 1.0, [(250, 160, 54), (240, 72, 104), (140, 62, 220)])
    return composite(fg, bg)


# ---------- C 霓虹：深底 + 青/品红/蓝三张斜卡 ----------
def make_neon():
    bg = gradient3((16, 20, 52), (22, 14, 54), (10, 26, 58),
                   glows=[(0.22, 0.20, 26, 0.40), (0.80, 0.78, 22, 0.38)])
    fg = new_fg()

    def layer(box, angle, color):
        lay = Image.new("RGBA", (CS, CS), (0, 0, 0, 0))
        ImageDraw.Draw(lay).rounded_rectangle(rect(box), radius=int(0.055 * CS), fill=color)
        return lay.rotate(angle, resample=Image.BICUBIC, center=(CS * 0.5, CS * 0.5))

    fg.alpha_composite(layer((0.30, 0.22, 0.74, 0.76), -14, (34, 211, 238, 235)))
    fg.alpha_composite(layer((0.26, 0.25, 0.70, 0.79), 11, (232, 121, 249, 225)))
    fg.alpha_composite(layer((0.24, 0.27, 0.66, 0.77), -4, (99, 102, 241, 220)))
    card_shadow(fg, cx=0.455, cy=0.50, w=0.50, h=0.62)
    white_card(fg, cx=0.455, cy=0.50, w=0.50, h=0.62)
    tri_gradient(fg, 0.455, 0.495, 0.88, [(8, 145, 178), (124, 58, 237), (217, 70, 239)])
    return composite(fg, bg)


# ---------- D 光谱：深紫底 + 彩虹渐变三角 ----------
def make_spectrum():
    bg = gradient3((52, 20, 112), (32, 22, 88), (14, 16, 56),
                   glows=[(0.26, 0.20, 28, 0.44), (0.76, 0.80, 26, 0.40)])
    fg = new_fg()
    card_shadow(fg)
    white_card(fg)
    tri_gradient(fg, 0.50, 0.495, 1.0,
                 [(34, 211, 238), (59, 130, 246), (168, 85, 247), (244, 114, 182), (251, 146, 60)])
    return composite(fg, bg)


items = [
    ("vivid_aurora", make_aurora),
    ("vivid_sunset", make_sunset),
    ("vivid_neon", make_neon),
    ("vivid_spectrum", make_spectrum),
]
imgs = []
for name, fn in items:
    im = fn()
    p = os.path.join(OUT_DIR, name + ".png")
    im.save(p)
    imgs.append((name, im))
    print(p, os.path.getsize(p), "bytes", im.mode, im.size)

# 拼一张对比图（2x2，带标题条）
TW = 420
bar = 34
canvas = Image.new("RGB", (TW * 2 + 24, (TW + bar) * 2 + 24), (238, 238, 242))
d = ImageDraw.Draw(canvas)
for i, (name, im) in enumerate(imgs):
    x = 8 + (i % 2) * (TW + 8)
    y = 8 + (i // 2) * (TW + bar + 8)
    canvas.paste(im.resize((TW, TW), Image.LANCZOS), (x, y + bar))
    d.text((x + 8, y + 9), name, fill=(30, 30, 40))
cmp = os.path.join(OUT_DIR, "compare_vivid.png")
canvas.save(cmp)
print(cmp, os.path.getsize(cmp), "bytes")
