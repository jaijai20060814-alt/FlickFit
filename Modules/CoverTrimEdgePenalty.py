# -*- coding: utf-8 -*-
"""表紙プレビュー周辺帯の「余白」とは別物（文字・線・着色）比率を算出する。
入力: argv1 = 画像パス
標準出力: max_side_fraction （0.0〜1.0、四辺それぞれの帯内サンプルのうちコンテンツピクセルの割合の最大）"""

from __future__ import annotations

import sys

EDGE = 0.06


def pixel_is_content(r: int, g: int, b: int) -> bool:
    """白〜淡灰のフラット近似「余白」以外をコンテンツとみなす。"""
    mx = max(r, g, b)
    mn = min(r, g, b)
    gray = int((r + g + b) / 3)
    if gray < 230:
        return True
    if gray >= 244 and mx - mn <= 11:
        return False
    if mx - mn >= 14 and gray <= 251:
        return True
    return False


def _fraction_in_box(px, samples, x0, y0, x1, y1) -> float:
    n = total = 0
    ww = max(1, x1 - x0)
    hh = max(1, y1 - y0)
    sx = max(1, ww // samples)
    sy = max(1, hh // samples)
    for y in range(int(y0), int(y1), sy):
        for x in range(int(x0), int(x1), sx):
            r, g, b = px[x, y]
            total += 1
            if pixel_is_content(r, g, b):
                n += 1
    return n / total if total else 0.0


def main() -> int:
    if len(sys.argv) < 2:
        print("0.0")
        return 0
    path = sys.argv[1].strip('"')
    try:
        from PIL import Image
    except Exception:
        print("0.0")
        return 0
    try:
        img = Image.open(path).convert("RGB")
    except Exception:
        print("0.0")
        return 0

    if hasattr(Image, "Resampling"):
        resample = Image.Resampling.LANCZOS
    elif hasattr(Image, "LANCZOS"):
        resample = Image.LANCZOS
    else:
        resample = getattr(Image, "ANTIALIAS", Image.BILINEAR)

    w, h = img.size
    if w < 8 or h < 8:
        print("0.0")
        return 0
    mh = max(w, h)
    if mh > 900:
        s = 900 / float(mh)
        nw = max(8, int(w * s))
        nh = max(8, int(h * s))
        img = img.resize((nw, nh), resample)

    px = img.load()
    w, h = img.size
    ew = max(4, int(w * EDGE))
    eh = max(4, int(h * EDGE))
    samples_side = max(35, ew // 2)

    fl = _fraction_in_box(px, samples_side, 0, 0, ew, h)
    fr = _fraction_in_box(px, samples_side, w - ew, 0, w, h)
    ft = _fraction_in_box(px, samples_side, 0, 0, w, eh)
    fb = _fraction_in_box(px, samples_side, 0, h - eh, w, h)

    mf = max(fl, fr, ft, fb)
    print("%.6f" % mf)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
