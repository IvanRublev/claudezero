#!/usr/bin/env bash
# smoke.sh — CI dependency smoke test. Runs the OS tools claudezero.sh relies on,
# in the exact argument forms it uses, to catch BSD-vs-GNU divergence (macOS) early.
# ponytail: curated to the real platform-divergent calls, not every command — keep
# in sync when claudezero.sh grows a new tool dependency.
set -euo pipefail

fail() { echo "SMOKE FAIL: $*" >&2; exit 1; }
ok()   { echo "ok — $*"; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

echo "== env =="
echo "uname:    $(uname -a)"
echo "bash:     $BASH_VERSION"
echo "git:      $(git --version)"
echo "tmp:      $tmp"
echo "== checks =="

# 1. flock — runnable (claudezero.sh:61) + lockfile-command form (:498,509)
flock -n "$(mktemp)" true 2>/dev/null || fail "flock not runnable (-n fd true)"
lock="$tmp/lock"
flock "$lock" true                 || fail "flock <lockfile> <command> form failed"
# mutual exclusion: hold lock in background, non-blocking grab must fail
( flock 9; sleep 2 ) 9>"$lock" &
sleep 0.3
if flock -n 9 9>"$lock"; then fail "flock did not serialize (got a held lock)"; fi
wait
ok "flock"

# 2. instance id — uuidgen | tr -d - | head -c8 (claudezero.sh:120)
id="$(uuidgen 2>/dev/null | tr -d - | head -c8)"
[ "${#id}" -eq 8 ] || fail "uuidgen|tr|head produced '$id' (want 8 chars)"
ok "uuidgen/tr/head -> $id"

# 3. session_id extraction — sed + tr -cd (claudezero.sh:198)
sid="$(printf '%s' '{"session_id": "ab-CD_12"}' \
  | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
  | tr -cd 'A-Za-z0-9_-')"
[ "$sid" = "ab-CD_12" ] || fail "session_id parse got '$sid' (want ab-CD_12)"
ok "sed/tr session_id"

# 4. process introspection — ps forms (claudezero.sh:206,208,304)
[ -n "$(ps -o comm= -p $$ 2>/dev/null)" ]                        || fail "ps -o comm= empty"
[ -n "$(ps -o ppid= -p $$ 2>/dev/null | tr -d '[:space:]')" ]    || fail "ps -o ppid= empty"
st1="$(ps -o lstart= -p $$ 2>/dev/null | awk '{$1=$1;print}')"
[ -n "$st1" ]                                                    || fail "ps -o lstart= empty"
st2="$(ps -o lstart= -p $$ 2>/dev/null | awk '{$1=$1;print}')"
[ "$st1" = "$st2" ]                                              || fail "ps -o lstart= not stable ('$st1' vs '$st2')"
ok "ps comm/ppid/lstart"

# 5. epoch seconds — date +%s (claudezero.sh:304 area / timing)
now="$(date +%s)"; case "$now" in ''|*[!0-9]*) fail "date +%s -> '$now'";; esac
ok "date +%s"

# 6. git worktree lifecycle — add -b / repair / remove --force / prune (:486,498,500,509)
repo="$tmp/repo"; mkdir "$repo"; cd "$repo"
git init -q; git config user.email ci@ci; git config user.name ci
git commit -q --allow-empty -m init
base="$(git rev-parse --abbrev-ref HEAD)"
wt="$tmp/repo-task-1"
flock "$repo/.wtlock" git worktree add "$wt" -b "$base-task-1" "$base" >/dev/null 2>&1 \
  || fail "git worktree add -b failed"
[ -d "$wt" ] || fail "worktree dir missing after add"
flock "$repo/.wtlock" git worktree repair "$wt" >/dev/null 2>&1 || fail "git worktree repair failed"
flock "$repo/.wtlock" git worktree remove --force "$wt"        || fail "git worktree remove --force failed"
git worktree prune                                             || fail "git worktree prune failed"
ok "git worktree add/repair/remove/prune"

# 7. token accounting — transcript_path sed (claudezero.sh:243) + the usage awk (claudezero.sh:304).
# The awk must dedupe by requestId and take the PARENT field on each line, never the
# usage.iterations[] copy or the cache_creation ephemeral leaves.
tp="$(printf '%s' '{"transcript_path": "/a b/c.jsonl"}' \
  | sed -n 's/.*"transcript_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
[ "$tp" = "/a b/c.jsonl" ] || fail "transcript_path parse got '$tp'"
u='"input_tokens":10,"cache_creation_input_tokens":248,"cache_read_input_tokens":1000,"output_tokens":20,"cache_creation":{"ephemeral_5m_input_tokens":148,"ephemeral_1h_input_tokens":100},"iterations":[{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":1000,"cache_creation_input_tokens":248}]'
for _ in 1 2; do printf '{"requestId":"req_A","message":{"usage":{%s}}}\n' "$u"; done > "$tmp/t.jsonl"
sums="$(awk '
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
  END { if (n) printf "%d %d %d %d %d\n", i, o, cc, cr, i + o + cc + cr }' "$tmp/t.jsonl")"
[ "$sums" = "10 20 248 1000 1278" ] || fail "usage awk got '$sums' (want '10 20 248 1000 1278')"
ok "sed transcript_path / awk usage dedupe"

echo "SMOKE PASS ($(uname -s), bash $BASH_VERSION)"
