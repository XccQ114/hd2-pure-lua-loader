# HD2 纯 Lua Mod Loader

[English](README.md) | **简体中文**

> 本文是 [README.md](README.md) 的中文对照版，与英文版逐节对应。两者内容一致；如有出入，以英文版为准。

一个面向当前 Steam 构建（**26088801**，最初在 25988413 上验证、2026-10-23 在新构建上复测通过）的《绝地潜兵 2》（HELLDIVERS 2）**纯 Lua Mod Loader**。它通过覆盖 `boot` 资源，把 `<game>\mods\` 下的 mod 加载进游戏**自己的 Lua 5.1 状态**里——不需要 native DLL、不需要代码签名、不碰反作弊、也不依赖 Bingus Shared Loader。

> **状态：0.2.2 —— 两种部署形态均已在游戏内验证通过。** 在构建 25988413 上端到端验证了两种配置：**solo**（loader 单独构成整个 `boot` payload）与 **merge**（追加在第三方 host payload，例如 ArmoryForge 之后）。两种情况下，一个为 Bingus Shared Loader 编写的真实第三方 mod（shock233 的 P2P Ping）都被加载并画出了 HUD，随包附带的 `examples/hud-panel` 也连续绘制正常。实测证据（含**做不到**的部分）见 [docs/COMPATIBILITY.zh-CN.md](docs/COMPATIBILITY.zh-CN.md)。
>
> 首发之后有三个修复值得知道，见 [CHANGELOG.zh-CN.md](CHANGELOG.zh-CN.md)：可被绕过的沙箱写入规则（0.2.1）、以及因 `Gui.resolution` 传参而引发的可复现崩溃（0.2.2）。

---

## 能做什么、不能做什么

| ✅ 能 | ❌ 不能 |
|---|---|
| 加载纯 Lua mod（`init` / `update` / `render` / `shutdown`） | **没有 FFI** —— 读写不了游戏内存 |
| BSL 兼容层：`CowboyBingusModLoader.api = 1`、`open_log()`、可包装 `_G.update` | 读不到单位坐标（我们取的每个样本上 `world_position` 都是 `0,0,0` / `1,1,1`，见 `docs/COMPATIBILITY.zh-CN.md` §3） |
| 游戏内 GUI 文本（`Gui.text`）、矩形（`Gui.rect`，一个可用的第三方 payload 在用）、热键 | 改不了 gameplay 数值（伤害、弹药、冷却） |
| `stingray.Network.*`、`GameSession.*` 查询 | 加载不了 FFI 型 mod（而那几乎是整个 BSL 生态） |
| 目录加载 + 固定名兜底（`mods\01`…`mods\20`） | 绕不过引擎的插件签名门禁（错误码 `577`） |

**如果你需要内存补丁或 gameplay 数值，这个 loader 不适合你。** 它覆盖的是信息类与界面类 mod：overlay、HUD 读数、延迟显示、游戏内面板。

---

## 安装（30 秒）

前提：Steam 版《绝地潜兵 2》、**游戏已关闭**、有 PowerShell。

```powershell
# 在仓库根目录执行
powershell -ExecutionPolicy Bypass -File .\tools\install.ps1
```

安装脚本会：

1. 找到你的游戏安装目录（游戏开着会拒绝执行），
2. **先备份你现有的 `data\9ba626afa44a3aa3.patch_0*`** 到 `_backup-<时间戳>\`，
3. 把 loader 的 `patch_0`（三个文件）复制进 `data\`，
4. 告诉你日志会出现在哪。

**通过 Steam 启动游戏**（`steam://rungameid/553850`），然后检查：

```
<game>\mods\loader.log
  === hd2 pure-lua loader start ===
  [host] update/shutdown hooked (prev_update=nil, prev_shutdown=nil)
  [host] init/render hooked (prev_init=nil, prev_render=nil)
  [boot] mods root = mods, found 0 dir(s)
  [boot] loaded 0 mod(s)
```

### 回滚

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\rollback.ps1
```

按提示选择要恢复的备份——包括"安装前先备份一份纯净游戏"这种情况。

---

## 安装一个 mod

```
<game>\mods\<modname>\main.lua        # 你的 mod
<game>\mods\mods.txt                  # 每行一个目录名
```

`mods.txt`：

```
# 以 # 开头的行是注释
hello
my-other-mod
```

放在 `mods\01` … `mods\20` 里的 mod **即使不写进 `mods.txt` 也会被自动加载**（loader 用能否打开 `<dir>\main.lua` 来探测；之所以只能这样，是因为 `io.popen` 会阻塞游戏主线程，没法用来枚举目录）。

### 最小 mod

```lua
-- mods\hello\main.lua
local M = { name = "hello", version = "1.0.0" }

function M.init()
    local f = io.open("mods\\hello.log", "a")
    if f then f:write("hello from the loader\n"); f:close() end
end

function M.update(dt)
    -- 每帧调用一次
end

function M.shutdown()
end

