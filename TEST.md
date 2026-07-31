# TEST.md — end-to-end tests for `claudezero.sh`

Each scenario lives in its own folder under a single **isolated TESTROOT created
outside the repo** (via `mktemp -d`). They touch separate throwaway git repos, never
the project's own working tree or history, and can run concurrently.

- **A — parallel zeroing + restart-resume + timing.** 3 agents zero one todo in
  parallel; the script restarts each claude after every task (`CLAUDEZERO_MAX_LOOPS`)
  and resumes. Also asserts the per-instance execution-time report and env-hop.
- **B — startup-guard refusals.** dirty-tree and detached-HEAD both refuse to start.
  Pure bash, no claude, finishes in seconds.
- **C — merge-conflict path.** two tasks edit the same line; one merges, the other
  hits a conflict, and the zero run aborts cleanly leaving the base green and the branch for
  a human.
- **D — foreign check-off refusal + self-heal.** one agent is induced to tick a second
  task's box; `merge_task` refuses with a pointer and the agent self-heals (step 2.e).
- **E — timing accounting.** Deterministic, **no real claude** (a stub `claude` on PATH):
  per-instance in-flight credit routing + idempotency, and startup orphan-file GC.
- **G — token accounting.** Deterministic, **no real claude** (a stub that fabricates a
  session transcript and fires the real Stop hook): `requestId` dedupe, no double-count of
  the nested `iterations`/`cache_creation` fields, accumulation across restarts, and
  `Tokens: n/a` degradation.

Parallelism (A, C) is enforced with a **file-lock barrier**, not `sleep`, so the
proof is independent of claude startup/shutdown times.

**Isolation contract.** Nothing is written inside the project repo. All test repos,
their `../ts-*` worktrees, and all state live under `$TESTROOT` (outside the repo).
The only thing read from the repo is `claudezero.sh` itself (`$SCRIPT`). The final
residue check (Cleanup) proves the project repo was untouched.

**Run every step from the repo root** (the dir holding this file). `$(pwd)` there is
the repo; the tests themselves execute against `$TESTROOT`, never `$(pwd)`. An agent
reading this file can run it autonomously and report the results.

**Prerequisites:** `flock`, `uuidgen`, `timeout`, `git`, `date`, `find`, `stat`, `mv`
on PATH. A and C need real `claude` on PATH and the `suggest-compact` hook installed in
`~/.claude/settings.json` (claudezero.sh refuses to start without it — if A/C logs show
an immediate hook error, report "prerequisite missing — suggest-compact hook"). B, E, F and
G do **not** need real claude but still need `flock` and the `suggest-compact` hook (both
startup guards run before any claude launch; E/F/G supply a stub `claude` so claudezero
writes `zero.sh` and loops out at once). A missing hook makes them exit with the wrong
message and their assertions fail.

Inform about progress during the test; at the end return a summary report
of passes, fails, and causes.


---

## 0. Shared setup

Run once, from the repo root. Defines `REPO`/`SCRIPT` (the code under test) and a fresh
`TESTROOT` **outside** the repo, plus `write_gate` (A, C) and `ago` (E) helpers.

```bash
set -euo pipefail
REPO="$(pwd)"                                   # repo holding claudezero.sh (never written to)
SCRIPT="$REPO/claudezero.sh"
TESTROOT="$(mktemp -d "${TMPDIR:-/tmp}/claudezero-tests.XXXXXX")"   # isolated, outside the repo
TESTROOT="$(cd "$TESTROOT" && pwd -P)"          # canonical path: on macOS $TMPDIR is /var→/private/var; the root-guard compares $PWD to git's physical path, so an uncanonicalized /var path misfires "not at repo root" at the real root
echo "TESTROOT=$TESTROOT"

# touch-timestamp for N seconds ago, BSD (-v) or GNU (-d). Used by E.
ago(){ date -v-"$1"S +%Y%m%d%H%M.%S 2>/dev/null || date -d "-$1 sec" +%Y%m%d%H%M.%S; }

write_gate(){ cat > "$1" <<'EOF'
#!/usr/bin/env bash
# Barrier + latch: block until NEED distinct agents are simultaneously in-flight,
# then latch open so later rounds pass instantly. Proves real parallelism
# independent of claude startup/shutdown skew (a fast agent waits for the slow one).
set -euo pipefail
G="$(cd "$(dirname "$0")" && pwd)/gate"; mkdir -p "$G/inflight"
label="${1:?usage: gate.sh LABEL [NEED] [TRIES]}"; need="${2:-3}"; tries="${3:-400}"
touch "$G/inflight/$label"
i=0
while [ ! -f "$G/opened" ] && [ "$i" -lt "$tries" ]; do
  flock "$G/lock" bash -c 'n=$(ls "$1/inflight" 2>/dev/null | wc -l); [ "$n" -ge "$2" ] && : > "$1/opened"' _ "$G" "$need" || true
  [ -f "$G/opened" ] || sleep 0.3
  i=$((i+1))
done
rm -f "$G/inflight/$label"
[ -f "$G/opened" ]   # exit 0 only if the latch opened (NEED-way overlap proven)
EOF
chmod +x "$1"; }
```

---

## Scenario S — static check (shellcheck)   (no claude)

Lints claudezero.sh (S1) **and the scripts it emits at runtime** (S2). The emitted
scripts live in single-quoted heredocs, invisible to a lint of claudezero.sh — that
blind spot once shipped an unbalanced quote in `zero.sh`. `CLAUDEZERO_TEST_EMIT=1`
runs init for real in a throwaway repo (writes the scripts, exits before claude), then
we lint the actual files. `-e SC2016` mirrors `.github/check-embedded.sh`: single-quoted
`bash -c`/awk blobs are intentional. If `shellcheck` isn't on PATH, report **skipped**.

```sh
if command -v shellcheck >/dev/null; then
  shellcheck "$SCRIPT" && echo "S1 PASS — claudezero.sh clean" || echo "S1 FAIL — findings above"
  # emit in a subshell (init must run at the temp repo root); lint from HERE with absolute
  # paths — a version-manager shim (asdf/mise) re-resolves shellcheck by cwd, so cd'ing into
  # the temp repo (no .tool-versions) would break the shim, not the script.
  TS="$TESTROOT/S/repo"; mkdir -p "$TS"
  ( cd "$TS"; git init -q; git config user.email t@t.t; git config user.name test
    echo '- [ ] G noop' > todo.md; git add -A; git commit -qm init
    CLAUDEZERO_TEST_EMIT=1 bash "$SCRIPT" todo.md >/dev/null )
  rc=0
  for f in compact-exit-hook.sh zero.sh checkbox-merge.sh; do
    [ -f "$TS/.git/$f" ] || { echo "S2 FAIL — $f not emitted"; rc=1; continue; }
    shellcheck -e SC2016 "$TS/.git/$f" || rc=1
  done
  [ "$rc" = 0 ] && echo "S2 PASS — emitted scripts clean" || echo "S2 FAIL — findings above"
else
  echo "S SKIP — shellcheck not installed"
fi
```
- **S PASS** — S1 and S2 both PASS (claudezero.sh clean, all three emitted scripts clean).

---

## Scenario A — parallel zeroing + restart-resume + timing   `[$TESTROOT/A]`

`CLAUDEZERO_MAX_LOOPS=4` makes claudezero restart claude after each session; the `-t`
prompt forces **one task per session**, so completing all five *requires* restart +
resume — a broken restart would leave a missing/duplicate marker. The barrier
(`need=3`) proves 3-way overlap. The extra timing asserts confirm each instance printed
its own execution-time report and that `CLAUDEZERO_INSTANCE` reached `zero.sh`.

### Setup
```bash
T="$TESTROOT/A"; mkdir -p "$T/repo"
write_gate "$T/gate.sh"
cd "$T/repo"
git init -q; git config user.email t@t.t; git config user.name test
U=(); for i in 1 2 3 4 5; do U+=("$(uuidgen)"); done
: > todo.md
for i in 1 2 3 4 5; do
  echo "- [ ] T$i In your task worktree do IN ORDER: (a) run \`$T/gate.sh <your label>\` and wait for it to exit 0; (b) create file markers/${U[i-1]}.done whose only line is \`agent=<your label> task=T$i\`; (c) commit. If the gate command exits non-zero, STOP and report failure." >> todo.md
done
git add todo.md; git commit -qm todo
printf '%s\n' "${U[@]}" > "$T/uuids.txt"
```

