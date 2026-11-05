#!/usr/bin/env bash
#
# Regression suite for scripts/unity-worktree-cow.sh. Synthetic fixtures only: a
# fake Unity project and a fake Library, built in a temp directory. No Unity.
#
# usage: tests/run-tests.sh [ROOT]
#   ROOT is where fixtures are built (default: a temp dir). Point it at a
#   volume that block-clones (ReFS, APFS, btrfs, XFS reflink=1) to run every
#   group; elsewhere the groups that need cloning assert the REFUSAL paths and
#   report the rest as SKIP.
#
# exit 0 all assertions passed | 1 something failed | 2 could not run

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UWT="$HERE/../.claude/skills/unity-worktree-cow/scripts/unity-worktree-cow.sh"
[ -f "$UWT" ] || { echo "missing $UWT"; exit 2; }

ROOT="${1:-$(mktemp -d "${TMPDIR:-/tmp}/uwt-tests-XXXXXX")}"
mkdir -p "$ROOT" || exit 2
ROOT="$(cd "$ROOT" && pwd)"
case "$(uname -s)" in *_NT*) WIN=1 ;; *) WIN=0 ;; esac   # MINGW64_NT, UCRT64_NT, MSYS_NT, ...

PASS=0; FAILN=0; SKIPN=0
pass() { PASS=$((PASS+1)); printf '  PASS  %s\n' "$*"; }
fail() { FAILN=$((FAILN+1)); printf '  FAIL  %s\n' "$*"; }
skip() { SKIPN=$((SKIPN+1)); printf '  SKIP  %s\n' "$*"; }
check() { # check <description> <command...>
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d"; fi
}
group() { printf '\n%s\n' "$*"; }
uwt() { bash "$UWT" "$@"; }
# All-of predicates, so a check can name several paths without a shell
# operator escaping the `check` call.
exists()   { local f; for f in "$@"; do [ -e "$f" ] || return 1; done; }
nonempty() { local f; for f in "$@"; do [ -s "$f" ] || return 1; done; }
absent()   { local f; for f in "$@"; do [ ! -e "$f" ] || return 1; done; }
# One JSON document on stdin, optionally with a python expression over it (d)
# that must be truthy. Falls back to a shape check where there is no python.
PY="$(command -v python3 || command -v python || true)"
json_is() { # json_is [expr] <<<"$json"
  if [ -n "$PY" ]; then "$PY" -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if eval(sys.argv[1]) else 1)' "${1:-True}"
  else grep -q '^{"status":'; fi
}
# Any extent of <file> with ReFS Ref > 1, parsed as a number (a pattern on the
# hex digits would also accept a zero-padded 0x01).
shares_blocks() {
  fsutil file queryExtentsAndRefCounts "$(cygpath -w "$1")" \
    | awk '{ for (i = 1; i < NF; i++) if ($i == "Ref:") {
               h = tolower($(i + 1)); sub(/^0x/, "", h); v = 0
               for (j = 1; j <= length(h); j++) v = v * 16 + index("0123456789abcdef", substr(h, j, 1)) - 1
               if (v > 1) shared = 1 } }
           END { exit !shared }'
}

# ------------------------------------------------------------------ fixture
PROJ="$ROOT/proj"
rm -rf "$ROOT"/proj "$ROOT"/proj-* "$ROOT"/wt-* "$ROOT"/plain
mkdir -p "$PROJ" && cd "$PROJ" || exit 2
git init -q && git config user.email t@t && git config user.name t && git config core.autocrlf false
mkdir -p ProjectSettings Assets/Scenes Packages Library/PackageCache/com.x@abc Library/DataStore/00 \
         Library/Bee Library/BurstCache Library/ScriptAssemblies Library/Search Library/Pipeline Library/ShaderCache Temp obj
printf 'm_EditorVersion: 6000.7.0b1\nm_EditorVersionWithRevision: 6000.7.0b1 (deadbeef)\n' > ProjectSettings/ProjectVersion.txt
echo scene > Assets/Scenes/A.unity; echo '{}' > Packages/manifest.json; echo tracked > README.md
printf '/Library/\n/Temp/\n/obj/\n*.csproj\n*.sln\n' > .gitignore
head -c 300000 /dev/urandom > Library/ArtifactDB
head -c 200000 /dev/urandom > Library/SourceAssetDB
head -c 100000 /dev/urandom > Library/DataStore/uds.db
head -c 100000 /dev/urandom > Library/DataStore/UDSData_3.bin
echo pkg > Library/PackageCache/com.x@abc/package.json
echo dag > Library/Bee/x.dag; echo burst > Library/BurstCache/b.dll; echo dll > Library/ScriptAssemblies/a.dll
echo idx > Library/Search/i.index; echo pipe > Library/Pipeline/p; echo sc > Library/ShaderCache/s.bin
echo '{"process_id":999999}' > Library/EditorInstance.json; : > Library/ArtifactDB-lock; echo 123 > Library/burst.pid
: > Temp/UnityLockfile; echo x > Foo.csproj
git add -A && git commit -qm init
git branch keep HEAD
echo untracked > scratch.txt      # untracked, not ignored: must not survive `new`

# Can this ROOT clone? Decide once, from the tool's own probe.
CLONES=0
if uwt doctor "$PROJ" >/dev/null 2>&1; then CLONES=1; fi
echo "fixture: $PROJ   block-cloning: $([ $CLONES = 1 ] && echo yes || echo no)"
if [ $CLONES = 0 ]; then
  uwt doctor "$PROJ" 2>&1 | grep -E 'block cloning|same volume|different volumes' | sed 's/^ */  doctor: /'
  echo "  clone groups will assert refusals or SKIP. To run them, pass a ROOT on a volume"
  echo "  that clones (ReFS Dev Drive, APFS, btrfs, XFS reflink=1): bash tests/run-tests.sh E:/uwt-tests"
fi

# ------------------------------------------------------------------ 1. doctor
group "1. doctor"
out="$(uwt doctor "$PROJ" 2>&1)"; rc=$?
check "doctor exits 0 (clones) or 2 (cannot clone), never anything else" bash -c "[ $rc = 0 ] || [ $rc = 2 ]"
check "doctor names the Unity version" grep -q '6000.7.0b1' <<<"$out"
check "doctor reports the golden as absent" grep -q 'none yet' <<<"$out"
check "doctor from a subdirectory finds the project" bash -c "cd '$PROJ/Assets' && bash '$UWT' doctor >/dev/null 2>&1; [ \$? = $rc ]"

# ------------------------------------------------------------------ 2. seed
group "2. seed"
GD="$PROJ/.git/uwt/golden"
out="$(uwt seed "$PROJ" 2>&1)"; rc=$?
if [ $CLONES = 1 ]; then
  check "seed exits 0"                                   [ $rc = 0 ]
  check "golden.txt, golden.index and golden/Library exist" exists "$GD.txt" "$GD.index" "$GD/Library"
  check "golden records the Unity version"               grep -q '^unity_version=6000.7.0b1' "$GD.txt"
  check "golden records HEAD"                            grep -q "^commit=$(git rev-parse HEAD)" "$GD.txt"
  check "golden records its longest relative path"       grep -qE '^longest_path=[1-9][0-9]*$' "$GD.txt"
  check "tracked tree is in the golden"                  exists "$GD/Assets/Scenes/A.unity" "$GD/README.md"
  check "Temp, obj, .git are not"                        absent "$GD/Temp" "$GD/obj" "$GD/.git"
  check "generated .csproj is not"                       [ ! -e "$GD/Foo.csproj" ]
  check "cloned: ArtifactDB, SourceAssetDB, DataStore, PackageCache, ShaderCache" \
        nonempty "$GD/Library/ArtifactDB" "$GD/Library/SourceAssetDB" "$GD/Library/DataStore/uds.db" \
                 "$GD/Library/PackageCache/com.x@abc/package.json" "$GD/Library/ShaderCache/s.bin"
  check "denied: Bee, BurstCache, ScriptAssemblies, Search" \
        absent "$GD/Library/Bee" "$GD/Library/BurstCache" "$GD/Library/ScriptAssemblies" "$GD/Library/Search"
  check "never-files stripped: EditorInstance.json, *-lock, *.pid, Pipeline/" \
        absent "$GD/Library/EditorInstance.json" "$GD/Library/ArtifactDB-lock" "$GD/Library/burst.pid" "$GD/Library/Pipeline"
  check "source Library untouched (never-files still there)" exists "$PROJ/Library/EditorInstance.json" "$PROJ/Library/ArtifactDB-lock"
  check "seed again without --force is a no-op exit 0"   bash -c "bash '$UWT' seed '$PROJ' | grep -q 'already exists'"
  check "seed --force republishes"                       bash -c "touch -d '2000-01-01' '$GD.txt'; bash '$UWT' seed '$PROJ' --force >/dev/null && [ \"\$(find '$GD.txt' -newermt '2001-01-01')\" ]"
  check "seed refuses an empty ArtifactDB"               bash -c "cp -r '$PROJ' '$ROOT/proj-empty' && : > '$ROOT/proj-empty/Library/ArtifactDB'; bash '$UWT' seed '$ROOT/proj-empty' --force; [ \$? = 2 ]"
  rm -rf "$ROOT/proj-empty"
