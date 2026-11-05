#!/usr/bin/env bash
#
# uwt - cheap Unity git worktrees (or Plastic workspaces) via copy-on-write.
#
# One golden snapshot of a project (working tree + Library) is taken while the
# editor is closed. Every new worktree is a block-clone of that snapshot which
# git then reconciles to the requested branch. Nothing is shared by reference:
# each worktree owns its files; only the disk blocks are shared until written.
#
# Unity Version Control (Plastic) workspaces get the same treatment: a new
# workspace is the snapshot plus a copy of the source's plastic.wktree, which
# plays the part of git's index, and `cm` reconciles it.
#
# Platforms: Windows (Git Bash, ReFS / Dev Drive on 24H2+), macOS (APFS),
# Linux (btrfs, XFS reflink=1, ZFS 2.2+). Nothing else: on a filesystem that
# cannot block-clone this tool has no value, so it refuses instead of copying.
#
# Dependencies: bash, git, coreutils. Windows adds robocopy + fsutil (in-box).
# Plastic workspaces need `cm` on PATH.
#
# Exit codes: 0 ok | 2 failure | 3 refused by a safety interlock

set -uo pipefail

EXIT_OK=0; EXIT_FAIL=2; EXIT_REFUSED=3

case "$(uname -s)" in
  Darwin)               OS=darwin ;;
  Linux)                OS=linux ;;
  # Every MSYS2 environment names itself here: MINGW64_NT-10.0, UCRT64_NT-10.0
  # (Git for Windows' default since it moved to UCRT), CLANGARM64_NT-10.0, ...
  *_NT*)                OS=windows ;;
  *)                    OS=unknown ;;
esac

# Library entries that never travel between worktrees. Everything else in
# Library/ is cloned - the same thing that happens when a project directory is
# copied or moved, which Unity supports. The deny list is the set whose worst
# failure is not "Unity rebuilds it" but "a build silently uses another
# worktree's state": build-system caches keyed by absolute path, compiled
# output of THIS branch's scripts, and indexes derived from the artifact DB.
# They are also all cheap to rebuild, so denying them costs almost nothing.
# (Bee was measured directly: grafting it ships the donor's compiled output.)
LIBRARY_DENY="Bee BurstCache BuildCache ScriptAssemblies PackageManager Search TempArtifacts"

# Files that identify or lock a running editor. Copying them cross-wires two
# editors or trips LMDB's reader table. Stripped after every Library clone.
strip_never() { # strip_never <library-dir>
  [ -d "$1" ] || return 0
  find "$1" -type f \( -name '*-lock' -o -name '*.pid' -o -name 'uds.lock' -o -name '*.index-lock' \
      -o -name EditorInstance.json -o -name ProtocolInstance.json \) -delete 2>/dev/null
  rm -rf "$1/Pipeline"
}

# Top-level entries of the project that are never part of a snapshot: per-
# machine state, editor scratch, IDE files, and the .csproj/.sln Unity
# regenerates per checkout (they embed absolute paths).
TREE_EXCLUDE=".git .plastic Library Temp Logs obj UserSettings Build Builds ProfilerCaptures .vs .idea .vscode"
TREE_EXCLUDE_GLOBS="*.csproj *.sln *.user"

# ------------------------------------------------------------------ output
C0=''; CR=''; CG=''; CY=''; CC=''
if [ -t 1 ]; then C0=$'\033[0m'; CR=$'\033[31m'; CG=$'\033[32m'; CY=$'\033[33m'; CC=$'\033[36m'; fi
say()  { printf '%s\n' "$*"; }
head_(){ printf '%s%s%s\n' "$CC" "$*" "$C0"; }
good() { printf '  %s+%s %s\n' "$CG" "$C0" "$*"; }
warn() { printf '  %s!%s %s\n' "$CY" "$C0" "$*"; }
fail() { printf '  %sx%s %s\n' "$CR" "$C0" "$*"; }
die()  { fail "$*"; json_fail $EXIT_FAIL "$*"; exit $EXIT_FAIL; }
refuse(){ fail "$*"; json_fail $EXIT_REFUSED "$*"; exit $EXIT_REFUSED; }

# --json (list, new, remove): the human output above moves to stderr and fd 3
# carries exactly one JSON record, success or failure, for agent callers.
JSON=0
json_str() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
  printf '"%s"' "$s"
}
json_ok()   { [ "$JSON" = 1 ] && printf '{"status":"ok","command":"%s","value":%s}\n' "$1" "$2" >&3; return 0; }
json_fail() { [ "$JSON" = 1 ] && printf '{"status":"error","exit":%s,"message":%s}\n' "$1" "$(json_str "$2")" >&3; return 0; }
now()  { date +%s; }
stamp(){ date -u +%Y-%m-%dT%H:%M:%SZ; }

# ------------------------------------------------------------------ paths
wpath() { if [ "$OS" = windows ]; then cygpath -w "$1"; else printf '%s' "$1"; fi; }

# Absolute path against the CALLER's directory, for a path that may not exist
# yet (its parent must). Accepts C:\ style on Windows.
abs_path() {
  local p="$1"
  case "$OS:$p" in windows:[A-Za-z]:*) p="$(cygpath -u "$p")" ;; esac
  case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
  local d; d="$(cd "$(dirname "$p")" 2>/dev/null && pwd)" || { printf '%s' "$p"; return; }
  printf '%s/%s' "$d" "$(basename "$p")"
}

# ------------------------------------------------------------------ vcs
# A project is versioned by git or by Plastic (Unity Version Control). The
# nearest metadata directory above it decides: .git, or .plastic holding a
# plastic.workspace. Everything below that differs between the two goes
# through vcs_of; cloning, the Library and the interlock do not care.
vcs_of() { # vcs_of <dir> -> git | plastic; exit 1 if neither
  local d; d="$(cd "$1" 2>/dev/null && pwd)" || return 1
  while :; do
    [ -f "$d/.plastic/plastic.workspace" ] && { echo plastic; return 0; }
    [ -e "$d/.git" ] && { echo git; return 0; }
    [ "$d" = "$(dirname "$d")" ] && return 1
    d="$(dirname "$d")"
  done
}
# Root of the worktree or workspace containing <dir>.
wk_top() {
  case "$(vcs_of "$1")" in
    git)     git -C "$1" rev-parse --path-format=absolute --show-toplevel 2>/dev/null ;;
    plastic) local d; d="$(cd "$1" && pwd)"
             while [ ! -f "$d/.plastic/plastic.workspace" ]; do d="$(dirname "$d")"; done
             printf '%s' "$d" ;;
    *)       return 1 ;;
  esac
}

# cm takes Windows paths and spec arguments like br:/main/x, which Git Bash
# would otherwise rewrite into C:/Program Files/Git/main/x.
cm_() { if [ "$OS" = windows ]; then MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' cm "$@"; else cm "$@"; fi; }
# `cm status` of <workspace> as "CODE<tab>path" lines, path in this shell's
# form. CODE is cm's machine-readable status: CO checked out, AD added, DE
# deleted, MV moved, CH changed, LD/LM locally deleted/moved, HC hidden
# changed (as CH+HC), PR private, IG ignored. The remaining arguments are cm's
# search types (--controlledchanged, --private, ...).
pl_status() { # pl_status <workspace> <search-type...>
  local wk="$1"; shift
  cm_ status "$(wpath "$wk")" "$@" --machinereadable --fieldseparator='|' 2>/dev/null | tr -d '\r' \
    | awk -F'|' '$1 != "STATUS" && NF >= 4 {
        p = $0; sub(/^[^|]*\|/, "", p); sub(/\|[^|]*\|[^|]*$/, "", p)
        if (p ~ /^[A-Za-z]:\\/) { p = "/" tolower(substr(p, 1, 1)) substr(p, 3); gsub(/\\/, "/", p) }
        print $1 "\t" p }'
}
# Pending work that cannot be carried or discarded silently: checkouts (and
# the locks they may hold), adds, deletes, moves, merges in progress.
pl_pending() { pl_status "$1" --controlledchanged; }
# Local changes cm can put back: edited, deleted or moved without a checkout,
# including edits hidden by hidden_changes.conf.
pl_local()   { pl_status "$1" --changed --localdeleted --localmoved --hiddenchanged | grep -v '^PR'; }
pl_header()  { cm_ status "$(wpath "$1")" --header --machinereadable --fieldseparator='|' 2>/dev/null | tr -d '\r' | grep -m1 '^STATUS|'; }
pl_head()    { pl_header "$1" | cut -d'|' -f2; }                              # loaded changeset number
pl_repo()    { pl_header "$1" | awk -F'|' '{ print $3 "@" $4 }'; }             # repo@server
pl_branch()  { cm_ wi "$(wpath "$1")" 2>/dev/null | tr -d '\r' | sed -n 's/^Branch \(\/[^@]*\)@.*/\1/p' | head -1; }
pl_type()    { cm_ gwp "$(wpath "$1")" --format='{type} {dynamic}' --extended 2>/dev/null | tr -d '\r'; }
pl_exists()  { cm_ ls / --tree="$1" >/dev/null 2>&1; }                      # pl_exists <spec@repo>
# A repo spec names a repository but is not its identity: one server answers
# as `local` and as `localhost:8084`. The GUID is. Same spec is the fast path;
# a different repo name is a different repo; otherwise ask each server.
pl_repo_guid() { # pl_repo_guid <repo@server>
  cm_ repository list "${1#*@}" --format='{repname}|{repguid}' 2>/dev/null | tr -d '\r' \
    | awk -F'|' -v n="${1%%@*}" '$1 == n { print $2; exit }'
}
pl_same_repo() { # pl_same_repo <repo@server> <repo@server>
  [ "$1" = "$2" ] && return 0
  [ "${1%%@*}" = "${2%%@*}" ] || return 1
  local g; g="$(pl_repo_guid "$1")"; [ -n "$g" ] && [ "$g" = "$(pl_repo_guid "$2")" ]
}
# Every workspace on this machine of the repo <main> is on, main first.
pl_workspaces() { # pl_workspaces <main>
  local m="$1" repo p; repo="$(pl_repo "$m")"; printf '%s\n' "$m"
  cm_ workspace list --format='{path}' 2>/dev/null | tr -d '\r' | while IFS= read -r p; do
    [ "$OS" = windows ] && p="$(cygpath -u "$p")"
    [ -d "$p" ] || continue; p="$(cd "$p" && pwd)"
    [ "$p" != "$m" ] && pl_same_repo "$(pl_repo "$p")" "$repo" && printf '%s\n' "$p"
  done
}
# Where Plastic's EOL conversion is configured, if anywhere: the workspace
# root, the snapshot's, or the user's config dir (global config is cached
# there too). It rewrites text files on disk, so they no longer hash to the
# server's content.
pl_eol_conf() { # pl_eol_conf <workspace> [<golden>] -> path; exit 1 if none
  local f d
  for f in "$1/eolconversion.conf" ${2:+"$2/eolconversion.conf"}; do [ -f "$f" ] && { printf '%s' "$f"; return 0; }; done
  case "$OS" in windows) d="${LOCALAPPDATA:+$(cygpath -u "$LOCALAPPDATA")/plastic4}" ;; *) d="$HOME/.plastic4" ;; esac
  [ -n "$d" ] && [ -d "$d" ] || return 1
  f="$(find "$d" -maxdepth 3 -name eolconversion.conf -print -quit 2>/dev/null)"
  [ -n "$f" ] && printf '%s' "$f"
}
# Unsupported workspace kinds, as a reason; nothing printed means supported.
# A partial (Gluon) workspace loads a subset whose plastic.wktree describes a
# different file set from a full one; a dynamic one is a virtual filesystem.
pl_unsupported() {
  case "$(pl_type "$1")" in
    partial*)    echo "a partial (Gluon) workspace" ;;
    *dynamic*)   echo "a dynamic workspace" ;;
    "")          echo "not a workspace cm recognises (is cm on PATH and the server reachable?)" ;;
  esac
}

