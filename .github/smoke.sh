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

# 7. main-worktree root — git worktree list --porcelain | sed -n '1s/^worktree //p' (claudezero.sh:191)
#    First porcelain entry must be the MAIN worktree even when read from inside a linked one,
#    which is what makes the root guard refuse a launch in a leftover ../ts-* worktree (BUG-014).
main_root="$(cd "$repo" && pwd -P)"
[ "$(git -C "$repo" worktree list --porcelain | sed -n '1s/^worktree //p')" = "$main_root" ] \
  || fail "porcelain/sed main-root form failed from the main worktree"
wt2="$tmp/repo-task-2"
git -C "$repo" worktree add "$wt2" -b "$base-task-2" "$base" >/dev/null 2>&1 || fail "worktree add for root check failed"
[ "$(cd "$wt2" && git worktree list --porcelain | sed -n '1s/^worktree //p')" = "$main_root" ] \
  || fail "porcelain/sed answered the linked worktree instead of the main one"
git -C "$repo" worktree remove --force "$wt2" >/dev/null 2>&1
ok "git worktree list --porcelain | sed main-root"

# 8. token accounting — transcript_path sed (claudezero.sh:243) + the usage awk (claudezero.sh:304).
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

# 9. CLAUDEZERO_LINK symlink — plain POSIX `ln -s target link` (claudezero.sh link_ignored).
#    BSD and GNU ln agree on the two-argument form and diverge on -r/-f/-n, which is why none are
#    used. The guard is `[ ! -e ] && [ ! -L ]`: -e FOLLOWS the link, so a dangling link reads as
#    absent and an unguarded ln would die "File exists".
ldir="$tmp/linksrc"; mkdir -p "$ldir"; echo "criterion" > "$ldir/spec.md"
ln -s "$ldir" "$tmp/link"                       || fail "ln -s <dir> <name> failed"
[ -L "$tmp/link" ]                              || fail "-L did not see the symlink"
[ "$(cat "$tmp/link/spec.md")" = criterion ]    || fail "read through symlink failed"
ln -s "$tmp/nowhere" "$tmp/dangling"            || fail "ln -s to a missing target failed"
[ -L "$tmp/dangling" ]                          || fail "-L did not see the dangling link"
if [ -e "$tmp/dangling" ]; then fail "-e followed a dangling link (guard would misfire)"; fi
ok "ln -s / -L / -e guard"

# 10. context-rot guard's field extraction / threshold resolution (claudezero.sh's Stop hook).
# `grep -noE` feeds short per-field `LINE:"key":value` lines into the table-matcher awk — never
# the raw record — so this exercises: ENVIRON[] escapes surviving intact (a `-v` hand-off would
# expand `\[1m\]` into the character class `[1m]`, matching bare "1"/"m"); dynamic regex matching
# a version-suffixed family id while a word-suffix tier ("-mini") falls through to the default
# (split(s,a," ") whitespace-run parsing, blank table lines dropped, exercised via CZ_TABLE's own
# leading/trailing blank lines below); and match-based field extraction surviving a `tail -c` cut
# that lands mid-JSON, dropping `model` while the `usage` object (which trails it) survives.
CZT='
  \[1m\]                                                200000
  claude-fable-5(-[0-9]|[^A-Za-z0-9-])                  200000
'
guard_verdict() {   # $1 = raw bytes: a JSONL record, or a `tail -c`-cropped fragment of one
  printf '%s' "$1" \
    | grep -noE '"model":"[^"]*"|"input_tokens":[0-9]+|"cache_read_input_tokens":[0-9]+|"cache_creation_input_tokens":[0-9]+|"output_tokens":[0-9]+' \
    | CZ_TABLE="$CZT" CZ_DEFAULT=160000 awk '
      BEGIN {
        def = ENVIRON["CZ_DEFAULT"] + 0
        n = split(ENVIRON["CZ_TABLE"], tln, "\n")
        for (i = 1; i <= n; i++) {
          if (split(tln[i], f, " ") < 2) continue
          tn++; pat[tn] = f[1]; thr[tn] = f[2] + 0
        }
      }
      {
        if (!match($0, /^[0-9]+:/)) next
        L = substr($0, 1, RLENGTH - 1); rest = substr($0, RLENGTH + 1)
        if (!match(rest, /^"[a-zA-Z_]+":/)) next
        key = substr(rest, 2, RLENGTH - 3); val = substr(rest, RLENGTH + 1)
        if ((L, key) in seen) next
        seen[L, key] = 1
        if (key == "model") { sub(/^"/, "", val); sub(/"$/, "", val); mdl[L] = val; next }
        if (key == "output_tokens") { saw_out[L] = 1; next }
        tot[L] += val + 0
      }
      END {
        best = ""
        for (L in saw_out) { if ((tot[L]+0) > 0 && (best == "" || (L+0) > (best+0))) best = L }
        if (best == "") { print 0; exit }
        id = mdl[best] " "
        th = def
        for (i = 1; i <= tn; i++) { if (id ~ pat[i]) { th = thr[i]; break } }
        print (((tot[best]+0) >= th) ? 1 : 0)
      }'
}

REC_MINI='{"model":"claude-fable-5-mini","input_tokens":9000,"cache_read_input_tokens":170000,"cache_creation_input_tokens":1000,"output_tokens":500}'
[ "$(guard_verdict "$REC_MINI")" = 1 ] || fail "claude-fable-5-mini at 180000: default (160000) should fire; a -v hand-off would corrupt \\[1m\\] into a class matching mini's 'm' and wrongly give 0"

REC_VER='{"model":"claude-fable-5-20260115-v1:0","input_tokens":9000,"cache_read_input_tokens":170000,"cache_creation_input_tokens":1000,"output_tokens":500}'
[ "$(guard_verdict "$REC_VER")" = 0 ] || fail "claude-fable-5-20260115-v1:0 at 180000 should keep the family row (200000), not the default"

REC_FULL='{"model":"claude-fable-5","content":"PADDING","input_tokens":9000,"cache_read_input_tokens":170000,"cache_creation_input_tokens":1000,"output_tokens":500}'
[ "$(guard_verdict "$REC_FULL")" = 0 ] || fail "uncropped record should resolve its family row"
cropped="$(printf '%s' "$REC_FULL" | tail -c 110)"
[ "$(guard_verdict "$cropped")" = 1 ] || fail "a tail -c cut mid-JSON that drops 'model' should degrade to the default, not stay unmatched"

ok "context-rot guard: grep -n -o extraction, ENVIRON[] escapes, dynamic regex, tail -c mid-JSON cut"

echo "SMOKE PASS ($(uname -s), bash $BASH_VERSION)"