else
  check "seed refuses on a non-cloning volume with exit 2" [ $rc = 2 ]
  check "seed says why"                                    grep -qi 'cannot block-clone' <<<"$out"
  check "seed published nothing"                           [ ! -e "$GD.txt" ]
fi

# ------------------------------------------------------------------ 3. interlock
group "3. editor interlock"
if [ "$WIN" = 1 ]; then
  skip "busy-file probe (a Git Bash fd is opened with FILE_SHARE_DELETE, so only a real Unity can exercise the rename probe)"
else
  # An open fd (Linux: /proc/*/fd; macOS: lsof).
  ( sleep 8 9<>"$PROJ/Library/ArtifactDB" ) & holder=$!
  sleep 1
  uwt seed "$PROJ" --force >/dev/null 2>&1; rc=$?
  check "seed refuses (exit 3) while ArtifactDB is held open by another process" [ $rc = 3 ]
  kill $holder 2>/dev/null; wait $holder 2>/dev/null
  # A memory mapping with the fd closed, which is how LMDB holds a database.
  # python3 is only used by the test to create the mapping.
  if [ "$(uname -s)" = Linux ] && command -v python3 >/dev/null 2>&1; then
    python3 -c 'import mmap,os,sys,time
fd=os.open(sys.argv[1],os.O_RDWR); m=mmap.mmap(fd,4096); os.close(fd); time.sleep(8)' "$PROJ/Library/SourceAssetDB" & holder=$!
    sleep 1
    uwt seed "$PROJ" --force >/dev/null 2>&1; rc=$?
    check "seed refuses (exit 3) while SourceAssetDB is memory-mapped with its fd closed" [ $rc = 3 ]
    kill $holder 2>/dev/null; wait $holder 2>/dev/null
  fi
fi
check "doctor names the open-file mechanism" bash -c "bash '$UWT' doctor '$PROJ' 2>&1 | grep -q 'open-file check:'"
check "a dead pid in EditorInstance.json does not block" bash -c "bash '$UWT' seed '$PROJ' --force >/dev/null 2>&1; [ \$? != 3 ]"

# ------------------------------------------------------------------ 4. new
group "4. new"
if [ $CLONES = 1 ]; then
  cd "$PROJ"
  out="$(uwt new feature/x 2>&1)"; rc=$?
  WT="$ROOT/proj-feature-x"
  check "new exits 0"                                   [ $rc = 0 ]
  check "default path is <repo>-<branch> beside the repo" [ -d "$WT" ]
  check "worktree is registered"                        bash -c "git -C '$PROJ' worktree list | grep -q 'feature/x'"
  check "HEAD is the new branch"                        [ "$(git -C "$WT" branch --show-current)" = feature/x ]
  check "tracked tree is clean"                         [ -z "$(git -C "$WT" status --porcelain --untracked-files=no)" ]
  check "inherited untracked file was cleaned"          [ ! -e "$WT/scratch.txt" ]
  check "Library hydrated with a stamp"                 nonempty "$WT/Library/ArtifactDB" "$WT/Library/.uwt-hydration.txt"
  check "Library has no denied or never entries"        absent "$WT/Library/Bee" "$WT/Library/EditorInstance.json"
  check "Library is writable"                           bash -c "echo x >> '$WT/Library/ArtifactDB'"
  check "new refuses an existing path"                  bash -c "bash '$UWT' new feature/y --path '$WT' >/dev/null 2>&1; [ \$? = 2 ]"
  check "existing branch is checked out, not recreated" bash -c "bash '$UWT' new keep --path '$ROOT/wt-keep' >/dev/null 2>&1 && [ \"\$(git -C '$ROOT/wt-keep' branch --show-current)\" = keep ]"
  check "--inherit-untracked keeps the snapshot's untracked files" \
        bash -c "bash '$UWT' new feature/u --path '$ROOT/wt-u' --inherit-untracked >/dev/null 2>&1 && [ -f '$ROOT/wt-u/scratch.txt' ]"
  check "new outside any project exits 2" \
        bash -c "cd '$ROOT' && bash '$UWT' new feature/r --path ./wt-rel >/dev/null 2>&1; [ \$? = 2 ] && [ ! -e '$ROOT/wt-rel' ]"
  check "relative --path resolves against the caller's directory, not the repo root" \
        bash -c "cd '$PROJ/Assets' && bash '$UWT' new feature/r2 --path ../../wt-rel2 >/dev/null 2>&1 && [ -d '$ROOT/wt-rel2/Assets' ]"
  check "--base picks the start commit" \
        bash -c "cd '$PROJ' && bash '$UWT' new feature/b --path '$ROOT/wt-b' --base keep >/dev/null 2>&1 && [ \"\$(git -C '$ROOT/wt-b' rev-parse HEAD)\" = \"\$(git -C '$PROJ' rev-parse keep)\" ]"
  cp "$UWT" "$PROJ/uwt-copy.sh"
  check "new warns when the uwt it runs is not committed to this repo" \
        bash -c "cd '$PROJ' && bash uwt-copy.sh new feature/nc --path '$ROOT/wt-nc' 2>&1 | grep -q 'skill is not committed'"
  check "no such warning when it is committed"           bash -c "! grep -q 'not committed' <<<\"\$(bash '$UWT' new feature/c2 --path '$ROOT/wt-c2' 2>&1)\""
  rm -f "$PROJ/uwt-copy.sh"
  # Concurrent new: the golden is only read and every step writes inside its own
  # worktree, so parallel calls must all succeed.
  for i in 1 2 3 4; do (cd "$PROJ" && bash "$UWT" new "feature/par$i" --path "$ROOT/wt-par$i" >"$ROOT/par$i.log" 2>&1; echo $? >"$ROOT/par$i.rc") & done; wait
  check "four concurrent news all exit 0"               bash -c "[ \"\$(cat '$ROOT'/par[1-4].rc | tr -d '\n')\" = 0000 ]"
  check "and all four are clean, hydrated worktrees"    bash -c "for i in 1 2 3 4; do [ -s '$ROOT/wt-par'\$i/Library/ArtifactDB ] && [ -z \"\$(git -C '$ROOT/wt-par'\$i status --porcelain)\" ] || exit 1; done"
  if [ $WIN = 1 ] && [ "$(MSYS_NO_PATHCONV=1 reg query 'HKLM\SYSTEM\CurrentControlSet\Control\FileSystem' /v LongPathsEnabled 2>/dev/null | grep -oE '0x[0-9]+$')" != 0x1 ]; then
    # Just long enough that root + deepest golden file passes 259 characters.
    lp="$(sed -n 's/^longest_path=//p' "$GD.txt")"; wr="$(cygpath -w "$ROOT")"
    deep="$ROOT/$(printf 'd%.0s' $(seq 1 $(( 260 - ${#wr} - 2 - lp + 1 ))))"
    check "new warns when the root would push the deepest file past MAX_PATH" \
          bash -c "cd '$PROJ' && bash '$UWT' new feature/deep --path '$deep' 2>&1 | grep -q 'LongPathsEnabled is off'"
    check "but not for a short root"                    bash -c "! grep -q 'LongPathsEnabled is off' <<<\"\$(bash '$UWT' new feature/short --path '$ROOT/wt-s' 2>&1)\""
    git -C "$PROJ" worktree remove --force "$deep" >/dev/null 2>&1; rm -rf "$deep"
  else
    skip "MAX_PATH warning (Windows with LongPathsEnabled=0 only)"
  fi
  # Cross-branch: the snapshot is at master; the target branch differs.
  git -C "$PROJ" checkout -q -b other && echo changed > README.md && echo new > Assets/N.txt && git rm -q Packages/manifest.json && git add -A && git commit -qm other && git checkout -q master
  check "cross-branch: reset reconciles to the target branch exactly" \
        bash -c "cd '$PROJ' && bash '$UWT' new other --path '$ROOT/wt-other' >/dev/null 2>&1 && [ \"\$(cat '$ROOT/wt-other/README.md')\" = changed ] && [ -f '$ROOT/wt-other/Assets/N.txt' ] && [ ! -e '$ROOT/wt-other/Packages/manifest.json' ] && [ -z \"\$(git -C '$ROOT/wt-other' status --porcelain)\" ]"
  # Local edits hidden behind index bits: git status cannot see them, so only
  # clearing the bits stops them reaching a worktree.
  git -C "$PROJ" update-index --skip-worktree README.md && echo local > "$PROJ/README.md"
  git -C "$PROJ" update-index --assume-unchanged Assets/Scenes/A.unity && echo local > "$PROJ/Assets/Scenes/A.unity"
  out="$(uwt seed "$PROJ" --force 2>&1)"
  check "seed warns about assume-unchanged/skip-worktree files" grep -q '2 file(s) marked assume-unchanged or skip-worktree' <<<"$out"
  uwt new feature/sw --path "$ROOT/wt-sw" >/dev/null 2>&1; rc=$?
  check "new with flagged files in the snapshot exits 0"   [ $rc = 0 ]
  check "skip-worktree file has the committed content"     [ "$(cat "$ROOT/wt-sw/README.md" 2>/dev/null)" = tracked ]
  check "assume-unchanged file has the committed content"  [ "$(cat "$ROOT/wt-sw/Assets/Scenes/A.unity" 2>/dev/null)" = scene ]
  check "no bits carried into the worktree"                bash -c "[ -z \"\$(git -C '$ROOT/wt-sw' ls-files -v | grep '^[a-zS] ')\" ]"
  git -C "$PROJ" update-index --no-skip-worktree README.md && git -C "$PROJ" update-index --no-assume-unchanged Assets/Scenes/A.unity
  git -C "$PROJ" checkout -q -- README.md Assets/Scenes/A.unity && uwt seed "$PROJ" --force >/dev/null 2>&1