# The Unity project containing <path> (default: cwd): the path itself, the
# root of the worktree it is inside, or - for a project that lives in a
# subdirectory of its repo - that subdirectory as recorded by the golden.
# Callers capture its stdout, so its refusals go to stderr or they are lost.
project_root() {
  local p; p="$(cd "${1:-$PWD}" 2>/dev/null && pwd)" || die "no such directory: $1" >&2
  [ -f "$p/ProjectSettings/ProjectVersion.txt" ] && { printf '%s' "$p"; return; }
  local top; top="$(wk_top "$p")"
  [ -n "$top" ] && [ -f "$top/ProjectSettings/ProjectVersion.txt" ] && { printf '%s' "$top"; return; }
  if [ -n "$top" ]; then
    local pre; pre="$(golden_field "$(golden_dir "$top")" prefix)"
    [ -n "$pre" ] && [ -f "$top/$pre/ProjectSettings/ProjectVersion.txt" ] && { printf '%s/%s' "$top" "$pre"; return; }
  fi
  die "not a Unity project (no ProjectSettings/ProjectVersion.txt): $p" >&2
}
# Where the project sits inside its worktree: "" at the root, or e.g. "game"
# for a monorepo. The golden mirrors the project directory only, so every
# clone of it has to land at the same offset in the new worktree.
project_prefix() {
  case "$(vcs_of "$1")" in
    plastic) local p top; p="$(cd "$1" && pwd)"; top="$(wk_top "$p")"; [ "$p" = "$top" ] || printf '%s' "${p#"$top"/}" ;;
    *)       local s; s="$(git -C "$1" rev-parse --show-prefix 2>/dev/null)"; printf '%s' "${s%/}" ;;
  esac
}

# The main worktree is the one whose metadata directory holds the golden. For
# git that is the repo's common .git dir. Plastic workspaces are independent,
# so the one that was seeded is main: every workspace uwt creates records it
# in .plastic/uwt-main, and one made by hand finds it by looking for a golden
# among the repo's workspaces. With none anywhere, a workspace is its own main.
common_dir() {
  case "$(vcs_of "$1")" in
    plastic) local m; m="$(main_worktree "$1")" || return 1; printf '%s/.plastic' "$m" ;;
    *)       git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null ;;
  esac
}
main_worktree() {
  case "$(vcs_of "$1")" in
    plastic) local top m=""; top="$(wk_top "$1")" || return 1
             [ -f "$top/.plastic/uwt-main" ] && m="$(head -1 "$top/.plastic/uwt-main")"
             if [ -n "$m" ] && [ -f "$m/.plastic/plastic.workspace" ]; then printf '%s' "$m"; return; fi
             if [ ! -f "$top/.plastic/uwt/golden.txt" ] && [ -z "${UWT_CACHE_ROOT:-}" ]; then
               while IFS= read -r m; do
                 [ -f "$m/.plastic/uwt/golden.txt" ] && { printf '%s' "$m"; return; }
               done < <(pl_workspaces "$top")
             fi
             printf '%s' "$top" ;;
    git)     local c; c="$(common_dir "$1")" || return 1
             case "$(basename "$c")" in .git) dirname "$c" ;; *) printf '%s' "$c" ;; esac ;;
    *)       return 1 ;;
  esac
}
# The golden lives inside the main worktree's metadata dir by default (.git
# or .plastic): same volume as the main checkout, ignored by the VCS, gone
# when the checkout is. Override with UWT_CACHE_ROOT when worktrees live on a
# different volume.
cache_root()    { if [ -n "${UWT_CACHE_ROOT:-}" ]; then abs_path "$UWT_CACHE_ROOT"; else printf '%s/uwt' "$(common_dir "$1")"; fi; }
# <cache root>/golden is the snapshot itself; golden.txt and the VCS state
# (golden.index for git, golden.wktree + golden.selector for Plastic) sit
# beside it so the snapshot can be cloned whole. golden.txt is written last,
# so its presence means "published".
golden_dir()    { printf '%s/golden' "$(cache_root "$1")"; }
golden_side()   { case "$(golden_field "$1" vcs)" in plastic) echo "wktree selector" ;; *) echo index ;; esac; }
golden_ok()     { [ -f "$1.txt" ] && [ -d "$1/Library" ] || return 1
                  local s; for s in $(golden_side "$1"); do [ -f "$1.$s" ] || return 1; done; }

unity_version() {
  local f="$1/ProjectSettings/ProjectVersion.txt"
  [ -f "$f" ] || { printf 'unknown'; return; }
  { grep -m1 'm_EditorVersionWithRevision:' "$f" || grep -m1 'm_EditorVersion:' "$f"; } 2>/dev/null \
    | sed 's/^[^:]*:[[:space:]]*//' | tr -d '\r'
}
golden_field() { grep -m1 "^$2=" "$1.txt" 2>/dev/null | cut -d= -f2-; }

fs_type() {
  case "$OS" in
    windows) df -T "$1" 2>/dev/null | awk 'NR==2{print $2}' ;;   # Git Bash df knows refs/ntfs; fsutil needs admin
    darwin)  diskutil info "$(df -P "$1" | awk 'NR==2{print $1}')" 2>/dev/null \
               | awk -F: '/Type \(Bundle\)/{gsub(/ /,"",$2); print $2}' | head -1 ;;
    *)       findmnt -n -o FSTYPE --target "$1" 2>/dev/null | head -1 || stat -f -c %T "$1" 2>/dev/null ;;
  esac
}
same_volume() { [ "$(df -P "$1" | awk 'NR==2{print $1}')" = "$(df -P "$2" | awk 'NR==2{print $1}')" ]; }
file_count()  { find "$1" -type f 2>/dev/null | wc -l | tr -d ' '; }
# Length of the longest file path under <dir>, relative to it. Recorded at seed
# so `new` can tell, before it writes anything, whether a root breaks MAX_PATH.
longest_path() { (cd "$1" && find . -type f 2>/dev/null) | awk '{ l = length($0) - 2; if (l > m) m = l } END { print m + 0 }'; }
# Windows only: exit 0 iff LongPathsEnabled=1.
long_paths_on() {
  [ "$(MSYS_NO_PATHCONV=1 reg query 'HKLM\SYSTEM\CurrentControlSet\Control\FileSystem' /v LongPathsEnabled 2>/dev/null | grep -oE '0x[0-9]+$')" = 0x1 ]
}

# Does <dir>'s volume fold case? Asked of the volume, not the OS: APFS and
# NTFS/ReFS usually do, but both can be formatted or flagged case-sensitive.
case_insensitive() { # case_insensitive <dir>; exit 0 iff it folds case
  local p rc=1; p="$(mktemp -d "$1/.uwt-case-XXXXXX" 2>/dev/null)" || return 1
  : > "$p/uwtCase"; [ -e "$p/UWTCASE" ] && rc=0
  rm -rf "$p"; return $rc
}
# Paths in <ref>'s tree that land on one name on a case-folding volume, files
# and the directories above them alike (Assets/x and assets/y collide at the
# directory). git writes one over the other and the tree never verifies, so
# `new` refuses up front with the names instead. ASCII folding only. With "-"
# the paths come from stdin, one per line (how Plastic trees are checked).
case_collisions() { # case_collisions <repo> <ref> | case_collisions - -> "a <-> b" lines
  { if [ "$1" = - ]; then cat; else git -C "$1" -c core.quotePath=false ls-tree -r -z --name-only --full-tree "$2" 2>/dev/null | tr '\0' '\n'; fi; } \
    | awk '{ n = split($0, part, "/"); p = ""
             for (i = 1; i <= n; i++) {
               p = (i == 1) ? part[1] : p "/" part[i]; k = tolower(p)
               if (!(k in seen)) seen[k] = p
               else if (seen[k] != p && !(k in told)) { told[k] = 1; print seen[k] " <-> " p } } }'
}

