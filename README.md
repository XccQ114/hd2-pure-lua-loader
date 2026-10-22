# HD2 Pure-Lua Mod Loader

**English** | [简体中文](README.zh-CN.md)

A **pure-Lua mod loader** for HELLDIVERS 2 on the current Steam build (**25988413**). It loads mods from
`<game>\mods\` into the game's own Lua 5.1 state through a `boot` resource override — no native DLL, no code
signature, no anti-cheat interaction, no Bingus Shared Loader.

> **Status: 0.2.0 — proven in both deployment modes.** Verified end-to-end on build 25988413 in two configurations:
> **solo** (the loader alone is the whole `boot` payload) and **merged** (appended to a third-party host payload such
> as ArmoryForge). In both, a real third-party mod written for Bingus Shared Loader (P2P Ping by shock233) loaded and
> drew its HUD on screen. See [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md) for measured evidence, including what
> does **not** work.

---

## What this can and cannot do

| ✅ Works | ❌ Does not work |
|---|---|
| Load pure-Lua mods (`init` / `update` / `render` / `shutdown`) | **No FFI** — cannot read or write game memory |
| BSL compatibility shim: `CowboyBingusModLoader.api = 1`, `open_log()`, `_G.update` wrapping | Cannot read unit positions (`world_position` is always `0,0,0` on this build) |
| In-game GUI text (`Gui.text`), rectangles (`Gui.rect` — used by a working third-party payload), hotkeys | Cannot change gameplay values (damage, ammo, cooldowns) |
| `stingray.Network.*`, `GameSession.*` queries | Cannot load FFI-based mods (that is ~all of the BSL ecosystem) |
| Directory loading + fixed-name fallback (`mods\01`…`mods\20`) | Cannot bypass the engine's plugin signature gate (error `577`) |

**If you need memory patching or gameplay values, this loader is not for you.** What it does cover is information
and interface mods: overlays, HUD readouts, latency displays, in-game panels.

---

## Install (30 seconds)

You need HELLDIVERS 2 from Steam, **the game closed**, and PowerShell.

```powershell
# from the repository root
powershell -ExecutionPolicy Bypass -File .\tools\install.ps1
```

The installer:

1. finds your game install (and refuses to run if the game is open),
2. **backs up your existing `data\9ba626afa44a3aa3.patch_0*`** to `_backup-<timestamp>\`,
3. copies the loader's `patch_0` (three files) into `data\`,
4. tells you where the log will appear.

Start the game **through Steam** (`steam://rungameid/553850`). Then check:

```
<game>\mods\loader.log
  === hd2 pure-lua loader start ===
  [host] update/shutdown hooked (prev_update=nil, prev_shutdown=nil)
  [host] init/render hooked (prev_init=nil, prev_render=nil)
  [boot] mods root = mods, found 0 dir(s)
  [boot] loaded 0 mod(s)
```

### Roll back

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\rollback.ps1
```

This restores whichever backup you pick — including a clean, unmodified game if you backed that up first.

---

## Install a mod

```
<game>\mods\<modname>\main.lua        # your mod
<game>\mods\mods.txt                  # one directory name per line
```

`mods.txt`:

```
# lines starting with # are comments
hello
my-other-mod
```

Mods placed in `mods\01` … `mods\20` are **loaded automatically** even if they are not listed in `mods.txt`
(the loader probes `<dir>\main.lua`; this is the fallback because `io.popen` blocks the game's main thread and
cannot be used to enumerate directories).

### Minimal mod

```lua
-- mods\hello\main.lua
local M = { name = "hello", version = "1.0.0" }

function M.init()
    local f = io.open("mods\\hello.log", "a")
    if f then f:write("hello from the loader\n"); f:close() end
end

function M.update(dt)
    -- called once per frame
end

function M.shutdown()
end

