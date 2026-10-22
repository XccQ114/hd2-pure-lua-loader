# 兼容性与实测证据

**简体中文** | [English](COMPATIBILITY.md)

> 本文是 [COMPATIBILITY.md](COMPATIBILITY.md) 的中文对照版。如有出入，以英文版为准。

以下内容几乎全部来自零售版 Steam 安装的实测。凡是**超出直接观测**的推理，句子里会写明（`推断`、`观测到`、`未测试`）——请把那些当作**推断**，而不是测量结果。当官方 Stingray Lua API 参考与本构建的实际行为冲突时，**以实测为准**——本项目已经在这上面栽过两次。

本文标注为推断的有：Lua 的"静态链接"（我们只观测到不存在独立 DLL）、`WinVerifyTrust` 的**位置**（我们数了出现次数，没有跟踪调用）、四个 RVA 的分桶规律、以及那约 1706 个无法枚举的单位到底是什么。

- **游戏构建：** 25988413（Steam 零售版，Easy Anti-Cheat 生效）
- **Lua：** 5.1.4，`sizeof(size_t)` = **4**（32 位），`sizeof(int)` = 4，`integral` = 0，`num` = 8 —— 后四项是 `string.dump` 字节码头里的字段，从三份互相一致的 dump 中读出。
- **Lua 看起来是静态链接进 `data/game/game.dll` 的** —— 本构建**完全没有** `bin/lua51.dll`（旧构建 25480438 带一个，469,080 B）。*推断：*我们观测到的是"这个 DLL 不存在"，而不是链接关系本身。
- **签名 / 脚本 mod 门禁：** 字符串 `WinVerifyTrust` 在 `bin/helldivers2.exe` 里出现 **1 次**（约 `+0x14979B8`），在 `data/game/game.dll` 里出现 **0 次**。*推断：*因此签名校验跑在宿主 exe 里，而不是引擎 DLL 里。我们**没有**检查反作弊服务自己的二进制，所以对它不作任何断言。

---

## 1. 引擎 API —— 实测状态

### 可用（可以放心调用）

| 调用 | 实测结果 |
|---|---|
| `Application.worlds()` | 返回 11 个 world 的表 |
| `Application.make_hash(name)` | `make_hash("boot")` → `"f476df93691895fa"`，与归档里使用的资源 id 一致 |
| `Application.can_get(type, name)` | 双参数形式安全，返回 bool。`type` 字符串不被校验 |
| `Application.set_resource_override(type, name, other)` | 可用，见 §5 |
| `Application.clear_resource_override(type, name)` | 可用，能恢复先前状态 |
| `stingray.Script.exists(name)` / `Script.load(name)` | `load` 返回**可调用的 chunk**；执行它时全局环境完整（`io`、`os` 都可用） |
| `string.dump(fn)` | 可用；产出的字节码是 32 位 `size_t` |
| `World.entities(world)` | 369 个真 Entity userdata 的表（`ud:[Entity "name" id:version]`） |
| `World.num_units(world)` | 局内 2303（probe13），舰船场景 62 |
| `World.levels(world)` / `Level.units(level)` | 见 §3 |
| `World.unit_by_name(w, name)` | 名字不存在时返回 `nil`，不崩 |
| `World.units_by_resource(w, res)` | 资源不存在或空串时返回 0 长度表，不崩 |
| `World.load_prefab(w, name)` | 可用（prefab 实例的唯一来源） |
| `Unit.debug_name` | 返回可读的 `#ID[<hash>]` 串——唯一稳定的身份字段 |
| `Unit.alive`、`Unit.resource_name` | 可用（bool / IdString64） |
| `Gui.text`、`Gui.resolution`、`Gui.set_visible`、`World.create_screen_gui` | 可用；字体 `core/performance_hud/debug` 确实以 `font` 类型存在 |
| `Network.ping`、`Network.game_session`、`GameSession.peers`、`GameSession.game_session_host` | 可用；主菜单里也有 session（`peers=1`） |

### 会让进程崩溃（不要调用）

| 调用 | 模块 + RVA | 异常 |
|---|---|---|
| `World.units(world)` | ——（无 dump） | 进程直接死 |
| `UnitComponent.unit(component, entity)` | `helldivers2.exe+0x3EB121` | `0xC0000005`，`rdi=0` 空指针解引用 |
| `World.unit_by_id(world, id)` | `helldivers2.exe+0x3C07D9` | `0xC0000005` |
| `Unit.has_mesh` / `Unit.is_a` | `helldivers2.exe+0x3E7CA3` | `0xC0000005` |
| `Application.set_resource_override(type, name, nil)` | `helldivers2.exe+0x3D203F` | `0xC0000005` |
| `Application.can_get(x)`（单参数） | ——（无 dump） | 进程直接死 |
| 未定义 `init` 或 `render` 的 `boot` payload | `helldivers2.exe+0x79A553` | `0xC0000005` |

