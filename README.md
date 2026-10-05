# drovr

Hand tasks from your Claude Code session to headless Claude Code workers running on
cheaper Anthropic-compatible backends (DeepSeek, or anything else that speaks the
Anthropic Messages API). Your main session decides what to delegate, `drovr` starts
the worker, and the answer comes back as one message.

No daemon, no multiplexer: a worker is `claude -p` with a different `ANTHROPIC_BASE_URL`,
detached, with its state in `~/.local/state/drovr/<name>/`.

## What a worker can and cannot do

Workers run with their own empty Claude config (`~/.local/state/drovr-claude`) and
`--restricted --strict-mcp-config --tools Read,Grep,Glob,Edit,Write`:

- **Read, search and edit files. Nothing else**: no Bash, so no builds, tests, git or web.
- **File tools are confined to the worker's directory.** Reads outside it are refused by
  the tool, not by the model (verified with a canary file in `~/.cache`).
- **None of your settings, permission rules, MCP servers, CLAUDE.md or memory** reach a
  worker.
- **Small prompt.** The five-tool set cuts the first-turn prompt from ~45k tokens (a full
  personal config) to ~3k.

## Where a worker runs

| Mode | Worker sees | Allowed when |
|---|---|---|
| public repo | a worktree of your local HEAD: committed files, including unpushed commits; never uncommitted edits, untracked or ignored files | `origin` answers an anonymous `git ls-remote` |
| allowlisted repo | the same kind of worktree | listed in `allowedRepos` **and** has a `DROVR.md` at its root |
| `--scratch <dir>` | only a copy of a folder you prepared | anywhere |

Everything a worker reads is sent to its provider. `DROVR.md` records, in plain
language, what may leave a private repo, plus an optional `providers: a, b` line.

## Install (home-manager, flakes)

```nix
# flake.nix
inputs.drovr.url = "github:rupel190/drovr";

# home-manager configuration
imports = [ inputs.drovr.homeManagerModules.default ];

programs.drovr = {
  enable = true;
  providers.deepseek = {
    baseUrl = "https://api.deepseek.com/anthropic";
    model = "deepseek-v4-pro";
    keyFile = "/run/agenix/deepseek-api-key"; # any file holding the key
  };
  # allowedRepos = [ "/home/me/projects/private-thing" ];
};
```

Each provider becomes a `claude-<name>` wrapper (here `claude-deepseek`). The key is read
from `keyFile` at launch and never enters the Nix store. `claudePackage` defaults to
`pkgs.claude-code`.

## Commands

```bash
drovr run <name> "<task>"                  # read-only worker in a worktree of HEAD
drovr run <name> --edit "<task>"           # own worktree + branch drovr-<name>, edits accepted
drovr run <name> --scratch <dir> "<task>"  # only <dir>, copied
drovr run <name> --via <provider> "<task>"
drovr wait <name> [seconds]
drovr read <name>                          # final answer, then any denied tool calls
drovr prompt <name> "<follow-up>"          # next turn, same session
drovr path <name> | drovr list | drovr providers | drovr rm <name>
```

The bundled skill (installed to `~/.claude/skills/drovr`, disable with
`installSkill = false`) teaches the main session the modes, the ground rules for what
never leaves, and to use drovr only when asked.
