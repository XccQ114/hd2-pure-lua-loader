-- ============================================================================
-- 示例 mod：验证 loader 能否正确加载 / 隔离 / 分发回调
-- 放到 <game>\mods\hello\main.lua
-- 正常表现：loader.log 里出现 [hello] 开头的行；游戏不崩
-- ============================================================================

local M = {
    name = "hello-loader-test",
    version = "1.0.0",
}

local frames = 0
local elapsed = 0
local reported = false

local function log_path()
    return "mods\\hello.log"
end

local function say(text)
    local f = io.open(log_path(), "a")
    if f then
        f:write(text .. "\n")
        f:close()
    end
end

function M.init()
    say(string.format("[hello] init, _VERSION=%s, modname=%s", tostring(_VERSION), tostring(__MODNAME)))
    say("[hello] stingray present = " .. tostring(type(stingray)))
    say("[hello] loader compat = " .. tostring(CowboyBingusModLoader and CowboyBingusModLoader.version))
    -- 验证关键引擎接口在这个沙箱里可见
    local ok, worlds = pcall(function() return stingray.Application.worlds() end)
    say(string.format("[hello] Application.worlds ok=%s type=%s", tostring(ok), type(worlds)))
end

function M.update(dt)
    frames = frames + 1
    elapsed = elapsed + (tonumber(dt) or 0)

    -- 每 60 帧报一次，最多报 10 次，避免刷盘
    if frames % 60 == 0 and not reported then
        say(string.format("[hello] frame=%d elapsed=%.1fs", frames, elapsed))
        if frames >= 600 then
            reported = true
            say("[hello] done reporting after 600 frames")
        end
    end
end

function M.shutdown()
    say(string.format("[hello] shutdown at frame=%d elapsed=%.1fs", frames, elapsed))
end

return M
