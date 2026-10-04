---
name: unity-worktree
description: Create Unity git worktrees that share disk blocks via copy-on-write, so a new worktree of a 34 GiB project costs ~0.35 GiB and ~25 s instead of ~34 GiB and a 10-minute reimport, Library included. Use when setting up parallel or agentic Unity development, when multiple checkouts are running out of disk, when asked to create a Unity worktree, or when a worktree needs its Library populated without a full reimport.
---

# unity-worktree (uwt)

Run many concurrent Unity worktrees without paying full disk for each one.

One **golden snapshot** of the project (working tree + `Library/`) is taken
while the editor is closed. Every new worktree is a block-clone of that
snapshot, which git then reconciles to the requested branch. Each worktree
owns a real, private, independent `Library/`; nothing is symlinked or shared by
reference. Only the disk blocks are shared, and they diverge on write. That is
the only model that preserves Unity's assumption of exclusive ownership while
making extra worktrees cheap.

Measured per worktree on four projects (Windows 11, ReFS, Unity 6000.7):

| project | plain checkout + its own Library | `uwt new` | after first open + 100 edits |
|---|---|---|---|
| asset-heavy, 41k files | 33.6 GiB · 135 s + 617 s import | 346 MiB · 24 s | 1.99 GiB · **17×** |
| monorepo subdir, 39k files | 16.1 GiB · 73 s + 416 s | 278 MiB · 25 s | 967 MiB · **17×** |
| URP sample, 3k files | 3.4 GiB · 6 s + 138 s | 118 MiB · 11 s | 421 MiB · **8×** |
| DOTS, code only | 1.1 GiB · 0.4 s + 71 s | 97 MiB · 10 s | 412 MiB · **2.7×** |

A hydrated worktree opens with 0–4 assets imported, against 3,990–23,788 cold.
The first open is where the private cost comes from, almost all of it Unity
rebuilding `Bee` and `BurstCache` and re-materialising package binaries; after
that, code, material, shader, prefab and scene edits grow a worktree slowly
(+17 to +77 MiB over a second open and 250 edits).

`DataStore`, the bulk of a Unity 6.6+ Library, stays shared through all of
that, but not through every reimport. It packs artifacts into a few large
`UDSData_<n>.bin` segments and garbage-collects by compaction: when a segment
holds superseded entries, the next editor open copies its live entries into a
new segment and deletes the old one. For a worktree that means a whole golden
segment turns private. On Linux/btrfs, 10 texture reimports left 81 KB dead in
a 476 MB segment, and the next open compacted it: **+455 MiB**. One reimport
did not trigger it. The 807 MB segment held out until most of it was dead.
A post-build golden does the same on first open. The copied entries sit at unaligned
offsets, so no clone or dedupe can share them again. The post-build case did
not reproduce on Windows/ReFS, where segments are 1 GiB; the reimport case is
untested there.

Budget the "after" column, not the `uwt new` one, plus about one segment for
each round of edits that reimports textures, models or other large-artifact
assets.

## Quick start

In a checkout whose `Library/` is imported and whose editor is **closed**:

```bash
uwt=.claude/skills/unity-worktree/scripts/unity-worktree.sh   # Git Bash on Windows
$uwt doctor                  # ALWAYS first: a live clone probe, not a capability flag
$uwt seed                    # snapshot project + Library into .git/uwt/golden
$uwt new feature/my-thing    # git worktree add + clone + hydrate
```

Hydrating a worktree created some other way (including Claude Code's own
`isolation: worktree`):

```bash
$uwt hydrate path/to/that/worktree
```

## Commands

| command | what it does |
|---|---|
| `doctor [PATH]` | Proves this volume block-clones by doing one and reading the refcount back. Checks the golden and cache root are on the project's volume, which open-file check the interlock will use, whether an editor is live, and the golden's state. Warns on Windows when long paths are off. |
| `seed [PATH] [--force]` | Snapshots the working tree and `Library/` (minus the deny list) plus the git index. Refuses while an editor or Data Store has the project open. Cheap; re-run after editor upgrades. |
| `new BRANCH [--path DIR] [--base REF] [--inherit-untracked] [--init-submodules] [--verify] [--json]` | `git worktree add --no-checkout`, clone the snapshot, hand git the snapshot's index, `reset --hard` to the branch, verify zero tracked differences, clean inherited untracked files, hydrate `Library/`. Refuses before registering anything if the volume cannot clone, or if it folds case and the branch has paths that collide by case. Rolls back on failure. |
| `hydrate [PATH] [--force]` | Gives an existing worktree a `Library/` cloned from the golden. |
| `list [PATH] [--json]` | Every worktree of the repo, including ones uwt did not create, with its branch, lock state, and whether its `Library/` came from uwt (`uwt`), from an editor (`other`), or is absent (`none`). |
| `remove PATH [--force] [--json]` | `git worktree remove` behind the editor interlock. A dirty worktree needs `--force`; a locked one needs `git worktree unlock` first; the branch is kept. Refuses the main worktree. |