else
  cd "$PROJ"
  out="$(uwt new feature/x 2>&1)"; rc=$?
  check "new refuses with exit 2 when there is no golden"   [ $rc = 2 ]
  check "nothing was registered"                            bash -c "! git -C '$PROJ' worktree list | grep -q feature/x"
  check "no branch was created"                             bash -c "! git -C '$PROJ' rev-parse --verify --quiet refs/heads/feature/x"
fi

# ------------------------------------------------------------------ 5. hydrate
group "5. hydrate"
git -C "$PROJ" worktree add -q "$ROOT/plain" -b plain
if [ $CLONES = 1 ]; then
  check "hydrate fills a plain git worktree"          bash -c "bash '$UWT' hydrate '$ROOT/plain' >/dev/null 2>&1 && [ -s '$ROOT/plain/Library/ArtifactDB' ]"
  check "hydrate refuses to overwrite without --force" bash -c "bash '$UWT' hydrate '$ROOT/plain' >/dev/null 2>&1; [ \$? = 2 ]"
  check "hydrate --force replaces"                    bash -c "echo junk > '$ROOT/plain/Library/JUNK'; bash '$UWT' hydrate '$ROOT/plain' --force >/dev/null 2>&1 && [ ! -e '$ROOT/plain/Library/JUNK' ]"
  check "hydrate warns on a Unity version mismatch"   bash -c "sed -i.bak 's/6000.7.0b1/6000.8.0a1/' '$ROOT/plain/ProjectSettings/ProjectVersion.txt'; bash '$UWT' hydrate '$ROOT/plain' --force 2>&1 | grep -q 'declares'"
else
  check "hydrate refuses with exit 2 when there is no golden" bash -c "bash '$UWT' hydrate '$ROOT/plain' >/dev/null 2>&1; [ \$? = 2 ]"
fi

# ------------------------------------------------------------------ 6. cli
group "6. cli"
check "unknown command exits 2"        bash -c "bash '$UWT' frob >/dev/null 2>&1; [ \$? = 2 ]"
check "unknown option exits 2"         bash -c "bash '$UWT' doctor --bogus >/dev/null 2>&1; [ \$? = 2 ]"
check "help exits 0"                   bash -c "bash '$UWT' help >/dev/null 2>&1"
check "new without a branch exits 2"   bash -c "cd '$PROJ' && bash '$UWT' new >/dev/null 2>&1; [ \$? = 2 ]"

# ------------------------------------------------------------------ 7. subdirectory project
# A Unity project that is a subdirectory of its repo (a monorepo). The golden
# mirrors the project directory, so every clone must land at the same offset.
group "7. subdirectory project"
MONO="$ROOT/mono"
rm -rf "$MONO" "$ROOT"/mono-* "$ROOT"/wt-mono*
mkdir -p "$MONO/pkgs/p1" "$MONO/game/ProjectSettings" "$MONO/game/Assets" "$MONO/game/Library/DataStore"
git -C "$MONO" init -q && git -C "$MONO" config user.email t@t && git -C "$MONO" config user.name t && git -C "$MONO" config core.autocrlf false
printf 'm_EditorVersion: 6000.7.0b1\n' > "$MONO/game/ProjectSettings/ProjectVersion.txt"
head -c 1000000 /dev/urandom > "$MONO/game/Assets/big.bin"; echo p > "$MONO/pkgs/p1/package.json"
printf 'game/Library/\n' > "$MONO/.gitignore"
head -c 300000 /dev/urandom > "$MONO/game/Library/ArtifactDB"; head -c 100000 /dev/urandom > "$MONO/game/Library/DataStore/uds.db"
git -C "$MONO" add -A && git -C "$MONO" commit -qm init
if [ $CLONES = 1 ]; then
  check "seed from the subdirectory records its prefix" \
        bash -c "cd '$MONO/game' && bash '$UWT' seed >/dev/null 2>&1 && grep -qx 'prefix=game' '$MONO/.git/uwt/golden.txt'"
  check "new from the repo root places the project at its prefix" \
        bash -c "cd '$MONO' && bash '$UWT' new feat/m --path '$ROOT/wt-mono' >/dev/null 2>&1 && [ -s '$ROOT/wt-mono/game/Library/ArtifactDB' ] && [ -f '$ROOT/wt-mono/game/Assets/big.bin' ]"
  check "no Library at the worktree root"               bash -c "[ -d '$ROOT/wt-mono/game' ] && [ ! -e '$ROOT/wt-mono/Library' ] && [ ! -e '$ROOT/wt-mono/Assets' ]"
  check "files outside the project come from git"       nonempty "$ROOT/wt-mono/pkgs/p1/package.json"
  check "subdirectory worktree is clean"                bash -c "s=\$(git -C '$ROOT/wt-mono' status --porcelain) && [ -z \"\$s\" ]"
  if [ $WIN = 1 ]; then
    check "project files were cloned, not written by git" shares_blocks "$ROOT/wt-mono/game/Assets/big.bin"
  else
    skip "block-sharing check for the subdirectory clone (fsutil only)"
  fi
  check "hydrate given the worktree root finds the project" \
        bash -c "rm -rf '$ROOT/wt-mono/game/Library' && bash '$UWT' hydrate '$ROOT/wt-mono' >/dev/null 2>&1 && [ -s '$ROOT/wt-mono/game/Library/ArtifactDB' ]"