# ------------------------------------------------------------------ copy-on-write
# Clone a directory tree. Every platform's native copy will block-clone when
# the filesystem allows it: robocopy (Windows 24H2+ on ReFS), cp -c (APFS),
# cp --reflink (btrfs/XFS/ZFS). Names after <dst> are top-level entries of
# <src> to leave out; --globs also leaves out TREE_EXCLUDE_GLOBS.
cow_tree() { # cow_tree <src> <dst> [--globs] [exclude-name...]
  local src="$1" dst="$2"; shift 2
  local globs=""; [ "${1:-}" = --globs ] && { globs="$TREE_EXCLUDE_GLOBS"; shift; }
  local e x skip
  if [ "$OS" = windows ]; then
    local xd=()
    for e in "$@"; do xd+=("$(wpath "$src/$e")"); done
    local log; log="$(mktemp)"
    # /E all subdirs (empty too), /COPY:DAT + /DCOPY:T keep timestamps - the
    # warm-index trick below needs file mtimes intact. /MT:8 still block-clones
    # (verified by refcount) and is ~3x faster on a 24k-file Library. /XJ never
    # follows junctions. MSYS_NO_PATHCONV stops Git Bash rewriting /E as a path.
    # shellcheck disable=SC2086
    MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' \
    robocopy "$(wpath "$src")" "$(wpath "$dst")" /E /COPY:DAT /DCOPY:T /MT:8 /XJ /R:0 /W:0 /NFL /NDL /NJH /NJS /NP \
      ${globs:+/XF $globs} ${xd[@]+/XD "${xd[@]}"} >"$log" 2>&1
    local rc=$?
    if [ $rc -ge 8 ]; then fail "robocopy failed (rc=$rc):"; tail -5 "$log" | sed 's/^/    /'; rm -f "$log"; return 1; fi
    rm -f "$log"; return 0
  fi
  mkdir -p "$dst" || return 1
  for e in "$src"/* "$src"/.[!.]*; do
    [ -e "$e" ] || continue
    local n; n="$(basename "$e")"; skip=0
    for x in "$@"; do [ "$n" = "$x" ] && skip=1; done
    # shellcheck disable=SC2254
    for x in $globs; do case "$n" in $x) skip=1 ;; esac; done
    [ $skip = 1 ] && continue
    case "$OS" in
      darwin) cp -Rpc "$e" "$dst/" ;;
      linux)  cp -a --reflink=always "$e" "$dst/" ;;
      *)      return 1 ;;
    esac || { fail "clone failed on $n"; return 1; }
  done
}

# Reads `fsutil file queryExtentsAndRefCounts` output; exit 0 iff an extent has
# Ref > 1. Parsed as a number: a pattern on the hex digits would also accept a
# zero-padded 0x01, which is an unshared extent.
refs_shared() {
  awk '{ for (i = 1; i < NF; i++) if ($i == "Ref:") {
           h = tolower($(i + 1)); sub(/^0x/, "", h); v = 0
           for (j = 1; j <= length(h); j++) v = v * 16 + index("0123456789abcdef", substr(h, j, 1)) - 1
           if (v > 1) shared = 1 } }
       END { exit !shared }'
}

# Prove that a clone into <dir> shares blocks, by doing one. A capability flag
# is not enough: robocopy on NTFS, or on ReFS before Windows 11 24H2, copies
# every byte and says nothing. Prints a reason; exit 0 iff cloning works.
cow_probe() { # cow_probe <dir>
  local d="$1" p
  p="$(mktemp -d "$d/.uwt-probe-XXXXXX" 2>/dev/null)" || { echo "cannot create files in $d"; return 1; }
  head -c 8388608 /dev/urandom > "$p/a.bin" 2>/dev/null   # 8 MiB, incompressible
  local rc=1 why
  case "$OS" in
    darwin)  if cp -c "$p/a.bin" "$p/b.bin" 2>/dev/null; then rc=0; why="APFS clonefile"; else why="cp -c rejected: not APFS"; fi ;;
    linux)   if cp --reflink=always "$p/a.bin" "$p/b.bin" 2>/dev/null; then rc=0; why="reflink ($(fs_type "$d"))"
             else why="reflink rejected by $(fs_type "$d") (ext4 cannot; XFS needs reflink=1)"; fi ;;
    windows) mkdir -p "$p/b"
             MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' robocopy "$(wpath "$p")" "$(wpath "$p/b")" a.bin /R:0 /W:0 >/dev/null 2>&1
             # A clone's extents carry Ref >= 2; a byte copy's carry Ref 1.
             if fsutil file queryExtentsAndRefCounts "$(wpath "$p/b/a.bin")" 2>/dev/null | refs_shared; then
               rc=0; why="ReFS block clone (fsutil refcount 2)"
             else why="robocopy copied bytes: $(fs_type "$d") volume, or Windows older than 11 24H2"; fi ;;
    *)       why="unsupported OS: uname -s says '$(uname -s)'" ;;
  esac
  rm -rf "$p"; echo "$why"; return $rc
}

# ------------------------------------------------------------------ interlock
# Is an editor (or the Unity 6.6+ Data Store, which can outlive it) using this
# project? Two layers: the pid the editor wrote down, and whether the files it
# memory-maps are still open. Only the second is unfoolable, so it is the one
# that matters; the first just gives a better message.
editor_live() { # editor_live <project> -> prints reasons; exit 0 iff live
  local proj="$1" lib="$1/Library" live=1 pid f
  if [ -f "$lib/EditorInstance.json" ]; then
    pid="$(grep -oE '"(process_id|pid)"[[:space:]]*:[[:space:]]*[0-9]+' "$lib/EditorInstance.json" | grep -oE '[0-9]+$' | head -1)"
    if [ -n "$pid" ]; then
      case "$OS" in
        windows) MSYS_NO_PATHCONV=1 tasklist /FI "PID eq $pid" /NH 2>/dev/null | grep -qi unity && { echo "    - EditorInstance.json names live Unity pid $pid"; live=0; } ;;
        *)       kill -0 "$pid" 2>/dev/null && ps -p "$pid" -o comm= 2>/dev/null | grep -qi unity && { echo "    - EditorInstance.json names live Unity pid $pid"; live=0; } ;;
      esac
    fi
  fi
  for f in Temp/UnityLockfile Library/ArtifactDB Library/SourceAssetDB Library/DataStore/uds.db; do
    [ -f "$proj/$f" ] || continue
    file_busy "$proj/$f" && { echo "    - $f is open in another process"; live=0; }
  done
  return $live
}

# Is <file> open or memory-mapped by any process? Exit 0 iff so.
#   windows  Unity opens these without FILE_SHARE_DELETE, so a rename fails
#            while they are open; rename back in the same breath.
#   linux    scan /proc directly: open fds, then memory maps (LMDB keeps the
#            mapping after it may have closed the fd). No lsof dependency,
#            which was the gap: lsof and fuser are not on every Ubuntu, and
#            without them this check used to pass silently.
#   darwin   lsof is always present.
file_busy() { # file_busy <file>
  local f="$1"
  case "$OS" in
    windows) ! { mv -- "$f" "$f.uwt-busy" 2>/dev/null && mv -- "$f.uwt-busy" "$f"; } ;;
    linux)   local real esc
             real="$(readlink -f -- "$f")" || real="$f"
             esc="$(printf '%s' "$real" | sed 's/[][*?\\]/\\&/g')"
             [ -n "$(find /proc/[0-9]*/fd -maxdepth 1 -lname "$esc" -print -quit 2>/dev/null)" ] && return 0
             # cat, not awk's own file list: mawk (Ubuntu's default awk) aborts
             # on the first unreadable maps file of another user's process.
             cat /proc/[0-9]*/maps 2>/dev/null \
               | awk -v f="$real" 'index($0, f) && substr($0, length($0)-length(f)+1) == f { found=1; exit } END { exit !found }' ;;
    *)       if command -v lsof >/dev/null 2>&1; then [ -n "$(lsof -t -- "$f" 2>/dev/null)" ]
             elif command -v fuser >/dev/null 2>&1; then fuser -s -- "$f" 2>/dev/null
             else return 1; fi ;;
  esac
}
# How file_busy decides here, for doctor.
interlock_mechanism() {
  case "$OS" in
    windows) echo "rename probe (FILE_SHARE_DELETE)" ;;
    linux)   echo "/proc fd and mmap scan" ;;
    *)       if command -v lsof >/dev/null 2>&1; then echo lsof
             elif command -v fuser >/dev/null 2>&1; then echo fuser
             else echo "NONE - install lsof; open-file checks are skipped"; fi ;;
  esac
}

require_editor_closed() { # require_editor_closed <project> <verb>
  local reasons
  if reasons="$(editor_live "$1")"; then
    fail "refusing to $2: a Unity Editor or Data Store is using $1"
    printf '%s\n' "$reasons"
    warn "Save and close the editor, then re-run. uwt never closes it for you."
    json_fail $EXIT_REFUSED "refusing to $2: a Unity Editor or Data Store is using $1"
    exit $EXIT_REFUSED
  fi
}