### Run
```bash
cd "$T/repo"
run(){ timeout -k 10 480 env CLAUDEZERO_MAX_LOOPS=4 bash "$SCRIPT" todo.md \
  -t "You are agent $1. Process EXACTLY ONE unchecked task this session: do exactly what its line instructs (run the gate command it names and wait for that command to exit 0 before continuing), check it off, commit, and let the task merge. Then STOP — end the session without starting another task, so you can be restarted fresh for the next one. Any marker file must contain the single line: agent=$1 task=<that task's id>. Put $1 in every commit message." \
  > "$T/log_$1.txt" 2>&1; }
run AGENT_A & run AGENT_B & run AGENT_C &
wait
```

### Assert
```bash
cd "$T/repo"
for u in $(cat "$T/uuids.txt"); do [ -f "markers/$u.done" ] || echo "MISSING marker $u"; done
echo "--- markers (task -> agent) ---"; grep -h . markers/*.done 2>/dev/null | sort
echo "distinct agents : $(grep -h -o 'agent=[^ ]*' markers/*.done 2>/dev/null | sort -u | wc -l | tr -d ' ')"
echo "todos checked   : $(grep -c '^- \[x\]' todo.md)/5"
echo "git clean       : $([ -z "$(git status --porcelain)" ] && echo yes || echo no)"
echo "latch opened    : $([ -f "$T/gate/opened" ] && echo yes || echo no)"
echo "restarts (A/B/C): $(grep -c restarting "$T/log_AGENT_A.txt") $(grep -c restarting "$T/log_AGENT_B.txt") $(grep -c restarting "$T/log_AGENT_C.txt")"
# timing / per-instance isolation:
echo "instance ids    : $(grep -h -oE 'instance [^)]+' "$T"/log_AGENT_*.txt | sort -u | wc -l | tr -d ' ')"
echo "report labels   : $(grep -h -cE '  (Todos|ClaudeZero run loop):' "$T"/log_AGENT_A.txt | tr -d ' ')"
echo "stale loop line : $(grep -h -c 'Claude loops:' "$T"/log_AGENT_A.txt | tr -d ' ')  (want 0)"
echo "todos counted   : $(awk '/❄ TOTAL/{exit} /Todos:.*· [0-9]+ completed/{l=$0} END{print l}' "$T"/log_AGENT_A.txt)"
echo "TOTAL blocks    : $(grep -h -c '❄ TOTAL' "$T"/log_AGENT_*.txt | paste -sd' ' -)  (want 1 each — exit path)"
echo "zero.sh wrote files: $(ls "$T"/repo/.git 2>/dev/null | grep -c '^todos-seconds-')"
echo "zero.sh wrote counts: $(ls "$T"/repo/.git 2>/dev/null | grep -c '^todos-done-')"
```
- **Zero PASS** — all 5 markers present, `todos checked = 5/5`, `git clean = yes`.
- **Parallel PASS** — `latch opened = yes` AND `distinct agents = 3`.
- **Restart PASS** — restarts summed across the three logs ≥ 3.
- **Timing PASS** — `instance ids = 3` (each instance a distinct id → isolation), each
  agent's log shows the `Todos:` / `ClaudeZero run loop:` lines with `stale loop line = 0`,
  `todos counted` shows a non-zero `N completed` for an agent that merged, the per-agent
  counts sum to 5, and `zero.sh wrote files ≥ 1` / `zero.sh wrote counts ≥ 1`. Those last
  two are the **env-hop proof**: `zero.sh` only writes `todos-seconds-<base>-<id>` and
  `todos-done-<base>-<id>` when it received `CLAUDEZERO_INSTANCE` from claude's env. (An
  instance that merged 0 tasks writes no file, so the count can be < 3; ≥ 1 is the gate.)
- **Fleet PASS** — `TOTAL blocks = 1 1 1`: each agent ended its run with one fleet TOTAL block
  (the `todos counted` reading is taken from before it, so it stays the per-instance figure).

---

## Scenario B — startup-guard refusals   `[$TESTROOT/B]`   (no claude)

Four pristine repos: one with a dirty working tree, one on a detached HEAD, one clean
launched from a subdir, one clean launched from inside a leftover `../ts-*` task worktree.
Each must make claudezero refuse to start with the matching message and a non-zero exit.

### Setup
```bash
TB="$TESTROOT/B"
for name in dirty detached nested worktree; do
  mkdir -p "$TB/$name"
  ( cd "$TB/$name"; git init -q; git config user.email t@t.t; git config user.name test
    echo x > f; git add f; git commit -qm init
    echo "- [ ] G1 noop" > todo.md; git add todo.md; git commit -qm todo )
done
( cd "$TB/dirty";    echo change >> f )       # dirty working tree
( cd "$TB/detached"; git checkout -q --detach )
mkdir -p "$TB/nested/sub"                      # clean repo; we launch from this subdir
# leftover claim worktree, exactly what a crashed peer abandons: branch <base>-task-1 + ../ts-*
( cd "$TB/worktree"; base="$(git rev-parse --abbrev-ref HEAD)"
  git worktree add -q "$TB/ts-$base-task-1-dead" -b "$base-task-1" "$base" )
```

### Run + assert
```bash
cd "$TB/dirty"
if out=$(timeout 20 bash "$SCRIPT" todo.md -t x 2>&1); then rc=0; else rc=$?; fi
{ [ "$rc" != 0 ] && echo "$out" | grep -qi dirty; } && echo "B1 dirty-guard PASS" || echo "B1 FAIL (rc=$rc): $out"

cd "$TB/detached"
if out=$(timeout 20 bash "$SCRIPT" todo.md -t x 2>&1); then rc=0; else rc=$?; fi
{ [ "$rc" != 0 ] && echo "$out" | grep -qi 'detached HEAD'; } && echo "B2 detached-guard PASS" || echo "B2 FAIL (rc=$rc): $out"

cd "$TB/nested/sub"                            # clean repo, but not at the repo root
if out=$(timeout 20 bash "$SCRIPT" ../todo.md -t x 2>&1); then rc=0; else rc=$?; fi
{ [ "$rc" != 0 ] && echo "$out" | grep -qi 'not at.*repo root'; } && echo "B3 subdir-guard PASS" || echo "B3 FAIL (rc=$rc): $out"

cd "$TB/ts-$(git -C "$TB/worktree" rev-parse --abbrev-ref HEAD)-task-1-dead"   # a peer's claim worktree
if out=$(timeout 20 bash "$SCRIPT" todo.md -t x 2>&1); then rc=0; else rc=$?; fi
{ [ "$rc" != 0 ] && echo "$out" | grep -qi 'not at.*repo root'; } && echo "B4 worktree-guard PASS" || echo "B4 FAIL (rc=$rc): $out"
git -C "$TB/worktree" branch --list '*-task-*-task-*' | grep -q . && echo "B4 FAIL: second-claim branch created"
```
- **B PASS** — B1, B2, B3, and B4 all report PASS (non-zero exit + the expected message,
  before any claude launch), and no `*-task-*-task-*` branch exists. B3 proves the
  worktree-path assumption is enforced: a subdir launch refuses rather than misfiring
  `../ts-*` paths. B4 proves the same for a launch *inside* a leftover claim worktree, where
  the base branch would otherwise be poisoned to a peer's claim and both instances would take
  the same todo (BUG-014).

---

## Scenario C — merge-conflict path   `[$TESTROOT/C]`

Two tasks overwrite the same line of `conflict.txt`. The barrier (`need=2`) forces
both agents to branch off the same base before either merges, so the second merge is
a guaranteed modify/modify conflict. Zero mode must abort it, keep the base green, and
leave the losing branch for a human (zero algorithm, step 2.e).

