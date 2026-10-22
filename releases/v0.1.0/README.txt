HD2 Pure-Lua Mod Loader — prebuilt patch
========================================
file    : 9ba626afa44a3aa3.patch_0 (+ .gpu_resources, .stream — both empty)
size    : 20921 B
sha256  : E6EC2295EAA66C080483D1219508DC37B48D0951B12FD43971D14EE19C9ADFC2
mode    : solo — the loader is the entire boot payload; no third-party content
built   : 2026-10-23
loader  : loader_core.lua 20721 B (sha256 4876BA18EBD5C4F296F38559D19E0D0F0CD910D07F663F11AF2CE2644D5BE40C)
changes : 0.2.1 sandbox write-guard fix (see CHANGELOG.md)

Verified in game on build 25988413:
  [host] update/shutdown hooked (prev_update=nil, prev_shutdown=nil)
  [host] init/render hooked (prev_init=nil, prev_render=nil)
  [boot] loaded 2 mod(s)

Copy all three files into <game>\data\ with the game closed.
