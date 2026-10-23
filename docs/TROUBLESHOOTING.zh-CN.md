# 故障排查

**简体中文** | [English](TROUBLESHOOTING.md)

> 本文是 [TROUBLESHOOTING.md](TROUBLESHOOTING.md) 的中文对照版。如有出入，以英文版为准。

这里每一条都是本项目**真实踩过**的故障，并附上定位它的那次实测。症状 → 原因 → 修法。

---

## 1. loader 写完头几行日志后，游戏立刻崩溃

**症状。** `mods\loader.log` 里有 `=== hd2 pure-lua loader start ===` 和 `[host] … hooked …` 那几行，然后什么都没有了。进程死掉。没有任何 Lua 报错。`%APPDATA%\Arrowhead\Helldivers2\dumps\` 里多出一个 dump：

```
ExceptionCode    0xC0000005
ExceptionAddress helldivers2.exe + 0x79A553
```

**原因。** `boot` payload 没有定义全部四个引擎钩子。引擎会调用 `init`、`update`、`render`、`shutdown`，并且**不做空值检查**；缺一个就是宿主 Lua 错误路径里的一次空调用。

**修法。** 无条件定义全部四个，哪怕其中一些是空函数，并把原有的实现用 `pcall` 串接起来。本 loader 自 0.2.0 起就是这么做的。如果你在写自己的 payload，照抄这个模式：

```lua
init, shutdown, update, render = noop, noop, noop, noop   -- 先把四个槽位全占住
```

**为什么容易漏：** merge 构建（你的 payload 追加在一个已经占满四个槽位的第三方 payload 之后）完全正常，所以这个 bug 只在 solo 构建里现形。

---

## 2. 什么都没发生 —— 没有日志文件，也没崩

**症状。** 游戏正常启动并运行，`mods\` 里没有 `loader.log`。

**原因 A —— 补丁槽位不对。** 本构建**只读 `data\9ba626afa44a3aa3.patch_0`**。放进 `patch_14`（或任何其它编号）的 payload 永远不会被读取。实测：同样的字节放 `patch_14` → 毫无反应；放 `patch_0` → 立刻生效。

**原因 B —— 你在游戏运行时才复制文件。** 归档是在启动时读的；游戏开着的时候复制 `patch_0`，要等下次启动才生效。

**原因 C —— 缺 sidecar 文件。** 三个都要给：`…patch_0`、`…patch_0.gpu_resources`、`…patch_0.stream`。后两个可以是 0 字节，但文件必须存在。

---

## 3. 游戏卡死；`Responding=False`；冒出一个 `cmd.exe`

**症状。** 游戏窗口冻住，任务管理器显示"无响应"，并且有一个 `cmd.exe`，它的父进程是 `helldivers2.exe`。

**原因。** 游戏进程内部有人调了 `os.execute` 或 `io.popen`。这两个都会永久阻塞主线程——它们启动一个子进程，然后在"还得负责泵游戏消息"的那条线程上等它。

**修法。** 永远不要暴露、也不要用它们。本 loader 不用，也不交给 mod。你必须接受的后果：

- 你没法从 Lua 创建目录 —— 自己把 `mods\` 的目录结构准备好，
- 你没法枚举目录 —— 所以才有 `mods\mods.txt` 清单加上 `01`…`20` 探测（`io.open("<dir>\\main.lua")` 是唯一不需要起进程就能判断"这个目录里有没有入口"的办法）。

**注意。** 在游戏外跑的 Lua 测试脚本用 `os.execute` 完全没问题；那种环境下出现 `Permission denied` 也不能说明游戏里会失败。

---

## 4. `loader.log` 全是乱码

**症状。** 用 PowerShell 读日志时，本该是中文的地方显示 `����`。

**原因。** loader 写的是 **UTF-8**；Windows PowerShell 默认按 ANSI 代码页（中文系统上是 GBK）读。

**修法。**

```powershell
Get-Content .\mods\loader.log -Encoding UTF8
# 或者
[System.IO.File]::ReadAllLines("…\mods\loader.log", [System.Text.Encoding]::UTF8)
```

---

## 5. 读某个 mod 的日志时报"文件正被另一进程使用"

**原因。** 那个 mod 整局都保持着它的日志句柄（P2P Ping 就是）。`[System.IO.File]::ReadAllLines` 会失败；`Get-Content` 能容忍。

**修法。** 用 `Get-Content`，或者准备一个能读"可能被占用文件"的读取器。如果你写自己的 mod，就每行 open/write/close。

---

## 6. 你打包出来的归档行为和原版不一样

**症状。** 你重打了一份本该完全相同的 payload，游戏却不理它；或者某个归档解析器和游戏说法不一致。

**原因 —— `0x20` 字段。** 这个归档格式里，`0x20` 字段是**向上对齐到 256 字节的容量**，不是数据的真实末尾。把真实长度写进去，产出的归档游戏不会读。

**原因 —— 尾部对齐。** 资源块**不要**补 16 字节对齐。参考打包器没有这一步。

**怎么确认：** 用你的打包器重打**已知正确的原始** payload，在把任何一个改动托付给它之前，先要求字节完全一致。`build_loader_patch.py --verify-original` 干的就是这个：它能把参考归档——**797,815 B 文件** = 184 B 头部向上取到 192 B + **797,623 B** 资源区，里面装着一份 **797,615 B** 的 Lua 源码——逐字节复现。**这三个数字要分清**；把它们混成一个，正是本项目和曾经公开发表过的错误说法。

按本仓库实现的布局（全部小端）：

```
0x00  u32  magic = 0xF0000011
0x04  u32  num_types
0x08  u32  num_files
0x0C  20 B 填充
0x20  u64  容量        （= 数据末尾向上对齐到 256）
0x28  u64  未知        (0)
0x30  24 B 填充                          → 头部共 72 字节
0x48  num_types × 32 B  <IIQIIII>  (0, 0, type_id, count, 0, 16, 16)
      num_files × 80 B  <7Q6I>     (file_id, type_id, offset, 0,0,0,0,
                                    data_size, 0, 0, 16, 16, index)
      align16 → 资源区
            u32 lua_len, u32 mode(=2), lua 源码
