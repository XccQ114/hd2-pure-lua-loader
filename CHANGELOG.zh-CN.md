# 变更记录

[English](CHANGELOG.md) | **简体中文**

> 本文是 [CHANGELOG.md](CHANGELOG.md) 的中文对照版。如有出入，以英文版为准。
> 日期为本地时间（UTC+8），除非另注。

本项目的重要变更都记在这里。

## 0.2.1 — 2026-10-23

### 安全 / 正确性 —— mod 沙箱的写入规则可以被绕过

写模式的 `io.open` 守卫，判断的是路径里**是否含有** `mods` 这个子串。实测可绕过的路径：

| 路径 | 旧判定 | 实际解析到 |
|---|---|---|
| `mods\..\..\evil.txt` | 放行 | 游戏根目录（向上两级） |
| `mods\..\evil.txt` | 放行 | `data\` |
| `C:\temp\mods_evil.txt` | 放行 | 任意盘的任意目录 |
| `modsx\..\..\evil.txt` | 放行 | 子串匹配，根本没碰 `mods\` |

现在守卫会**先规范化路径**（统一分隔符、丢弃 `.`、解析 `..`、越界即拒绝），再要求结果以 `mods\` 开头；绝对路径一律拒绝。已在游戏内验证：4 条越权尝试全部被拒且磁盘上没有出现任何文件，同时 `mods\.\x.log`、`mods\sub\..\x.log` 这类正常写法仍然可用。

**这是行为变更。** 通过绝对路径写日志的 mod 现在会被拒绝——**即使那个绝对路径指向 `mods\` 内部**，我们自己的旧版测试 mod 就是这么写的。mod 请改用相对路径 `mods\…`。

### 新增 —— 拒绝不再是静默的

被拒的写入原本只返回 `nil, err`，作者只会看到"我的日志文件没出现"。现在按不同原因各记一行：

```
[sandbox] denied write: D:\...\mods\hello.log  -> path escapes (absolute, or .. above the root)
```

正是这行日志让"绝对路径行为变更"在测试中被抓到——在此之前，日志为空这件事无法区分"写入被拒"和"mod 本身坏了"。

## 0.2.0 — 2026-10-22

### 修复 —— solo 部署会导致游戏崩溃

**症状。** 用 `--solo` 构建（loader 单独作为 `boot` payload）并启动游戏：loader 跑起来了，写出前两行日志，然后进程死掉。没有任何 Lua 报错。游戏产生了 crashpad dump：

```
ExceptionCode    0xC0000005 (ACCESS_VIOLATION)
ExceptionAddress helldivers2.exe + 0x79A553
```

**根因。** 引擎会从 `boot` 这个 Lua 状态调用**四个**生命周期钩子——`init`、`update`、`render`、`shutdown`——并且**不做空值检查**。loader 当时只定义了 `update` 和 `shutdown`，于是引擎调用了一个 nil 的 `init`，崩在它自己的 Lua 错误路径里（`+0x79A553` 与编译失败崩点 `+0x79A511` 位于同一个函数）。

这在 merge 构建里完全看不出来，因为 loader 所追加的那个第三方 payload 正好把四个槽位都用空函数占了：

```lua
local function noop() end
init,shutdown,update,render = noop,noop,noop,noop
```

**修复。** loader 现在无条件定义全部四个钩子，并用 `pcall` 串接任何已有实现。mod 加载时机从"第一次 `update`"移入 `init`——既贴合引擎生命周期，也让"加载失败"与"每帧回调出错"在日志里分得开。`render` 会把调用转发给 mod 可选的 `render(world)`。

### 新增 —— solo 模式已在游戏内验证

两种部署形态现已在构建 25988413 上端到端实测：

| 形态 | 日志里的 `prev_*` 类型 | 结果 |
|---|---|---|
| solo | `prev_init=nil, prev_update=nil, prev_render=nil, prev_shutdown=nil` | 加载 2 个 mod，hello 跑满 600 帧，P2P Ping 首 tick，`Responding=True`，无 dump |
| merge（ArmoryForge） | 四个 `prev_*` 全为 `function` | 同上，且 ArmoryForge 自己的日志同步推进 |

### 新增 —— 验证工具

- 归档结构自检脚本：检查一个构建产物的全部 29 个头部/类型/TOC 字段是否符合打包规则，包括 `0x20` = 256 字节对齐容量、以及 payload 头（`u32 长度` + `u32 mode=2`）。
- dump 分诊辅助脚本：把 `ExceptionAddress` 映射到「模块 + RVA」，`+0x79A553` 正是这样被认出来的。

### 已验证 —— 示例是真的能在游戏里跑，不是纸上推演

`examples/hud-panel` 已在构建 25988413 上加载并持续绘制（`[ui] drew: HUD-PANEL …`，27 秒内 59 行，无崩溃，`Responding=True`）。为了走到这一步，踩出一个值得所有人知道的坑：

> **`stingray.Vector2` 是可调用的 *table*（元表 `__call`），不是函数** —— `stingray.Color` 才是真函数。因此把守卫写成 `type(Vector2) ~= "function"` 会把 Vector2 直接判死，HUD 什么都不会画，却只会在日志里写 "missing"。请检测"可调用性"（函数 **或** 带 `__call` 的 table），永远不要只看 `type()`。

该面板同时确认了实测得到的绘制签名：`World.create_screen_gui(world, "scale", 1, 1)`、`Gui.text(gui, text, font, size, material, Vector2(x, y), Color(a, r, g, b))`、字体 `core/performance_hud/debug`、字号 22、颜色通道 0–255。

### 变更

- `[host] update/shutdown hooked (...)` 原样保留，以兼容既有工具链；新增的是第二行 `[host] init/render hooked (...)`，而不是改动第一行。

## 0.1.0 — 2026-10-22

首个可用版本。

- 纯 Lua loader 追加进 `data\9ba626afa44a3aa3.patch_0` 的 `boot` 资源，无 DLL、无签名。
- 归档写入器能把原始第三方 payload **逐字节**复现（797,815 B）作为自检，并在写出任何文件之前跑一遍 `luac -p` 语法闸门。
- BSL 兼容层：`CowboyBingusModLoader.api = 1`、`version = 17`、`open_log(name)`，以及 mod 沙箱里可包装的 `_G.update` / `_G.shutdown`。
- 从 `mods\mods.txt` 读取清单加载目录，外加对 `mods\01` … `mods\20` 的固定名兜底探测（`io.popen` / `os.execute` 会阻塞主线程，全项目一处都没用）。
- 每个 mod 一个 `setfenv` 沙箱、`pcall` 隔离、连续 10 次错误自动禁用。
- 用一个第三方 mod（shock233 的 P2P Ping，零改动）验证到游戏内 HUD 正常渲染。
