# Tests

One suite for the one script.

```
bash tests/run-tests.sh                  # temp dir; clone groups SKIP where the FS cannot clone
bash tests/run-tests.sh E:/uwt-tests     # a ReFS / APFS / btrfs / XFS path runs everything
```

Without `ROOT` the fixtures go to the temp dir, which on Windows is `/tmp` =
`%TEMP%` on C:, usually NTFS, even when the checkout is on a Dev Drive. The
suite then prints `block-cloning: no` and doctor's reason; pass a path on the
ReFS volume to run the clone groups.

Exit 0 means every assertion passed; skips are named. Exit 1 means something
failed. Exit 2 means the suite could not run.

Synthetic fixtures: a fake git repo shaped like a Unity project with a fake
`Library/`, built in the root you give it. No Unity, no real project.

| group | covers |
|---|---|
| 1 | `doctor` resolves the project from a subdirectory and reports state |
| 2 | `seed` snapshots the tracked tree and `Library`, applies the deny list and the never-list, leaves the source alone, honours `--force`, rejects an empty `ArtifactDB` |
| 3 | the interlock refuses while a database is held open by another process (Linux and macOS) and while it is memory-mapped with the fd already closed, the way LMDB holds it (Linux; python3 builds the mapping); `doctor` names the open-file mechanism; a dead pid does not block. Windows needs a real editor, see below |
| 4 | `new` registers, clones, reconciles to the target branch (same-commit and cross-branch), cleans inherited untracked files, honours `--path`, `--base`, `--inherit-untracked`, checks out an existing branch, gives committed content for files the source hides behind `assume-unchanged`/`skip-worktree`, and refuses before registering when it cannot proceed |
| 5 | `hydrate` fills a plain worktree, refuses to overwrite without `--force`, warns on a Unity version mismatch |
| 6 | CLI errors exit 2 |
| 7 | a project in a subdirectory of its repo: `seed` records the prefix, `new` clones back to it and leaves files outside it to git, `hydrate` given the worktree root finds the project |
| 8 | `list` (text and `--json`) and where each `Library` came from; `remove` refuses the main worktree, a non-root path, a dirty worktree without `--force`, and a worktree whose `ArtifactDB` is open (exit 3), and keeps the branch; `new --json` success and error records; `new --verify` rolls back a snapshot whose content changed behind matching stat data (which plain `new` lets through on Windows), runs its fresh-index pass only on Windows, and a configured `core.checkStat=minimal` does not weaken the check |
| 9 | the case-collision detector (file and directory level) everywhere; through `new`, refusal on a case-folding volume (macOS CI) or success on a case-sensitive one |
| 10 | submodules: `new` leaves them empty rather than cloning the source's `.git` link, the worktree is clean, the source is untouched; `--init-submodules` gives the worktree its own submodule repository |
| 11 | `measure` covers every worktree and the golden, a new 1 MiB file adds exactly 1 MiB private with no `sync`, the answer repeats; on ZFS, which has no physical extents to read, it refuses with exit 2 |

CI also runs the suite on Linux on loopback btrfs, XFS (`reflink=1`) and ZFS
volumes, so every group runs on each filesystem `uwt` supports there.

On a volume that cannot block-clone (ubuntu and windows runners in CI) groups
2, 4 and 5 assert the refusal paths instead: exit 2, nothing published, nothing
registered, no stray branch. Groups 7, 9 (through `new`) and 10 are skipped
there.

## Not covered here

The Windows rename-probe interlock: a Git Bash file descriptor is opened with
`FILE_SHARE_DELETE`, so only a real Unity exercises it. Anything else that needs Unity (import counts, divergence, player builds,
block-sharing percentages) is out of scope for this suite.
