#!/usr/bin/env python3
"""Generate the I32/I64 engine fixtures and their value pins (INTEGER-TYPES-DESIGN §4, N6).

Every expected value is computed here, in Python, from the semantics the design
states (two's complement wrap, C's truncating division, arithmetic right shift,
a shift of the width or more giving 0 or -1), never captured from an engine.

    python3 test/engine_fixtures/gen_signed_edges.py

rewrites test/engine_fixtures/{i32,i64}_signed_edges.mdk and
test/engine_value_pins/engine/{i32,i64}_signed_edges.pin.
"""
import os

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def wrap(x, n):
    m = 1 << n
    return (x + (m >> 1)) % m - (m >> 1)


def tdiv(a, b):
    q = abs(a) // abs(b)
    return q if (a < 0) == (b < 0) else -q


def trem(a, b):
    return a - b * tdiv(a, b)


def shr(a, k, n):
    if k >= n:
        return -1 if a < 0 else 0
    return a >> k


def shl(a, k, n):
    return 0 if k >= n else wrap(a << k, n)


def sig(a):
    return (a > 0) - (a < 0)


def show(v):
    if v is True:
        return "True"
    if v is False:
        return "False"
    if isinstance(v, tuple):
        return "Some " + str(v[1]) if v[0] else "None"
    return str(v)


def lst(vs):
    return "[" + ", ".join(show(v) for v in vs) + "]"


def build(n, vals, mod, bystander_mdk, bystander_out, extra_mdk, extra_out):
    t = "I%d" % n
    lo = -(1 << (n - 1))
    ops = [
        ("+ 1", "(x => x + 1)", lambda x: wrap(x + 1, n)),
        ("- 1", "(x => x - 1)", lambda x: wrap(x - 1, n)),
        ("* 3", "(x => x * 3)", lambda x: wrap(x * 3, n)),
        ("* -1", "(x => x * (-1))", lambda x: wrap(-x, n)),
        ("* self", "(x => x * x)", lambda x: wrap(x * x, n)),
        ("negate", "negate", lambda x: wrap(-x, n)),
        ("abs", "abs", lambda x: wrap(abs(x), n)),
        ("signum", "signum", sig),
        ("/ 7", "(x => x / 7)", lambda x: wrap(tdiv(x, 7), n)),
        ("% 7", "(x => x % 7)", lambda x: trem(x, 7)),
        ("/ -7", "(x => x / (-7))", lambda x: wrap(tdiv(x, -7), n)),
        ("% -7", "(x => x % (-7))", lambda x: trem(x, -7)),
        ("/ -1", "(x => x / (-1))", lambda x: wrap(tdiv(x, -1), n)),
        ("% -1", "(x => x % (-1))", lambda x: trem(x, -1)),
        ("/ minBound", "(x => x / minBound)", lambda x: wrap(tdiv(x, lo), n)),
        ("% minBound", "(x => x % minBound)", lambda x: trem(x, lo)),
        ("< 0", "(x => x < 0)", lambda x: x < 0),
        ("> -1", "(x => x > (-1))", lambda x: x > -1),
        ("<= minBound", "(x => x <= minBound)", lambda x: x <= lo),
        ("== -1", "(x => x == (-1))", lambda x: x == -1),
        ("shiftRight 1", "(x => %s.shiftRight x 1)" % mod, lambda x: shr(x, 1, n)),
        ("shiftRight w-1", "(x => %s.shiftRight x %d)" % (mod, n - 1), lambda x: shr(x, n - 1, n)),
        ("shiftRight w", "(x => %s.shiftRight x %d)" % (mod, n), lambda x: shr(x, n, n)),
        ("shiftRight 100", "(x => %s.shiftRight x 100)" % mod, lambda x: shr(x, 100, n)),
        ("shiftLeft 1", "(x => %s.shiftLeft x 1)" % mod, lambda x: shl(x, 1, n)),
        ("shiftLeft w-1", "(x => %s.shiftLeft x %d)" % (mod, n - 1), lambda x: shl(x, n - 1, n)),
        ("shiftLeft w", "(x => %s.shiftLeft x %d)" % (mod, n), lambda x: shl(x, n, n)),
        ("bitNot", "%s.bitNot" % mod, lambda x: ~x),
        ("bitAnd -256", "(x => %s.bitAnd x (-256))" % mod, lambda x: x & -256),
        ("bitXor minBound", "(x => %s.bitXor x minBound)" % mod, lambda x: wrap(x ^ lo, n)),
    ]
    src = []
    out = []
    src.append("vs : List %s" % t)
    src.append("vs = [")
    for v in vals:
        src.append("  %d," % v)
    src.append("]")
    src.append("")
    src.append("main =")
    src.append('  println "%s literals"' % t.lower())
    src.append("  println vs")
    out.append("%s literals" % t.lower())
    out.append(lst(vals))
    for label, fn, f in ops:
        src.append('  println "%s"' % label)
        src.append("  println (map %s vs)" % fn)
        out.append(label)
        out.append(lst([f(v) for v in vals]))
    src.append('  println "sorted"')
    src.append("  println (sort (reverse vs))")
    out.append("sorted")
    out.append(lst(sorted(vals)))
    src.append('  println "compare"')
    src.append("  println (map (x => compare x 0) vs)")
    out.append("compare")
    out.append(lst([{-1: "Lt", 0: "Eq", 1: "Gt"}[sig(v)] for v in vals]))
    src.append('  println "min max bounds"')
    src.append("  println (minBound : %s, maxBound : %s)" % (t, t))
    out.append("min max bounds")
    out.append("(%d, %d)" % (lo, (1 << (n - 1)) - 1))
    src.extend(extra_mdk)
    out.extend(extra_out)
    src.extend(bystander_mdk)
    out.extend(bystander_out)
    return src, out