# ------------------------------------------------------------------ doctor
cmd_doctor() {
  local proj; proj="$(project_root "${1:-$PWD}")" || exit $EXIT_FAIL
  local bad=0 m cr gd
  say ""; head_ "uwt doctor"; say "project    $proj"
  m="$(main_worktree "$proj")" || { fail "not a git repository or Plastic workspace"; exit $EXIT_FAIL; }
  if [ "$(vcs_of "$proj")" = plastic ]; then
    command -v cm >/dev/null 2>&1 || { fail "a Plastic workspace, but cm is not on PATH"; exit $EXIT_FAIL; }
    good "plastic    cm $(cm_ version 2>/dev/null | tr -d '\r')  repo: $(pl_repo "$proj")  main workspace: $m"
    local un; un="$(pl_unsupported "$proj")"
    [ -z "$un" ] || { fail "this is $un; uwt supports full (regular, static) workspaces only"; bad=1; }
    local pend; pend="$(pl_pending "$proj" | wc -l | tr -d ' ')"
    [ "$pend" = 0 ] || warn "$pend pending change(s) (checkouts, adds, moves, deletes); seed refuses until they are checked in, shelved or undone"
  else
    good "git        $(git --version | sed 's/git version //')  main worktree: $m"
  fi
  good "unity      $(unity_version "$proj")"
  cr="$(cache_root "$proj")"; gd="$(golden_dir "$proj")"
  mkdir -p "$cr" 2>/dev/null || { fail "cannot create cache root $cr"; exit $EXIT_FAIL; }
  say ""; head_ "filesystem"
  say "  project     $(fs_type "$proj")"
  say "  cache root  $(fs_type "$cr")  $cr"
  if same_volume "$proj" "$cr"; then good "same volume (clones cannot cross volumes)"
  else fail "project and cache root are on different volumes - set UWT_CACHE_ROOT to a path on the worktrees' volume"; bad=1; fi
  local why
  if why="$(cow_probe "$cr")"; then good "block cloning works: $why"
  else fail "block cloning does NOT work here: $why"; say "    uwt has nothing to offer on this volume; see SKILL.md 'Requirements'."; bad=1; fi
  if case_insensitive "$cr"; then good "case-insensitive volume: new refuses a branch whose paths collide by case"
  else good "case-sensitive volume"; fi
  if [ "$OS" = windows ]; then
    if long_paths_on; then good "long paths enabled"
    else warn "LongPathsEnabled is not 1: Library/PackageCache paths approach 260 chars, so keep worktree roots short (E:\\wt\\name)"; fi
  fi
  say ""; head_ "editor"
  local mech; mech="$(interlock_mechanism)"
  case "$mech" in NONE*) warn "open-file check: $mech"; bad=1 ;; *) good "open-file check: $mech" ;; esac
  local reasons
  if reasons="$(editor_live "$proj")"; then warn "an editor or Data Store is using this project; seed would refuse:"; printf '%s\n' "$reasons"
  else good "no live editor"; fi
  say ""; head_ "golden"
  if golden_ok "$gd"; then
    say "  $gd"
    say "  unity=$(golden_field "$gd" unity_version)  commit=$(golden_field "$gd" commit | cut -c1-10)  created=$(golden_field "$gd" created)  files=$(golden_field "$gd" files)"
    [ "$(golden_field "$gd" unity_version)" = "$(unity_version "$proj")" ] || warn "golden was captured under a different editor version than this checkout declares; re-seed after upgrades"
  else say "  none yet - run: uwt seed   (with the editor closed)"; fi
  say ""; head_ "not offered, on purpose"
  say "  a shared Library via symlink/junction - Unity 6 keeps its lock in Temp/, so two editors get no mutual exclusion"
  say "  hardlinks for the artifact DBs         - no copy-on-write; Unity mmap-writes them and would corrupt every sibling"
  say "  copy fallback on non-cloning volumes    - a 24 GiB byte copy is the problem, not a solution"
  say ""
  [ $bad = 0 ] && { say "doctor: OK"; exit $EXIT_OK; }
  say "doctor: FAILED"; exit $EXIT_FAIL
}

# ------------------------------------------------------------------ seed
cmd_seed() {
  local proj; proj="$(project_root "${1:-$PWD}")" || exit $EXIT_FAIL
  local gd; gd="$(golden_dir "$proj")"; local cr; cr="$(dirname "$gd")"
  say ""; head_ "uwt seed"; say "project  $proj"; say "golden   $gd"
  [ -s "$proj/Library/ArtifactDB" ] || die "no imported Library/ here - open the project in Unity once, close it, then seed"
  local vcs; vcs="$(vcs_of "$proj")"
  if [ "$vcs" = plastic ]; then
    local un; un="$(pl_unsupported "$proj")"; [ -z "$un" ] || die "this is $un; uwt supports full (regular, static) workspaces only"
  fi
  require_editor_closed "$proj" seed
  good "no live editor"
  if golden_ok "$gd" && [ "${OPT_FORCE:-0}" != 1 ]; then
    warn "golden already exists (created $(golden_field "$gd" created)); pass --force to replace it"; exit $EXIT_OK
  fi
  mkdir -p "$cr" || die "cannot create $cr"
  same_volume "$proj" "$cr" || die "cache root $cr is on another volume than the project; set UWT_CACHE_ROOT"
  local why; why="$(cow_probe "$cr")" || die "this volume cannot block-clone ($why); run 'uwt doctor'"

  if [ "$vcs" = plastic ]; then
    # The snapshot's plastic.wktree would carry pending changes - and with a
    # checkout, possibly an exclusive lock - into every workspace made from
    # it, each claiming state that belongs to this one.
    local pend; pend="$(pl_pending "$proj")"
    [ -z "$pend" ] || { printf '%s\n' "$pend" | head -5 | sed 's/^/    /'
                        die "$(printf '%s\n' "$pend" | wc -l | tr -d ' ') pending change(s) here (checkouts, adds, moves, deletes or a merge); check them in, shelve or undo them, then seed"; }
    local dirty; dirty="$(pl_local "$proj" | wc -l | tr -d ' ')"
    [ "$dirty" = 0 ] || warn "$dirty local change(s) here (edited, deleted or moved without a checkout, hidden ones included); workspaces are reset to their branch, so these do not carry over"
  else
    local dirty; dirty="$(git -C "$proj" status --porcelain --untracked-files=no 2>/dev/null | wc -l | tr -d ' ')"
    [ "$dirty" = 0 ] || warn "$dirty uncommitted tracked change(s) here; worktrees are reset to their branch, so these do not carry over (ProjectVersion.txt bumps included)"
    local flagged; flagged="$(git -C "$proj" ls-files -v 2>/dev/null | grep -c '^[a-zS] ')"
    [ "$flagged" = 0 ] || warn "$flagged file(s) marked assume-unchanged or skip-worktree; worktrees get the committed version of them, not your local one"
  fi

  local stage="$cr/golden.new" t0; t0=$(now)
  rm -rf "$stage"
  say "snapshotting working tree..."
  # shellcheck disable=SC2086
  cow_tree "$proj" "$stage" --globs $TREE_EXCLUDE || { rm -rf "$stage"; die "snapshot failed; nothing published"; }
  say "snapshotting Library/ (minus: $LIBRARY_DENY)..."
  # shellcheck disable=SC2086
  cow_tree "$proj/Library" "$stage/Library" $LIBRARY_DENY || { rm -rf "$stage"; die "Library snapshot failed; nothing published"; }
  strip_never "$stage/Library"
  [ -s "$stage/Library/ArtifactDB" ] || { rm -rf "$stage"; die "snapshot has an empty ArtifactDB"; }
  if [ -d "$stage/Library/DataStore" ] && [ ! -s "$stage/Library/DataStore/uds.db" ]; then rm -rf "$stage"; die "snapshot has an empty DataStore/uds.db"; fi
  # git decides "unchanged" from the stat data cached in the index, and the
  # clone preserves mtimes - so carrying this index into a new worktree lets
  # `reset --hard` skip every file that already matches. plastic.wktree is the
  # same thing for cm (mtime and size, no rehash), and the selector says which
  # branch or changeset it describes. Neither names the workspace or its path;
  # plastic.workspace does, and never travels.
  local side s
  if [ "$vcs" = plastic ]; then
    local top; top="$(wk_top "$proj")"; side="wktree selector"
    for s in $side; do cp -p "$top/.plastic/plastic.$s" "$stage.$s" || { rm -rf "$stage" "$stage".*; die "could not copy plastic.$s"; }; done
  else
    side=index
    cp -p "$(git -C "$proj" rev-parse --path-format=absolute --git-path index)" "$stage.index" \
      || { rm -rf "$stage" "$stage.index"; die "could not copy the git index"; }
  fi
  {
    echo "vcs=$vcs"
    echo "unity_version=$(unity_version "$proj")"
    if [ "$vcs" = plastic ]; then
      echo "commit=$(pl_head "$proj")"
      echo "branch=$(pl_branch "$proj")"
      echo "repo=$(pl_repo "$proj")"
    else
      echo "commit=$(git -C "$proj" rev-parse HEAD 2>/dev/null)"
      echo "branch=$(git -C "$proj" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    fi
    echo "source=$proj"
    echo "prefix=$(project_prefix "$proj")"
    echo "created=$(stamp)"
    echo "files=$(file_count "$stage")"
    echo "longest_path=$(longest_path "$stage")"
  } > "$stage.txt"
  # Both kinds of side file go, whichever this golden had before.
  rm -rf "$gd" "$gd.txt" "$gd.index" "$gd.wktree" "$gd.selector" || { rm -rf "$stage" "$stage".*; die "could not remove the previous golden $gd"; }
  local ok=1; mv "$stage" "$gd" || ok=0
  for s in $side; do [ $ok = 1 ] && { mv "$stage.$s" "$gd.$s" || ok=0; }; done
  [ $ok = 1 ] && mv "$stage.txt" "$gd.txt" || ok=0
  [ $ok = 1 ] || { rm -rf "$stage" "$stage".* "$gd" "$gd".*; die "could not publish $gd"; }
  good "golden published in $(( $(now) - t0 ))s: $(golden_field "$gd" files) files, unity $(golden_field "$gd" unity_version), commit $(golden_field "$gd" commit | cut -c1-10)"
  say "  re-run 'uwt seed --force' after an editor upgrade or when the snapshot feels stale (it is cheap)."
  exit $EXIT_OK
}

# ------------------------------------------------------------------ hydrate
hydrate_library() { # hydrate_library <golden> <worktree>
  local gd="$1" wt="$2" t0; t0=$(now)
  cow_tree "$gd/Library" "$wt/Library" || { rm -rf "$wt/Library"; return 1; }
  strip_never "$wt/Library"
  local gv wv; gv="$(golden_field "$gd" unity_version)"; wv="$(unity_version "$wt")"
  [ "$gv" = "$wv" ] || warn "golden Library is from Unity '$gv', this worktree declares '$wv'; the editor will upgrade or reimport on first open (expect extra private disk). Re-seed under the new version to avoid it."
  { echo "golden_commit=$(golden_field "$gd" commit)"; echo "golden_created=$(golden_field "$gd" created)"
    echo "golden_unity=$gv"; echo "hydrated=$(stamp)"; } > "$wt/Library/.uwt-hydration.txt"
  good "Library hydrated in $(( $(now) - t0 ))s ($(file_count "$wt/Library") files)"
}

cmd_hydrate() {
  local wt; wt="$(project_root "${1:-$PWD}")" || exit $EXIT_FAIL
  local gd; gd="$(golden_dir "$wt")"
  say ""; head_ "uwt hydrate"; say "worktree $wt"
  golden_ok "$gd" || die "no golden for this repo - run 'uwt seed' in a checkout with an imported Library"
  local gpre wpre; gpre="$(golden_field "$gd" prefix)"; wpre="$(project_prefix "$wt")"
  [ "$gpre" = "$wpre" ] || die "the golden is of the project at '${gpre:-<repo root>}', not '${wpre:-<repo root>}'"
  require_editor_closed "$wt" hydrate
  if [ -d "$wt/Library" ]; then
    [ "${OPT_FORCE:-0}" = 1 ] || die "Library/ already exists; pass --force to replace it"
    rm -rf "$wt/Library" || die "could not remove the existing Library/"
  fi
  same_volume "$wt" "$gd" || die "worktree and golden are on different volumes; nothing would be shared"
  local why; why="$(cow_probe "$wt")" || die "this volume cannot block-clone ($why)"
  hydrate_library "$gd" "$wt" || die "hydrate failed; Library/ removed"
  exit $EXIT_OK
}

