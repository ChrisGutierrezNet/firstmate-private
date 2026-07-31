#!/usr/bin/env bash
# tests/fm-project-retire.test.sh - behavior tests for the guarded
# project-retirement owner, bin/fm-project-retire.sh.
#
# Every fixture is built in a fresh temp root with its own fake firstmate home,
# its own bare upstream, and its own fake /proc. No test reads, references, or
# mutates any real project tree, Treehouse pool, or fleet home.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RETIRE="$ROOT/bin/fm-project-retire.sh"
fm_git_identity

T=
OUT=
RC=0

# new_fixture: fresh temp root with
#   $T/upstream.git       bare origin
#   $T/seed               working clone used to publish upstream commits
#   $T/home               fake firstmate home (FM_ROOT_OVERRIDE / FM_HOME)
#   $T/approved           approved retirement boundary
#   $T/approved/legacy    retirement root, holding clone/
#   $T/approved/pool/1/clone   linked pool worktree of that clone
#   $T/proc               fake process table (empty by default)
new_fixture() {
  T=$(fm_test_tmproot fm-project-retire)
  mkdir -p "$T"
  # fm_test_tmproot registers its cleanup inside a command-substitution subshell,
  # so re-register in this shell and keep one EXIT trap that really fires.
  FM_TEST_CLEANUP_DIRS+=("$T")
  trap fm_test_cleanup EXIT
  T=$(cd "$T" && pwd -P)
  mkdir -p "$T/home/data" "$T/home/state" "$T/home/bin" "$T/approved/legacy" "$T/approved/pool" "$T/proc"
  : > "$T/home/AGENTS.md"
  git init -q --bare -b main "$T/upstream.git"
  git init -q -b main "$T/seed"
  printf 'seed\n' > "$T/seed/a.txt"
  git -C "$T/seed" add a.txt
  git -C "$T/seed" commit -qm initial
  git -C "$T/seed" remote add origin "file://$T/upstream.git"
  git -C "$T/seed" push -q origin main
  git clone -q "file://$T/upstream.git" "$T/approved/legacy/clone"
  git -C "$T/approved/legacy/clone" worktree add -q -b wt "$T/approved/pool/1/clone" main
}

# publish <subject> <file> <content>: land a commit on the bare upstream.
publish() {
  printf '%s\n' "$3" > "$T/seed/$2"
  git -C "$T/seed" add "$2"
  git -C "$T/seed" commit -qm "$1"
  git -C "$T/seed" push -q origin main
}

run_retire() {
  set +e
  OUT=$(FM_ROOT_OVERRIDE="$T/home" FM_HOME="$T/home" FM_RETIRE_PROC_ROOT="$T/proc" \
    "$RETIRE" "$@" 2>&1)
  RC=$?
  set -e
}

# preflight runs the fixture's standard flag set: root, proven pool, boundary.
preflight() {
  run_retire --root "$T/approved/legacy" --pool "$T/approved/pool" \
    --boundary "$T/approved" --preflight
}

plan_id_of() {
  printf '%s\n' "$OUT" | sed -n 's/^PLAN-ID: //p'
}

# --- usage contract ---------------------------------------------------------

new_fixture
run_retire --help
expect_code 0 "$RC" "--help exits 0"
assert_contains "$OUT" "the single guarded owner" "--help prints the contract"

run_retire
expect_code 2 "$RC" "no arguments is a usage error"

run_retire --root approved/legacy --boundary "$T/approved" --preflight
expect_code 2 "$RC" "a relative root is a usage error"
assert_contains "$OUT" "must be an absolute path" "relative root names the absolute-path rule"

run_retire --root "$T/approved/legacy/../legacy" --boundary "$T/approved" --preflight
expect_code 2 "$RC" "an unnormalized root is a usage error"

run_retire --root "$T/approved/legacy" --preflight
expect_code 2 "$RC" "a missing boundary is a usage error"
assert_contains "$OUT" "--boundary" "missing boundary names the flag"

run_retire --root "$T/approved/legacy" --boundary "$T/approved" --execute --confirm-root "$T/approved/legacy"
expect_code 2 "$RC" "--execute without --confirm-plan is a usage error"

run_retire --root "$T/approved/legacy" --boundary "$T/approved" --execute \
  --confirm-root "$T/approved" --confirm-plan deadbeef
expect_code 2 "$RC" "--confirm-root must repeat --root exactly"
assert_contains "$OUT" "does not repeat --root" "confirm-root mismatch is explicit"

run_retire --root "$T/approved/legacy" --boundary "$T/approved" --preflight --execute
expect_code 2 "$RC" "--preflight and --execute together is a usage error"
pass "usage contract requires an explicit absolute root, boundary, and confirmations"

