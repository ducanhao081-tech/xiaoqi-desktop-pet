# Architecture Sketch

The product should be built as several separable layers.

## Upstream-First Status

This sketch now describes the prototype boundaries, not a commitment to keep
building every layer locally. Desktop shell, renderer, and agent-integration
work should be replaced by stronger upstream projects whenever the XiaoQi
character experience can be preserved.

See:

```text
docs/UPSTREAM_REPLACEMENT.md
```

## 1. Shell Layer

Responsible for desktop integration.

Capabilities:

- transparent frameless window
- always-on-top toggle
- draggable pet surface
- screen-boundary protection
- position save/restore
- tray or menu-bar controls
- global shortcuts later

Windows prototype:

- implemented in WPF inside `src/DesktopPet.ps1`

Future direction:

- Evaluate upstream desktop shells before adding more local shell code.
- Keep this repo's native shells as smoke-test harnesses and fallback prototypes.

## 2. Character Layer

Responsible for identity.

Data:

- name
- summary
- personality traits
- speech style
- behavior bias
- privacy preferences

Current file:

```text
characters/default.character.json
```

Future direction:

- support user-edited profiles
- generate profiles from name plus description
- later support web-search-assisted character calibration

## 3. Behavior Layer

Responsible for choosing actions.

Inputs:

- character behavior bias
- current mode
- idle time
- user interaction
- wallpaper scene
- behavior packs

Current files:

```text
behavior-packs/basic.behavior.json
behavior-packs/playful-weird.behavior.json
```

Future direction:

- behavior-pack SDK
- weighted action selection
- animation resource binding
- wallpaper-specific action packs

## 4. Renderer Layer

Responsible for visual presentation.

Current state:

- WPF-drawn placeholder body
- simple timer-driven movement

Future direction:

- Export XiaoQi into established pet formats first.
- Current first target: Codex/Petdex `pet.json + spritesheet.webp`.
- Keep a repo-local metadata sidecar for each generated pet package so upstream
  adapters can trace source sprites, preview frames, and persona constraints.
- Keep an explicit atlas frame map sidecar for Codex/Petdex exports so later
  converters do not need to reverse-engineer row semantics or frame positions.
- Keep a reaction-hints sidecar for Codex/Petdex exports so agent integrations
  can map runtime states to XiaoQi atlas rows without duplicating render logic.
- Keep a single visual-contract sidecar that indexes those Codex/Petdex files
  so downstream adapters can depend on one stable entrypoint.
- Use upstream Live2D/VRM engines such as AIRI or Open-LLM-VTuber if continuous
  rigged character animation becomes required.
- Do not add Live2D/VRM support directly to the Swift prototype.

## 5. Brain Layer

Responsible for conversation and reasoning.

Current state:

- local template replies in `Get-PetReply`

Future direction:

- model-backed local service
- structured prompt using character profile
- optional memory
- rate-limited autonomy messages
- safety and privacy controls

## 6. Voice Layer

Responsible for listening and speaking.

Current state:

- Windows speech synthesis works
- Windows speech recognition entry exists but no recognizer is installed on this machine

Future direction:

- push-to-talk first
- then wake-word if needed
- speech-to-text through Whisper or platform APIs
- text-to-speech through platform TTS or model TTS

## 7. Wallpaper Sense Layer

Responsible for understanding desktop background.

Current state:

- Windows Registry wallpaper path lookup
- rough average-color classification

Future direction:

- screenshot or wallpaper-file analysis
- scene classification
- safe standing zones
- scene-specific behavior packs
