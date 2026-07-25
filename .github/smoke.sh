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

echo "SMOKE PASS ($(uname -s), bash $BASH_VERSION)"
