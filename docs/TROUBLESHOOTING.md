# Troubleshooting

**English** | [简体中文](TROUBLESHOOTING.zh-CN.md)

Every entry here is a failure this project actually hit, with the measurement that identified it. Symptom → cause
→ fix.

---

## 1. Game crashes right after the loader logs its first lines

**Symptom.** `mods\loader.log` contains `=== hd2 pure-lua loader start ===` and the `[host] … hooked …` lines, then
nothing. The process dies. No Lua error is logged. `%APPDATA%\Arrowhead\Helldivers2\dumps\` gains a dump with:

```
ExceptionCode    0xC0000005
ExceptionAddress helldivers2.exe + 0x79A553
```

**Cause.** The `boot` payload does not define all four engine hooks. The engine calls `init`, `update`, `render` and
`shutdown` and does **not** null-check them; a missing one is a null call inside the host's Lua error path.

**Fix.** Define all four unconditionally, even if some are no-ops, and `pcall`-chain whatever was there before. This
loader does that since 0.2.0. If you are writing your own payload, copy that pattern:

```lua
init, shutdown, update, render = noop, noop, noop, noop   -- claim all four slots first
```

**Why it is easy to miss:** a merged build (your payload appended after a third-party payload that already claims all
four) works fine, so the bug only appears in solo builds.

---

## 2. Nothing happens at all — no log file, no crash

**Symptom.** Game starts and runs normally, `mods\` gets no `loader.log`.

**Cause A — wrong patch slot.** This build reads **only `data\9ba626afa44a3aa3.patch_0`**. A payload placed in
`patch_14` (or any other number) is never read. Measured: identical bytes in `patch_14` → nothing at all; in
`patch_0` → immediate effect.

**Cause B — the game was running when you copied the file.** The archive is read at startup; copying `patch_0` while
the game is open has no effect until the next launch.

**Cause C — missing sidecar files.** Ship all three: `…patch_0`, `…patch_0.gpu_resources`, `…patch_0.stream`. The
latter two may be zero-length, but they must exist.

---

## 3. The game hangs; `Responding=False`; a `cmd.exe` shows up

**Symptom.** The game window freezes, Task Manager says "Not Responding", and there is a `cmd.exe` whose parent
process is `helldivers2.exe`.

**Cause.** Something called `os.execute` or `io.popen` from inside the game process. Both block the main thread
indefinitely — they start a child process and then wait for it on the thread that also has to pump the game's
messages.

**Fix.** Never expose or use them. This loader does not, and it does not hand them to mods. Consequences you have to
live with:

- you cannot create directories from Lua — ship the `mods\` layout yourself,
- you cannot enumerate directories — hence `mods\mods.txt` plus the `01`…`20` probe (`io.open("<dir>\\main.lua")`
  is the only way to test "does this directory have an entry" without spawning anything).

**Note.** A Lua test script run outside the game can use `os.execute` happily; a `Permission denied` in that context
means nothing about the game.

---

## 4. `loader.log` is full of mojibake

**Symptom.** Reading the log with PowerShell shows `����` where Chinese text should be.

**Cause.** The loader writes **UTF-8**; Windows PowerShell defaults to the ANSI codepage (GBK on a Chinese system).

**Fix.**

```powershell
Get-Content .\mods\loader.log -Encoding UTF8
# or
[System.IO.File]::ReadAllLines("…\mods\loader.log", [System.Text.Encoding]::UTF8)
```

---

## 5. "The file is being used by another process" when reading a mod's log

**Cause.** That mod keeps its log handle open for the whole session (P2P Ping does). `[System.IO.File]::ReadAllLines`
fails; `Get-Content` tolerates it.

**Fix.** Use `Get-Content`, and prefer a reader you can point at a file that may be held. If you write your own mod,
open/write/close per line.

---

## 6. The archive you built does not behave like the original

**Symptom.** You rebuilt a payload that is supposed to be identical and the game ignores it, or an archive parser
disagrees with the game.

**Cause — the `0x20` field.** In this archive format the `0x20` field is **the capacity rounded up to 256 bytes**, not
the actual end of the data. Writing the real length there produces an archive the game will not read.

**Cause — tail padding.** Do **not** pad the resource block to 16 bytes. The reference packer does not.

**How to be sure:** rebuild the *known-good original* payload with your writer and require a byte-exact match before
you trust it with a modification. That is exactly what `build_loader_patch.py --verify-original` does: it reproduces
the reference archive — **797,815 B file** = 184 B of headers rounded up to 192 B + **797,623 B** resource area,
holding a **797,615 B** Lua source — byte-for-byte. Keep those three numbers apart; conflating them is how a wrong
claim gets published.

Layout as implemented (all little-endian):

```
0x00  u32  magic = 0xF0000011
0x04  u32  num_types
0x08  u32  num_files
0x0C  20 B padding
0x20  u64  capacity   (= 256-byte aligned end of data)
0x28  u64  unknown    (0)
0x30  24 B padding                      → header is 72 bytes
0x48  num_types × 32 B  <IIQIIII>  (0, 0, type_id, count, 0, 16, 16)
      num_files × 80 B  <7Q6I>     (file_id, type_id, offset, 0,0,0,0,
                                    data_size, 0, 0, 16, 16, index)
      align16 → resource area
            u32 lua_len, u32 mode(=2), lua source
