---
name: drovr
description: Hand mechanical, well-specified tasks from this session to headless Claude Code workers on cheaper Anthropic-compatible backends (DeepSeek by default) via the `drovr` CLI. Use when a task is bulk and checkable (broad searches, codemods, test scaffolding, first-pass reviews, doc sweeps) and the repo is public, or allowlisted with a DROVR.md, or the task can be briefed in a scratch folder. Do not use for judgment-heavy debugging, or for anything the ground rules below exclude.
---

# drovr

A worker is the same `claude` CLI pointed at another provider's Anthropic-compatible
endpoint (`claude-<provider>`), run headless. It shares your settings, hooks and
permission rules, but not your context: write the task so it stands alone.

**Everything a worker reads goes to its provider.** Phrasing a task abstractly does
not limit what it reads; where it runs does. Pick the mode by what may leave.

## Two modes

| Mode | Worker sees | Allowed when |
|---|---|---|
| public repo (`drovr run`, `--edit`) | a fresh checkout of the remote's default branch: pushed content only, never your tree | origin answers an anonymous `git ls-remote` (drovr checks); no allowlist or DROVR.md needed |
| allowlisted repo (`drovr run`, `--edit`) | the whole working tree (read-only), or its own worktree with `--edit` | repo is in `my.claude.drovr.allowedRepos` **and** has a `DROVR.md` that permits this kind of task |
| scratch (`--scratch <dir>`) | only the folder you prepared, copied into its own state; Bash disabled | anywhere, as long as the brief itself obeys the ground rules |

For scratch: write a self-contained brief into a folder in your scratchpad (task
description plus only the snippets it needs, already cleaned), then
`drovr run <name> --scratch <dir> "<task>"`. The worker's edits stay in
`drovr path <name>`; copy back what you accept.

## Ground rules (every repo, every provider)

Never send, in a brief or by running a worker where it can read them:
- personal data about anyone (names with contact details, addresses, health, finances)
- credentials, keys, tokens, `.env` contents, agenix plaintext
- client or business data (quotes, prices, customer records, contracts)
- unpublished business logic that is the product itself

If cleaning a task enough to satisfy these costs more than it saves, use a normal
Claude subagent instead.

## DROVR.md (per repo)

drovr refuses an allowlisted (private) repo without one; a public repo may have one
to limit providers or record decisions. It records what may leave that repo, in plain
language, plus an optional `providers:` line:

```markdown
providers: deepseek

# What may leave this repo
- source under src/ and tests/ (open-source-able tooling)
# What may not
- data/customers/, anything under fixtures/real/
# Decisions
- 2026-10-05: test scaffolding for the parser: ok (asked)
```

**When a task is not clearly covered by the repo's DROVR.md: ask the user before
starting the worker, then write their answer into DROVR.md under Decisions.** Do not
create a DROVR.md, or add a repo to the allowlist, without asking. The allowlist
lives in Nix, so only the user changes it.

## Commands

```bash
drovr run <name> "<task>"                  # repo, read-only: edits and unapproved tools are denied
drovr run <name> --edit "<task>"           # repo, own worktree + branch drovr-<name>, edits auto-accepted
drovr run <name> --scratch <dir> "<task>"  # only <dir>, copied; edits auto-accepted, no Bash
drovr run <name> --via <p> "<task>"        # pick a provider; `drovr providers` lists them
drovr wait <name> 900                      # block until the turn ends (seconds; omit = no limit)
drovr read <name>                          # the worker's final answer
drovr prompt <name> "<follow-up>"          # next turn in the same session
drovr path <name>                          # its working directory
drovr list
drovr rm <name>                            # refuses while its worktree has uncommitted changes
```

Names: `[a-z][a-z0-9-]*`, unique among live workers. Repo mode runs from inside the repo.

## Working with results

- **Finish every task text with:** "End with a summary of at most 10 lines: what you did, files touched, anything unverified." `drovr read` returns only the final message, and you pay to read it.
- **Verify before trusting.** Read the worker's diff (`git -C <repo> diff main...drovr-<name>`), or the files in `drovr path <name>`, or spot-check its claims. Never relay its summary as fact.
- A refusal from drovr (allowlist, missing DROVR.md, provider not allowed) is the user's policy, not a bug to route around.
- Several independent workers may run at once; keep each task to one concern.
- A failed run prints its stderr on `drovr read`. Report it; do not retry blindly.
