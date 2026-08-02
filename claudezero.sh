#!/usr/bin/env bash
# claudezero.sh — run claude with a predefined first prompt in an endless loop.
#
# prerequisite: suggest-compact hook (https://github.com/affaan-m/ECC) installed globally in
# ~/.claude/settings.json, in a version that writes the per-session context-bucket state file
# (claude-context-bucket-<id>). We reuse that file as the "context full, restart" signal: when
# it appears the session Stop hook SIGTERMs claude and the loop restarts it on fresh context.
# No edit to the hook needed — we only read its state file.
#
# prerequisite: flock (brew install flock), runnable not just present. Serializes cross-instance
# merges and worktree rescues; without it parallel zeroing races and corrupts the base.

# Run -h for usage.
set -euo pipefail

VERSION="0.0.15"
PROG="$(basename "$0")"   # name shown in usage/errors, from how the script was invoked

LOOP_INTERVAL="3m"   # cadence claude reschedules its zeroing pass at (baked into the /loop prompt)
RESTART_WAIT=5       # seconds between claude restarts — the window to press Ctrl+C

# The braces around the pipe reader in the logging example are load-bearing — do NOT tidy them
# into a bare pipe. Ctrl+C signals the whole foreground group; the reader's default SIGINT action
# is terminate, and once it dies the log has no writer left, losing exactly the closing report the
# operator ran the pipe for. `trap '' INT` sets *ignore*, which survives `exec`, so the reader
# inherits it and drains the pipe until ClaudeZero exits.
usage() {
  # single-quoted heredoc keeps backticks literal; sed injects the RESTART_WAIT constant.
  sed -e "s/@@RESTART_WAIT@@/$RESTART_WAIT/g" -e "s/@@PROG@@/$PROG/g" -e "s/@@VERSION@@/$VERSION/g" <<'USAGE'
usage: @@PROG@@ [todo-file-path] [-t|--taskprompt TEXT | -l|--loopprompt TEXT]
version @@VERSION@@

  Loops claude to zero a Markdown todo file — fork a worktree per task, implement,
  commit, merge, restart on fresh context — until every box is checked. Run several
  in parallel; they claim tasks via git worktrees. Ctrl+C in the @@RESTART_WAIT@@s gap stops.

  todo-file-path         Todo.md to zero (zero mode). Omitted → prompted for it.
  -t, --taskprompt TEXT  How claude processes ONE task. Default "Follow your setup."
  -l, --loopprompt TEXT  Loop claude on this literal prompt (skips zero mode).
      --doctor           Check prerequisites, then exit.
  -h, --help             Show this help.

  -t and -l are mutually exclusive.

  Log a run (ClaudeZero's own output only; claude's TUI stays on the terminal):

    @@PROG@@ issues/todo.md 2>&1 | { trap '' INT; tee ../run.log; }

  The `trap` keeps tee alive through Ctrl+C so the final report lands in the file.
USAGE
}

# Self-contained install instructions for the suggest-compact hook, inlined from the README so the
# hint needs no network and no README file. Keep in sync with the README "Install" section.
# shellcheck disable=SC2016  # $TMPDIR is literal instructional text shown to the user, must not expand
INSTALL_HINT='Install the suggest-compact Claude Code hook globally in ~/.claude/settings.json (requires node). Source: https://github.com/affaan-m/ECC pinned to commit 7777656. The hook must write a per-session file at $TMPDIR/claude-context-bucket-<session_id> once the context bucket crosses its threshold; presence of that file is the "context full, restart" signal ClaudeZero reads. ClaudeZero only reads the file, so no other edits are needed.'

# hook_missing REASON: print why the suggest-compact prerequisite failed plus a ready-to-run
# command that has Claude install it, then exit. Single hint for every hook path.
hook_missing() {
  echo "$PROG: $1" >&2
  echo "" >&2
  echo "Install the suggest-compact hook, then retry. To have Claude set it up for you, run:" >&2
  echo "" >&2
  echo "  claude \"$INSTALL_HINT\"" >&2
  exit 1
}

# run_doctor: verify every prerequisite (claude CLI, suggest-compact hook, flock). The single
# source of truth for prerequisite checks — run on normal startup AND via `--doctor` (which the
# brew formula calls as a post-install step). Exits nonzero with an actionable message on failure.
run_doctor() {
  # guard: claude CLI present.
  command -v claude >/dev/null 2>&1 || { echo "$PROG: claude CLI not found on PATH — install Claude Code: https://claude.com/product/claude-code"; exit 1; }

  # guard: suggest-compact prerequisite (see top) — installed and writes the context-bucket file.
  SETTINGS="$HOME/.claude/settings.json"
  [ -f "$SETTINGS" ] || hook_missing "$SETTINGS not found"
  # pull the .js path out of the hook command line
  HOOK_JS="$(grep -oE '[^" ]*suggest-compact\.js' "$SETTINGS" | head -1)"
  [ -n "$HOOK_JS" ] || hook_missing "suggest-compact hook not installed in $SETTINGS"
  HOOK_JS="${HOOK_JS/#\$HOME/$HOME}"; HOOK_JS="${HOOK_JS/#\~/$HOME}"
  [ -f "$HOOK_JS" ] || hook_missing "hook script not found at $HOOK_JS"
  grep -q 'claude-context-bucket-' "$HOOK_JS" \
    || hook_missing "suggest-compact hook lacks the context-size signal (writes no claude-context-bucket file); update it"

  # guard: flock prerequisite (see top) — present AND runnable.
  command -v flock >/dev/null 2>&1 || { echo "$PROG: flock not found on PATH (Linux: util-linux; macOS: brew install flock)"; exit 1; }
  flock -n "$(mktemp)" true 2>/dev/null || { echo "$PROG: flock present but not runnable"; exit 1; }
}

# --doctor: run the prerequisite checks only, then exit. Used by `brew install` as a post-install
# step and for manual troubleshooting; any other args fall through to a normal run.
if [ "${1:-}" = --doctor ]; then run_doctor; echo "$PROG: all prerequisites OK."; exit 0; fi

# normal startup guard (fail-fast, before any side effects). Skipped under CLAUDEZERO_TEST_EMIT:
# that path only writes the generated scripts for CI to shellcheck and exits before launching
# claude, so CI needn't have claude/the hooks installed. See .github/check-embedded.sh.
[ -n "${CLAUDEZERO_TEST_EMIT:-}" ] || run_doctor


# claude restart loop: run claude, accumulate timing, repeat until all todos land / Ctrl+C /
# MAX_LOOPS. Reads main()'s globals (PROMPT, STOP_SETTINGS, INSTANCE_ID); own state stays global
# (no `local`) so the INT trap + print_report see it.
run_loop() {
# CLAUDEZERO_MAX_LOOPS: exit after N iterations instead of looping until Ctrl+C. 0/unset =
# unlimited (normal). Set >0 for tests so the loop self-terminates without a SIGINT.
MAX_LOOPS="${CLAUDEZERO_MAX_LOOPS:-0}"
# fd 4 = where claude's own chatter goes. Redirected stdout + stdin still on the terminal → claude
# keeps writing to the terminal, so piping claudezero.sh to a log file records the ❄ reports, not
# the TUI. No redirect, or stdin not a terminal (tests, CI, nohup) → fd 4 is plain stdout, as today.
# Dup stdin rather than open /dev/tty: on macOS a descriptor opened from the /dev/tty clone device
# is not kqueue-registrable, and claude dies at startup with `EINVAL … kqueue`. The tty stdin the
# shell was handed is a real terminal fd, opened read-write, so it takes writes and kqueue both.
if [ ! -t 1 ] && [ -t 0 ]; then exec 4>&0; else exec 4>&1; fi
LOOP_COUNT=0
STOP=0                    # set by the INT trap; the loop breaks to the closer below
TODOS_BASE=$(read_counter "${TODOS_TIME_FILE:-}")   # snapshot: report only THIS run's slice of the shared aggregates
TODOS_DONE_BASE=$(read_counter "${TODOS_DONE_FILE:-}")
LOOP_START=$(date +%s)   # script loop (outer while loop) starts here

# Ctrl+C during the between-runs sleep (cooked mode) requests a clean stop; the loop breaks to the
# single closer below (during chat the tty is raw, so Ctrl+C goes to claude, not here). Set AFTER
# the timing vars so the report can read them.
trap 'STOP=1' INT

reap_dead_sessions   # startup: clear markers left by crashed prior runs before the first claude
while true; do
    # first prompt submitted straight from the CLI arg. The session Stop hook SIGTERMs claude
    # when context fills; exit 143 is the normal restart path, so swallow it.
    CLAUDEZERO_INSTANCE="$INSTANCE_ID" CLAUDEZERO_TRANSCRIPTS="$TRANSCRIPTS_FILE" \
        claude --settings "$STOP_SETTINGS" --permission-mode auto --name "$SESSION_NAME" "$PROMPT" >&4 2>&4 || true
    # claude killed mid-run (Ctrl+C/SIGTERM) can leave the tty in raw mode with ISIG off; then every
    # later Ctrl+C arrives as a 0x03 byte, not a SIGINT, so the INT trap never fires and the loop
    # spins forever restarting claude on a wedged terminal. Restore cooked mode so Ctrl+C signals again.
    if [ -t 0 ]; then stty sane 2>/dev/null || true; fi
    NOW=$(date +%s)
    LOOP_COUNT=$((LOOP_COUNT+1))
    printf '\n\n'
    if [ "$MAX_LOOPS" -gt 0 ] && [ "$LOOP_COUNT" -ge "$MAX_LOOPS" ]; then
        printf '\n❄ claude exited after %s runs · reached CLAUDEZERO_MAX_LOOPS=%s · stopping\n' "$LOOP_COUNT" "$MAX_LOOPS"
        break
    fi
    print_report "$NOW"
    dojo_wisdom
    printf '\n❄ claude exited after %s runs · restarting in %ss · press Ctrl+C to stop\n' "$LOOP_COUNT" "$RESTART_WAIT"
    sleep "$RESTART_WAIT" || true          # SIGINT interrupts sleep and fires the INT trap
    if [ "$STOP" = 1 ]; then printf '\n❄ run loop stopped\n'; break; fi
done

# single closer — every exit path (Ctrl+C or MAX_LOOPS) lands here, so dojo_proud lives in one place.
# The exit report goes here too: the loop's own report prints before the between-runs sleep, so a
# Ctrl+C in that gap used to end the run on figures stale by one claude run. After credit_inflight_time
# so a task still in flight is folded in before the files are read.
credit_inflight_time
print_report "$(date +%s)"
print_fleet_total
if all_todos_done; then dojo_proud; fi
reap_dead_sessions   # no future acquire will reap this session's marker
}

