HD2 纯 Lua Mod Loader —— 预构建补丁
========================================
文件    : 9ba626afa44a3aa3.patch_0（另有 .gpu_resources、.stream，均为 0 字节）
大小    : 23779 B
sha256  : 5CD4C783BDE8305C6B966C4746F69A2E6CCA7C929EFD3967D9F0B73F8F680565
形态    : solo —— loader 单独构成整个 boot payload，不含任何第三方内容
构建于  : 2026-10-23
loader  : loader_core.lua 23579 B
          (sha256 93E2A0085B489D08FCCA803EFA8F1D50814A20840BF3C30C078E2F0178CE4043)
变更    : 0.2.2 修 Gui.resolution、0.2.1 修沙箱写白名单（见 CHANGELOG.zh-CN.md）
说明    : mods.txt 现已容忍 UTF-8 BOM 与 CRLF；loader.log 超过 512 KB 自动轮转

已在构建 25988413 上验证（solo 与 merge 两种形态）：
  [host] update/shutdown hooked / [host] init/render hooked
  [boot] loaded 3 mod(s)   hud-panel 画了 60 行、P2P Ping HUD 正常、无崩溃 dump
