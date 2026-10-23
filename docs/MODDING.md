# Modding guide

**English** | [简体中文](MODDING.zh-CN.md)

How to write a mod for this loader: file layout, the exact `main.lua` contract, and the exact sandbox API list.

If you have written a mod for **Bingus Shared Loader** before, read §6 — most of the shape is the same on purpose,
and simple BSL mods run here unmodified (a real one does).

---

## 1. File layout

```
<game>\mods\
├─ mods.txt                 # manifest: one directory name per line
├─ hello\
│  └─ main.lua              # entry point, required
└─ my-mod\
   ├─ main.lua
   └─ data\whatever.txt     # anything else you want to ship
```

`mods.txt`:

```
# lines starting with # are comments
hello
my-mod
```

Mods in `mods\01` … `mods\20` are loaded **even if they are not listed**, because the loader probes
`<dir>\main.lua`. That is a fallback, not the recommended path: the reason it exists is that `io.popen` and
`os.execute` block the game's main thread, so the loader cannot enumerate directories any other way.

Logs go next to the manifest: write to `mods\<yourmod>.log`. That is also the only place you may write (§4).

---

## 2. The `main.lua` contract

`main.lua` is compiled with `loadstring`, run in a fresh sandbox environment, and must **return a table**:

```lua
local M = { name = "my-mod", version = "1.0.0" }   -- both fields optional

function M.init()
    -- called once, after the payload has installed its hooks
end

function M.update(dt)
    -- every frame; dt is whatever the engine passes (seconds)
end

function M.render(world)
    -- optional; draw here
end

function M.shutdown()
    -- called once on exit
end

return M
```

| Field | Required | Notes |
|---|---|---|
| `name`, `version` | no | used in log lines only |
| `init` | no | called once, in `init`, after all mods are compiled |
| `update(dt)` | no | every frame |
| `render(world)` | no | forwarded from the engine's `render` hook |
| `shutdown` | no | once, at exit |

Every hook call is wrapped in `pcall` by the loader. A mod that throws **10 times on the same hook** is disabled
(one log line says so) rather than spamming the log every frame forever.

A mod that does not return a table, or whose chunk throws while loading, is rejected with a single log line and
skipped. Other mods are unaffected.

---

## 3. Drawing and querying

The full `stingray` namespace is exposed. Measured-working calls (details and crash points in
[COMPATIBILITY.md](COMPATIBILITY.md)):

```lua
-- screen GUI: (world, "scale", 1, 1) is the argument order that works on this build.
-- Anchor to the MAIN world; overlay worlds are not always composited.
local world = stingray.Application.main_world()        -- or Application.worlds()[i]
local gui = stingray.World.create_screen_gui(world, "scale", 1, 1)
stingray.Gui.set_visible(gui, true)

-- text: (gui, text, font, size, material, position, colour)
--   font "core/performance_hud/debug" exists on this build, size 22 is what the
--   working third-party overlay uses, colours are 0-255 per channel with alpha first.
local font = "core/performance_hud/debug"
local id = stingray.Gui.text(gui, "hello", font, 22, font,
                             stingray.Vector2(20, 20), stingray.Color(255, 255, 255, 255))

-- **No argument.** Gui.resolution(gui) does not error — it returns garbage
-- (measured in the same frame: resolution(gui) -> 1226853248 x 1426606976,
--  resolution() -> 2560 x 1440). Feeding those numbers into coordinates makes
--  Gui.text crash at helldivers2.exe+0x108732. Always sanity-check the result:
--  if it is not a plausible screen size, skip the frame instead of drawing.
local w, h = stingray.Gui.resolution()

-- Redraw means: destroy the previous object, then call Gui.text again. Every call
-- allocates one, including drop shadows — forgetting them leaks one per redraw.
stingray.Gui.destroy_text(gui, id)

-- session / latency
stingray.Network.ping(...)
local session = stingray.Network.game_session()
local peers = session and stingray.GameSession.peers(session)
```

> **`stingray.Vector2` is a callable *table*** (metatable `__call`); `stingray.Color` is a real function. A guard
> written as `type(Vector2) == "function"` rejects it and your HUD quietly draws nothing. Test callability instead —
> `examples/hud-panel` has the helper.

**Do not** call any of these — they kill the process, not just your mod:
`World.unit_by_id`, `UnitComponent.unit`, `Unit.has_mesh`, `Unit.is_a`,
`Application.can_get(x)` with one argument, `Application.set_resource_override(t, n, nil)`,
`Gui.resolution(nil, nil)`.

One nuance (added 2026-10-23, re-measured on build 26088801): **`World.units(w)` itself is safe** — it returns a
table (62 units on the ship, 2290 in a world-switch state, 17172 in a mission). What kills the process is
dereferencing `units[i]` for i ≥ 2, and `Unit.alive` returning `true` does not protect you. Treat the returned
table as "first element only".

---

## 4. Sandbox API — the exact list

Your environment (`_G` inside your chunk) is a **fresh table**, not the real global table. This is the complete
whitelist:

| Group | Available |
|---|---|
| Core | `tostring` `tonumber` `type` `pairs` `ipairs` `next` `select` `pcall` `error` `assert` `unpack` `_VERSION` |
| Meta | `rawget` `rawset` `rawequal` `setmetatable` `getmetatable` |
| `string` | whole library |
| `table` | whole library |
| `math` | whole library |
| `print` | present, but a **silent no-op** (keeps your noise out of the engine console) |
| `os` | `time` `clock` `date` `getenv` `difftime` — **no** `execute`, `remove`, `exit`, `tmpname` |
| `io` | `open` only, see below |
| Engine | `stingray` (whole namespace) |
| Loader | `CowboyBingusModLoader` (see §6), `__MODNAME`, `update`, `shutdown` |
| `_G` | points at this same sandbox table |

**`io.open` rules:** reading is unrestricted. For a mode containing `w`, `a` or `+`, the path is **normalised first**
(separators unified, `.` dropped, `..` resolved) and must then resolve to something **under `mods\`**; absolute paths
(`C:\…`, `\\server\…`, `\rooted`) are refused outright. Anything else returns
`nil, "write outside mods dir denied …"`.

That check is deliberately stricter than a substring test. An earlier version accepted any path *containing* the text
`mods`, which let `mods\..\..\evil.txt` resolve to the game root and `C:\temp\mods_evil.txt` pass on a different
drive. The rule is now "normalise, then require the `mods\` prefix" — `mods\sub\..\a.log` is fine, `mods\..\a.log` is
not.

**Not available at all** — anything not in the table above: `ffi`, `jit`, `require`, `package`, `module`,
`loadstring`, `load`, `loadfile`, `dofile`, `setfenv`/`getfenv`, `os.execute`, `os.remove`, `os.exit`, `io.popen`,
`io.write`, `io.lines`, `io.close`, `debug`, `coroutine`, `collectgarbage`, `newproxy`. If your mod needs any of
these, it cannot run under this loader — that is a design limit, not a bug. (`loadstring` is withheld on purpose:
the loader itself compiles your `main.lua`, and a mod that compiles further chunks would bypass this sandbox.)

---

## 5. Logging convention

Write one line per event, and include enough to identify the mod:

```lua
local function say(text)
    local f = io.open("mods\\my-mod.log", "a")
    if f then f:write(os.date("%H:%M:%S ") .. text .. "\n"); f:close() end
end
```

Open/write/close each time. Do **not** keep a handle open across frames: it makes the file unreadable by other tools
while the game runs (the third-party P2P Ping does exactly this, and reading its log from PowerShell then needs a
tolerant reader).

---

## 6. Bingus Shared Loader compatibility

BSL-style mods have a different shape: they do not return a table, they patch the global `update` from inside their
own chunk:

```lua
if rawget(_G, "my_mod_key") then return end
rawset(_G, "my_mod_key", true)

local loader = rawget(_G, "CowboyBingusModLoader")
local log = loader and loader.open_log and loader.open_log("my-mod.log")

local prev = rawget(_G, "update")
rawset(_G, "update", function(dt)
    if prev then prev(dt) end
    -- per-frame work
end)
```

To make that work, the loader provides:

| Symbol | Value |
|---|---|
| `CowboyBingusModLoader.api` | `1` (the hard gate most BSL mods check) |
| `CowboyBingusModLoader.version` | `17` |
| `CowboyBingusModLoader.open_log(name)` | open write handle to `mods\<name>` |
| `CowboyBingusModLoader.capabilities` | `{ build_gate=false, after_startup=false, jit=false, ffi=false, pure_lua_host=true }` |
| `CowboyBingusModLoader.build` | `{ supported=false, note="pure-lua host; no BSL build gate" }` |
| `update`, `shutdown` in your sandbox | no-op functions you can wrap |

The loader calls your wrapped `update`/`shutdown` once per frame/exit and logs `[bsl] first tick -> <mod>` the first
time, so an empty log tells you your wrapper was never installed.

Anything that uses `ffi` (which is most of the BSL mod ecosystem — 6 of 6 sampled popular repositories vendor the
same `bingus_memory.lua` that calls `require('ffi')` + `ReadProcessMemory`) **cannot** run here.

---

## 7. Common mistakes

| Symptom in `loader.log` | Cause |
|---|---|
| `[load] x: no main.lua, skipped` | wrong folder depth — the loader wants `mods\<name>\main.lua`, not `mods\<name>\<name>\main.lua` |
| `[load] x: main.lua returned nil, expected table` | your chunk returns nothing; add `return M` (a pure BSL-style mod never reaches this line, it is accepted differently) |
| `[load] x: compile error: …` | Lua 5.1 syntax; you may be using 5.2+ features (`goto`, integer division) |
| `[update] x error #1..10` | your `update` throws; read the message, the loader keeps going until the 10th |
| `[scan] 未找到 mods\mods.txt，改用固定名兜底` | manifest missing; folder names `01`…`20` still load |
| nothing at all in `loader.log` | the loader is not installed (wrong patch slot, or the game was already running when you copied it) |

---

## 8. Examples

- [`examples/hello`](../examples/hello/main.lua) — minimal mod: logs, counts frames, shuts down cleanly.
- [`examples/hud-panel`](../examples/hud-panel/main.lua) — a screen GUI panel with live text.
- [`examples/mod-template`](../examples/mod-template/main.lua) — copy-paste starting point with the logging
  convention, guarded engine calls and a `pcall` around every risky operation.
