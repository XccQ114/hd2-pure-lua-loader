"""Pack the pure-Lua loader into a `boot` anchor patch (build 25988413).

Layout rules below are the ones measured on a retail install. They are not
guesses — the `0x20` field is a 256-byte-aligned **capacity** (not the real
end of the data) and the resource block gets **no** tail padding. If you change
either, the game silently ignores the archive.

Usage
-----
    python build_loader_patch.py --solo
        The loader alone is the whole `boot` payload. This is the normal
        deployment: nothing else in the archive.

    python build_loader_patch.py --host-payload PATH/TO/host_payload.lua
        Append the loader after an existing third-party `boot` payload so both
        run (the loader pcall-chains the host's hooks). The host payload is not
        redistributed here; bring your own.

    python build_loader_patch.py --probe-resource
        Additionally ship a tiny extra lua resource, used to verify that a patch
        can carry more than one resource.

    python build_loader_patch.py --solo --verify-original PATH/TO/original.patch_0 --host-payload PATH/TO/host_payload.lua
        Self-check: rebuild the *known-good original* payload with these same
        rules and require a byte-exact match before writing anything.

    python build_loader_patch.py --solo --verify-original PATH --host-payload PATH --host-payload-already-appended
        (same idea, when the reference archive is a merged one)

Environment
-----------
    HD2_HOST_PAYLOAD   default for --host-payload
    LUAC               path to luac 5.1 (optional; skips the syntax gate if absent)

Output
------
    loader/dist/9ba626afa44a3aa3.patch_0  (+ .gpu_resources and .stream, both empty)
    Copy all three into  <game>\\data\\  with the game closed.
"""
import os
import shutil
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
LOADER = os.path.join(HERE, "loader_core.lua")
DIST = os.path.join(HERE, "dist")
PATCH_NAME = "9ba626afa44a3aa3.patch_0"

TYPE = 0xA14E8DFA2CD117E2          # lua resource type id in this archive family
BOOT_ID = 0xF476DF93691895FA       # MurmurHash64A("boot", seed 0)
CAP_ALIGN = 256                    # the 0x20 field is aligned to this

# Extra probe resource (--probe-resource). Its id is MurmurHash64A(name, seed 0),
# the same function Application.make_hash uses in game.
PROBE_RESOURCE_NAME = "hd2probe/injected"
PROBE_RESOURCE_LUA = (
    b"local lied = false\n"
    b"pcall(function()\n"
    b"  local f = io.open('mods\\\\injected_ran.log', 'a')\n"
    b"  if f then f:write('[injected] executed at ' .. tostring(os.time()) .. '\\n'); f:flush(); f:close(); lied = true end\n"
    b"end)\n"
    b"return { ok = true, from = 'patch-resource', logged = lied }\n"
)

_M64_MASK = (1 << 64) - 1
_M64_MIX = 0xC6A4A7935BD1E995


# --------------------------------------------------------------------- args

def arg_value(flag):
    """--flag VALUE or --flag=VALUE, from sys.argv."""
    argv = sys.argv[1:]
    for i, a in enumerate(argv):
        if a == flag and i + 1 < len(argv):
            return argv[i + 1]
        if a.startswith(flag + "="):
            return a.split("=", 1)[1]
    return None


def has_flag(flag):
    return flag in sys.argv[1:]


HOST_PAYLOAD = arg_value("--host-payload") or os.environ.get("HD2_HOST_PAYLOAD", "")
VERIFY_ORIGINAL = arg_value("--verify-original")


def find_luac():
    candidates = [
        os.environ.get("LUAC"),
        os.path.join(HERE, "luac5.1.exe"),
        os.path.join(HERE, "luac51.exe"),
        os.path.join(REPO, "tools", "luac5.1.exe"),
    ]
    for c in candidates:
        if c and os.path.exists(c):
            return c
    for name in ("luac5.1", "luac51", "luac"):
        found = shutil.which(name)
        if found:
            return found
    return None


# ------------------------------------------------------------------- hashing

def resource_hash(name: str) -> int:
    """Stingray resource id: MurmurHash64A(name, seed=0)."""
    data = name.encode("utf-8")
    value = len(data) * _M64_MIX & _M64_MASK
    end = len(data) // 8 * 8
    for (w,) in struct.iter_unpack("<Q", data[:end]):
        w = w * _M64_MIX & _M64_MASK
        w ^= w >> 47
        value = (value ^ (w * _M64_MIX & _M64_MASK)) * _M64_MIX & _M64_MASK
    if data[end:]:
        value = (value ^ int.from_bytes(data[end:], "little")) * _M64_MIX & _M64_MASK
    value ^= value >> 47
    value = value * _M64_MIX & _M64_MASK
    return value ^ (value >> 47)


def align(n, a):
    return (n + a - 1) & ~(a - 1)


# ------------------------------------------------------------------- archive

def make_archive(resources):
    """resources: {resource_id: bytes}. Returns (archive_bytes, capacity)."""
    count_ = len(resources)
    offset = (104 + 80 * count_ + 15) & ~15
    entries, body = bytearray(), bytearray(offset)
    for index, (name, resource) in enumerate(sorted(resources.items())):
        entries += struct.pack('<7Q6I', name, TYPE, offset, 0, 0, 0, 0,
                               len(resource), 0, 0, 16, 16, index)
        body += resource
        offset = len(body)          # deliberately no 16-byte tail padding
    cap = align(offset, CAP_ALIGN)
    header = struct.pack('<III20sQQ24s', 0xF0000011, 1, count_, b'', cap, 0, b'')
    types = struct.pack('<IIQIIII', 0, 0, TYPE, count_, 0, 16, 16)
    body[:104 + len(entries)] = header + types + entries
    return bytes(body), cap