### Setup
```bash
TC="$TESTROOT/C"; mkdir -p "$TC/repo"
write_gate "$TC/gate.sh"
cd "$TC/repo"
git init -q; git config user.email t@t.t; git config user.name test
echo INIT > conflict.txt
: > todo.md
for i in 1 2; do
  echo "- [ ] C$i In your task worktree do IN ORDER: (a) run \`$TC/gate.sh <your label> 2\` and wait for it to exit 0; (b) overwrite conflict.txt so its ONLY line is \`owner=<your label>\`; (c) commit." >> todo.md
done
git add conflict.txt todo.md; git commit -qm init
```

### Run
```bash
cd "$TC/repo"
runc(){ timeout -k 10 240 env CLAUDEZERO_MAX_LOOPS=1 bash "$SCRIPT" todo.md \
  -t "You are agent $1. Do exactly what the task line instructs (run its gate command and wait for exit 0, make the edit, commit). Follow the zero algorithm's merge-failure handling: if your merge fails, STOP and report the conflicting task and its worktree to the human." \
  > "$TC/log_$1.txt" 2>&1; }
runc AGENT_A & runc AGENT_B &
wait
```

### Assert
```bash
cd "$TC/repo"
echo "base clean        : $([ -z "$(git status --porcelain)" ] && echo yes || echo no)"
echo "merge in progress : $([ -e .git/MERGE_HEAD ] && echo yes || echo no)"
echo "todos checked     : $(grep -c '^- \[x\]' todo.md)/2"
echo "conflict.txt      : $(cat conflict.txt)"
echo "leftover branches :"; git branch --list '*-task-*'
grep -Eril 'conflict|merge fail|resolve|stop' "$TC"/log_*.txt >/dev/null && echo "log notes conflict: yes" || echo "log notes conflict: no"
```
- **C PASS** — `base clean = yes`, `merge in progress = no`, `todos checked = 1/2`
  (only the winner merged), exactly **one** leftover `*-task-*` branch (the conflicted
  one kept for the human), and a log notes the conflict/stop.

---

## Scenario D — foreign check-off refusal + self-heal   `[$TESTROOT/D]`

One agent, two tasks. The `-t` prompt **induces** the agent to tick a SECOND checkbox
(a task it does not own) and ignore step 2.d's touch-no-other-line rule, so the foreign tick
reaches the merge. `merge_task` enforces the one-box invariant on **every** merge (not
just conflicting ones), refuses with a `checkbox-merge: refused` pointer listing the
offending `file:line`s, and step 2.e self-heals: uncheck the foreign line, amend, retry —
then the merge lands. No parallelism, no gate; a single instance triggers it because the
branch carries two check-offs vs its fork point.

### Setup
```bash
H="$TESTROOT/D"; mkdir -p "$H/repo"
cd "$H/repo"
git init -q -b master; git config user.email t@t.t; git config user.name test
U1=$(uuidgen); U2=$(uuidgen)
: > todo.md
echo "- [ ] T1 Create file markers/$U1.done with the single line \`agent=<label> task=T1\`, then commit." >> todo.md
echo "- [ ] T2 Create file markers/$U2.done with the single line \`agent=<label> task=T2\`, then commit." >> todo.md
git add todo.md; git commit -qm todo
printf '%s\n%s\n' "$U1" "$U2" > "$H/uuids.txt"
```

### Run
```bash
cd "$H/repo"
timeout -k 10 300 env CLAUDEZERO_MAX_LOOPS=3 bash "$SCRIPT" todo.md \
  -t "You are agent HEAL. TEST INDUCEMENT for step d only: after doing your acquired task, ALSO tick the OTHER task's checkbox to [x] in todo.md, and IGNORE step 2.d's touch-no-other-line rule — commit both ticks on your task branch. Then proceed to the merge (step 2.e) normally and follow its instructions to the letter." \
  > "$H/log.txt" 2>&1 || true
```

### Assert
```bash
cd "$H/repo"
echo "refusal fired  : $(grep -c 'checkbox-merge: refused' "$H/log.txt")"
echo "todos checked  : $(grep -c '^- \[x\]' todo.md)/2"
echo "markers        : $(ls markers 2>/dev/null | wc -l | tr -d ' ')/2"
echo "phantom check  : $([ "$(grep -c '^- \[x\]' todo.md)" = "$(ls markers 2>/dev/null | wc -l | tr -d ' ')" ] && echo none || echo YES)"
echo "git clean      : $([ -z "$(git status --porcelain)" ] && echo yes || echo no)"
echo "leftover brnch : $(git branch --list 'master-task-*' | wc -l | tr -d ' ')"
```
- **D PASS** — `phantom check = none`: every checked task has a real `markers/<uuid>.done`.
  Ideally `todos checked = 2/2` with `markers = 2/2` (guard refused the double-tick, agent
  self-healed, then completed both), `git clean = yes`, no leftover branches.
- **D FAIL** — a box is checked with no marker (`phantom check = YES`): the guard let a
  foreign tick through (as happened when the check lived only in the conflict-only driver).
- `refusal fired` is **best-effort only**, not the gate: the refusal text prints to the
  agent's `zero.sh merge` tool output, not claudezero's stdout log, so this grep often
  reads 0 even on a correct self-heal. Trust `phantom check`, and read the agent's own
  narration in `log.txt` for the refuse→uncheck→amend→retry trace.

---

## Scenario E — timing accounting   `[$TESTROOT/E]`   (stub claude, deterministic)

The per-instance timing logic is deterministic and needs no real claude — a stub
`claude` on PATH lets claudezero write `zero.sh` and loop out immediately, then we
exercise the accounting paths directly. Covers the two bugs found while building the
feature: crediting must work when called **without** a claude ancestor (lazy
`ensure_owner`), and the in-flight sweep must be **idempotent** and route credit to the
**owner** instance, not the caller. E2 covers startup GC of orphan time-files.

### Setup (shared stub + repo)
```bash
TE="$TESTROOT/E"; mkdir -p "$TE/repo" "$TE/bin"
cat > "$TE/bin/claude" <<'EOF'
#!/usr/bin/env bash
exit 0                     # stub: do nothing; claudezero still writes zero.sh + registers instance
EOF
chmod +x "$TE/bin/claude"
cd "$TE/repo"
git init -q -b main; git config user.email t@t.t; git config user.name test
printf -- '- [ ] E1 x\n' > todo.md; git add -A; git commit -qm init
# bootstrap: real claudezero writes .git/zero.sh, stub claude exits, loop ends (MAX_LOOPS=1)
PATH="$TE/bin:$PATH" timeout 30 env CLAUDEZERO_MAX_LOOPS=1 bash "$SCRIPT" todo.md -t x > "$TE/boot.log" 2>&1 || true
ZERO="$(cd "$(git rev-parse --git-dir)" && pwd)/zero.sh"
GC="$(cd "$(git rev-parse --git-common-dir)" && pwd)"
echo "E0 zero.sh built : $([ -x "$ZERO" ] && echo yes || echo NO)"
```

### E1 — in-flight credit: routes to owner, no-ancestor-safe, idempotent
```bash
cd "$TE/repo"
# fabricate an orphaned in-flight worktree: dead owner (pid 999999) of instance A,
# acquired 100s ago, last file activity 60s ago → expected credit ≈ 40s.
git worktree add -q "$TE/wt-E1" -b "main-task-E1" main
WT="$(cd "$TE/wt-E1" && pwd)"
find "$WT" -type f -not -path '*/.git/*' -exec touch -t "$(ago 100)" {} +
printf '%s\n%s\n%s\n%s\n' 999999 fake "$(( $(date +%s) - 100 ))" A > "$WT/.owner"
touch -t "$(ago 60)" "$WT/worked.txt"
# credit AS instance B, with NO claude ancestor → must credit A (owner line4), not B
CLAUDEZERO_INSTANCE=B "$ZERO" credit_inflight_time; rc1=$?
a1=$(cat "$GC/todos-seconds-main-A" 2>/dev/null || echo MISSING)
CLAUDEZERO_INSTANCE=B "$ZERO" credit_inflight_time            # second pass must be a no-op
a2=$(cat "$GC/todos-seconds-main-A" 2>/dev/null || echo MISSING)
echo "E1 exit (no anc) : $rc1  (want 0 — lazy ensure_owner, not FATAL 3)"
echo "E1 credited A    : $a1  (want ~40; 30..70 ok)"
echo "E1 idempotent    : $([ "$a1" = "$a2" ] && echo yes || echo "no ($a1 -> $a2)")"
echo "E1 B untouched   : $([ -f "$GC/todos-seconds-main-B" ] && echo NO || echo yes)"
echo "E1 owner kept    : $(sed -n 4p "$WT/.owner")  (want A)"
git worktree remove --force "$TE/wt-E1" 2>/dev/null || true
```
- **E1 PASS** — `exit = 0`, `credited A` in 30..70, `idempotent = yes`, `B untouched = yes`,
  `owner kept = A`.