```

`file_id` = `MurmurHash64A(资源名, seed 0)`。已在游戏内交叉校验：`Application.make_hash("boot")` 返回 `f476df93691895fa`，正是本项目使用的 id。

---

## 7. `luac5.1 -l dump.luac` 报 "bad header in precompiled chunk"

**原因。** 随附的 `luac5.1.exe` 是 **64 位**构建（`size_t` = 8）。游戏的 Lua 是 **32 位**（`size_t` = 4）。两者头部第 8 个字节不同，所以原版反汇编器拒绝这个文件。

**修法。** 自己按 `size_t` = 4 解析字节码。`tools/lua51_disasm.py` 就是这么干的，并且处理了两个很容易搞错的结构细节：

1. `string.dump` 出来的 main chunk 后面**直接**是 source 字符串——没有单独的 `sizeupvalues` 字节，
2. 顺序是 `code → constants → debug → protos`，而在 Stingray 的 Lua 变体里整个 **debug 段被剥掉了**，所以 `constants` 之后紧接着就是 `sizep`。

---

## 8. BSL 风格的 mod 加载成功但从不 tick

**症状。** 出现 `[load] <name> ok`，然后没了。

**原因。** BSL mod 不返回 table，它们在自己的 chunk 里包装全局 `update`。如果 loader 沙箱里的 `update` 槽位缺失或已被占用，它们的包装就永远装不上。

**修法 / 诊断。** loader 在第一次调用某个 mod 包装后的 `update` 时会写 `[bsl] first tick -> <name>`。没有这行，要么是那个 mod 根本没包装任何东西，要么是它提前退出了。看它自己的日志（`loader.open_log`）里有没有退出原因。

早期实测的一个相关陷阱：第一版沙箱没有暴露 `rawget`/`rawset`，一个真实的 BSL mod 在它第 4 行就以 `attempt to call global 'rawget' (a nil value)` 死掉了。这两个都是纯 Lua 操作，是**必需项**，不是可选项。

---

## 9. 一个探针把游戏搞崩了，但你不知道是哪个调用

**有效的流程**（`COMPATIBILITY.zh-CN.md` 里每个 RVA 都是这样定位出来的）：

1. **在每一个可能崩的引擎调用之前写一行带编号的日志。** `pcall` 接不住访问违例；最后写出的那一行就是你的崩溃点。
2. **每个未知 API 只调一次**，拿到返回类型，再决定要不要循环。批量设计（每帧 5 个单位）在第一次崩时就把信息全丢了。
3. **把调用之间拉开时间**（隔几秒），这样活着的那几条才分得清。
4. 让它崩，然后换算地址：

```powershell
# ExceptionAddress - 模块基址 = RVA
python …\dump_exc_module.py  "%APPDATA%\Arrowhead\Helldivers2\dumps\dump-….dmp"
```

5. 拿 RVA 去对已知表。四个崩点聚在 `0x3C0000–0x3F0000`（同一段"查表后解引用"的代码），Lua 层的失败则在 `+0x79A5xx` 附近。

**不要**相信 dump 里的调用栈：报出来的栈帧是 crashpad 自己的（`dbgcore.dll+0x108`、`ntdll!Rtlp…`），所以只有 `ExceptionAddress` 和寄存器是可信的。

---

## 10. Steam 的「验证游戏文件完整性」与 loader

**2026-10-23 实测：它不会删掉 loader。** 会有人告诉你相反的说法——我们自己也曾这么以为，直到真跑了一次。

Steam 只校验它自己清单里有的文件。它不认识的文件，它不动。我们在一次完整验证前后对 `bin\` 与 `data\` 全量快照对比：

| | 验证前 | 验证后 |
|---|---|---|
| `bin\` 文件 | 45 | 45，SHA256 全部一致 |
| `data\` 文件 | 99 | 99 |
| `data\9ba626afa44a3aa3.patch_0` | 821,753 B | 仍在，SHA256 不变 |
| `bin\hd2probe\`（我们自己的子目录） | 19 个文件 | 19 个文件 |

**真正会删掉它的是：游戏更新。** 构建一变，Steam 会替换它管理的 `data/` 内容；更何况本项目崩点表里的每个地址都是随构建变化的——新构建下，无论文件在不在，loader 都失效。

所以：验证文件是安全的，需要提前规划的是游戏更新。

---

## 11. 两个 `boot` mod：只有一个生效

**症状。** 你又装了一个同样覆盖 `boot` 资源的 mod，结果两者之一无声失效。

**原因。** 本构建读 `boot` 内容时**只认一个槽位**：`data\9ba626afa44a3aa3.patch_0`。它不是队列也不是栈——两个 `patch_0` 不能共存，而放在 `patch_1`…`patch_14` 的 payload 永远不会被读取。谁最后写进 `patch_0`，谁赢。

**修法。** 不要二选一，把它们合并成一个 payload：用 `--host-payload <另一个 mod 的 boot payload.lua>` 构建，loader 会追加在宿主 Lua 之后，并 `pcall` 串接它的 `init` / `update` / `render` / `shutdown`，两个 mod 就在同一个 chunk 里一起跑。若宿主 payload 不是明文 `.lua`（已经封进归档了），需要先提取出来。

注意顺序约束：宿主 payload 必须把 `update`/`shutdown` 定义为**全局**，且不能以顶层 `return` 结尾——否则没有东西可串接。四钩子要求在 [§1](#1-game-crashes-right-after-the-loader-logs-its-first-lines) 里。

---

## 12. 通过 HD2MM 部署之后，我手工装的 patch 全没了

**症状。** 在 HD2MM 里部署了某个 mod，之前手工复制进 `data\` 的其它 mod 全部消失——没有提示，回收站里也没有。

**原因。** HD2MM 的 **Deploy** 会让 `data\` 与**已启用 mod 的集合**保持一致：它先把所有 `9ba626*.patch_*` 文件删掉，然后只铺已启用 mod 提供的那几个。它不管理的文件会一并消失。这是设计如此，不是 bug——但对**手工装的**内容是破坏性的。

**2026-10-23 实测：** 只启用本 loader 就删掉了 **36 个 patch 文件 / 314 MB** 手工放置的内容——`patch_1.gpu_resources`（121 MB）、`patch_9.gpu_resources`（85 MB）、`patch_8.stream`（67 MB）、`patch_4`（30.5 MB）等。回收站里一个都没有，HD2MM 的 `Temp` 目录也是空的。

**该备份什么——patch 家族，不是整个 `data\`。** `data\` 里大部分是官方文件，Steam 能恢复；真正不可替代的是 patch 文件：

```powershell
$bk = "E:\hd2mm-backup\$(Get-Date -Format yyyyMMdd-HHmm)"
New-Item -ItemType Directory -Force -Path $bk | Out-Null
Copy-Item "<游戏目录>\data\9ba626*.patch_*" $bk -Force
```

恢复就是反向复制。HD2MM 自己管理的 mod 不需要这样备份——它们的原始 ZIP 还在 HD2MM 的 `Mods` 目录里，重新部署即可。

---

## 13. "这个构建到底还允许脚本 mod 吗？"

实测答案：**允许，走这条路线就允许。** `.patch` 归档照样加载，引擎的 Lua 状态照样执行 `boot` payload，`Script.load` 照样返回可调用的 chunk。2026-10-20 死掉的是：(a) 第三方加载器，(b) 签名 DLL 插件加载。所以如果你在排查"Lua 是不是死了"，答案是没死——先检查你的部署槽位和钩子集合。

---

## 14. 你改了 loader，想知道还能不能用

```powershell
# 1. 语法闸门（零启动次数就能拦下 Lua 5.1 特有的错误）
luac5.1 -p loader\loader_core.lua