return M
```

Full authoring guide, including the exact sandbox API list: **[docs/MODDING.md](docs/MODDING.md)**.

---

## Why this exists

On 2026-10-20 Arrowhead switched HELLDIVERS 2 from GameGuard to Easy Anti-Cheat and the game build moved to
**25988413**. Since then:

- **Bingus Shared Loader v20** starts no mods on an unsupported build (its build gate is deliberate), and
- its single injection entry point, the Lua resource `core/wwise/lua/wwise_flow_callbacks`, **no longer exists in
  this build** (verified in game: `Application.can_get("lua", …)` returns `false`), and
- the ecosystem's heavier projects moved to a separate offline client instead.

So the `boot` resource override is the one Lua entry point that still works on the retail client. This loader uses
it, and nothing else.

---

## Technical notes

The loader is a single Lua file appended to the `boot` resource of a `data/9ba626afa44a3aa3.patch_0` archive:

- archive layout: **72-byte header** (magic, counts, `0x20` = 256-byte-aligned capacity) + 32-byte type header +
  80-byte TOC entry, with the resource area starting at offset **192**; no per-resource tail padding
  (verified by rebuilding the original payload byte-for-byte),
- the loader **defines all four engine hooks unconditionally** — `init`, `update`, `render`, `shutdown` — and
  `pcall`-chains any pre-existing implementation. This is not optional: a `boot` payload that omits `init` or
  `render` makes the engine crash in `helldivers2.exe+0x79A553` (`0xC0000005`) right after the payload finishes
  running. The original third-party payload we learned the format from occupies all four slots with no-ops; that is
  why a merged build worked while a solo build crashed. See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md),
- the loader is idempotent (re-appending it does not double-install),
- mods run in a `setfenv` sandbox: whitelisted standard library, read-any / write-only-inside-`mods` `io`,
  full `stingray` namespace, and the BSL shim,
- a mod that throws 10 times is disabled instead of spamming the log every frame,
- `os.execute` and `io.popen` are **not** exposed to mods: inside the game process they block the main thread
  and the game stops responding (`Responding=False`) — measured, not assumed.

Build it yourself:

```powershell
# normal build — the loader alone is the whole boot payload
python loader\build_loader_patch.py --solo

# append the loader after your own third-party boot payload so both run
python loader\build_loader_patch.py --host-payload path\to\host_payload.lua

# optional: also ship a tiny extra lua resource (proves multi-resource archives work)
python loader\build_loader_patch.py --solo --probe-resource

# optional: make the writer prove itself against a known-good archive before it writes anything
python loader\build_loader_patch.py --solo --host-payload path\to\host_payload.lua --verify-original path\to\original.patch_0
```

Output goes to `loader\dist\`. A **prebuilt solo patch ships in `releases\v0.1.0\`**, so installing does not require
Python at all.

Everything is resolved relative to the script's own location. The third-party host payload is **not** redistributed —
bring your own, or use `--solo`. If `luac` is available it is used as a syntax gate (point at it with the `LUAC`
environment variable); without it the build still works and says so. A 64-bit `luac` parses the *source* fine — it
only chokes on the game's own bytecode dumps, which use 32-bit `size_t`.

`--verify-original` rebuilds a reference archive with the same rules and refuses to write if the bytes differ. That is
how the packing rules in this repo were established: the reference archive (**797,815 B** file = 192 B headers +
797,623 B resource area holding a 797,615 B Lua source) is reproduced byte-for-byte. Keep those three numbers apart —
conflating them is exactly the mistake this project already had to correct once.

---

## Provenance and AI disclosure

The code, the documentation and most of the experimental design here were drafted by an **AI coding agent**
(DSH, on DeepSeek) running on the author's machine at the author's request. Every game launch was made on that same
machine, with the author authorising and reviewing each command. Saying that plainly is more useful than hiding it:
it tells you what to discount.

What it does **not** mean:

- no figure on this page comes from a model's recall. Every measurement was produced by a run against a retail
  install of build 25988413 and is traceable to a log line, a crash dump, or a file that still exists;
- where the text reasons past a direct observation, it says so. The four such passages in
  [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md) are listed up front, by name;
- crash addresses were computed as `ExceptionAddress − module base` from minidumps, not guessed;
- this project has already had to correct its own claims twice after re-reading its logs — a payload-size figure
  that conflated three different lengths, and a theory of the signature gate that one counter-example killed. Both
  corrections are recorded in [CHANGELOG.md](CHANGELOG.md).

Weight the evidence by the logs, not by the prose.

---

## Licence

MIT — see [LICENSE](LICENSE). Do what you want; no warranty.

This project contains no game assets and redistributes no third-party mod payload; the shipped patch holds only the
loader's own Lua source. Not affiliated with Arrowhead Game Studios or Sony Interactive Entertainment. HELLDIVERS is
a trademark of Sony Interactive Entertainment. Use at your own discretion.
