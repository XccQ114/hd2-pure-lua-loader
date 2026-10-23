# Compatibility & measured evidence

**English** | [简体中文](COMPATIBILITY.zh-CN.md)

Almost everything below was measured on a retail Steam install. Where the text reasons *beyond* a direct observation
the sentence says so (`likely`, `observed`, `we did not test`); treat those as **inference**, not as measurement.
Where the official Stingray Lua API reference disagrees with what this build does, **the measurement wins** — that
has already bitten this project twice.

Marked as inference in this document: `statically linked` Lua (we only observed that no separate DLL exists), the
`WinVerifyTrust` *location* (we counted occurrences, we did not trace a call), the four-bucket RVA pattern, and what
the ~1706 unenumerable units are.

- **Game build:** **26088801** (Steam, retail, Easy Anti-Cheat active — the 2026-10-22 hotfix 7.2.1). Most of this
  document was first measured on **25988413** (the 2026-10-20 update); on 2026-10-23 the boot anchor, the four hooks,
  `World.units`, `Gui.resolution` and the crash table were **re-checked on 26088801 and still hold**.
- **Lua:** 5.1.4, `sizeof(size_t)` = **4** (32-bit), `sizeof(int)` = 4, `integral` = 0, `num` = 8 — the last four are
  fields of the `string.dump` bytecode header, read off three dumps that agreed with each other.
- **Lua appears to be statically linked into `data/game/game.dll`** — this build ships **no** `bin/lua51.dll` at all
  (the older build 25480438 shipped one, 469,080 B). *Inference:* we observed the absence of the DLL, not the link
  itself.
- **Signature / script-mod gate:** the string `WinVerifyTrust` appears **once** in `bin/helldivers2.exe`
  (≈ `+0x14979B8`) and **zero** times in `data/game/game.dll`. *Inference:* signature verification therefore runs in
  the host executable rather than the engine DLL. We did **not** examine the anti-cheat service's own binaries, so
  we make no claim about them.

---

## 1. Engine API — measured status

### Works (safe to call)

| Call | Observed result |
|---|---|
| `Application.worlds()` | table of 11 worlds |
| `Application.make_hash(name)` | `make_hash("boot")` → `"f476df93691895fa"`, matches the resource id used in patch archives |
| `Application.can_get(type, name)` | 2-argument form is safe; returns bool. The `type` string is not validated |
| `Application.set_resource_override(type, name, other)` | works; see §5 |
| `Application.clear_resource_override(type, name)` | works, restores the previous state |
| `stingray.Script.exists(name)` / `Script.load(name)` | `load` returns a **callable chunk**; executing it gives full globals (`io`, `os` available) |
| `string.dump(fn)` | works; produces bytecode with 32-bit `size_t` |
| `World.entities(world)` | table of 369 real Entity userdata (`ud:[Entity "name" id:version]`) |
| `World.num_units(world)` | 2303 in a mission (probe13), 62 on the ship |
| `World.levels(world)` / `Level.units(level)` | see §3 |
| `World.unit_by_name(w, name)` | returns `nil` for a missing name — no crash |
| `World.units_by_resource(w, res)` | returns a 0-length table for missing/empty — no crash |
| `World.load_prefab(w, name)` | works (the only source of a prefab instance) |
| `Unit.debug_name` | returns a readable `#ID[<hash>]` string — the only stable identity field |
| `Unit.alive`, `Unit.resource_name` | work (bool / IdString64) |
| `Gui.text`, `Gui.set_visible`, `World.create_screen_gui` | work; font `core/performance_hud/debug` exists as `font` |
| `Gui.resolution` | works **only with no arguments** — `Gui.resolution(gui)` returns garbage without erroring (measured in one frame: `1226853248 x 1426606976`, while `Gui.resolution()` returned `2560 x 1440`). Using the garbage as coordinates crashes `Gui.text` at `+0x108732` |
| `Network.ping`, `Network.game_session`, `GameSession.peers`, `GameSession.game_session_host` | work; a session also exists in the main menu (`peers=1`) |

### Crashes the process (do not call)

| Call | Module + RVA | Exception |
|---|---|---|
| `World.units(w)` — the call itself is safe; **dereferencing `units[i]` for i ≥ 2** | `helldivers2.exe+0x3E5654` | `0xC0000005`. *Measured 2026-10-23 on 26088801:* the call returns a table and does not crash — 62 units on the ship, 2 290 in another world, **17 172 in a mission** — but reading `world_position` of `units[2]` kills the process even though `Unit.alive` returned `true`. Same code family as `0x3C07D9` / `0x3D203F` / `0x3E7CA3` / `0x3EB121` |
| `UnitComponent.unit(component, entity)` | `helldivers2.exe+0x3EB121` | `0xC0000005`, `rdi=0` null deref |
| `World.unit_by_id(world, id)` | `helldivers2.exe+0x3C07D9` | `0xC0000005` |
| `Unit.has_mesh` / `Unit.is_a` | `helldivers2.exe+0x3E7CA3` | `0xC0000005` |
| `Application.set_resource_override(type, name, nil)` | `helldivers2.exe+0x3D203F` | `0xC0000005` |
| `Application.can_get(x)` (single argument) | — (no dump) | process dies |
| a `boot` payload that does **not** define `init` or `render` | `helldivers2.exe+0x79A553` | `0xC0000005` |
| `Gui.resolution(nil, nil)` | `helldivers2.exe+0x3BBB14` | `0xC0000005`. *Measured 2026-10-23:* `Gui.resolution()` with **no** arguments is safe and returns the real `2560×1440` |