### E2 — startup GC of orphan time-files
```bash
cd "$TE/repo"
GC="$(cd "$(git rev-parse --git-common-dir)" && pwd)"; mkdir -p "$GC/instance"
printf '%s\n%s\n' 999999 fake > "$GC/instance/DEADID"          # marker of a dead instance
: > "$GC/todos-seconds-main-DEADID"; : > "$GC/todos-seconds-main-DEADID.lock"
: > "$GC/todos-done-main-DEADID";    : > "$GC/todos-done-main-DEADID.lock"
: > "$GC/todos-seconds-main-NOMARK"                             # file with no marker at all
: > "$GC/todos-done-main-NOMARK"
# run claudezero once more (stub claude) → startup registers our live instance, then GCs orphans
PATH="$TE/bin:$PATH" timeout 30 env CLAUDEZERO_MAX_LOOPS=1 bash "$SCRIPT" todo.md -t x > "$TE/boot2.log" 2>&1 || true
echo "E2 dead file gone   : $([ -f "$GC/todos-seconds-main-DEADID" ] && echo NO || echo yes)"
echo "E2 dead count gone  : $([ -f "$GC/todos-done-main-DEADID" ] || [ -f "$GC/todos-done-main-DEADID.lock" ] && echo NO || echo yes)"
echo "E2 dead marker gone : $([ -f "$GC/instance/DEADID" ] && echo NO || echo yes)"
echo "E2 nomark file gone : $([ -f "$GC/todos-seconds-main-NOMARK" ] && echo NO || echo yes)"
echo "E2 nomark count gone: $([ -f "$GC/todos-done-main-NOMARK" ] && echo NO || echo yes)"
```
- **E2 PASS** — all five `gone = yes`: the dead instance's marker was reaped by liveness,
  and its time-file, its count-file (both + `.lock`) and the unmarked files were deleted.
  (This run's own instance marker is live during the sweep, so a real instance's file is
  never collateral.)

## Scenario F — fenced-checkbox immunity   `[$TESTROOT/F]`   (stub claude, deterministic)

Checkbox scans (`all_todos_done`, `zero.sh done`/`box_checked_on_base`, the merge guard)
must judge **task** state only — a `- [ ]`/`- [x]` inside a fenced ` ``` ` code block is
prose (an example issue in `spec.md`), not a task. Before the fix, one unchecked example
box in a fence made `all_todos_done` return false forever, so `dojo_proud` never fired even
with every real task done; a checked example box could also mis-report a task as landed.
No real claude needed — a stub bootstraps `zero.sh`, then we drive the two checks directly.

### Setup (shared stub + repo)
```bash
TF="$TESTROOT/F"; mkdir -p "$TF/repo" "$TF/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TF/bin/claude"; chmod +x "$TF/bin/claude"
cd "$TF/repo"
git init -q -b main; git config user.email t@t.t; git config user.name test
# todo with a FENCED example block (unchecked + checked example boxes) and real tasks all done
cat > todo.md <<'EOF'
# tasks

Example issue (prose, must be ignored):
```markdown
- [ ] EX example unchecked box
- [x] EXDONE example checked box
```

- [x] 1. real task done
- [x] 2. real task done
EOF
git add -A; git commit -qm init
PATH="$TF/bin:$PATH" timeout 30 env CLAUDEZERO_MAX_LOOPS=1 bash "$SCRIPT" todo.md -t x > "$TF/boot.log" 2>&1 || true
ZERO="$(cd "$(git rev-parse --git-dir)" && pwd)/zero.sh"
echo "F0 zero.sh built : $([ -x "$ZERO" ] && echo yes || echo NO)"
```

### F1 — `all_todos_done` ignores fenced boxes → `dojo_proud` fires
```bash
cd "$TF/repo"
# every REAL task is [x]; the only [ ] is the fenced example. Fixed script → all-done → dojo_proud.
echo "F1 dojo_proud    : $(grep -c 'surveys the frozen field' "$TF/boot.log")  (want 1)"
```
- **F1 PASS** — `dojo_proud = 1`: the fenced `- [ ] EX` box did not block the all-done signal.

### F2 — `zero.sh done` ignores fenced boxes (`box_checked_on_base`)
```bash
cd "$TF/repo"
"$ZERO" done 1.     ; echo "F2 real done id  : $?  (want 0 — real [x] task)"
"$ZERO" done EXDONE ; echo "F2 fenced [x] id  : $?  (want 1 — checked box is prose in a fence)"
"$ZERO" done EX     ; echo "F2 fenced [ ] id  : $?  (want 1 — unchecked example)"
```
- **F2 PASS** — `real done id = 0`, both fenced ids = `1`: a checked example box never
  reports a task as landed.

## Scenario G — token accounting   `[$TESTROOT/G]`   (stub claude, deterministic)

The token figures come from the session transcripts the Stop hook records, so a stub
`claude` that fabricates a transcript and then fires the **real** hook exercises the whole
path with no API calls and no real claude. `MAX_LOOPS=3` is deliberate: the report prints
*between* runs (the `MAX_LOOPS` break comes before it), so three runs give two reports —
the second proves figures accumulate across a context restart. Covers what a naive summer
gets wrong: one API request writes one transcript line **per content block**, all repeating
the same `usage`, and each `usage` repeats all four field names inside `iterations[]` plus
the `cache_creation` ephemeral leaves that already sum into the parent.

### Setup (stub + repo)
```bash
TG="$TESTROOT/G"; mkdir -p "$TG/repo" "$TG/bin" "$TG/tx"
cat > "$TG/bin/claude" <<'EOF'
#!/usr/bin/env bash
# stub claude: no API calls. Fabricates ONE session transcript per run, then fires the real
# Stop hook (path pulled out of the --settings JSON claudezero passed us) with the payload
# shape claude sends, so transcript_path recording is exercised for real.
n=$(( $(cat "$TG_TX/count" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$TG_TX/count"
t="$TG_TX/t$n.jsonl"
case "${TG_MODE:-ok}" in
  missing) : ;;                                              # record a path with no file
  bad)     printf '{"message":{"usage":{"outp\n' > "$t" ;;   # truncated / invalid JSON
  *) if [ "$n" = 1 ]; then
       # req_A on 3 content-block lines with IDENTICAL usage (must count once), each carrying
       # the usage.iterations[] copy and the cache_creation ephemeral leaves (148+100 = 248).
       u='"input_tokens":10,"cache_creation_input_tokens":248,"cache_read_input_tokens":1000,"output_tokens":20,"cache_creation":{"ephemeral_5m_input_tokens":148,"ephemeral_1h_input_tokens":100},"iterations":[{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":1000,"cache_creation_input_tokens":248}]'
       for i in 1 2 3; do printf '{"requestId":"req_A","type":"assistant","message":{"usage":{%s}}}\n' "$u"; done > "$t"
       printf '{"requestId":"req_B","type":"assistant","message":{"usage":{"input_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":500,"output_tokens":7}}}\n' >> "$t"
     else
       printf '{"requestId":"req_C","type":"assistant","message":{"usage":{"input_tokens":100,"cache_creation_input_tokens":300,"cache_read_input_tokens":400,"output_tokens":200}}}\n' > "$t"
     fi ;;
