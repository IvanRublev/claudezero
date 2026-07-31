# Todo

- [x] BUG-014 Fix the root guard so a launch inside a leftover `../ts-*` task worktree refuses instead of starting with a peer's claim branch as its base
- [x] ISSUE-015 Report how many todos an instance zeroed and drop the `Claude loops` timing line
- [x] ISSUE-016 Report token consumption per instance run: a headline total plus the four billed categories
- [x] ISSUE-017 Print a fleet-wide TOTAL of todos, time, and tokens on the Ctrl+C exit path (blocked by 015 + 016)
- [x] ISSUE-018 Send claude's TUI to the terminal on fd 4 so a piped run logs only ClaudeZero's reports, and document the Ctrl+C-safe `tee` command in `-h`
- [x] ISSUE-019 Name each claude session `(<instance id>) <dojo student activity>` via `--name`
- [x] ISSUE-020 Collapse the zero prompt's acquire/validate/re-check steps into one `.git/zero.sh claim task_id` call
- [x] ISSUE-021 Give each instance's claude session a short unique nickname: `(<id>) <nick> · <activity>`
- [x] BUG-022 Print the `TOTAL` block on solo runs too, singular heading — its absence today is indistinguishable from a fleet sum that matched nothing
- [x] BUG-023 Reword the two dojo activities that say `one` checkbox (plus the merge-gate arrival) so a session name reads as a continuing series, not a one-todo run
- [x] BUG-026 Refuse a zero-mode launch when the todo is not tracked on the base branch — untracked today means every merge is refused and nothing can ever land
- [x] ISSUE-027 Print the instance nickname next to its id in the execution stats header