Two patterns worth remembering:

- The four RVAs `0x3C07D9`, `0x3D203F`, `0x3E7CA3`, `0x3EB121` all sit inside `0x3C0000–0x3F0000`. *Inference:* that
  is the same "look up the table, then dereference the result" code, which never null-checks. The rule of thumb that
  follows (**anything by id is a landmine, anything by name/resource got null-checks**) is a pattern we observed
  across ~10 calls, not a guarantee.
- `+0x79A553` (missing hook) and `+0x79A511` (invalid Lua chunk) are 0x42 bytes apart — the host's Lua error path.
  A crash there means "the host could not hand off to Lua", not "your Lua threw".

### Documented but unusable

The official Stingray Lua API reference documents `UnitComponent.unit(self, entity)` as returning `stingray.Unit`.
On this build it crashes on the first entity. Treat documentation as a list of *candidates*, never as a list of
capabilities.

---

## 2. What the loader can actually deliver

| Capability | Status |
|---|---|
| Load a mod from `mods\<name>\main.lua` | yes |
| Load N mods, isolate them with `pcall`, auto-disable after 10 errors | yes |
| Run a third-party BSL-era mod **unmodified** (`CowboyBingusModLoader.api == 1` shim) | yes — verified with P2P Ping (author: shock233) drawing its HUD |
| Draw GUI text / rectangles, read `Network.*` | yes |
| Dispatch `init` / `update` / `render` / `shutdown` to mods | yes |
| Read or write game memory | **no** — no `ffi`, no `jit`, no `require` |
| Change gameplay values (damage, ammo, cooldowns) | **no** — see §6 |
| Read unit positions | **no** — see §3 |
| Enumerate dynamic units | **no** — see §3 |
| Load DLL/plugin-based mods | **no** — see §7 |

---

## 3. Units — what you can and cannot enumerate

- `Application.worlds()` → 11 worlds. The main world reports `num_units = 2303` in a mission (probe13; an earlier
  probe recorded 2307 in the same scene — the value moves frame to frame, so treat it as "about 2.3 k").
- `World.levels(main_world)` → a `Level` userdata; `Level.units(level)` → **597** units, no crash.
- Those 597 are **static level content** (ship/scene mesh parts): 109 distinct resource ids, `num_meshes` 1–9,
  `alive == false` for 0 of them.
- The remaining ~1706 units are **not enumerable through any channel we tried**. *Inference:* they are
  runtime-spawned (enemies, projectiles, vehicles) — we never enumerated them directly, we only observed that the
  three channels crash. Two of them still do: `UnitComponent.unit`, `World.unit_by_id`. **`World.units` does not**
  (re-measured 2026-10-23 on 26088801): the call returns a table — 62 units on the ship, 2 290 in another world — but
  dereferencing `units[i]` for i ≥ 2 kills the process, and `Unit.alive` returning `true` does not protect you.
- **The position data is uninitialised memory, not coordinates.** `units[1]` is the same object in every world
  (`resource_name` = `0x465f4895f3dc98d1`). Across **seven samples** — ship, a 2 290-unit world, and a real mission
  (17 172 units / 1 234 levels) — `Unit.world_position` returned `Vector3(1,1,1)`, `Vector3(0,0,0)`, and once
  `Vector3(-1.02749043e-34, 7.91733632e-43, 9.80908925e-45)`. The same call on the same handle in the same scene
  giving different values is what uninitialised memory looks like, not what a position looks like.
  `Unit.world_pose` exposes only 4 components to Lua (`pose[1..4]` == `pose.x/.y/.z/.w`; `pose[5..16]` → `nil`;
  `translation` / `position` / `row1..4` / `m11` / `m44` → `nil`; no methods at all), and those 4 are themselves
  garbage. `Unit.id` → `nil`. `Unit.name_hash` → a garbage string (do not use it).
  **A third party reports a plausible coordinate (`Vector3(110.699356, -944.186157, -313.060883)`) from a mission;
  with the evidence above, the likely explanation is another snapshot of the same uninitialised memory** — a value
  that merely *looks* like a position. This is not an accusation of fabrication; it is a statement that the API's
  return value cannot be trusted.

**Conclusion:** aim/ESP/distance mods are not reachable from this Lua surface. Anything that needs a specific
dynamic unit's position is a native-layer problem.

---

## 4. Lua resource name space

Only three `lua` resource names are known to be reachable on this build:

