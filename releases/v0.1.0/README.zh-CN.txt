HD2 纯 Lua Mod Loader —— 预构建补丁
========================================
文件    : 9ba626afa44a3aa3.patch_0（另有 .gpu_resources、.stream，均为 0 字节）
大小    : 20921 B
sha256  : E6EC2295EAA66C080483D1219508DC37B48D0951B12FD43971D14EE19C9ADFC2
形态    : solo —— loader 单独构成整个 boot payload，不含任何第三方内容
构建于  : 2026-10-23
loader  : loader_core.lua 20721 B
          (sha256 4876BA18EBD5C4F296F38559D19E0D0F0CD910D07F663F11AF2CE2644D5BE40C)
变更    : 0.2.1 修正沙箱写白名单（见 CHANGELOG.zh-CN.md）

已在构建 25988413 上游戏内验证：
  [host] update/shutdown hooked (prev_update=nil, prev_shutdown=nil)
  [host] init/render hooked (prev_init=nil, prev_render=nil)
  [boot] loaded 2 mod(s)

安装：关闭游戏，把这三个文件一起复制进 <game>\data\。