```

`file_id` = `MurmurHash64A(resource_name, seed 0)`. Cross-checked in game: `Application.make_hash("boot")` returns
`f476df93691895fa`, which is the id this project uses.

---

## 7. `luac5.1 -l dump.luac` says "bad header in precompiled chunk"

**Cause.** The bundled `luac5.1.exe` is a **64-bit** build (`size_t` = 8). The game's Lua is **32-bit**
(`size_t` = 4). The headers differ in byte 8, so the stock disassembler refuses the file.

**Fix.** Parse the bytecode yourself with `size_t` = 4. `tools/lua51_disasm.py` does that, including two structural
quirks that are easy to get wrong:

1. the main chunk from `string.dump` is followed **directly** by the source string — there is no separate
   `sizeupvalues` byte,
2. order is `code → constants → debug → protos`, and in Stingray's Lua variant the whole **debug section is
   stripped**, so after `constants` comes `sizep` immediately.

---

## 8. A BSL-style mod is loaded but never ticks

**Symptom.** `[load] <name> ok` appears, then nothing.

**Cause.** BSL mods do not return a table; they wrap the global `update` from inside their chunk. If the loader's
sandbox `update` slot is missing or already claimed, their wrapper is never installed.

**Fix / diagnose.** The loader logs `[bsl] first tick -> <name>` the first time it calls a mod's wrapped `update`.
No such line means either the mod never wrapped anything, or it bailed out early. Check its own log
(`loader.open_log`) for a bail-out message.

Related trap measured early on: the first sandbox version did not expose `rawget`/`rawset`, and a real BSL mod died
on its fourth line with `attempt to call global 'rawget' (a nil value)`. Both are pure-Lua operations and are
required, not optional.

---

## 9. A probe crashed the game and you do not know which call did it

**Procedure that works** (used to identify every RVA in `COMPATIBILITY.md`):

1. **Write a numbered log line before every engine call** that could plausibly crash. `pcall` cannot catch an access
   violation; the last line written is your crash site.
2. **Call each unknown API exactly once**, then check the result type, then decide whether to loop. A batch design
   (5 units per frame) loses all information on the first crash.
3. **Space the calls out** (a few seconds apart) so the survivors are distinguishable.
4. Let it crash, then convert the address:

```powershell
# ExceptionAddress - module base = RVA   (modular arithmetic uses the loader base, not the file offset)
python McOP2fix\dump-stack.py  "%APPDATA%\Arrowhead\Helldivers2\dumps\dump-….dmp"
```

5. Compare the RVA with the known table. Four of the crash points cluster in `0x3C0000–0x3F0000` (same
   look-up-then-dereference code), and Lua-level failures sit near `+0x79A5xx`.

**Do not** trust the call stack in the dump: the reported stack frames are crashpad's own
(`dbgcore.dll+0x108`, `ntdll!Rtlp…`), so only `ExceptionAddress` and the registers are meaningful.

---

## 10. Steam's "verify integrity of game files" and the loader

**Measured 2026-10-23: it does *not* remove the loader.** Someone will tell you otherwise; we assumed so
ourselves until we ran it.

Steam only validates files that appear in its own manifest. A file it does not know about is left alone. We
snapshotted the full `bin\` and `data\` trees before and after a complete verification run:

| | before | after |
|---|---|---|
| `bin\` files | 45 | 45, all SHA256 identical |
| `data\` files | 99 | 99 |
| `data\9ba626afa44a3aa3.patch_0` | 821,753 B | present, same SHA256 |
| `bin\hd2probe\` (our own subdirectory) | 19 files | 19 files |

**What does remove it: a game update.** When the build changes, Steam replaces the `data/` files it manages, and
in any case every address in this project's crash table is build-specific — a new build invalidates the loader
whether or not the file survives.

So: verifying files is safe. Updating the game is the thing to plan for.

---

## 11. Two `boot` mods: only one of them runs

**Symptom.** You installed a second mod that also overrides the `boot` resource. One of the two silently stops
working.

**Cause.** This build reads **exactly one** archive slot for boot content: `data\9ba626afa44a3aa3.patch_0`. It is not
a queue and not a stack — two `patch_0` files cannot coexist, and a payload in `patch_1`…`patch_14` is never read.
Whoever wrote `patch_0` last wins.

**Fix.** Merge them into a single payload instead of picking a winner: build with
`--host-payload <the other mod's boot payload.lua>`, which appends the loader after the host's Lua and `pcall`-chains
its `init` / `update` / `render` / `shutdown`. Both mods then run in the same chunk. If the host payload is not a
plain `.lua` (it is already encoded into an archive), extract it first.

