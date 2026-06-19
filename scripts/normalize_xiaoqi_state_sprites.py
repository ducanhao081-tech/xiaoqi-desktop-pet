#!/usr/bin/env python3
"""Normalize selected Xiaoqi raw sprites onto a stable runtime canvas.

This does not wire sprites into Swift. It prepares reviewed candidates so the
runtime can later switch states without each cropped sprite having a different
canvas size and baseline.
"""
import json
import os
from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
RAW = ROOT / "characters/xiaoqi/assets/raw_sprites"
OUT = ROOT / "characters/xiaoqi/assets/state_sprites"
CANVAS = (370, 435)

# Reviewed from /tmp/xiaoqi_raw_sprites_contact.png. These are visually useful
# character poses; obvious text/divider false positives are intentionally absent.
SPRITES = [
    {
        "state": "front",
        "source": "sprite_002.png",
        "output": "front.png",
        "targetHeight": 330,
        "baselineY": 414,
        "notes": "front-facing turnaround candidate",
    },
    {
        "state": "happy",
        "source": "sprite_012.png",
        "output": "happy_hearts.png",
        "targetHeight": 320,
        "baselineY": 414,
        "notes": "heart / happy expression candidate",
    },
    {
        "state": "angry",
        "source": "sprite_017.png",
        "output": "angry.png",
        "targetHeight": 320,
        "baselineY": 414,
        "notes": "anger mark expression candidate",
    },
    {
        "state": "sleepy",
        "source": "sprite_038.png",
        "output": "sleepy_blanket.png",
        "targetHeight": 250,
        "baselineY": 414,
        "notes": "sleep / tucked-in candidate",
    },
    {
        "state": "fireball",
        "source": "sprite_025.png",
        "output": "fireball.png",
        "targetHeight": 300,
        "baselineY": 414,
        "notes": "small magic / fireball action candidate",
    },
    {
        "state": "cheer",
        "source": "sprite_050.png",
        "output": "cheer.png",
        "targetHeight": 330,
        "baselineY": 414,
        "notes": "celebration / jump candidate",
    },
]


def trim_alpha(img: Image.Image) -> Image.Image:
    bbox = img.getbbox()
    return img.crop(bbox) if bbox else img


def normalize(entry: dict) -> dict:
    src = RAW / entry["source"]
    img = trim_alpha(Image.open(src).convert("RGBA"))
    scale = entry["targetHeight"] / img.height
    resized = img.resize((round(img.width * scale), round(img.height * scale)), Image.LANCZOS)

    canvas = Image.new("RGBA", CANVAS, (0, 0, 0, 0))
    x = round((CANVAS[0] - resized.width) / 2)
    y = round(entry["baselineY"] - resized.height)
    canvas.alpha_composite(resized, (x, y))

    out_path = OUT / entry["output"]
    canvas.save(out_path)

    return {
        "state": entry["state"],
        "file": f"assets/state_sprites/{entry['output']}",
        "source": f"assets/raw_sprites/{entry['source']}",
        "canvas": {"width": CANVAS[0], "height": CANVAS[1]},
        "placement": {"x": x, "y": y, "width": resized.width, "height": resized.height},
        "notes": entry["notes"],
    }


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    entries = [normalize(e) for e in SPRITES]
    manifest = {
        "version": 1,
        "id": "xiaoqi-state-sprites",
        "canvas": {"width": CANVAS[0], "height": CANVAS[1]},
        "runtimeDefault": "idle.png remains the active aligned runtime image for now.",
        "sprites": entries,
        "knownLimits": [
            "These are normalized candidates, not final high-resolution assets.",
            "Do not wire them into state swaps until visual alignment is manually accepted.",
            "Source sheet crops are lower resolution than idle.png and may look soft when enlarged.",
        ],
    }
    with open(OUT / "sprites.json", "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print(f"Wrote {len(entries)} normalized sprites to {OUT}")


if __name__ == "__main__":
    main()
