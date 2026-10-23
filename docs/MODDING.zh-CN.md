# Mod 编写指南

**简体中文** | [English](MODDING.md)

> 本文是 [MODDING.md](MODDING.md) 的中文对照版。如有出入，以英文版为准。

怎么给这个 loader 写 mod：文件布局、`main.lua` 的确切契约、以及沙箱 API 的精确清单。

如果你以前给 **Bingus Shared Loader** 写过 mod，直接看 §6 —— 大部分形状是刻意保持一致的，简单的 BSL mod 在这里可以零改动运行（确实有一个真家伙在跑）。

---

## 1. 文件布局

```
<game>\mods\
├─ mods.txt                 # 清单：每行一个目录名
├─ hello\
│  └─ main.lua              # 入口，必需
└─ my-mod\
   ├─ main.lua
   └─ data\whatever.txt     # 你想随包带的其它文件
```

`mods.txt`：

```
# 以 # 开头的行是注释
hello
my-mod
```

放在 `mods\01` … `mods\20` 里的 mod **即使没写进清单也会被加载**，因为 loader 用能否打开 `<dir>\main.lua` 来探测。这是兜底路径，不是推荐路径：它之所以存在，是因为 `io.popen` 和 `os.execute` 会阻塞游戏主线程，loader 没有别的办法枚举目录。

日志写在清单旁边：写 `mods\<你的mod>.log`。那也是你唯一被允许写入的地方（见 §4）。

---

## 2. `main.lua` 的契约

`main.lua` 会被 `loadstring` 编译，在一个全新的沙箱环境里运行，并且**必须返回一个 table**：

```lua
local M = { name = "my-mod", version = "1.0.0" }   -- 两个字段都可选

function M.init()
    -- 调用一次，在 payload 装好钩子之后
end

function M.update(dt)
    -- 每帧；dt 是引擎传进来的值（秒）
end

function M.render(world)
    -- 可选；在这里绘制
end

function M.shutdown()
    -- 退出时调用一次
end

return M
```

| 字段 | 必需 | 说明 |
|---|---|---|
| `name`、`version` | 否 | 只用于日志 |
| `init` | 否 | 调用一次，在所有 mod 编译完之后 |
| `update(dt)` | 否 | 每帧 |
| `render(world)` | 否 | 由引擎的 `render` 钩子转发 |
| `shutdown` | 否 | 退出时一次 |

每个钩子调用都被 loader 包在 `pcall` 里。同一个钩子上抛错 **10 次**的 mod 会被禁用（会有一行日志说明），而不是永远每帧刷日志。

没有返回 table、或者在加载时抛错的 mod，会带着一行日志被拒绝并跳过。其它 mod 不受影响。

---

## 3. 绘制与查询

完整的 `stingray` 命名空间都暴露给你。以下调用均已实测可用（细节与崩点见 [COMPATIBILITY.zh-CN.md](COMPATIBILITY.zh-CN.md)）：

```lua
-- 屏幕 GUI：(world, "scale", 1, 1) 是本构建上可用的参数顺序。
-- 锚定到主 world；overlay world 不一定会被合成。
local world = stingray.Application.main_world()        -- 或 Application.worlds()[i]
local gui = stingray.World.create_screen_gui(world, "scale", 1, 1)
stingray.Gui.set_visible(gui, true)

-- 文本：(gui, text, font, size, material, position, colour)
--   字体 "core/performance_hud/debug" 在本构建上存在，字号 22 是一个可用的
--   第三方 overlay 实际在用的值，颜色为每通道 0-255、alpha 在最前。
local font = "core/performance_hud/debug"
local id = stingray.Gui.text(gui, "hello", font, 22, font,
                             stingray.Vector2(20, 20), stingray.Color(255, 255, 255, 255))

-- **不传参数。** Gui.resolution(gui) 不会报错，但会返回垃圾值
-- （同一帧实测：resolution(gui) -> 1226853248 x 1426606976，
--   resolution()    -> 2560 x 1440）。拿这些数去算坐标会让 Gui.text
-- 崩在 helldivers2.exe+0x108732。务必对结果做合理性检查：
-- 不是合理的屏幕尺寸就跳过这一帧，别画。
local w, h = stingray.Gui.resolution()

-- 重绘的意思是：先销毁上一个对象，再调一次 Gui.text。
-- 每次调用都会分配一个对象，包括阴影 —— 忘了销毁就每次重绘泄漏一个。
stingray.Gui.destroy_text(gui, id)

-- session / 延迟
stingray.Network.ping(...)
local session = stingray.Network.game_session()
local peers = session and stingray.GameSession.peers(session)
```

