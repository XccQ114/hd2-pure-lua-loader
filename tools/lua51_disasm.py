"""Lua 5.1 字节码解析器（32 位 size_t 变体）

背景：游戏内 `Script.load` + `string.dump` 拿到的 chunk，header 是
  int=4 size_t=4 instr=4 num=8 integral=0
而本机的 luac5.1.exe 是 64 位编译（size_t=8），所以 `luac -l` 直接报
"bad header in precompiled chunk"。本脚本自己按 32 位 size_t 解析，
输出常量表与反汇编指令，用于阅读游戏自己的 Lua 资源。

用法：python lua51_disasm.py <file.luac> [--max-insn N]
"""
import sys
import struct

OPNAMES = [
    "MOVE", "LOADK", "LOADBOOL", "LOADNIL", "GETUPVAL", "GETGLOBAL", "GETTABLE",
    "SETGLOBAL", "SETUPVAL", "SETTABLE", "NEWTABLE", "SELF", "ADD", "SUB", "MUL",
    "DIV", "MOD", "POW", "UNM", "NOT", "LEN", "CONCAT", "JMP", "EQ", "LT", "LE",
    "TEST", "TESTSET", "CALL", "TAILCALL", "RETURN", "FORLOOP", "FORPREP",
    "TFORLOOP", "SETLIST", "CLOSE", "CLOSURE", "VARARG",
]


class Reader:
    def __init__(self, data, size_t=4):
        self.d = data
        self.p = 0
        self.size_t = size_t

    def byte(self):
        v = self.d[self.p]
        self.p += 1
        return v

    def u32(self):
        v = struct.unpack_from("<I", self.d, self.p)[0]
        self.p += 4
        return v

    def i32(self):
        v = struct.unpack_from("<i", self.d, self.p)[0]
        self.p += 4
        return v

    def u64(self):
        v = struct.unpack_from("<Q", self.d, self.p)[0]
        self.p += 8
        return v

    def size(self):
        if self.size_t == 4:
            return self.u32()
        return self.u64()

    def string(self):
        n = self.size()
        if n == 0:
            return None
        s = self.d[self.p:self.p + n]
        self.p += n
        return s


def read_function(r, depth=0, out=None, max_insn=None, counter=None):
    src = r.string()
    linedefined = r.i32()
    lastlinedefined = r.i32()
    nups = r.byte()
    numparams = r.byte()
    is_vararg = r.byte()
    maxstack = r.byte()

    ncode = r.u32()
    code = [struct.unpack_from("<I", r.d, r.p + 4 * i)[0] for i in range(ncode)]
    r.p += 4 * ncode

    nk = r.u32()
    consts = []
    for _ in range(nk):
        t = r.byte()
        if t == 0:
            consts.append(("nil", None))
        elif t == 1:
            consts.append(("bool", r.byte()))
        elif t == 3:
            consts.append(("num", struct.unpack_from("<d", r.d, r.p)[0]))
            r.p += 8
        elif t == 4:
            consts.append(("str", r.string()))
        else:
            raise ValueError("bad constant type %d at 0x%X" % (t, r.p))

    nprotos = None
    # ★ 关键结构发现（三个样本实测一致，别再按教科书改回去）：
    #   Stingray 的 Lua 变体在 string.dump 时**把 debug 段 strip 了**：
    #   constants 之后**直接是 sizep**（protos 数量），没有 lineinfo/locvars/upvalues 三段。
    #   判据：dump_injected.luac 在 consts 结束处读到 u32=1，其后依次是
    #         source_len=0（NULL，复用父 source）、linedefined=2、lastlinedefined=5
    #         —— 与我们那段 pcall(function() … end) 跨第 2–5 行完全对上；
    #         若按标准 debug 读，会把 1 当成 sizelineinfo，而 ncode=11，对不上。
    debug_ok = True
    fn_note = "debug 段已 strip（Stingray 变体），直接读 sizep"
    try:
        nprotos = r.u32()
        if nprotos > 100000:
            raise ValueError("sizep 荒谬: %d" % nprotos)
    except Exception as e:
        debug_ok = False
        nprotos = 0
        fn_note = "sizep 读取失败（%s），子函数不可达" % e

    protos = []
    for _ in range(nprotos or 0):
        try:
            before = r.p
            protos.append(read_function(r, depth + 1))
        except Exception:
            r.p = before
            break

    fn = {
        "source": src, "linedefined": linedefined, "lastlinedefined": lastlinedefined,
        "nups": nups, "numparams": numparams, "is_vararg": is_vararg,
        "maxstack": maxstack, "code": code, "consts": consts, "protos": protos,
        "depth": depth, "note": fn_note,
    }
    return fn


