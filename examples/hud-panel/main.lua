-- ============================================================================
-- Example: hud-panel — a screen-GUI panel with live text
--
-- Install:  copy this folder to <game>\mods\hud-panel\  and add "hud-panel"
--           on its own line in <game>\mods\mods.txt
-- Expect:   <game>\mods\hud-panel.log   and a panel at the upper left of the
--           screen once a world exists.
--
-- Every engine call below is one this project measured as safe on build
-- 25988413. The arguments are copied from a real, working third-party overlay
-- (P2P Ping), not invented:
--
--   World.create_screen_gui(world, "scale", 1, 1)          -> gui handle
--   Gui.text(gui, text, font, size, material, pos, color)  -> text id
--   Gui.destroy_text(gui, id)
--   Gui.set_visible(gui, bool)
--   Gui.resolution(gui)                                    -> w, h
--   Vector2(x, y) / Color(alpha, r, g, b)                  (0-255 each)
--
-- Three traps this example handles for you:
--   * anchor the GUI to Application.main_world(), **not** to an overlay world:
--     overlay worlds are not always composited (text calls succeed, nothing
--     appears);
--   * the world object is replaced on map/ship transitions, so the GUI must be
--     rebuilt when main_world() changes;
--   * **every** `Gui.text` returns an object that must be destroyed before you
--     draw again — including the drop-shadow copies. Forgetting the shadow
--     leaks one GUI text object per redraw.
-- ============================================================================

local M = { name = "hud-panel", version = "1.0.2" }

-- ---- engine tables (grab once; they are plain tables in this Lua state) ----
local sr          = stingray
local Application = sr and rawget(sr, "Application") or nil
local World       = sr and rawget(sr, "World") or nil
local Gui         = sr and rawget(sr, "Gui") or nil
local Network     = sr and rawget(sr, "Network") or nil
local Vector2     = sr and rawget(sr, "Vector2") or nil
local Color       = sr and rawget(sr, "Color") or nil

local FONT = "core/performance_hud/debug"   -- exists on this build (verified)
local FONT_SIZE = 22
local REDRAW_PERIOD = 0.5                   -- seconds; do not redraw every frame
local LOG_PATH = "mods\\hud-panel.log"

-- ---- helpers ---------------------------------------------------------------

-- Is this value callable? **Do not test type(v) == "function" alone.** Stingray
-- exposes some constructors as *callable tables* (metatable `__call`) instead of
-- functions. Measured on build 25988413:
--     stingray.Vector2 -> table   (callable via __call)
--     stingray.Color   -> function
-- A `type(v) == "function"` guard therefore rejects Vector2, and a HUD written
-- that way silently draws nothing while logging "missing".
local function is_callable(v)
    if type(v) == "function" then return true end
    if type(v) == "table" then
        local mt = getmetatable(v)
        return type(mt) == "table" and type(mt.__call) == "function"
    end
    return false
end

local function describe(v)
    if type(v) == "function" then return "function" end
    if type(v) == "table" then return is_callable(v) and "table(callable)" or "table" end
    return type(v)
end

local function say(text)
    local f = io.open(LOG_PATH, "a")
    if f then
        f:write(tostring(text) .. "\n")
        f:close()
    end
end

-- call f(...) only if f is callable; returns ok, result. Never raises.
local function attempt(f, ...)
    if not is_callable(f) then return false, nil end
    local ok, value = pcall(f, ...)
    if ok then return true, value end
    return false, nil
end

-- Read tbl[key] without trusting it: engine namespaces may be proxy tables whose
-- __index can raise, so index through pcall as well.
local function member(tbl, key)
    if type(tbl) ~= "table" then return nil end
    local ok, value = pcall(function() return tbl[key] end)
    if ok then return value end
    return nil
end

-- Is tbl.key callable? This is for *members of a table* (Gui.text,
-- World.create_screen_gui, Network.game_session). For "does the table itself
-- exist", test type(tbl) == "table" — a namespace like stingray.Network is a
-- table, so passing it here would always answer false.
local function callable(tbl, key)
    return is_callable(member(tbl, key))
end

-- ---- state -----------------------------------------------------------------

local gui, gui_world          -- screen gui handle and the world it is bound to
local text_id, shadow_id      -- text objects returned by Gui.text; both must be freed
local last_text
local redraw_elapsed = REDRAW_PERIOD
local frames = 0
local elapsed = 0
local world_count_label

local function destroy_texts(target)
    if target == nil then
        text_id, shadow_id = nil, nil
        return
    end
    if callable(Gui, "destroy_text") then
        if text_id ~= nil then pcall(Gui.destroy_text, target, text_id) end
        if shadow_id ~= nil then pcall(Gui.destroy_text, target, shadow_id) end
    end
    text_id, shadow_id = nil, nil
end

-- ---- drawing ---------------------------------------------------------------

local function drop_gui()
    if gui and gui_world and callable(World, "destroy_gui") then
        pcall(World.destroy_gui, gui_world, gui)
    end
    gui, gui_world, last_text = nil, nil, nil
    text_id, shadow_id = nil, nil
end