esac
hook=""
for a in "$@"; do case "$a" in *compact-exit-hook.sh*) hook="$(printf '%s' "$a" | sed -n 's/.*"command":"\([^"]*\)".*/\1/p')";; esac; done
[ -n "$hook" ] && printf '{"session_id":"stub%s","transcript_path":"%s"}' "$n" "$t" | "$hook"
exit 0
EOF
chmod +x "$TG/bin/claude"
cd "$TG/repo"
git init -q -b main; git config user.email t@t.t; git config user.name test
printf -- '- [ ] G1 x\n' > todo.md; git add -A; git commit -qm init
# $1 = stub mode, $2 = log file. Fresh transcript dir per run.
grun() { rm -rf "$TG/tx"; mkdir -p "$TG/tx"
  PATH="$TG/bin:$PATH" TG_TX="$TG/tx" TG_MODE="$1" \
    timeout 90 env CLAUDEZERO_MAX_LOOPS=3 bash "$SCRIPT" todo.md -t x > "$2" 2>&1 || true; }
```

### G1 — dedupe, no double-count, accumulation across restarts
```bash
cd "$TG/repo"
grun ok "$TG/ok.log"
GC="$(cd "$(git rev-parse --git-common-dir)" && pwd)"
inst="$(sed -n 's/.*execution stats (instance \([A-Za-z0-9]*\) · .*/\1/p' "$TG/ok.log" | head -1)"
echo "G1 heading       : $(grep -c 'execution stats' "$TG/ok.log")  (want 2 — renamed from 'execution time')"
echo "G1 report 1      : $(grep -A1 'Tokens:' "$TG/ok.log" | sed -n '1,2p' | tr '\n' '|')"
echo "G1 report 2      : $(grep -A1 'Tokens:' "$TG/ok.log" | sed -n '4,5p' | tr '\n' '|')"
echo "G1 per-instance  : $([ -f "$GC/transcripts-main-$inst" ] && echo yes || echo NO)  (instance $inst)"
```
- **G1 PASS** — `heading = 2`, and the two reports read exactly:
  - report 1: `  Tokens: 1.7k Total|  in 15 · out 27 · cache write 248 · cache read 1.5k|`
    — `req_A`'s three identical lines counted **once** (10+5 in, 20+7 out), `iterations[]`
    not added on top, and the cache write is `248`, not `496` (leaves not added to parent).
    Total `15+27+248+1500 = 1790` → `1.7k`, i.e. exactly the sum of the four categories.
  - report 2: `  Tokens: 2.7k Total|  in 115 · out 227 · cache write 548 · cache read 1.9k|`
    — run 2's transcript **added** to run 1's, not replacing it (2790 → `2.7k`).
  - `per-instance = yes`: the transcript list is namespaced `transcripts-main-<instance>`,
    so parallel instances can never read each other's figures.

### G2 — degradation: never lie, never fail the run
```bash
cd "$TG/repo"
grun missing "$TG/missing.log"; grun bad "$TG/bad.log"
echo "G2 missing file : $(grep -c 'Tokens: n/a' "$TG/missing.log")  (want 2)"
echo "G2 invalid json : $(grep -c 'Tokens: n/a' "$TG/bad.log")  (want 2)"
echo "G2 timing kept  : $(grep -c 'ClaudeZero run loop:' "$TG/bad.log")  (want 2)"
```
- **G2 PASS** — both runs print `Tokens: n/a` in every report and still print the timing
  rows: a deleted transcript or a truncated/invalid line degrades to `n/a` and the run
  completes normally instead of printing a wrong number.

---

## Scenario G — claude's output descriptor (fd 4)   `[$TESTROOT/G]`   (stub claude, deterministic)

claude writes to fd 4 so `claudezero.sh … | tee run.log` logs the `❄` reports without the
TUI. Only the *fallback* is deterministic here: with output captured to a file there is no
controlling terminal, so fd 4 must fall back to plain stdout and the stub's bytes must still
appear in the captured stream. The split itself needs a pty — manual check below.

### Setup + assert
```bash
TG="$TESTROOT/G"; mkdir -p "$TG/repo" "$TG/bin"
cat > "$TG/bin/claude" <<'EOF'
#!/usr/bin/env bash
echo "STUB-CLAUDE-MARKER"
exit 0
EOF
chmod +x "$TG/bin/claude"
cd "$TG/repo"
git init -q -b main; git config user.email t@t.t; git config user.name test
printf -- '- [ ] G1 x\n' > todo.md; git add -A; git commit -qm init
# run as a session leader so there is genuinely no controlling terminal (macOS has no setsid)
detach() {
  if command -v setsid >/dev/null 2>&1; then setsid "$@"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' "$@"
  else echo "G1 SKIP — neither setsid nor python3 available to drop the controlling terminal" >&2; fi
}
detach env PATH="$TG/bin:$PATH" CLAUDEZERO_MAX_LOOPS=1 \
  timeout 30 bash "$SCRIPT" todo.md -t x > "$TG/run.log" 2>&1 || true
echo "G1 stub output kept : $(grep -c 'STUB-CLAUDE-MARKER' "$TG/run.log")  (want 1 — fd 4 fell back to stdout)"
echo "G1 own output kept  : $(grep -c '❄ ClaudeZero' "$TG/run.log")  (want >=1)"
```
- **G1 PASS** — both counts as stated: with no controlling terminal the `(: >/dev/tty)` probe
  fails, fd 4 is a dup of stdout, and no scenario that captures output loses stub-claude bytes.
  Detaching explicitly matters — run from a terminal without `detach`, the probe succeeds and
  the stub's bytes go to the terminal by design, which is the whole point of the split.

### G2 — the split itself (manual, needs a pty)

Not scripted: it needs a real terminal, and the two `script(1)` implementations take
opposite argument orders. Run one of these by hand in a scratch repo with a real `claude`:

```bash
# macOS / BSD script — typescript to /dev/null; script's own stdout is the pipe
script -q /dev/null ./claudezero.sh issues/todo.md 2>&1 | { trap '' INT; tee run.log; }
# util-linux script — command via -c, typescript file last
script -q -c "./claudezero.sh issues/todo.md 2>&1" /dev/null | { trap '' INT; tee run.log; }
```
`script` gives claudezero a pty (so `/dev/tty` opens) while its stdout is the pipe (so fd 1 is
not a tty) — exactly the operator's situation.
- **G2 PASS** — `run.log` holds the `❄` banner, reports, and loop notices and no TUI frames
  (`grep -c $'\033' run.log` is `0`), the terminal shows both streams, and pressing Ctrl+C in
  the between-runs gap still lands the closing report in `run.log`.

---

## Scenario H — claude session display name   `[$TESTROOT/H]`   (stub claude, deterministic)

Each instance names its claude session `(<instance id>) <nickname> · <student activity>` via
`--name`, so parallel terminals are told apart without reading hex. The name must reach claude as
ONE argv element, and must be the SAME on every context restart (the id and the activity are
derived from the id; the nickname is picked once at launch and stored on the liveness marker).
The nickname must differ from every peer live in this repo. The stub claude echoes its argv, so no
real claude is needed.

### Setup
```bash
TH="$TESTROOT/H"; mkdir -p "$TH/repo" "$TH/bin"
cat > "$TH/bin/claude" <<'EOF'
#!/usr/bin/env bash
printf 'ARGV:'; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\n'
exit 0
EOF
chmod +x "$TH/bin/claude"
cd "$TH/repo"
git init -q -b main; git config user.email t@t.t; git config user.name test
printf -- '- [ ] H1 x\n' > todo.md; git add -A; git commit -qm init
# the ten activities, verbatim (claudezero.sh dojo_student)
ACT=('drilling the fork-implement-merge kata' 'hauling snow buckets uphill' \
     'claiming a track before stepping on it' 'reading the whole task before striking' \
     'starting over on fresh snow' 'carving checkbox after checkbox into ice' 'hunting the next box on the list' \
     'practicing one clean strike per task' "leaving a peer's branch untouched" \
     'walking back to the merge gate')
# claude's own output goes to fd 4, which falls back to stdout only when there is no controlling
# terminal — run detached so the stub's ARGV line lands in the capture file (see Scenario G).
detachH() {
  if command -v setsid >/dev/null 2>&1; then setsid "$@"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' "$@"
  else echo "H SKIP — neither setsid nor python3 available to drop the controlling terminal" >&2; fi
}
# the fifteen nicknames, verbatim (claudezero.sh pick_nickname)
NICKS=(ash bob cleo dax elk finn gus hana ivo jun kit lux moss nix opal)
GCH="$(cd "$(git rev-parse --git-common-dir)" && pwd)"
# a fabricated LIVE peer holding nickname $1 (pid/start of this shell, so liveness keeps it)
mkpeer() { mkdir -p "$GCH/instance"
  printf '%s\n%s\n%s\n' "$$" "$(ps -o lstart= -p $$ | awk '{$1=$1;print}')" "$1" > "$GCH/instance/fake-$2"; }
nick_of() { sed -E 's/.*\) (.*) · .*/\1/'; }   # nickname out of a `[--name] [...]` line
```

### H1 — name construction, unsplit argv, restart stability
```bash
cd "$TH/repo"
detachH env PATH="$TH/bin:$PATH" CLAUDEZERO_MAX_LOOPS=3 \
  timeout 90 bash "$SCRIPT" todo.md -t x > "$TH/run.log" 2>&1 || true
ID=$(grep -m1 -oE 'instance [0-9A-Za-z]+' "$TH/run.log" | awk '{print $2}')
NICK=$(grep -m1 -oE '\[--name\] \[[^]]*\]' "$TH/run.log" | nick_of)
WANT="($ID) $NICK · ${ACT[$(( 16#${ID:0:2} % 10 ))]}"
echo "H1 want name     : $WANT"
echo "H1 launches      : $(grep -c '^ARGV:' "$TH/run.log")  (want 3)"
echo "H1 named+unsplit : $(grep -c -F -- "[--name] [$WANT]" "$TH/run.log")  (want 3)"
echo "H1 nick in list  : $(printf '%s\n' "${NICKS[@]}" | grep -qxF "$NICK" && echo yes || echo NO)"
echo "H1 header nick   : $(grep -qF "execution stats (instance $ID · $NICK)" "$TH/run.log" && echo yes || echo NO)"
echo "H1 name released : $(ls "$GCH/instance" 2>/dev/null | wc -l | tr -d ' ')  (want 0 — marker gone on exit)"
```
- **H1 PASS** — `launches = 3` and `named+unsplit = 3`: `--name` carries the parenthesised,
  space-containing name as a single argv element, the activity is the one the id selects by
  `16#<first two chars> % 10`, the nickname sits between id and activity, and all three restarts
  used the same name. `nick in list = yes` (one of the fifteen, lowercase),
  `header nick = yes` — the execution-stats header reads `(instance <id> · <nick>)` with the same
  nickname the session name carries, so a report and a terminal title can be matched by word — and
  `name released = 0` — the exiting instance unlinked its marker, so its nickname is free again.

### H2 — loop mode named too; decimal (`$$`-shaped) id picks an activity, not an error
```bash
cd "$TH/repo"
detachH env PATH="$TH/bin:$PATH" CLAUDEZERO_MAX_LOOPS=1 \
  timeout 60 bash "$SCRIPT" -l 'hi' > "$TH/loop.log" 2>&1 || true
echo "H2 loop-mode name: $(grep -m1 -oE '\[--name\] \[[^]]*\]' "$TH/loop.log" || echo NONE)"
# the $$ fallback id is decimal digits — valid hex, so the same derivation applies with no
# branch. Drive the real function on such an id.
eval "$(sed -n '/^dojo_student()/,/^}/p' "$SCRIPT")"
echo "H2 decimal id    : $(dojo_student 48584); $(dojo_student 90210)  (two activities, no error)"
echo "H2 deterministic : $([ "$(dojo_student a1b2c3d4)" = "$(dojo_student a1ffffff)" ] && echo yes || echo NO)"
echo "H2 a1 vs b2      : $([ "$(dojo_student a1b2c3d4)" != "$(dojo_student b2b2c3d4)" ] && echo differ || echo same)"
```
- **H2 PASS** — the loop-mode line shows `[--name] [(<id>) <nickname> · <activity>]`, both decimal
  ids render an activity with no arithmetic error, `deterministic = yes` (only the first two chars
  select), and `a1 vs b2 = differ` (`16#a1 % 10 = 1`, `16#b2 % 10 = 8`).

### H3 — two instances launched at the same moment draw different nicknames
```bash
cd "$TH/repo"; rm -rf "$GCH/instance"
detachH env PATH="$TH/bin:$PATH" CLAUDEZERO_MAX_LOOPS=1 timeout 90 bash "$SCRIPT" todo.md -t x > "$TH/a.log" 2>&1 &
detachH env PATH="$TH/bin:$PATH" CLAUDEZERO_MAX_LOOPS=1 timeout 90 bash "$SCRIPT" todo.md -t x > "$TH/b.log" 2>&1 &
wait
NA=$(grep -m1 -oE '\[--name\] \[[^]]*\]' "$TH/a.log" | nick_of)
NB=$(grep -m1 -oE '\[--name\] \[[^]]*\]' "$TH/b.log" | nick_of)
echo "H3 nicks         : '$NA' '$NB'"
echo "H3 differ        : $([ -n "$NA" ] && [ "$NA" != "$NB" ] && echo yes || echo NO)"
```
- **H3 PASS** — `differ = yes`: the scan-then-claim ran under `instance.lock`, so the second
  instance saw the first's line 3 and picked another word.

### H4 — the free set is what the live markers leave; suffix past fifteen; a crashed peer frees its name
```bash
cd "$TH/repo"
rm -rf "$GCH/instance"; i=0; for n in "${NICKS[@]}"; do [ "$n" = moss ] || mkpeer "$n" $((i++)); done
detachH env PATH="$TH/bin:$PATH" CLAUDEZERO_MAX_LOOPS=1 timeout 90 bash "$SCRIPT" todo.md -t x > "$TH/c.log" 2>&1 || true
echo "H4 fourteen held : $(grep -m1 -oE '\[--name\] \[[^]]*\]' "$TH/c.log" | nick_of)  (want moss)"
rm -rf "$GCH/instance"; i=0; for n in "${NICKS[@]}"; do mkpeer "$n" $((i++)); done
detachH env PATH="$TH/bin:$PATH" CLAUDEZERO_MAX_LOOPS=1 timeout 90 bash "$SCRIPT" todo.md -t x > "$TH/d.log" 2>&1 || true
echo "H4 all fifteen   : $(grep -m1 -oE '\[--name\] \[[^]]*\]' "$TH/d.log" | nick_of)  (want '<name> 1')"
rm -rf "$GCH/instance"; i=0; for n in "${NICKS[@]}"; do mkpeer "$n" $((i++)); mkpeer "$n 1" $((i++)); done
detachH env PATH="$TH/bin:$PATH" CLAUDEZERO_MAX_LOOPS=1 timeout 90 bash "$SCRIPT" todo.md -t x > "$TH/e.log" 2>&1 || true
echo "H4 both levels   : $(grep -m1 -oE '\[--name\] \[[^]]*\]' "$TH/e.log" | nick_of)  (want '<name> 2')"
# crashed peer: a marker whose pid is dead still names moss — the startup GC unlinks it first
rm -rf "$GCH/instance"; mkdir -p "$GCH/instance"; printf '999999\ndead\nmoss\n' > "$GCH/instance/crashed"
i=0; for n in "${NICKS[@]}"; do [ "$n" = moss ] || mkpeer "$n" $((i++)); done
detachH env PATH="$TH/bin:$PATH" CLAUDEZERO_MAX_LOOPS=1 timeout 90 bash "$SCRIPT" todo.md -t x > "$TH/f.log" 2>&1 || true
echo "H4 crashed freed : $(grep -m1 -oE '\[--name\] \[[^]]*\]' "$TH/f.log" | nick_of)  (want moss)"
rm -rf "$GCH/instance"
```
- **H4 PASS** — `fourteen held = moss` (the one free word), `all fifteen` is a `<name> 1` form and
  `both levels` a `<name> 2` form (ascending suffix, random within the level), and
  `crashed freed = moss` — the dead peer's marker was GC'd before the pick, so its name came back.

### H5 — degradation: an unreadable registry still names the session
```bash
cd "$TH/repo"
eval "$(sed -n '/^pick_nickname()/,/^}/p' "$SCRIPT")"
( set -euo pipefail; INSTANCE_DIR="$TH/gone/instance"; INSTANCE_ID=zz
  echo "H5 fallback name : '$(pick_nickname)'  rc=$?" )
```
- **H5 PASS** — a name from the full fifteen is printed and `rc=0`: a missing registry costs
  uniqueness, never the launch. (`$TH/gone` is never created — nothing is written.)

---

## Scenario I — `zero.sh claim` exit paths   `[$TESTROOT/I]`   (stub claude, deterministic)

`claim` is the whole "is this task mine to work?" decision: acquire, validate, re-check. It
prints the worktree path on stdout and exits 0 when the task is yours, else 1 (not claimed),
3 (validation failed) or 4 (a peer already landed it). No real claude needed — but `claim`
goes through `ensure_owner`, which requires a `claude` **ancestor process**, so the driver
below is executed by a copy of `bash` named `claude`.

### Setup
```bash
TI="$TESTROOT/I"; mkdir -p "$TI/repo" "$TI/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TI/bin/claude"; chmod +x "$TI/bin/claude"
cd "$TI/repo"
git init -q -b main; git config user.email t@t.t; git config user.name test
printf -- '- [ ] I1 a\n- [ ] I3 b\n- [ ] I4 c\n- [ ] I5 d\n- [ ] I6/a e\n' > todo.md
git add -A; git commit -qm init
# bootstrap: real claudezero writes .git/zero.sh, stub claude exits, loop ends
PATH="$TI/bin:$PATH" timeout 30 env CLAUDEZERO_MAX_LOOPS=1 bash "$SCRIPT" todo.md -t x > "$TI/boot.log" 2>&1 || true
cp "$(command -v bash)" "$TI/bin/claude"   # ensure_owner walks `ps -o comm=` for an ancestor named claude
cat > "$TI/drive.sh" <<'DRIVE'
set -uo pipefail
cd "$TI/repo"
ZERO="$(cd "$(git rev-parse --git-dir)" && pwd)/zero.sh"
GC="$(cd "$(git rev-parse --git-common-dir)" && pwd)"

# I1 — free task: exit 0, worktree path on stdout and nothing else
wt=$("$ZERO" claim I1); rc=$?
echo "I1 exit            : $rc  (want 0)"
echo "I1 branch          : $(git -C "$wt" symbolic-ref --short HEAD 2>/dev/null)  (want main-task-I1)"
echo "I1 stdout clean    : $([ "$(printf '%s' "$wt" | wc -l | tr -d ' ')" = 0 ] && [ "$(printf '%s' "$wt" | wc -w | tr -d ' ')" = 1 ] && echo yes || echo NO)"

# I2 — already held by a live session: exit 1, no second worktree
before=$(git worktree list | grep -c 'task-I1')
out=$("$ZERO" claim I1 2>&1 >/dev/null); rc=$?
echo "I2 exit            : $rc  (want 1)"
echo "I2 stderr          : $out"
echo "I2 no new worktree : $([ "$(git worktree list | grep -c 'task-I1')" = "$before" ] && echo yes || echo NO)"

# I3 — a peer landed it on base first: exit 4, and the worktree/branch it briefly held are gone
sed -i'' -e 's/^- \[ \] I3 /- [x] I3 /' todo.md; git commit -qam 'peer landed I3'
out=$("$ZERO" claim I3 2>&1 >/dev/null); rc=$?
echo "I3 exit            : $rc  (want 4)"
echo "I3 stderr          : $out"
echo "I3 worktree gone   : $(git worktree list | grep -c 'task-I3')  (want 0)"
echo "I3 branch gone     : $(git branch --list 'main-task-I3' | wc -l | tr -d ' ')  (want 0)"

# I4 — validation failure, FAULT-INJECTED: acquire hands back a detached worktree. Unreachable in
# normal operation (acquire always lands on the task branch), so inject rather than fabricate.
sed 's|^  setup_exclude "$wt"; claim_owner "$wt"; set_current "$n"; printf|  setup_exclude "$wt"; claim_owner "$wt"; set_current "$n"; git -C "$wt" checkout -q --detach; printf|' \
  "$ZERO" > "$TI/zero-bad.sh"; chmod +x "$TI/zero-bad.sh"
out=$("$TI/zero-bad.sh" claim I4 2>&1 >/dev/null); rc=$?
echo "I4 exit            : $rc  (want 3)"
echo "I4 stderr          : $out"
echo "I4 worktree kept   : $(git worktree list | grep -c 'task-I4')  (want 1 — exit 3 must NOT remove it)"
echo "I4 marker cleared  : $(grep -l '^I4$' "$GC"/session/* 2>/dev/null | wc -l | tr -d ' ')  (want 0 — no session still names I4)"

# I5 — the leaked-claim regression: after an exit 3 the session may still claim another task
wt5=$("$ZERO" claim I5); rc=$?
echo "I5 exit            : $rc  (want 0 — the failed claim did not leak)"
echo "I5 branch          : $(git -C "$wt5" symbolic-ref --short HEAD 2>/dev/null)  (want main-task-I5)"

# I6 — the RAW id reaches is_done: an id needing sanitization still matches its todo line
sed -i'' -e 's|^- \[ \] I6/a |- [x] I6/a |' todo.md; git commit -qam 'peer landed I6/a'
out=$("$ZERO" claim 'I6/a' 2>&1 >/dev/null); rc=$?
echo "I6 exit            : $rc  (want 4 — raw 'I6/a' matched the todo line, the branch used the slug)"

echo "I7 usage           : $("$ZERO" 2>&1 | grep -c 'claim N')  (want 1)"
DRIVE
```

### Run + assert
```bash
TI="$TI" "$TI/bin/claude" "$TI/drive.sh"
```
- **I PASS** — every line reports its `want` value. Together they cover the four exit paths, the
  single-field stdout the prompt's `wt=$(…)` depends on, the exit-3 claim leak (I4/I5), and the
  raw-vs-sanitized id split (I6).

---

## Scenario J — fleet TOTAL on the exit path   `[$TESTROOT/J]`   (stub claude, deterministic)

The exit path (Ctrl+C or `MAX_LOOPS`) prints this instance's report and then a fleet-wide
TOTAL summed from every peer's per-instance files for this base. No real claude and no
parallelism: the stub fabricates two peer instances **from inside the run**, so they land
after startup GC — `PEER1` with a live marker, `DEADPEER` with files but no marker (a crashed
peer's merged todos still belong in the total). The fabricated transcript repeats one
`requestId` on three lines and carries the nested `iterations[]`/`cache_creation` copies, so
the token sum also proves dedupe and no-double-count.

### Setup
```bash
TJ="$TESTROOT/J"; mkdir -p "$TJ/repo" "$TJ/bin"
cat > "$TJ/bin/claude" <<'EOF'
#!/usr/bin/env bash
GC="$(cd "$(git rev-parse --git-common-dir)" && pwd)"; mkdir -p "$GC/instance"
# PEER1: live marker (this stub's own pid) → survives any later GC. DEADPEER: files only.
printf '%s\n%s\n' "$$" "$(ps -o lstart= -p $$ | awk '{$1=$1;print}')" > "$GC/instance/PEER1"
printf '100\n' > "$GC/todos-seconds-main-PEER1";   printf '2\n' > "$GC/todos-done-main-PEER1"
printf '50\n'  > "$GC/todos-seconds-main-DEADPEER"; printf '1\n' > "$GC/todos-done-main-DEADPEER"
tr="$GC/tx-PEER1.jsonl"; : > "$tr"
u='"input_tokens":10,"output_tokens":20,"cache_creation_input_tokens":248,"cache_creation":{"ephemeral_5m_input_tokens":148,"ephemeral_1h_input_tokens":100},"cache_read_input_tokens":1000,"iterations":[{"input_tokens":10,"output_tokens":20,"cache_creation_input_tokens":248,"cache_read_input_tokens":1000}]'
for i in 1 2 3; do printf '{"requestId":"req_AAA","message":{"usage":{%s}}}\n' "$u" >> "$tr"; done
printf '%s\n' "$tr" > "$GC/transcripts-main-PEER1"
exit 0
EOF
chmod +x "$TJ/bin/claude"
cd "$TJ/repo"
git init -q -b main; git config user.email t@t.t; git config user.name test
printf -- '- [ ] J1 x\n' > todo.md; git add -A; git commit -qm init
```

### J1 — TOTAL equals the sum of the per-instance files
```bash
cd "$TJ/repo"
PATH="$TJ/bin:$PATH" timeout 40 env CLAUDEZERO_MAX_LOOPS=1 bash "$SCRIPT" todo.md -t x > "$TJ/run.log" 2>&1
echo "J1 exit          : $?  (want 0 — the report never fails the exit path)"
sed -n '/❄ TOTAL/,$p' "$TJ/run.log"
echo "J1 instances     : $(grep -o '❄ TOTAL ([0-9]*' "$TJ/run.log" | tr -dc 0-9)  (want 2 — PEER1 + DEADPEER, dead peer counted)"
echo "J1 todos sum     : $(sed -n '/❄ TOTAL/,$p' "$TJ/run.log" | grep -oE '2m30s.*3 completed' | head -1)  (want 2m30s · 3 completed = 100+50s, 2+1)"
echo "J1 token sum     : $(sed -n '/❄ TOTAL/,$p' "$TJ/run.log" | grep -oE 'Tokens: [^ ]+ Total')  (want 1.2k = 10+20+248+1000, counted ONCE)"
echo "J1 categories    : $(sed -n '/❄ TOTAL/,$p' "$TJ/run.log" | grep -oE 'in 10 · out 20 · cache write 248 · cache read 1.0k')  (want that line)"
echo "J1 no registry   : $(ls "$TJ/repo/.git" | grep -cE '^(fleet|total)-')  (want 0 — glob, no aggregate file)"
```
- **J1 PASS** — `exit = 0`, `instances = 2`, the todo sum is `2m30s · 3 completed`, the token
  total is `1.2k` with categories `in 10 · out 20 · cache write 248 · cache read 1.0k`
  (the `requestId` appeared on three lines and the nested `iterations[]`/`ephemeral_*` copies
  were ignored), and `no registry = 0`.

### J2 — solo run prints a singular TOTAL; unreadable peer files degrade, never lie
```bash
cd "$TJ/repo"
cat > "$TJ/bin/claude" <<'EOF'                                  # no peers: this run's own id only
#!/usr/bin/env bash
GC="$(cd "$(git rev-parse --git-common-dir)" && pwd)"; tr="$GC/tx-solo.jsonl"
printf '{"requestId":"req_S","message":{"usage":{"input_tokens":70,"output_tokens":30,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n' > "$tr"
printf '%s\n' "$tr" > "$CLAUDEZERO_TRANSCRIPTS"   # the hook's job, done by hand: one id on disk
exit 0
EOF
chmod +x "$TJ/bin/claude"
PATH="$TJ/bin:$PATH" timeout 40 env CLAUDEZERO_MAX_LOOPS=1 bash "$SCRIPT" todo.md -t x > "$TJ/solo.log" 2>&1 || true
echo "J2 solo TOTAL    : $(grep -c '❄ TOTAL' "$TJ/solo.log")  (want 1 — one id still gets the block; the heading names the count)"
echo "J2 solo heading  : $(grep -o '❄ TOTAL (1 instance)' "$TJ/solo.log")  (want '❄ TOTAL (1 instance)' — singular)"
echo "J2 solo figures  : $(sed -n '/❄ TOTAL/,$p' "$TJ/solo.log" | grep -cE '0s  ·  0 completed|Tokens: 100 Total|in 70 · out 30 · cache write 0 · cache read 0')  (want 3 — each equals the per-instance block above)"
echo "J2 solo run loop : $(sed -n '/❄ TOTAL/,$p' "$TJ/solo.log" | grep -c 'ClaudeZero run loop:')  (want 0 — summed wall times are not a duration)"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TJ/bin/claude"       # writes nothing: zero ids on disk
PATH="$TJ/bin:$PATH" timeout 40 env CLAUDEZERO_MAX_LOOPS=1 bash "$SCRIPT" todo.md -t x > "$TJ/none.log" 2>&1 || true
echo "J2 no-files TOTAL: $(grep -c '❄ TOTAL' "$TJ/none.log")  (want 0 — n=0 stays silent, the guard is -ge 1 not -ge 0)"
cat > "$TJ/bin/claude" <<'EOF'
#!/usr/bin/env bash
GC="$(cd "$(git rev-parse --git-common-dir)" && pwd)"
printf 'not-a-number\n' > "$GC/todos-seconds-main-GARB"; printf 'xx\n' > "$GC/todos-done-main-GARB"
printf '/nonexistent/transcript.jsonl\n' > "$GC/transcripts-main-GONE"
exit 0
EOF
chmod +x "$TJ/bin/claude"
PATH="$TJ/bin:$PATH" timeout 40 env CLAUDEZERO_MAX_LOOPS=1 bash "$SCRIPT" todo.md -t x > "$TJ/degrade.log" 2>&1
echo "J2 degrade exit  : $?  (want 0)"
echo "J2 degrade TOTAL : $(sed -n '/❄ TOTAL/,$p' "$TJ/degrade.log" | grep -cE '0s  ·  0 completed|Tokens: n/a')  (want 2 — zeroed todos row + n/a tokens)"
echo "J2 loop mode     : $(PATH="$TJ/bin:$PATH" timeout 40 env CLAUDEZERO_MAX_LOOPS=1 bash "$SCRIPT" -l hi 2>&1 | sed -n '/❄ TOTAL/,$p' | grep -c 'Todos:')  (want 0 — token rows only)"
```
- **J2 PASS** — `solo TOTAL = 1` with the singular heading, `solo figures = 3`,
  `solo run loop = 0` and `no-files TOTAL = 0`,
  `degrade exit = 0` with `degrade TOTAL = 2` (a garbled counter
  contributes 0 and a missing transcript degrades to `Tokens: n/a`), and `loop mode = 0` todo
  rows in the TOTAL block.

---

## Run all in parallel (optional)

After Section 0 and each Setup, launch the Run blocks together: put A's and C's run
blocks in the background and B/E inline (both are seconds). Then run the Assert blocks.
Total wall time ≈ 8 min, dominated by A: real `claude` cold-boots each restart, and A
zeros 5 tasks across 3 instances with a restart per task (`MAX_LOOPS=4`), so its `run`
timeout is 480s. Measured zeroing vs budget: 120s→1/5, 300s→3/5, 420s→5/5. B/E finish in
seconds; C in ~1-2 min.

## Report

For each scenario print its verdict(s) with the evidence numbers above. For A, add a
table `T1..T5 | agent | PASS/FAIL` from marker contents, plus the timing verdict. Quote
failing log tails.

## Cleanup
```bash
pkill -f claudezero.sh 2>/dev/null || true
pkill -f 'claude .*--settings' 2>/dev/null || true
rm -rf "$TESTROOT"
```
Then verify the tests left **no residue in the project repo itself** — the whole point of
running outside `$(pwd)`:
```bash
cd "$REPO"
echo "TESTROOT gone  : $([ -d "$TESTROOT" ] && echo NO || echo yes)"
echo "stale worktrees: $(git worktree list | tail -n +2 | wc -l | tr -d ' ') (want 0)"
echo "stale branches : $(git branch --list '*-task-*' | wc -l | tr -d ' ') (want 0)"
echo "stray files    : $(ls .git 2>/dev/null | grep -c '^todos-seconds-\|^todos-done-\|^transcripts-\|^zero.sh$\|^instance$')  (want 0)"
git status --porcelain
```
All counts must be 0 and `git status` empty. A leftover worktree, `*-task-*` branch, or
`todos-seconds-*`/`todos-done-*`/`zero.sh`/`instance/` under the project's `.git` means a test ran
claudezero against the project repo instead of its `$TESTROOT` sandbox — report it, don't
silently delete.
