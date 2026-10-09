#!/usr/bin/env python3
"""Private disk per tree on Linux and macOS, by physical-block overlap.

usage: measure.py [--target NAME[;NAME...]] [--by N] [--json] [NAME=]DIR...

The same method and output as measure.ps1 on Windows. Every DIR takes part;
--target picks which are reported (default: all). A block is private to a tree
when no other tree maps it. Trees nested in another (the golden under .git) are
skipped when walking the outer one.

Physical offsets come from FIEMAP on Linux (btrfs, XFS) and F_LOG2PHYS_EXT on
macOS (APFS). ZFS clones blocks but has no FIEMAP (OpenZFS 2.4 answers
EOPNOTSUPP), so there this exits 1 rather than report every file unmapped.
Inline data (btrfs, small files) counts as one private block. On Linux each
file is flushed before it is mapped (FIEMAP_FLAG_SYNC), so delayed-allocation
data gets its physical block; on macOS every file written in the last 30
minutes is fsync'd first. Data still with no physical block is reported as
`unmapped`, counted neither way.

The macOS reader is the one measure-space-apfs.py used. The Linux reader is
verified on btrfs and XFS by tests/run-tests.sh group 11.

Called by `uwt measure`; usable on its own.
"""
import argparse, bisect, errno, fcntl, json, os, struct, sys, time

BLOCK = 4096
RECENT_SECS = 30 * 60      # files written this recently are flushed before mapping (macOS)


class Unsupported(Exception):
    """The filesystem cannot report physical extents at all."""

# ------------------------------------------------------------------ readers
if sys.platform == 'darwin':
    F_LOG2PHYS_EXT = 65
    L2P = '=Iqq'                 # struct log2phys, #pragma pack(4): flags, contigbytes, devoffset

    def extents(fd, size):
        """-> ([(lo, hi) device byte ranges], inline_blocks, unmapped_bytes)"""
        out, off = [], 0
        while off < size:
            try:
                _, n, dev = struct.unpack(L2P, fcntl.fcntl(fd, F_LOG2PHYS_EXT, struct.pack(L2P, 0, size - off, off)))
            except OSError:
                return out, 0, size - off
            if n <= 0:
                return out, 0, size - off
            out.append((dev - dev % BLOCK, dev + n + (-(dev + n) % BLOCK)))
            off += n
        return out, 0, 0
else:
    FS_IOC_FIEMAP = 0xC020660B
    FIEMAP_FLAG_SYNC = 0x1        # flush the file first, so delalloc data has a physical block
    FIEMAP_EXTENT_LAST, FIEMAP_EXTENT_UNKNOWN, FIEMAP_EXTENT_DELALLOC = 0x1, 0x2, 0x4
    FIEMAP_EXTENT_DATA_INLINE = 0x200
    HDR = '=QQIIII'               # fm_start, fm_length, fm_flags, fm_mapped_extents, fm_extent_count, fm_reserved
    EXT = '=QQQQQIIII'            # fe_logical, fe_physical, fe_length, 2x reserved64, fe_flags, 3x reserved
    BATCH = 256

    def extents(fd, size):
        out, inline, unmapped, start = [], 0, 0, 0
        while True:
            buf = bytearray(struct.pack(HDR, start, 2 ** 64 - 1 - start, FIEMAP_FLAG_SYNC, 0, BATCH, 0) + bytes(struct.calcsize(EXT) * BATCH))
            try:
                fcntl.ioctl(fd, FS_IOC_FIEMAP, buf, True)
            except OSError as e:
                if e.errno in (errno.EOPNOTSUPP, errno.ENOTTY):
                    raise Unsupported('FIEMAP')
                return out, inline, size
            mapped = struct.unpack_from(HDR, buf)[3]
            if mapped == 0:
                return out, inline, unmapped
            last = False
            for i in range(mapped):
                logical, phys, length, _, _, flags, _, _, _ = struct.unpack_from(EXT, buf, struct.calcsize(HDR) + i * struct.calcsize(EXT))
                if flags & FIEMAP_EXTENT_DATA_INLINE:
                    inline += 1
                elif flags & (FIEMAP_EXTENT_UNKNOWN | FIEMAP_EXTENT_DELALLOC):
                    unmapped += length
                else:
                    out.append((phys - phys % BLOCK, phys + length + (-(phys + length) % BLOCK)))
                start = logical + length
                last = last or bool(flags & FIEMAP_EXTENT_LAST)
            if last:
                return out, inline, unmapped


# ------------------------------------------------------------------ overlap
def merge(runs):
    runs.sort()
    out = []
    for lo, hi in runs:
        if out and lo <= out[-1][1]:
            if hi > out[-1][1]:
                out[-1][1] = hi
        else:
            out.append([lo, hi])
    return out


def uncovered(cover, starts, lo, hi):
    """Bytes of [lo, hi) not covered by the merged, sorted intervals."""
    n, i = 0, max(bisect.bisect_right(starts, lo) - 1, 0)
    while i < len(cover) and cover[i][0] < hi:
        a, b = max(lo, cover[i][0]), min(hi, cover[i][1])
        if b > a:
            n += b - a
        i += 1
    return (hi - lo) - n


def group_key(rel, by):
    parts = rel.split(os.sep)
    if len(parts) > by:
        return os.sep.join(parts[:by])
    return os.sep.join(parts[:-1]) or '.'