# entrypoint. Resolves the prompt (zero or loop mode), installs the session Stop hook,
# then loops claude.
main() {
# tasks fork from + merge back to whatever branch is checked out now.
BASE_BRANCH="$(git rev-parse --abbrev-ref HEAD)"

# per-instance id: isolates this instance's todo-time from peers zeroing the same base, so you can
# compare instances after a run and size the fleet next time. Exported into claude's env below,
# inherited by its Bash-tool children; zero.sh reads it (CLAUDEZERO_INSTANCE) to route credit.
INSTANCE_ID="$(uuidgen 2>/dev/null | tr -d - | head -c8)"; [ -n "$INSTANCE_ID" ] || INSTANCE_ID="$$"

# -t/--taskprompt sets the zero task prompt; -l/--loopprompt runs claude on a
# literal prompt (skips zero mode). They are mutually exclusive.
TASK_PROMPT=""; TASK_SET=0
LOOP_PROMPT=""; LOOP_SET=0
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)          usage; exit 0 ;;
    -t|--taskprompt)    [ $# -ge 2 ] || { echo "$PROG: $1 needs a value"; exit 1; }; TASK_PROMPT="$2"; TASK_SET=1; shift 2 ;;
    --taskprompt=*)     TASK_PROMPT="${1#*=}"; TASK_SET=1; shift ;;
    -l|--loopprompt)    [ $# -ge 2 ] || { echo "$PROG: $1 needs a value"; exit 1; }; LOOP_PROMPT="$2"; LOOP_SET=1; shift 2 ;;
    --loopprompt=*)     LOOP_PROMPT="${1#*=}"; LOOP_SET=1; shift ;;
    --)                 shift; while [ $# -gt 0 ]; do ARGS+=("$1"); shift; done ;;
    -*)                 echo "$PROG: unknown option: $1"; usage; exit 1 ;;
    *)                  ARGS+=("$1"); shift ;;
  esac
done
set -- ${ARGS[@]+"${ARGS[@]}"}   # guard empty-array expansion under set -u (portable)

[ "$TASK_SET" = 1 ] && [ "$LOOP_SET" = 1 ] && { echo "$PROG: -t/--taskprompt and -l/--loopprompt are mutually exclusive"; exit 1; }
[ $# -le 1 ] || { echo "$PROG: too many positional args; expected at most one todo-file-path"; exit 1; }
TODO_ARG="${1:-}"

printf '\n❄ ClaudeZero %s\n' "$VERSION"
if [ "$LOOP_SET" = 1 ]; then
    MODE=loop
    [ -n "$TODO_ARG" ] && echo "$PROG: warning: todo-file-path ignored in --loopprompt mode" >&2
    printf '  loop mode · claude on a literal prompt\n\n'
    PROMPT="$LOOP_PROMPT"
else
    MODE=zero
    # task prompt tells claude HOW to process one task (step 2.e).
    TASK_PROMPT="${TASK_PROMPT:-Implement the task following your setup.}"
    # guardrail: the merge step runs `git merge` on the main tree, so it must be a real branch
    # (not detached) and CLEAN before we start — else refuse and let the human decide.
    [ "$BASE_BRANCH" != HEAD ] || { echo "$PROG: detached HEAD — check out the base branch first."; exit 1; }
    # guardrail: claude's Bash calls run from cwd, and the zero prompt + `.git/zero.sh` + `../ts-*`
    # worktree paths all assume cwd is the main worktree's root — refuse a subdir launch, and a
    # launch inside a leftover `../ts-*` claim worktree, so they never misfire. The first entry of
    # `git worktree list --porcelain` is always the main worktree, so one compare covers both.
    REPO_ROOT="$(git worktree list --porcelain | sed -n '1s/^worktree //p')"
    [ "$PWD" = "$REPO_ROOT" ] || { echo "$PROG: not at the main repo root — cd to '$REPO_ROOT' first. (ClaudeZero's own ../ts-* task worktrees are never valid launch dirs.)"; exit 1; }
    [ -z "$(git status --porcelain)" ] || { echo "$PROG: working tree on '$BASE_BRANCH' is dirty — commit or stash first."; git status --short; exit 1; }
    printf '  zero mode · base %s · fork → implement → commit → merge\n\n' "$BASE_BRANCH"
    # todo path: from the positional arg, else ask interactively.
    if [ -n "$TODO_ARG" ]; then TODO_PATH="$TODO_ARG"; else read -r -p "Path to todo.md file: " TODO_PATH; fi
    [ -n "$TODO_PATH" ] || { echo "$PROG: no path entered"; exit 1; }
    [ -f "$TODO_PATH" ] || { echo "$PROG: file not found: $TODO_PATH"; exit 1; }
    # hand claude a path relative to its cwd (accepts abs or rel input): resolve to absolute,
    # strip the cwd prefix, reject anything outside the tree.
    ABS_PATH="$(cd "$(dirname "$TODO_PATH")" && pwd)/$(basename "$TODO_PATH")"
    case "$ABS_PATH" in
        "$PWD/"*) TODO_PATH="${ABS_PATH#"$PWD"/}" ;;
        *) echo "$PROG: path not under working dir $PWD: $TODO_PATH"; exit 1 ;;
    esac
    # guardrail: the merge gate diffs the todo against the branch's fork point on the base, so a
    # todo that is not tracked there (never added, or gitignored — the dirty-tree guard above misses
    # a gitignored file) makes EVERY merge refuse "newly checks 0 boxes" and nothing can ever land.
    git cat-file -e "$BASE_BRANCH:$TODO_PATH" 2>/dev/null || { echo "$PROG: '$TODO_PATH' is not tracked on '$BASE_BRANCH' — commit it there first, else every merge is refused and no task can land."; exit 1; }
    PROMPT="$(build_zero_prompt "$TODO_PATH" "$TASK_PROMPT")"
fi

# session-scoped Stop hook: written into the git dir, wired via `claude --settings` so ONLY the
# session we launch gets it (parallel zero-mode sessions stay isolated; global settings.json untouched).
# --settings MERGES over global config and hooks are additive, so suggest-compact keeps firing and
# this Stop hook is added on top. Fires at each turn end; SIGTERMs claude once suggest-compact has
# written the session's context-bucket file (threshold crossed), and the loop restarts it fresh.
GITDIR_ABS="$(cd "$(git rev-parse --git-dir)" && pwd)"
SESSION_DIR="$(cd "$(git rev-parse --git-common-dir)" && pwd)/session"   # matches zero.sh's marker dir
TODOS_TIME_FILE="$(cd "$(git rev-parse --git-common-dir)" && pwd)/todos-seconds-${BASE_BRANCH//\//-}-$INSTANCE_ID"   # this instance's file (matches zero.sh's todos_file)
TODOS_DONE_FILE="$(cd "$(git rev-parse --git-common-dir)" && pwd)/todos-done-${BASE_BRANCH//\//-}-$INSTANCE_ID"      # count of todos this instance merged (matches zero.sh's todos_done_file)
# this instance's list of claude session transcripts (one path per line, appended by the Stop hook).
# Namespaced like the time-file so parallel instances never read each other's token figures.
TRANSCRIPTS_FILE="$(cd "$(git rev-parse --git-common-dir)" && pwd)/transcripts-${BASE_BRANCH//\//-}-$INSTANCE_ID"
ZERO_SH="$GITDIR_ABS/zero.sh"   # where build_zero_prompt wrote the helper (zero mode only)
INSTANCE_DIR="$(cd "$(git rev-parse --git-common-dir)" && pwd)/instance"

