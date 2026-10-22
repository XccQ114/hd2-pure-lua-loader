-- ============================================================================
-- Example: mod-template — copy this folder to start a new mod
--
--   <game>\mods\my-mod\main.lua      <- this file, renamed
--   <game>\mods\mods.txt             <- add one line: my-mod
--
-- Rules this template already follows (each one was learned the hard way):
--   * return a table; hooks are optional and each is pcall'd by the loader;
--   * log to mods\<something>.log, open/write/close every line;
--   * never touch os.execute / io.popen — they freeze the game's main thread;
--   * pick engine tables out of `stingray` and check them with type(), because
--     the API surface differs between builds;
--   * wrap every risky engine call in pcall and log the failure once, not
--     every frame.
-- ============================================================================

local M = { name = "my-mod", version = "0.1.0" }

-- ---- configuration ---------------------------------------------------------

local LOG_PATH     = "mods\\my-mod.log"
local TICK_PERIOD  = 1.0     -- seconds between periodic samples
local DEBUG_VERBOSE = false  -- log every frame? almost never

-- ---- engine tables ---------------------------------------------------------

local sr          = stingray
local Application = sr and rawget(sr, "Application") or nil
local World       = sr and rawget(sr, "World") or nil
local Network     = sr and rawget(sr, "Network") or nil
local Gui         = sr and rawget(sr, "Gui") or nil
local Vector2     = sr and rawget(sr, "Vector2") or nil
local Color       = sr and rawget(sr, "Color") or nil

-- ---- logging ---------------------------------------------------------------

local function say(text)
    local f = io.open(LOG_PATH, "a")
    if f then
        f:write(tostring(text) .. "\n")
        f:close()
    end
end

-- ---- defensive helpers -----------------------------------------------------

local function callable(tbl, key)
    return type(tbl) == "table" and type(tbl[key]) == "function"
end

-- Returns ok, value. Never raises.
local function attempt(f, ...)
    if type(f) ~= "function" then return false, nil end
    local ok, value = pcall(f, ...)
    if ok then return true, value end
    return false, nil
end

-- Log a given message only once per session, so a broken API cannot flood.
local logged = {}
local function say_once(key, text)
    if logged[key] then return end
    logged[key] = true
    say(text)
end

-- ---- state -----------------------------------------------------------------

local frames = 0
local elapsed = 0
local since_tick = 0

-- ---- hooks -----------------------------------------------------------------

function M.init()
    say(string.format("[%s] init v%s, loader=%s, modname=%s",
        M.name, M.version,
        tostring(CowboyBingusModLoader and CowboyBingusModLoader.version),
        tostring(__MODNAME)))

    -- Report what this build actually gives us, once. If a call you need is
    -- missing, say so here instead of failing silently later.
    say(string.format("[%s] apis: application=%s world=%s network=%s gui=%s",
        M.name, type(Application), type(World), type(Network), type(Gui)))

    local ok, worlds = attempt(Application and Application.worlds)
    say(string.format("[%s] Application.worlds ok=%s type=%s count=%s",
        M.name, tostring(ok), type(worlds),
        tostring(type(worlds) == "table" and #worlds or "n/a")))
end

function M.update(dt)
    local step = tonumber(dt) or 0
    if step <= 0 or step > 1 then step = 1 / 60 end

    frames = frames + 1
    elapsed = elapsed + step
    since_tick = since_tick + step

    if DEBUG_VERBOSE then say(string.format("[%s] frame %d dt=%.4f", M.name, frames, step)) end

    if since_tick < TICK_PERIOD then return end
    since_tick = 0

    local ok_main, main_world = attempt(Application and Application.main_world)
    if not ok_main then say_once("no_main_world", "[" .. M.name .. "] main_world unavailable") end

    if callable(Network, "game_session") then
        local ok, session = pcall(Network.game_session)
        if not ok then
            say_once("session_fail", "[" .. M.name .. "] game_session failed")
        elseif session ~= nil then
            -- in a session: peers are available through GameSession.peers
            local GameSession = sr and rawget(sr, "GameSession") or nil
            if callable(GameSession, "peers") then
                local ok_p, peers = pcall(GameSession.peers, session)
                if ok_p and type(peers) == "table" then
                    say(string.format("[%s] tick %d t=%.1fs peers=%d", M.name, frames, elapsed, #peers))
                end
            end
        else
            say(string.format("[%s] tick %d t=%.1fs (no session)", M.name, frames, elapsed))
        end
    end
end

-- Optional: only define this if you actually draw. The loader forwards the
-- engine's render hook to it.
-- function M.render(world)
-- end

function M.shutdown()
    say(string.format("[%s] shutdown after %d frames, %.1fs", M.name, frames, elapsed))
end

return M