两条值得记住的规律：

- 四个 RVA `0x3C07D9`、`0x3D203F`、`0x3E7CA3`、`0x3EB121` 全落在 `0x3C0000–0x3F0000` 区间。*推断：*这是同一段"查表后直接解引用结果"的代码，从不做空值检查。由此得到的经验法则（**凡是按 id 反查的都是雷区，凡是按名字/按资源批量的都做了空值检查**）是我们在约 10 个调用上观察到的模式，不是保证。
- `+0x79A553`（缺钩子）与 `+0x79A511`（Lua chunk 非法）相距 0x42 字节——是宿主的 Lua 错误路径。崩在这里的含义是"宿主无法把手交给 Lua"，不是"你的 Lua 抛错了"。

### 有文档但不可用

官方 Stingray Lua API 参考把 `UnitComponent.unit(self, entity)` 记为返回 `stingray.Unit`。在本构建上它对第一个 entity 就崩。**把官方文档当作"候选清单"，绝不要当作"能力清单"。**

---

## 2. loader 实际能交付什么

| 能力 | 状态 |
|---|---|
| 从 `mods\<name>\main.lua` 加载 mod | 能 |
| 加载 N 个 mod，用 `pcall` 隔离，连续 10 次错误自动禁用 | 能 |
| **零改动**运行 BSL 时代的第三方 mod（`CowboyBingusModLoader.api == 1` 兼容层） | 能 —— 已用 P2P Ping（作者 shock233）画出游戏内 HUD 验证 |
| 绘制 GUI 文本 / 矩形，读取 `Network.*` | 能 |
| 向 mod 分发 `init` / `update` / `render` / `shutdown` | 能 |
| 读写游戏内存 | **不能** —— 没有 `ffi`、没有 `jit`、没有 `require` |
| 改 gameplay 数值（伤害、弹药、冷却） | **不能** —— 见 §6 |
| 读单位坐标 | **不能** —— 见 §3 |
| 枚举动态单位 | **不能** —— 见 §3 |
| 加载 DLL / 插件型 mod | **不能** —— 见 §7 |

---

## 3. 单位 —— 能枚举什么、不能枚举什么

- `Application.worlds()` → 11 个 world。主 world 在局内报告 `num_units = 2303`（probe13 的值；更早一次探针在同一场景录到 2307 —— 这个数字逐帧浮动，请当作"约 2.3k"）。
- `World.levels(main_world)` → 一个 `Level` userdata；`Level.units(level)` → **597** 个 unit，不崩。
- 那 597 个是**关卡的静态内容**（舰船 / 场景的模型部件）：109 种不同资源 id，`num_meshes` 分布 1–9，`alive == false` 的有 0 个。
- 剩下约 1706 个**通过我们试过的任何通道都无法枚举**。*推断：*它们是运行时生成的（敌人、投射物、载具）—— 我们从来没有直接枚举到它们，只观测到三条通道都会崩。三条通道：`World.units`、`UnitComponent.unit`、`World.unit_by_id`。
- **坐标读不出来。** `Unit.world_position` 恒为 `Vector3(0,0,0)`；`Unit.world_pose` 返回 `Matrix4x4`，但分量是 `1e-42 / -nan / …`——整数被当浮点解释的无效位模式，典型未初始化内存。`Unit.id` → `nil`。`Unit.name_hash` → 乱码字符串（不要用）。

**结论：** 自瞄 / ESP / 距离判定这类 mod 从这个 Lua 面触不到。任何需要"某个动态单位的位置"的功能，都是 native 层的问题。

---

## 4. Lua 资源名空间

本构建上已知可达的 `lua` 资源名只有三个：

| 名称 | `can_get("lua", …)` |
|---|---|
| `boot` | `true` |
| `core/wwise/lua/wwise_visualization` | `true` |
| `core/wwise/lua/wwise_bank_reference` | `true` |
| `core/wwise/lua/wwise_flow_callbacks`（BSL 唯一的注入入口） | **`false`** |

`make_hash("core/wwise/lua/wwise_flow_callbacks")` 仍然返回 `7251fdd9bb62480a`，与 Bingus Shared Loader 自己 `docs/TECHNICAL.md` 记录的哈希一致——所以名字是对的，资源是真的不可用。BSL 因此在本构建上有**两个互相独立**的失败原因：(1) 它 v20 的**构建门禁**会刻意在不支持的构建上不启动任何 mod；(2) 它唯一的注入入口已经没了 —— 即使把门禁拆掉，它照样起不来。