local function ensure_gui(main_world)
    if main_world == nil then return nil end
    if gui and gui_world == main_world then return gui end

    drop_gui()
    if not callable(World, "create_screen_gui") then
        say("[ui] World.create_screen_gui missing")
        return nil
    end

    -- The argument order (world, "scale", 1, 1) is the working one on this build.
    local ok, made = pcall(World.create_screen_gui, main_world, "scale", 1, 1)
    if not ok or made == nil then
        say("[ui] create_screen_gui failed: " .. tostring(made))
        return nil
    end

    gui, gui_world = made, main_world
    if callable(Gui, "set_visible") then pcall(Gui.set_visible, gui, true) end
    say("[ui] gui created for a new main world")
    return gui
end

local function draw(line, main_world)
    local target = ensure_gui(main_world)
    if target == nil then return end
    if not callable(Gui, "text") or not callable(Gui, "resolution") then
        say("[ui] Gui.text / Gui.resolution missing")
        return
    end
    if not is_callable(Vector2) or not is_callable(Color) then
        say("[ui] Vector2 / Color not callable: " .. describe(Vector2) .. " / " .. describe(Color))
        return
    end

    -- ★ Gui.resolution 是**无参**调用。
    --   传 gui 进去不会报错，但会返回垃圾（实测 1226853248 x 1426606976 —— 未初始化
    --   内存的值）。拿它算坐标会得到上千万的像素位置，再交给 Gui.text，引擎在内部
    --   处理越界坐标时崩在 helldivers2.exe+0x108732（0xC0000005）。
    --   实测同一帧内：resolution(gui) -> 垃圾，resolution() -> 2560x1440。
    --   第二道防线是范围检查：宁可不画这一帧，也不要把荒唐的分辨率喂给引擎。
    local ok_res, w, h = pcall(Gui.resolution)
    if not ok_res or type(w) ~= "number" or type(h) ~= "number"
       or w < 640 or h < 480 or w > 16384 or h > 16384 then
        say(string.format("[ui] resolution unusable (ok=%s w=%s h=%s)",
            tostring(ok_res), tostring(w), tostring(h)))
        return
    end

    -- Same text and both objects still alive: nothing to do.
    if line == last_text and text_id ~= nil then return end

    -- Replace, never accumulate: free BOTH the previous text and its shadow.
    destroy_texts(target)

    local x = math.floor(w * 0.0125 + 0.5)
    local y = math.floor(h * 0.035 + 0.5)
    local ok_pos, pos = pcall(Vector2, x, y)
    local ok_col, color = pcall(Color, 255, 255, 255, 255)
    if not ok_pos or not ok_col then
        say("[ui] Vector2/Color construction failed")
        return
    end

    -- drop shadow first (one pixel down-right), then the real text on top
    local ok_shadow_pos, shadow_pos = pcall(Vector2, x + 1, y - 1)
    if ok_shadow_pos then
        local ok_sh_color, sh_color = pcall(Color, 190, 0, 0, 0)
        if ok_sh_color then
            local ok_sh, sh_id = pcall(Gui.text, target, line, FONT, FONT_SIZE,
                                       FONT, shadow_pos, sh_color)
            if ok_sh then shadow_id = sh_id end
        end
    end

    local ok, id = pcall(Gui.text, target, line, FONT, FONT_SIZE, FONT, pos, color)
    if not ok then
        say("[ui] Gui.text failed: " .. tostring(id))
        return
    end
    text_id, last_text = id, line
    say("[ui] drew: " .. line)
end

-- ---- loader hooks ----------------------------------------------------------

function M.init()
    say(string.format("[hud-panel] init v%s, loader compat=%s",
        M.version,
        tostring(CowboyBingusModLoader and CowboyBingusModLoader.version)))
    say(string.format("[hud-panel] namespaces: application=%s world=%s gui=%s network=%s",
        type(Application), type(World), type(Gui), type(Network)))
    say(string.format("[hud-panel] types: vector2=%s color=%s (both must be callable)",
        describe(Vector2), describe(Color)))
end

function M.update(dt)
    local step = tonumber(dt) or 0
    if step <= 0 or step > 1 then step = 1 / 60 end
    frames = frames + 1
    elapsed = elapsed + step
    redraw_elapsed = redraw_elapsed + step

    if redraw_elapsed < REDRAW_PERIOD then return end
    redraw_elapsed = 0

    local ok_worlds, worlds = attempt(Application and Application.worlds)
    local ok_main, main_world = attempt(Application and Application.main_world)
    if not ok_main then main_world = nil end

    local count = (ok_worlds and type(worlds) == "table") and #worlds or 0
    world_count_label = tostring(count)

    -- Network is a namespace *table*; game_session is a function on it.
    local session = nil
    if callable(Network, "game_session") then
        local ok_s, s = pcall(Network.game_session)
        if ok_s then session = s end
    end

    local line = string.format("HUD-PANEL  fps~%d  worlds=%s  session=%s  t=%.1fs",
        math.floor(1 / step + 0.5),
        world_count_label,
        session and "yes" or "no",
        elapsed)

    local ok, err = pcall(draw, line, main_world or (worlds and worlds[1]))
    if not ok then say("[ui] draw error: " .. tostring(err)) end
end

function M.shutdown()
    say(string.format("[hud-panel] shutdown after %d frames", frames))
    destroy_texts(gui)
    drop_gui()
end

return M
