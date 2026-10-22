-- ============================================================================
-- HD2 Pure-Lua Mod Loader — boot payload 注入段（Lua 5.1）
--
-- 目标：在 build 25988413 上，不依赖 Bingus Shared Loader、不依赖任何签名 DLL，
--       提供一个能加载多个纯 Lua mod 的最小主机。
--
-- 设计约束（全部来自本机实测）：
--   * 这个 Lua 状态没有 ffi / jit / bit —— 所以只支持纯 Lua mod
--   * io.open 可用；io.popen / os.execute 在游戏进程内会卡死主线程（禁用）
--   * loadstring + setfenv 可用 —— mod 源码加载与沙箱隔离靠它们
--   * pcall 只能接住 Lua 错误，接不住 C 层崩溃 —— 所以每步都要落日志
--   * boot 资源全局唯一 —— 本段必须用 pcall 串接已有的 update/shutdown
--
-- 用法：把本段 append 到某个 boot payload 末尾，然后把 mods 放在
--       <game>\mods\<modname>\main.lua
--
-- mod 约定：
--   main.lua 返回一个 table，可含字段：
--     name, version           —— 元数据（可选）
--     init()                  —— 加载完成时调用一次
--     update(dt)              —— 每帧
--     render(world)           —— 每帧（若有）
--     shutdown()              —— 退出
-- ============================================================================

