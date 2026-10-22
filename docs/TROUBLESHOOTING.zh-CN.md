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

## 10. 在 Steam 里"验证游戏文件完整性"之后，loader 消失了

**症状。** 本来一切正常，某天游戏启动后 `mods\loader.log` 完全不再出现，也没有崩溃。

**原因。** Steam 的「验证游戏文件完整性」会拿 `data\` 跟官方清单比对。我们的 `9ba626afa44a3aa3.patch_0` 不在官方清单里，于是被删掉（严苛一些时连 `.gpu_resources` / `.stream` 两个 sidecar 一起删）。部分游戏更新后也会发生同样的事。

**修法。** 重跑 `tools\install.ps1`。什么都没坏——只是 loader 不再处于已安装状态。装完确认三个文件都在，下次启动就会有 `loader.log`。

---

## 11. 两个 `boot` mod：只有一个生效

**症状。** 你又装了一个同样覆盖 `boot` 资源的 mod，结果两者之一无声失效。

**原因。** 本构建读 `boot` 内容时**只认一个槽位**：`data\9ba626afa44a3aa3.patch_0`。它不是队列也不是栈——两个 `patch_0` 不能共存，而放在 `patch_1`…`patch_14` 的 payload 永远不会被读取。谁最后写进 `patch_0`，谁赢。

**修法。** 不要二选一，把它们合并成一个 payload：用 `--host-payload <另一个 mod 的 boot payload.lua>` 构建，loader 会追加在宿主 Lua 之后，并 `pcall` 串接它的 `init` / `update` / `render` / `shutdown`，两个 mod 就在同一个 chunk 里一起跑。若宿主 payload 不是明文 `.lua`（已经封进归档了），需要先提取出来。

注意顺序约束：宿主 payload 必须把 `update`/`shutdown` 定义为**全局**，且不能以顶层 `return` 结尾——否则没有东西可串接。四钩子要求在 [§1](#1-game-crashes-right-after-the-loader-logs-its-first-lines) 里。

---

## 12. "这个构建到底还允许脚本 mod 吗？"

实测答案：**允许，走这条路线就允许。** `.patch` 归档照样加载，引擎的 Lua 状态照样执行 `boot` payload，`Script.load` 照样返回可调用的 chunk。2026-10-20 死掉的是：(a) 第三方加载器，(b) 签名 DLL 插件加载。所以如果你在排查"Lua 是不是死了"，答案是没死——先检查你的部署槽位和钩子集合。

---

## 13. 你改了 loader，想知道还能不能用

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
