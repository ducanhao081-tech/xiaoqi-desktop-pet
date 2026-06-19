# Mac Migration Notes

The original Windows prototype cannot be directly converted into a Mac app because it is built with PowerShell and WPF.
This repo now includes a first native macOS shell in `src-mac/DesktopPetMac.swift`.

The product structure is shared through JSON files and docs.
The current macOS shell is intentionally dependency-light: Swift + AppKit, no Electron install required.

## Current Route

Use the same product behavior on both platforms.
Keep platform-specific code in separate shells.

Current shells:

- Windows: `src/DesktopPet.ps1`
- macOS: `src-mac/DesktopPetMac.swift`

Current macOS run command:

```bash
./RunDesktopPet-Mac.command
```

Current macOS self-test:

```bash
./SelfTest-Mac.command
```

## Later Route

Recommended first formal stack:

- Electron
- React
- TypeScript
- Vite
- A local Node-based brain/service layer

Why Electron may still make sense later:

- Transparent always-on-top windows are straightforward.
- System tray, global shortcuts, microphone capture, and audio playback are mature.
- React makes the pet UI, settings panel, and chat surface easier to iterate.
- It is easier to prototype character animations before optimizing app size.

Tauri can be considered later if app size and native performance become more important.

## What Is Shared Now

- `characters/default.character.json`
- `behavior-packs/*.behavior.json`
- `config/settings.json`
- Product concepts in `docs/ARCHITECTURE.md`
- Product parity in `docs/CROSS_PLATFORM_PARITY.md`
- Version history in `CHANGELOG.md`
- Window behavior requirements:
  - transparent window
  - always-on-top mode
  - draggable pet body
  - remembered position
  - screen-boundary protection
  - tray or menu-bar controls

## What Should Not Move Directly

These are Windows prototype implementation details:

- `src/DesktopPet.ps1`
- `Start-DesktopPet.ps1`
- `RunDesktopPet*.cmd`
- WPF shape drawing code
- `System.Speech` synthesis and recognition code
- Windows Registry wallpaper lookup

They should be treated as behavior references, not source code to port line by line.

## Suggested Mac Project Layout

Create a new repo on Mac:

```text
desktop-pet/
  package.json
  src/
    main/
      index.ts
      window.ts
      tray.ts
      shortcuts.ts
    preload/
      index.ts
    renderer/
      App.tsx
      pet/
        PetStage.tsx
        PetSprite.tsx
        PetBubble.tsx
      chat/
        ChatPanel.tsx
      settings/
        SettingsPanel.tsx
    shared/
      character.ts
      behaviorPack.ts
      appSettings.ts
      petState.ts
  resources/
    characters/
      default.character.json
    behavior-packs/
      basic.behavior.json
      playful-weird.behavior.json
  docs/
```

## First Mac Milestone

Build only the foundation first:

- transparent frameless pet window
- always-on-top option
- draggable pet
- position save/restore
- screen-boundary protection
- menu-bar or tray menu
- placeholder pet body
- no real AI yet
- no voice input yet

This matches the Windows `0.1.2` scope.

## Second Mac Milestone

Improve the experience layer:

- replace the WPF placeholder with a React/CSS or Canvas pet
- hide the debug-like bottom input by default
- show chat as a bubble or compact popover
- add a settings panel
- keep character and behavior pack formats compatible

## Third Mac Milestone

Add intelligence:

- model-backed Brain service
- text conversation
- speech synthesis
- push-to-talk voice input
- wallpaper sensing through screenshot or system wallpaper APIs

## Notes For Claude Code

Do not try to run the PowerShell/WPF app on Mac.
Use it as a reference for behavior and app requirements.

Start a new Electron project and copy the JSON data model ideas, not the UI implementation.
