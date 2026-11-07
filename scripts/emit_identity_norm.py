# Normaliser for scripts/emit_identity.sh: removes the checkout-tree path and nothing else.
# Each arm's emitter embeds ITS OWN tree root in the text it emits, so two trees at
# different paths never match byte for byte even when the compilers agree. A root is
# stripped from: (LLVM) every decoded `[N x i8] c"..."` constant, whose length prefix
# moves with the path, and any other line; (WAT) every run of
# `i32.const N / call $mdk_write_err_byte` pairs (or their folded form), decoded to one
# line, and any other line;
# (both) stderr. A stripped root also drops its trailing slash: an emitter spells a path
# relative to the entry's project when it can and absolute otherwise, so `<root>/x` and `x`
# are the same file. Each tree is stripped under its given spelling and its realpath, so a
# tree reached through a symlink compares equal to itself.
# Usage: python3 -I emit_identity_norm.py <out-dir> <treeA> <treeB> <ll|wat>
# For each entry that still differs prints `NORMALISED DIFFER <n>` and leaves the
# normalised forms in <out-dir>/{a,b}.<n>.norm. Last line:
# `norm: N entries, R raw differ, D differ after tree-path normalisation`.
# Exit 0 when D == 0, else 1.
import os
import re
import sys

out, tree_a, tree_b, kind = sys.argv[1:5]
spellings = set()
for t in (tree_a, tree_b):
    spellings.add(t)
    spellings.add(os.path.realpath(t))
roots = sorted((s.encode() for s in spellings), key=len, reverse=True)

CONST = re.compile(rb'^(\S+ = .*constant \[\d+ x i8\]) c"(.*)"(.*)$')
BYTE_CONST = re.compile(rb'^\s*i32\.const (\d+)\s*$')
BYTE_CALL = re.compile(rb'^\s*call \$mdk_write_err_byte\s*$')


def strip_roots(s):
    for r in roots:
        s = s.replace(r + b'/', b'').replace(r, b'<ROOT>')
    return s


def decode_llvm(s):
    return re.sub(rb'\\([0-9A-Fa-f]{2})', lambda m: bytes([int(m.group(1), 16)]), s)


SITEF = re.compile(rb'^@\.sitef\.(\d+) = ')
SITE_CALL = re.compile(rb'^(.*call [^@]*@mdk_[A-Za-z0-9_]*_at\((?:.*, )?i64 )(\d+)\)(.*)$')
SITE_FIRST_ARG_CALL = re.compile(rb'^(.*call [^@]*@mdk\.user\.([0-9a-f]+)\(i64 )(\d+)(,.*)$')
# `arrayIndexAt` takes its site as a boxed Int: (site << 1) | 1.
SITE_FIRST_ARG_FNS = (b'__arrayIndexAt',)
SITE_FILE_SHIFT = 44


def remap_site(site, rank):
    idx = site >> SITE_FILE_SHIFT
    if idx - 1 in rank:
        site = ((rank[idx - 1] + 1) << SITE_FILE_SHIFT) + (site & ((1 << SITE_FILE_SHIFT) - 1))
    return str(site).encode()


def norm_llvm(data):
    # Source locations are packed as (file index << 44) + line/col, and the file table is
    # sorted by full path (a site's file field is table index + 1), so two trees order
    # the same files differently. Files are renumbered by tree-relative path and the
    # packed site immediates of `@mdk_*_at` calls and of `arrayIndexAt` rewritten to match.
    src = data.split(b'\n')
    paths = {}
    for ln in src:
        m = CONST.match(ln)
        sm = SITEF.match(ln)
        if m and sm:
            paths[int(sm.group(1))] = strip_roots(decode_llvm(m.group(2)).rstrip(b'\0'))
    rank = {k: r for r, k in enumerate(sorted(paths, key=lambda k: paths[k]))}
    lines = []
    sitef_at = None
    for ln in src:
        m = CONST.match(ln)
        sm = SITEF.match(ln)
        if m and sm:
            if sitef_at is None:
                sitef_at = len(lines)
            continue
        if m:
            body = strip_roots(decode_llvm(m.group(2)))
            ln = re.sub(rb'\[\d+ x i8\]', b'[* x i8]', m.group(1)) + b' ' + repr(body).encode() + m.group(3)
        else:
            cm = SITE_CALL.match(ln)
            fm = SITE_FIRST_ARG_CALL.match(ln)
            if cm:
                ln = cm.group(1) + remap_site(int(cm.group(2)), rank) + b')' + cm.group(3)
            elif fm and bytes.fromhex(fm.group(2).decode()).endswith(SITE_FIRST_ARG_FNS):
                tagged = int(fm.group(3))
                ln = fm.group(1) + b'%d' % ((int(remap_site(tagged >> 1, rank)) << 1) | (tagged & 1)) + fm.group(4)
            ln = strip_roots(ln)
        lines.append(ln)
    if sitef_at is not None:
        table = [b'@.sitef.%d = %s' % (rank[k], repr(paths[k]).encode())
                 for k in sorted(paths, key=lambda k: rank[k])]
        lines[sitef_at:sitef_at] = table
    return b'\n'.join(lines)