# --- path safety ------------------------------------------------------------

run_retire --root "$T/approved/missing" --boundary "$T/approved" --preflight
expect_code 1 "$RC" "a missing root refuses"
assert_contains "$OUT" "does not exist" "missing root says so"

ln -s "$T/approved/legacy" "$T/approved/legacy-link"
run_retire --root "$T/approved/legacy-link" --boundary "$T/approved" --preflight
expect_code 1 "$RC" "a symlinked root refuses"
assert_contains "$OUT" "is a symlink" "symlinked root says so"

run_retire --root /tmp --boundary "$T/approved" --preflight
expect_code 1 "$RC" "a shallow root refuses"
assert_contains "$OUT" "too close to the filesystem root" "shallow root says so"
pass "unsafe, symlinked, and non-canonical roots refuse"

# --- protected fleet paths --------------------------------------------------

new_fixture
run_retire --root "$T/home" --boundary "$T" --preflight
expect_code 1 "$RC" "the primary firstmate home refuses"
assert_contains "$OUT" "the primary firstmate home" "home removal names the home"

mkdir -p "$T/home/projects/alpha"
printf -- '- alpha [no-mistakes] - a registered project (added 2026-07-30)\n' > "$T/home/data/projects.md"
run_retire --root "$T/home/projects/alpha" --boundary "$T/home/projects" --preflight
expect_code 1 "$RC" "a registered project clone inside the primary home refuses"
assert_contains "$OUT" "the primary firstmate home" "nesting inside the home is the refusal"

new_fixture
mkdir -p "$T/approved/legacy/inner-home/state"
: > "$T/approved/legacy/inner-home/AGENTS.md"
OUT=$(FM_ROOT_OVERRIDE="$T/approved/legacy/inner-home" FM_HOME="$T/approved/legacy/inner-home" \
  FM_RETIRE_PROC_ROOT="$T/proc" "$RETIRE" --root "$T/approved/legacy" \
  --boundary "$T/approved" --preflight 2>&1) && RC=0 || RC=$?
expect_code 1 "$RC" "a tree containing the primary home refuses"
assert_contains "$OUT" "the primary firstmate home" "containment refusal names the home"
pass "the primary home and anything nested in or containing it refuses"

new_fixture
printf -- '- sm - a second mate (home: %s; scope: x; projects: y; added 2026-07-30)\n' \
  "$T/approved/legacy/sm-home" > "$T/home/data/secondmates.md"
preflight
expect_code 1 "$RC" "a tree containing a registered secondmate home refuses"
assert_contains "$OUT" "registered secondmate home" "secondmate refusal names the registration"
pass "registered secondmate homes inside the tree refuse"

new_fixture
printf -- '- alpha [local-only] - legacy copy at %s (added 2026-07-30)\n' \
  "$T/approved/legacy/clone" > "$T/home/data/projects.md"
preflight
expect_code 1 "$RC" "a tree still named by the registry refuses"
assert_contains "$OUT" "retire the registry entry first" "registry refusal says what to do"
pass "a current registry reference refuses"

# --- boundary contract ------------------------------------------------------

new_fixture
run_retire --root "$T/approved/legacy" --pool "$T/approved/pool" --boundary "$T" --preflight
expect_code 1 "$RC" "a boundary containing the primary home refuses"
assert_contains "$OUT" "retirement boundary" "boundary refusal names the boundary"

mkdir -p "$T/elsewhere"
run_retire --root "$T/approved/legacy" --pool "$T/approved/pool" --boundary "$T/elsewhere" --preflight
expect_code 1 "$RC" "a root outside every boundary refuses"
assert_contains "$OUT" "outside every approved retirement boundary" "boundary refusal is explicit"
pass "the approved retirement boundary is enforced in both directions"

# --- live references --------------------------------------------------------

new_fixture
fm_write_meta "$T/home/state/task-a.meta" \
  "window=firstmate:fm-task-a" \
  "worktree=$T/approved/pool/1/clone" \
  "project=$T/approved/legacy/clone"
preflight
expect_code 1 "$RC" "a recorded task reference refuses"
assert_contains "$OUT" "recorded task task-a" "task refusal names the task"
pass "a live task reference refuses"

new_fixture
mkdir -p "$T/sm-home/state"
printf -- '- sm - a second mate (id is legacy) covering x (home: %s; scope: y; added 2026-07-30)\n' \
  "$T/sm-home" > "$T/home/data/secondmates.md"
