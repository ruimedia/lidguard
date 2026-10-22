#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
LidGuard 图标生成器 —— 输出 SVG 源文件。

两种形态：
  1. app icon   —— 圆角方形（squircle）满版彩色，macOS 应用图标
  2. menubar    —— 透明底纯黑单色，macOS 菜单栏模板图（系统自动着色）

造型语言：「合盖但还醒着」—— 一台合上盖子的笔记本电脑，
屏幕盖中央嵌一个电源符号。盖是关着的，电是通的。
"""
import math

S = 1024  # 画布


def squircle_path(cx, cy, half, n=5.0, steps=720):
    """超椭圆 |x/a|^n + |y/a|^n = 1 —— 逼近 macOS Big Sur 的连续圆角方形。"""
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        ct, st = math.cos(t), math.sin(t)
        x = math.copysign(abs(ct) ** (2.0 / n), ct)
        y = math.copysign(abs(st) ** (2.0 / n), st)
        pts.append((cx + x * half, cy + y * half))
    d = "M %.2f %.2f " % pts[0]
    for p in pts[1:]:
        d += "L %.2f %.2f " % p
    return d + "Z"


def power_arc(cx, cy, r, stroke, width):
    """电源符号的圆弧部分：缺口朝上，画 270°。"""
    a0 = math.radians(-45)    # 右下 45°
    a1 = math.radians(225)    # 逆时针扫过底部到左上
    p0 = (cx + r * math.cos(a0), cy + r * math.sin(a0))
    p1 = (cx + r * math.cos(a1), cy + r * math.sin(a1))
    large = 1 if (a1 - a0) > math.pi else 0
    sweep = 1  # 屏幕坐标下 sweep=1 为顺时针
    return (f'<path d="M {p0[0]:.2f} {p0[1]:.2f} '
            f'A {r:.2f} {r:.2f} 0 {large} {sweep} {p1[0]:.2f} {p1[1]:.2f}" '
            f'fill="none" stroke="{stroke}" stroke-width="{width}" '
            f'stroke-linecap="round"/>')


def build_app_icon():
    # —— 配色：夜幕深蓝紫 + 暖金电源 + 冷银机身 ——
    bg_top, bg_bot = "#2A2E68", "#0A0B18"
    metal = "#F2F4FA"
    metal_dim = "#9BA1BA"
    gold = "#FFC24D"

    # 构图：整体略高于几何中心，视觉重心才稳
    lid_x, lid_w = 246, 532
    lid_y, lid_h = 268, 356
    base_x, base_w = 196, 632
    base_y, base_h = 646, 66

    power_cx, power_cy = lid_x + lid_w / 2, lid_y + lid_h / 2 + 4
    power_r, power_w = 92, 42

    s = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{S}" height="{S}" '
         f'viewBox="0 0 {S} {S}">']
    s.append('<defs>')
    s.append(f'<linearGradient id="bg" x1="0.15" y1="0" x2="0.7" y2="1">'
             f'<stop offset="0" stop-color="{bg_top}"/>'
             f'<stop offset="1" stop-color="{bg_bot}"/></linearGradient>')
    s.append(f'<linearGradient id="metal" x1="0" y1="0" x2="0" y2="1">'
             f'<stop offset="0" stop-color="#FFFFFF"/>'
             f'<stop offset="0.62" stop-color="{metal}"/>'
             f'<stop offset="1" stop-color="{metal_dim}"/></linearGradient>')
    s.append(f'<linearGradient id="base" x1="0" y1="0" x2="0" y2="1">'
             f'<stop offset="0" stop-color="#E2E6F2"/>'
             f'<stop offset="1" stop-color="#7F86A3"/></linearGradient>')
    s.append(f'<radialGradient id="glow" cx="0.5" cy="0.5" r="0.5">'
             f'<stop offset="0" stop-color="{gold}" stop-opacity="0.42"/>'
             f'<stop offset="0.6" stop-color="{gold}" stop-opacity="0.12"/>'
             f'<stop offset="1" stop-color="{gold}" stop-opacity="0"/></radialGradient>')
    # 左上角的柔光：用径向渐变才没有硬边
    s.append('<radialGradient id="sheen" cx="0.5" cy="0.5" r="0.5">'
             '<stop offset="0" stop-color="#8E97FF" stop-opacity="0.30"/>'
             '<stop offset="1" stop-color="#8E97FF" stop-opacity="0"/></radialGradient>')
    s.append(f'<clipPath id="sq"><path d="{squircle_path(S/2, S/2, S/2)}"/></clipPath>')
    s.append('</defs>')

    # 全部内容裁进 squircle，四角留透明（macOS 图标规范）
    s.append('<g clip-path="url(#sq)">')
    s.append(f'<rect width="{S}" height="{S}" fill="url(#bg)"/>')
    s.append('<ellipse cx="215" cy="60" rx="720" ry="620" fill="url(#sheen)"/>')

    # 底座（略宽于盖子）
    s.append(f'<rect x="{base_x}" y="{base_y}" width="{base_w}" height="{base_h}" '
             f'rx="20" fill="url(#base)"/>')
    # 前沿的凹槽 —— 合上盖子的落位提示
    s.append(f'<rect x="{512 - 78}" y="{base_y + base_h - 17}" width="156" height="10" '
             f'rx="5" fill="#5E6480" opacity="0.6"/>')

    # 盖子
    s.append(f'<rect x="{lid_x}" y="{lid_y}" width="{lid_w}" height="{lid_h}" '
             f'rx="38" fill="url(#metal)"/>')

    # 电源符号 + 光晕
    s.append(f'<circle cx="{power_cx}" cy="{power_cy}" r="168" fill="url(#glow)"/>')
    s.append(power_arc(power_cx, power_cy, power_r, gold, power_w))
    s.append(f'<line x1="{power_cx}" y1="{power_cy - power_r - 20}" '
             f'x2="{power_cx}" y2="{power_cy - 10}" stroke="{gold}" '
             f'stroke-width="{power_w}" stroke-linecap="round"/>')
    s.append('</g>')
    s.append('</svg>')
    return "".join(s)


def build_menubar_icon():
    """菜单栏模板图：纯黑单色、透明底，由系统按深浅色菜单栏自动反色。

    菜单栏实际只有 18pt 高（约 36px @2x），描边加内部符号会糊成一团，
    所以这里只保留「合上盖子的笔记本」一个粗轮廓，不加任何内部细节。
    """
    ink = "#000000"
    sw = 84

    lid_x, lid_w = 212, 600      # 盖子：粗描边空心
    lid_y, lid_h = 118, 432
    base_x, base_w = 168, 688    # 底座：实心
    base_y, base_h = 606, 96

    s = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{S}" height="{S}" '
         f'viewBox="0 0 {S} {S}">']
    s.append(f'<rect x="{lid_x}" y="{lid_y}" width="{lid_w}" height="{lid_h}" '
             f'rx="56" fill="none" stroke="{ink}" stroke-width="{sw}"/>')
    s.append(f'<rect x="{base_x}" y="{base_y}" width="{base_w}" height="{base_h}" '
             f'rx="30" fill="{ink}"/>')
    s.append('</svg>')
    return "".join(s)


if __name__ == "__main__":
    import pathlib, sys
    out = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    out.mkdir(parents=True, exist_ok=True)
    (out / "icon-app.svg").write_text(build_app_icon(), encoding="utf-8")
    (out / "icon-menubar.svg").write_text(build_menubar_icon(), encoding="utf-8")
    print("已生成 icon-app.svg / icon-menubar.svg")