do
    -- 幂等保护：本段被重复 append 时只安装一次，否则会双层包装并重复加载 mod
    if rawget(_G, "__HD2_PURE_LUA_LOADER_INSTALLED") then
        return
    end
    rawset(_G, "__HD2_PURE_LUA_LOADER_INSTALLED", true)

    ------------------------------------------------------------------------
    -- 路径与日志
    -- 用相对路径：游戏进程的工作目录就是游戏根目录，同目录下的 ArmoryForge
    -- 就是用 "ArmoryForge-OneExtra-Menu.log" 这个相对名写日志并成功的。
    -- 绝对路径在游戏进程内未见成功先例，改成相对路径更贴近已验证的做法。
    ------------------------------------------------------------------------
    local MODS_REL = "mods"
    local LOG_PATH = MODS_REL .. "\\loader.log"
    local BOOT_PROBE = MODS_REL .. "\\loader_boot_probe.txt"

    -- 不再用 os.execute（在游戏内会阻塞主线程）。mods 目录若不存在，
    -- 写日志会直接失败，但不影响其余逻辑。
    local function ensure_file_path()
        local f = io.open(LOG_PATH, "a")
        if f then f:close() end
    end


    local function log(fmt, ...)
        local text
        if select("#", ...) > 0 then
            local ok, s = pcall(string.format, fmt, ...)
            text = ok and s or tostring(fmt)
        else
            text = tostring(fmt)
        end
        local f = io.open(LOG_PATH, "a")
        if f then
            f:write(text .. "\n")
            f:close()
        end
    end

    ensure_file_path()
    log("=== hd2 pure-lua loader start ===")

    ------------------------------------------------------------------------
    -- 目录与文件
    ------------------------------------------------------------------------
    -- io.popen 在游戏内同样会阻塞（起进程读输出），不能用来枚举目录。
    -- 主路径：读清单文件 mods\mods.txt，每行一个 mod 目录名，# 开头为注释。
    -- 兜底路径：清单缺失或漏写时，按固定名约定探测 mods\01 … mods\20
    --          （判据是 <dir>\main.lua 能否打开 —— 这是 io.popen 不可用后
    --           唯一不需要起进程的"目录是否存在"探测方式）。
    local FALLBACK_DIRS = {}
    for i = 1, 20 do FALLBACK_DIRS[#FALLBACK_DIRS + 1] = string.format("%02d", i) end

    local function dir_has_entry(root, name)
        local f = io.open(root .. "\\" .. name .. "\\main.lua", "r")
        if f then
            f:close()
            return true
        end
        return false
    end

    local function scan_subdirs(root)
        local dirs, seen = {}, {}
        local f = io.open(root .. "\\mods.txt", "r")
        if f then
            for line in f:lines() do
                line = line:gsub("^%s+", ""):gsub("%s+$", "")
                if line ~= "" and line:sub(1, 1) ~= "#" and not seen[line] then
                    seen[line] = true
                    dirs[#dirs + 1] = line
                end
            end
            f:close()
        else
            log("[scan] 未找到 " .. root .. "\\mods.txt，改用固定名兜底")
        end
        local added = 0
        for i = 1, #FALLBACK_DIRS do
            local name = FALLBACK_DIRS[i]
            if not seen[name] and dir_has_entry(root, name) then
                seen[name] = true
                dirs[#dirs + 1] = name
                added = added + 1
            end
        end
        if added > 0 then
            log(string.format("[scan] 固定名兜底补入 %d 个目录（mods\\01..mods\\20）", added))
        end
        return dirs
    end

    local function read_file(path)
        local f = io.open(path, "rb")
        if not f then return nil end
        local s = f:read("*a") or ""
        f:close()
        return s
    end

    ------------------------------------------------------------------------
    -- BSL 兼容桩：让"检测 loader 是否存在"的 mod 不至于立刻失败
    -- 注意：这里只提供元数据与日志句柄，不提供任何 FFI/内存能力
    ------------------------------------------------------------------------

    -- BSL 的 loader.open_log(name) 返回一个已打开的写句柄（落到 mods\<name>）。
    -- P2P Ping 这类 BSL 型 mod 在 chunk 顶层第一件事就是调它，缺了直接判
    -- "unsupported_loader_or_update" 退出，所以必须实现。走 loader 自己的
    -- io.open（不受 mod 沙箱写入白名单约束）。
    local function open_mod_log(name)
        local path = MODS_REL .. "\\" .. tostring(name or "mod.log")
        local f = io.open(path, "w")
        if not f then
            log("[compat] open_log failed: " .. path)
            return nil
        end
        return f
    end

    local compat = {
        api = 1,                 -- BSL mod 的硬门禁：loader.api 必须 == 1
        version = 17,
        open_log = open_mod_log,
        capabilities = {
            build_gate = false,
            after_startup = false,
            jit = false,
            ffi = false,
            pure_lua_host = true,
        },
        build = { supported = false, note = "pure-lua host; no BSL build gate" },
        jit = { churn = {} },
        host = "hd2-pure-lua-loader",
    }

    ------------------------------------------------------------------------
    -- mod 沙箱环境
    ------------------------------------------------------------------------
    -- BSL 风格的 mod（P2P Ping / Better Chat 等）不返回 update 字段，而是在
    -- chunk 顶层 `rawset(_G,'update',wrapped_update)` 把引擎回调包一层。
    -- 沙箱里先放占位函数让它有东西可包，loader 每帧再调用沙箱自己的 update。
    local function bsl_update_noop() end
    local function bsl_shutdown_noop() end

    -- 路径规范化：只接受相对路径。统一分隔符 → 吃掉 "." → 解析 ".."（越界即返回 nil）。
    -- 绝对路径（盘符 / 反斜杠开头 / UNC）一律返回 nil：写操作只允许 mods 之下的相对路径。
    local function normalize_relative(path)
        if type(path) ~= "string" or path == "" then return nil end
        if path:find("^%a:") or path:sub(1, 2) == "\\\\" or path:sub(1, 1) == "\\" then
            return nil
        end
        local slashed = path:gsub("/", "\\")
        local parts = {}
        for seg in slashed:gmatch("[^\\]+") do
            if seg == "." then
                -- 无意义的当前目录段，丢弃
            elseif seg == ".." then
                if #parts == 0 then return nil end     -- 越过根，拒绝
                parts[#parts] = nil
            else
                parts[#parts + 1] = seg
            end
        end
        if #parts == 0 then return nil end
        return table.concat(parts, "\\")
    end

    -- 被拒的写尝试只记一次（按原因去重），否则一个每帧写日志的 mod 会刷爆 loader.log。
    -- 静默拒绝是坏事：作者只会看到"日志没写"，看不到为什么。
    local denied_seen = {}
    local function note_denied(path, why)
        local key = tostring(why)
        if denied_seen[key] then return end
        denied_seen[key] = true
        log("[sandbox] denied write: " .. tostring(path) .. "  -> " .. tostring(why))
    end

    local function make_env(modname)
        local env = {}
        -- 标准库（允许）
        env.string = string
        env.table = table
        env.math = math
        env.tostring = tostring
        env.tonumber = tonumber
        env.type = type
        env.pairs = pairs
        env.ipairs = ipairs
        env.next = next
        env.select = select
        env.pcall = pcall
        env.error = error
        env.assert = assert
        env.unpack = unpack
        -- BSL 型 mod 大量使用 rawset/rawget 打补丁到自己的 _G（P2P Ping 第 6 行
        -- 就是 rawget(_G, MOD_KEY)）。这两个是纯 Lua 操作，不给会让它们秒退。
        env.rawget = rawget
        env.rawset = rawset
        env.rawequal = rawequal
        env.setmetatable = setmetatable
        env.getmetatable = getmetatable
        env.print = function() end          -- 静默，避免污染引擎控制台
        env._VERSION = _VERSION

        -- os：只给时间相关，不给 execute/remove（mod 要起进程得显式申请）
        env.os = {
            time = os.time,
            clock = os.clock,
            date = os.date,
            getenv = os.getenv,
            difftime = os.difftime,
        }

        -- io：只给读文件；写操作限定在 mods 目录**之内**
        --
        -- ★ 不要退回到 path:find("mods", 1, true) 的写法。那是子串搜索，
        --   实测可绕过（E:\DSH\_hd2mm\_work\loader\sandbox_guard_test.lua）：
        --     mods\..\..\evil.txt   -> 通过，实际写到游戏根目录
        --     mods\..\evil.txt      -> 通过，实际写到 data 目录
        --     C:\temp\mods_evil.txt -> 通过，'mods' 只是别处的一个子串
        --   正确做法是先规范化（统一分隔符、吃掉 .、解析 ..、越界即拒绝），
        --   再判断结果**是否恰好以 mods\ 开头**。
        env.io = {
            open = function(path, mode)
                if type(path) ~= "string" then return nil, "bad path" end
                if mode ~= nil and type(mode) ~= "string" then return nil, "bad mode" end
                if mode and mode:find("[wa+]") then
                    local norm = normalize_relative(path)
                    if norm == nil then
                        local why = "path escapes (absolute, or .. above the root)"
                        note_denied(path, why)
                        return nil, "write outside mods dir denied (" .. why .. ")"
                    end
                    local lower = norm:lower()
                    local prefix = MODS_REL:lower() .. "\\"
                    if lower:sub(1, #prefix) ~= prefix then
                        local why = "not under " .. MODS_REL .. "\\"
                        note_denied(path, why)
                        return nil, "write outside mods dir denied (" .. why .. ")"
                    end
                end
                return io.open(path, mode)
            end,
        }

        -- 引擎 API
        env.stingray = stingray
        env.CowboyBingusModLoader = compat
        env.__MODNAME = modname
        -- BSL 兼容：给 mod 一个可包装的 update / shutdown
        env.update = bsl_update_noop
        env.shutdown = bsl_shutdown_noop
        env._G = env
        return env
    end

    ------------------------------------------------------------------------
    -- 加载单个 mod
    ------------------------------------------------------------------------
    local mods = {}

    local function load_mod(dirname)
        local dir = MODS_REL .. "\\" .. dirname
        local entry = dir .. "\\main.lua"
        local src = read_file(entry)
        if src == nil then
            log(string.format("[load] %s: no main.lua, skipped", dirname))
            return false
        end

        local chunk, err = loadstring(src, "@" .. entry)
        if not chunk then
            log(string.format("[load] %s: compile error: %s", dirname, tostring(err)))
            return false
        end

        local env = make_env(dirname)
        setfenv(chunk, env)

        local ok, mod = pcall(chunk)
        if not ok then
            log(string.format("[load] %s: runtime error: %s", dirname, tostring(mod)))
            return false
        end
        if type(mod) ~= "table" then
            log(string.format("[load] %s: main.lua returned %s, expected table", dirname, type(mod)))
            return false
        end

        mod.__name = tostring(mod.name or dirname)
        mod.__dir = dir
        mod.__env = env
        mod.__errors = 0
        mod.__disabled = false

        -- init
        if type(mod.init) == "function" then
            local ok2, e2 = pcall(mod.init)
            if not ok2 then
                log(string.format("[init] %s: %s", mod.__name, tostring(e2)))
                mod.__errors = 1
            end
        end

        mods[#mods + 1] = mod
        log(string.format("[load] %s ok (version=%s)", mod.__name, tostring(mod.version)))
        return true
    end

    local MAX_ERRORS = 10

    local function run_hook(hook, ...)
        for i = 1, #mods do
            local m = mods[i]
            if not m.__disabled then
                -- 取函数和调用分别 pcall：某个 mod 的 metatable 出错不能中断后续 mod
                local okf, fn = pcall(function() return m[hook] end)
                if okf and type(fn) == "function" then
                    local ok, err = pcall(fn, ...)
                    if not ok then
                        m.__errors = m.__errors + 1
                        log(string.format("[%s] %s error #%d: %s", hook, m.__name, m.__errors, tostring(err)))
                        if m.__errors >= MAX_ERRORS then
                            m.__disabled = true
                            log(string.format("[%s] %s disabled after %d errors", hook, m.__name, m.__errors))
                        end
                    end
                elseif not okf then
                    log(string.format("[%s] %s: reading hook failed: %s", hook, m.__name, tostring(fn)))
                end
            end
        end
    end

    ------------------------------------------------------------------------
    -- BSL 风格的 mod：它们包装的是沙箱里的 update / shutdown 占位函数，
    -- 由 loader 每帧显式调用一次。首次调用落一行日志，崩溃时最后一行即可定位。
    ------------------------------------------------------------------------
    local bsl_first_tick = {}

    local function bump_error(m, tag, err)
        m.__errors = m.__errors + 1
        log(string.format("[%s] %s error #%d: %s", tag, m.__name, m.__errors, tostring(err)))
        if m.__errors >= MAX_ERRORS then
            m.__disabled = true
            log(string.format("[%s] %s disabled after %d errors", tag, m.__name, m.__errors))
        end
    end

    local function run_bsl_hook(hook, noop, ...)
        for i = 1, #mods do
            local m = mods[i]
            if not m.__disabled and m.__env ~= nil then
                local fn = rawget(m.__env, hook)
                if type(fn) == "function" and fn ~= noop then
                    if hook == "update" and not bsl_first_tick[m.__name] then
                        bsl_first_tick[m.__name] = true
                        log(string.format("[bsl] first tick -> %s", m.__name))
                    end
                    local ok, err = pcall(fn, ...)
                    if not ok then bump_error(m, "bsl-" .. hook, err) end
                end
            end
        end
    end

    ------------------------------------------------------------------------
    -- 串接引擎回调（boot 全局唯一，必须保留已有实现）
    --
    -- ★ 必须在顶层无条件定义 init / update / render / shutdown **四个**全局钩子。
    --   依据（2026-10-22 solo 版崩溃实测）：ArmoryForge 的 boot payload 末尾写着
    --     local function noop() end
    --     init,shutdown,update,render = noop,noop,noop,noop
    --   四个全占位；而只带 loader 的 solo 版当时只定义了 update/shutdown，
    --   结果 boot 脚本执行完（日志已写出 [host]）后，宿主层在
    --   helldivers2.exe+0x79A553 以 0xC0000005 崩落 —— 与 DECISIONS 记录的
    --   Lua 错误路径 +0x79A511 同段代码。补上 init/render 后 solo 版正常。
    --   → 引擎会调用这些钩子而不判空，缺一个就崩。
    ------------------------------------------------------------------------
    local prev_init = init
    local prev_update = update
    local prev_render = render
    local prev_shutdown = shutdown
    local t_total = 0
    local booted = false

    local function boot()
        if booted then return end
        booted = true
        local dirs = scan_subdirs(MODS_REL)
        log(string.format("[boot] mods root = %s, found %d dir(s)", MODS_REL, #dirs))
        for i = 1, #dirs do
            pcall(load_mod, dirs[i])
        end
        log(string.format("[boot] loaded %d mod(s)", #mods))
    end

    ------------------------------------------------------------------------
    -- init：引擎在 boot 脚本加载后调用一次。mod 的加载放在这里（而不是等
    -- 第一次 update），既贴合引擎生命周期，也让"加载失败"与"每帧回调出错"
    -- 两类问题在日志里分得开。
    ------------------------------------------------------------------------
    init = function(...)
        if type(prev_init) == "function" then pcall(prev_init, ...) end
        local ok, err = pcall(function()
            if not booted then boot() end
        end)
        if not ok then log("[init] host error: " .. tostring(err)) end
    end

    update = function(...)
        if type(prev_update) == "function" then pcall(prev_update, ...) end
        local dt = ...
        local step = tonumber(dt) or 0
        if step <= 0 or step > 1 then step = 0.016 end
        t_total = t_total + step

        -- Lua 5.1: '...' 只在 vararg 函数体内可见，无法穿透进嵌套闭包。
        -- 先把参数捕获成 table，再在 pcall 闭包里用 unpack 还原（nargs 保留 nil 位）。
        local args = {...}
        local nargs = select("#", ...)
        local ok, err = pcall(function()
            if not booted then boot() end
            run_hook("update", unpack(args, 1, nargs))
            run_bsl_hook("update", bsl_update_noop, unpack(args, 1, nargs))
        end)
        if not ok then log("[update] host error: " .. tostring(err)) end
    end

    ------------------------------------------------------------------------
    -- render：引擎每帧渲染时调用（ArmoryForge 也把它占了位）。这里只把
    -- mod 的 render(world) 转发出去，loader 自己不画任何东西。
    ------------------------------------------------------------------------
    render = function(...)
        if type(prev_render) == "function" then pcall(prev_render, ...) end
        local args = {...}
        local nargs = select("#", ...)
        local ok, err = pcall(function()
            run_hook("render", unpack(args, 1, nargs))
        end)
        if not ok then log("[render] host error: " .. tostring(err)) end
    end

    local shut = false
    shutdown = function(...)
        if shut then return end
        shut = true
        local ok, err = pcall(function()
            run_hook("shutdown")
            run_bsl_hook("shutdown", bsl_shutdown_noop)
            log(string.format("=== loader shutdown t=%.1fs, mods=%d ===", t_total, #mods))
        end)
        if not ok then log("[shutdown] host error: " .. tostring(err)) end
        if type(prev_shutdown) == "function" then pcall(prev_shutdown, ...) end
    end

    log("[host] update/shutdown hooked (prev_update=" .. type(prev_update)
        .. ", prev_shutdown=" .. type(prev_shutdown) .. ")")
    log("[host] init/render hooked (prev_init=" .. type(prev_init)
        .. ", prev_render=" .. type(prev_render) .. ")")
end
