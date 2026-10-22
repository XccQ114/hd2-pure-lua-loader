# Changelog

All notable changes to this project. Dates are local (UTC+8) unless noted.

`update` is not in this changelog? It is: 0.2.2 is the `Gui.resolution` fix, 0.2.1 the sandbox fix, 0.2.0 the
four-hook fix, 0.1.0 the first release.

## 0.2.2 — 2026-10-23

### Fixed — `Gui.resolution` must be called with **no arguments**

`Gui.resolution(gui)` does not raise an error. It returns garbage:

| call | result (same process, same frame) |
|---|---|
| `Gui.resolution(gui)` | `1226853248 x 1426606976` |
| `Gui.resolution()` | `2560 x 1440` |

A HUD that used the first form computed coordinates around 15 million pixels and handed them to `Gui.text`, which
crashed the game at `helldivers2.exe+0x108732` (`0xC0000005`) — reproducibly, on every launch where the panel was
actually drawn.

Why it took a while to find: **`pcall` catches nothing, because nothing is raised.** The wrong call returns
plausible-looking types (`number`, `number`), so every defensive guard passed. And the merged deployment masked it
entirely, so the earlier "verified in game" runs never hit it.

`examples/hud-panel` now calls `Gui.resolution()` and additionally rejects implausible sizes (anything outside
640×480 … 16384×16384) rather than drawing with them. Verified after the fix: solo + `hud-panel` draws for 30+
seconds with no crash; before it, the process died five log lines in.

**If you copied the earlier snippet, change it** — `docs/MODDING.md` shipped the wrong form for a few hours.

## 0.2.1 — 2026-10-23

### Security / correctness — the mod sandbox write rule was bypassable

The `io.open` guard for write modes accepted any path *containing* the text `mods`, as a substring. Measured bypasses:

| path | old verdict | what it actually resolved to |
|---|---|---|
| `mods\..\..\evil.txt` | allowed | the game root (two levels up) |
| `mods\..\evil.txt` | allowed | `data\` |
| `C:\temp\mods_evil.txt` | allowed | any directory on any drive |
| `modsx\..\..\evil.txt` | allowed | substring match, no `mods\` involved |

The guard now **normalises the path first** (separators unified, `.` dropped, `..` resolved, escaping the root
refused) and then requires the result to start with `mods\`. Absolute paths are refused outright. Verified in game:
four escape attempts denied with no file appearing on disk, while normal writes — including `mods\.\x.log` and
`mods\sub\..\x.log` — still succeed.

**This is a behaviour change.** A mod writing through an absolute path is now refused — *even if that absolute path
points inside `mods\`*, which is what our own older test mod did. Point mods at relative `mods\…` paths.

### Added — refusals are no longer silent

A denied write used to return `nil, err` and nothing else, so the author only saw "my log file never appeared". The
loader now logs one line per distinct reason:

```
[sandbox] denied write: D:\...\mods\hello.log  -> path escapes (absolute, or .. above the root)
```

That line is how the absolute-path behaviour change was caught in testing: the log stayed empty, and without this
line there was no way to tell a refused write from a broken mod.

## 0.2.0 — 2026-10-22

### Fixed — solo deployment crashed the game

**Symptom.** Building with `--solo` (loader alone as the `boot` payload) and starting the game: the loader ran and
wrote its first two log lines, then the process died. No Lua error was logged. The game produced a crashpad dump:

```
ExceptionCode    0xC0000005 (ACCESS_VIOLATION)
ExceptionAddress helldivers2.exe + 0x79A553
```

**Root cause.** The engine calls **four** lifecycle hooks from the `boot` Lua state — `init`, `update`, `render`,
`shutdown` — and does not null-check them. The loader only defined `update` and `shutdown`, so the engine called a
nil `init` and crashed in its own Lua error path (`+0x79A553` sits in the same function as the compile-failure
crash point `+0x79A511`).

This was invisible in the merged build because the third-party payload the loader was appended to occupies all four
slots with no-ops:

```lua
local function noop() end
init,shutdown,update,render = noop,noop,noop,noop
```

**Fix.** The loader now defines all four hooks unconditionally and `pcall`-chains any previous implementation. Mod
loading moved from "first `update` frame" into `init`, which matches the engine lifecycle and keeps "failed to
load" distinct from "per-frame callback errored" in the log. `render` forwards to a mod's optional `render(world)`.

### Added — solo mode verified in game

Both deployment modes are now measured end-to-end on build 25988413:

| Mode | `prev_*` types in log | Result |
|---|---|---|
| solo | `prev_init=nil, prev_update=nil, prev_render=nil, prev_shutdown=nil` | 2 mods loaded, hello ran 600 frames, P2P Ping first tick, `Responding=True`, no dump |
| merged (ArmoryForge) | all four `prev_*=function` | same, plus ArmoryForge's own log advanced |

### Added — verification tooling

- `loader/verify_solo_patch.py` (kept in the private work tree) — checks all 29 header/type/TOCTOU fields of a
  built archive against the packing rules, including `0x20` = 256-byte-aligned capacity and the payload header
  (`u32 length` + `u32 mode=2`).
- A dump triage helper that maps `ExceptionAddress` to `module + RVA`, which is how `+0x79A553` was identified.

### Verified — the examples run in game, not just on paper

`examples/hud-panel` was loaded on build 25988413 and drew continuously (`[ui] drew: HUD-PANEL …`, 59 lines over
27 s, no crash, `Responding=True`). Getting there exposed a trap worth knowing about:

> **`stingray.Vector2` is a callable *table* (metatable `__call`), not a function** — `stingray.Color` is a real
> function. A guard written as `type(Vector2) ~= "function"` therefore rejects Vector2, and the HUD silently draws
> nothing while logging "missing". Test callability (function **or** table-with-`__call`), never `type()` alone.

The panel also confirmed the measured drawing signatures: `World.create_screen_gui(world, "scale", 1, 1)`,
`Gui.text(gui, text, font, size, material, Vector2(x, y), Color(a, r, g, b))`, font `core/performance_hud/debug`,
size 22, colour channels 0–255.

### Changed

- `[host] update/shutdown hooked (...)` is kept verbatim for compatibility with existing tooling; a second line
  `[host] init/render hooked (...)` was added rather than changing the first.

## 0.1.0 — 2026-10-22

Initial working release.

- Pure-Lua loader appended to the `boot` resource of `data\9ba626afa44a3aa3.patch_0`, no DLL and no signature.
- Archive writer reproduces the original third-party payload **byte-for-byte** (797,815 B) as a self-check, plus a
  `luac -p` syntax gate before writing anything.
- BSL compatibility shim: `CowboyBingusModLoader.api = 1`, `version = 17`, `open_log(name)`, a wrappable
  `_G.update`/`_G.shutdown` in the mod sandbox.
- Directory loading from `mods\mods.txt` plus fixed-name fallback probe of `mods\01` … `mods\20`
  (`io.popen`/`os.execute` block the main thread and are not used anywhere).
- `setfenv` sandbox per mod, `pcall` isolation, auto-disable after 10 errors.
- Verified with a third-party mod (P2P Ping by shock233, unmodified) rendering its HUD in game.
