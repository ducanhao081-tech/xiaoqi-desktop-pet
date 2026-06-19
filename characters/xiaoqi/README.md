# 小七 Character Pack Draft

This folder is a user-provided original character pack draft.

Current contents:

- `persona.json` — personality, speech style, likes/dislikes.
- `manifest.json` — planned rig anchors and part names.
- `motions.json` — 120+ frame motion clip drafts.
- `voice.json` — voice style and future custom-voice configuration.
- `assets/idle.png` — current aligned runtime image.
- `assets/state_sprites/` — normalized state candidates used for upstream export.

The current Swift/AppKit runtime can render `assets/idle.png`, but the preferred
next path is upstream adapter export rather than expanding the custom renderer.

Generate the Codex/Petdex-style package from the repository root:

```bash
python3 scripts/export_codex_pet.py
```

The exporter requires Pillow.

Generate additional upstream adapter drafts:

```bash
python3 scripts/export_open_llm_vtuber_config.py
python3 scripts/export_openpets_agent_mapping.py
python3 scripts/export_openpets_install_prompts.py
python3 scripts/export_airi_character_card.py
```

Output:

```text
exports/codex-pet/xiaoqi/pet.json
exports/codex-pet/xiaoqi/spritesheet.webp
exports/open-llm-vtuber/xiaoqi/xiaoqi.character.yaml
exports/openpets/xiaoqi/xiaoqi-agent-reactions.json
exports/openpets-install/xiaoqi/mcp-server-snippet.json
exports/airi/xiaoqi/xiaoqi.airi-character-card.json
```
