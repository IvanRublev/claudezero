# Contributing

Thanks for helping to improve ClaudeZero. Even snow leopards sharpen their claws. Rawr.

1. **Fork** the repository and create a feature branch.

2. **Make your change.** Keep the diff surgical — match the existing style in
   `claudezero.sh`. Update the README and `TEST.md` if behavior changes.

   **`claudezero.sh` must parse under bash 3.2** — macOS ships it as `/bin/bash`,
   and a parse error there kills the script before line one runs. Avoid:

   ```sh
   prompt="$(cat <<'EOF'    # here-doc inside $( … ) — bash 3.2 cannot parse it
   ...
   EOF
   )"

   IFS= read -r -d '' prompt <<'EOF' || :    # use this instead
   ...
   EOF
   ```

   `TEST.md` Scenario S guards it: S3a scans for the construct on any host,
   S3b parses with a real bash 3.x. Locally: `/bin/bash -n claudezero.sh`.

3. **Keep the CI scripts in sync with `claudezero.sh`.** Two scripts under
   `.github/` mirror details of `claudezero.sh` and drift silently if you don't
   update them:

   - **`.github/smoke.sh`** — runs each OS tool `claudezero.sh` calls, in the exact
     argument form it uses, to catch BSD-vs-GNU (macOS) divergence. If your change
     adds a new external-tool dependency (e.g. a new `flock`/`ps`/`sed`/`git`
     invocation with a non-portable flag), add a numbered case for it, following
     the existing ones. Update the `claudezero.sh:<line>` reference in the case's
     comment if you moved the call.

   - **`.github/check-embedded.sh`** — shellchecks the scripts `claudezero.sh`
     writes into the git dir at runtime (their bodies live inside single-quoted
     heredocs, invisible to a plain shellcheck of `claudezero.sh`). If you add,
     rename, or remove one of those emitted scripts, update the `SCRIPTS=(...)`
     array at the top of the file to match. The check runs `claudezero.sh` for real
     via the `CLAUDEZERO_TEST_EMIT` flag — if you rename that flag, update its guard
     in `claudezero.sh` (near `run_loop`) and this script together.

   Run both locally before pushing (`shellcheck` needed for the second):

   ```sh
   bash .github/smoke.sh
   bash .github/check-embedded.sh
   ```

4. **Run the tests.** The end-to-end suite in [TEST.md](TEST.md) is executed by
   an LLM agent:

   ```sh
   claude --permission-mode auto "execute TEST.md and return a report"
   ```

5. **Open a PR** to this repository once all tests pass, with a short note on
   what changed and the test report.

Found a security issue? Don't open a PR or public issue — see
[SECURITY.md](SECURITY.md).
