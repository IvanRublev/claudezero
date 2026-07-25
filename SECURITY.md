# Security Policy

## Reporting a vulnerability

Email git@ivanrublev.me — do not open a public issue for security bugs.
Expect a first reply within 7 days. Include repro steps and the affected
version (see `VERSION` in `claudezero.sh`).

## Supported versions

Only the latest release gets fixes. Pre-1.0 — no backports.

## Security model — read before running

ClaudeZero runs `claude --permission-mode auto`: the agent acts on your
machine WITHOUT per-action approval. It edits files, runs shell commands, and
commits — unattended, in a loop. Treat every run as "I authorize this agent to
do anything I could do at this terminal."

### Trust boundaries

- **The todo file is executable intent.** Each line becomes an agent task.
  A todo authored by someone else is remote code execution by proxy. Only
  zero todo files you wrote or reviewed line by line.
- **CLAUDE.md steers every run.** The reflection loop lets the agent append to
  it; a poisoned CLAUDE.md redirects all future tasks. Review its diffs like
  any other code.
- **The suggest-compact hook is third-party** (affaan-m/ECC) and runs in your
  Claude session. Audit and pin it; ClaudeZero only reads its state file.

### Blast radius, and how it's bounded

- **Start from a clean, committed tree** — the script refuses to run otherwise.
  It forks a worktree per task off the branch you launch on (`main` is the
  intended base) and merges each back into it. Commits land autonomously, so
  your clean starting commit is the restore point — git is your only undo.
- Parallel instances create worktrees and claim branches. A crash leaves them
  behind — inspect `git worktree list` before assuming a clean state.
- Merges are serialized via `flock`; on conflict or over-check the loop stops
  and hands off rather than force-merge. It won't silently corrupt the base.
- `--permission-mode auto` still respects Claude Code's own deny rules — set
  project `permissions.deny` for paths and commands the agent must never touch.

### Not in scope

- Bugs in `claude` itself — report to Anthropic.
- Whatever the agent does when you feed it an untrusted todo file — that's use,
  not a vulnerability.