fm_write_meta "$T/sm-home/state/task-b.meta" \
  "window=firstmate:fm-task-b" \
  "worktree=$T/approved/pool/1/clone"
preflight
expect_code 1 "$RC" "a task recorded by a secondmate whose registry line has prose parentheses refuses"
assert_contains "$OUT" "recorded task task-b" "the parenthetical registry line still yields its state directory"
pass "a secondmate home is found even behind prose parentheses in its registry line"

new_fixture
mkdir -p "$T/proc/4242"
ln -s "$T/approved/legacy/clone" "$T/proc/4242/cwd"
preflight
expect_code 1 "$RC" "a live process working inside the tree refuses"
assert_contains "$OUT" "live process 4242" "process refusal names the pid"

new_fixture
mkdir -p "$T/proc/4243"
ln -s "$T/approved/pool/1/clone" "$T/proc/4243/cwd"
preflight
expect_code 1 "$RC" "a live process working inside the proven pool refuses"
assert_contains "$OUT" "legacy pool root" "the pool process refusal names the pool as the target"
pass "a live process current directory refuses"

new_fixture
mkdir -p "$T/proc/11" "$T/proc/12" "$T/proc/13"
ln -s "$T/seed" "$T/proc/11/cwd"
ln -s "$T/home" "$T/proc/12/cwd"
preflight
expect_code 0 "$RC" "processes outside the retirement tree do not refuse"
assert_contains "$OUT" "inspected 2 live process working directories (1 not inspectable" \
  "the process table is walked once, so --pool does not double the reported coverage"
pass "live-process coverage counts each process exactly once across every removal target"

# --- git inventory ----------------------------------------------------------

new_fixture
mkdir -p "$T/approved/plain/sub"
run_retire --root "$T/approved/plain" --boundary "$T/approved" --preflight
expect_code 1 "$RC" "a tree with no checkout refuses"
assert_contains "$OUT" "no git checkout found" "empty-tree refusal is explicit"

new_fixture
printf 'edited\n' >> "$T/approved/legacy/clone/a.txt"
preflight
expect_code 1 "$RC" "a dirty checkout refuses"
assert_contains "$OUT" "dirty or untracked files" "dirty refusal is explicit"
assert_contains "$OUT" "a.txt" "dirty refusal names the file"

new_fixture
printf 'scratch\n' > "$T/approved/pool/1/clone/scratch.txt"
preflight
expect_code 1 "$RC" "an untracked file refuses"
assert_contains "$OUT" "scratch.txt" "untracked refusal names the file"
pass "dirty and untracked files refuse"

new_fixture
run_retire --root "$T/approved/legacy" --boundary "$T/approved" --preflight
expect_code 1 "$RC" "a linked worktree outside the root refuses without --pool"
assert_contains "$OUT" "outside the retirement tree" "linked-worktree refusal is explicit"

new_fixture
git -C "$T/approved/legacy/clone" worktree lock "$T/approved/pool/1/clone"
preflight
expect_code 1 "$RC" "a locked worktree refuses"
assert_contains "$OUT" "locked (in use) worktree" "locked-worktree refusal is explicit"
pass "linked and in-use worktrees refuse"

new_fixture
git -C "$T/approved/legacy/clone" worktree add -q -b gone "$T/approved/legacy/gone" main
rm -rf "$T/approved/legacy/gone"
preflight
expect_code 1 "$RC" "a stale worktree registration refuses"
assert_contains "$OUT" "stale worktree registration" "stale-registration refusal is explicit"
pass "a stale worktree registration refuses instead of being pruned away"

new_fixture
git init -q --bare -b main "$T/approved/legacy/orphan.git"
git -C "$T/approved/legacy/orphan.git" fetch -q "file://$T/upstream.git" "main:refs/heads/main"
preflight
expect_code 1 "$RC" "a bare repository with no landing evidence refuses"
assert_contains "$OUT" "orphan.git" "the bare repository is inventoried, not skipped"
assert_contains "$OUT" "no remote" "the bare repository needs its own landing evidence"

new_fixture
git init -q -b main --separate-git-dir "$T/approved/legacy/detached.git" "$T/approved/legacy/detached-work"
rm -rf "$T/approved/legacy/detached-work"
preflight
expect_code 1 "$RC" "a detached non-bare git directory is inspected, not skipped"
assert_contains "$OUT" "detached.git" "the detached git directory is inventoried"
assert_contains "$OUT" "no remote" "the detached git directory needs its own landing evidence"
pass "a standalone repository with no checkout is still inventoried, bare or not"