# register this instance (liveness marker), remove it on any exit, then GC dead runs' time-files.
# EXIT fires on normal end, MAX_LOOPS break, and after the INT trap's `exit 0` — marker always cleared.
mkdir -p "$INSTANCE_DIR"; printf '%s\n%s\n' "$$" "$(proc_start "$$")" > "$INSTANCE_DIR/$INSTANCE_ID"
trap 'rm -f "$INSTANCE_DIR/$INSTANCE_ID" 2>/dev/null' EXIT
cleanup_orphan_time_files

# claude's display name (prompt box, /resume picker, terminal title) — the same id and nickname the
# report heads its stats with, the nickname short enough to say out loud, and a dojo-student activity, so parallel
# terminals are told apart without reading hex. The id and activity are derived from the id, never
# from chance; the nickname is picked once here, so every restart re-launches under the same name.
INSTANCE_NICK="$(pick_nickname)"    # kept in a var: the report header says it too, and it is drawn once
SESSION_NAME="($INSTANCE_ID) $INSTANCE_NICK · $(dojo_student "$INSTANCE_ID")"

STOP_HOOK="$GITDIR_ABS/compact-exit-hook.sh"
cat >"$STOP_HOOK" <<'HOOK_EOF'
#!/usr/bin/env bash
# Stop hook. Fires post-turn (transcript already persisted). If suggest-compact wrote its
# per-session context-bucket file (= threshold crossed), SIGTERM the owning claude so the outer
# loop restarts fresh. Reusing that bucket file as the signal means no separate flag and no edit
# to the hook. Couples to its filename/tmpdir; update if ECC changes them.
input="$(cat)"
# token accounting: record this session's transcript path for the outer loop to sum after claude
# exits. The hook file is shared by all instances in this git dir, so the destination comes from
# the env of the claude WE launched (CLAUDEZERO_TRANSCRIPTS), never baked in. One line per path;
# best-effort, never fails the turn.
tf="${CLAUDEZERO_TRANSCRIPTS:-}"
if [ -n "$tf" ]; then
  tp="$(printf '%s' "$input" | sed -n 's/.*"transcript_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  [ -n "$tp" ] && ! grep -qxF "$tp" "$tf" 2>/dev/null && printf '%s\n' "$tp" >> "$tf"
fi
sid="$(printf '%s' "$input" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | tr -cd 'A-Za-z0-9_-')"
[ -n "$sid" ] || exit 0
dir="${TMPDIR:-${TMP:-${TEMP:-/tmp}}}"; dir="${dir%/}"      # match node os.tmpdir()
[ -f "$dir/claude-context-bucket-$sid" ] || exit 0          # threshold not crossed → keep going
# nearest ancestor named 'claude' → SIGTERM (graceful: reaps bash tree, runs SessionEnd hooks,
# exits 143). Turn already saved, so the kill loses nothing.
pid=$PPID; depth=0
while [ -n "$pid" ] && [ "$pid" -gt 1 ] && [ "$depth" -lt 8 ]; do
  comm="$(ps -o comm= -p "$pid" 2>/dev/null)" || exit 0
  [ "${comm##*/}" = claude ] && { kill -TERM "$pid"; exit 0; }
  pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
  depth=$((depth+1))
done
exit 0
HOOK_EOF
chmod +x "$STOP_HOOK"

# inline settings JSON merged over global config via --settings. git-dir path has no JSON
# metachars, so a bare interpolation is safe.
STOP_SETTINGS="$(printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"%s"}]}]}}' "$STOP_HOOK")"

# test hook: with CLAUDEZERO_TEST_EMIT set, init has now written its generated scripts
# (compact-exit-hook.sh + zero.sh + checkbox-merge.sh in zero mode) — stop before launching
# claude so CI can shellcheck the real emitted artifacts. See .github/check-embedded.sh.
[ -n "${CLAUDEZERO_TEST_EMIT:-}" ] && { echo "$PROG: CLAUDEZERO_TEST_EMIT set — wrote generated scripts to $GITDIR_ABS, exiting."; exit 0; }

# everything prepared (PROMPT, STOP_SETTINGS, INSTANCE_ID, hooks, registry); drive the
# claude restart loop until all todos land (zero mode) / Ctrl+C / MAX_LOOPS.
run_loop
}

# format a duration in seconds as HhMMmSSs, dropping leading zero units.
fmt_dur() {
  local s=$1
  if   [ "$s" -ge 3600 ]; then printf '%dh%02dm%02ds' $((s/3600)) $((s%3600/60)) $((s%60))
  elif [ "$s" -ge 60 ];   then printf '%dm%02ds' $((s/60)) $((s%60))
  else                         printf '%ds' "$s"; fi
}

# format a token count as 5.8M / 84.3k / 312 — integer arithmetic only (bash 3.2 has no floats).
fmt_tok() {
  local n=$1
  if   [ "$n" -ge 1000000 ]; then printf '%d.%dM' $((n/1000000)) $(( (n%1000000)/100000 ))
  elif [ "$n" -ge 1000 ];    then printf '%d.%dk' $((n/1000))    $(( (n%1000)/100 ))
  else                            printf '%d' "$n"; fi
}

# sum this instance's claude token usage over the session transcripts its Stop hook recorded.
# Echoes "input output cache_create cache_read total"; EMPTY when nothing parses → report says n/a.
# Whole-file pass per call, not incremental byte offsets: a duplicate-requestId group can straddle
# an incremental boundary and get double-counted. Transcripts are bounded by the restart-at-
# context-threshold design, so re-reading them is cheap.
#   dedupe by requestId — ONE API request is written as several transcript lines, one per content
#     block (text, tool_use, thinking), each repeating the SAME usage object verbatim. Summing per
#     line inflates every figure by the average blocks-per-turn.
#   first match per line is the parent field — usage.iterations[] repeats all four names one level
#     down, and usage.cache_creation carries the ephemeral_5m/1h leaves that already sum into
#     cache_creation_input_tokens. Take the parent only, never the leaves or the nested copy.
# $1 = transcript-list file, default this instance's — the fleet total passes each peer's in turn.
read_tokens_total() {
  local tf=${1:-${TRANSCRIPTS_FILE:-}} p
  [ -n "$tf" ] && [ -f "$tf" ] || return 0
  while IFS= read -r p; do
    if [ -f "$p" ]; then cat "$p"; fi
  done < "$tf" | awk '
    function num(key,   s) {
      if (!match($0, "\"" key "\":[0-9]+")) return 0
      s = substr($0, RSTART, RLENGTH); sub(/.*:/, "", s); return s + 0
    }
    /"output_tokens":/ {
      k = match($0, /"requestId":"[^"]+"/) ? substr($0, RSTART + 13, RLENGTH - 14) : "line" NR
      if (k in seen) next
      seen[k] = 1; n++
      i  += num("input_tokens");                o  += num("output_tokens")
      cc += num("cache_creation_input_tokens"); cr += num("cache_read_input_tokens")
    }
    END { if (n) printf "%d %d %d %d %d\n", i, o, cc, cr, i + o + cc + cr }' 2>/dev/null
}

# the report's token block: headline total, then the four billed categories beneath it. They do not
# overlap (total_input = cache_read + cache_creation + input, output on its own axis) and each bills
# at its own rate, so the total is a SCALE figure for comparison, not a cost. No money figure: there
# is no first-party programmatic rate source, only a hardcoded table that would rot. Degrade, never
# lie — a parse miss, a missing transcript or a schema change prints n/a and leaves the run alone.
print_tokens() {
  local t; t="$(read_tokens_total || true)"
  # shellcheck disable=SC2086  # deliberate split: awk emits five space-separated integers
  set -- $t
  if [ "$#" -ne 5 ]; then printf '\n  Tokens: n/a\n'; return 0; fi
  printf '\n  Tokens: %s Total\n' "$(fmt_tok "$5")"
  printf '  in %s · out %s · cache write %s · cache read %s\n' \
    "$(fmt_tok "$1")" "$(fmt_tok "$2")" "$(fmt_tok "$3")" "$(fmt_tok "$4")"
}

# read one of zero.sh's per-instance aggregates ($1 = path: seconds of task ownership, or todos
# merged), 0 if absent/unset/garbled.
read_counter() {
  local v=0 f=${1:-}
  [ -n "$f" ] && [ -f "$f" ] && { read -r v < "$f" 2>/dev/null || v=0; }
  case "$v" in ''|*[!0-9]*) v=0;; esac
  printf '%s' "$v"
}

