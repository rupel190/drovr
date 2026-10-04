---
name: claude-workers
description: Delegate mechanical, well-specified tasks to cheap headless Claude Code workers running on DeepSeek via the `cw` CLI. Use when a task is bulk and checkable (broad searches, codemods, test scaffolding, first-pass reviews, doc sweeps) and the repo is on the allowlist. Do not use for judgment-heavy debugging, anything touching secrets, or repos `cw` refuses.
---

# claude-workers (`cw`)

A worker is the same `claude` CLI pointed at DeepSeek (`claude-ds`), run headless.
It shares your settings, hooks and permission rules, but not your context: write
the task so it stands alone.

## Commands

```bash
cw run <name> "<task>"            # read-only: edits and unapproved tools are denied
cw run <name> --edit "<task>"     # own git worktree + branch cw/<name>, edits auto-accepted
cw wait <name> 900                # block until the turn ends (seconds; omit = no limit)
cw read <name>                    # the worker's final answer
cw prompt <name> "<follow-up>"    # next turn in the same session
cw list
cw rm <name>                      # refuses while its worktree has uncommitted changes
```

Names: `[a-z][a-z0-9-]*`, unique among live workers. Run from inside the target repo.

## Rules

- **Finish every task text with:** "End with a summary of at most 10 lines: what you did, files touched, anything unverified." `cw read` returns only the final message, and you pay to read it.
- **Verify before trusting.** Read the worker's diff (`git -C <repo> diff main...cw/<name>`) or spot-check its claims; never relay its summary as fact.
- **`cw` refusing a repo is the user's policy** (`my.claude.workers.allowedRepos`), not a bug to route around.
- Several independent workers may run at once; keep each task to one concern.
- A failed run prints its stderr on `cw read`. Report it; do not retry blindly.
