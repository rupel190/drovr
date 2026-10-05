# drovr

Hand tasks from your Claude Code session to headless Claude Code workers on cheaper
Anthropic-compatible backends, such as DeepSeek. Named after a *drover*, who moves a
herd to its destination and hands it over: drovr moves tasks out and brings results back.

A worker is `claude -p` pointed at another `ANTHROPIC_BASE_URL`. No daemon, no multiplexer.

## Workers

- Run `--restricted` with only Read, Grep, Glob, Edit and Write: **no Bash**, so no
  builds, tests or git.
- Can't read outside their own directory (enforced by the tool, not the model).
- Get an empty Claude config: none of your settings, MCP servers, CLAUDE.md or memory.
- Start with a ~3k-token prompt instead of ~17.5k for stock Claude Code.

| Mode | Worker sees | Allowed when |
|---|---|---|
| public repo | worktree of your local HEAD (no uncommitted, untracked or ignored files) | `origin` is readable anonymously |
| private repo | the same | in `allowedRepos` and has a `DROVR.md` |
| `--scratch <dir>` | a copy of `<dir>` only | always |

Everything a worker reads goes to its provider. `DROVR.md` states what may leave a
private repo; an optional `providers: a, b` line limits backends.

## Install (home-manager)

```nix
inputs.drovr.url = "github:rupel190/drovr";

imports = [ inputs.drovr.homeManagerModules.default ];
programs.drovr = {
  enable = true;
  providers.deepseek = {
    baseUrl = "https://api.deepseek.com/anthropic";
    model = "deepseek-v4-pro";
    keyFile = "/run/agenix/deepseek-api-key"; # read at launch, never in the store
  };
};
```

Each provider becomes a `claude-<name>` wrapper. A skill is installed to
`~/.claude/skills/drovr` (`installSkill = false` to skip).

## Usage

```bash
drovr run <name> [--edit | --scratch <dir>] [--via <provider>] "<task>"
drovr wait <name> [seconds]
drovr read <name>        # answer, then any denied tool calls
drovr prompt <name> "<follow-up>"
drovr list | path <name> | providers | rm <name>
```

## License

GPL-3.0-only.