枚举这条路是结构性封死的：客户端侧所有索引（`bundles.nxa`、`bundle_database.data`、`bundles.region_hints`）只存哈希与偏移，从不存路径，而 `dl_library.dl_typelib` 是加密的。一次 1,578 个生成候选的暴力扫描，**命中数为零**。社区 HD2 SDK 的哈希表确实提供了 4,036 个真实名字——但那是**内容**资源，对引擎 `lua` 的条目数为 **0**。

因此 loader 除了 `boot` 本身之外不依赖任何引擎资源名，它自己的模块是作为同一个 patch 里的附加资源承载的（见 §5）。

---

## 5. 资源覆盖是"别名"，不是"注入"

单次会话内实测的闭环：

```
can_get('lua','hd2probe/override_target')                      = false
set_resource_override('lua','hd2probe/override_target','boot') -> nil
can_get('lua','hd2probe/override_target')                      = TRUE
clear_resource_override('lua','hd2probe/override_target')      -> nil
can_get('lua','hd2probe/override_target')                      = false
```

也就是说，第三个参数是**另一个资源名**，这个操作的语义是"让名字 A 解析到已存在的资源 B"。它无法凭空创造内容：给 `nil` 会崩（`+0x3D203F`）。这里要交代清楚**到底测了什么**——我们试过 `nil`（崩）和资源名字符串（可用）。路径字符串和对象**没有**试过，所以早先那句"不是路径、不是对象"是假设，不是测量。

相关但互不相通：`has_data('lua', <名字>)` 对一个已被覆盖的名字仍然返回 `false`，`get_data` 返回 `nil`。DataLibrary 那条通道（`get_data`/`set_data`/`has_data`）与资源覆盖通道**不互通**；你没法通过 `set_data` 注入 Lua 源码。

一个 patch 归档**可以**携带任意多个 `lua` 资源——已验证：加入第二个资源后 `can_get("lua","hd2probe/injected")` 为 true，对 `Script.load` 拿到 chunk 并执行，代码在游戏进程内成功写盘。loader 正是靠这条路径承载那些不该放在 `mods\` 里的模块。

---

## 6. Gameplay 数值是"数据资源"问题

`data/game/` 下的 `.dl_bin` 是 **libsodium sealed box**（32 字节临时公钥 + 16 字节 Poly1305 tag + XSalsa20 密文；固定 48 字节开销）。改数值意味着产出一个新的 sealed box，而这需要接收方密钥——密钥在随游戏发布的二进制里不存在明文（文档记载的那个 RVA 在当前未加壳的 `helldivers2.exe` 里读出来是全零，XOR 常量 `0xEB63463F0C116E2C` 在旧加壳 EXE、新 EXE、以及 49 MB 的 `game.dll` 里都匹配不到）。

生态里有两种绕开方式，都与本 loader 无关：

- 作者手里本来就持有预封装好的 payload（例如 ArmoryForge 在它的 `boot` payload 里直接带了 32 份），或者
- 先对着数据库的明文镜像做离线分析，再由作者侧重新封装。

loader 的职责止于"你的 Lua 模块能被执行、并且有完整的引擎访问权"。数值是另一条路线的事。

---

## 7. Native / 签名 DLL 路线

给需要它的人：加载一个 native 插件要过**两**道门。

| 关卡 | 失败码 | 含义 |
|---|---|---|
| PE / 映射层 | `193` | 映像无法映射（路径 / 来源 / 名字冲突，不是策略判定） |
| Authenticode 签名 | `577` | 没有一个来自**公开信任链**的有效签名 |
| 两关都过 | `127` | 加载成功 |

证据：未签名的第三方 DLL → `577`；自签并把根证书导入 `LocalMachine\Root`（Authenticode 报 Valid）→ 仍然 `577`，所以**本地安装的根不算**，必须是公开信任链。证书过期 → `577`（样本之一：DigiCert EV，2022 到期）。把已加载的系统 DLL 复制 / 改名到别处 → `193`，这就是为什么 `193` 绝不能被读成"签名被拒"。

这条不属于本 loader。记在这里，是因为所有"为什么不直接做 X"的问题最终都撞在它上面。

---

## 8. 未验证 / 开放问题

- 运行时是否还能加载**别的**引擎 `lua` 资源（名字空间已封，见 §4）。
- `render` 是否在所有游戏状态下都逐帧被调用（它被定义是因为缺了会崩；mod 不应依赖它的调用频率）。
- 25988413 之外的构建上的行为。这里的任何结论都不会自动迁移；RVA 与钩子集合都是随构建变化的。