Note the ordering constraint: the host payload must define `update`/`shutdown` as **globals** and must not end in a
top-level `return` — otherwise there is nothing to chain to. See [§1](#1-game-crashes-right-after-the-loader-logs-its-first-lines)
for the four-hook requirement.

---

## 12. Deploying through HD2MM wiped patches I had installed by hand

**Symptom.** You deploy something in HD2MM, and other mods you had copied into `data\` by hand vanish — no warning,
and nothing in the Recycle Bin.

**Cause.** HD2MM's *Deploy* makes `data\` match **the set of enabled mods**: it removes every `9ba626*.patch_*` file
first, then lays down only what the enabled mods provide. Anything it does not manage goes with them. That is by
design, not a bug — but it is destructive to hand-installed content.

**Measured 2026-10-23:** enabling only this loader removed **36 patch files / 314 MB** that had been placed by hand —
`patch_1.gpu_resources` (121 MB), `patch_9.gpu_resources` (85 MB), `patch_8.stream` (67 MB), `patch_4` (30.5 MB) and
the rest. The Recycle Bin held none of them and HD2MM's `Temp` directory was empty.

**What to back up — the patch family, not all of `data\`.** Most of `data\` is official and Steam restores it; the
irreplaceable part is the patch files:

```powershell
$bk = "E:\hd2mm-backup\$(Get-Date -Format yyyyMMdd-HHmm)"
New-Item -ItemType Directory -Force -Path $bk | Out-Null
Copy-Item "<game>\data\9ba626*.patch_*" $bk -Force
```

Restoring is the reverse copy. Mods that HD2MM itself manages need no such backup — their original ZIPs stay in
HD2MM's `Mods` directory and can simply be redeployed.

---

## 13. "Does this build still allow script mods at all?"

Measured answer: **yes, through this route.** `.patch` archives still load, the engine's Lua state still executes a
`boot` payload, and `Script.load` still returns callable chunks. What died on 2026-10-20 is (a) the third-party
loaders, and (b) signed-DLL plugin loading. If you are debugging "is Lua dead?", the answer is no — check your
deployment slot and your hook set first.

---

## 14. You changed the loader and want to know it still works

```powershell
# 1. syntax gate (catches Lua 5.1-only errors with zero game launches)
E:\DSH\_hd2mm\_work\lua51\luac5.1.exe -p loader\loader_core.lua

# 2. build; --verify also rebuilds the reference payload and requires byte equality
python loader\build_loader_patch.py --solo --verify

# 3. structure check before deploying
python …\verify_solo_patch.py        # every header/TOC field vs the packing rules

# 4. deploy with the game closed, launch through Steam, read mods\loader.log
Start-Process 'steam://rungameid/553850'
```

Expected solo log (no third-party host payload present):

```
=== hd2 pure-lua loader start ===
[host] update/shutdown hooked (prev_update=nil, prev_shutdown=nil)
[host] init/render hooked (prev_init=nil, prev_render=nil)
[boot] mods root = mods, found 2 dir(s)
[load] hello-loader-test ok (version=1.0.0)
[boot] loaded 2 mod(s)
```

`prev_*` being `nil` is correct for a solo build and `function` for a merged build — that is the cheapest way to tell
which one you are actually running.

---

## 15. A second patch in `data\` is silently ignored

The engine merges `data\<bundle>.patch_N` **in contiguous order**: once the chain has a gap, every patch after the gap
is not read at all — the files are on disk, the hashes match, and the game behaves as if they were not there.

Measured on this build (another group's controlled experiment): with `patch_1` and `patch_2` deleted and only
`patch_3` present, six probe mods came back `absent` (0 found / 0 loaded / 6 absent); with a contiguous
`patch_0..patch_3` the same probes loaded (3 / 3 / 3).

What to do:

- Keep the chain contiguous from `patch_0` upward. Never "tidy up" by deleting a middle slot.
- If you only run this loader you do **not** need extra slots at all — one `patch_0` is the whole install. HD2MM's
  Deploy actually helps here: it clears every other `9ba626*.patch_*` and leaves a single contiguous `patch_0` (the
  cost of that behaviour is #12).
- If you stack several hand-installed patches, check the numbering before blaming the mod.

*Note:* that measurement is one observation by another group (gap state 0/0/6 vs contiguous 3/3/3); we have not
re-run it ourselves. The mechanism matches everything else we know about `patch_N` loading — the engine reads the
chain at startup, in order (see `docs/COMPATIBILITY.md` §2).