# ------------------------------------------------------------------ new
# --base for Plastic: cs:N, lb:NAME, br:/path, a bare changeset number or a
# bare branch path.
pl_spec() { case "$1" in cs:*|lb:*|br:*) printf '%s' "$1" ;; [0-9]*) printf 'cs:%s' "$1" ;; *) printf 'br:%s' "$1" ;; esac; }
pl_branch_create() { # pl_branch_create <branch> <repo> <base-spec>
  local from
  case "$3" in
    cs:*) from="--changeset=${3#cs:}" ;;
    br:*) local cs; cs="$(cm_ find changeset "where branch='${3#br:}'" on repository "'$2'" --format='{changesetid}' --nototal 2>/dev/null \
                           | tr -d '\r' | sort -n | tail -1)"
          [ -n "$cs" ] || return 1; from="--changeset=$cs" ;;
    *)    return 1 ;;
  esac
  cm_ branch create "br:$1@$2" "$from" -c="created by uwt" >/dev/null 2>&1
}
# git clean -xdf for a workspace: delete private and ignored items. Only paths
# inside <workspace> are touched, whatever cm prints.
pl_clean() { # pl_clean <workspace>
  local code p
  while IFS=$'\t' read -r code p; do
    case "$p" in "$1"/*) rm -rf -- "$p" ;; esac
  done < <(pl_status "$1" --private --ignored --cutignored)
}
# Content check for --verify: every controlled file's MD5 against the
# server's for <spec>. cm decides "unchanged" from mtime and size alone, on
# every OS, so a snapshot file changed behind matching stat data otherwise
# gets through. Prints the paths that differ or are missing.
pl_verify() { # pl_verify <workspace> <spec@repo>
  local list sum; list="$(mktemp)"
  case "$OS" in darwin) sum="md5 -r" ;; *) sum=md5sum ;; esac
  cm_ ls -R --tree="$2" --format='{type}|{hash}|{path}' 2>/dev/null | tr -d '\r' \
    | awk -F'|' '$1 != "dir" && $2 != "" { p = $0; sub(/^[^|]*\|[^|]*\|\/?/, "", p); print $2 "\t" p }' > "$list"
  # shellcheck disable=SC2086
  (cd "$1" && cut -f2- "$list" | tr '\n' '\0' | xargs -0 $sum 2>/dev/null) \
    | awk -v list="$list" '
        function b64hex(s,   a, i, c, v, n, b, out) {
          a = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"; v = 0; n = 0; out = ""
          for (i = 1; i <= length(s); i++) {
            c = substr(s, i, 1); if (c == "=") break
            v = v * 64 + index(a, c) - 1; n += 6
            if (n >= 8) { n -= 8; b = int(v / 2 ^ n); v -= b * 2 ^ n; out = out sprintf("%02x", b) }
          }
          return out
        }
        BEGIN { while ((getline l < list) > 0) { t = index(l, "\t"); want[substr(l, t + 1)] = b64hex(substr(l, 1, t - 1)) } }
        { h = $1; p = $0; sub(/^[0-9a-fA-F]+ [ *]?/, "", p); got[p] = tolower(h) }
        END { for (p in want) if (got[p] != want[p]) print p }'
  rm -f "$list"
}

# `new` for a Plastic workspace. Called from cmd_new once the checks both
# kinds share have passed, and sees its locals: branch (a full path by now),
# proj, m, gd, path. Exits.
new_plastic() {
  local top repo name; top="$(wk_top "$proj")"
  repo="$(golden_field "$gd" repo)"; [ -n "$repo" ] || repo="$(pl_repo "$top")"
  [ -n "$repo" ] || die "cm cannot read this workspace's repository (is the server reachable?)"
  name="$(basename "$path")"
  cm_ workspace list --format='{wkname}' 2>/dev/null | tr -d '\r' | grep -qxF -- "$name" \
    && die "a workspace named '$name' already exists on this machine; choose another --path"
  local eol
  if [ "${OPT_VERIFY:-0}" = 1 ] && eol="$(pl_eol_conf "$top" "$gd")"; then
    die "--verify cannot check this workspace: $(wpath "$eol") converts line endings on disk, so text files do not hash to the server's content; run without --verify"
  fi

  # Everything that can refuse does so BEFORE cm creates anything.
  local exists=0 base="" target
  if pl_exists "br:$branch@$repo"; then exists=1; target="br:$branch"
  else
    base="$(pl_spec "${OPT_BASE:-cs:$(pl_head "$top")}")"
    # cm takes no label as a tree spec, so a label is its changeset from here.
    case "$base" in
      lb:*) local lcs; lcs="$(cm_ find label "where name='${base#lb:}'" on repository "'$repo'" --format='{changeset}' --nototal 2>/dev/null | tr -d '\r' | head -1)"
            [ -n "$lcs" ] || die "no label ${base#lb:} in $repo"
            say "base     $base = cs:$lcs"; base="cs:$lcs" ;;
    esac
    pl_exists "$base@$repo" || die "not a changeset, label or branch in $repo: $base"
    [ "$(dirname "$branch")" = / ] || pl_exists "br:$(dirname "$branch")@$repo" \
      || die "parent branch $(dirname "$branch") does not exist in $repo"
    target="$base"
  fi
  if case_insensitive "$(dirname "$path")"; then
    local coll; coll="$(cm_ ls -R --tree="$target@$repo" --format='{path}' 2>/dev/null | tr -d '\r' | sed 's#^/##' | grep -v '^$' | case_collisions -)"
    if [ -n "$coll" ]; then
      printf '%s\n' "$coll" | head -5 | sed 's/^/    /'
      die "$(printf '%s\n' "$coll" | wc -l | tr -d ' ') path(s) in $target collide by case, and this volume folds case; rename them on a case-sensitive workspace first"
    fi
  fi

  local t0; t0=$(now); local created_branch=0
  cm_ workspace create "$name" "$(wpath "$path")" "$repo" >/dev/null 2>&1 || die "cm workspace create failed"
  rollback() {
    fail "$1"; warn "rolling back: a registered workspace with wrong contents is worse than none"
    cm_ workspace delete "$(wpath "$path")" >/dev/null 2>&1; rm -rf "$path"
    [ $created_branch = 1 ] && cm_ branch delete "br:$branch@$repo" >/dev/null 2>&1
    json_fail $EXIT_FAIL "$1 (rolled back)"
    exit $EXIT_FAIL
  }
  good "registered workspace $name"

  local pre; pre="$(golden_field "$gd" prefix)"
  local pdir="$path${pre:+/$pre}"
  [ -n "$pre" ] && say "project  $pre/ (files outside it are written by cm, not cloned)"
  mkdir -p "$pdir" || rollback "could not create $pdir"
  cow_tree "$gd" "$pdir" Library || rollback "clone of the snapshot failed"
  # The snapshot's tree state, under this workspace's own identity: the new
  # plastic.workspace (name, GUID) that cm just wrote stays.
  local s; for s in wktree selector; do cp -p "$gd.$s" "$path/.plastic/plastic.$s" || rollback "could not place plastic.$s"; done
  printf '%s\n' "$m" > "$path/.plastic/uwt-main" || rollback "could not record the main workspace"
  # Reconcile to the snapshot's changeset. undo puts back what was edited,
  # deleted or moved without a checkout, and downloads what the clone lacks
  # (files outside the project directory). It ignores edits hidden by
  # hidden_changes.conf, so those are deleted first: a deleted file it does
  # restore.
  local code p
  while IFS=$'\t' read -r code p; do
    case "$code:$p" in *HC*:"$path"/*) rm -f -- "$p" ;; esac
  done < <(pl_status "$path" --hiddenchanged)
  cm_ undo -r "$(wpath "$path")" --silent >/dev/null 2>&1 || rollback "cm undo failed"
  # A branch is created on the server, where the team sees it, so only once
  # the workspace is known good.
  if [ $exists = 0 ]; then
    pl_branch_create "$branch" "$repo" "$base" || rollback "could not create branch $branch from $base"
    created_branch=1; target="br:$branch"
    good "created branch $branch from $base"
  fi
  cm_ switch "$target" --workspace="$(wpath "$path")" --noinput --silent >/dev/null 2>&1 || rollback "cm switch $target failed"
  local differ; differ="$(pl_pending "$path"; pl_local "$path")"
  [ -z "$differ" ] || { printf '%s\n' "$differ" | head -5 | sed 's/^/    /'
                        rollback "$(printf '%s\n' "$differ" | wc -l | tr -d ' ') item(s) still differ from $branch after the switch"; }
  local head; head="$(pl_head "$path")"
  good "workspace matches $branch (cs:$head) in $(( $(now) - t0 ))s"
  if [ "${OPT_VERIFY:-0}" = 1 ]; then
    local vt bad; vt=$(now); bad="$(pl_verify "$path" "cs:$head@$repo")"
    [ -z "$bad" ] || { printf '%s\n' "$bad" | head -5 | sed 's/^/    /'
                       rollback "$(printf '%s\n' "$bad" | wc -l | tr -d ' ') file(s) differ by content from cs:$head though their stat data matched; re-seed"; }
    good "content verified against the server's hashes in $(( $(now) - vt ))s"
  fi
  # The clone is directory-level, so the snapshot's private files came too,
  # and a switch renames a private file in its way to <name>.private.N.
  if [ "${OPT_INHERIT_UNTRACKED:-0}" = 1 ]; then warn "keeping private files inherited from the snapshot (--inherit-untracked)"
  else pl_clean "$path"; fi

  hydrate_library "$gd" "$pdir" || rollback "Library clone failed"
  local secs=$(( $(now) - t0 ))
  local self; self="$(abs_path "${BASH_SOURCE[0]}")"
  say ""; good "workspace ready in ${secs}s: $path"
  say "  remove it later with: $(wpath "$self") remove $(wpath "$path")"
  case "$self" in
    "$m"/*) [ -n "$(cm_ ls "$(wpath "$self")" --format='{hash}' 2>/dev/null | tr -d '\r[:space:]')" ] \
              || warn "the uwt skill is not checked in, so the new workspace has no copy of it; check in .claude/skills/unity-worktree-cow/" ;;
  esac
  local jpath="$path" jproj="$pdir"   # in git's form: E:/x on Windows
  [ "$OS" = windows ] && { self="$(cygpath -m "$self")"; jpath="$(cygpath -m "$path")"; jproj="$(cygpath -m "$pdir")"; }
  json_ok new "{\"path\":$(json_str "$jpath"),\"uwt\":$(json_str "$self"),\"project\":$(json_str "$jproj"),\"branch\":$(json_str "$branch"),\"head\":$(json_str "cs:$head"),\"seconds\":$secs,\"verified\":$([ "${OPT_VERIFY:-0}" = 1 ] && echo true || echo false),\"submodules_uninitialized\":0}"
  exit $EXIT_OK
}

cmd_new() {
  local branch="${1:-}"; [ -n "$branch" ] || die "usage: uwt new <branch> [--path DIR] [--base REF] [--inherit-untracked] [--init-submodules] [--verify] [--json]"
  local proj; proj="$(project_root "$PWD")" || exit $EXIT_FAIL
  local m; m="$(main_worktree "$proj")" || die "not a git repository or Plastic workspace"
  local vcs; vcs="$(vcs_of "$proj")"
  local gd; gd="$(golden_dir "$proj")"
  if [ "$vcs" = plastic ]; then
    [ "${OPT_INIT_SUBMODULES:-0}" = 1 ] && die "--init-submodules is for git submodules; Plastic Xlinks are loaded by cm itself"
    # A Plastic branch is a path. A bare name is a child of the branch this
    # workspace is on, as the Plastic GUI does it, not a top-level branch,
    # which would start from changeset 0.
    case "$branch" in
      /*) ;;
      *)  local parent; parent="$(pl_branch "$(wk_top "$proj")")"
          [ -n "$parent" ] || die "this workspace is not on a branch; give the full branch path, e.g. /main/$branch"
          branch="$parent/$branch" ;;
    esac
  fi
  local path="${OPT_PATH:-$(dirname "$m")/$(basename "$m")-$(printf '%s' "${branch#/}" | tr -c 'A-Za-z0-9._-' '-')}"
  mkdir -p "$(dirname "$path")" 2>/dev/null; path="$(abs_path "$path")"
  say ""; head_ "uwt new"; say "repo     $m"; say "branch   $branch"; say "path     $path"
  golden_ok "$gd" || die "no golden yet - run 'uwt seed' first (editor closed)"
  [ -e "$path" ] && die "path already exists: $path"

  # MAX_PATH: the golden knows its longest relative path, so this is exact for
  # the snapshot. Warn rather than refuse: robocopy copes, git and Unity may not.
  local lp; lp="$(golden_field "$gd" longest_path)"
  if [ "$OS" = windows ] && [ -n "$lp" ] && ! long_paths_on; then
    local pdir0; pdir0="$(wpath "$path")"; local pre0; pre0="$(golden_field "$gd" prefix)"
    [ -n "$pre0" ] && pdir0="$pdir0/$pre0"
    local need=$(( ${#pdir0} + 1 + lp ))
    [ "$need" -lt 260 ] || warn "LongPathsEnabled is off and the deepest file here would be $need characters (limit 259); choose a short --path such as E:\wt\name, or enable long paths"
  fi

  # Everything that can refuse does so BEFORE git registers anything.
  same_volume "$gd" "$(dirname "$path")" || die "the golden ($gd) and the new worktree must be on one volume; set UWT_CACHE_ROOT or choose another --path"
  local why; why="$(cow_probe "$(dirname "$path")")" \
    || die "this volume cannot block-clone ($why); use plain $([ "$vcs" = plastic ] && echo "'cm workspace create'" || echo "'git worktree add'")"
  [ "$vcs" = plastic ] && new_plastic
  local ref="${OPT_BASE:-HEAD}" exists=0
  git -C "$m" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null && { ref="refs/heads/$branch"; exists=1; }
  git -C "$m" rev-parse --verify --quiet "$ref^{commit}" >/dev/null || die "not a commit: $ref"
  if case_insensitive "$(dirname "$path")"; then
    local coll; coll="$(case_collisions "$m" "$ref")"
    if [ -n "$coll" ]; then
      printf '%s\n' "$coll" | head -5 | sed 's/^/    /'
      die "$(printf '%s\n' "$coll" | wc -l | tr -d ' ') path(s) in $ref collide by case, and this volume folds case; rename them on a case-sensitive checkout first"
    fi
  fi

  local t0; t0=$(now) created_branch=0
  if [ $exists = 1 ]; then
    git -C "$m" worktree add -q --no-checkout "$path" "$branch" || die "git worktree add failed"
  else
    git -C "$m" worktree add -q --no-checkout -b "$branch" "$path" "${OPT_BASE:-HEAD}" || die "git worktree add failed"
    created_branch=1
  fi
  rollback() {
    fail "$1"; warn "rolling back: a registered worktree with wrong contents is worse than none"
    rm -rf "$path"; git -C "$m" worktree prune >/dev/null 2>&1
    [ $created_branch = 1 ] && git -C "$m" branch -D "$branch" >/dev/null 2>&1
    json_fail $EXIT_FAIL "$1 (rolled back)"
    exit $EXIT_FAIL
  }
  good "registered worktree (no checkout)"

  # A project in a subdirectory of its repo: the snapshot is that directory,
  # so it goes back at the same offset. Tracked files outside it are few and
  # small in practice, and git writes them in the reset below.
  local pre; pre="$(golden_field "$gd" prefix)"
  local pdir="$path${pre:+/$pre}"
  [ -n "$pre" ] && say "project  $pre/ (files outside it are written by git, not cloned)"
  mkdir -p "$pdir" || rollback "could not create $pdir"
  cow_tree "$gd" "$pdir" Library || rollback "clone of the snapshot failed"
  cp -p "$gd.index" "$(git -C "$path" rev-parse --path-format=absolute --git-path index)" || rollback "could not place the index"
  # The donor's index carries its assume-unchanged and skip-worktree bits, and
  # reset and status both skip flagged paths, so the donor's local edits to
  # them would survive and pass the check below. Clear them so every path is
  # reset and verified; a sparse checkout re-applies its own on reset.
  local flagged; flagged="$(git -C "$path" ls-files -v | grep -c '^[a-zS] ')"
  if [ "$flagged" != 0 ]; then
    local bit   # update-index applies one mark per invocation, so one pass per bit
    for bit in --no-assume-unchanged --no-skip-worktree; do
      git -C "$path" ls-files -v -z | while IFS= read -r -d '' e; do
        case "$e" in [a-zS]\ *) printf '%s\0' "${e#? }" ;; esac
      done | git -C "$path" update-index -z "$bit" --stdin \
        || rollback "could not clear assume-unchanged/skip-worktree bits"
    done
    say "cleared assume-unchanged/skip-worktree on $flagged file(s) from the snapshot's index"
  fi
  # Submodule directories came over with the snapshot, and so did their .git
  # files: a relative gitdir that is broken here, or an absolute one that is
  # the SOURCE's module repo, which would give two checkouts one submodule
  # index. Empty them, which is what `git worktree add` leaves; --init-submodules
  # below checks them out properly.
  local e p
  while IFS= read -r -d '' e; do
    case "$e" in 160000\ *) p="${e#*$'\t'}"
      case "/$p/" in */../*|//) rollback "refusing a submodule path: $p" ;; esac
      rm -rf "${path:?}/$p" && mkdir -p "$path/$p" || rollback "could not empty submodule $p" ;;
    esac
  done < <(git -C "$path" ls-files -s -z)
  # core.checkStat=minimal: git's default stat check includes inode and ctime,
  # and a clone always has a new inode, so without this every file looks dirty
  # and git rewrites the whole tree (measured: slower than plain checkout).
  # mtime+size is what the donor's own `git status` relied on anyway.
  git -C "$path" -c core.checkStat=minimal reset --hard -q || rollback "git reset --hard failed"
  # checkStat pinned to default: a user's core.checkStat=minimal would stop
  # this status comparing inodes, and with it the content check described
  # below that --verify relies on outside Windows.
  local differ; differ="$(git -C "$path" -c core.checkStat=default status --porcelain --untracked-files=no | wc -l | tr -d ' ')"
  [ "$differ" = 0 ] || { git -C "$path" status --porcelain --untracked-files=no | head -5 | sed 's/^/    /'; rollback "$differ tracked file(s) still differ from $branch after reset"; }
  good "tracked tree matches $branch ($(git -C "$path" ls-files | wc -l | tr -d ' ') files) in $(( $(now) - t0 ))s"
  # reset skipped every file whose mtime and size matched the snapshot's
  # index. On macOS and Linux the status above then re-hashes every clone,
  # because its inode differs from the index's: a full content check, paid in
  # tracked bytes (65 s for 23.5 GB of LFS on macOS). Git for Windows reports
  # inode 0 and robocopy keeps timestamps, so there status passes on stat
  # alone, and a snapshot file changed without moving mtime or size (a tool
  # that restores mtimes, a coarse-timestamp race in the source) gets through.
  # --verify re-hashes every tracked file against an index with no stat data:
  # the content check Windows otherwise lacks. Elsewhere it would be a second
  # full pass that cannot find anything the status missed, so it is skipped.
  if [ "${OPT_VERIFY:-0}" = 1 ] && [ "$OS" != windows ]; then
    good "content verified: the status above re-hashed every cloned file (new inodes), so --verify has nothing to add here"
  elif [ "${OPT_VERIFY:-0}" = 1 ]; then
    local vt vi bad; vt=$(now); vi="$(git -C "$path" rev-parse --path-format=absolute --git-path index).uwt-verify"
    rm -f "$vi"
    GIT_INDEX_FILE="$vi" git -C "$path" read-tree HEAD || { rm -f "$vi"; rollback "could not build a fresh index to verify against"; }
    GIT_INDEX_FILE="$vi" git -C "$path" update-index -q --refresh >/dev/null
    bad="$(GIT_INDEX_FILE="$vi" git -C "$path" diff-files --name-only)"; rm -f "$vi"
    [ -z "$bad" ] || { printf '%s\n' "$bad" | head -5 | sed 's/^/    /'
                       rollback "$(printf '%s\n' "$bad" | wc -l | tr -d ' ') tracked file(s) differ by content from $branch though their stat data matched; re-seed"; }
    good "content verified against a fresh index in $(( $(now) - vt ))s"
  fi
  # The clone is directory-level, so the snapshot's untracked files came too.
  if [ "${OPT_INHERIT_UNTRACKED:-0}" = 1 ]; then warn "keeping untracked files inherited from the snapshot (--inherit-untracked)"
  else git -C "$path" clean -xdfq 2>/dev/null; fi
  local subs; subs="$(git -C "$path" ls-files -s | grep -c '^160000 ')"
  if [ "$subs" != 0 ]; then
    if [ "${OPT_INIT_SUBMODULES:-0}" = 1 ]; then
      git -C "$path" submodule update --init --recursive -q || rollback "git submodule update --init failed"
      good "initialised $subs submodule(s) (written by git, not cloned)"; subs=0
    else
      warn "$subs submodule(s) left uninitialised; pass --init-submodules, or run: git -C $(wpath "$path") submodule update --init --recursive"
    fi
  fi

  hydrate_library "$gd" "$pdir" || rollback "Library clone failed"
  local secs=$(( $(now) - t0 )) reg; reg="$(git -C "$path" rev-parse --path-format=absolute --show-toplevel)"
  # Agents inside the worktree need a way back to uwt, if only to remove
  # themselves. A skill this repo has not committed was cleaned out above.
  local self sd; self="$(abs_path "${BASH_SOURCE[0]}")"; sd="$(dirname "$self")"
  say ""; good "worktree ready in ${secs}s: $path"
  say "  remove it later with: $(wpath "$self") remove $(wpath "$path")"
  if [ "$(common_dir "$sd")" = "$(common_dir "$m")" ] && ! git -C "$sd" ls-files --error-unmatch "$(basename "$self")" >/dev/null 2>&1; then
    warn "the uwt skill is not committed, so the new worktree has no copy of it; commit .claude/skills/unity-worktree-cow/"
  fi
  [ "$OS" = windows ] && self="$(cygpath -m "$self")"
  json_ok new "{\"path\":$(json_str "$reg"),\"uwt\":$(json_str "$self"),\"project\":$(json_str "$reg${pre:+/$pre}"),\"branch\":$(json_str "$branch"),\"head\":$(json_str "$(git -C "$path" rev-parse HEAD)"),\"seconds\":$secs,\"verified\":$([ "${OPT_VERIFY:-0}" = 1 ] && echo true || echo false),\"submodules_uninitialized\":$subs}"
  exit $EXIT_OK
}

# ------------------------------------------------------------------ list
# Every worktree of the repo, and whether uwt gave it its Library (the stamp
# hydrate writes). Read from git's own porcelain so it sees worktrees uwt did
# not create.
cmd_list() {
  local src="${1:-$PWD}"; [ -d "$src" ] || die "no such directory: $src"
  local m; m="$(main_worktree "$src")" || die "not a git repository or Plastic workspace: $src"
  local pre; pre="$(golden_field "$(golden_dir "$m")" prefix)"
  local wt="" head="" br="" locked=false prunable=false first=1 rows="" f
  emit() {
    local lib="$wt${pre:+/$pre}/Library" state=none gc=""
    if [ -f "$lib/.uwt-hydration.txt" ]; then state=uwt; gc="$(grep -m1 '^golden_commit=' "$lib/.uwt-hydration.txt" | cut -d= -f2-)"
    elif [ -d "$lib" ]; then state=other; fi
    local main=false; [ $first = 1 ] && main=true
    rows="$rows$([ $first = 1 ] || printf ,){\"path\":$(json_str "$wt"),\"head\":$(json_str "$head"),\"branch\":$([ -n "$br" ] && json_str "$br" || printf null),\"main\":$main,\"locked\":$locked,\"prunable\":$prunable,\"library\":\"$state\",\"golden_commit\":$([ -n "$gc" ] && json_str "$gc" || printf null)}"
    local tags="library=$state"; [ $main = true ] && tags="$tags main"
    [ $locked = true ] && tags="$tags locked"; [ $prunable = true ] && tags="$tags prunable"
    printf '%s  %-28s %s\n' "$wt" "${br:-(detached ${head:0:10})}" "$tags"
    first=0
  }
  # Plastic: every workspace of this repo on this machine, main first. head
  # is the loaded changeset; a workspace on a changeset or label has no branch.
  if [ "$(vcs_of "$src")" = plastic ]; then
    while IFS= read -r wt; do
      head="cs:$(pl_head "$wt")"; br="$(pl_branch "$wt")"
      [ "$OS" = windows ] && wt="$(cygpath -m "$wt")"
      emit
    done < <(pl_workspaces "$m")
    json_ok list "[$rows]"
    exit $EXIT_OK
  fi
  while IFS= read -r -d '' f; do
    case "$f" in
      "")                  [ -n "$wt" ] && emit; wt="" head="" br="" locked=false prunable=false ;;
      "worktree "*)        wt="${f#worktree }" ;;
      "HEAD "*)            head="${f#HEAD }" ;;
      "branch "*)          br="${f#branch refs/heads/}" ;;
      locked|"locked "*)   locked=true ;;
      prunable|"prunable "*) prunable=true ;;
    esac
  done < <(git -C "$m" worktree list --porcelain -z)
  [ -n "$wt" ] && emit
  json_ok list "[$rows]"
  exit $EXIT_OK
}

# ------------------------------------------------------------------ remove
# Plastic's version of the rules below, from cmd_remove (sees its target).
# Pending changes (checkouts, adds, ...) refuse without --force; with it they
# are undone first, which releases any lock a checkout holds - deleting the
# directory alone would leave the lock on the server, held by a workspace
# that no longer exists. Edited or private files need --force, as untracked
# ones do for git. The branch is kept unless --delete-branch, and even then
# while it has changesets of its own or another workspace is on it.
remove_plastic() {
  local top; top="$(cd "$(wk_top "$target")" && pwd -P)"
  [ "$top" = "$target" ] || die "$target is inside a workspace, not its root ($top)"
  # Main holds the golden. A workspace whose recorded main has since been
  # deleted falls back to being its own main, but is not one: it may go.
  local m; m="$(main_worktree "$target")"; m="$(cd "$m" && pwd -P)"
  if [ -f "$target/.plastic/uwt/golden.txt" ] || { [ "$m" = "$target" ] && [ ! -f "$target/.plastic/uwt-main" ]; }; then
    die "refusing to remove the main workspace: $target"
  fi
  local pre; pre="$(golden_field "$(golden_dir "$target")" prefix)"
  local proj="$target${pre:+/$pre}"
  [ -f "$proj/ProjectSettings/ProjectVersion.txt" ] && require_editor_closed "$proj" remove
  local br repo keep=""; br="$(pl_branch "$target")"; repo="$(pl_repo "$target")"
  if [ "${OPT_DELETE_BRANCH:-0}" = 1 ] && [ -n "$br" ]; then
    local w
    while IFS= read -r w; do
      [ "$w" = "$target" ] || [ "$(pl_branch "$w")" != "$br" ] || keep="workspace $(wpath "$w") is on it"
    done < <(pl_workspaces "$target")
  fi
  local pend loc priv
  pend="$(pl_pending "$target" | wc -l | tr -d ' ')"; loc="$(pl_local "$target" | wc -l | tr -d ' ')"
  priv="$(pl_status "$target" --private | grep -c '^PR')"
  if [ "${OPT_FORCE:-0}" != 1 ]; then
    [ "$pend" = 0 ] || die "$target has $pend pending change(s) (checkouts, adds, moves, deletes); check them in, shelve or undo them, or pass --force to undo them"
    [ "$loc" = 0 ] && [ "$priv" = 0 ] || die "$target contains modified or private files, use --force to delete it"
  elif [ "$pend" != 0 ]; then
    cm_ undo -r "$(wpath "$target")" --silent >/dev/null 2>&1 || die "cm undo failed; $target is untouched"
    good "undid $pend pending change(s), releasing any locks they held"
  fi
  cm_ workspace delete "$(wpath "$target")" >/dev/null 2>&1 || die "cm workspace delete refused $target"
  rm -rf "$target" || die "unregistered, but could not delete $target; delete it by hand"
  # A branch with no changesets holds no work, only a name on the server.
  local deleted=false
  if [ "${OPT_DELETE_BRANCH:-0}" = 1 ] && [ -n "$br" ] && [ -z "$keep" ]; then
    local cs out
    if ! cs="$(cm_ find changeset "where branch='$br'" on repository "'$repo'" --format='{changesetid}' --nototal 2>/dev/null | tr -d '\r')"; then
      keep="could not list its changesets"
    elif [ -n "$(printf '%s' "$cs" | tr -d '[:space:]')" ]; then
      keep="it has $(printf '%s\n' "$cs" | grep -c .) changeset(s)"
    elif out="$(cm_ branch delete "br:$br@$repo" 2>&1)"; then deleted=true
    else keep="$(printf '%s' "$out" | tr -d '\r' | head -1)"; fi
  fi
  removed_msg "$target" "$br" $deleted "$keep"
  local reg="$target"; [ "$OS" = windows ] && reg="$(cygpath -m "$target")"
  json_ok remove "{\"path\":$(json_str "$reg"),\"branch\":$([ -n "$br" ] && json_str "$br" || printf null),\"branch_deleted\":$deleted}"
  exit $EXIT_OK
}

removed_msg() { # removed_msg <target> <branch> <deleted> <why kept>
  if [ -z "$2" ]; then good "removed $1"
  elif [ "$3" = true ]; then good "removed $1 and deleted branch $2"
  else good "removed $1 (branch $2 kept)"; [ -z "$4" ] || warn "kept branch $2: $4"; fi
}

# git worktree remove, behind the editor interlock: deleting a Library an
# editor has mapped fails half-way on Windows and pulls it out from under the
# editor elsewhere. git's own rules stand: a dirty worktree needs --force, a
# locked one needs `git worktree unlock` first, and the branch is kept.
# --delete-branch deletes it as `git branch -d` would: only when merged into
# the main worktree's HEAD or its upstream, so never a branch with work.
cmd_remove() {
  local target="${1:-}"; [ -n "$target" ] || die "usage: uwt remove PATH [--force] [--delete-branch] [--json]"
  target="$(abs_path "$target")"
  [ -d "$target" ] || die "no such directory: $target (a worktree deleted by hand is cleaned up by: git worktree prune)"
  # pwd -P throughout: git reports the resolved path (/private/var on macOS,
  # where the temp dir is /var -> /private/var), so a logical one never matches.
  target="$(cd "$target" && pwd -P)"
  [ "$(vcs_of "$target")" = plastic ] && remove_plastic
  local reg; reg="$(git -C "$target" rev-parse --path-format=absolute --show-toplevel 2>/dev/null)" || die "not a git worktree: $target"
  local top; top="$(cd "$reg" && pwd -P)"
  [ "$top" = "$target" ] || die "$target is inside a worktree, not its root ($top)"
  local m; m="$(main_worktree "$target")"; m="$(cd "$m" && pwd -P)"
  [ "$m" = "$target" ] && die "refusing to remove the main worktree: $target"
  local pre; pre="$(golden_field "$(golden_dir "$target")" prefix)"
  local proj="$target${pre:+/$pre}"
  [ -f "$proj/ProjectSettings/ProjectVersion.txt" ] && require_editor_closed "$proj" remove
  local br; br="$(git -C "$target" branch --show-current 2>/dev/null)"
  local ff=(); [ "${OPT_FORCE:-0}" = 1 ] && ff=(--force)
  local out; out="$(git -C "$m" worktree remove ${ff[@]+"${ff[@]}"} "$target" 2>&1)" \
    || die "git worktree remove refused: $(printf '%s' "$out" | sed 's/^fatal: //' | head -1)"
  local deleted=false keep=""
  if [ "${OPT_DELETE_BRANCH:-0}" = 1 ] && [ -n "$br" ]; then
    if out="$(git -C "$m" branch -d "$br" 2>&1)"; then deleted=true
    else keep="$(printf '%s' "$out" | sed 's/^error: //' | head -1)"; fi
  fi
  removed_msg "$target" "$br" $deleted "$keep"
  json_ok remove "{\"path\":$(json_str "$reg"),\"branch\":$([ -n "$br" ] && json_str "$br" || printf null),\"branch_deleted\":$deleted}"
  exit $EXIT_OK
}

# ------------------------------------------------------------------ measure
# Private disk per worktree, against every other worktree of the repo and the
# golden. The measuring itself is a platform helper (C# through PowerShell on
# Windows, Python elsewhere) because it needs physical extent ioctls; which
# trees count, and the output, are decided here so every platform agrees.
cmd_measure() {
  local anchor; anchor="$(project_root "$PWD")" || exit $EXIT_FAIL
  local m; m="$(main_worktree "$anchor")" || die "not a git repository or Plastic workspace"
  local gd; gd="$(golden_dir "$anchor")"
  local here; here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # Every tree that may share blocks: each worktree, named by its directory
  # (de-duplicated), and the golden.
  local names=() dirs=() wt n i
  while IFS= read -r wt; do
    [ -d "$wt" ] || continue
    n="$(printf '%s' "${wt##*/}" | tr -c 'A-Za-z0-9._-' '-')"; i=2
    while printf '%s\n' ${names[@]+"${names[@]}"} | grep -qxF -- "$n"; do n="${n%-[0-9]*}-$i"; i=$((i+1)); done
    names+=("$n"); dirs+=("$(cd "$wt" && pwd -P)")
  done < <(if [ "$(vcs_of "$m")" = plastic ]; then pl_workspaces "$m"; else git -C "$m" worktree list --porcelain | sed -n 's/^worktree //p'; fi)
  local gdp=""; golden_ok "$gd" && { gdp="$(cd "$gd" && pwd -P)"; names+=(golden); dirs+=("$gdp"); }
  [ ${#dirs[@]} -ge 2 ] || die "nothing to compare: one worktree and no golden"

  # Targets: the worktree containing each PATH, or the golden itself.
  local targets="" p top k
  for p in "$@"; do
    top="$(cd "$p" 2>/dev/null && pwd -P)" || die "no such directory: $p"
    if [ "$top" != "$gdp" ]; then
      top="$(wk_top "$top")" || die "not a worktree, nor the golden: $p"
      top="$(cd "$top" && pwd -P)"
    fi
    n=""; for k in "${!dirs[@]}"; do [ "${dirs[$k]}" = "$top" ] && n="${names[$k]}"; done
    [ -n "$n" ] || die "not a worktree of this repo: $p"
    targets="$targets;$n"
  done
  local args=(); for k in "${!dirs[@]}"; do args+=("${names[$k]}=$(wpath "${dirs[$k]}")"); done

  local opts=() out rc
  case "$OS" in
    windows)
      local ps; ps="$(command -v pwsh || command -v powershell)" || die "PowerShell not found"
      [ -n "$targets" ] && opts+=(-Target "${targets#;}"); [ -n "${OPT_BY:-}" ] && opts+=(-By "$OPT_BY"); [ "$JSON" = 1 ] && opts+=(-Json)
      out="$(MSYS2_ARG_CONV_EXCL='*' "$ps" -NoProfile -ExecutionPolicy Bypass -File "$(wpath "$here/measure.ps1")" ${opts[@]+"${opts[@]}"} "${args[@]}" 2>&1)"; rc=$? ;;
    darwin|linux)
      local py; py="$(command -v python3)" || die "python3 not found"
      [ -n "$targets" ] && opts+=(--target "${targets#;}"); [ -n "${OPT_BY:-}" ] && opts+=(--by "$OPT_BY"); [ "$JSON" = 1 ] && opts+=(--json)
      out="$("$py" "$here/measure.py" ${opts[@]+"${opts[@]}"} "${args[@]}" 2>&1)"; rc=$? ;;
    *) die "unsupported OS: $(uname -s)" ;;
  esac
  [ $rc = 0 ] || die "measure failed: $(printf '%s' "$out" | tail -3)"
  if [ "$JSON" = 1 ]; then json_ok measure "$out"; else say "$out"; fi
  exit $EXIT_OK
}