else
  skip "subdirectory project (needs a volume that block-clones)"
fi

# ------------------------------------------------------------------ 8. list, remove, --json
group "8. list, remove, --json"
cd "$PROJ"
out="$(uwt list 2>&1)"; rc=$?
check "list exits 0"                          [ $rc = 0 ]
check "list shows the main worktree"          grep -q "main" <<<"$out"
out="$(uwt list --json 2>/dev/null)"
check "list --json is one ok record with an array" json_is 'd["status"]=="ok" and isinstance(d["value"],list)' <<<"$out"
check "list --json marks exactly one main"    json_is 'sum(w["main"] for w in d["value"])==1' <<<"$out"
check "--json is refused on doctor"           bash -c "bash '$UWT' doctor --json >/dev/null 2>&1; [ \$? = 2 ]"
check "remove refuses the main worktree"      bash -c "bash '$UWT' remove '$PROJ' >/dev/null 2>&1; [ \$? = 2 ] && [ -d '$PROJ/.git' ]"
check "remove refuses a path that is not a worktree root" bash -c "bash '$UWT' remove '$PROJ/Assets' >/dev/null 2>&1; [ \$? = 2 ]"
if [ $CLONES = 1 ]; then
  WT="$ROOT/proj-feature-x"
  check "list says which Library came from uwt (main has an editor-built one)" \
        json_is "any(w['library']=='uwt' and w['branch']=='feature/x' for w in d['value']) and all(w['library']=='other' for w in d['value'] if w['main'])" <<<"$out"
  out="$(uwt new feature/j --path "$ROOT/wt-j" --json 2>/dev/null)"; rc=$?
  check "new --json exits 0 with one ok record on stdout" json_is 'd["status"]=="ok" and d["value"]["branch"]=="feature/j"' <<<"$out"
  check "new --json reports a path that exists"  json_is '__import__("os").path.isdir(d["value"]["path"])' <<<"$out"
  check "new --json names the uwt script, and it exists" json_is '__import__("os").path.isfile(d["value"]["uwt"])' <<<"$out"
  out="$(uwt new feature/j2 --path "$ROOT/wt-j" --json 2>/dev/null)"; rc=$?
  check "new --json failure exits 2"             [ $rc = 2 ]
  check "new --json failure record names the problem" json_is 'd["status"]=="error" and d["exit"]==2 and "exists" in d["message"]' <<<"$out"
  echo dirty >> "$ROOT/wt-j/README.md"
  check "remove refuses a dirty worktree without --force" bash -c "bash '$UWT' remove '$ROOT/wt-j' >/dev/null 2>&1; [ \$? = 2 ] && [ -d '$ROOT/wt-j/Library' ]"
  out="$(uwt remove "$ROOT/wt-j" --force --json 2>/dev/null)"; rc=$?
  check "remove --force --json removes it"       bash -c "[ $rc = 0 ] && [ ! -e '$ROOT/wt-j' ]"
  check "remove --json record names the branch"  json_is 'd["status"]=="ok" and d["value"]["branch"]=="feature/j"' <<<"$out"
  check "remove keeps the branch"                git -C "$PROJ" rev-parse --verify --quiet refs/heads/feature/j
  check "remove unregisters it"                  bash -c "! git -C '$PROJ' worktree list | grep -q 'wt-j'"
  check "remove of a clean worktree needs no --force (its ignored Library does not count)" \
        bash -c "bash '$UWT' remove '$ROOT/wt-keep' >/dev/null 2>&1 && [ ! -e '$ROOT/wt-keep' ]"
  uwt new feature/del --path "$ROOT/wt-del" >/dev/null 2>&1
  out="$(uwt remove "$ROOT/wt-del" --delete-branch --json 2>/dev/null)"; rc=$?
  check "remove --delete-branch deletes a branch with no work of its own" \
        bash -c "[ $rc = 0 ] && ! git -C '$PROJ' rev-parse --verify --quiet refs/heads/feature/del >/dev/null"
  check "and says so in --json"                  json_is 'd["value"]["branch_deleted"] is True' <<<"$out"
  uwt new feature/del2 --path "$ROOT/wt-del2" >/dev/null 2>&1
  git -C "$ROOT/wt-del2" commit -q --allow-empty -m work
  out="$(uwt remove "$ROOT/wt-del2" --delete-branch --json 2>/dev/null)"; rc=$?
  check "remove --delete-branch keeps a branch with commits, and still removes" \
        bash -c "[ $rc = 0 ] && [ ! -e '$ROOT/wt-del2' ] && git -C '$PROJ' rev-parse --verify --quiet refs/heads/feature/del2 >/dev/null"
  check "and says so in --json"                  json_is 'd["value"]["branch_deleted"] is False' <<<"$out"
  if [ "$WIN" = 0 ]; then
    # Through a symlinked parent, as macOS's temp dir is (/var -> /private/var):
    # git reports the resolved path, the caller passes the logical one. The
    # link lives inside ROOT: ROOT may be a mount point in a root-owned /mnt.
    ln -sfn "$ROOT" "$ROOT/link"
    check "remove works through a symlinked path" \
          bash -c "bash '$UWT' remove '$ROOT/link/wt-rel2' >/dev/null 2>&1 && [ ! -e '$ROOT/wt-rel2' ]"
    rm -f "$ROOT/link"
    ( sleep 8 9<>"$ROOT/wt-b/Library/ArtifactDB" ) & holder=$!
    sleep 1
    uwt remove "$ROOT/wt-b" --force >/dev/null 2>&1; rc=$?
    check "remove refuses (exit 3) while the worktree's ArtifactDB is open" bash -c "[ $rc = 3 ] && [ -d '$ROOT/wt-b/Library' ]"
    kill $holder 2>/dev/null; wait $holder 2>/dev/null
  fi
  # --verify: a snapshot file changed without moving its mtime or size. On
  # macOS and Linux the post-reset status already re-hashes it (a clone's
  # inode never matches the index; measured on macOS), so it is caught either
  # way there; on Windows, where git reports inode 0, only --verify catches
  # it. Either way: rolled back, never a wrong tree.
  # The golden index must be strictly newer than the file, or git counts the
  # entry racily clean, rehashes it, and repairs the file before --verify runs.
  sleep 1; touch "$GD.index"
  f="$GD/Assets/Scenes/A.unity"; cp -p "$f" "$ROOT/ref.stamp"; printf 'SCENE\n' > "$f"; touch -r "$ROOT/ref.stamp" "$f"
  uwt new feature/v --path "$ROOT/wt-v" --verify >/dev/null 2>&1; rc=$?
  check "new --verify rolls back when content differs behind matching stat data" \
        bash -c "[ $rc = 2 ] && [ ! -e '$ROOT/wt-v' ] && ! git -C '$PROJ' rev-parse --verify --quiet refs/heads/feature/v"
  uwt new feature/v --path "$ROOT/wt-v" >/dev/null 2>&1; rc=$?
  if [ "$WIN" = 1 ]; then
    check "without --verify the wrong content gets through (Windows git has no inodes; the stat cache is trusted)" \
          bash -c "[ $rc = 0 ] && grep -qx SCENE '$ROOT/wt-v/Assets/Scenes/A.unity'"
    uwt remove "$ROOT/wt-v" --force >/dev/null 2>&1; git -C "$PROJ" branch -D -q feature/v 2>/dev/null
  else check "without --verify it is still rolled back (inode mismatch makes status rehash)" bash -c "[ $rc = 2 ] && [ ! -e '$ROOT/wt-v' ]"; fi
  uwt seed "$PROJ" --force >/dev/null 2>&1; rm -f "$ROOT/ref.stamp"
  out="$(uwt new feature/v --path "$ROOT/wt-v" --verify --json 2>"$ROOT/verify.err")"
  check "new --verify passes on an honest snapshot" json_is 'd["status"]=="ok" and d["value"]["verified"]' <<<"$out"
  if [ "$WIN" = 1 ]; then check "on Windows --verify runs the fresh-index pass" grep -q 'against a fresh index' "$ROOT/verify.err"
  else check "outside Windows --verify skips the redundant second pass" grep -q 'nothing to add here' "$ROOT/verify.err"; fi
  # The skip relies on status comparing inodes; a user's checkStat=minimal
  # must not switch that off.
  git -C "$PROJ" config core.checkStat minimal
  sleep 1; touch "$GD.index"
  cp -p "$f" "$ROOT/ref.stamp"; printf 'SCENE\n' > "$f"; touch -r "$ROOT/ref.stamp" "$f"
  uwt new feature/v3 --path "$ROOT/wt-v3" --verify >/dev/null 2>&1; rc=$?
  check "a configured core.checkStat=minimal does not weaken the check" bash -c "[ $rc = 2 ] && [ ! -e '$ROOT/wt-v3' ]"
  git -C "$PROJ" config --unset core.checkStat; uwt seed "$PROJ" --force >/dev/null 2>&1; rm -f "$ROOT/ref.stamp" "$ROOT/verify.err"