def walk(root, skip, by):
    t = {'files': 0, 'logical': 0, 'inline': 0, 'unreadable': 0, 'unmapped': 0, 'groups': {}, 'raw': [], 'rawgroup': []}
    for d, dirs, files in os.walk(root):
        dirs[:] = [x for x in dirs if os.path.join(d, x) not in skip and not os.path.islink(os.path.join(d, x))]
        for f in files:
            p = os.path.join(d, f)
            try:
                st = os.lstat(p)
            except OSError:
                continue
            if (st.st_mode & 0o170000) != 0o100000:
                continue
            key = group_key(os.path.relpath(p, root), by)
            g = t['groups'].setdefault(key, [0, 0, 0])
            t['files'] += 1; t['logical'] += st.st_size; g[0] += 1; g[1] += st.st_size
            try:
                fd = os.open(p, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0))
            except OSError:
                t['unreadable'] += 1
                continue
            try:
                # macOS: a cached write, even an overwrite of a clone, still maps to the
                # old blocks until flushed. Linux flushes through FIEMAP_FLAG_SYNC.
                if sys.platform == 'darwin' and time.time() - st.st_mtime < RECENT_SECS:
                    try:
                        os.fsync(fd)
                    except OSError:
                        pass
                ex, inl, um = extents(fd, st.st_size)
            finally:
                os.close(fd)
            t['inline'] += inl; t['unmapped'] += um; g[2] += inl * BLOCK
            t['raw'].extend(ex); t['rawgroup'].extend([key] * len(ex))
    return t


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('tree', nargs='+')
    ap.add_argument('--target', default='')
    ap.add_argument('--by', type=int, default=2)
    ap.add_argument('--json', action='store_true')
    a = ap.parse_args()

    names, roots = [], []
    for t in a.tree:
        n, sep, p = t.partition('=')
        if not sep or os.sep in n:
            n, p = None, t
        r = os.path.realpath(p)
        if not os.path.isdir(r):
            sys.exit(f'no such directory: {p}')
        roots.append(r); names.append(n or r)
    want = {w.rstrip('/') for w in a.target.split(';') if w}
    report = [not want or n in want or r in want for n, r in zip(names, roots)]

    t0 = time.time()
    trees = []
    for k, r in enumerate(roots):
        try:
            t = walk(r, set(roots) - {r}, a.by)
        except Unsupported as e:
            sys.exit(f'{r}: this filesystem does not report physical extents ({e}), so private disk '
                     'cannot be measured here (ZFS has none)')
        t['runs'] = merge(list(t['raw']))
        t['allocated'] = sum(hi - lo for lo, hi in t['runs']) + t['inline'] * BLOCK
        trees.append(t)
    for k, t in enumerate(trees):
        if not report[k]:
            continue
        cover = merge([tuple(x) for j, o in enumerate(trees) if j != k for x in o['runs']])
        starts = [lo for lo, _ in cover]
        t['private'] = t['inline'] * BLOCK + sum(uncovered(cover, starts, lo, hi) for lo, hi in t['runs'])
        for (lo, hi), key in zip(t['raw'], t['rawgroup']):
            t['groups'][key][2] += uncovered(cover, starts, lo, hi)

    secs = round(time.time() - t0, 1)
    out = {'method': 'physical-overlap', 'cluster_bytes': BLOCK, 'seconds': secs, 'trees': []}
    for k, t in enumerate(trees):
        row = {'name': names[k], 'path': roots[k], 'reported': report[k], 'files': t['files'], 'logical': t['logical'],
               'inline_files': t['inline'], 'unreadable': t['unreadable'], 'unmapped': t['unmapped'], 'allocated': t['allocated']}
        if report[k]:
            row['private'] = t['private']
            row['shared'] = t['allocated'] - t['private']
            # Every group, largest private first: JSON consumers sum them, so none are dropped.
            ordered = sorted(t['groups'].items(), key=lambda kv: -kv[1][2])
            row['groups'] = {g: {'files': v[0], 'logical': v[1], 'private': v[2]} for g, v in ordered}
        out['trees'].append(row)
    if a.json:
        print(json.dumps(out, separators=(',', ':')))
        return 0

    mib = 1048576.0
    print(f"{'tree':<12} {'files':>9} {'logical':>12} {'allocated':>12} {'private':>12} {'shared%':>8}")
    for t in out['trees']:
        if t['reported']:
            pct = 100.0 * t['shared'] / t['allocated'] if t['allocated'] else 0
            print(f"{t['name']:<12} {t['files']:>9,} {t['logical'] / mib:>8,.0f} MiB {t['allocated'] / mib:>8,.0f} MiB "
                  f"{t['private'] / mib:>8,.0f} MiB {pct:>7.1f}%")
    for t in out['trees']:
        top = [(g, v) for g, v in t.get('groups', {}).items() if v['private']][:10]
        if t['reported'] and top:
            print(f"\nlargest private in {t['name']}:")
            for g, v in top:
                print(f"  {v['private'] / mib:>10,.1f} MiB  {v['files']:>8,} files  {g}")
    um = sum(t['unmapped'] for t in out['trees'])
    if um:
        print(f"\nunmapped {um / mib:,.1f} MiB: not yet allocated; run sync and measure again")
    print(f"({len(trees)} trees, {secs} s, {BLOCK}-byte blocks; inline files count one block each)")
    return 0


if __name__ == '__main__':
    sys.exit(main())