# ------------------------------------------------------------------ cli
usage() {
  cat <<EOF
uwt - cheap Unity git worktrees (or Plastic workspaces) via copy-on-write

  uwt doctor  [PATH]                      prove this volume clones; show golden state
  uwt seed    [PATH] [--force]            snapshot the project + Library (editor CLOSED)
  uwt new     BRANCH [--path DIR] [--base REF] [--inherit-untracked]
              [--init-submodules] [--verify] [--json]
                                          git worktree add + clone the snapshot + hydrate
  uwt hydrate [PATH] [--force]            give an existing worktree a Library from the golden
  uwt list    [PATH] [--json]             the repo's worktrees and where each Library came from
  uwt remove  PATH [--force] [--delete-branch] [--json]
                                          git worktree remove, behind the editor interlock;
                                          --delete-branch only if the branch holds no work
  uwt measure [PATH...] [--by N] [--json] private disk of each worktree and the golden
                                          (default: all), by physical-block overlap

Plastic workspaces: BRANCH is a branch path (/main/task); a bare name is a
  child of the current branch. --base takes cs:N, lb:NAME or br:/path.
  --init-submodules is git only.
Golden location: <repo>/.git/uwt/golden, <main workspace>/.plastic/uwt/golden,
  or \$UWT_CACHE_ROOT/golden.
--json: human output goes to stderr; stdout carries one record,
  {"status":"ok","command":...,"value":...} or {"status":"error","exit":N,"message":...}.
Exit codes: 0 ok, 2 failure, 3 refused (an editor is using the project).
EOF
}