> **`stingray.Vector2` 是可调用的 *table***（元表 `__call`），而 `stingray.Color` 是真函数。把守卫写成 `type(Vector2) == "function"` 会把它判死，你的 HUD 会安安静静什么都不画。请检测"可调用性"——`examples/hud-panel` 里有现成的辅助函数。

**以下调用一个都不要碰**——它们杀的是进程，不只是你的 mod：
`World.unit_by_id`、`UnitComponent.unit`、`Unit.has_mesh`、`Unit.is_a`、
单参数形式的 `Application.can_get(x)`、`Application.set_resource_override(t, n, nil)`、
以及 `Gui.resolution(nil, nil)`。

一条补充（2026-10-23 在 build 26088801 上复测）：**`World.units(w)` 调用本身是安全的** —— 它返回一个 table（舰船 62 个、另一个世界 2 290 个）。杀进程的是解引用 `units[i]`（i ≥ 2），而且 `Unit.alive` 返回 `true` 也保不住你。请把返回的表当成"只有第一个元素能用"。

---

## 4. 沙箱 API —— 精确清单

你的环境（chunk 里的 `_G`）是一个**全新的 table**，不是真正的全局表。以下是完整白名单：

| 组 | 可用 |
|---|---|
| 核心 | `tostring` `tonumber` `type` `pairs` `ipairs` `next` `select` `pcall` `error` `assert` `unpack` `_VERSION` |
| 元表 | `rawget` `rawset` `rawequal` `setmetatable` `getmetatable` |
| `string` | 整个库 |
| `table` | 整个库 |
| `math` | 整个库 |
| `print` | 存在，但**是空函数**（免得把你的噪声灌进引擎控制台） |
| `os` | `time` `clock` `date` `getenv` `difftime` —— **没有** `execute`、`remove`、`exit`、`tmpname` |
| `io` | 只有 `open`，见下 |
| 引擎 | `stingray`（整个命名空间） |
| Loader | `CowboyBingusModLoader`（见 §6）、`__MODNAME`、`update`、`shutdown` |
| `_G` | 指向这个沙箱表本身 |

**`io.open` 的规则：** 读不限。当模式串含 `w`、`a` 或 `+` 时，路径会**先被规范化**（统一分隔符、丢弃 `.`、解析 `..`），然后必须落在 **`mods\` 之下**；绝对路径（`C:\…`、`\\server\…`、`\` 开头的）一律拒绝。其它情况返回 `nil, "write outside mods dir denied …"`。

这个检查是**故意**比"子串匹配"更严的。早期版本只要路径里**含有** `mods` 这几个字就放行，结果 `mods\..\..\evil.txt` 能解析到游戏根目录、`C:\temp\mods_evil.txt` 能落到别的盘上。现在的规则是"先规范化，再要求 `mods\` 前缀"——`mods\sub\..\a.log` 可以，`mods\..\a.log` 不行。

**完全不可用**——凡是上面表格里没有的都算：`ffi`、`jit`、`require`、`package`、`module`、`loadstring`、`load`、`loadfile`、`dofile`、`setfenv`/`getfenv`、`os.execute`、`os.remove`、`os.exit`、`io.popen`、`io.write`、`io.lines`、`io.close`、`debug`、`coroutine`、`collectgarbage`、`newproxy`。如果你的 mod 需要其中任何一个，它在这个 loader 下跑不起来——这是设计限制，不是 bug。（`loadstring` 是**故意**不给的：loader 自己编译你的 `main.lua`，而一个能继续编译 chunk 的 mod 就能绕过这个沙箱。）

---

## 5. 日志约定

一个事件一行，且要足够识别出是哪个 mod：

```lua
local function say(text)
    local f = io.open("mods\\my-mod.log", "a")
    if f then f:write(os.date("%H:%M:%S ") .. text .. "\n"); f:close() end