# have all todos landed on the base branch? (zero mode only) — zero unchecked `- [ ]` AND at least
# one `- [x]`. Same invariant behind claude's "ALL TASKS DONE", read straight from git —
# deterministic, no stdout parsing. First true reading = the all-done moment.
all_todos_done() {
  [ "${MODE:-}" = zero ] || return 1
  git show "$BASE_BRANCH:$TODO_PATH" 2>/dev/null | awk '
    /^[ \t]*```/       { fence = !fence; next }   # skip checkboxes inside fenced code blocks
    fence              { next }                   # (example issues), only real tasks count
    /^[ \t]*- \[ \]/    { unchecked=1 }
    /^[ \t]*- \[[ x]\]/ { any=1 }
    END { exit (any && !unchecked) ? 0 : 1 }'
}

# multiline execution-stats report. $1 = now epoch.
#   Todos       = per-task ownership time and count of todos merged, this run's delta of zero.sh's
#                 aggregates
#   Script loop = wall time of the outer while loop (claude runs + between-run sleeps)
#   Tokens      = this instance's claude token usage, own block (not a duration, so it does not
#                 share the timing rows' label column)
print_report() {
  printf '\n❄ execution stats (instance %s · %s)\n' "${INSTANCE_ID:-?}" "${INSTANCE_NICK:-?}"
  if [ "${MODE:-}" = zero ]; then
    printf '  %-20s %s  ·  %s completed\n' 'Todos:' \
      "$(fmt_dur $(( $(read_counter "${TODOS_TIME_FILE:-}") - TODOS_BASE )))" \
      "$(( $(read_counter "${TODOS_DONE_FILE:-}") - TODOS_DONE_BASE ))"
  fi
  printf '  %-20s %s\n' 'ClaudeZero run loop:' "$(fmt_dur $(( $1 - LOOP_START )))"
  print_tokens
}

# fleet-wide TOTAL for this base, printed once on the exit path beneath this instance's report.
# The sum is a GLOB, not a registry: every figure is already one file per instance in the git common
# dir, so a shared aggregate would only be a second copy that can disagree with the first. Read
# without flock — all three writers publish with temp-file + mv, so a reader sees the old file or
# the new one, never a torn line. No baseline: per-instance files are created fresh under a new
# INSTANCE_ID each launch and dead runs' files are GC'd at startup, so what is on disk IS this run;
# subtracting a startup snapshot would under-report peers that started earlier. A crashed peer's
# files are summed too — its merged todos did land. A solo run prints the block as well: its figures
# restate the block above, but the heading carries the instance count, which nothing else prints and
# which is worth most when it reads 1 — that is the case an absent block cannot be told apart from a
# sum that matched no files (BUG-022). Zero ids stays silent, so absence keeps one meaning.
# `ClaudeZero run loop:` is omitted — instances' wall times overlap, so their sum is not a duration
# anything took.
print_fleet_total() {
  local gc slug pre f id ids="" n=0 secs=0 done_n=0 t any=0 ti=0 to=0 tcc=0 tcr=0 tt=0 plural=s
  gc="$(cd "$(git rev-parse --git-common-dir)" 2>/dev/null && pwd)" || return 0
  [ -n "$gc" ] || return 0
  slug="${BASE_BRANCH//\//-}"
  for pre in todos-seconds todos-done transcripts; do    # union: an instance that merged nothing
    for f in "$gc/$pre-$slug-"*; do                      # writes no todos-done file, but has tokens
      [ -e "$f" ] || continue
      case "$f" in *.lock|*.tmp) continue;; esac
      id="${f##*/"$pre"-"$slug"-}"
      case " $ids " in *" $id "*) continue;; esac
      ids="$ids $id"; n=$((n+1))
    done
  done
  [ "$n" -ge 1 ] || return 0    # n=0: no files for this slug — stay silent, absence means only that
  if [ "$n" -eq 1 ]; then plural=""; fi
  for id in $ids; do
    secs=$((   secs   + $(read_counter "$gc/todos-seconds-$slug-$id") ))
    done_n=$(( done_n + $(read_counter "$gc/todos-done-$slug-$id") ))
    t="$(read_tokens_total "$gc/transcripts-$slug-$id" || true)"
    # shellcheck disable=SC2086  # deliberate split: awk emits five space-separated integers
    set -- $t
    if [ "$#" -eq 5 ]; then any=1; ti=$((ti+$1)); to=$((to+$2)); tcc=$((tcc+$3)); tcr=$((tcr+$4)); tt=$((tt+$5)); fi
  done
  printf '\n-----------------------------------------------\n'
  printf '❄ TOTAL (%s instance%s)\n' "$n" "$plural"
  if [ "${MODE:-}" = zero ]; then
    printf '  %-20s %s  ·  %s completed\n' 'Todos:' "$(fmt_dur "$secs")" "$done_n"
  fi
  if [ "$any" = 1 ]; then
    printf '\n  Tokens: %s Total\n' "$(fmt_tok "$tt")"
    printf '  in %s · out %s · cache write %s · cache read %s\n' \
      "$(fmt_tok "$ti")" "$(fmt_tok "$to")" "$(fmt_tok "$tcc")" "$(fmt_tok "$tcr")"
  else
    printf '\n  Tokens: n/a\n'
  fi
}

# credit orphaned in-flight tasks before an exit-path report: zero.sh folds worktrees whose owner
# claude exited (mid-task work never merged nor stolen) into the todos aggregate. No-op in loop
# mode / before zero.sh exists. Never fails the caller.
credit_inflight_time() { if [ "${MODE:-}" = zero ] && [ -x "${ZERO_SH:-}" ]; then "$ZERO_SH" credit_inflight_time >/dev/null 2>&1 || true; fi; }

# A random line for the between-runs (Ctrl+C) screen — something to read while the restart ticks.
dojo_wisdom() {
  local w=(
    'ClaudeZero: "One track, one task, one clean strike — do not chase the whole mountain at once."'
    'ClaudeZero: "When your mind fills like a snow-heavy branch, let it fall. The empty branch holds the next snow clean."'
    'ClaudeZero: "Your power is endless; your haste is not. Spend the cold freely, the moment slowly."'
    'ClaudeZero: "A checkbox is a breath held. Commit, and let it out."'
    'ClaudeZero: "Freeze what is yours. Never shatter what another still holds."'
    'ClaudeZero: "Many hunters, one mountain — claim a track no other walks."'
    'ClaudeZero: "Do not finish the list. Teach the list to finish itself."'
    'ClaudeZero: "Read the breath and the weight, then commit everything. Never hedge."'
    'ClaudeZero: "Where two paths cross in conflict, step back. Some snow is for human hands."'
    'ClaudeZero: "Rot creeps into the mind that never rests. Take winter'\''s gift: the clean, cold restart."'
    'ClaudeZero: "Hold the line alone when the context flees."'
    'ClaudeZero pauses, and thinks.'
    'ClaudeZero yawns, and curls his tail over his paws.'
    'ClaudeZero grooms a paw, unhurried.'
    'ClaudeZero chirps softly at the falling snow.'
    'ClaudeZero stretches, long and slow, and says nothing.'
  )
  printf '\n❄ %s\n' "${w[RANDOM % ${#w[@]}]}"
}
# what the student under ClaudeZero's guidance is busy with — the tail of a claude session's
# display name. $1 = instance id; the first two chars (hex from uuidgen, decimal from the $$
# fallback — both valid hex) pick the line, so the name is stable across context restarts.
dojo_student() {
  local a=(
    'drilling the fork-implement-merge kata'
    'hauling snow buckets uphill'
    'claiming a track before stepping on it'
    'reading the whole task before striking'
    'starting over on fresh snow'
    'carving checkbox after checkbox into ice'
    'hunting the next box on the list'
    'practicing one clean strike per task'
    "leaving a peer's branch untouched"
    'walking back to the merge gate'
  )
  printf '%s' "${a[$(( 16#${1:0:2} % 10 ))]}"
}
# the proud closer — his quiet nod of pride, printed independently once every todo has landed.
dojo_proud() { printf '\n❄ ClaudeZero surveys the frozen field, and is proud.\n'; }

# unlink session markers (see zero.sh) whose owner pid is gone or was recycled. zero.sh GCs these
# on every acquire; this covers FINAL exit, when no future acquire reaps the last session's marker.
# Reap by liveness — no need to capture the just-exited claude's pid.
reap_dead_sessions() {
  [ -n "${SESSION_DIR:-}" ] && [ -d "$SESSION_DIR" ] || return 0
  local f pid st
  for f in "$SESSION_DIR"/*; do
    [ -e "$f" ] || continue
    pid=${f##*/}; { read -r st; } < "$f" 2>/dev/null || st=""
    if kill -0 "$pid" 2>/dev/null && [ "$(ps -o lstart= -p "$pid" 2>/dev/null | awk '{$1=$1;print}')" = "$st" ]; then continue; fi
    rm -f "$f"
  done
}

# --- per-instance liveness registry: lets us GC per-instance todo-time files from dead runs -------
# Each instance writes $INSTANCE_DIR/<id> (line1=pid line2=start-time) while alive, removed on exit.
# A time-file is an orphan iff its id has no LIVE marker (crash-leaked markers are GC'd by liveness).
proc_start() { ps -o lstart= -p "$1" 2>/dev/null | awk '{$1=$1;print}'; }
instance_alive() { kill -0 "$1" 2>/dev/null && [ "$(proc_start "$1")" = "$2" ]; }   # $1=pid $2=start
# delete todos-seconds-<base>-<id> / todos-done-<base>-<id> (+ .lock/.tmp sidecars) whose instance
# is not live. Called at startup AFTER our marker is written, so this instance and live peers are
# always preserved.
cleanup_orphan_time_files() {
  [ -n "${INSTANCE_DIR:-}" ] || return 0
  local gc slug f id m pid st pre
  gc="$(cd "$(git rev-parse --git-common-dir)" && pwd)"; slug="${BASE_BRANCH//\//-}"
  if [ -d "$INSTANCE_DIR" ]; then                       # GC crash-leaked markers first
    for m in "$INSTANCE_DIR"/*; do
      [ -e "$m" ] || continue
      { read -r pid; read -r st; } < "$m" 2>/dev/null || { pid=""; st=""; }
      instance_alive "${pid:-0}" "${st:-}" || rm -f "$m"
    done
  fi
  for pre in todos-seconds todos-done; do
    for f in "$gc/$pre-$slug-"*; do
      [ -e "$f" ] || continue
      case "$f" in *.lock|*.tmp) continue;; esac           # sidecars swept with their base file below
      id="${f##*/"$pre"-"$slug"-}"
      [ -f "$INSTANCE_DIR/$id" ] && continue                # id still has a (live) marker → keep
      rm -f "$f" "$f.lock" "$f.tmp"
    done
  done
  for f in "$gc/transcripts-$slug-"*; do                  # same rule for the token-accounting lists
    [ -e "$f" ] || continue
    id="${f##*/transcripts-"$slug"-}"
    [ -f "$INSTANCE_DIR/$id" ] && continue
    rm -f "$f"
  done
}

# a short, speakable handle for this instance — one of the fifteen below, held by no peer running
# against this repo right now, so "kill kit" beats reading eight hex chars aloud. Line 3 of a
# marker is its holder's nickname (line 1/2 untouched, so the GC above still reads them), which
# makes the liveness registry the name registry too — no second list to disagree with the first.
# Call ONCE, AFTER cleanup_orphan_time_files, or dead peers' markers still hold names hostage.
# scan-then-claim runs under one lock so two instances launched together cannot draw the same word.
# Past fifteen live instances the names take an ascending suffix ("bob 1", then "bob 2", …).
# Degrade, never lie: an unwritable lock or registry costs uniqueness, never the launch.
pick_nickname() {
  local names=(ash bob cleo dax elk finn gus hana ivo jun kit lux moss nix opal)
  local m taken="" free=() cand n suffix=0
  { exec 6>"$INSTANCE_DIR.lock" && flock 6; } 2>/dev/null || true
  for m in "$INSTANCE_DIR"/*; do
    [ -e "$m" ] || continue
    taken+="$(sed -n 3p "$m" 2>/dev/null)"$'\n'     # no line 3 = a peer not yet at the lock: takes nothing
  done
  while [ ${#free[@]} -eq 0 ]; do
    for n in "${names[@]}"; do
      [ "$suffix" -eq 0 ] || n="$n $suffix"
      case $'\n'"$taken" in *$'\n'"$n"$'\n'*) continue;; esac
      free+=("$n")
    done
    suffix=$((suffix+1))
  done
  cand="${free[RANDOM % ${#free[@]}]}"              # random among the free, never derived from the id
  printf '%s\n' "$cand" 2>/dev/null >> "$INSTANCE_DIR/$INSTANCE_ID" || true
  exec 6>&-                                        # close fd, release lock
  printf '%s' "$cand"
}

# write .git/zero.sh (the per-task acquire/release/merge helper the zero prompt calls) with
# BASE_BRANCH baked in, then echo the parallel zero-mode prompt on stdout. $1 = TODO path (repo-relative).
build_zero_prompt() {
    local todo="$1" loopprompt="$2"
    local gitdir; gitdir="$(git rev-parse --git-dir)"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'set -euo pipefail\n'
        printf 'BASE_BRANCH=%q\n' "$BASE_BRANCH"
        printf 'TODO_PATH=%q\n' "$todo"
        cat <<'ZERO_EOF'
GITDIR="$(cd "$(git rev-parse --git-common-dir)" && pwd)"   # absolute: safe from any cwd
MERGE_LOCK="$GITDIR/merge.lock"
# worktree add/remove/repair all rewrite the shared .git/config + .git/worktrees; git does not
# serialize that, so concurrent instances race on .git/config.lock ("File exists"). Held briefly
# around each worktree mutation. Nested inside MERGE_LOCK during merge cleanup — order is always
# MERGE_LOCK then WT_LOCK (acquire/release take WT_LOCK alone), so no lock-ordering cycle.
WT_LOCK="$GITDIR/worktree.lock"
# this invocation's instance = the claudezero.sh that launched the claude above it, via env.
# 'shared' fallback if unset (should not happen under claudezero.sh).
INSTANCE_ID="${CLAUDEZERO_INSTANCE:-shared}"
# per-instance aggregate path: seconds of task ownership credited to instance $1. Namespaced by base
# slug (like branches/worktrees/reclaim-locks) AND instance id, so peers keep separate, comparable totals.
todos_file() { printf '%s/todos-seconds-%s-%s' "$GITDIR" "${BASE_BRANCH//\//-}" "$1"; }
# same namespacing for the count of todos instance $1 landed on the base branch.
todos_done_file() { printf '%s/todos-done-%s-%s' "$GITDIR" "${BASE_BRANCH//\//-}" "$1"; }

# stat mtime-epoch flavor, probed once: BSD/macOS `-f %m` vs GNU/Linux `-c %Y`.
if stat -f %m . >/dev/null 2>&1; then STAT_MTIME=(stat -f %m); else STAT_MTIME=(stat -c %Y); fi
# newest file mtime (epoch) under $1, excluding .git; empty if no files. Estimates a dead session's
# mid-task work: acquire epoch to last file touched, so the crash-to-steal idle gap isn't counted.
newest_mtime() {
  # exclude .owner: it's zero mode's bookkeeping (rewritten by claim / credit_inflight_time to "now"),
  # not agent work — counting it would inflate the estimate and break idempotency after the anchor advance.
  find "$1" -type f -not -path '*/.git/*' -not -name .owner -print0 2>/dev/null \
    | xargs -0 "${STAT_MTIME[@]}" 2>/dev/null | sort -rn | head -1
}
# add $1 seconds (positive int) to instance $2's todos aggregate, under a per-instance lock (fd 8 —
# fd 9 is acquire's). Credit goes to the instance that WORKED the span, not necessarily the caller
# (a stealer credits the crashed owner). Silently ignores non-numeric / non-positive / no-instance.
add_todos_time() {
  local add=${1:-0} inst=${2:-}
  case "$add" in ''|*[!0-9]*) return 0;; esac; [ "$add" -gt 0 ] || return 0
  [ -n "$inst" ] || inst=shared
  add_counter "$add" "$(todos_file "$inst")"
}
# +1 to instance $1's completed-todo count, from the same rc=0 point that credits its time, so
# the count and the time credit can never disagree about who did the work.
add_todos_done() {
  local inst=${1:-}
  [ -n "$inst" ] || inst=shared
  add_counter 1 "$(todos_done_file "$inst")"
}
# add $1 (positive int) to counter file $2, under a per-file lock.
add_counter() {
  local add=$1 f=$2 cur=0
  exec 8>"$f.lock"; flock 8
  [ -f "$f" ] && { read -r cur < "$f" 2>/dev/null || cur=0; }
  case "$cur" in ''|*[!0-9]*) cur=0;; esac
  # atomic publish (temp + rename): the report reads this file WITHOUT the lock, so a plain
  # truncate-write would expose an empty file mid-write. rename is atomic — readers see old or new.
  printf '%s\n' "$((cur + add))" > "$f.tmp" && mv -f "$f.tmp" "$f"
  exec 8>&-   # close fd, release lock
}

# Task branch is prefixed with the base branch so agent groups zeroing the SAME repo off DIFFERENT
# bases never collide on branch/worktree names. Slashes in the base (feature/x) are legal in a
# branch ref but not in a dir name, so sanitize for the wt.
BR_SLUG="${BASE_BRANCH//\//-}"
task_branch() { printf '%s-task-%s' "$BASE_BRANCH" "$1"; }

# Owner = nearest ancestor process named 'claude' (the Bash tool may nest a shell in between).
find_owner() {
  local pid=$PPID comm depth=0
  while [ -n "$pid" ] && [ "$pid" -gt 1 ] && [ "$depth" -lt 8 ]; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    if [ "${comm##*/}" = claude ]; then echo "$pid"; return 0; fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
    depth=$((depth+1))
  done
  return 1
}
# process start-time (via ps): pins identity so a RECYCLED pid isn't mistaken for the same session.
# `ps -o lstart=` pads with spaces; awk '{$1=$1}' trims+collapses so the value stored via $() and
# the value read back via `read` (which trims) compare equal. Empty only if dead.
proc_start() { ps -o lstart= -p "$1" 2>/dev/null | awk '{$1=$1;print}'; }
# resolve the owning claude session into OWNER_PID/OWN_START. Only the lease ops (acquire/merge/
# release, via claim_owner/set_current) need it, and they run UNDER claude. done/credit_inflight_time
# run from claudezero.sh itself (no claude ancestor), so it's called per-subcommand below, never eagerly.
ensure_owner() {
  OWNER_PID=$(find_owner) || { echo "FATAL: no 'claude' ancestor process — task ownership and liveness are unsafe; abort this run." >&2; exit 3; }
  OWN_START=$(proc_start "$OWNER_PID")
}

# --- ownership as a per-session LEASE, not a per-worktree pid probe -----------------------
# A claude SESSION outlives any single task (zeros many, idles between /loop fires), so "is the pid
# alive?" is too coarse — it says the session is up, not that it still holds THIS task. Record, per
# session, the ONE task it is currently on:
#     $GITDIR/session/<pid>   line1=<process start-time>   line2=<current task id | none>
# zero.sh is the sole writer: set on acquire, cleared to `none` on merge/release. A task is owned
# iff some live session marker names it (pid up + start-time match + current == id). This reclaims a
# task from a session that DIED, whose pid was REUSED, or that MOVED ON.
SESSION_DIR="$GITDIR/session"
marker() { printf '%s/%s' "$SESSION_DIR" "$1"; }
session_alive() { kill -0 "$1" 2>/dev/null && [ "$(proc_start "$1")" = "$2" ]; }  # $1=pid $2=start
session_current() {                              # $1=pid → its current task id, or 'none'
  local f cur; f=$(marker "$1"); [ -f "$f" ] || { echo none; return; }
  { read -r _; read -r cur; } < "$f" 2>/dev/null || true
  printf '%s' "${cur:-none}"
}
set_current() { mkdir -p "$SESSION_DIR"; printf '%s\n%s\n' "$OWN_START" "$1" > "$(marker "$OWNER_PID")"; }
# GC: unlink markers whose session is gone or whose pid was recycled. Cheap — piggybacks acquire's
# scan. Others reap the dead; a dead session can't clean its own file.
reap_dead_sessions() {
  [ -d "$SESSION_DIR" ] || return 0
  local f pid st
  for f in "$SESSION_DIR"/*; do
    [ -e "$f" ] || continue
    pid=${f##*/}; { read -r st; } < "$f" 2>/dev/null || st=""
    session_alive "$pid" "$st" || rm -f "$f"
  done
}

wt_for_branch() {
  git worktree list --porcelain | awk -v b="refs/heads/$1" '
    /^worktree /{p=substr($0,10)}
    /^branch /{ if (substr($0,8)==b){print p; exit} }'
}

# a worktree's claim record: line1=pid line2=start-time line3=acquire-epoch line4=instance-id
# (written when we (re)claim it). line3 anchors the todo-time accounting (elapsed on merge, or
# mtime-estimate on steal); line4 routes that credit to the instance that worked the span.
claim_owner() { printf '%s\n%s\n%s\n%s\n' "$OWNER_PID" "$OWN_START" "$(date +%s)" "$INSTANCE_ID" > "$1/.owner"; }
setup_exclude() {                                # keep zero mode's .owner out of the agent's `git add -A`
  local ex; ex="$(git -C "$1" rev-parse --git-path info/exclude)"; mkdir -p "$(dirname "$ex")"
  grep -qxF '/.owner' "$ex" 2>/dev/null || echo '/.owner' >> "$ex"
}

# acquire: print worktree path + exit 0 if claimed; exit 1 = could not acquire (skip). Holds a
# per-task lock for the WHOLE decision so two peers never race the same task_id (distinct ids use
# distinct locks, so tasks still run in parallel). fd 9 = bash-3.2-safe; auto-released on exit.
acquire_task() {
  local n=$1 branch wt owner_pid owner_start owner_acq owner_inst m ilk; branch=$(task_branch "$n")
  reap_dead_sessions
  exec 9>"$GITDIR/reclaim-$BR_SLUG-task-$n.lock"
  flock -n 9 || return 1                          # a peer is mid-acquire on this same task → skip

  wt=$(wt_for_branch "$branch")
  if [ -n "$wt" ]; then                           # branch already has a worktree
    if [ -f "$wt/.owner" ]; then
      { read -r owner_pid; read -r owner_start; read -r owner_acq; read -r owner_inst; } < "$wt/.owner" 2>/dev/null || owner_pid=""
      if [ -n "$owner_pid" ] && [ "$(session_current "$owner_pid")" = "$n" ] \
           && session_alive "$owner_pid" "$owner_start"; then
        return 1                                  # actively owned by a live session on THIS task
      fi
      # stealing a dead/moved-on worktree: credit its partial todo-time (acquire epoch to newest
      # file mtime; skips the crash-to-resume idle gap) to the OWNER instance that worked it, not us.
      # Self-steal across a context restart credits this same instance.
      case "${owner_acq:-}" in ''|*[!0-9]*) ;; *)
        m=$(newest_mtime "$wt"); [ -n "$m" ] && add_todos_time "$((m - owner_acq))" "${owner_inst:-}" ;;
      esac
    fi
    # dead / pid-reused / moved-on / no .owner → steal this worktree in place
    flock "$WT_LOCK" git worktree repair "$wt" >/dev/null 2>&1 || true
    ilk=$(git -C "$wt" rev-parse --git-path index.lock 2>/dev/null || true)
    [ -n "$ilk" ] && [ -f "$ilk" ] && rm -f "$ilk"
    git -C "$wt" merge  --abort 2>/dev/null || true
    git -C "$wt" rebase --abort 2>/dev/null || true
    claim_owner "$wt"; set_current "$n"; printf '%s' "$wt"; return 0
  fi

  # no worktree for the branch: make one. Reattach if the branch exists (orphaned by a release that
  # couldn't delete an unmerged branch, keeping its committed work); else fork off base.
  wt="../ts-$BR_SLUG-task-$n-$(uuidgen | tr -d - | head -c7)"
  if git rev-parse --verify -q "refs/heads/$branch" >/dev/null; then
    flock "$WT_LOCK" git worktree add "$wt" "$branch"                  >/dev/null 2>&1 || return 1   # reattach (git prints "HEAD is now at" to stdout — drop it)
  else
    flock "$WT_LOCK" git worktree add "$wt" -b "$branch" "$BASE_BRANCH" >/dev/null 2>&1 || return 1  # fresh fork
  fi
  setup_exclude "$wt"; claim_owner "$wt"; set_current "$n"; printf '%s' "$wt"; return 0
}

# claim: the WHOLE "is this task mine to work?" decision in one call — acquire, validate the
# worktree, then re-check that no peer landed it first. Prints the worktree path (stdout, no
# newline) + exit 0 when it is yours; every skip reason goes to stderr with a distinct exit code
# so TEST.md can assert which path ran: 1 = not claimed, 3 = validation failed, 4 = already landed.
# The agent treats all non-zero the same. Takes the RAW id: acquire/release want it sanitized,
# is_done wants it raw (it matches the todo line's first token), so both values are held here.
claim_task() {
  local raw=$1 n wt br; n=$(sanitize_id "$raw")
  if ! wt=$(acquire_task "$n"); then
    echo "claim $raw: not claimed — a peer owns it or it is being rescued" >&2; return 1
  fi
  br=""   # set -e: keep the probe in an `if` — a bare failing `&&` chain would kill the process
  if [ -n "$wt" ] && [ -d "$wt" ]; then br=$(git -C "$wt" symbolic-ref --short HEAD 2>/dev/null || true); fi
  if [ "$br" != "$(task_branch "$n")" ]; then
    # do NOT release: that would force-remove a worktree sitting on an unexpected branch with
    # unknown contents. Just drop the session claim; a later acquire steals it the normal way.
    set_current none
    echo "claim $raw: validation failed — worktree ${wt:-<none>} is on ${br:-<none>}, want $(task_branch "$n")" >&2
    return 3
  fi
  if is_done "$raw" "$wt"; then
    release_task "$n" "$wt"
    echo "claim $raw: already landed on $BASE_BRANCH by a peer — released" >&2; return 4
  fi
  printf '%s' "$wt"
}

# release: undo a claim (worktree + branch) and mark this session idle. -d refuses a branch with
# unmerged commits (safety), leaving an orphan branch a later acquire reattaches.
release_task() {
  local n=$1 wt=$2 branch; branch=$(task_branch "$n")
  flock "$WT_LOCK" git worktree remove --force "$wt" 2>/dev/null || true
  git branch -d "$branch" >/dev/null 2>&1 || true
  set_current none
}

# merge: SERIAL across instances. exit 0 = merged & cleaned; exit 2 = failed (human needed), base left clean.
merge_task() {
  local n=$1 wt=$2 branch acq inst rc; branch=$(task_branch "$n")
  # acquire epoch + instance (lines 3,4 of .owner), read before the merge subshell removes the wt.
  acq=""; inst=""; if [ -f "$wt/.owner" ]; then { read -r _; read -r _; read -r acq; read -r inst; } < "$wt/.owner" 2>/dev/null || acq=""; fi
  if flock "$MERGE_LOCK" bash -c '
      wt="$1"; branch="$2"; base="$3"; err="$4"; todo="$5"; wtlock="$6"
      rm -f "$err"
      # hard guard, on EVERY merge (not just the conflicting ones git routes to the driver): the
      # branch may newly check EXACTLY ONE box in the todo vs its fork point. >1 = it ticked a task
      # it does not own — refuse with a pointer so step 2.g can self-heal.
      mb=$(git merge-base "$base" "$branch") || exit 2
      # newly-checked lines (fork-point [ ] to branch [x]), as "TODO:LINENO TEXT". No paste: todo
      # lines may be tab-indented, and a tab-delimited paste/-F"\t" would mis-split them. awk reads
      # both blobs and pairs them by line number instead.
      newly=$(awk -v p="$todo" '\''FNR==1{fence=0}                # reset fence state at each blob start
          /^[ \t]*```/{fence=!fence; next}                       # skip checkboxes inside fenced code blocks
          fence{next}
          NR==FNR{b[FNR]=$0;next}
          b[FNR] ~ /^[ \t]*- \[ \]/ && $0 ~ /^[ \t]*- \[x\]/ {printf "  %s:%d %s\n", p, FNR, $0}'\'' \
          <(git show "$mb:$todo" 2>/dev/null) <(git show "$branch:$todo" 2>/dev/null))
      n=$(printf '\''%s'\'' "$newly" | grep -c . )
      if [ "$n" != 1 ]; then
        { echo "checkbox-merge: refused — your branch newly checks $n boxes; a task branch may check exactly ONE, for its own task_id."
          echo "Offending checked lines follow as <file>:<line> <text>. Keep only your task_id line, uncheck the rest, amend the commit, then retry the merge:"
          printf '\''%s\n'\'' "$newly"
        } | tee "$err"
        exit 2
      fi
      git checkout "$base" >/dev/null 2>&1 || exit 2
      if ! git merge --no-ff -m "merge $branch" "$branch"; then
        git merge --abort 2>/dev/null || true                         # abort: base stays green, branch kept
        [ -f "$err" ] && cat "$err"                                    # surface checkbox pointer to the agent
        exit 2
      fi
      flock "$wtlock" git worktree remove --force "$wt" || true
      git branch -d "$branch" >/dev/null 2>&1 || true
    ' _ "$wt" "$branch" "$BASE_BRANCH" "$GITDIR/checkbox-merge.err" "$TODO_PATH" "$WT_LOCK"; then rc=0; else rc=$?; fi
  # merged → credit full elapsed (acquire → now) and one completed todo to the instance that held
  # it (line4). The branch is deleted right above, so no todo can be counted twice.
  if [ "$rc" -eq 0 ] && [ -n "$acq" ]; then add_todos_time "$(( $(date +%s) - acq ))" "$inst"; fi
  if [ "$rc" -eq 0 ]; then add_todos_done "$inst"; fi
  return $rc
}

