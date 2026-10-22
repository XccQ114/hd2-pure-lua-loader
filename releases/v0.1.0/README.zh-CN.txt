HD2 纯 Lua Mod Loader —— 预构建补丁
========================================
文件    : 9ba626afa44a3aa3.patch_0（另有 .gpu_resources、.stream，均为 0 字节）
大小    : 18,265 B
sha256  : 0057C04DDB493B779A14B02DA92279CD06F4A3620E6D1E9312E567B10464E63D
形态    : solo —— loader 单独构成整个 boot payload，不含任何第三方内容
构建于  : 2026-10-22
loader  : loader_core.lua 18,065 B
          (sha256 597C778565D68950791951F69329261B4EAC359242F1E00AF18EDF6161F4E5BF)

已在构建 25988413 上游戏内验证（2026-10-22）：
  [host] update/shutdown hooked (prev_update=nil, prev_shutdown=nil)
  [host] init/render hooked (prev_init=nil, prev_render=nil)
  [boot] loaded 2 mod(s)

安装：关闭游戏，把这三个文件一起复制进 <game>\data\。
回滚：用 tools\rollback.ps1，或手工恢复你安装前备份的 patch_0 三件。
