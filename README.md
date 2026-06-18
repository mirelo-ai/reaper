# Mirelo for REAPER

AI sound effects & music generation inside REAPER — generate from a text prompt
or the video on your timeline, and extend or inpaint audio clips. Powered by
[Mirelo](https://mirelo.ai).

This repo is the **ReaPack distribution** for the plugin (ReaScript + ReaImGui).

## Install

You need **REAPER** with **[ReaPack](https://reapack.com)** installed (restart
REAPER after installing ReaPack). REAPER runs the plugin's Lua itself — you do
**not** need to install Lua.

**One-step install:** download [`install-mirelo.lua`](install-mirelo.lua), then in
REAPER: `Actions ▸ Show action list ▸ New action ▸ Load ReaScript…` → pick it →
**Run**. It adds this repository and installs Mirelo via ReaPack. When it
finishes, search the Actions list for **"Mirelo"** and run it.

**Manual install:** `Extensions ▸ ReaPack ▸ Import repositories`, paste

```
https://raw.githubusercontent.com/mirelo-ai/reaper/main/index.xml
```

then `Browse packages` → install **Mirelo**.

## Requirements

- **ReaImGui ≥ 0.9** — the plugin prompts you if it's missing; install from
  `Extensions ▸ ReaPack ▸ Browse packages ▸ "ReaImGui"`.
- **curl ≥ 7.73** — in-box on Windows 10 1803+, macOS, and modern Linux.
- **SWS** — optional; enables in-panel audio preview.

Updates arrive through ReaPack's **Synchronize**.