else
  check "remove of a non-worktree directory exits 2" bash -c "mkdir -p '$ROOT/notwt' && bash '$UWT' remove '$ROOT/notwt' >/dev/null 2>&1; [ \$? = 2 ]"
fi

# ------------------------------------------------------------------ 9. case collisions
group "9. case collisions"
# The detector itself, everywhere: file-level and directory-level collisions.
CC="$ROOT/cc"; rm -rf "$CC"; git init -q "$CC"
( cd "$CC" && export GIT_INDEX_FILE="$CC/.git/cc-index"
  b="$(echo x | git hash-object -w --stdin)"
  for n in README.md readme.MD Assets/a.txt assets/b.txt Other/c.txt; do git update-index --add --cacheinfo "100644,$b,$n"; done
  git -c user.email=t@t -c user.name=t commit-tree -m cc "$(git write-tree)" > "$CC/.git/cc-commit" )
cc_out="$(bash -c "eval \"\$(sed -n '/^case_collisions()/,/^}/p' '$UWT')\"; case_collisions '$CC' \"\$(cat '$CC/.git/cc-commit')\"")"
check "detector finds a file collision"      grep -qx 'README.md <-> readme.MD' <<<"$cc_out"
check "detector finds a directory collision" grep -qx 'Assets <-> assets' <<<"$cc_out"
check "detector reports nothing else"        [ "$(wc -l <<<"$cc_out" | tr -d ' ')" = 2 ]
if [ $CLONES = 1 ]; then
  cd "$PROJ"
  git -C "$PROJ" branch casey "$(cd "$PROJ" && export GIT_INDEX_FILE="$PROJ/.git/cc-index"
    git read-tree HEAD; b="$(echo x | git hash-object -w --stdin)"; git update-index --add --cacheinfo "100644,$b,readme.MD"
    git commit-tree -p HEAD -m casey "$(git write-tree)")"
  rm -f "$PROJ/.git/cc-index"
  if bash -c "eval \"\$(sed -n '/^case_insensitive()/,/^}/p' '$UWT')\"; case_insensitive '$ROOT'"; then
    out="$(uwt new casey --path "$ROOT/wt-case" 2>&1)"; rc=$?
    check "case-folding volume: new refuses a colliding branch with exit 2" [ $rc = 2 ]
    check "the refusal names both paths"          grep -q 'README.md <-> readme.MD' <<<"$out"
    check "nothing registered"                    bash -c "[ ! -e '$ROOT/wt-case' ] && ! git -C '$PROJ' worktree list | grep -q wt-case"
  else
    check "case-sensitive volume: a colliding branch is fine" \
          bash -c "bash '$UWT' new casey --path '$ROOT/wt-case' >/dev/null 2>&1 && [ -f '$ROOT/wt-case/README.md' ] && [ -f '$ROOT/wt-case/readme.MD' ]"
  fi
else
  skip "case collisions through new (needs a volume that block-clones)"
fi

# ------------------------------------------------------------------ 10. submodules
group "10. submodules"
SUBR="$ROOT/subrepo"; SUPER="$ROOT/super"
rm -rf "$SUBR" "$SUPER" "$ROOT"/wt-sub*
git init -q "$SUBR" && git -C "$SUBR" config user.email t@t && git -C "$SUBR" config user.name t && git -C "$SUBR" config core.autocrlf false
mkdir -p "$SUBR/Runtime" && echo pkg > "$SUBR/package.json" && echo code > "$SUBR/Runtime/a.cs"
git -C "$SUBR" add -A && git -C "$SUBR" commit -qm sub
mkdir -p "$SUPER/ProjectSettings" "$SUPER/Assets" "$SUPER/Library"
git -C "$SUPER" init -q && git -C "$SUPER" config user.email t@t && git -C "$SUPER" config user.name t && git -C "$SUPER" config core.autocrlf false
printf 'm_EditorVersion: 6000.7.0b1\n' > "$SUPER/ProjectSettings/ProjectVersion.txt"; echo a > "$SUPER/Assets/a.txt"
printf '/Library/\n' > "$SUPER/.gitignore"
head -c 300000 /dev/urandom > "$SUPER/Library/ArtifactDB"
# file:// submodules are refused by default since git 2.38.1; allow them for
# these commands and every git the tool starts.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always
git -C "$SUPER" submodule add -q "$SUBR" Packages/com.x >/dev/null 2>&1
git -C "$SUPER" add -A && git -C "$SUPER" commit -qm init
if [ $CLONES = 0 ]; then
  skip "submodules (needs a volume that block-clones)"
elif [ ! -f "$SUPER/Packages/com.x/package.json" ]; then
  fail "fixture: git could not add a file:// submodule (git $(git --version | sed 's/git version //'))"
else
  cd "$SUPER"
  uwt seed >/dev/null 2>&1
  out="$(uwt new feat/s --path "$ROOT/wt-sub" --json 2>/dev/null)"; rc=$?
  check "new with a submodule exits 0"                 [ $rc = 0 ]
  check "the submodule is left empty, as git worktree add leaves it" \
        bash -c "[ -d '$ROOT/wt-sub/Packages/com.x' ] && [ -z \"\$(ls -A '$ROOT/wt-sub/Packages/com.x')\" ]"
  check "and reported as uninitialised"                json_is 'd["value"]["submodules_uninitialized"]==1' <<<"$out"
  check "the worktree is clean"                        bash -c "[ -z \"\$(git -C '$ROOT/wt-sub' status --porcelain)\" ]"
  check "the source's submodule is untouched"          nonempty "$SUPER/Packages/com.x/package.json" "$SUPER/Packages/com.x/.git"
  check "--init-submodules checks it out in the worktree" \
        bash -c "bash '$UWT' new feat/s2 --path '$ROOT/wt-sub2' --init-submodules >/dev/null 2>&1 && [ -s '$ROOT/wt-sub2/Packages/com.x/Runtime/a.cs' ]"
  check "its submodule repo is the worktree's own, not the source's" \
        bash -c "[ \"\$(git -C '$ROOT/wt-sub2/Packages/com.x' rev-parse --absolute-git-dir)\" != \"\$(git -C '$SUPER/Packages/com.x' rev-parse --absolute-git-dir)\" ]"
  check "a status in the worktree's submodule leaves the source's clean" \
        bash -c "echo x >> '$ROOT/wt-sub2/Packages/com.x/package.json'; [ -z \"\$(git -C '$SUPER/Packages/com.x' status --porcelain)\" ]"
fi
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0

# ------------------------------------------------------------------ 11. measure
group "11. measure"
FSTYPE=""; [ "$(uname -s)" = Linux ] && FSTYPE="$(stat -f -c %T "$ROOT" 2>/dev/null)"
if [ $CLONES = 0 ]; then
  skip "measure (needs a volume that block-clones)"