I32_VALS = [-(1 << 31), -(1 << 31) + 1, -65536, -7, -1, 0, 1, 7, 65535, (1 << 31) - 1]
I64_VALS = [-(1 << 63), -(1 << 63) + 1, -(1 << 62) - 1, -(1 << 62), -(1 << 32), -7, -1, 0,
            1, 7, (1 << 32), (1 << 62) - 1, 1 << 62, (1 << 63) - 1]


def i64_toint(v):
    return (True, v) if -(1 << 62) <= v < (1 << 62) else (False, None)


def main():
    i32_extra_mdk = [
        '  println "toInt"',
        "  println (map I32.toInt vs)",
        '  println "toBits"',
        "  println (map I32.toBits vs)",
        '  println "truncate"',
        "  println (map I32.truncate [2147483648, 4294967295, -2147483649, 1099511627775])",
        '  println "tryFromInt"',
        "  println (map I32.tryFromInt [2147483648, -2147483648, -2147483649, 0])",
        '  println "fromBits"',
        "  println (map I32.fromBits [0, 1, 2147483647, 2147483648, 4294967295])",
        '  println "hash agrees with Int"',
        "  println (map (x => hash x == hash (I32.toInt x)) vs)",
        '  println "literal patterns"',
        "  println (map classify vs)",
    ]
    i32_extra_out = [
        "toInt", lst(I32_VALS),
        "toBits", lst([v % (1 << 32) for v in I32_VALS]),
        "truncate", lst([wrap(x, 32) for x in [2147483648, 4294967295, -2147483649, 1099511627775]]),
        "tryFromInt", lst([(False, None), (True, -2147483648), (False, None), (True, 0)]),
        "fromBits", lst([wrap(x, 32) for x in [0, 1, 2147483647, 2147483648, 4294967295]]),
        "hash agrees with Int", lst([True] * len(I32_VALS)),
        "literal patterns", lst([{0: "zero", 2147483647: "max", 65535: "ffff"}.get(v, "other") for v in I32_VALS]),
    ]
    i32_by_mdk = [
        '  println "bystanders"',
        "  println ((4294967295 : U32) + 1, (7 : U32) / 2, (0 : U32) - 1)",
        "  println ((-7) / 2, (-7) % 2, shiftRight (-16) 2)",
        "  println (hash 5 == hash (5 : U32))",
    ]
    i32_by_out = [
        "bystanders",
        "(0, 3, 4294967295)",
        "(-3, -1, -4)",
        "True",
    ]
    src, out = build(32, I32_VALS, "I32", i32_by_mdk, i32_by_out, i32_extra_mdk, i32_extra_out)
    head = [
        "-- I32 (N6, #3430, epic #3417), the signed tagged tier, at its edges: minBound,",
        "-- maxBound, -1, 0, minBound / -1, minBound % -1, negate and abs of minBound, and",
        "-- shifts of w - 1, w and past it.  I32 shares Int's word, held sign-extended, so",
        "-- a wrong sign extension shows as a value outside -2^31 .. 2^31 - 1.",
        "--",
        "-- The `bystanders` lines are [T-GLOBAL-TABLE]: U32 and Int in the same program",
        "-- keep their own semantics.",
        "--",
        "-- Generated with its pin by test/engine_fixtures/gen_signed_edges.py, which",
        "-- computes every expected value in Python; edit the generator, not this file.",
        "",
        "import i32 as I32",
        "import u32",
        "import list.{sort, reverse}",
        "",
        "classify : I32 -> String",
        "classify x = match x",
        '  0 => "zero"',
        '  2147483647 => "max"',
        '  65535 => "ffff"',
        '  _ => "other"',
        "",
    ]
    write("i32_signed_edges", head + src, out)

    big = [(1 << 63) - 1, 1 << 62, -(1 << 62) - 1, -(1 << 63)]
    i64_extra_mdk = [
        '  println "toInt"',
        "  println (map I64.toInt vs)",
        '  println "toBits"',
        "  println (map I64.toBits vs)",
        '  println "fromBits"',
        "  println (map I64.fromBits [0, 1, 0x7FFFFFFFFFFFFFFF, 0x8000000000000000, 0xFFFFFFFFFFFFFFFF])",
        '  println "fromI32 fromU32"',
        "  println (I64.fromI32 (-2147483648 : I32), I64.fromU32 (4294967295 : U32))",
        '  println "hash agrees with Int in range"',
        "  println (map (x => hash (I64.fromI32 x) == hash (I32.toInt x)) [-7, 0, 7])",
        '  println "wide literals"',
        "  println (-9223372036854775808 : I64, 9223372036854775807 : I64, -4611686018427387905 : I64)",
    ]
    i64_extra_out = [
        "toInt", lst([i64_toint(v) for v in I64_VALS]),
        "toBits", lst([v % (1 << 64) for v in I64_VALS]),
        "fromBits", lst([wrap(x, 64) for x in [0, 1, (1 << 63) - 1, 1 << 63, (1 << 64) - 1]]),
        "fromI32 fromU32", "(-2147483648, 4294967295)",
        "hash agrees with Int in range", "[True, True, True]",
        "wide literals", "(-9223372036854775808, 9223372036854775807, -4611686018427387905)",
    ]
    i64_by_mdk = [
        '  println "bystanders"',
        "  println ((18446744073709551615 : U64) / 3, (9223372036854775808 : U64) > 1, (0 : U64) - 1)",
        "  println ((-7) / 2, (-7) % 2, shiftRight (-16) 2)",
        "  println (hash 5 == hash (5 : U64))",
    ]
    i64_by_out = [
        "bystanders",
        "(%d, True, %d)" % (((1 << 64) - 1) // 3, (1 << 64) - 1),
        "(-3, -1, -4)",
        "True",
    ]
    src, out = build(64, I64_VALS, "I64", i64_by_mdk, i64_by_out, i64_extra_mdk, i64_extra_out)
    head = [
        "-- I64 (N6, #3430, epic #3417), the signed boxed tier, at its edges: minBound,",
        "-- maxBound, -1, 0, the magnitudes past Int (2^62, -2^62 - 1), minBound / -1,",
        "-- minBound % -1, negate and abs of minBound, and shifts of 63, 64 and past it.",
        "-- An I64 read as a U64 anywhere (order, division, rendering) shows as a wrong",
        "-- line here.",
        "--",
        "-- The `bystanders` lines are [T-GLOBAL-TABLE]: U64 and Int in the same program",
        "-- keep their own semantics.",
        "--",
        "-- Generated with its pin by test/engine_fixtures/gen_signed_edges.py, which",
        "-- computes every expected value in Python; edit the generator, not this file.",
        "",
        "import i64 as I64",
        "import i32 as I32",
        "import u32",
        "import u64",
        "import list.{sort, reverse}",
        "",
    ]
    write("i64_signed_edges", head + src, out)


def write(name, src, out):
    with open(os.path.join(ROOT, "test", "engine_fixtures", name + ".mdk"), "w") as fh:
        fh.write("\n".join(src) + "\n")
    with open(os.path.join(ROOT, "test", "engine_value_pins", "engine", name + ".pin"), "w") as fh:
        fh.write("\n".join(out) + "\n")


if __name__ == "__main__":
    main()