OPT_FORCE=0; OPT_DELETE_BRANCH=0; OPT_INHERIT_UNTRACKED=0; OPT_PATH=""; OPT_BASE=""; OPT_VERIFY=0; OPT_INIT_SUBMODULES=0; OPT_JSON=0; OPT_BY=""
POS=()
CMD="${1:-help}"; shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --force)             OPT_FORCE=1 ;;
    --delete-branch)     OPT_DELETE_BRANCH=1 ;;
    --inherit-untracked) OPT_INHERIT_UNTRACKED=1 ;;
    --verify)            OPT_VERIFY=1 ;;
    --init-submodules)   OPT_INIT_SUBMODULES=1 ;;
    --json)              OPT_JSON=1 ;;
    --path)              shift; OPT_PATH="${1:?--path needs a value}" ;;
    --path=*)            OPT_PATH="${1#--path=}" ;;
    --base)              shift; OPT_BASE="${1:?--base needs a value}" ;;
    --base=*)            OPT_BASE="${1#--base=}" ;;
    --by)                shift; OPT_BY="${1:?--by needs a value}" ;;
    --by=*)              OPT_BY="${1#--by=}" ;;
    -h|--help)           usage; exit 0 ;;
    --*)                 die "unknown option: $1" ;;
    *)                   POS+=("$1") ;;
  esac
  shift
done
if [ "$OPT_JSON" = 1 ]; then
  case "$CMD" in list|new|remove|measure) exec 3>&1 1>&2; JSON=1 ;; *) die "--json is supported by list, new, remove and measure" ;; esac
fi
case "$CMD" in
  doctor)  cmd_doctor  "${POS[@]:-}" ;;
  seed)    cmd_seed    "${POS[@]:-}" ;;
  hydrate) cmd_hydrate "${POS[@]:-}" ;;
  new)     cmd_new     "${POS[@]:-}" ;;
  list)    cmd_list    "${POS[@]:-}" ;;
  remove)  cmd_remove  "${POS[@]:-}" ;;
  measure) cmd_measure ${POS[@]+"${POS[@]}"} ;;
  help|-h|--help) usage; exit 0 ;;
  *)       usage; die "unknown command: $CMD" ;;
esac
