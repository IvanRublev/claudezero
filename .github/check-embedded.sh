#!/usr/bin/env bash
# check-embedded.sh — shellcheck the scripts claudezero.sh emits at runtime
# (compact-exit-hook.sh, zero.sh, checkbox-merge.sh). They live in single-quoted
# heredocs, so shellcheck of claudezero.sh can't see inside — the blind spot that
# shipped an unbalanced quote in zero.sh. CLAUDEZERO_TEST_EMIT runs init for real
# in a throwaway repo (writes the scripts, exits before claude); we lint the actual
# files — no re-extraction to drift from how they're emitted.
set -euo pipefail

# scripts claudezero.sh emits into its git dir; keep in sync when a new one is added.
SCRIPTS=(compact-exit-hook.sh zero.sh checkbox-merge.sh)

here="$(cd "$(dirname "$0")" && pwd)"
src="$(cd "$here/.." && pwd)/claudezero.sh"
sc="${SHELLCHECK:-shellcheck}"
# absolutize now — we cd into a temp repo below (bare name or relative path both break after).
case "$sc" in
  */*) sc="$(cd "$(dirname "$sc")" && pwd)/$(basename "$sc")" ;;
  *)   sc="$(command -v "$sc")" ;;
esac

# pwd -P: macOS mktemp returns /var/... but git toplevel resolves /private/var/...;
# claudezero.sh refuses launch when $PWD != git toplevel, so match the physical path.
tmp="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$tmp"' EXIT
repo="$tmp/repo"; mkdir "$repo"; cd "$repo"
git init -q; git config user.email ci@ci; git config user.name ci
mkdir tasks; printf '# todo\n\n- [ ] task one\n' > tasks/todo.md
git add -A; git commit -q -m init

echo "== env =="
echo "uname:    $(uname -a)"
echo "bash:     $BASH_VERSION"
echo "git:      $(git --version)"
echo "shellcheck: $sc ($("$sc" --version | awk '/version:/{print $2}'))"
echo "PWD:      $PWD"
echo "toplevel: $(git rev-parse --show-toplevel)"

echo "== emit (CLAUDEZERO_TEST_EMIT=1) =="
# don't swallow output: on failure set -e aborts, so show what init printed before dying.
if ! CLAUDEZERO_TEST_EMIT=1 bash "$src" tasks/todo.md; then
  echo "FAIL: emit exited non-zero (see output above)" >&2
  exit 1
fi
gitdir="$(git rev-parse --git-dir)"
echo "gitdir:   $gitdir"
echo "emitted:  $(cd "$gitdir" && printf '%s ' *)"

# -e SC2016: single quotes not expanding is intentional here (bash -c blob, awk
# programs). Real breakage is an SC1xxx parse error — this exclusion doesn't touch it.
fail=0
for f in "${SCRIPTS[@]}"; do
  p="$gitdir/$f"
  [ -f "$p" ] || { echo "FAIL: $f was not emitted by init" >&2; fail=1; continue; }
  echo "== shellcheck $f =="
  "$sc" -e SC2016 "$p" || fail=1
done
[ "$fail" -eq 0 ] && echo "embedded scripts OK"
exit "$fail"
