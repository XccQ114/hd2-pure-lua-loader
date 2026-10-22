HD2 Pure-Lua Mod Loader — prebuilt patch
========================================
file    : 9ba626afa44a3aa3.patch_0 (+ .gpu_resources, .stream — both empty)
size    : 23779 B
sha256  : 5CD4C783BDE8305C6B966C4746F69A2E6CCA7C929EFD3967D9F0B73F8F680565
mode    : solo — the loader is the entire boot payload; no third-party content
built   : 2026-10-23
loader  : loader_core.lua 23579 B (sha256 93E2A0085B489D08FCCA803EFA8F1D50814A20840BF3C30C078E2F0178CE4043)
changes : 0.2.2 Gui.resolution fix, 0.2.1 sandbox write-guard fix (see CHANGELOG.md)
notes   : mods.txt now tolerates UTF-8 BOM and CRLF; loader.log rotates at 512 KB

Verified in game on build 25988413 (solo and merged):
  [host] update/shutdown hooked / [host] init/render hooked
  [boot] loaded 3 mod(s)   hud-panel drew 60 lines, P2P Ping HUD up, no crash dump
