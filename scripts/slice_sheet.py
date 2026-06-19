#!/usr/bin/env python3
"""Auto-detect and slice sprite sheet using connected components."""
import os
import sys
from collections import deque
from PIL import Image
import numpy as np

SRC = "characters/xiaoqi/source/sheet-v2-purple.png"
OUT_DIR = "characters/xiaoqi/assets/raw_sprites"

# Filtering thresholds — tune these if output is wrong.
MIN_PIXELS = 1500     # discard tiny icons/text
MIN_SIDE = 30         # discard skinny strips
MAX_RATIO = 0.8       # discard near-full-sheet components
PAD = 4               # padding around bbox when cropping

# Try scipy for speed; fall back to BFS.
try:
    from scipy.ndimage import label, find_objects
    USE_SCIPY = True
except ImportError:
    USE_SCIPY = False

print(f"Loading {SRC}")
img = Image.open(SRC).convert("RGBA")
arr = np.array(img)
H, W = arr.shape[:2]
print(f"  size {W}x{H}")

r = arr[..., 0]; g = arr[..., 1]; b = arr[..., 2]; a = arr[..., 3]
is_white = (r > 235) & (g > 235) & (b > 235)
is_content = (a > 128) & (~is_white)
print(f"  content pixels: {int(is_content.sum())}")

components = []

if USE_SCIPY:
    print("Using scipy.ndimage.label")
    labeled, n = label(is_content)
    print(f"  {n} components")
    slices = find_objects(labeled)
    for i, sl in enumerate(slices, start=1):
        if sl is None: continue
        ys, xs = sl
        miny, maxy = ys.start, ys.stop - 1
        minx, maxx = xs.start, xs.stop - 1
        mask = (labeled[sl] == i)
        pixels = int(mask.sum())
        components.append({'pixels': pixels, 'box': (minx, miny, maxx, maxy)})
else:
    print("Using BFS (slower, no scipy)")
    visited = np.zeros((H, W), dtype=bool)
    ys, xs = np.where(is_content)
    for y0, x0 in zip(ys, xs):
        if visited[y0, x0]: continue
        q = deque([(y0, x0)])
        visited[y0, x0] = True
        minx, miny, maxx, maxy = x0, y0, x0, y0
        pixels = 0
        while q:
            y, x = q.popleft()
            pixels += 1
            if x < minx: minx = x
            if x > maxx: maxx = x
            if y < miny: miny = y
            if y > maxy: maxy = y
            for dy, dx in ((-1,0),(1,0),(0,-1),(0,1)):
                ny, nx = y+dy, x+dx
                if 0 <= ny < H and 0 <= nx < W and not visited[ny, nx] and is_content[ny, nx]:
                    visited[ny, nx] = True
                    q.append((ny, nx))
        components.append({'pixels': pixels, 'box': (minx, miny, maxx, maxy)})

# Filter
kept = []
for c in components:
    minx, miny, maxx, maxy = c['box']
    w = maxx - minx + 1
    h = maxy - miny + 1
    if c['pixels'] < MIN_PIXELS: continue
    if w < MIN_SIDE or h < MIN_SIDE: continue
    if w > W * MAX_RATIO or h > H * MAX_RATIO: continue
    kept.append(c)

# Sort by row band, then x
kept.sort(key=lambda c: ((c['box'][1] + c['box'][3]) // 100, c['box'][0]))
print(f"Kept {len(kept)} sprites after filtering")

os.makedirs(OUT_DIR, exist_ok=True)
manifest_lines = []
for i, c in enumerate(kept):
    minx, miny, maxx, maxy = c['box']
    x1 = max(0, minx - PAD)
    y1 = max(0, miny - PAD)
    x2 = min(W, maxx + 1 + PAD)
    y2 = min(H, maxy + 1 + PAD)
    crop = img.crop((x1, y1, x2, y2))
    fname = f"sprite_{i:03d}.png"
    crop.save(os.path.join(OUT_DIR, fname))
    manifest_lines.append(
        f"{fname} bbox=({x1},{y1},{x2},{y2}) size={x2-x1}x{y2-y1} pixels={c['pixels']}"
    )

with open(os.path.join(OUT_DIR, "MANIFEST.txt"), "w") as f:
    f.write("# Auto-sliced from sheet-v2-purple.png\n")
    f.write(f"# total={len(kept)}\n\n")
    f.write("\n".join(manifest_lines))

print(f"\nWrote {len(kept)} sprites to {OUT_DIR}")
print("First 10 manifest entries:")
for line in manifest_lines[:10]:
    print("  ", line)
