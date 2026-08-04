# TEST.md — end-to-end tests for `claudezero.sh`

Each scenario lives in its own folder under a single **isolated TESTROOT created
outside the repo** (via `mktemp -d`). They touch separate throwaway git repos, never
the project's own working tree or history, and can run concurrently.

- **S — static checks (shellcheck + bash 3.2 syntax).** No claude. Lints `claudezero.sh` and
  the scripts it emits at runtime, then checks the bash 3.2 heredoc-in-`$(...)` constraint
  structurally and, where available, with a real bash 3.x parse.
- **A — parallel zeroing + restart-resume + timing.** 3 agents zero one todo in
  parallel; the script restarts each claude after every task (`CLAUDEZERO_MAX_LOOPS`)
  and resumes. Also asserts the per-instance execution-time report and env-hop.
- **B — startup-guard refusals.** dirty-tree, detached-HEAD, wrong-cwd, inside-a-leftover
  worktree, and untracked-todo all refuse to start. Pure bash, no claude, finishes in seconds.
- **C — merge-conflict path.** two tasks edit the same line; one merges, the other
  hits a conflict, and the zero run aborts cleanly leaving the base green and the branch for
  a human.
- **D — foreign check-off refusal + self-heal.** one agent is induced to tick a second
  task's box; `merge_task` refuses with a pointer and the agent self-heals (step 2.e).
- **E — timing accounting.** Deterministic, **no real claude** (a stub `claude` on PATH):
  per-instance in-flight credit routing + idempotency, and startup orphan-file GC.
- **F — fenced-checkbox immunity.** Deterministic, no real claude. A `- [ ]`/`- [x]` box
  inside a fenced code block is prose, not a task — proven for `all_todos_done`/`dojo_proud`
  and for `zero.sh done`/`box_checked_on_base`.
- **G1 — token accounting.** Deterministic, **no real claude** (a stub that fabricates a
  session transcript and fires the real Stop hook): `requestId` dedupe, no double-count of
  the nested `iterations`/`cache_creation` fields, accumulation across restarts, and
  `Tokens: n/a` degradation.
- **G2 — claude's output descriptor (fd 4).** Deterministic. claude writes to fd 4 so a
  captured run still gets the `❄` reports without the TUI; proves the no-tty fallback to
  stdout and, via a pty, that the TUI/report split actually holds both ways.
- **H — claude session display name.** Deterministic. `--name` carries `(<id>) <nickname> ·
  <activity>` as one argv element, stable across restarts, unique among live peers, and
  freed again on exit or crash.
- **I — `zero.sh claim` exit paths.** Deterministic. The four `claim` outcomes — free,
  peer-held, peer-landed, validation-failed — and their exit codes, plus the exit-3 claim
  leak and raw-vs-sanitized id matching.
- **J — fleet TOTAL on the exit path.** Deterministic. The exit-path report sums every
  peer's per-instance todo/token files into one fleet TOTAL, including a crashed peer that
  left files but no live marker.
- **K — SIGTERM while claude hangs.** Deterministic. A hung claude is reaped on SIGTERM
  (backgrounded + interruptible `wait`) without losing the exit report; normal exit and
  restart paths are unaffected.
- **L — claude's exit code + `--debug-file`.** Deterministic. Restart/stop log lines carry
  claude's real exit code, and `CLAUDEZERO_DEBUG` opts into a per-invocation `--debug-file`
  with no argv change when unset.
