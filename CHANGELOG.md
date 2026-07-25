# Changelog

All notable changes to ClaudeZero are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