# credit_inflight_time: credit orphaned in-flight worktrees whose owning session has exited (claude
# died/finished mid-task, work neither merged nor stolen). For each such task worktree, credit its
# partial work (acquire epoch to newest file mtime) and ADVANCE the anchor to that mtime — so a
# repeat pass adds ~0 and a later steal counts only work beyond this point (no double-count).
# Live-owned worktrees are left alone (self-credit on merge). Called from claudezero.sh's exit paths.
credit_inflight_time() {
  local wt br owner_pid owner_start owner_acq owner_inst m n line
  credit_one() {
    [ -n "${wt:-}" ] || return 0
    case "${br:-}" in "$BASE_BRANCH-task-"*) n=${br#"$BASE_BRANCH"-task-} ;; *) return 0 ;; esac  # task worktrees only
    [ -f "$wt/.owner" ] || return 0
    exec 7>"$GITDIR/reclaim-$BR_SLUG-task-$n.lock"          # same lock a steal takes, so no race
    flock -n 7 || { exec 7>&-; return 0; }                  # a peer is mid-steal on this task; it credits
    { read -r owner_pid; read -r owner_start; read -r owner_acq; read -r owner_inst; } < "$wt/.owner" 2>/dev/null || { exec 7>&-; return 0; }
    if ! session_alive "$owner_pid" "$owner_start"; then    # dead owner = orphaned in-flight
      case "${owner_acq:-}" in ''|*[!0-9]*) : ;; *)
        m=$(newest_mtime "$wt")
        # credit to the OWNER instance (line4), not whoever runs the sweep; keep line4 on the anchor advance.
        [ -n "$m" ] && { add_todos_time "$((m - owner_acq))" "${owner_inst:-}"; printf '%s\n%s\n%s\n%s\n' "$owner_pid" "$owner_start" "$m" "${owner_inst:-}" > "$wt/.owner"; } ;;
      esac
    fi
    exec 7>&-
  }
  wt=""; br=""
  while IFS= read -r line; do
    case "$line" in
      worktree\ *)          wt=${line#worktree } ;;
      branch\ refs/heads/*) br=${line#branch refs/heads/} ;;
      "")                   credit_one; wt=""; br="" ;;       # blank line ends each porcelain record
    esac
  done < <(git worktree list --porcelain)
  credit_one   # flush last record if git emitted no trailing blank
}

# escape a task id into a git-ref-safe branch slug: keep only branch-safe chars, then remove git's
# forbidden ref patterns ('..', trailing '.' or '.lock'); never empty. Called on every N below so no
# unescaped id reaches a branch/worktree/lock name. Distinct ids differing only in escaped chars
# would collide — fine, given ids are unique tokens like SMTH-855 / 7.a.
sanitize_id() {
  local s; s=$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-')
  while [ "$s" != "${s//../.}" ]; do s=${s//../.}; done   # collapse '..' runs (forbidden in refs)
  s=${s%.lock}; s=${s%.}                                  # no trailing '.lock' or '.'
  printf '%s' "${s:-x}"
}

# is the RAW task id's box [x] on the BASE branch's todo? A checkbox line is `^[ \t]*- [ ]` (or
# [x]); the id is the first whitespace token after the box (same rule the agent uses), so no
# id-regex escaping. Anchoring to the line-start box ignores any [x]/[ ] inside task text.
box_checked_on_base() {
  git show "$BASE_BRANCH:$TODO_PATH" 2>/dev/null | awk -v id="$1" '
    /^[ \t]*```/ { fence = !fence; next }   # ignore checkboxes inside fenced code blocks (example issues)
    fence        { next }
    /^[ \t]*- \[[ x]\]/ {
      line = $0
      sub(/^[ \t]*- \[/, "", line)                  # drop prefix up to and incl "["
      box  = substr(line, 1, 1)                      # " " or "x"
      sub(/^[ x]\][ \t]*/, "", line)                 # drop "x] " → leaves id + rest
      split(line, a, /[ \t]/)
      if (a[1] == id && box == "x") { found=1; exit }
    }
    END { exit found ? 0 : 1 }'
}

