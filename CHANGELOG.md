# Changelog

All notable changes to ClaudeZero are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
- Each `claude` session is named `(<instance id>) <nick> · <activity>`, visible
  in the prompt box, `/resume` picker and terminal title. The nickname is a
  short word no live peer holds, so you can say "kill kit" instead of reading
  eight hex characters off a terminal title. Names survive context restarts.

### Changed

- `claude`'s TUI goes to fd 4, so `claudezero.sh 2>&1 | tee run.log` captures
  only ClaudeZero's own output instead of every TUI redraw. Falls back to
  stdout when there is no redirect or no controlling terminal. `-h` documents
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