# 2. 构建；--verify-original 会重打参考归档并要求字节一致
python loader\build_loader_patch.py --solo --verify-original path\to\original.patch_0 --host-payload path\to\host_payload.lua

# 3. 部署前的结构自检
python …\verify_solo_patch.py        # 每个头部/TOC 字段对打包规则

# 4. 关着游戏部署，通过 Steam 启动，读 mods\loader.log
Start-Process 'steam://rungameid/553850'
```

预期的 solo 日志（没有第三方 host payload 时）：

```
=== hd2 pure-lua loader start ===
[host] update/shutdown hooked (prev_update=nil, prev_shutdown=nil)
[host] init/render hooked (prev_init=nil, prev_render=nil)
[boot] mods root = mods, found 2 dir(s)
[load] hello-loader-test ok (version=1.0.0)
[boot] loaded 2 mod(s)
```

`prev_*` 为 `nil` 说明是 solo 构建，为 `function` 说明是 merge 构建——这是判断"你实际跑的到底是哪一种"最省事的办法。

---

## 15. `data\` 里的第二个 patch 被静默忽略

引擎按**连续序号**合并 `data\<bundle>.patch_N`：序号链中间一旦出现空洞，洞后面的补丁**完全不会被读到** —— 文件在磁盘上、哈希也对，但游戏当作它们不存在。

本构建上的实测（另一组人做的对照实验）：把 `patch_1`、`patch_2` 删掉只留 `patch_3`，六个探针 mod 全部 `absent`（0 找到 / 0 加载 / 6 缺失）；补成连续的 `patch_0..patch_3` 之后，同样的探针 3 / 3 / 3 全部加载。

怎么办：

- 从 `patch_0` 往上保持连续，**不要**在"整理"时删掉中间某个槽位。
- 如果你只用这个 loader，**根本不需要额外槽位** —— 一个 `patch_0` 就是完整安装。HD2MM 的 Deploy 在这里反而帮了忙：它把其它 `9ba626*.patch_*` 全部清掉、只留一个连续的 `patch_0`（这个行为的代价见第 12 条）。
- 如果你手工叠了多个 patch，先查编号连续性，再怀疑 mod 本身。

*注：* 那条对照是另一组人的一次观察（洞态 0/0/6 与连续态 3/3/3），我们还没有自己重跑；但机制与我们对 `patch_N` 加载的全部认识一致 —— 引擎在启动时按顺序读整条链（见 `docs/COMPATIBILITY.zh-CN.md` §2）。