PAREN_BYTE = re.compile(rb'^\s*\(call \$mdk_write_err_byte \(i32\.const (\d+)\)\)\s*$')
FILE_IF = re.compile(rb'^\s*\(if \(i32\.eq \(local\.get \$f\) \(i32\.const (\d+)\)\)\s*$')
SITE_CONST = re.compile(rb'^(\s*i64\.const )(\d+)\s*$')
SITE_CONSUMER = re.compile(rb'^\s*call \$mdk_(write_err_loc|trap_nonexh|int_[a-z]+)\s*$')


def collapse_err_bytes(src):
    # Runs of err-byte writes (flat `i32.const N / call` pairs or folded
    # `(call ... (i32.const N))` forms) become one `ERRBYTES <bytes>` line each, with
    # the tree roots stripped from the decoded bytes.
    lines = []
    run = []
    i = 0

    def flush():
        if run:
            lines.append(b'ERRBYTES ' + repr(strip_roots(bytes(run))).encode())
            del run[:]

    while i < len(src):
        m = BYTE_CONST.match(src[i])
        pm = PAREN_BYTE.match(src[i])
        if m and i + 1 < len(src) and BYTE_CALL.match(src[i + 1]):
            run.append(int(m.group(1)) & 0xFF)
            i += 2
        elif pm:
            run.append(int(pm.group(1)) & 0xFF)
            i += 1
        else:
            flush()
            lines.append(strip_roots(src[i]))
            i += 1
    flush()
    return lines


def norm_wat(data):
    # The site file table is the `$mdk_write_err_loc` chain of `(if (i32.eq $f K) ...)`
    # blocks, one per file, K = table index + 1 and the table sorted by full path. Blocks
    # are reordered by tree-relative path, K renumbered, and the packed site operand of
    # every located-trap call rewritten to the new numbering.
    lines = collapse_err_bytes(data.split(b'\n'))
    blocks = []
    first = None
    i = 0
    while i < len(lines):
        m = FILE_IF.match(lines[i])
        if (m and i + 3 < len(lines) and lines[i + 1].strip() == b'(then'
                and lines[i + 2].startswith(b'ERRBYTES ') and lines[i + 3].strip() == b'))'):
            blocks.append((int(m.group(1)), lines[i + 2], i))
            i += 4
        else:
            i += 1
    if not blocks:
        return b'\n'.join(lines)
    start = blocks[0][2]
    order = sorted(blocks, key=lambda blk: blk[1])
    rank = {blk[0]: r + 1 for r, blk in enumerate(order)}
    drop = set()
    for blk in blocks:
        drop.update(range(blk[2], blk[2] + 4))
    table = []
    for r, blk in enumerate(order):
        table += [b'(if (i32.eq (local.get $f) (i32.const %d))' % (r + 1), b'(then', blk[1], b'))']
    out_lines = []
    for j, ln in enumerate(lines):
        if j == start:
            out_lines += table
        if j in drop:
            continue
        sm = SITE_CONST.match(ln)
        if sm and j + 1 < len(lines) and SITE_CONSUMER.match(lines[j + 1]):
            site = int(sm.group(2))
            idx = site >> SITE_FILE_SHIFT
            if idx in rank:
                site = (rank[idx] << SITE_FILE_SHIFT) + (site & ((1 << SITE_FILE_SHIFT) - 1))
            ln = sm.group(1) + str(site).encode()
        out_lines.append(ln)
    return b'\n'.join(out_lines)


norm_body = norm_llvm if kind == 'll' else norm_wat


def rd(arm, n, ext):
    with open(os.path.join(out, '%s.%d.%s' % (arm, n, ext)), 'rb') as f:
        return f.read()


count = len([ln for ln in open(os.path.join(out, 'index')).read().split('\n') if ln.strip()])
raw = bad = 0
for n in range(1, count + 1):
    same_raw = (rd('a', n, 'code') == rd('b', n, 'code')
                and rd('a', n, kind) == rd('b', n, kind)
                and rd('a', n, 'err') == rd('b', n, 'err'))
    if same_raw:
        continue
    raw += 1
    forms = []
    for arm in ('a', 'b'):
        form = (b'EXIT ' + rd(arm, n, 'code') + b'\n== stderr\n' + strip_roots(rd(arm, n, 'err'))
                + b'\n== stdout\n' + norm_body(rd(arm, n, kind)))
        forms.append(form)
        with open(os.path.join(out, '%s.%d.norm' % (arm, n)), 'wb') as f:
            f.write(form)
    if forms[0] != forms[1]:
        bad += 1
        print('NORMALISED DIFFER', n)
print('norm: %d entries, %d raw differ, %d differ after tree-path normalisation' % (count, raw, bad))
sys.exit(0 if bad == 0 else 1)