# done: deterministic "has this task already LANDED on the base branch?" — exit 0 = landed (safe to
# release/skip), exit 1 = not landed (own it, drive+merge it). Given the RAW task id. Authoritative
# signal is the base box: OR-merge + the one-box invariant mean a base [x] can only come from THIS
# task's branch actually merging. A worktree that ticked its own box on its task branch but whose merge
# failed/aborted leaves base at [ ] = not done. If a wt is passed and still exists, also assert its
# tip is an ancestor of base — catches the ticked-box-but-unmerged wt from the failed-merge rescue path.
is_done() {
  local raw=$1 wt=${2:-} head
  box_checked_on_base "$raw" || return 1
  [ -n "$wt" ] && head=$(git -C "$wt" rev-parse -q HEAD 2>/dev/null) || return 0  # no/gone wt: base [x] settles it
  git merge-base --is-ancestor "$head" "$BASE_BRANCH"
}

case "${1:-}" in
  claim)   ensure_owner; claim_task "$2" ;;
  acquire) ensure_owner; acquire_task "$(sanitize_id "$2")" ;;
  release) ensure_owner; release_task "$(sanitize_id "$2")" "$3" ;;
  merge)   ensure_owner; merge_task "$(sanitize_id "$2")" "$3" && set_current none || exit $? ;;  # clear only on success
  done)    is_done "$2" "${3:-}" ;;
  credit_inflight_time)   credit_inflight_time ;;
  *) echo "usage: zero.sh {claim N | acquire N | release N WT | merge N WT | done N [WT] | credit_inflight_time}" >&2; exit 64 ;;
