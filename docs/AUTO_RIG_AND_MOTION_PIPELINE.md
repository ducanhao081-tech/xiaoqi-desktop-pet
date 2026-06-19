# Auto Rig And Motion Pipeline

Goal: when the user imports a character image or character asset pack, the app should identify reusable facial/body anchors once, then generate smooth motions such as blink, mouth open/close, look left/right, yawn, stretch, and speaking.

This is an import-time pipeline, not a runtime recognition loop. Runtime animation should read confirmed anchors from `manifest.json` and motion curves from `motions.json`.

## Why Import-Time Anchors

Different anime-style characters have very different eye shapes, mouths, hair, accessories, and proportions. Live recognition on every frame would be unstable and expensive.

The stable flow is:

```text
user image / asset pack
  -> automatic anchor proposal
  -> user correction UI
  -> manifest.json
  -> generated motions.json
  -> runtime renderer
```

AI/vision can help propose anchors, but the saved rig is the source of truth.

## Minimum Anchors

For a single front-facing character, the importer should produce these anchors:

```json
{
  "face": {
    "center": { "x": 110, "y": 82 },
    "bounds": { "x": 52, "y": 28, "width": 116, "height": 112 }
  },
  "eyes": {
    "left": {
      "center": { "x": 88, "y": 76 },
      "bounds": { "x": 78, "y": 66, "width": 20, "height": 20 },
      "blinkAxis": "vertical"
    },
    "right": {
      "center": { "x": 132, "y": 76 },
      "bounds": { "x": 122, "y": 66, "width": 20, "height": 20 },
      "blinkAxis": "vertical"
    }
  },
  "mouth": {
    "center": { "x": 110, "y": 110 },
    "bounds": { "x": 99, "y": 102, "width": 22, "height": 14 },
    "openDirection": "vertical"
  },
  "body": {
    "center": { "x": 110, "y": 120 },
    "bounds": { "x": 48, "y": 28, "width": 124, "height": 132 }
  }
}
```

Optional anchors:

- leftHand / rightHand
- ears / horns / antennae / hair tufts
- tail / cape / backpack
- props / weapon-like accessories
- shadow

## Detection Strategy

Use a layered strategy rather than one detector.

1. **Asset pack metadata first**
   - If the uploaded pack already has named layers such as `eye_left`, `eye_right`, `mouth`, trust those names.
   - For PSD/PNG sequences later, layer names should win over computer vision.

2. **AI vision proposal**
   - Ask a vision model to return JSON anchor proposals: face bounds, eye centers, mouth center, hands, accessories.
   - Treat this as a draft, not final truth.

3. **Image heuristics**
   - Find high-contrast dark eye blobs inside the upper face region.
   - Find small dark/colored mouth region under the eyes.
   - Mirror-check eye candidates around the face center.

4. **User confirmation**
   - Show draggable boxes for eyes, mouth, face, body.
   - Require the user to confirm before writing `manifest.json`.

## 120+ Frame Motion Requirement

To avoid choppy motion, every visible motion should be represented by at least 120 sampled frames or an equivalent continuous curve that can be sampled at display rate.

Recommended standard:

```text
display rate: 60 fps
minimum visible motion length: 120 frames = 2 seconds
micro motions can be short, but they should still use smooth interpolation curves and be sampled at 60 fps
```

The current prototype logic tick is about 11 Hz (`0.09s`). That is fine for autonomy decisions, but too slow for premium animation. Long term, split the system:

```text
Autonomy clock: 5-12 Hz, decides what should happen
Animation clock: 60 Hz, renders smooth transitions
```

macOS implementation options:

- `CVDisplayLink` for display-synced animation timing.
- `Timer(timeInterval: 1.0 / 60.0)` as a simpler first version.
- Keep behavior decisions in the current slower `tickAutonomy`.

## Motion Curve Format

Store motions as named curves, not as hard-coded switch blocks.

```json
{
  "blink": {
    "durationFrames": 120,
    "fps": 60,
    "tracks": {
      "leftEye.scaleY": [
        { "frame": 0, "value": 1.0, "ease": "easeOut" },
        { "frame": 10, "value": 0.08, "ease": "easeInOut" },
        { "frame": 20, "value": 1.0, "ease": "easeOut" },
        { "frame": 120, "value": 1.0 }
      ],
      "rightEye.scaleY": [
        { "frame": 0, "value": 1.0 },
        { "frame": 10, "value": 0.08 },
        { "frame": 20, "value": 1.0 },
        { "frame": 120, "value": 1.0 }
      ]
    }
  },
  "talkSoft": {
    "durationFrames": 120,
    "fps": 60,
    "loop": true,
    "tracks": {
      "mouth.open": [
        { "frame": 0, "value": 0.05 },
        { "frame": 12, "value": 0.55 },
        { "frame": 24, "value": 0.15 },
        { "frame": 36, "value": 0.7 },
        { "frame": 48, "value": 0.1 },
        { "frame": 120, "value": 0.05 }
      ]
    }
  }
}
```

For short actions like blink, the visible blink may only happen in the first 20 frames, while the full 120-frame clip includes settling and breathing continuity. This satisfies the smoothness requirement without making every blink look slow.

## Generated Motions

For each imported character, generate these defaults:

1. `blink`
   - Eye scaleY closes then opens.
   - If closed-eye asset exists, swap variant during closed frames.

2. `lookLeft` / `lookRight`
   - Translate eyes or pupils horizontally.
   - If the character has no visible pupils, shift the whole eye highlight or head by a tiny amount.

3. `talkSoft`
   - Mouth open value cycles with small randomness.
   - Use while TTS is playing.

4. `yawn`
   - Eyes half-close.
   - Mouth opens vertically.
   - Body lowers slightly.

5. `stretch`
   - Body scaleY up, scaleX down, then settle.
   - Optional hands/ears move outward.

6. `sleep`
   - Body lowers.
   - Eyes closed.
   - Breathing amplitude reduced.

## Single Image Limitation

From a single flat image, the app can create convincing lightweight motion, but it cannot perfectly reveal hidden mouth interiors, eyelids, or limbs that do not exist in the image.

Fallback drawing rules:

- If no closed-eye asset: draw a clean eyelid curve over the eye.
- If no open-mouth asset: draw a small stylized mouth overlay.
- If no separate hand/limb: use body squash/stretch and head motion instead.

This keeps generated packs usable without pretending to reconstruct missing art.

## Runtime Integration Plan

1. Add `CharacterRigManifest: Codable`.
2. Add `MotionClip: Codable`.
3. Add `RigImportResult` with confidence scores.
4. Add a debug overlay that draws anchor boxes on the pet.
5. Add a `MotionPlayer`:
   - current clip
   - current frame
   - curve sampling
   - blend back to idle
6. Keep existing `PetRig.defaultA` as fallback.

## Acceptance Criteria

- Importing an image produces eye and mouth anchor proposals.
- User can adjust anchors before saving.
- Generated blink/talk/yawn motions contain at least `durationFrames >= 120`.
- Runtime animation is sampled at 60 fps or uses continuous curves equivalent to 120+ frame clips.
- If detection confidence is low, importer asks for manual correction instead of guessing silently.
