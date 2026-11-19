"""Render every reference theme with the Swift engine and compare with the Python reference PNGs.

Usage (from the repo root): .venv/bin/python macos/Tests/compare.py [theme ...]
Writes macos/Tests/out/<theme>.png (Swift render) and <theme>.diff.png (Python | Swift | differences in red).
"""
import os
import subprocess
import sys

import numpy as np
from PIL import Image

ROOT = os.getcwd()
TESTS = os.path.join(ROOT, "macos", "Tests")
GOLDEN = os.path.join(TESTS, "golden")
OUT = os.path.join(TESTS, "out")
RENDER = os.path.join(ROOT, "macos", ".build", "debug", "RenderTheme")
THRESHOLD = 40  # per-channel difference that counts as a "different" pixel (ignores antialiasing noise)

os.makedirs(OUT, exist_ok=True)
themes = sys.argv[1:] or sorted(f[:-4] for f in os.listdir(GOLDEN) if f.endswith(".png"))
rows = []
for theme in themes:
    out = os.path.join(OUT, theme + ".png")
    r = subprocess.run([RENDER, os.path.join(ROOT, "res"), theme, out], capture_output=True, text=True)
    if r.returncode != 0:
        rows.append((theme, None, r.stderr.strip().splitlines()[-1] if r.stderr.strip() else "failed"))
        continue
    a = np.asarray(Image.open(os.path.join(GOLDEN, theme + ".png")).convert("RGB")).astype(int)
    b = np.asarray(Image.open(out).convert("RGB")).astype(int)
    if a.shape != b.shape:
        rows.append((theme, None, f"size {b.shape[1]}x{b.shape[0]} vs {a.shape[1]}x{a.shape[0]}"))
        continue
    diff = np.abs(a - b).max(axis=2)
    bad = diff > THRESHOLD
    pct = bad.mean() * 100
    rows.append((theme, pct, f"{bad.sum()} px, mean diff {np.abs(a - b).mean():.2f}"))
    if pct > 0:
        overlay = (a * 0.35).astype(np.uint8)
        overlay[bad] = [255, 0, 0]
        side = np.concatenate([a.astype(np.uint8), b.astype(np.uint8), overlay], axis=1)
        Image.fromarray(side).save(os.path.join(OUT, theme + ".diff.png"))

for theme, pct, note in sorted(rows, key=lambda r: -1 if r[1] is None else r[1], reverse=True):
    print(f"{'ERROR' if pct is None else f'{pct:6.2f}%':>8}  {theme:34s} {note}")
ok = [p for _, p, _ in rows if p is not None]
print(f"\n{len(ok)}/{len(rows)} rendered; median {np.median(ok):.2f}% of pixels differ; "
      f"{sum(p < 1 for p in ok)} themes under 1%")