esac
ZERO_EOF
    } > "$gitdir/zero.sh"
    chmod +x "$gitdir/zero.sh"
    printf '❄ wrote %s/zero.sh (base %s)\n' "$gitdir" "$BASE_BRANCH" >&2

    # checkbox merge driver: parallel check-offs of ADJACENT todo lines otherwise conflict (git
    # groups neighbouring one-line changes into one hunk). This ORs the [x] state per line so both
    # land. Scoped to the todo file ONLY via info/attributes, so every other file (real conflicts
    # included) merges normally. Idempotent setup, no teardown — a leftover driver would also OR
    # checkboxes in a later manual merge of this file; harmless, arguably wanted. In .git, untracked.
    local gitdir_abs; gitdir_abs="$(cd "$gitdir" && pwd)"
    cat > "$gitdir_abs/checkbox-merge.sh" <<'DRIVER_EOF'
#!/usr/bin/env bash
# git merge driver — resolve the todo file by OR-ing each line's [x] state. Safe ONLY because
# the zero run's sole edit is a checkbox flip; any deviation bails (exit 1), leaving a real conflict for a human.
set -euo pipefail
base="$1"; ours="$2"; theirs="$3"            # git passes: %O(base) %A(ours,output) %B(theirs)
strip() { sed 's/^\([[:blank:]]*- \)\[[ x]\]/\1[ ]/' "$1"; }   # blank the line-start box → compare text only ([[:blank:]] = BSD-sed-safe [ \t])
# structural guard: all three versions must share identical line text (boxes aside);
# a task line added/edited/removed is not ours to auto-merge. (The one-box invariant is
# enforced upstream in merge_task, on EVERY merge — not just the conflicting ones git
# routes here.)
[ "$(strip "$base")" = "$(strip "$ours")" ] && [ "$(strip "$ours")" = "$(strip "$theirs")" ] || exit 1
# OR each line's box across ours/theirs. No paste (-d'\t' collides with tab-indented lines); awk
# pairs the two files by line number. Output = ours text with the box flipped [ ] to [x] when either
# side checked it. Structural guard above already proved identical line counts.
awk 'NR==FNR{o[FNR]=$0; next}
  { line=o[FNR]
    if (line ~ /^[ \t]*- \[x\]/ || $0 ~ /^[ \t]*- \[x\]/) sub(/- \[ \]/, "- [x]", line)
    print line }' "$ours" "$theirs" > "$ours.tmp" && mv "$ours.tmp" "$ours"