def fmt_const(c):
    t, v = c
    if t == "str":
        try:
            return repr(v.decode("utf-8", "replace"))
        except Exception:
            return repr(v)
    if t == "num":
        return repr(v)
    if t == "bool":
        return "true" if v else "false"
    return "nil"


def dump_fn(fn, max_insn=None, show_code=True):
    ind = "  " * fn["depth"]
    src = fn["source"]
    src_s = src.decode("utf-8", "replace") if src else "(null)"
    print(f"{ind}function <{src_s}:{fn['linedefined']}-{fn['lastlinedefined']}> "
          f"params={fn['numparams']} vararg={fn['is_vararg']} nups={fn['nups']} "
          f"stack={fn['maxstack']} code={len(fn['code'])} consts={len(fn['consts'])}")
    if fn.get("note"):
        print(f"{ind}  ! {fn['note']}")
    if fn["consts"]:
        print(f"{ind}  constants:")
        for i, c in enumerate(fn["consts"]):
            print(f"{ind}    K{i:<3} {c[0]:<4} {fmt_const(c)}")
    if show_code and fn["code"]:
        print(f"{ind}  code:")
        limit = len(fn["code"]) if max_insn is None else min(len(fn["code"]), max_insn)
        for i in range(limit):
            ins = fn["code"][i]
            op = ins & 0x3F
            A = (ins >> 6) & 0xFF
            C = (ins >> 14) & 0x1FF
            B = (ins >> 23) & 0x1FF
            Bx = (ins >> 14) & 0x3FFFF
            sBx = Bx - 131071
            name = OPNAMES[op] if op < len(OPNAMES) else f"OP_{op}"
            extra = ""
            if name in ("LOADK", "GETGLOBAL", "SETGLOBAL", "CLOSURE"):
                if 0 <= Bx < len(fn["consts"]):
                    extra = "  ; " + fmt_const(fn["consts"][Bx])
            elif name == "JMP":
                extra = f"  ; to {i + 1 + sBx}"
            elif name == "GETTABLE":
                if 0 <= C < len(fn["consts"]):
                    extra = "  ; " + fmt_const(fn["consts"][C])
            elif name in ("SETTABLE",):
                if 0 <= B < len(fn["consts"]):
                    extra = "  ; " + fmt_const(fn["consts"][B])
            print(f"{ind}    [{i:4}] {name:<10} A={A:<3} B={B:<3} C={C:<3} "
                  f"Bx={Bx:<6} sBx={sBx:<6}{extra}")
        if limit < len(fn["code"]):
            print(f"{ind}    ... ({len(fn['code']) - limit} more)")
    for p in fn["protos"]:
        dump_fn(p, max_insn, show_code)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    path = sys.argv[1]
    max_insn = None
    if "--max-insn" in sys.argv:
        max_insn = int(sys.argv[sys.argv.index("--max-insn") + 1])

    data = open(path, "rb").read()
    if data[:4] != b"\x1bLua":
        print("不是 Lua 字节码")
        return 1
    ver, fmt, endian, si, sst, sinstr, snum, integral = data[4:12]
    print(f"[header] ver=0x{ver:02X} format={fmt} endian={endian} "
          f"int={si} size_t={sst} instr={sinstr} num={snum} integral={integral}")

    r = Reader(data, size_t=sst)
    r.p = 12
    # ★ 实测：string.dump 的 main chunk 后面**直接**是 source 字符串，
    #   没有单独的 sizeupvalues 字节（与部分文档描述不同，此处以字节流为准）。
    fn = read_function(r)
    dump_fn(fn, max_insn)
    print(f"\n[parsed {r.p} / {len(data)} bytes]")
    return 0


if __name__ == "__main__":
    sys.exit(main())