def wrap_lua(source: bytes) -> bytes:
    """A lua resource is: u32 length, u32 mode (2 = Lua source), then the source."""
    return struct.pack('<II', len(source), 2) + source


def build(payload_lua: bytes, extras=None):
    payload = wrap_lua(payload_lua)
    resources = {BOOT_ID: payload}
    if extras:
        resources.update(extras)
    return make_archive(resources)


def verify_against_original(original_path, host_payload_path, host_payload_is_merged):
    """Rebuild the reference payload with these rules and require byte equality."""
    if not os.path.exists(original_path):
        print(f"[verify] skipped: {original_path} not found")
        return None
    with open(original_path, "rb") as f:
        orig = f.read()
    with open(host_payload_path, "rb") as f:
        src = f.read()
    if not host_payload_is_merged:
        arc, cap = build(src)
    else:
        with open(LOADER, "rb") as f:
            merged = src + b"\n" + f.read()
        arc, cap = build(merged)
    same = arc == orig
    print(f"[verify] rebuilt reference: {'OK' if same else 'MISMATCH'}"
          f"  (generated {len(arc):,} B / reference {len(orig):,} B, cap={cap:,})")
    if not same:
        for i, (a, b) in enumerate(zip(arc, orig)):
            if a != b:
                print(f"[verify] first difference @ {i}: ours=0x{a:02X} orig=0x{b:02X}")
                break
    return same


# ---------------------------------------------------------------------- main

def main():
    solo = has_flag("--solo")
    probe_resource = has_flag("--probe-resource")
    os.makedirs(DIST, exist_ok=True)

    if not os.path.exists(LOADER):
        print(f"[abort] loader source not found: {LOADER}")
        return 1
    with open(LOADER, "rb") as f:
        loader_src = f.read()

    # ---------------------------------------------------- self-check (optional)
    if VERIFY_ORIGINAL:
        if not HOST_PAYLOAD:
            print("[abort] --verify-original needs --host-payload to rebuild the reference")
            return 1
        ok = verify_against_original(VERIFY_ORIGINAL, HOST_PAYLOAD,
                                     has_flag("--host-payload-already-appended"))
        if ok is False:
            print("[abort] the writer does not reproduce the reference archive; refusing to write")
            return 1

    # ------------------------------------------------------------- syntax gate
    luac = find_luac()
    if luac:
        import subprocess
        r = subprocess.run([luac, "-p", LOADER], capture_output=True, text=True)
        if r.returncode != 0:
            print("[abort] luac syntax check failed:")
            print((r.stdout or "") + (r.stderr or ""))
            return 1
        print("[luac] syntax OK")
    else:
        print("[luac] not found — skipping syntax gate (set LUAC=/path/to/luac5.1 to enable)")

    # --------------------------------------------------------------- payload
    if solo:
        merged = loader_src
        print(f"[mode] solo: loader {len(merged):,} B")
    else:
        if not HOST_PAYLOAD:
            print("[abort] merge mode needs --host-payload PATH (or use --solo).")
            print("        The third-party host payload is not redistributed with this repo.")
            return 1
        if not os.path.exists(HOST_PAYLOAD):
            print(f"[abort] host payload not found: {HOST_PAYLOAD}")
            return 1
        with open(HOST_PAYLOAD, "rb") as f:
            base = f.read()
        merged = base + b"\n" + loader_src
        print(f"[mode] merge: host {len(base):,} B + loader {len(loader_src):,} B "
              f"= {len(merged):,} B")

    # --------------------------------------------------------------- extras
    extras = None
    if probe_resource:
        probe_id = resource_hash(PROBE_RESOURCE_NAME)
        extras = {probe_id: wrap_lua(PROBE_RESOURCE_LUA)}
        print(f"[probe] extra resource {PROBE_RESOURCE_NAME!r}")
        print(f"        id = 0x{probe_id:016X}  payload = {len(extras[probe_id])} B")
        boot_check = resource_hash("boot")
        print(f"[probe] self-check resource_hash('boot') = 0x{boot_check:016X} "
              f"{'OK' if boot_check == BOOT_ID else 'MISMATCH! do not deploy'}")

    # ----------------------------------------------------------------- write
    archive, cap = build(merged, extras)
    dst = os.path.join(DIST, PATCH_NAME)
    with open(dst, "wb") as f:
        f.write(archive)
    for side in ('.gpu_resources', '.stream'):
        with open(dst + side, 'wb') as f:
            f.write(b'')

    print(f"[out] {dst}")
    print(f"      file={len(archive):,} B  payload={len(merged):,} B  "
          f"resources={1 + (1 if extras else 0)}  cap(0x20)={cap:,}")
    print()
    print("Deploy (the game must be closed):")
    print(f'  Copy-Item "{dst}*" "<game>\\data\\" -Force')
    print("  mod manifest: <game>\\mods\\mods.txt   (one mod directory per line)")
    print("Roll back: restore the patch_0 trio you backed up first.")
    return 0


if __name__ == '__main__':
    sys.exit(main())