elif [ "$FSTYPE" = zfs ]; then
  # ZFS clones but has no FIEMAP: measure must refuse, not report all unmapped.
  cd "$PROJ"
  out="$(uwt measure --json 2>/dev/null)"; rc=$?
  check "on ZFS measure refuses (exit 2)"               [ $rc = 2 ]
  check "and says the filesystem has no physical extents" json_is '"physical extents" in d["message"]' <<<"$out"
else
  cd "$PROJ"
  uwt new feature/m --path "$ROOT/wt-m" >/dev/null 2>&1
  priv() { bash "$UWT" measure "$ROOT/wt-m" --json 2>/dev/null | "$PY" -c 'import json,sys; print([t for t in json.load(sys.stdin)["value"]["trees"] if t["reported"]][0]["private"])'; }
  out="$(uwt measure --json 2>/dev/null)"; rc=$?
  check "measure exits 0"                               [ $rc = 0 ]
  check "it covers every worktree and the golden"       json_is 'any(t["name"]=="golden" for t in d["value"]["trees"]) and len(d["value"]["trees"]) == 1 + len([w for w in __import__("subprocess").run(["git","worktree","list","--porcelain"],capture_output=True,text=True).stdout.splitlines() if w.startswith("worktree ")])' <<<"$out"
  if [ -n "$PY" ]; then
    p0="$(priv)"; head -c 1048576 /dev/urandom > "$ROOT/wt-m/new.bin"; p1="$(priv)"   # no sync: measure flushes
    check "a new 1 MiB file adds exactly 1 MiB private"   [ "$(( p1 - p0 ))" = 1048576 ]
    check "the same answer twice"                          [ "$(priv)" = "$p1" ]
    # Measured at once, no sync: a burst large enough that the write cache still
    # holds most of it. Unflushed data has no blocks yet, so measure must flush.
    "$PY" -c 'import os,sys
for i in range(256): open(os.path.join(sys.argv[1], "burst%d.bin" % i), "wb").write(os.urandom(1048576))' "$ROOT/wt-m"
    p2="$(priv)"
    check "a 256 MiB burst measured at once adds exactly 256 MiB" [ "$(( p2 - p1 ))" = 268435456 ]
  else
    skip "measure deltas (needs python)"
  fi
  check "measure of a path outside the repo exits 2"    bash -c "cd '$PROJ' && bash '$UWT' measure '$ROOT' >/dev/null 2>&1; [ \$? = 2 ]"
fi