| Name | `can_get("lua", …)` |
|---|---|
| `boot` | `true` |
| `core/wwise/lua/wwise_visualization` | `true` |
| `core/wwise/lua/wwise_bank_reference` | `true` |
| `core/wwise/lua/wwise_flow_callbacks` (BSL's only injection entry) | **`false`** |

`make_hash("core/wwise/lua/wwise_flow_callbacks")` still returns `7251fdd9bb62480a`, matching the hash recorded in
Bingus Shared Loader's own `docs/TECHNICAL.md` — so the name is right and the resource is genuinely unavailable.
BSL therefore cannot run on this build for **two** independent reasons: (1) its v20 **build gate** deliberately
starts no mods on an unsupported build, and (2) its only injection entry point is gone — the gate could be removed
and it still would not start.

Enumeration is closed, for structural reasons: every client-side index (`bundles.nxa`, `bundle_database.data`,
`bundles.region_hints`) stores hashes and offsets only, never paths, and `dl_library.dl_typelib` is encrypted. A
brute-force pass of 1,578 generated candidates produced **zero** additional hits. The community HD2 SDK's hash list
does provide 4,036 real names — for *content* resources, with **0 entries** for engine `lua`.

The loader therefore does not rely on any engine resource name except `boot` itself, and it ships its own modules as
additional resources in the same patch (§5).

---

## 5. Resource override is aliasing, not injection

Measured closed loop in a single session:

```
can_get('lua','hd2probe/override_target')                      = false
set_resource_override('lua','hd2probe/override_target','boot') -> nil
can_get('lua','hd2probe/override_target')                      = TRUE
clear_resource_override('lua','hd2probe/override_target')      -> nil
can_get('lua','hd2probe/override_target')                      = false
```

So the third argument is **a second resource name**, and the operation is "make name A resolve to existing
resource B". It cannot create content: `nil` crashes (`+0x3D203F`). Be precise about what was tested — we tried
`nil` (crashes) and a resource-name string (works). A path string and an object were **not** tried, so the earlier
wording "not a path, not an object" was an assumption, not a measurement.

Related but separate: `has_data('lua', <name>)` returns `false` and `get_data` returns `nil` even for an overridden
name. The DataLibrary channel (`get_data`/`set_data`/`has_data`) and the resource-override channel do not
interconnect; you cannot inject Lua source through `set_data`.

A patch archive **can** carry arbitrarily many `lua` resources — verified: adding a second resource made
`can_get("lua","hd2probe/injected")` true, and `Script.load` on it returned a chunk whose execution wrote a file
from inside the game. That is how the loader ships modules that must not live in `mods\`.

---

## 6. Gameplay values are a data-resource problem

`.dl_bin` files under `data/game/` are **libsodium sealed boxes** (32-byte ephemeral public key + 16-byte Poly1305
tag + XSalsa20 ciphertext; a fixed 48-byte overhead). Changing numbers means producing a new sealed box, which needs
the recipient key — and that key is not present in the shipped binaries as plaintext (the documented RVA reads as
zeros in the current, unpacked `helldivers2.exe`, and the XOR constant `0xEB63463F0C116E2C` matches nothing in
either the old packed EXE, the new EXE, or the 49 MB `game.dll`).

Two ways this is worked around in the ecosystem, neither of which is this loader's business:

- authors who already hold pre-sealed payloads (e.g. ArmoryForge ships 32 of them inside its `boot` payload), or
- offline analysis against a plaintext mirror of the data library, then re-sealing on the author's side.

The loader's job ends at "your Lua module gets executed with full engine access". Numbers are a different route.

---

## 7. Native / signed-DLL route

Measured model, for anyone who needs it: loading a native plugin passes **two** gates.

| Gate | Failure code | Meaning |
|---|---|---|
| PE / mapping layer | `193` | the image could not be mapped (path/origin/name conflict, not a policy decision) |
| Authenticode signature | `577` | no *valid* signature from a publicly trusted chain |
| both pass | `127` | loaded |

Evidence: an unsigned third-party DLL → `577`; a self-signed DLL with its root imported into `LocalMachine\Root`
(Authenticode reports Valid) → still `577`, so **locally installed roots are not enough** — the chain must be
publicly trusted. Expired certificates → `577` (one sample: DigiCert EV, expired 2022). Moved/renamed copies of
already-loaded system DLLs → `193`, which is why `193` must never be read as "signature rejected".

This is not part of the loader. It is recorded here because every "why not just do X" question ends at it.

---

## 8. Not verified / open

- Whether any *other* engine `lua` resource is loadable at runtime (name space is closed, §4).
- Whether `render` is called on every frame in all game states (it is defined because a missing hook crashes; mods
  should not depend on its cadence).
- Behaviour on builds other than **26088801** / 25988413. Nothing here transfers automatically; the RVAs and the
  hook set are build-specific.
- Whether **any** engine path can return a real unit position. Every route we tried either gives uninitialised data
  (`Unit.world_position` / `Unit.world_pose`, §3) or kills the process (`units[i]` for i ≥ 2 at `+0x3E5654`,
  `UnitComponent.unit`, `World.unit_by_id`). A usable position likely needs the native layer.
