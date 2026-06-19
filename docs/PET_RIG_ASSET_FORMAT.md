# Pet Rig Asset Format

This is the planned bridge from the current code-drawn 小A body to user-supplied custom characters.

The runtime should not guess where the eyes, mouth, arms, or body are from a flat image. A custom character should ship with explicit rig metadata: parts, anchors, layer order, and reusable motion targets.

## Directory Shape

```text
characters/custom-name/
  manifest.json
  motions.json
  assets/
    body.png
    face.png
    eye_left_open.png
    eye_left_closed.png
    eye_right_open.png
    eye_right_closed.png
    mouth_smile.png
    mouth_yawn.png
```

The current `PetRig.defaultA` in `src-mac/DesktopPetMac.swift` is the code-native equivalent of this manifest. It centralizes the body, eye, mouth, antenna, and shadow coordinates so future renderers can swap geometry for image parts without rewriting behavior logic.

## Manifest Sketch

```json
{
  "version": 1,
  "id": "custom-name",
  "canvas": { "width": 220, "height": 170 },
  "parts": [
    {
      "id": "body",
      "asset": "assets/body.png",
      "layer": 10,
      "anchor": { "x": 0.5, "y": 0.5 },
      "position": { "x": 115, "y": 100 },
      "size": { "width": 112, "height": 108 }
    },
    {
      "id": "leftEye",
      "asset": "assets/eye_left_open.png",
      "closedAsset": "assets/eye_left_closed.png",
      "parent": "body",
      "layer": 30,
      "position": { "x": 92, "y": 94 },
      "size": { "width": 12, "height": 18 }
    },
    {
      "id": "rightEye",
      "asset": "assets/eye_right_open.png",
      "closedAsset": "assets/eye_right_closed.png",
      "parent": "body",
      "layer": 30,
      "position": { "x": 130, "y": 94 },
      "size": { "width": 12, "height": 18 }
    },
    {
      "id": "mouth",
      "asset": "assets/mouth_smile.png",
      "variants": {
        "yawn": "assets/mouth_yawn.png"
      },
      "parent": "body",
      "layer": 31,
      "position": { "x": 117, "y": 122 }
    }
  ]
}
```

## Motions Sketch

```json
{
  "blink": {
    "duration": 0.12,
    "parts": {
      "leftEye": { "variant": "closed" },
      "rightEye": { "variant": "closed" }
    }
  },
  "lookLeft": {
    "duration": 1.3,
    "parts": {
      "leftEye": { "translate": { "x": -3, "y": 0 } },
      "rightEye": { "translate": { "x": -3, "y": 0 } }
    }
  },
  "stretch": {
    "duration": 1.6,
    "parts": {
      "body": { "scale": { "x": 0.97, "y": 1.06 }, "translate": { "x": 0, "y": -4 } }
    }
  },
  "yawn": {
    "duration": 2.0,
    "parts": {
      "leftEye": { "variant": "closed" },
      "rightEye": { "variant": "closed" },
      "mouth": { "variant": "yawn" }
    }
  }
}
```

## Import Workflow

1. User provides layered assets or a flat reference image.
2. An import helper can use AI vision to propose eye, mouth, body, arm, and leg anchors.
3. The user confirms or edits those anchors once.
4. The runtime saves `manifest.json` and only uses the confirmed rig at animation time.

This keeps runtime animation deterministic. AI may help author the rig, but the pet should not depend on live visual recognition to blink or move limbs.

## Next Implementation Steps

1. Add Codable manifest structs parallel to `PetRig`.
2. Load `characters/<id>/manifest.json` when present; fall back to `PetRig.defaultA`.
3. Add an image-part renderer behind `PetCanvasView`.
4. Move idle accents from code switches to a small motion evaluator.