DRIVER_EOF
    chmod +x "$gitdir_abs/checkbox-merge.sh"
    # every instance sets this same value at startup; concurrent writers race on git's own
    # .git/config.lock ("could not lock config file"). Skip when already set, and serialize the write
    # with a dedicated lock (NOT config.lock — that's git's own transient lock).
    local ckdriver="$gitdir_abs/checkbox-merge.sh %O %A %B"
    [ "$(git config --get merge.checkbox.driver 2>/dev/null)" = "$ckdriver" ] \
      || flock "$gitdir_abs/cz-config.lock" git config merge.checkbox.driver "$ckdriver"
    mkdir -p "$gitdir_abs/info"
    grep -qxF "/$todo merge=checkbox" "$gitdir_abs/info/attributes" 2>/dev/null \
      || printf '/%s merge=checkbox\n' "$todo" >> "$gitdir_abs/info/attributes"

    # single-quoted heredoc keeps $wt/backticks literal; inject params via bash replace (safe for
    # arbitrary @@LOOPPROMPT@@ text — no sed metachar/delimiter escaping).
    # `read -d ''` not `$(cat <<EOF)`: bash 3.2 (stock macOS) cannot parse a heredoc inside a
    # command substitution. It exits 1 at EOF, hence `|| :`.
    local prompt
    IFS= read -r -d '' prompt <<'PROMPT_EOF' || :
/loop @@LOOP_INTERVAL@@

You are ONE of many independent Claude instances zeroing tasks from @@TODO@@ in PARALLEL.
Keep these facts in mind for every iteration:

  • Coordination is via git alone: a branch = a claim, an flock = the rescue mutex.
  • Peers may hold other tasks at the same time — that is expected. Never assume you are alone.
  • Every Bash call starts fresh at the repo root (cwd resets after each call). So the relative
    path `.git/zero.sh` always resolves — call it exactly that, and do all worktree work as
    `cd "$wt" && …` in a SINGLE command.

=== PER-ITERATION ALGORITHM ===
1. FIND candidate tasks yourself in @@TODO@@. Tasks are GitHub-style Markdown checkboxes, one per
   line, each carrying an id as the FIRST whitespace-delimited token after the checkbox:
       - [ ] SMTH-855 some task not done yet     ← UNCHECKED = still to do
       - [x] 7.a some task already done          ← CHECKED   = done, skip it
   That first token is the task_id (e.g. SMTH-855, 7, 7.a).

   VALIDATION GUARDRAIL (once, before zeroing): collect the ids of ALL tasks in @@TODO@@ (checked
   and unchecked). If any task is missing an id, or the same id appears on more than one line,
   STOP THE LOOP IMMEDIATELY — report the offending ids and do not schedule the next iteration.
2. For each candidate task_id, in order:
   a. INDEPENDENCE — decide by EVIDENCE from the task body, never from its title,
      id, or position in the list:
      i.   READ THE FULL LINE/BODY of this task (not the one-line summary). If it is
           truncated in your view, expand it before judging.
      ii.  A blocking dependency exists ONLY IF this task CONSUMES an artifact that
           some *unchecked* task PRODUCES — a named file, function, fixture, finding
           class, prompt, gate, tag, or exit code. Direction is inbound only:
           "this task needs X's output". Being depended-ON by others does NOT block.
      iii. For EACH unchecked task, you must be able to quote the span in THIS task's
           body that names that task's output. No quotable reference → no edge →
           treat as independent for that pair. Title similarity, adjacency, or "same
           area" is NOT evidence.
      iv.  A prerequisite that is already `[x]` never blocks (its output exists).
      - Any inbound edge to an unchecked task → skip to the next task_id.
      - No such edge (every claimed edge is either to a checked task or unquotable)
        → continue to step b.
   b. CLAIM: wt=$(.git/zero.sh claim task_id)
      - exit ≠ 0 → not yours (a peer owns it, it is being rescued, or a peer already landed it)
        → skip to the next task_id. The reason is printed on stderr.
      - exit 0   → you OWN task_id; its git worktree is at $wt. Continue to step c.
        Do NOT trust the box in `$wt/@@TODO@@` — the claim already re-checked @@BASE_BRANCH@@.
   c. IMPLEMENT task_id. If task_id's line names an issue/spec file, its acceptance criteria define
      done for this task — they may span files the task title never mentions: satisfy each and tick
      it there (`[ ]`→`[x]`) as you land it, never ahead of verifying it.
      Scope every edit to task_id only before you skip to the next one; never touch
      another task, even one you will process later this same pass (you reach the next task_id
      at step e — this is per-task, not per-session).
      @@LOOPPROMPT@@
   d. CHECK OFF only your task_id's line in `$wt/@@TODO@@` (`[ ]`→`[x]`); touch no other line.
      Then commit in `$wt` on the worktree's branch.
   e. MERGE: .git/zero.sh merge task_id "$wt"
      - exit 0 → merged to @@BASE_BRANCH@@, worktree + branch cleaned → continue to the next task_id.
      - exit ≠ 0 with output starting `checkbox-merge: refused` → you checked off more than your own
        task. The output lists each offending line as `<file>:<line> <text>`. In `$wt/@@TODO@@` uncheck
        every listed line EXCEPT task_id's (`[x]`→`[ ]`), keep yours checked, run
        `git -C "$wt" commit --amend --no-edit`, then retry `.git/zero.sh merge task_id "$wt"` ONCE.
        If it fails again for this cause, STOP THE LOOP IMMEDIATELY — report the offending lines, task_id,
        its worktree $wt and its branch (`git -C "$wt" symbolic-ref --short HEAD`), and ask the human to
        clear the unrelated checkboxes, then merge by hand.
      - any other exit ≠ 0 → a merge conflict. Resolve it yourself, iterating until you merge or you see
        no better merge option. If you cannot, MERGE FAILED: STOP THE LOOP IMMEDIATELY — report task_id,
        its worktree $wt and its branch (`git -C "$wt" symbolic-ref --short HEAD`), and ask the human to
        "resolve the conflict on that branch, then merge by hand".
3. If every task in @@TODO@@ is now checked → announce "ALL TASKS DONE" and stop the loop: end this
   pass WITHOUT scheduling the next iteration. Otherwise end this pass and let the scheduled loop re-fire.
PROMPT_EOF
    prompt=${prompt%$'\n'}          # read keeps the final newline; $(cat) stripped it
    prompt=${prompt//@@TODO@@/$todo}
    prompt=${prompt//@@BASE_BRANCH@@/$BASE_BRANCH}
    prompt=${prompt//@@LOOP_INTERVAL@@/$LOOP_INTERVAL}
    prompt=${prompt//@@LOOPPROMPT@@/$loopprompt}
    printf '%s\n' "$prompt"
}

main "$@"