Run `new` from inside the repo. `--path` is relative to your directory; the
default is `<repo>-<branch>` beside the repo. The golden lives at
`<repo>/.git/uwt/golden`; set `UWT_CACHE_ROOT` when worktrees live on a
different volume from the repo (the golden must be on the worktrees' volume).

Exit codes: `0` ok · `2` failure · `3` refused by the editor interlock.

For agents, `list`, `new` and `remove` take `--json`: the human output moves to
stderr and stdout carries exactly one record, either
`{"status":"ok","command":"new","value":{...}}` or
`{"status":"error","exit":2,"message":"..."}`. `new`'s value has `path`,
`project`, `branch`, `head`, `seconds`, `verified` and
`submodules_uninitialized`.

A project in a subdirectory of its repo (a monorepo) works: `seed` records
the offset and `new` clones the snapshot back to it. Tracked files outside the
project are written by git rather than cloned, so this pays off when they are
small. One golden per repo, so one Unity project per repo.

## Requirements

A filesystem that block-clones, with golden and worktrees on **one volume**:

- **Windows**: ReFS (Dev Drive) on Windows 11 24H2 or later. Runs under Git
  Bash and clones with robocopy. NTFS cannot clone.
- **macOS**: APFS. `new` re-reads every tracked byte once there, so on a
  large LFS project it takes about a minute (see Troubleshooting).
- **Linux**: btrfs, XFS with `reflink=1`, ZFS ≥ 2.2. ext4 cannot.

There is no copy fallback. On a volume that cannot clone, `doctor` says so and
every command refuses, because a byte copy of the project is the problem this
tool exists to avoid. A silent byte copy is also the single most likely way a
do-it-yourself version of this goes wrong: robocopy on NTFS or on a pre-24H2
build, `cp` without `--reflink`, or a cross-volume target all copy 24 GiB and
say nothing.

## Rules that matter

**Seed with the editor closed; uwt refuses otherwise.** Cloning a memory-mapped
LMDB mid-write captures a torn read. The interlock checks the pid in
`EditorInstance.json` and whether `ArtifactDB`, `SourceAssetDB`, `uds.db` and
`Temp/UnityLockfile` are open in another process. Only the second check is
unfoolable, so it never depends on an optional tool: Windows uses a rename
probe (Unity opens these files without `FILE_SHARE_DELETE`), Linux scans
`/proc` for open descriptors and memory maps, macOS uses `lsof`, which is
always present. `doctor` prints which one is in use. The Unity 6.6+ Data Store
runs out of process and can outlive the editor for a few seconds; wait and
retry. **uwt never closes the editor for you**: `unity close` exits without
saving.

**Worktrees are reset to their branch.** Uncommitted edits in the checkout you
seeded from do not carry over. That includes `ProjectSettings/ProjectVersion.txt`:
if the running editor is newer than the committed version, commit the bump
before seeding, or every worktree declares the old version and hydrate warns.

**Re-seed after an editor upgrade.** A Library from another editor version is
usable (Unity upgrades or reimports it, exactly as when a single checkout
switches branches) but the reimport lands as private disk. `hydrate` warns
when the golden's version differs from the worktree's.

**Never clone worktree-to-worktree, only from the golden.** ReFS caps a
region at 8175 references; chaining multiplies them. uwt only ever clones the
golden.

**Keep Windows worktree roots short** unless `LongPathsEnabled=1`:
`Library/PackageCache` paths approach 260 characters on their own. `doctor`
warns.

**Remove worktrees with `uwt remove PATH`**, which refuses while an editor
has the worktree open. Plain `git worktree remove` works too, with the editor
closed; the `Library/` inside is ignored, private data and does not make the
worktree count as dirty.

**Submodules are left uninitialised**, as `git worktree add` leaves them: the
snapshot's copies carry the source's `.git` link, which is either broken in a
new worktree or points at the source's own submodule repository, so `new`
empties them. `--init-submodules` runs `git submodule update --init
--recursive` in the worktree; those bytes are written by git, not cloned. A
Unity package vendored as a submodule is missing until then.

**Case collisions are refused on case-folding volumes** (APFS and ReFS by
default). Two paths that differ only by case, file or directory, would land
on one name and the tree could never verify, so `new` names them and refuses
before registering. `doctor` says which kind of volume you are on.

## What is cloned, and what is not

The Library is cloned **whole, minus a short deny list**. Copying a project
directory is something Unity supports; the deny list is the set of entries
whose worst failure is not "Unity rebuilds it" but "a build silently uses
another worktree's state". They are also all cheap to rebuild, so denying
them costs almost nothing. Measured: 335 of the 347 files in a Library that
contain absolute paths are in `Bee` and `BurstCache`, and both are regenerated
by the first build.

- **Denied**: `Bee`, `BurstCache`, `BuildCache` (build-system state keyed by
  absolute path), `ScriptAssemblies` (compiled output of *this* branch's
  scripts), `PackageManager` (regenerated from the lock file), `Search`,
  `TempArtifacts` (indexes derived from the artifact DB).
- **Never**: `EditorInstance.json`, `ProtocolInstance.json`, `Pipeline/`,
  `*.pid`, `*-lock`, `uds.lock`, `*.index-lock`. These identify or lock a
  running editor; they are stripped after every clone.
- **Everything else is cloned**: `PackageCache`, `DataStore`, `ArtifactDB`,
  `SourceAssetDB`, `ShaderCache`, the `Build*` settings, `PlayerDataCache`,
  per-user UI state. The `Build*` files are the best value per byte: they
  carry the active build target, so the worktree opens on the same platform
  without a platform-switch reimport.

From the working tree, `Temp`, `Logs`, `obj`, `UserSettings`, `Build*`,
`ProfilerCaptures`, IDE directories, and `*.csproj`/`*.sln` (regenerated per
checkout, full of absolute paths) are left out of the snapshot. Untracked files
that are in the snapshot are removed from a new worktree unless you pass
`--inherit-untracked`.

The deny list is measured, not argued. Grafting a whole `Bee` into a worktree and building a player there (Unity 6000.7.0b1,
ReFS): the build succeeded but took 33 s *longer* than without the graft, kept
the donor's player DAG and stripper response file, read the donor's link
configuration through them, and shipped an `Assembly-CSharp.dll` that names
the donor path. It saved about 64 MiB.
The same class of risk applies to any future `Library/` entry that keys
artifacts by absolute path.

## How `new` works, and why each step is there

1. `git worktree add --no-checkout` registers the worktree and writes no files.
2. The snapshot (minus `Library`) is cloned in, one directory-level clone.
3. The snapshot's git index is copied into the worktree's git dir. git decides
   "unchanged" from the stat data cached in the index, and the clone
   preserves mtimes, so every file that matches is skipped.
4. `git -c core.checkStat=minimal reset --hard`. git's default stat check
   includes inode and ctime, and a clone always has a new inode, so without
   this git rewrites every file and `new` is *slower* than plain git (measured
   on btrfs: 12.9 s versus 12.1 s; with it, 0.7 s). Only files that differ
   between the snapshot's commit and the target branch are written.
5. Zero tracked differences are required, or the worktree is rolled back.
   Verified same-commit and cross-branch at 84% churn. The check is a plain
   `git status`. On macOS and Linux a clone's new inode fails its stat check,
   so it re-hashes every tracked file once (LFS files through git-lfs) and
   writes fresh stat data back to the index. That makes it a content check,
   and it keeps later git commands fast. It costs time in proportion to the
   tracked bytes; Git for Windows reports no inodes, so Windows skips it.
   The status runs with `core.checkStat=default` whatever the repo is
   configured with, since `minimal` would let it pass on stat alone.
   `--verify` matters on Windows: it re-hashes every tracked file against a
   fresh index, the content check Windows otherwise lacks, reading every
   tracked byte once. On macOS and Linux the status has already done exactly
   that, so `--verify` says so and skips a second pass (about a minute on the
   23.5 GB LFS project).
6. `git clean -xdf`, then `Library/` is cloned from the golden.

## Cost model

Marginal disk is **~1 cluster (4 KiB) per file, independent of size**, so cost
tracks file count, not bytes, and the ratio improves with project size. Files
under 4 KiB share nothing (stored resident); files over 512 KiB share 99.9%
whatever they contain. From a file-size histogram alone this predicts a fresh
worktree to within one file on all four projects above, and files under 4 KiB
are 68–74% of the cost on every one of them. Content type decides how much
there is to save, not what a worktree costs.

## Measuring it yourself

Free-space deltas and `du` are **not** valid measurements on ReFS, btrfs or
APFS: free space updates lazily, and `du` counts shared blocks once per file.
Measure sharing directly:

- **Windows/ReFS**: `fsutil file queryExtentsAndRefCounts <file>`; an extent
  with `Ref` above 1 is shared. Sum private clusters over a tree for the
  worktree's true cost.
- **Linux/btrfs**: `sync`, then `btrfs filesystem du -s <dir>`. Before a
  `sync` its numbers are wrong.
- **Linux/XFS, macOS**: compare physical offsets (`filefrag -v`;
  `F_LOG2PHYS_EXT` on macOS).

To check a build for path leaks between worktrees, grep for path fragments,
not the bare project name: Unity bakes `productName` into `app.info` and
`globalgamemanagers`.

## Deliberately not supported

- **Sharing one `Library/` via junction or symlink.** Unity 6 moved
  `UnityLockfile` to `Temp/`, so two editors get no mutual exclusion, plus
  LMDB lock contention and reimport thrash.
- **Hardlinking the artifact DBs.** No copy-on-write; Unity mmap-writes LMDB
  and would corrupt every sibling worktree.
- **A local Unity Accelerator.** Costs ~2× Library size; the wrong shape for a
  disk problem.
- **`refsutil dedup`.** Post-hoc, so it needs the full duplicate set allocated
  first, and it contends with cloning for the same reference budget.
- **Copy, hardlink-farm and partial-clone fallbacks.**
  They let the tool run where it cannot deliver its value.

## Troubleshooting

- `seed` refuses but the editor is closed: `Unity.DataStore` can outlive the
  editor for a few seconds; on Windows check `tasklist | findstr DataStore`.
  If it is genuinely orphaned (no editor anywhere), ending it is safe: its
  state lives in `Library/DataStore/`.
- `doctor` says cloning does not work on a ReFS volume: Windows older than 11
  24H2, or the cache root is on another volume (set `UWT_CACHE_ROOT`).
  Also check the volume is actually ReFS (`df -T` under Git Bash, or
  `Get-Volume`).
- `doctor` says cloning does not work on Linux: ext4 cannot; XFS must have
  been created with `-m reflink=1` (`xfs_info <mount> | grep reflink`).
- ReFS error 347 / `0xC000048C` (too many clones): a region hit the 8175
  reference cap. Re-seed to reset the count.
- The disk fills up after a successful `new`: cloned blocks diverge lazily,
  when Unity writes. Budget as above.
- `new` reports tracked differences after reset and rolls back: the snapshot's
  index did not match its files (mtimes not preserved). Re-seed and retry.
- Every fresh worktree spends minutes importing: the golden is from another
  editor version (see `hydrate`'s warning), it was seeded before the project
  was fully imported, or the source had uncommitted `.meta` edits.
- An LFS file is still a pointer in a new worktree: it is a pointer in the
  source too. uwt clones the source's state; `git lfs pull` in either.
- A tracked directory uwt excludes (`.idea`, `Build`) costs its full size: git
  writes it, since it was not cloned.
- `new` is slow in "tracked tree matches" on macOS or Linux: that is step 5's
  `git status` re-hashing the tracked content, LFS included, because every
  cloned file has a new inode. It scales with tracked bytes (URP, 0.95 GB:
  8 s for the whole `new`). Measured on macOS: 65.5 s of a 78 s `new`
  for 23.5 GB of LFS content; the reset itself took 0.4 s. It is paid once per
  worktree. Skipping it would only move it to the first `git status` anyone
  runs there. `GIT_TRACE2_PERF=/tmp/t.txt` on the `new` shows it as the
  `refresh` region.
