---
name: drovr
description: Delegate mechanical, well-specified tasks to cheap headless Claude Code workers running on DeepSeek via the `drovr` CLI. Use when a task is bulk and checkable (broad searches, codemods, test scaffolding, first-pass reviews, doc sweeps) and the repo is on the allowlist. Do not use for judgment-heavy debugging, anything touching secrets, or repos `drovr` refuses.
---

# drovr

A worker is the same `claude` CLI pointed at DeepSeek (`claude-ds`), run headless.
It shares your settings, hooks and permission rules, but not your context: write
the task so it stands alone.

## Commands

```bash
drovr run <name> "<task>"            # read-only: edits and unapproved tools are denied
drovr run <name> --edit "<task>"     # own git worktree + branch drovr/<name>, edits auto-accepted
drovr wait <name> 900                # block until the turn ends (seconds; omit = no limit)
drovr read <name>                    # the worker's final answer
drovr prompt <name> "<follow-up>"    # next turn in the same session
drovr list
drovr rm <name>                      # refuses while its worktree has uncommitted changes
```

Names: `[a-z][a-z0-9-]*`, unique among live workers. Run from inside the target repo.

## Rules

- **Finish every task text with:** "End with a summary of at most 10 lines: what you did, files touched, anything unverified." `drovr read` returns only the final message, and you pay to read it.
- **Verify before trusting.** Read the worker's diff (`git -C <repo> diff main...drovr/<name>`) or spot-check its claims; never relay its summary as fact.
- **`drovr` refusing a repo is the user's policy** (`my.claude.drovr.allowedRepos`), not a bug to route around.
- Several independent workers may run at once; keep each task to one concern.
- A failed run prints its stderr on `drovr read`. Report it; do not retry blindly.
