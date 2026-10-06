# unity-worktree-cow

A Claude Code skill (`uwt`) for running many concurrent Unity git worktrees
without paying full disk for each one.

One golden snapshot of the project (working tree + `Library/`) is taken while
the editor is closed. Every new worktree is a block-clone of that snapshot,
which git then reconciles to the requested branch. Each worktree owns a real,
private `Library/`; only the disk blocks are shared, and they diverge on write.

Measured per worktree on Windows 11, ReFS:

| project | plain checkout + its own Library | `uwt new` | after first open + work |
|---|---|---|---|
| asset-heavy, 41k files | 33.6 GiB · 135 s + 617 s import | 346 MiB · 24 s | 1.99 GiB · **17×** |
| monorepo subdir, 39k files | 16.1 GiB · 73 s + 416 s | 278 MiB · 25 s | 967 MiB · **17×** |
| URP sample, 3k files | 3.4 GiB · 6 s + 138 s | 118 MiB · 11 s | 421 MiB · **8×** |
| DOTS, code only | 1.1 GiB · 0.4 s + 71 s | 97 MiB · 10 s | 412 MiB · **2.7×** |
| production, 41.5k files, 25 GiB Library | ~31 GiB (estimated) | 405 MiB · 34–40 s | 2.50–2.64 GiB · **~12×** |

The first four are Unity 6000.7 after 100 scripted edits, measured by per-file
refcount; the fifth is Unity 6000.6 after four agent-driven editors compiled
and ran tests in parallel, measured by physical-cluster overlap.

A hydrated worktree opens without a reimport (0–6 assets imported, against
3,990–23,788 cold) but not without a compile: the first open rebuilds every
script assembly and resolves packages, about 400 s on the production project.
Its cost is about one 4 KiB cluster per file, so it is close
to fixed per project and the saving grows with project size. After the first
open it grows slowly, except that on Unity 6.6+ a texture or model reimport
can turn a whole `DataStore` segment private (~0.5 GiB); see `SKILL.md`.

## Use it

Copy `.claude/skills/unity-worktree/` into the target repo and commit it, so
the worktrees it creates carry it too. Then, in a
checkout whose `Library/` is imported and whose editor is **closed**:

```bash
uwt=.claude/skills/unity-worktree/scripts/unity-worktree.sh
$uwt doctor                  # proves this volume block-clones; run first
$uwt seed                    # snapshot project + Library into .git/uwt/golden
$uwt new feature/x           # git worktree add + clone + hydrate, ~seconds
$uwt hydrate path/to/wt      # give a worktree someone else created a Library
$uwt list --json             # every worktree, and where its Library came from
$uwt remove path/to/wt       # git worktree remove, refused while an editor has it open
$uwt measure                 # private disk of every worktree and the golden
```

`list`, `new`, `remove` and `measure` take `--json` for agents: one record on stdout,
human output on stderr. `new` is safe to run concurrently. `SKILL.md` has a
recipe for one editor per worktree.

One bash script, all platforms. On Windows it runs under Git Bash and uses
robocopy for the clone. Exit codes: `0` ok · `2` failure · `3` refused because
an editor is using the project.

## Requirements

A filesystem that block-clones, with the repo and the worktrees on the same
volume:

- **Windows** — ReFS (Dev Drive) on Windows 11 24H2 or later. NTFS cannot.
- **macOS** — APFS. Suite green; measured end to end on the 41k-file project: a fresh worktree is 0 MiB private, 1.45 GiB after a first open
  and 100 edits, against 33.8 GiB for a plain checkout plus cold import
  (23×). `new` takes 80 s there, 69 s of it the verify `git status`
  re-hashing 23.5 GB of LFS content once, because every clone has a new
  inode. Windows skips that; see `SKILL.md` Troubleshooting.
- **Linux** — btrfs, XFS with `reflink=1`, or ZFS ≥ 2.2 (where `measure`
  refuses: ZFS does not report physical extents). ext4 cannot.

On anything else `doctor` says so and the tool refuses. There is no copy
fallback: a byte copy of the project is the problem this exists to avoid.

Dependencies are bash, git and coreutils. Windows adds robocopy and fsutil,
both in-box. `measure` alone also needs PowerShell on Windows (in-box) or
`python3` elsewhere, because reading physical extents needs ioctls. The editor interlock needs nothing extra: a rename probe on
Windows, a `/proc` scan on Linux, `lsof` on macOS.

## Documentation

`.claude/skills/unity-worktree/SKILL.md` is the full reference: commands, what
is and is not cloned and why, the cost model, how to measure sharing, and
troubleshooting.

## Tests

```
bash tests/run-tests.sh [ROOT]
```

Synthetic fixtures, no Unity, seconds to run, on Windows (Git Bash), macOS and
Linux. Point `ROOT` at a volume that block-clones to run every group.