- **M — one task per session, the shell waits.** Deterministic. The claimable-task probe
  lives in the shell now: nothing left → close; everything unchecked held by a live peer →
  wait with no claude launched; anything free (including a crashed peer's branch) → launch.
- **N — the `CLAUDEZERO_WATCHDOG` timer.** Deterministic. A stalled claude is killed (TERM
  then KILL) and restarted based on CPU-time inactivity, not wall clock; `0` disables it, a
  healthy or still-working claude is left alone.
- **O — `CLAUDEZERO_LINK` into task worktrees.** Deterministic. Symlinks a gitignored
  directory into a task worktree, write-through, invisible to git via `info/exclude`,
  validated at startup before any claude launch.
- **P — the dependency-blocked wait (`CLAUDEZERO_DEPENDENCY_WAIT`).** Deterministic. A session
  that walks the whole list and claims nothing marks the block (`no-claim-mark`); the shell
  waits on the deterministic signature instead of relaunching blindly, breaks the instant a
  box flips or a peer's marker goes stale, `0` disables the wait, and an unchanged signature
  past the ceiling forces a relaunch anyway.

Parallelism (A, C) is enforced with a **file-lock barrier**, not `sleep`, so the
proof is independent of claude startup/shutdown times.

**Isolation contract.** Nothing is written inside the project repo. All test repos,
their `../ts-*` worktrees, and all state live under `$TESTROOT` (outside the repo).
The only thing read from the repo is `claudezero.sh` itself (`$SCRIPT`). The final
residue check (Cleanup) proves the project repo was untouched.

`REPO` (Section 0) is resolved via `git worktree list`, never `$(pwd)` — deterministic
regardless of which worktree an agent happens to be sitting in when it starts, so a cwd
drift can no longer point `$SCRIPT` at a real task worktree of the project instead of the
main checkout (that worktree shares the project's actual `.git`; running claudezero.sh
there is a real run — real claude, real Stop hook — against real repo state, not a test).
`in_testroot` (Section 0) is the matching per-invocation check: every scenario's own `cd`
into its `$T*/repo` is what makes an individual run land under `$TESTROOT`, and this asserts
it did, refusing instead of silently proceeding on a miss.

**Run every step from anywhere inside the repo** (any worktree). An agent reading this file
can run it autonomously and report the results.

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

Run once, from anywhere inside the repo (any worktree). Defines `REPO`/`SCRIPT` (the code
under test) and a fresh `TESTROOT` **outside** the repo, plus `write_gate` (A, C) and `ago`
(E) helpers.

```bash
set -euo pipefail
# main worktree, deterministically — never $(pwd): a cwd sitting inside a task worktree of
# this same project would otherwise point SCRIPT at the wrong .git (shared, real, live).
# `git worktree list` always lists the main working tree first, regardless of invocation cwd.
REPO="$(git worktree list | head -1 | awk '{print $1}')"
SCRIPT="$REPO/claudezero.sh"
[ -f "$SCRIPT" ] || { echo "FATAL: $SCRIPT not found — not inside the claudezero.sh repo" >&2; exit 1; }
TESTROOT="$(mktemp -d "${TMPDIR:-/tmp}/claudezero-tests.XXXXXX")"   # isolated, outside the repo
TESTROOT="$(cd "$TESTROOT" && pwd -P)"          # canonical path: on macOS $TMPDIR is /var→/private/var; the root-guard compares $PWD to git's physical path, so an uncanonicalized /var path misfires "not at repo root" at the real root
echo "TESTROOT=$TESTROOT"

# touch-timestamp for N seconds ago, BSD (-v) or GNU (-d). Used by E.
ago(){ date -v-"$1"S +%Y%m%d%H%M.%S 2>/dev/null || date -d "-$1 sec" +%Y%m%d%H%M.%S; }

# refuse to run claudezero.sh anywhere but under TESTROOT — call this right before every
# invocation of $SCRIPT. A real project worktree shares the project's .git, so a cwd mistake
# here would run a REAL claudezero session (real claude, real Stop hook) against real repo state.
in_testroot(){ case "$PWD" in "$TESTROOT"/*) return 0;; *)
  echo "REFUSING: cwd $PWD is not under TESTROOT=$TESTROOT — not invoking claudezero.sh" >&2; return 1;; esac; }

# decoy ancestor for any block that manually fires the real compact-exit-hook.sh (only Scenario G1
# does today). term_owner()/find_owner() in claudezero.sh first trust an inherited CLAUDE_PID if
# it's alive and named claude, else walk up to 8 PPID hops for the first ancestor whose `ps -o
# comm=` reads claude, and SIGTERM it. An agent running this file autonomously already has a real,
# live claude ancestor within that many hops (its own session) — the walk finds no `claude`-named
# process any closer because every wrapper in between (this file's own bash, claudezero.sh's own
# `bash "$SCRIPT"`, the agent's own Bash-tool shell) is invoked via `bash script`, not exec'd
# directly, so `ps -o comm=` reports bash for all of them, not the script's filename. `guard`
# plants a REAL bash binary (not a #!/bin/bash script — a script would report comm=bash too, same
# problem) copied to a file literally named claude, one hop above the command, and drops
# CLAUDE_PID first — so the walk's first (and only) claude-named match is this harmless decoy,
# never the real session further up.
# `$1 & wait $!`, not a bare `-c "$1"`: bash execve()-replaces a `-c` process in place (no fork,
# same pid, new image) when the whole script is one tail command — the decoy's own pid would
# silently become the payload's own command name mid-run, undoing the rename this exists for.
# Backgrounding forces a real fork; `wait $!` then blocks on it and forwards its real exit status.
mkdir -p "$TESTROOT/guard"; cp "$(command -v bash)" "$TESTROOT/guard/claude"
guard(){ env -u CLAUDE_PID "$TESTROOT/guard/claude" -c "$1"' & wait $!'; }

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

## Scenario S — static checks (shellcheck + bash 3.2 syntax)   (no claude)

Lints claudezero.sh (S1) **and the scripts it emits at runtime** (S2), then checks the
bash 3.2 constraint — structurally on any host (S3a) and by a real bash 3.x parse where one
exists (S3b). The emitted
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

S3 — bash 3.2 syntax. macOS ships bash 3.2 as `/bin/bash` and that is what a Homebrew
install runs, but bash 3.2 has parse-time limits bash 5 does not (a heredoc inside `$(…)`
is one; it once made the whole script unparsable). Parse-only, no execution. Two steps:
S3a catches the construct on **any** host, S3b runs a real bash 3.x parse where one exists.

S3a — the construct, structurally. A Linux-only CI leg has no bash 3.2 to parse with, so a
`/bin/bash -n` gate alone goes silent exactly where the bug is easiest to reintroduce. This
scan is pure text: it tracks quote state, skips comments and here-doc bodies, ignores `$(( ))`
and `<<<`, and reports any here-doc opened inside a command substitution, by line and
delimiter. It never SKIPs.

```sh
mkdir -p "$TESTROOT/S"
cat > "$TESTROOT/S/heredoc-scan.awk" <<'SCAN_EOF'
{
  if (await != "") {                       # inside a here-doc body: only the delimiter ends it
    t = $0; sub(/^[ \t]+/, "", t)
    if ($0 == await || t == await) await = ""
    next
  }
  n = length($0)
  for (i = 1; i <= n; i++) {
    c = substr($0, i, 1)
    if (sq) { if (c == "'") sq = 0; continue }
    if (c == "\\") { i++; continue }
    if (substr($0, i, 3) == "$((") { arith++; i += 2; continue }
    if (substr($0, i, 2) == "$(")  { stack[++subst] = dq; dq = 0; i += 1; continue }
    if (c == ")") {
      if (arith > 0 && substr($0, i+1, 1) == ")") { arith--; i++ }
      else if (subst > 0) { dq = stack[subst--] }
      continue
    }
    if (dq) { if (c == "\"") dq = 0; continue }
    if (c == "'") { sq = 1; continue }
    if (c == "\"") { dq = 1; continue }
    if (c == "#" && (i == 1 || substr($0, i-1, 1) ~ /[ \t;&|(]/)) break
    if (substr($0, i, 3) == "<<<") { i += 2; continue }
    if (substr($0, i, 2) == "<<") {
      j = i + 2
      if (substr($0, j, 1) == "-") j++
      while (substr($0, j, 1) == " ") j++
      d = ""; q = substr($0, j, 1)
      if (q == "'" || q == "\"") { j++; while (j <= n && substr($0, j, 1) != q) { d = d substr($0, j, 1); j++ } }
      else { while (j <= n && substr($0, j, 1) ~ /[A-Za-z0-9_]/) { d = d substr($0, j, 1); j++ } }
      if (subst > 0) { printf "%s:%d: here-doc <<%s opened inside $( … )\n", FILENAME, FNR, d; bad = 1 }
      if (d != "") await = d
      i = j - 1
      continue
    }
  }
}
END { exit (bad ? 1 : 0) }
SCAN_EOF
SCAN="awk -f $TESTROOT/S/heredoc-scan.awk"
$SCAN "$SCRIPT" && echo "S3a PASS — no here-doc inside \$( … )" || echo "S3a FAIL — findings above"

# self-test: the scan must FAIL on the pre-fix form, or it is only passing beside the bug.
# The fix predates this repo's history, so `git show HEAD~1:claudezero.sh` has nothing to
# catch — rebuild the offending construct from the current script instead.
sed "s#^    IFS= read -r -d '' prompt <<'PROMPT_EOF' || :#    local prompt=\"\$(cat <<'PROMPT_EOF'#" \
  "$SCRIPT" > "$TESTROOT/S/unfixed.sh"
$SCAN "$TESTROOT/S/unfixed.sh" >/dev/null \
  && echo "S3a SELFTEST FAIL — scan passed the unfixed script" \
  || echo "S3a SELFTEST PASS — $($SCAN "$TESTROOT/S/unfixed.sh" | head -1)"
```

S3b — a real bash 3.x parse, where the host has one. Covers the emitted scripts too: they
are written at runtime, so a bash-3.2 parse error inside `zero.sh` never shows up in a parse
of `claudezero.sh`. Needs S2 to have emitted them; a no-op if it did not.

```sh
B3=""
for c in /bin/bash /usr/local/bin/bash-3.2 /opt/homebrew/bin/bash-3.2; do
  [ -x "$c" ] && "$c" --version 2>/dev/null | head -1 | grep -q 'version 3\.' && { B3="$c"; break; }
done
if [ -z "$B3" ]; then
  echo "S3b SKIP — no bash 3.x on this host (S3a already covered the construct)"
else
  ver="$("$B3" --version | head -1 | sed -n 's/.*version \([0-9.]*\).*/\1/p')"
  rc=0; files="$SCRIPT"
  TS="$TESTROOT/S/repo"
  if [ -d "$TS/.git" ]; then
    for f in compact-exit-hook.sh zero.sh checkbox-merge.sh; do
      [ -f "$TS/.git/$f" ] && files="$files $TS/.git/$f"
    done
  else
    echo "S3b NOTE — S2 did not emit (no shellcheck); parsing claudezero.sh only"
  fi
  for f in $files; do "$B3" -n "$f" || rc=1; done
  n=$(echo $files | wc -w | tr -d ' ')
  [ "$rc" = 0 ] && echo "S3b PASS — parses under bash $ver ($n file$([ "$n" = 1 ] || echo s))" \
                || echo "S3b FAIL — errors above (bash $ver)"
fi
```
- **S PASS** — S1 and S2 both PASS (claudezero.sh clean, all three emitted scripts clean),
  S3a PASS with its SELFTEST PASS, and S3b PASS or SKIP.

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
echo "todos counted   : $(awk '/❄ TOTAL/{exit} /Todos:.*·[[:space:]]+[0-9]+ completed/{l=$0} END{print l}' "$T"/log_AGENT_A.txt)"
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

Five pristine repos: one with a dirty working tree, one on a detached HEAD, one clean
launched from a subdir, one clean launched from inside a leftover `../ts-*` task worktree,
and one clean whose todo is gitignored (so untracked on the base branch).
Each must make claudezero refuse to start with the matching message and a non-zero exit.

### Setup
```bash
TB="$TESTROOT/B"
for name in dirty detached nested worktree untracked; do
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
# todo present on disk but gitignored → untracked on the base, yet the tree still reads clean
( cd "$TB/untracked"; git rm -q --cached todo.md
  echo todo.md > .gitignore; git add .gitignore; git commit -qm ignore-todo )
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

cd "$TB/untracked"                             # clean repo, but the todo is not in the base tree
if out=$(timeout 20 bash "$SCRIPT" todo.md -t x 2>&1); then rc=0; else rc=$?; fi
{ [ "$rc" != 0 ] && echo "$out" | grep -qi 'not tracked'; } && echo "B5 untracked-guard PASS" || echo "B5 FAIL (rc=$rc): $out"
```
- **B PASS** — B1, B2, B3, B4, and B5 all report PASS (non-zero exit + the expected message,
  before any claude launch), and no `*-task-*-task-*` branch exists. B3 proves the
  worktree-path assumption is enforced: a subdir launch refuses rather than misfiring
  `../ts-*` paths. B4 proves the same for a launch *inside* a leftover claim worktree, where
  the base branch would otherwise be poisoned to a peer's claim and both instances would take
  the same todo (BUG-014). B5 proves a todo the base branch does not track refuses up front
  instead of letting every merge be refused for checking zero boxes (BUG-026).

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

## Scenario G1 — token accounting   `[$TESTROOT/G]`   (stub claude, deterministic)

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
# guarded (see Section 0): the stub below pipes straight into the real compact-exit-hook.sh,
# whose term_owner() SIGTERMs a `claude`-named ancestor — without the decoy that ancestor walk
# lands on the real agent session running this file, not the stub.
grun() { rm -rf "$TG/tx"; mkdir -p "$TG/tx"; : > "$2"
  guard "PATH='$TG/bin:$PATH' TG_TX='$TG/tx' TG_MODE='$1' timeout 90 env CLAUDEZERO_MAX_LOOPS=3 bash '$SCRIPT' todo.md -t x > '$2' 2>&1" || true
  # the decoy above IS the ancestor term_owner() SIGTERMs when loop 1's Stop hook fires, so it
  # dies (and `wait $!` returns) after just one loop; the run itself keeps going detached the
  # other two. Poll the log for all three per-loop reports instead of trusting the early return.
  i=0; while [ "$(grep -c 'execution stats' "$2" 2>/dev/null || echo 0)" -lt 3 ] && [ "$i" -lt 190 ]; do sleep 0.5; i=$((i+1)); done; }
```

### G1.1 — dedupe, no double-count, accumulation across restarts
```bash
cd "$TG/repo"
grun ok "$TG/ok.log"
GC="$(cd "$(git rev-parse --git-common-dir)" && pwd)"
inst="$(sed -n 's/.*execution stats (instance \([A-Za-z0-9]*\) · .*/\1/p' "$TG/ok.log" | head -1)"
echo "G1.1 heading       : $(grep -c 'execution stats' "$TG/ok.log")  (want 3 — a report between runs 1|2 and 2|3, plus the closing one)"
echo "G1.1 report 1      : $(grep -A1 'Tokens:' "$TG/ok.log" | sed -n '1,2p' | tr '\n' '|')"
echo "G1.1 report 2      : $(grep -A1 'Tokens:' "$TG/ok.log" | sed -n '4,5p' | tr '\n' '|')"
echo "G1.1 per-instance  : $([ -f "$GC/transcripts-main-$inst" ] && echo yes || echo NO)  (instance $inst)"
```
- **G1.1 PASS** — `heading = 3`, and the first two reports read exactly:
  - report 1: `  Tokens: 1.7k Total|  in 15 · out 27 · cache write 248 · cache read 1.5k|`
    — `req_A`'s three identical lines counted **once** (10+5 in, 20+7 out), `iterations[]`
    not added on top, and the cache write is `248`, not `496` (leaves not added to parent).
    Total `15+27+248+1500 = 1790` → `1.7k`, i.e. exactly the sum of the four categories.
  - report 2: `  Tokens: 2.7k Total|  in 115 · out 227 · cache write 548 · cache read 1.9k|`
    — run 2's transcript **added** to run 1's, not replacing it (2790 → `2.7k`).
  - `per-instance = yes`: the transcript list is namespaced `transcripts-main-<instance>`,
    so parallel instances can never read each other's figures.

### G1.2 — degradation: never lie, never fail the run
```bash
cd "$TG/repo"
grun missing "$TG/missing.log"; grun bad "$TG/bad.log"
echo "G1.2 missing file : $(grep -c 'Tokens: n/a' "$TG/missing.log")  (want 4 — one per report, plus the fleet TOTAL)"
echo "G1.2 invalid json : $(grep -c 'Tokens: n/a' "$TG/bad.log")  (want 4 — one per report, plus the fleet TOTAL)"
echo "G1.2 timing kept  : $(grep -c 'ClaudeZero run loop:' "$TG/bad.log")  (want 3 — one per report; TOTAL omits the row, summed wall times are not a duration)"
```
- **G1.2 PASS** — both runs print `Tokens: n/a` in every report and in the fleet TOTAL, and
  still print the timing rows: a deleted transcript or a truncated/invalid line degrades to
  `n/a` and the run completes normally instead of printing a wrong number.

---

## Scenario G2 — claude's output descriptor (fd 4)   `[$TESTROOT/G]`   (stub claude, deterministic)

claude writes to fd 4 so `claudezero.sh … | tee run.log` logs the `❄` reports without the
TUI. Only the *fallback* is deterministic here: with stdin off the terminal there is no tty to
split to, so fd 4 must fall back to plain stdout and the stub's bytes must still appear in the
captured stream. The split itself needs a pty — manual check below.

### G2.1 — fd 4 fallback (no tty)
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
# stdin off the terminal: fd 4 has no tty to split to and must fall back to stdout
env PATH="$TG/bin:$PATH" CLAUDEZERO_MAX_LOOPS=1 \
  timeout 30 bash "$SCRIPT" todo.md -t x > "$TG/run.log" 2>&1 < /dev/null || true
echo "G2.1 stub output kept : $(grep -c 'STUB-CLAUDE-MARKER' "$TG/run.log")  (want 1 — fd 4 fell back to stdout)"
echo "G2.1 own output kept  : $(grep -c '❄ ClaudeZero' "$TG/run.log")  (want >=1)"
```
- **G2.1 PASS** — both counts as stated: with stdin not a terminal the `[ -t 0 ]` probe fails,
  fd 4 is a dup of stdout, and no scenario that captures output loses stub-claude bytes.
  Redirecting stdin explicitly matters — run from a terminal without `< /dev/null`, the probe
  succeeds and the stub's bytes go to the terminal by design, which is the whole point of the split.

### G2.2 — the split itself (automated, `script(1)` supplies the pty)

The operator's situation is stdin on a terminal, stdout on a pipe. `script(1)` allocates a pty
and logs everything crossing it, so running the documented pipe form under it captures **both**
sides at once: fd 4 lands in the typescript, ClaudeZero's own stdout in the pipe capture. The
two `script` argument orders (BSD positional, util-linux `-c`) are picked by a helper, so no
one has to choose.

```bash
TG="$TESTROOT/G2"; mkdir -p "$TG/repo" "$TG/bin"
cat > "$TG/bin/claude" <<'EOF'
#!/usr/bin/env bash
if [ -t 0 ]; then a=yes; else a=no; fi
if [ -t 1 ]; then b=yes; else b=no; fi
echo "STUB TTY0=$a TTY1=$b"
printf 'TUI-FRAME \033[1mbold\033[0m\n'
exit 0
EOF
chmod +x "$TG/bin/claude"
cd "$TG/repo"
git init -q -b main; git config user.email t@t.t; git config user.name test
printf -- '- [ ] G2 x\n' > todo.md; git add -A; git commit -qm init
# BSD `script -q FILE CMD...` vs util-linux `script -q -c CMD FILE` — detect, don't choose.
pty() { if script --version 2>&1 | grep -qi util-linux
        then script -qec "$1" "$2"; else script -q "$2" bash -c "$1"; fi; }
export PATH="$TG/bin:$PATH"     # inherited by the pty child — keeps the command string quote-free
pty "CLAUDEZERO_MAX_LOOPS=1 bash '$SCRIPT' todo.md -t x 2>&1 | { trap '' INT; tee '$TG/pipe.log'; }" \
    "$TG/typescript" >/dev/null 2>&1
tr -d '\r' < "$TG/typescript" > "$TG/tty.log"       # pty writes CRLF; strip before matching
echo "G2.2 stub sees ttys : $(grep -o 'STUB TTY0=[a-z]* TTY1=[a-z]*' "$TG/tty.log" | head -1)  (want both yes)"
echo "G2.2 TUI on tty     : $(grep -c 'TUI-FRAME' "$TG/tty.log")  (want >=1)"
echo "G2.2 TUI not in pipe: $(grep -c 'TUI-FRAME' "$TG/pipe.log")  (want 0)"
echo "G2.2 report in pipe : $(grep -c 'execution stats' "$TG/pipe.log")  (want >=1)"
echo "G2.2 no escapes     : $(grep -c $'\033' "$TG/pipe.log")  (want 0)"

# The other direction. Under `tee` the report reaches BOTH the file and the terminal — that is
# what tee is for — so "own output stays off the tty" can only be asserted on the redirect form,
# where stdout is the file alone. fd 4 still splits the TUI to the terminal.
pty "CLAUDEZERO_MAX_LOOPS=1 bash '$SCRIPT' todo.md -t x > '$TG/redir.log' 2>&1" \
    "$TG/typescript2" >/dev/null 2>&1
tr -d '\r' < "$TG/typescript2" > "$TG/tty2.log"
echo "G2.2 report in file : $(grep -c 'execution stats' "$TG/redir.log")  (want >=1)"
echo "G2.2 report off tty : $(grep -c 'execution stats' "$TG/tty2.log")  (want 0)"
echo "G2.2 TUI still tty  : $(grep -c 'TUI-FRAME' "$TG/tty2.log")  (want >=1)"
```
- **G2.2 PASS** — all eight as stated. `stub sees ttys = yes yes` proves fd 4 is a real terminal
  descriptor (a dup of stdin), not a pipe. The split is asserted in both directions: claude's
  `TUI-FRAME` reaches the terminal and never the capture file, and ClaudeZero's own `❄` report
  reaches the capture file and — on the redirect form, where `tee` is not echoing it back —
  never the terminal. No escape byte reaches the file.

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
# claude's own output goes to fd 4, which falls back to stdout only when stdin is not a terminal
# — run with stdin off the tty so the stub's ARGV line lands in the capture file (see Scenario G2).
notty() { "$@" < /dev/null; }
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
notty env PATH="$TH/bin:$PATH" CLAUDEZERO_MAX_LOOPS=3 \
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
notty env PATH="$TH/bin:$PATH" CLAUDEZERO_MAX_LOOPS=1 \
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
notty env PATH="$TH/bin:$PATH" CLAUDEZERO_MAX_LOOPS=1 timeout 90 bash "$SCRIPT" todo.md -t x > "$TH/a.log" 2>&1 &
notty env PATH="$TH/bin:$PATH" CLAUDEZERO_MAX_LOOPS=1 timeout 90 bash "$SCRIPT" todo.md -t x > "$TH/b.log" 2>&1 &
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
notty env PATH="$TH/bin:$PATH" CLAUDEZERO_MAX_LOOPS=1 timeout 90 bash "$SCRIPT" todo.md -t x > "$TH/c.log" 2>&1 || true
echo "H4 fourteen held : $(grep -m1 -oE '\[--name\] \[[^]]*\]' "$TH/c.log" | nick_of)  (want moss)"
rm -rf "$GCH/instance"; i=0; for n in "${NICKS[@]}"; do mkpeer "$n" $((i++)); done
notty env PATH="$TH/bin:$PATH" CLAUDEZERO_MAX_LOOPS=1 timeout 90 bash "$SCRIPT" todo.md -t x > "$TH/d.log" 2>&1 || true
echo "H4 all fifteen   : $(grep -m1 -oE '\[--name\] \[[^]]*\]' "$TH/d.log" | nick_of)  (want '<name> 1')"
rm -rf "$GCH/instance"; i=0; for n in "${NICKS[@]}"; do mkpeer "$n" $((i++)); mkpeer "$n 1" $((i++)); done
notty env PATH="$TH/bin:$PATH" CLAUDEZERO_MAX_LOOPS=1 timeout 90 bash "$SCRIPT" todo.md -t x > "$TH/e.log" 2>&1 || true
echo "H4 both levels   : $(grep -m1 -oE '\[--name\] \[[^]]*\]' "$TH/e.log" | nick_of)  (want '<name> 2')"
# crashed peer: a marker whose pid is dead still names moss — the startup GC unlinks it first
rm -rf "$GCH/instance"; mkdir -p "$GCH/instance"; printf '999999\ndead\nmoss\n' > "$GCH/instance/crashed"
i=0; for n in "${NICKS[@]}"; do [ "$n" = moss ] || mkpeer "$n" $((i++)); done
notty env PATH="$TH/bin:$PATH" CLAUDEZERO_MAX_LOOPS=1 timeout 90 bash "$SCRIPT" todo.md -t x > "$TH/f.log" 2>&1 || true
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
# same real-binary-not-script trick as `guard` in Section 0, but for the opposite reason: this one
# needs ensure_owner to FIND a claude ancestor (claim/merge FATAL out at exit 3 without one), not to
# stop term_owner from killing one — claim never SIGTERMs anything, so a wrongly-found ancestor here
# only misattributes bookkeeping, it can't take down this session. Kept inline (driver is a whole
# script file with real work between every claim, never a bare tail command) rather than routed
# through `guard`, whose `& wait $!` shape exists for a single -c command, not a multi-step driver.
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
sed 's|^  setup_exclude "$wt"; link_ignored "$wt"; claim_owner "$wt"; set_current "$n"; printf|  setup_exclude "$wt"; link_ignored "$wt"; claim_owner "$wt"; set_current "$n"; git -C "$wt" checkout -q --detach; printf|' \
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
# -u CLAUDE_PID: this driver IS the ancestor find_owner/term_owner must walk to. An agent
# running this file autonomously already has a real CLAUDE_PID in env (its own live session) —
# left set, find_owner trusts that inherited pid over the nearer stub ancestor below, since
# claudezero.sh trusts CLAUDE_PID whenever it is alive and named claude, with no check that it's
# actually this invocation's ancestor. Unset so the stub is the only candidate found.
TI="$TI" env -u CLAUDE_PID "$TI/bin/claude" "$TI/drive.sh"
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

## Scenario K — SIGTERM while claude hangs   `[$TESTROOT/K]`   (stub claude, deterministic)

A supervisor / `timeout` / `kill` stopping the run must still land at the closer. The stub
hangs forever, so the wrapper only survives the TERM if claude is backgrounded and reaped by
an interruptible `wait` — a foreground child would defer the trap until the KILL. The same
stub set proves the two paths this must not change: a clean exit still ends 0, and a stub
exiting 143 (the Stop hook's restart signal) still restarts with `TERMED` unset.

### Setup
```bash
TK="$TESTROOT/K"; mkdir -p "$TK/repo" "$TK/bin"
cd "$TK/repo"
git init -q -b main; git config user.email t@t.t; git config user.name test
printf -- '- [ ] K1 x\n' > todo.md; git add -A; git commit -qm init
```

### K1 — the hang: closer still runs, exit 143, no orphan child
```bash
cd "$TK/repo"
printf '#!/usr/bin/env bash\necho "Execution error"\nsleep 1000\n' > "$TK/bin/claude"; chmod +x "$TK/bin/claude"
PATH="$TK/bin:$PATH" timeout --preserve-status -k 20 8 env CLAUDEZERO_MAX_LOOPS=1 bash "$SCRIPT" todo.md -t x > "$TK/hang.log" 2>&1
echo "K1 exit          : $?  (want 143 = 128+15; plain \`timeout\` would report its own 124)"
echo "K1 stats         : $(grep -c 'execution stats' "$TK/hang.log")  (want 1 — the report the TERM used to eat)"
echo "K1 stopped       : $(grep -c 'run loop stopped' "$TK/hang.log")  (want 1)"
echo "K1 orphans       : $(pgrep -f "$TK/bin/claude" | wc -l | tr -d ' ')  (want 0 — the TERM was forwarded to claude)"
echo "K1 one TERM trap : $(grep -c '^trap .*TERM$' "$SCRIPT")  (want 1 — a second handler would silently replace this one)"
echo "K1 backgrounded  : $(grep -c 'claude "\${CLAUDE_ARGS\[@\]}" "\$PROMPT" >&4 2>&4 &$' "$SCRIPT")  (want 1 — no foreground launch, no \`|| true\` swallow)"
```
- **K1 PASS** — `exit = 143`, `stats = 1`, `stopped = 1`, `orphans = 0`,
  `one TERM trap = 1`, `backgrounded = 1`.

### K2 — the two paths that must not change
```bash
cd "$TK/repo"
printf '#!/usr/bin/env bash\necho "stub ran"\nexit 0\n' > "$TK/bin/claude"; chmod +x "$TK/bin/claude"
PATH="$TK/bin:$PATH" timeout 40 env CLAUDEZERO_MAX_LOOPS=1 bash "$SCRIPT" todo.md -t x > "$TK/ok.log" 2>&1
echo "K2 normal exit   : $?  (want 0 — TERMED=0 must not leak a status through set -e)"
echo "K2 normal stats  : $(grep -c 'execution stats' "$TK/ok.log")  (want 1)"
printf '#!/usr/bin/env bash\necho "stub run"\nexit 143\n' > "$TK/bin/claude"; chmod +x "$TK/bin/claude"
PATH="$TK/bin:$PATH" timeout 60 env CLAUDEZERO_MAX_LOOPS=2 bash "$SCRIPT" todo.md -t x > "$TK/restart.log" 2>&1
echo "K2 restart exit  : $?  (want 0 — claude's own 143 is the Stop hook path, not ours)"
echo "K2 restart runs  : $(grep -c 'stub run' "$TK/restart.log")  (want 2 — the wait's re-check found it dead and looped)"
echo "K2 restart line  : $(grep -c 'restarting in' "$TK/restart.log")  (want 1)"
```
- **K2 PASS** — `normal exit = 0` with `normal stats = 1`, and
  `restart exit = 0` with `restart runs = 2`, `restart line = 1`.

---

## Scenario L — claude's exit code + `--debug-file`   `[$TESTROOT/L]`   (stub claude, deterministic)

The restart / `MAX_LOOPS`-stop lines carry claude's real exit status, so a hang and a clean
exit are told apart without re-deriving them from timing. `CLAUDEZERO_DEBUG` is the opt-in:
set, every claude invocation gets its own `--debug-file`; unset, the argv is byte-identical
to before. The stub echoes its own argv, which is how the argv claim is checked.

### Setup
```bash
TL="$TESTROOT/L"; mkdir -p "$TL/repo" "$TL/bin"
cat > "$TL/bin/claude" <<'EOF'
#!/usr/bin/env bash
printf 'ARGV: %s\n' "$*"
exit "${STUB_EXIT:-0}"
EOF
chmod +x "$TL/bin/claude"
cd "$TL/repo"
git init -q -b main; git config user.email t@t.t; git config user.name test
printf -- '- [ ] L1 x\n' > todo.md; git add -A; git commit -qm init
```

### L1 — the code is on both lines, and it is claude's own
```bash
cd "$TL/repo"
PATH="$TL/bin:$PATH" STUB_EXIT=7 timeout 60 env CLAUDEZERO_MAX_LOOPS=2 bash "$SCRIPT" todo.md -t x > "$TL/code.log" 2>&1
echo "L1 exit          : $?  (want 0 — claude's status is reported, not adopted)"
echo "L1 restart line  : $(grep -c 'claude exited with code 7 after 1 runs · restarting in' "$TL/code.log")  (want 1)"
echo "L1 stop line     : $(grep -c 'claude exited with code 7 after 2 runs · reached CLAUDEZERO_MAX_LOOPS' "$TL/code.log")  (want 1)"
echo "L1 no old line   : $(grep -c 'claude exited after' "$TL/code.log")  (want 0 — merged into the same line, not a second one)"
PATH="$TL/bin:$PATH" timeout 40 env CLAUDEZERO_MAX_LOOPS=1 bash "$SCRIPT" todo.md -t x > "$TL/zero.log" 2>&1
echo "L1 clean code    : $(grep -c 'claude exited with code 0 after 1 runs' "$TL/zero.log")  (want 1 — an exit-0 stub reads 0, not a stale status)"
```
- **L1 PASS** — `exit = 0`, `restart line = 1`, `stop line = 1`, `no old line = 0`,
  `clean code = 1`.

### L2 — `--debug-file` is opt-in, one file per invocation
```bash
cd "$TL/repo"
echo "L2 argv default  : $(grep -c -- '--debug-file' "$TL/zero.log")  (want 0 — unset is the default and changes nothing)"
echo "L2 argv shape    : $(grep -c 'ARGV: --settings .* --permission-mode auto --name .* You are ONE of ' "$TL/zero.log")  (want 1 — the pre-existing argv: flags, then the prompt, nothing added)"
PATH="$TL/bin:$PATH" CLAUDEZERO_DEBUG=1 timeout 60 env CLAUDEZERO_MAX_LOOPS=2 bash "$SCRIPT" todo.md -t x > "$TL/debug.log" 2>&1
echo "L2 debug exit    : $?  (want 0)"
echo "L2 argv debug    : $(grep -c -- '--debug-file .*/\.git/debug-main-[0-9A-F]*-[12]\.log' "$TL/debug.log")  (want 2 — <kind>-<base>-<instance>-<loop>, one per invocation)"
echo "L2 distinct paths: $(grep -o -- '--debug-file [^ ]*' "$TL/debug.log" | sort -u | wc -l | tr -d ' ')  (want 2 — the loop number keeps a restart from truncating run 1's trace)"
```
- **L2 PASS** — `argv default = 0` with `argv shape = 1`, and
  `debug exit = 0`, `argv debug = 2`, `distinct paths = 2`.

---

## Scenario M — one task per session, the shell waits   `[$TESTROOT/M]`   (stub claude, deterministic)

The claimable probe moved out of claude and into the shell: nothing left → the closer;
everything unchecked held by a *live* peer → wait, launching no claude at all; anything free
(including a crashed peer's branch, which only claude can rescue) → launch. The Stop hook is
the other half — in zero mode it ends the session at every turn end, so one session zeroes one
task; in `-l` loop mode only the context-bucket file still ends it.

### Setup
```bash
TM="$TESTROOT/M"; mkdir -p "$TM/repo" "$TM/bin"
cat > "$TM/bin/claude" <<'EOF'
#!/usr/bin/env bash
echo launched >> "$STUB_LAUNCHED"
exit 0
EOF
chmod +x "$TM/bin/claude"
mkdir -p "$TM/owner"; cp "$(command -v bash)" "$TM/owner/claude"   # M4 needs a process `ps -o comm=` reports as 'claude'
cd "$TM/repo"
git init -q -b main; git config user.email t@t.t; git config user.name test
printf -- '- [ ] M1 x\n' > todo.md; git add -A; git commit -qm init
# a LIVE peer holding M1: claim branch + worktree `.owner` + session marker, exactly what
# zero.sh's acquire writes and what held_todos reads back.
sleep 600 & PEER=$!
git worktree add -q -b main-task-M1 "$TM/wt1" main
printf '%s\n%s\n%s\n%s\n' "$PEER" "$(ps -o lstart= -p "$PEER" | awk '{$1=$1;print}')" "$(date +%s)" "PEERINST" > "$TM/wt1/.owner"
mkdir -p "$TM/repo/.git/session"
printf '%s\n%s\n' "$(ps -o lstart= -p "$PEER" | awk '{$1=$1;print}')" "M1" > "$TM/repo/.git/session/$PEER"
```

### M1 — every unchecked task peer-held: no claude, plain waiting lines when stdout is not a tty
```bash
cd "$TM/repo"
export STUB_LAUNCHED="$TM/launched"; : > "$STUB_LAUNCHED"
sleep 600 & DECOY=$!   # stands in for the caller's own session: Claude Code exports CLAUDE_PID
PATH="$TM/bin:$PATH" CLAUDE_PID=$DECOY timeout 45 env CLAUDEZERO_MAX_LOOPS=1 bash "$SCRIPT" todo.md -t x > "$TM/wait.log" 2>&1
echo "M1 exit          : $?  (want 124 — still waiting when the timeout fired, never launched)"
echo "M1 decoy alive   : $(kill -0 $DECOY 2>/dev/null && echo yes || echo no)  (want yes — the TERM trap must never kill an INHERITED CLAUDE_PID; nothing was launched yet)"
kill "$DECOY" 2>/dev/null; wait "$DECOY" 2>/dev/null || true
echo "M1 launches      : $(wc -l < "$STUB_LAUNCHED" | tr -d ' ')  (want 0 — no claude process, no transcript, no tokens)"
echo "M1 waiting line  : $(grep -c 'waiting for a claimable task · 1 held by peers' "$TM/wait.log")  (want 3 — LOG_TICK=20 over a 45s wait, NOT one per WAIT_TICK probe)"
# -F, two -e patterns: `\|` alternation is a GNU BRE extension and `\033[` leaves an unbalanced
# bracket, so the single-pattern form dies "brackets not balanced" on the macOS leg's BSD grep
echo "M1 no escapes    : $(LC_ALL=C grep -cF -e $'\r' -e $'\033[' "$TM/wait.log")  (want 0 — a pipe gets no \r and no cursor moves)"
```
- **M1 PASS** — `exit = 124`, `decoy alive = yes`, `launches = 0`, `waiting line = 3`, `no escapes = 0`.

### M2 — a dead peer's branch is claimable: claude IS launched to rescue it
```bash
cd "$TM/repo"
kill "$PEER" 2>/dev/null; wait "$PEER" 2>/dev/null || true
: > "$STUB_LAUNCHED"
PATH="$TM/bin:$PATH" timeout 40 env CLAUDEZERO_MAX_LOOPS=1 bash "$SCRIPT" todo.md -t x > "$TM/rescue.log" 2>&1
echo "M2 exit          : $?  (want 0)"
echo "M2 launches      : $(wc -l < "$STUB_LAUNCHED" | tr -d ' ')  (want 1 — held_todos counts only LIVE owners, else a crash parks the fleet forever)"
echo "M2 no wait line  : $(grep -c 'waiting for a claimable task' "$TM/rescue.log")  (want 0)"
```
- **M2 PASS** — `exit = 0`, `launches = 1`, `no wait line = 0`.

### M3 — every box checked: the closer runs, claude never starts
```bash
cd "$TM/repo"
git worktree remove --force "$TM/wt1"; git branch -qD main-task-M1
printf -- '- [x] M1 x\n' > todo.md; git add -A; git commit -qm done
: > "$STUB_LAUNCHED"
PATH="$TM/bin:$PATH" timeout 40 env CLAUDEZERO_MAX_LOOPS=1 bash "$SCRIPT" todo.md -t x > "$TM/done.log" 2>&1
echo "M3 exit          : $?  (want 0)"
echo "M3 launches      : $(wc -l < "$STUB_LAUNCHED" | tr -d ' ')  (want 0 — nothing to zero, so nothing to launch)"
echo "M3 closing report: $(grep -c 'execution stats' "$TM/done.log")  (want >=1 — broke straight to the closer)"
```
- **M3 PASS** — `exit = 0`, `launches = 0`, `closing report >= 1`.

### M4 — the Stop hook: ends every zero-mode turn, only context-full in loop mode
```bash
cd "$TM/repo"
CLAUDEZERO_TEST_EMIT=1 bash "$SCRIPT" todo.md -t x > /dev/null 2>&1
HOOK="$TM/repo/.git/compact-exit-hook.sh"
# -u CLAUDE_PID: "$TM/owner/claude" below IS the ancestor term_owner must SIGTERM. An agent
# running this file autonomously already has a real CLAUDE_PID in env (its own live session) —
# left set, term_owner trusts that inherited pid unconditionally (alive + named claude, no check
# it's actually this invocation's ancestor) and SIGTERMs the live agent running the test instead
# of the stub. Unset so the stub is the only candidate the ancestor walk can find.
# This IS `guard` from Section 0's technique (real bash binary named claude, not a script — a
# shebang script would report comm=bash, not claude, to the walk), applied by hand instead of
# calling `guard` directly: this needs CLAUDEZERO_MODE set as a prefix on the SAME command, and the
# `-c` body is two statements ending in `sleep 3`, so — same reasoning as guard's own `& wait $!` —
# the real work (printf | bash "$1", where the hook's term_owner runs) is never in tail position and
# this process's own comm can't get execve()-replaced out from under it before the kill lands.
run_as_claude(){ CLAUDEZERO_MODE="$1" env -u CLAUDE_PID "$TM/owner/claude" -c 'printf "%s" "$2" | bash "$1" >/dev/null 2>&1; sleep 3' _ "$HOOK" "$2"; echo $?; }
echo "M4 zero mode     : $(run_as_claude zero '{}')  (want 143 — ordinary turn end SIGTERMs the owning claude)"
echo "M4 loop mode     : $(run_as_claude loop '{}')  (want 0 — -l has no task boundary, so it is left running)"
B="${TMPDIR:-/tmp}"; B="${B%/}/claude-context-bucket-czM4"; : > "$B"
echo "M4 bucket branch : $(run_as_claude loop '{"session_id":"czM4"}')  (want 143 — the context-rot guard is unchanged and still first)"
rm -f "$B"
```
- **M4 PASS** — `zero mode = 143`, `loop mode = 0`, `bucket branch = 143`.

### M5 — terminal pacing: one frame a second, clock in 5s steps, independent of `WAIT_TICK`
```bash
cd "$TM/repo"
# M2/M3 landed M1, so restore an unchecked, peer-held task for the wait to sit on
printf -- '- [ ] M5 x\n' > todo.md; git add -A; git commit -qm m5
sleep 600 & PEER5=$!
git worktree add -q -b main-task-M5 "$TM/wt5" main
printf '%s\n%s\n%s\n%s\n' "$PEER5" "$(ps -o lstart= -p "$PEER5" | awk '{$1=$1;print}')" "$(date +%s)" "PEERINST" > "$TM/wt5/.owner"
printf '%s\n%s\n' "$(ps -o lstart= -p "$PEER5" | awk '{$1=$1;print}')" "M5" > "$TM/repo/.git/session/$PEER5"
# a pty is required: the repainting branch is behind `[ -t 1 ]`
/usr/bin/script -q "$TM/tty.txt" env PATH="$TM/bin:$PATH" timeout 21 env CLAUDEZERO_MAX_LOOPS=1 \
  bash "$SCRIPT" todo.md -t x >/dev/null 2>&1
kill "$PEER5" 2>/dev/null; wait "$PEER5" 2>/dev/null || true
tr '\r' '\n' < "$TM/tty.txt" | grep 'waiting for a claimable task' > "$TM/frames.txt"
N=$(grep -c . "$TM/frames.txt")
echo "M5 repaints      : $N  ($( [ "$N" -ge 19 ] && [ "$N" -le 22 ] && echo yes || echo NO) — want yes: ~1/s over the 21s window. A probe-paced line would give 4)"
# the exact invariant, immune to a second of startup slop: the frames run |/-\ in order, forever.
# The sequence goes through a PIPE, never `awk -v` — awk expands backslash escapes in a -v value,
# which silently eats the `\` frame and shifts every comparison after it.
SEQ=$(grep -o '❄ .' "$TM/frames.txt" | sed 's/^❄ //' | tr -d '\n')
echo "M5 cycle         : $(printf '%s\n' "$SEQ" | awk '{c="|/-\\"; for(i=1;i<=length($0);i++) if (substr($0,i,1) != substr(c,(i-1)%4+1,1)) {print "NO at "i; exit} print "yes"}')  (want yes)"
echo "M5 clock steps   : $(grep -oE '· [0-9]+m?[0-9]*s' "$TM/frames.txt" | sort -u | tr '\n' ' ')  (want only 0s/5s/10s/15s/20s — WAIT_STEP=5)"
echo "M5 no odd clock  : $(grep -cE '· [0-9]*[1-46-9]s' "$TM/frames.txt")  (want 0 — no 1s/2s/3s ever printed)"
```
- **M5 PASS** — `repaints = yes`, `cycle = yes`, `clock steps` only multiples of 5, `no odd clock = 0`.
  Together they pin the frame rate and the clock step to `WAIT_FRAME`/`WAIT_STEP` rather than to
  `WAIT_TICK`: the probe fires 4 times in this window, the line repaints ~21.

---

## Scenario N — the `CLAUDEZERO_WATCHDOG` timer   `[$TESTROOT/N]`   (stub claude, deterministic)

A claude that stops making progress never exits, so the loop parks on it forever. The watchdog
is the cutoff: it names itself on its own console line, SIGTERMs claude onto the ordinary
restart path, and escalates to SIGKILL for a claude that ignores TERM. A claude that exits on
its own must never see it, and `0` must switch it off. Progress is claude's own CPU time, not
wall clock, so a claude still working past the window must survive it (N4).

### Setup
```bash
TN="$TESTROOT/N"; mkdir -p "$TN/repo" "$TN/bin"
cd "$TN/repo"
git init -q -b main; git config user.email t@t.t; git config user.name test
printf -- '- [ ] N1 x\n' > todo.md; git add -A; git commit -qm init
```

### N1 — a hung claude is killed, named, and restarted
```bash
cd "$TN/repo"
printf '#!/usr/bin/env bash\necho "stub hung"\nsleep 1000\n' > "$TN/bin/claude"; chmod +x "$TN/bin/claude"
PATH="$TN/bin:$PATH" CLAUDEZERO_WATCHDOG=5 timeout 90 env CLAUDEZERO_MAX_LOOPS=2 bash "$SCRIPT" todo.md -t x > "$TN/hang.log" 2>&1
echo "N1 exit          : $?  (want 0 — the watchdog's kill is a restart, not a failure of the run)"
echo "N1 watchdog line : $(grep -c '❄ watchdog · no progress from claude for 5s · killing it (CLAUDEZERO_WATCHDOG=5)' "$TN/hang.log")  (want 2 — its own line, once per hung launch)"
echo "N1 restart code  : $(grep -c 'claude exited with code 143 after 1 runs · restarting in' "$TN/hang.log")  (want 1 — SIGTERM, so the tested restart path)"
echo "N1 runs          : $(grep -c 'stub hung' "$TN/hang.log")  (want 2 — the loop went on instead of parking on run 1)"
echo "N1 orphans       : $(pgrep -f "$TN/bin/claude" | wc -l | tr -d ' ')  (want 0)"
```
- **N1 PASS** — `exit = 0`, `watchdog line = 2`, `restart code = 1`, `runs = 2`, `orphans = 0`.

### N2 — a claude that ignores SIGTERM is SIGKILLed
```bash
cd "$TN/repo"
printf '#!/usr/bin/env bash\ntrap "" TERM\necho "stub deaf"\nsleep 1000\n' > "$TN/bin/claude"; chmod +x "$TN/bin/claude"
PATH="$TN/bin:$PATH" CLAUDEZERO_WATCHDOG=5 timeout 90 env CLAUDEZERO_MAX_LOOPS=1 bash "$SCRIPT" todo.md -t x > "$TN/deaf.log" 2>&1
echo "N2 exit          : $?  (want 0 — not 124: the timer, not the harness, ended it)"
echo "N2 kill code     : $(grep -c 'claude exited with code 137 after 1 runs' "$TN/deaf.log")  (want 1 — 128+9, the escalation ~10s after the ignored TERM)"
echo "N2 orphans       : $(pgrep -f "$TN/bin/claude" | wc -l | tr -d ' ')  (want 0)"
```
- **N2 PASS** — `exit = 0`, `kill code = 1`, `orphans = 0`.

### N3 — off by request, silent on a healthy claude, default on a mistyped value
```bash
cd "$TN/repo"
printf '#!/usr/bin/env bash\necho "stub hung"\nsleep 1000\n' > "$TN/bin/claude"; chmod +x "$TN/bin/claude"
PATH="$TN/bin:$PATH" CLAUDEZERO_WATCHDOG=0 timeout 20 env CLAUDEZERO_MAX_LOOPS=1 bash "$SCRIPT" todo.md -t x > "$TN/off.log" 2>&1
echo "N3 off exit      : $?  (want 124 — 0 disables the timer, so the hang is left alone)"
echo "N3 off line      : $(grep -c '❄ watchdog' "$TN/off.log")  (want 0)"
printf '#!/usr/bin/env bash\necho "stub ran"\nexit 0\n' > "$TN/bin/claude"; chmod +x "$TN/bin/claude"
PATH="$TN/bin:$PATH" CLAUDEZERO_WATCHDOG=5 timeout 40 env CLAUDEZERO_MAX_LOOPS=1 bash "$SCRIPT" todo.md -t x > "$TN/ok.log" 2>&1
echo "N3 healthy exit  : $?  (want 0)"
echo "N3 healthy line  : $(grep -c '❄ watchdog' "$TN/ok.log")  (want 0 — a claude that exits on its own retires its own timer)"
PATH="$TN/bin:$PATH" CLAUDEZERO_WATCHDOG=15min timeout 40 env CLAUDEZERO_MAX_LOOPS=1 bash "$SCRIPT" todo.md -t x > "$TN/bad.log" 2>&1
echo "N3 bad exit      : $?  (want 0)"
echo "N3 bad warning   : $(grep -c 'ignoring CLAUDEZERO_WATCHDOG=15min' "$TN/bad.log")  (want 1 — a typo falls back to the default, never to no watchdog)"
```
- **N3 PASS** — `off exit = 124` with `off line = 0`, `healthy exit = 0` with `healthy line = 0`,
  and `bad exit = 0` with `bad warning = 1`.

### N4 — a claude still working past the window is not killed
```bash
cd "$TN/repo"
# burns CPU in the claude process itself for 3× the window, then exits on its own
printf '#!/usr/bin/env bash\necho "stub busy"\nend=$((SECONDS+15))\nwhile [ $SECONDS -lt $end ]; do :; done\nexit 0\n' > "$TN/bin/claude"; chmod +x "$TN/bin/claude"
PATH="$TN/bin:$PATH" CLAUDEZERO_WATCHDOG=5 timeout 60 env CLAUDEZERO_MAX_LOOPS=1 bash "$SCRIPT" todo.md -t x > "$TN/busy.log" 2>&1
echo "N4 busy exit     : $?  (want 0 — the stub ran 3× the window and finished by itself)"
echo "N4 busy line     : $(grep -c '❄ watchdog' "$TN/busy.log")  (want 0 — advancing CPU time resets the window)"
echo "N4 own exit code : $(grep -c 'claude exited with code 0 after 1 runs' "$TN/busy.log")  (want 1 — not 143/137)"
```
- **N4 PASS** — `busy exit = 0`, `busy line = 0`, `own exit code = 1`. Wall clock alone would have
  killed it at 5s; only the CPU-time sample tells honest long work from a wedged socket.

---

## Scenario O — `CLAUDEZERO_LINK` into task worktrees   `[$TESTROOT/O]`   (stub claude, deterministic)

A worktree checks out tracked files only, so a gitignored spec directory a todo line points at is
absent there and the session works from the title alone. `CLAUDEZERO_LINK` symlinks it in. The link
must be readable, must write through to the real file, and must stay invisible to git — a `name/`
ignore pattern matches a directory, not a symlink to one, so without an `info/exclude` entry the
link rides along in the session's `git add -A`. Like Scenario I, `claim` needs a `claude` **ancestor
process**, so the driver is executed by a copy of `bash` named `claude`.

### Setup
```bash
TO="$TESTROOT/O"; mkdir -p "$TO/repo" "$TO/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TO/bin/claude"; chmod +x "$TO/bin/claude"
cd "$TO/repo"
git init -q -b main; git config user.email t@t.t; git config user.name test
printf 'issues/\nsources/\n' > .gitignore
printf -- '- [ ] O1 a\n- [ ] O2 b\n- [ ] O3 c\n- [ ] O4 d\n' > todo.md
git add -A; git commit -qm init
mkdir issues sources
printf -- '- [ ] criterion one\n' > issues/ISSUE-O.md      # the spec the todo line points at
printf 'private\n' > sources/s.txt                         # gitignored, NOT listed in CLAUDEZERO_LINK
PATH="$TO/bin:$PATH" timeout 30 env CLAUDEZERO_MAX_LOOPS=1 bash "$SCRIPT" todo.md -t x > "$TO/boot.log" 2>&1 || true
cp "$(command -v bash)" "$TO/bin/claude"   # ensure_owner walks `ps -o comm=` for an ancestor named claude
# same reasoning as Scenario I's identical line (see there): `guard` in Section 0 codifies this
# real-binary trick for the term_owner-kill case; claim/link_ignored here only need ensure_owner to
# FIND an ancestor (no kill involved), and the driver below is a multi-step script, not a bare
# tail command, so it's inline rather than routed through `guard`.
cat > "$TO/drive.sh" <<'DRIVE'
set -uo pipefail
cd "$TO/repo"
ZERO="$(cd "$(git rev-parse --git-dir)" && pwd)/zero.sh"

# O1 — listed name is linked, readable, and write-through; unlisted name is not linked
wt=$(CLAUDEZERO_LINK=issues "$ZERO" claim O1)
echo "O1 is symlink      : $([ -L "$wt/issues" ] && echo yes || echo NO)  (want yes — linked, not copied)"
echo "O1 readable        : $(cat "$wt/issues/ISSUE-O.md" 2>/dev/null)  (want '- [ ] criterion one')"
sed -i'' -e 's/- \[ \]/- [x]/' "$wt/issues/ISSUE-O.md"
echo "O1 write-through   : $(cat "$TO/repo/issues/ISSUE-O.md")  (want '- [x] criterion one' — no commit, no merge)"
echo "O1 status empty    : $([ -z "$(git -C "$wt" status --short)" ] && echo yes || echo NO)  (want yes — the exclude covers the symlink)"
git -C "$wt" add -A
echo "O1 add -A stages   : $(git -C "$wt" status --short | grep -c 'issues')  (want 0 — the link never reaches a commit)"
echo "O1 unlisted absent : $([ -e "$wt/sources" ] && echo NO || echo yes)  (want yes — only listed names are linked)"
echo "O1 exclude entry   : $(grep -c '^/issues$' "$(git -C "$wt" rev-parse --git-path info/exclude)")  (want 1 — info/exclude is the COMMON dir's, shared by every worktree)"

# O2 — unset variable links nothing at all
wt2=$("$ZERO" claim O2)
echo "O2 no link         : $([ -e "$wt2/issues" ] && echo NO || echo yes)  (want yes — default is off)"

# O3 — link_ignored itself no longer re-checks the list: a bad entry cannot reach it, because
# startup refused the run (see O6). Its only remaining guard is the occupied-name test.
echo "O3 guards          : $(sed -n '/^link_ignored() {/,/^}/p' "$ZERO" | grep -c '\-e "\$root/\$p"\|case "\$p" in')  (want 0 — validation lives at startup, once)"

# O4 — a second claim appends no duplicate exclude entry and leaves the link alone
wt4=$(CLAUDEZERO_LINK=issues "$ZERO" claim O4)
EX4="$(git -C "$wt4" rev-parse --git-path info/exclude)"
CLAUDEZERO_LINK=issues "$ZERO" claim O4 >/dev/null 2>&1 || true
echo "O4 exclude dupes   : $(grep -c '^/issues$' "$EX4")  (want 1 — claiming twice appends once)"
echo "O4 link intact     : $([ -L "$wt4/issues" ] && echo yes || echo NO)  (want yes)"
# the -L half of the guard, called directly — a second `claim` of a task this session already holds
# returns 1 before ever reaching link_ignored (see I2), so it cannot exercise this. A DANGLING link
# is `-L` true but `-e` false: without the -L test the `ln -s` dies "File exists" on BSD and GNU
# alike, and `set -e` inside acquire_task takes the whole claim down with it.
sed -n '/^link_ignored() {/,/^}/p' "$ZERO" > "$TO/li.sh"
rm -f "$wt4/issues"; ln -s "$TO/gone" "$wt4/issues"
( set -euo pipefail; . "$TO/li.sh"; CLAUDEZERO_LINK=issues link_ignored "$wt4" ); rc=$?
echo "O4 dangling exit   : $rc  (want 0 — the -L guard skips the name instead of failing on ln -s)"
echo "O4 dangling kept   : $([ -L "$wt4/issues" ] && [ ! -e "$wt4/issues" ] && echo yes || echo NO)  (want yes)"

# O5 — the merge gate is unchanged: ticks in a linked file are not counted as checked boxes
sed -i'' -e 's/^- \[ \] O1 /- [x] O1 /' "$wt/todo.md"
git -C "$wt" add todo.md; git -C "$wt" commit -qm 'O1 done'
"$ZERO" merge O1 "$wt" > "$TO/merge.log" 2>&1
echo "O5 merge exit      : $?  (want 0 — the gate scans only the todo file)"
echo "O5 refusal         : $(grep -c 'checkbox-merge: refused' "$TO/merge.log")  (want 0)"
DRIVE
```

### Run + assert
```bash
# -u CLAUDE_PID: see Scenario I — this driver IS the ancestor find_owner must walk to, and an
# inherited real CLAUDE_PID (an agent running this file autonomously has its own) would otherwise
# be trusted over the nearer stub.
TO="$TO" env -u CLAUDE_PID "$TO/bin/claude" "$TO/drive.sh"
```

### O6 — a bad `CLAUDEZERO_LINK` refuses the run at startup, before any claude
```bash
cd "$TO/repo"
git checkout -q -- todo.md 2>/dev/null; git stash -q 2>/dev/null || true   # O5 left the todo merged
export STUB_LAUNCHED="$TO/launched"; : > "$STUB_LAUNCHED"
printf '#!/usr/bin/env bash\necho launched >> "$STUB_LAUNCHED"\nexit 0\n' > "$TO/bin/cz-stub"; chmod +x "$TO/bin/cz-stub"
mkdir -p "$TO/stub"; cp "$TO/bin/cz-stub" "$TO/stub/claude"
run_bad(){ PATH="$TO/stub:$PATH" CLAUDEZERO_LINK="$1" timeout 30 env CLAUDEZERO_MAX_LOOPS=1 \
  bash "$SCRIPT" todo.md -t x > "$TO/bad-$2.log" 2>&1; echo $?; }
echo "O6 missing exit    : $(run_bad 'nosuchdir' missing)  (want 1)"
echo "O6 missing names it: $(grep -c "CLAUDEZERO_LINK entry 'nosuchdir' does not exist at" "$TO/bad-missing.log")  (want 1)"
echo "O6 nested exit     : $(run_bad 'issues/nested' nested)  (want 1)"
echo "O6 nested names it : $(grep -c "CLAUDEZERO_LINK entry 'issues/nested' is not a top-level name" "$TO/bad-nested.log")  (want 1)"
echo "O6 one bad kills   : $(run_bad 'issues,nosuchdir' mixed)  (want 1 — a good entry does not excuse a bad one)"
echo "O6 no launches     : $(wc -l < "$STUB_LAUNCHED" | tr -d ' ')  (want 0 — refused before the first session, so no tokens)"
```
- **O6 PASS** — `missing exit = 1`, `nested exit = 1`, `one bad kills = 1`, each with its naming
  line = 1, and `no launches = 0`.

### O7 — `--help` names the variable, so it is discoverable without the README
```bash
H="$(bash "$SCRIPT" -h)"
echo "O7 env block       : $(printf '%s' "$H" | grep -c 'Environment:')  (want 1)"
echo "O7 names the var   : $(printf '%s' "$H" | grep -c 'CLAUDEZERO_LINK=name\[,name')  (want 1 — the comma-separated form)"
echo "O7 says default    : $(printf '%s' "$H" | grep -c 'Unset by default')  (want 1)"
```
- **O7 PASS** — all three = 1.

- **O PASS** — every line reports its `want` value. Together they cover the link and its
  readability (O1), write-through with no commit and an empty `git add -A` (O1), the unlisted and
  unset cases (O1/O2), `link_ignored` carrying no validation of its own (O3), a second claim
  appending no duplicate `info/exclude` entry and a dangling link surviving the `-L` guard (O4),
  the untouched merge gate (O5), the startup refusals (O6), and the `--help` `Environment:` block (O7).

---

## Scenario P — the dependency-blocked wait (`CLAUDEZERO_DEPENDENCY_WAIT`)   `[$TESTROOT/P]`   (stub claude, deterministic)

Dependency judgment lives in claude's own prompt (step 2.a), invisible to the shell. Without a
signal, a fully dependency-blocked list looks identical to a genuinely stuck one: a session
launches, claims nothing, the shell restarts it after `RESTART_WAIT`, and it happens again —
one claude session burned per cycle for zero possible progress. Step 3 closes the gap: a session
that claims nothing marks the block (`.git/zero.sh no-claim-mark`) before ending its turn, and
the shell waits on a deterministic signature (the todo blob's SHA + the sorted ids peers
currently hold) instead of relaunching blindly.

### Setup
```bash
TP="$TESTROOT/P"; mkdir -p "$TP/repo" "$TP/bin"
cd "$TP/repo"
git init -q -b main; git config user.email t@t.t; git config user.name test
printf -- '- [ ] P1 x\n' > todo.md; git add -A; git commit -qm init
CLAUDEZERO_TEST_EMIT=1 bash "$SCRIPT" todo.md >/dev/null 2>&1   # writes .git/zero.sh once, up front
export STUB_ZERO="$TP/repo/.git/zero.sh"
export STUB_LAUNCHED="$TP/launched"
```

### P1 — a marker blocks relaunch until the todo blob's SHA changes; a distinct waiting line
```bash
cd "$TP/repo"
: > "$STUB_LAUNCHED"
cat > "$TP/bin/claude" <<'EOF'
#!/usr/bin/env bash
echo launched >> "$STUB_LAUNCHED"
n=$(wc -l < "$STUB_LAUNCHED" | tr -d ' ')
[ "$n" -eq 1 ] && "$STUB_ZERO" no-claim-mark   # only the FIRST launch marks the block, so the
exit 0                                          # marker file is provably gone once the wait ends
EOF
chmod +x "$TP/bin/claude"
( sleep 12; cd "$TP/repo"; sed -i'' -e 's/- \[ \]/- [x]/' todo.md; git add -A; git commit -qm 'flip P1' ) &
FLIPPER=$!
PATH="$TP/bin:$PATH" timeout 40 env CLAUDEZERO_MAX_LOOPS=2 CLAUDEZERO_DEPENDENCY_WAIT=5m bash "$SCRIPT" todo.md -t x > "$TP/p1.log" 2>&1
echo "P1 exit             : $?  (want 0)"
echo "P1 launches         : $(wc -l < "$STUB_LAUNCHED" | tr -d ' ')  (want 2 — one that marked the block, one after the flip broke it)"
echo "P1 dependency line  : $(grep -c 'waiting for a claimable task (now blocked 1)' "$TP/p1.log")  (want >=1 — its own wording, not wait_for_claimable's)"
echo "P1 no plain line    : $(grep -c '^❄ waiting for a claimable task · ' "$TP/p1.log")  (want 0 — P1 is never peer-held, so that wait never runs here)"
echo "P1 marker gone      : $(ls "$TP/repo/.git"/no-claim-* 2>/dev/null | wc -l | tr -d ' ')  (want 0 — consumed once read)"
wait "$FLIPPER" 2>/dev/null || true
```
- **P1 PASS** — `exit = 0`, `launches = 2`, `dependency line >= 1`, `no plain line = 0`, `marker gone = 0`.

### P2 — a peer's marker going stale (its worktree dies) breaks the wait even though the blob is unchanged
```bash
cd "$TP/repo"
printf -- '- [ ] P2 x\n- [ ] P2H y\n' >> todo.md; git add -A; git commit -qm 'add P2 tasks'
sleep 600 & PEER2=$!
git worktree add -q -b main-task-P2H "$TP/wt2h" main
printf '%s\n%s\n%s\n%s\n' "$PEER2" "$(ps -o lstart= -p "$PEER2" | awk '{$1=$1;print}')" "$(date +%s)" "PEERINST" > "$TP/wt2h/.owner"
mkdir -p "$TP/repo/.git/session"
printf '%s\n%s\n' "$(ps -o lstart= -p "$PEER2" | awk '{$1=$1;print}')" "P2H" > "$TP/repo/.git/session/$PEER2"
: > "$STUB_LAUNCHED"
( sleep 12; kill "$PEER2" 2>/dev/null ) &
KILLER=$!
PATH="$TP/bin:$PATH" timeout 40 env CLAUDEZERO_MAX_LOOPS=2 CLAUDEZERO_DEPENDENCY_WAIT=5m bash "$SCRIPT" todo.md -t x > "$TP/p2.log" 2>&1
echo "P2 exit             : $?  (want 0)"
echo "P2 launches         : $(wc -l < "$STUB_LAUNCHED" | tr -d ' ')  (want 2 — the wait broke on the held-ids change, no todo edit at all)"
wait "$KILLER" 2>/dev/null || true
git worktree remove --force "$TP/wt2h" 2>/dev/null || true; git branch -qD main-task-P2H 2>/dev/null || true
```
- **P2 PASS** — `exit = 0`, `launches = 2`.

### P3 — `CLAUDEZERO_DEPENDENCY_WAIT=0` relaunches immediately every cycle
```bash
cd "$TP/repo"
printf -- '- [ ] P3 x\n' >> todo.md; git add -A; git commit -qm 'add P3'
: > "$STUB_LAUNCHED"
PATH="$TP/bin:$PATH" timeout 20 env CLAUDEZERO_MAX_LOOPS=2 CLAUDEZERO_DEPENDENCY_WAIT=0 bash "$SCRIPT" todo.md -t x > "$TP/p3.log" 2>&1
echo "P3 exit             : $?  (want 0)"
echo "P3 launches         : $(wc -l < "$STUB_LAUNCHED" | tr -d ' ')  (want 2 — 0 disables the wait outright)"
echo "P3 no wait line     : $(grep -c 'now blocked' "$TP/p3.log")  (want 0)"
```
- **P3 PASS** — `exit = 0`, `launches = 2`, `no wait line = 0`.

### P4 — an unchanged signature past the ceiling forces a relaunch anyway
```bash
cd "$TP/repo"
printf -- '- [ ] P4 x\n' >> todo.md; git add -A; git commit -qm 'add P4'
: > "$STUB_LAUNCHED"
PATH="$TP/bin:$PATH" timeout 40 env CLAUDEZERO_MAX_LOOPS=2 CLAUDEZERO_DEPENDENCY_WAIT=6s bash "$SCRIPT" todo.md -t x > "$TP/p4.log" 2>&1
echo "P4 exit             : $?  (want 0)"
echo "P4 launches         : $(wc -l < "$STUB_LAUNCHED" | tr -d ' ')  (want 2 — nothing changed, so the ceiling itself ended the wait)"
echo "P4 marker gone      : $(ls "$TP/repo/.git"/no-claim-* 2>/dev/null | wc -l | tr -d ' ')  (want 0)"
```
- **P4 PASS** — `exit = 0`, `launches = 2`, `marker gone = 0`.

### P5 — absence check: no marker written, relaunch timing and output are unaffected
```bash
cd "$TP/repo"
printf -- '- [ ] P5 x\n' >> todo.md; git add -A; git commit -qm 'add P5'
cat > "$TP/bin/claude" <<'EOF'
#!/usr/bin/env bash
echo launched >> "$STUB_LAUNCHED"
exit 0
EOF
chmod +x "$TP/bin/claude"
: > "$STUB_LAUNCHED"
PATH="$TP/bin:$PATH" timeout 20 env CLAUDEZERO_MAX_LOOPS=2 bash "$SCRIPT" todo.md -t x > "$TP/p5.log" 2>&1
echo "P5 exit             : $?  (want 0)"
echo "P5 launches         : $(wc -l < "$STUB_LAUNCHED" | tr -d ' ')  (want 2 — a claude that never marks a block is never made to wait)"
echo "P5 no wait line     : $(grep -c 'now blocked' "$TP/p5.log")  (want 0 — no marker, no new poll)"
```
- **P5 PASS** — `exit = 0`, `launches = 2`, `no wait line = 0`.

### P6 — `-h`/`--help` names the variable
```bash
H="$(bash "$SCRIPT" -h)"
echo "P6 names the var    : $(printf '%s' "$H" | grep -c 'CLAUDEZERO_DEPENDENCY_WAIT=duration')  (want 1)"
```
- **P6 PASS** — `names the var = 1`.

- **P PASS** — every line reports its `want` value. Together they cover the marker blocking a
  relaunch until the blob changes and the wait's distinct line (P1), a peer's marker going stale
  as an independent trigger (P2), the `0` off-switch (P3), the ceiling forcing a relaunch when
  nothing changes (P4), the marker being consumed either way (P1/P4), the absence case costing no
  new sleep or poll (P5), and `--help` documenting the variable (P6).

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
# scoped to THIS run only: a nested real claude's --settings value is a JSON blob whose
# `command` field is $STOP_HOOK, always under $TESTROOT for every scenario — so this pattern
# never matches a claude/claudezero.sh process outside this run. Deliberately NOT a bare
# `claudezero.sh`/`claude .*--settings` pattern: that matches every such process on the
# machine, including this project's own real dogfood loop (if one happens to be running) and
# possibly the real agent itself, if its launch command line ever carries --settings too. Bare
# claudezero.sh loops need no separate catch here — every Run block already wraps its own
# invocation in `timeout`, which self-terminates them on schedule regardless of Cleanup.
pkill -f "$TESTROOT" 2>/dev/null || true
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