end
```

每次都 open/write/close。**不要**跨帧保持句柄开着：那样游戏运行期间别的工具就读不了这个文件（第三方 P2P Ping 就是这么干的，于是从 PowerShell 读它的日志需要一个宽容的读取器）。

---

## 6. Bingus Shared Loader 兼容

BSL 风格的 mod 形状不同：它们不返回 table，而是在自己的 chunk 里给全局 `update` 打补丁：

```lua
if rawget(_G, "my_mod_key") then return end
rawset(_G, "my_mod_key", true)

local loader = rawget(_G, "CowboyBingusModLoader")
local log = loader and loader.open_log and loader.open_log("my-mod.log")

local prev = rawget(_G, "update")
rawset(_G, "update", function(dt)
    if prev then prev(dt) end
    -- 每帧的工作
end)
```

要让它成立，loader 提供：

| 符号 | 值 |
|---|---|
| `CowboyBingusModLoader.api` | `1`（大多数 BSL mod 检查的硬门禁） |
| `CowboyBingusModLoader.version` | `17` |
| `CowboyBingusModLoader.open_log(name)` | 打开 `mods\<name>` 的写句柄 |
| `CowboyBingusModLoader.capabilities` | `{ build_gate=false, after_startup=false, jit=false, ffi=false, pure_lua_host=true }` |
| `CowboyBingusModLoader.build` | `{ supported=false, note="pure-lua host; no BSL build gate" }` |
| 你沙箱里的 `update`、`shutdown` | 可以包装的空函数 |

loader 每帧 / 退出时调用你包装的 `update`/`shutdown`，并在第一次调用时写一行 `[bsl] first tick -> <mod>`，所以日志里没有这行就说明你的包装没装上。

任何用到 `ffi` 的东西（也就是 BSL mod 生态的大头——抽查 6 个高星仓库，6 个全都 vendor 了同一份调用 `require('ffi')` + `ReadProcessMemory` 的 `bingus_memory.lua`）**在这里都跑不起来**。

---

## 7. 常见错误

| `loader.log` 里的症状 | 原因 |
|---|---|
| `[load] x: no main.lua, skipped` | 目录层级错了 —— loader 要的是 `mods\<name>\main.lua`，不是 `mods\<name>\<name>\main.lua` |
| `[load] x: main.lua returned nil, expected table` | 你的 chunk 没有返回值；补上 `return M`（纯 BSL 风格的 mod 不会走到这一行，它会被另一条路径接受） |
| `[load] x: compile error: …` | Lua 5.1 语法问题；你可能用了 5.2+ 的特性（`goto`、整除） |
| `[update] x error #1..10` | 你的 `update` 抛错了；读消息，loader 会一直跑到第 10 次 |
| `[scan] 未找到 mods\mods.txt，改用固定名兜底` | 清单文件缺失；`01`…`20` 这种目录名仍然会被加载 |
| `loader.log` 里什么都没有 | loader 没装上（补丁槽位不对，或者你在游戏运行时才复制文件） |

---

## 8. 示例

- [`examples/hello`](../examples/hello/main.lua) —— 最小 mod：写日志、数帧、干净关闭。
- [`examples/hud-panel`](../examples/hud-panel/main.lua) —— 带实时文本的屏幕 GUI 面板（**已在游戏内实测画出**）。
- [`examples/mod-template`](../examples/mod-template/main.lua) —— 可直接复制开工的起点：日志约定、引擎调用守卫、每个危险操作都包 `pcall`。
