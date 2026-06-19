# Cross-Platform Parity

This project now treats Windows and macOS as two platform shells for the same desktop pet product.

The shared product surface is:

- same character profile format in `characters/*.character.json`
- same behavior-pack format in `behavior-packs/*.behavior.json`
- same settings schema in `config/settings.json`
- same transparent floating pet window goal
- same drag, show, hide, reset, topmost, voice toggle, autonomy toggle, and exit controls
- same obvious exit path, with a visible macOS `Exit` button and Windows context/tray exit controls
- same visible daily controls for send, exit, listen, voice, pause/resume autonomy, reset, and profile
- same Chinese-first language mode with a visible Chinese/English toggle
- same text chat and template brain behavior
- same position save/restore behavior
- same screen-boundary protection goal
- same first-pass wallpaper mood sensing goal
- same local-only runtime state under `local-state/`

## Current Platform Shells

Windows:

- entry point: `RunDesktopPet.cmd`
- implementation: `src/DesktopPet.ps1`
- UI stack: PowerShell + WPF

macOS:

- entry point: `RunDesktopPet-Mac.command`
- implementation: `src-mac/DesktopPetMac.swift`
- UI stack: Swift + AppKit

## Known Parity Notes

- macOS speech synthesis is implemented with the system speech engine.
- macOS speech recognition is not wired yet; the Listen control exists and reports this clearly, matching the current "entry point first" stage.
- macOS wallpaper sensing first asks System Events, then falls back to the Dock wallpaper database when available. Some machines may still deny this without privacy permission.
- The same source JSON files should remain portable. Avoid adding platform-specific fields there unless both shells can ignore them safely.

## Development Rule

When adding a user-visible capability, define the behavior once in this file or the architecture docs, then implement it in both shells as closely as the platform allows.
