# Changelog

All notable changes to ClaudeZero are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- The context-full restart signal is now computed in ClaudeZero's own Stop hook, from a
  threshold table (`CONTEXT_THRESHOLDS`) at the top of `claudezero.sh`, instead of depending on
  a third-party `suggest-compact` hook — one prerequisite instead of two. Existing installs need
  no action: a still-installed `suggest-compact` hook keeps writing a file nothing reads, so it
  is inert, not conflicting, and removing it is optional (ISSUE-035).

## [0.0.16] — 2026-08-03

### Added

- `CLAUDEZERO_WATCHDOG` kills a `claude` that has stopped making progress
  mid-turn, so a wedged API call or a hung tool costs one timeout instead of the
  whole overnight run. Progress is claude's own cumulative CPU time, so a long
  honest run is never killed — only one that has stopped working. SIGTERM first,
  SIGKILL after a 10s grace. Default `15m`; `0` disables it. The kill prints its
  own `❄ watchdog · no progress from claude for …` line, so it is never mistaken
  for the ordinary context-full restart (ISSUE-032).
- `CLAUDEZERO_LINK` — comma-separated top-level names symlinked from the repo
  root into every task worktree, unset by default. A worktree checks out tracked
  files only, so a gitignored spec directory a todo line points at is simply not
  there: the session falls back to the one-line title and reports done against
  it. Through a link the session reads the acceptance criteria and ticks them in
  the real file. The whole list is validated at startup and a bad entry (empty,
  containing `/`, or missing at the repo root) refuses the run — a typo costs the
  launch, not the tasks (ISSUE-033).
- `CLAUDEZERO_DEBUG` adds `--debug-file .git/debug-<base>-<instance>-<loop>.log`
  to the `claude` invocation, so a repeat of a rare startup flake leaves a trace
  instead of a bare hang. Off by default — a diagnostic opt-in, not a standing
  cost on every run. Unset, the claude argv is unchanged (ISSUE-030).
- An `Environment:` block on the `-h`/`--help` screen naming `CLAUDEZERO_WATCHDOG`
  and `CLAUDEZERO_LINK` with their formats and defaults, so neither knob has to be
  found by reading the script (ISSUE-032, ISSUE-033).
- A waiting line while every unchecked task is peer-held: a spinner with an
  elapsed clock and the held count on a terminal, a periodic line every 20s when
  stdout is a log or a pipe (ISSUE-031).

### Changed

- A `claude` session zeroes exactly one task and exits; the wait for the next
  claimable task lives in `claudezero.sh` instead of inside claude. `/loop` is
  gone from the zero prompt, and the Stop hook now ends the session at every turn
  end rather than only when the context bucket crosses its threshold. Every task
  therefore starts on a context isolated from the task before it (~20% fewer
  tokens on a working instance), and an instance with nothing to claim launches
  no `claude` at all instead of re-sending a startup context per probe. 
  `-l/--loopprompt` is unaffected (ISSUE-031).