# ------------------------------------------------------------------ 12. plastic
# The same lifecycle on a Unity Version Control (Plastic) workspace. Needs cm
# and a reachable server: UWT_TEST_PLASTIC_SERVER, default "local" (the
# server a client install sets up). A Unity Cloud organization (org@unity)
# keeps repos under a project, which must already exist: name it in
# UWT_TEST_PLASTIC_PROJECT. Each run makes throwaway repos named uwt-test-*,
# and deletes them, and any a crashed run left, at the end.
group "12. plastic"
PS="${UWT_TEST_PLASTIC_SERVER:-local}"
PP="${UWT_TEST_PLASTIC_PROJECT:+$UWT_TEST_PLASTIC_PROJECT/}"
pcm() { if [ "$WIN" = 1 ]; then MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' cm "$@"; else cm "$@"; fi; }
pwp() { if [ "$WIN" = 1 ]; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
if ! command -v cm >/dev/null 2>&1; then skip "plastic group (cm not on PATH)"
elif ! pcm repository list "$PS" >/dev/null 2>&1; then skip "plastic group (no Plastic server reachable as '$PS'; set UWT_TEST_PLASTIC_SERVER)"
elif [ $CLONES = 0 ]; then skip "plastic group (this volume cannot block-clone)"
else
  # Leftovers of an earlier run: workspaces under ROOT, then uwt-test-* repos.
  pl_sweep() {
    local p
    pcm workspace list --format='{path}' 2>/dev/null | tr -d '\r' | while IFS= read -r p; do
      [ "$WIN" = 1 ] && p="$(cygpath -u "$p")"
      case "$p" in "$ROOT"/*) pcm workspace delete "$(pwp "$p")" >/dev/null 2>&1; rm -rf "$p" ;; esac
    done
    pcm repository list "$PS" --format='{repname}' 2>/dev/null | tr -d '\r' | grep -F "${PP}uwt-test-" | grep "^${PP}uwt-test-" \
      | while IFS= read -r p; do pcm repository delete "$p@$PS" >/dev/null 2>&1; done
  }
  pl_sweep
  PR="${PP}uwt-test-$$@$PS"; PM="$ROOT/uwtp"
  pcm repository create "$PR" >/dev/null 2>&1
  pcm workspace create uwtp "$(pwp "$PM")" "$PR" >/dev/null 2>&1
  (
    cd "$PM" || exit 1
    mkdir -p ProjectSettings Assets/Scenes Packages
    printf 'm_EditorVersion: 6000.7.0b1\nm_EditorVersionWithRevision: 6000.7.0b1 (deadbeef)\n' > ProjectSettings/ProjectVersion.txt
    echo scene > Assets/Scenes/A.unity; echo '{}' > Packages/manifest.json; echo tracked > README.md
    printf '/Library\n/Temp\n/obj\n*.csproj\n' > ignore.conf
    pcm checkin --all --private -c init >/dev/null 2>&1
    pcm label create "lb:L1@$PR" "cs:1@$PR" >/dev/null 2>&1
    pcm branch create "br:/main/feat@$PR" >/dev/null 2>&1
    pcm switch br:/main/feat --noinput >/dev/null 2>&1
    echo changed > Assets/Scenes/A.unity; echo new > Assets/new.txt; rm README.md
    pcm checkin --all --private -c feat >/dev/null 2>&1
    pcm switch br:/main --noinput >/dev/null 2>&1
    echo second > Assets/second.txt; pcm checkin --all --private -c second >/dev/null 2>&1
    mkdir -p Library/PackageCache/com.x@abc Library/DataStore Library/Bee Library/ScriptAssemblies Temp
    head -c 300000 /dev/urandom > Library/ArtifactDB; head -c 200000 /dev/urandom > Library/SourceAssetDB
    head -c 100000 /dev/urandom > Library/DataStore/uds.db; echo pkg > Library/PackageCache/com.x@abc/package.json
    echo dag > Library/Bee/x.dag; echo dll > Library/ScriptAssemblies/a.dll; : > Library/ArtifactDB-lock
    : > Temp/UnityLockfile; echo x > Foo.csproj
    echo private > scratch.txt   # private, not ignored: must not survive `new`
  )
  PGD="$PM/.plastic/uwt/golden"
  pstat() { pcm status "$(pwp "$1")" --controlledchanged --changed --localdeleted --localmoved --short 2>/dev/null | tr -d '\r' | grep -c . ; }
  pguid() { sed -n 2p "$1/.plastic/plastic.workspace" | tr -d '\r'; }
  registered() { pcm workspace list --format='{path}' 2>/dev/null | tr -d '\r' | grep -qixF "$(pwp "$1")"; }
  pbranch() { pcm ls / --tree="br:$1@$PR" >/dev/null 2>&1; }
  check "fixture: a Plastic workspace on /main with a clean status" bash -c "[ $(pstat "$PM") = 0 ] && [ -f '$PM/ProjectSettings/ProjectVersion.txt' ]"

  out="$(uwt doctor "$PM" 2>&1)"; rc=$?
  check "doctor exits 0 on a Plastic workspace"         [ $rc = 0 ]
  check "doctor says plastic and names the repo"        grep -q "plastic.*repo: ${PR}" <<<"$out"

  out="$(uwt seed "$PM" 2>&1)"; rc=$?
  check "seed exits 0"                                  [ $rc = 0 ]
  check "the golden is in the main workspace's .plastic" exists "$PGD.txt" "$PGD.wktree" "$PGD.selector" "$PGD/Library/ArtifactDB"
  check "golden records vcs, repo and the changeset"    bash -c "grep -qx 'vcs=plastic' '$PGD.txt' && grep -qx 'repo=$PR' '$PGD.txt' && grep -qx 'commit=3' '$PGD.txt'"
  check ".plastic, Temp and the denied Library entries are not in the golden" \
        absent "$PGD/.plastic" "$PGD/Temp" "$PGD/Foo.csproj" "$PGD/Library/Bee" "$PGD/Library/ArtifactDB-lock"
  check "the golden is invisible to cm status"          [ "$(pstat "$PM")" = 0 ]

  pcm checkout "$(pwp "$PM/README.md")" >/dev/null 2>&1
  out="$(uwt seed "$PM" --force 2>&1)"; rc=$?
  check "seed refuses a checkout (exit 2)"              [ $rc = 2 ]
  check "and says why"                                  grep -q 'pending change' <<<"$out"
  check "and keeps the previous golden"                 exists "$PGD.txt" "$PGD.wktree"
  pcm undo -r "$(pwp "$PM")" >/dev/null 2>&1

  # A local edit, and one hidden by hidden_changes.conf: both in the snapshot.
  echo edited > "$PM/Assets/Scenes/A.unity"; echo edited > "$PM/README.md"
  printf '/README.md\n' > "$PM/hidden_changes.conf"
  out="$(uwt seed "$PM" --force 2>&1)"; rc=$?
  check "seed with local and hidden edits exits 0"     [ $rc = 0 ]
  check "warning that they do not carry over"           grep -q 'local change' <<<"$out"

  cd "$PM"
  out="$(uwt new task1 --json 2>/dev/null)"; rc=$?
  PT1="$ROOT/uwtp-main-task1"
  check "new task1 exits 0"                             [ $rc = 0 ]
  check "a bare name becomes a child of the current branch" json_is 'd["value"]["branch"] == "/main/task1" and d["value"]["head"].startswith("cs:")' <<<"$out"
  check "the branch exists on the server"               pbranch /main/task1
  check "the workspace is registered with cm"           registered "$PT1"
  check "under its own identity, not the source's"      bash -c "[ '$(pguid "$PT1")' != '$(pguid "$PM")' ] && [ -n '$(pguid "$PT1")' ]"
  check "it records the main workspace"                 bash -c "[ \"\$(head -1 '$PT1/.plastic/uwt-main')\" = '$PM' ]"
  check "cm status is clean"                            [ "$(pstat "$PT1")" = 0 ]
  check "the source's local edit did not carry over"    grep -qx scene "$PT1/Assets/Scenes/A.unity"
  check "nor its hidden edit"                           grep -qx tracked "$PT1/README.md"
  check "private files from the snapshot are gone"      absent "$PT1/scratch.txt" "$PT1/Temp" "$PT1/Foo.csproj"
  check "Library hydrated, denied entries absent"       bash -c "[ -s '$PT1/Library/ArtifactDB' ] && [ -f '$PT1/Library/.uwt-hydration.txt' ] && [ ! -e '$PT1/Library/Bee' ]"
  check "the source is untouched"                       bash -c "grep -qx edited '$PM/README.md' && [ -f '$PM/scratch.txt' ]"
  rm -f "$PM/hidden_changes.conf"; pcm undo -r "$(pwp "$PM")" >/dev/null 2>&1
  uwt seed "$PM" --force >/dev/null 2>&1   # a clean golden again for what follows

  out="$(uwt new /main/feat --path "$ROOT/uwtp-feat" 2>&1)"; rc=$?
  check "new on an existing branch exits 0"             [ $rc = 0 ]
  check "with that branch's content"                    bash -c "grep -qx changed '$ROOT/uwtp-feat/Assets/Scenes/A.unity' && [ -f '$ROOT/uwtp-feat/Assets/new.txt' ] && [ ! -e '$ROOT/uwtp-feat/README.md' ] && [ ! -e '$ROOT/uwtp-feat/Assets/second.txt' ]"
  check "and a clean status"                            [ "$(pstat "$ROOT/uwtp-feat")" = 0 ]

  out="$(uwt new /main/fromlabel --base lb:L1 --path "$ROOT/uwtp-lb" 2>&1)"; rc=$?
  check "new --base lb:L1 starts the branch at the label" bash -c "[ $rc = 0 ] && [ ! -e '$ROOT/uwtp-lb/Assets/second.txt' ] && [ -f '$ROOT/uwtp-lb/README.md' ]"
  out="$(uwt new /main/fromfeat --base br:/main/feat --path "$ROOT/uwtp-bf" 2>&1)"; rc=$?
  check "new --base br:/main/feat starts at that branch's head" bash -c "[ $rc = 0 ] && [ -f '$ROOT/uwtp-bf/Assets/new.txt' ]"

  out="$(uwt new /main/bad --base cs:999 --path "$ROOT/uwtp-bad" 2>&1)"; rc=$?
  check "a base that does not exist: exit 2, nothing created" \
        bash -c "[ $rc = 2 ] && [ ! -e '$ROOT/uwtp-bad' ]"
  check "and no branch"                                 bash -c "! MSYS_NO_PATHCONV=1 cm ls / --tree='br:/main/bad@$PR' >/dev/null 2>&1"
  out="$(uwt new /main/dup --path "$ROOT/sub/uwtp-feat" 2>&1)"; rc=$?
  check "a workspace name already in use: exit 2, nothing created" bash -c "[ $rc = 2 ] && [ ! -e '$ROOT/sub/uwtp-feat' ]"
  check "and says the name is taken"                    grep -q 'already exists' <<<"$out"
  check "--init-submodules is refused as git only"      bash -c "cd '$PM' && bash '$UWT' new x --init-submodules >/dev/null 2>&1; [ \$? = 2 ]"

  # --verify: change a golden file behind matching stat data. Plain new trusts
  # the stat data, as cm does; --verify hashes and rolls back.
  f="$PGD/Assets/Scenes/A.unity"; m0="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f")"
  printf 'SCENE\n' > "$f"; touch -d "@$m0" "$f" 2>/dev/null || touch -t "$(date -r "$m0" +%Y%m%d%H%M.%S)" "$f"
  out="$(uwt new /main/v1 --verify --path "$ROOT/uwtp-v1" --json 2>/dev/null)"; rc=$?
  check "--verify catches content changed behind matching stat data (exit 2)" [ $rc = 2 ]
  check "and rolls back: no directory, no registration, no branch" \
        bash -c "[ ! -e '$ROOT/uwtp-v1' ] && ! MSYS_NO_PATHCONV=1 cm ls / --tree='br:/main/v1@$PR' >/dev/null 2>&1"
  ! registered "$ROOT/uwtp-v1" && pass "and cm does not list it" || fail "and cm does not list it"
  uwt seed "$PM" --force >/dev/null 2>&1
  out="$(uwt new /main/v2 --verify --path "$ROOT/uwtp-v2" --json 2>/dev/null)"; rc=$?
  check "--verify on a sound golden passes"             json_is 'd["value"]["verified"] is True' <<<"$out"
  # EOL conversion rewrites text on disk: the server's hashes cannot verify it.
  printf '.txt auto\n' > "$PM/eolconversion.conf"
  out="$(uwt new /main/v3 --verify --path "$ROOT/uwtp-v3" 2>&1)"; rc=$?
  check "--verify refuses under eolconversion.conf, before creating anything" bash -c "[ $rc = 2 ] && [ ! -e '$ROOT/uwtp-v3' ]"
  check "and names the file"                            grep -q 'eolconversion.conf' <<<"$out"
  rm -f "$PM/eolconversion.conf"

  # A workspace made by hand finds the golden through the repo's workspaces.
  pcm workspace create uwtp-hand "$(pwp "$ROOT/uwtp-hand")" "$PR" >/dev/null 2>&1
  pcm update "$(pwp "$ROOT/uwtp-hand")" >/dev/null 2>&1
  out="$(uwt hydrate "$ROOT/uwtp-hand" 2>&1)"; rc=$?
  check "hydrate in a hand-made workspace finds the golden" bash -c "[ $rc = 0 ] && [ -s '$ROOT/uwtp-hand/Library/ArtifactDB' ]"

  out="$(cd "$PT1" && uwt list --json 2>/dev/null)"; rc=$?
  check "list --json from a created workspace exits 0"  [ $rc = 0 ]
  check "it shows main first and every workspace of the repo" \
        json_is 'd["value"][0]["main"] and len(d["value"]) == 7 and any(w["branch"] == "/main/task1" and w["library"] == "uwt" for w in d["value"])' <<<"$out"

  out="$(uwt measure --json 2>/dev/null)"; rc=$?
  check "measure covers the workspaces and the golden"  json_is 'any(t["name"]=="golden" for t in d["value"]["trees"]) and len(d["value"]["trees"]) == 8' <<<"$out"

  # The same repository under another server spec is the same repository. The
  # local server also answers as localhost:8084, where it is set up that way.
  if [ "$PS" = local ] && [ "$(pcm repository list localhost:8084 --format='{repguid}' 2>/dev/null | tr -d '\r' | sort)" = "$(pcm repository list local --format='{repguid}' 2>/dev/null | tr -d '\r' | sort)" ]; then
    pcm workspace create uwtp-alias "$(pwp "$ROOT/uwtp-alias")" "${PR%@*}@localhost:8084" >/dev/null 2>&1
    out="$(cd "$PM" && uwt list --json 2>/dev/null)"
    check "list counts a workspace that names the server differently" json_is 'len(d["value"]) == 8' <<<"$out"
    pcm workspace delete "$(pwp "$ROOT/uwtp-alias")" >/dev/null 2>&1; rm -rf "$ROOT/uwtp-alias"
  else
    skip "server alias (needs the local server reachable as localhost:8084)"
  fi

  uwt remove "$PM" >/dev/null 2>&1; rc=$?
  check "remove refuses the main workspace (exit 2)"    bash -c "[ $rc = 2 ] && [ -d '$PM/.plastic' ]"
  echo p > "$ROOT/uwtp-feat/private.txt"
  uwt remove "$ROOT/uwtp-feat" >/dev/null 2>&1; rc=$?
  check "remove refuses a private file without --force" bash -c "[ $rc = 2 ] && [ -d '$ROOT/uwtp-feat' ]"
  pcm checkout "$(pwp "$PT1/Assets/Scenes/A.unity")" >/dev/null 2>&1
  uwt remove "$PT1" >/dev/null 2>&1; rc=$?
  check "remove refuses a checkout without --force"     bash -c "[ $rc = 2 ] && [ -d '$PT1' ]"
  out="$(uwt remove "$PT1" --force --json 2>/dev/null)"; rc=$?
  check "remove --force undoes the checkout and removes" bash -c "[ $rc = 0 ] && [ ! -e '$PT1' ]"
  ! registered "$PT1" && pass "the workspace is unregistered" || fail "the workspace is unregistered"
  check "the branch is kept"                            pbranch /main/task1
  check "remove --json names the branch"                json_is 'd["value"]["branch"] == "/main/task1" and d["value"]["branch_deleted"] is False' <<<"$out"
  # --delete-branch: only a branch with no changesets that no other workspace is on.
  uwt new /main/del1 --path "$ROOT/uwtp-del1" >/dev/null 2>&1
  out="$(uwt remove "$ROOT/uwtp-del1" --delete-branch --json 2>/dev/null)"; rc=$?
  check "remove --delete-branch deletes a branch with no changesets" bash -c "[ $rc = 0 ] && ! MSYS_NO_PATHCONV=1 cm ls / --tree='br:/main/del1@$PR' >/dev/null 2>&1"
  check "and says so in --json"                         json_is 'd["value"]["branch_deleted"] is True' <<<"$out"
  out="$(uwt remove "$ROOT/uwtp-feat" --force --delete-branch 2>&1)"; rc=$?
  check "it keeps a branch with changesets, and still removes" bash -c "[ $rc = 0 ] && [ ! -e '$ROOT/uwtp-feat' ]"
  check "the branch with changesets is still there"     pbranch /main/feat
  check "and says why"                                  grep -q 'changeset' <<<"$out"
  uwt new /main/shared --path "$ROOT/uwtp-sh1" >/dev/null 2>&1; uwt new /main/shared --path "$ROOT/uwtp-sh2" >/dev/null 2>&1
  out="$(uwt remove "$ROOT/uwtp-sh1" --delete-branch 2>&1)"; rc=$?
  check "it keeps a branch another workspace is on"     bash -c "[ $rc = 0 ] && [ ! -e '$ROOT/uwtp-sh1' ] && [ -d '$ROOT/uwtp-sh2' ]"
  check "the shared branch is still there"              pbranch /main/shared
  check "and says which workspace"                      grep -q 'uwtp-sh2' <<<"$out"
  check "the main workspace is untouched"               bash -c "[ -d '$PM/.plastic' ] && [ \"$(pstat "$PM")\" = 0 ]"

  # A partial (Gluon) workspace: its wktree describes a subset.
  pcm workspace create uwtp-part "$(pwp "$ROOT/uwtp-part")" "$PR" >/dev/null 2>&1
  (cd "$ROOT/uwtp-part" && pcm partial configure +/ProjectSettings +/Assets >/dev/null 2>&1 \
     && mkdir -p Library && head -c 1000 /dev/urandom > Library/ArtifactDB)
  out="$(uwt seed "$ROOT/uwtp-part" 2>&1)"; rc=$?
  check "seed refuses a partial (Gluon) workspace"      [ $rc = 2 ]
  check "and says it is partial"                        grep -q 'partial' <<<"$out"

  # A project in a subdirectory of its workspace: the golden is that
  # directory, and cm writes what lies outside it.
  PR2="${PP}uwt-test-$$-sub@$PS"; PS2="$ROOT/uwtp-mono"
  pcm repository create "$PR2" >/dev/null 2>&1
  pcm workspace create uwtp-mono "$(pwp "$PS2")" "$PR2" >/dev/null 2>&1
  (
    cd "$PS2" || exit 1
    mkdir -p game/ProjectSettings game/Assets tools
    printf 'm_EditorVersion: 6000.7.0b1\n' > game/ProjectSettings/ProjectVersion.txt
    echo a > game/Assets/a.txt; echo root > README.md; echo t > tools/t.txt
    printf '/game/Library\n' > ignore.conf
    pcm checkin --all --private -c init >/dev/null 2>&1
    mkdir -p game/Library && head -c 1000 /dev/urandom > game/Library/ArtifactDB
  )
  out="$(uwt seed "$PS2/game" 2>&1)"; rc=$?
  check "seed of a project in a subdirectory records the prefix" bash -c "[ $rc = 0 ] && grep -qx 'prefix=game' '$PS2/.plastic/uwt/golden.txt'"
  out="$(cd "$PS2/game" && uwt new sub1 --path "$ROOT/uwtp-mono-sub1" 2>&1)"; rc=$?
  check "new clones it back to the same offset"         bash -c "[ $rc = 0 ] && [ -f '$ROOT/uwtp-mono-sub1/game/Assets/a.txt' ] && [ -s '$ROOT/uwtp-mono-sub1/game/Library/ArtifactDB' ]"
  check "and cm writes the files outside it"            exists "$ROOT/uwtp-mono-sub1/README.md" "$ROOT/uwtp-mono-sub1/tools/t.txt"
  check "with a clean status"                           [ "$(pstat "$ROOT/uwtp-mono-sub1")" = 0 ]
  # Its main workspace, and the golden with it, deleted by hand.
  pcm workspace delete "$(pwp "$PS2")" >/dev/null 2>&1; rm -rf "$PS2"
  uwt remove "$ROOT/uwtp-mono-sub1" >/dev/null 2>&1; rc=$?
  check "remove takes a workspace whose main is gone"   bash -c "[ $rc = 0 ] && [ ! -e '$ROOT/uwtp-mono-sub1' ]"

  cd "$ROOT"; pl_sweep
fi

# ------------------------------------------------------------------ done
printf '\n%d passed, %d failed, %d skipped   (fixtures in %s)\n' "$PASS" "$FAILN" "$SKIPN" "$ROOT"
[ "$FAILN" = 0 ]