new_fixture
mkdir -p "$T/approved/pool/2"
git init -q -b main "$T/outside-repo"
printf 'x\n' > "$T/outside-repo/x.txt"
git -C "$T/outside-repo" add x.txt
git -C "$T/outside-repo" commit -qm outside
git -C "$T/outside-repo" worktree add -q -b y "$T/approved/pool/2/outside" main
preflight
expect_code 1 "$RC" "a pool member of a foreign repository refuses"
assert_contains "$OUT" "outside the retirement root" "foreign pool member refusal is explicit"

new_fixture
rm -rf "$T/approved/pool"
mkdir -p "$T/approved/emptypool"
run_retire --root "$T/approved/legacy" --pool "$T/approved/emptypool" \
  --boundary "$T/approved" --preflight
expect_code 1 "$RC" "an unproven pool refuses"
assert_contains "$OUT" "cannot be proven linked" "unproven pool refusal is explicit"
pass "the legacy pool must be proven linked to the retirement root"

# --- landing evidence -------------------------------------------------------

new_fixture
git -C "$T/approved/legacy/clone" remote remove origin
preflight
expect_code 1 "$RC" "a repository with no remote refuses"
assert_contains "$OUT" "no remote" "missing-remote refusal is explicit"

new_fixture
git -C "$T/approved/legacy/clone" remote set-url origin "file://$T/no-such-upstream.git"
preflight
expect_code 1 "$RC" "a failed evidence refresh refuses"
assert_contains "$OUT" "cannot refresh landing evidence" "stale-evidence refusal is explicit"
pass "incomplete or unrefreshable landing evidence refuses"

new_fixture
git clone -q --bare "file://$T/upstream.git" "$T/approved/legacy/mirror.git"
git -C "$T/approved/legacy/clone" remote set-url origin "file://$T/approved/legacy/mirror.git"
preflight
expect_code 1 "$RC" "landing evidence inside the retirement root refuses"
assert_contains "$OUT" "would be destroyed by this retirement" "the doomed-evidence refusal explains itself"
assert_contains "$OUT" "mirror.git" "the doomed-evidence refusal names the remote it distrusts"
assert_present "$T/approved/legacy/clone" "nothing is removed when the evidence is doomed"

new_fixture
git -C "$T/approved/legacy/clone" remote set-url origin "$T/approved/legacy/clone"
preflight
expect_code 1 "$RC" "a self-remote is not landing evidence"
assert_contains "$OUT" "would be destroyed by this retirement" "the self-remote refusal explains itself"

new_fixture
git -C "$T/approved/legacy/clone" remote set-url origin "file://$T/approved/pool/mirror.git"
preflight
expect_code 1 "$RC" "landing evidence inside the proven pool refuses"
assert_contains "$OUT" "legacy pool root" "the pool-evidence refusal names the pool"
pass "landing evidence that lives inside a removal target refuses"

new_fixture
mkdir -p "$T/approved/legacy/clone/.git/objects/ab"
printf 'not an object at all' \
  > "$T/approved/legacy/clone/.git/objects/ab/1234567890123456789012345678901234abcd"
preflight
expect_code 1 "$RC" "an unreadable object store refuses"
assert_contains "$OUT" "cannot check the object store" "the fsck refusal is explicit"
assert_present "$T/approved/legacy/clone" "a corrupt object store removes nothing"
pass "a git fsck failure refuses instead of reporting no unreachable commits"

new_fixture
git -C "$T/approved/legacy/clone" checkout -q -b unlanded main
printf 'only here\n' > "$T/approved/legacy/clone/local.txt"
git -C "$T/approved/legacy/clone" add local.txt
git -C "$T/approved/legacy/clone" commit -qm "local only work"
git -C "$T/approved/legacy/clone" checkout -q main
preflight
expect_code 1 "$RC" "an unpushed, unlanded branch refuses"
assert_contains "$OUT" "unlanded branch unlanded" "unlanded refusal names the branch"

new_fixture
publish "the real change" real.txt "authoritative"
git -C "$T/approved/legacy/clone" checkout -q -b lookalike main
printf 'something else entirely\n' > "$T/approved/legacy/clone/real.txt"
git -C "$T/approved/legacy/clone" add real.txt
git -C "$T/approved/legacy/clone" commit -qm "the real change"
git -C "$T/approved/legacy/clone" checkout -q main
preflight
expect_code 1 "$RC" "a matching commit subject is not landing proof"
assert_contains "$OUT" "unlanded branch lookalike" "subject-match refusal names the branch"
assert_contains "$OUT" "not patch-equivalent" "subject-match refusal explains the real test"
pass "unpushed work and lookalike subjects refuse"