- Both "claude exited after N runs" lines — `CLAUDEZERO_MAX_LOOPS`-reached and
  restarting — carry claude's real exit code: `claude exited with code %s after
  %s runs · …`. A hang is visible without re-deriving it from timing, and it is
  one line per event, not two (ISSUE-030).
- A run stopped by SIGTERM exits `143` (128+15), so a supervisor can tell
  "terminated" from "finished". Plain `timeout` callers still see its own `124`;
  use `timeout --preserve-status` to observe the 143 (BUG-029).

### Fixed

- A SIGTERM arriving while `claude` hangs no longer kills the run silently.
  `claude` ran as a foreground child, and bash defers every trap until a
  foreground child exits — so with a hung child no handler could run, the
  follow-up SIGKILL ended the process mid-wait, and the run dropped its
  `❄ execution stats` report, the fleet `❄ TOTAL`, and the EXIT trap that clears
  the instance liveness marker. `claude` is now backgrounded and reaped with a
  re-entrant `wait`, and a trapped TERM forwards to claude and breaks to the
  existing closer, so every exit path lands at the closing report (BUG-029).
- The watchdog's SIGKILL escalation rechecks `kill -0` before firing: if the
  earlier SIGTERM already reaped `claude`, the OS can recycle that pid during
  the grace sleep, and a blind SIGKILL would land on whatever unrelated process
  holds it next.
- `term_owner`/`find_owner` prefer the inherited `CLAUDE_PID` over the bare
  ancestor-name walk: the walk matched any process named `claude` up to 8 hops
  with no check it was this session's own, so a live `claude` sitting in the
  ancestry for an unrelated reason (a nested Task agent, this tool being
  dogfood-tested from inside a real session) got SIGTERMed instead.

## [0.0.15] — 2026-07-31

### Added

- Fleet-wide `TOTAL` block on every exit path, summing todos, todo time and
  tokens across every instance of the run. A crashed peer's landed work still
  counts.
- Per-instance token consumption in the execution-stats report: a headline total
  plus the input / output / cache-creation / cache-read breakdown. No dollar
  figure — there is no first-party rate source, and a hardcoded table would
  print confidently wrong money after any model launch.
- Per-instance count of todos zeroed, credited at the same point as the
  ownership time so the two always agree.
- The `-h`/`--help` screen states the script version on its own line below the
  `usage:` heading, so a bug report can quote the release without opening the
  script or starting a run to read the launch banner (ISSUE-028).
- Each `claude` session is named `(<instance id>) <nick> · <activity>`, visible
  in the prompt box, `/resume` picker and terminal title. The nickname is a
  short word no live peer holds, so you can say "kill kit" instead of reading
  eight hex characters off a terminal title. Names survive context restarts.

### Changed

- `claude`'s TUI goes to fd 4, so `claudezero.sh 2>&1 | tee run.log` captures
  only ClaudeZero's own output instead of every TUI redraw. Falls back to
  stdout when there is no redirect or stdin is not a terminal. `-h` documents
  the Ctrl+C-safe pipe form.
- The zero prompt's acquire / validate / re-check steps collapse into one
  `claim` call, so a failed validation no longer leaves a claim behind until a
  peer steals it.
- The report heading is "execution stats", not "execution time" — a token block
  is not a duration. The aggregate Claude-loops timing is gone.
- The execution-stats header carries the instance nickname next to its id
  (`instance a1b2c3d4 · moss`), so a report in a scrollback matches the terminal
  title it came from without reading eight hex characters.

### Fixed

- Launching inside a leftover task worktree is refused. It previously passed the
  root guard and took a peer's claim branch as the base, letting two instances
  claim the same todo and landing merges in the peer's in-flight branch
  (BUG-014).
- The `TOTAL` block prints on solo runs, with a singular heading. Suppressing it
  made a correct one-instance total indistinguishable from a fleet total that
  matched no files because the base slug was not what you thought.
- Three dojo activities no longer claim a single unit of work, which read as a
  ceiling the instance does not have.
- The script parses under bash 3.2, the `/bin/bash` macOS ships. The zero
  prompt's heredoc sat inside a command substitution, which bash 3.2 cannot
  parse, so every macOS run died before doing anything (BUG-024).
- A piped run on macOS reaches the prompt instead of killing `claude` at startup
  with `EINVAL … kqueue`. fd 4 is a dup of stdin, not a fresh open of `/dev/tty`
  — a descriptor from the clone device cannot be registered with kqueue
  (BUG-025).
- A zero-mode launch whose todo file is not tracked on the base branch is
  refused at startup. Untracked — never added, or gitignored — means every merge
  is refused, so the run would burn tokens on work that can never land
  (BUG-026).

## [0.0.14] — 2026-07-26

First public release. Base version — prior `0.0.x` iterations were pre-public
and are not itemized here.

- Zero mode: loops `claude` over a todo list, one task per git worktree,
  committing and checking off each task until the list is zeroed.
- Parallel zeroing: multiple instances coordinate via git worktrees and `flock`,
  each claiming todos the others haven't taken.
- Context-rot restart: SIGTERMs `claude` near the context limit (via the
  suggest-compact hook's state file) and restarts on a fresh context.
- Crash recovery: reclaims and finishes an abandoned task branch; work counts
  as done only once it lands on the base branch with its box checked.
- Loop mode (`-l`): loops `claude` on one literal prompt instead of zeroing.