return M
```

完整编写指南（含沙箱 API 的精确清单）：**[docs/MODDING.zh-CN.md](docs/MODDING.zh-CN.md)**。

---

## 为什么会有这个项目

2026-10-20，Arrowhead 把《绝地潜兵 2》从 GameGuard 换成了 Easy Anti-Cheat，游戏构建也随之变成 **25988413**。自那以后：

- **Bingus Shared Loader v20** 在不支持的构建上不会启动任何 mod（它的构建门禁是故意的），并且
- 它唯一的注入入口——Lua 资源 `core/wwise/lua/wwise_flow_callbacks`——**在本构建中已经不存在**（游戏内实测：`Application.can_get("lua", …)` 返回 `false`），并且
- 生态里更重的项目改用了一个独立的离线客户端。

于是 `boot` 资源覆盖成了零售客户端上唯一还活着的 Lua 入口。这个 loader 只用了它，没别的。

---

## 技术说明

loader 就是单个 Lua 文件，被追加进 `data/9ba626afa44a3aa3.patch_0` 归档的 `boot` 资源里：

- 归档布局：**72 字节头部**（magic、计数、`0x20` = 256 字节对齐的容量）+ 32 字节类型头 + 80 字节 TOC 条目，资源区起始于偏移 **192**；资源块后**不做**尾部对齐（判定依据：用同一套规则重打原始 payload，可做到逐字节一致），
- loader **无条件定义引擎的全部四个钩子**——`init`、`update`、`render`、`shutdown`——并用 `pcall` 串接已有的实现。这一步不是可选项：缺 `init` 或 `render` 的 `boot` payload 会让引擎在 payload 执行完的瞬间于 `helldivers2.exe+0x79A553`（`0xC0000005`）崩溃。我们学习格式所用的那个第三方 payload 恰好把四个槽位都用空函数占了——这就是"merge 版一直正常、solo 版一上来就崩"的原因。详见 [docs/TROUBLESHOOTING.zh-CN.md](docs/TROUBLESHOOTING.zh-CN.md)，
- loader 是幂等的（重复追加不会重复安装），
- mod 运行在 `setfenv` 沙箱里：白名单标准库、读随意但写只能落在 `mods` 内的 `io`、完整的 `stingray` 命名空间，以及 BSL 兼容层，
- 同一个钩子上抛错 10 次的 mod 会被禁用，而不是每帧刷日志，
- `os.execute` 与 `io.popen` **不暴露**给 mod：在游戏进程内它们会阻塞主线程，游戏会变成无响应（`Responding=False`）——这是实测，不是推断。

自己构建：

```powershell
# 常规构建 —— loader 单独构成整个 boot payload
python loader\build_loader_patch.py --solo

# 把 loader 追加到你自己的第三方 boot payload 之后，让两者共存
python loader\build_loader_patch.py --host-payload path\to\host_payload.lua

# 可选：额外携带一个很小的 lua 资源（用于证明归档可以带多资源）
python loader\build_loader_patch.py --solo --probe-resource

# 可选：让打包器先对着一份已知正确的归档自证，否则拒绝写出任何东西
python loader\build_loader_patch.py --solo --host-payload path\to\host_payload.lua --verify-original path\to\original.patch_0
```

产物写到 `loader\dist\`。**`releases\current\` 里附了一份预构建的 solo patch**，所以安装完全不需要 Python。

所有路径都以脚本自身位置为基准解析。第三方 host payload **不随仓库分发**——自备，或者用 `--solo`。若系统里有 `luac`，会被当作语法闸门（用 `LUAC` 环境变量指定）；没有也能构建，只是会明确告诉你跳过了。64 位的 `luac` 解析**源码**没问题——它只解析不了游戏自己的字节码 dump（那是 32 位 `size_t`）。

`--verify-original` 会用同一套规则重打一份参考归档，字节不一致就拒绝写出。本仓库的打包规则正是这样确立的：参考归档（**797,815 B** 文件 = 192 B 头部 + 797,623 B 资源区，其中装着一份 797,615 B 的 Lua 源码）可以被逐字节复现。**这三个数字要分清**——把它们混成一个，正是本项目已经不得不更正过一次的错误。

---

## 来源与 AI 披露

本仓库的代码、文档以及大部分实验设计，由**AI 编码代理**（DSH，基于 DeepSeek）在作者本人的机器上、按作者要求起草。每一次游戏启动都发生在同一台机器上，并且都由作者授权、逐条复核命令。把这件事直说，比藏着更有用：它告诉你该对哪些东西打折。

它**不等于**下面这些：

- 本页没有任何一个数字来自模型的记忆。每个测量都来自对构建 25988413 零售版的真实一次运行，并且可以追溯到具体的日志行、崩溃 dump、或仍然存在的文件；
- 凡是超出直接观测的推理，文中都写明了。`docs/COMPATIBILITY.zh-CN.md` 里那四处推断，已经在开头逐条点名；
- 崩溃地址是用 minidump 按 `ExceptionAddress − 模块基址` 算出来的，不是猜的；
- 本项目已经因为重读自己的日志而更正过两次——一次是把三个不同的长度混成同一个数字（payload 大小），一次是关于签名门禁的一个理论被单个反例推翻。两次更正都记在 [CHANGELOG.zh-CN.md](CHANGELOG.zh-CN.md) 里。

请按日志来权衡证据，而不是按行文。

---

## 许可

MIT —— 见 [LICENSE](LICENSE)。随便用，不提供任何担保。

本项目不含任何游戏资产，也不再分发任何第三方 mod payload；随包发布的补丁里只有 loader 自己的 Lua 源码。与 Arrowhead Game Studios 及 Sony Interactive Entertainment 无关。HELLDIVERS 是 Sony Interactive Entertainment 的商标。请自行斟酌使用。