new_fixture
git -C "$T/approved/legacy/clone" checkout -q -b scratch main
printf 'lost work\n' > "$T/approved/legacy/clone/lost.txt"
git -C "$T/approved/legacy/clone" add lost.txt
git -C "$T/approved/legacy/clone" commit -qm "work in progress"
git -C "$T/approved/legacy/clone" checkout -q main
git -C "$T/approved/legacy/clone" branch -qD scratch
preflight
expect_code 1 "$RC" "an unreachable unique commit refuses"
assert_contains "$OUT" "unreachable commit" "unreachable refusal is explicit"
pass "an unreachable unique commit refuses"

# --- successful preflight, including squash-landed history ------------------

new_fixture
git -C "$T/approved/legacy/clone" checkout -q -b feature main
printf 'one\n' > "$T/approved/legacy/clone/f1.txt"
git -C "$T/approved/legacy/clone" add f1.txt
git -C "$T/approved/legacy/clone" commit -qm "feature part one"
printf 'two\n' > "$T/approved/legacy/clone/f2.txt"
git -C "$T/approved/legacy/clone" add f2.txt
git -C "$T/approved/legacy/clone" commit -qm "feature part two"
git -C "$T/approved/legacy/clone" checkout -q main
printf 'one\n' > "$T/seed/f1.txt"
printf 'two\n' > "$T/seed/f2.txt"
git -C "$T/seed" add f1.txt f2.txt
git -C "$T/seed" commit -qm "squashed feature"
git -C "$T/seed" push -q origin main

preflight
expect_code 0 "$RC" "a clean, fully landed tree preflights"
assert_contains "$OUT" "branch feature landed" "the squash-landed branch is proven"
assert_contains "$OUT" "content already contained in" "squash landing uses content containment, not subjects"
assert_contains "$OUT" "PREFLIGHT OK" "preflight reports success"
assert_contains "$OUT" "rm -rf -- $T/approved/pool" "the plan names the pool removal"
assert_contains "$OUT" "rm -rf -- $T/approved/legacy" "the plan names the root removal"
assert_present "$T/approved/legacy/clone" "preflight removes nothing"
assert_present "$T/approved/pool/1/clone" "preflight leaves the pool alone"
PLAN_ID=$(plan_id_of)
[ -n "$PLAN_ID" ] || fail "preflight must print a plan id"
pass "preflight proves squash-landed history and removes nothing"

# --- execution requires a matching second confirmation ----------------------

run_retire --root "$T/approved/legacy" --pool "$T/approved/pool" --boundary "$T/approved" \
  --execute --confirm-root "$T/approved/legacy" --confirm-plan "not-the-plan-id"
expect_code 1 "$RC" "a wrong plan id refuses"
assert_contains "$OUT" "no longer matches the current evidence" "plan mismatch is explicit"
assert_present "$T/approved/legacy/clone" "a refused execution removes nothing"

git -C "$T/approved/legacy/clone" branch -q raced main
run_retire --root "$T/approved/legacy" --pool "$T/approved/pool" --boundary "$T/approved" \
  --execute --confirm-root "$T/approved/legacy" --confirm-plan "$PLAN_ID"
expect_code 1 "$RC" "evidence that changed after preflight refuses"
assert_contains "$OUT" "Nothing was removed" "the race refusal says nothing was removed"
assert_present "$T/approved/legacy/clone" "the raced tree survives"
assert_present "$T/approved/pool/1/clone" "the raced pool survives"
pass "execution refuses when evidence changed between approval and removal"

# --- successful bounded execution -------------------------------------------

preflight
expect_code 0 "$RC" "re-preflight after the race succeeds"
PLAN_ID=$(plan_id_of)
run_retire --root "$T/approved/legacy" --pool "$T/approved/pool" --boundary "$T/approved" \
  --execute --confirm-root "$T/approved/legacy" --confirm-plan "$PLAN_ID"
expect_code 0 "$RC" "the re-approved plan executes"
assert_contains "$OUT" "RETIRED: removed $T/approved/pool" "the pool is reported removed"
assert_contains "$OUT" "RETIRED: removed $T/approved/legacy" "the root is reported removed"
assert_absent "$T/approved/legacy" "the retirement root is gone"
assert_absent "$T/approved/pool" "the proven pool is gone"
assert_present "$T/approved" "the boundary itself is untouched"
assert_present "$T/home/AGENTS.md" "the firstmate home is untouched"
assert_present "$T/upstream.git" "the upstream repository is untouched"
assert_present "$T/seed/a.txt" "unrelated neighbours are untouched"
pass "execution removes exactly the approved tree and its proven pool"
