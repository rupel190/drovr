# drovr

drovr hands tasks from your Claude Code session to headless workers on cheaper
Anthropic-compatible backends like DeepSeek. Named after a *drover*, who moves a herd to
its destination and hands it over: drovr moves tasks out and brings results back.

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

## Install

drovr is one bash script plus a config file. It needs `bash`, `jq`, `git`, `setsid`
(util-linux) and Claude Code.

```bash
install -Dm755 drovr.sh ~/.local/bin/drovr
install -Dm644 SKILL.md ~/.claude/skills/drovr/SKILL.md   # optional
```

`~/.config/drovr/config.json` (or `$DROVR_CONFIG`):

```json
{
  "claude": "claude",
  "defaultProvider": "deepseek",
  "allowedRepos": [],
  "providers": {
    "deepseek": {
      "baseUrl": "https://api.deepseek.com/anthropic",
      "model": "deepseek-v4-pro",
      "keyFile": "/path/to/deepseek-key",
      "price": { "input": 1.32, "cachedInput": 0.044, "output": 3.96 }
    }
  }
}
```

The key is read from `keyFile` at launch, never stored in the config. `authVar` picks
`ANTHROPIC_AUTH_TOKEN` (default) or `ANTHROPIC_API_KEY`; `price` (USD per 1M tokens) is
optional and fills the cost column of `drovr list`.

### home-manager

```nix
inputs.drovr.url = "github:rupel190/drovr";

imports = [ inputs.drovr.homeManagerModules.default ];
programs.drovr = {
  enable = true;
  providers.deepseek = {
    baseUrl = "https://api.deepseek.com/anthropic";
    model = "deepseek-v4-pro";
    keyFile = "/run/agenix/deepseek-api-key";
  };
};
```

The module writes the config, installs the skill, and adds `claude-<name>` shortcuts for
`drovr claude <name>`.

## Usage

```bash
drovr run <name> [--edit | --scratch <dir>] [--via <provider>] "<task>"
drovr wait <name> [seconds]
drovr read <name>        # answer, then any denied tool calls
drovr prompt <name> "<follow-up>"
drovr list               # each worker: status, cost, turn, current action
drovr status             # one line for a prompt or status bar: "2▶ 1✓ 1✗"
drovr claude <provider>  # Claude Code against a provider, for a quick check
drovr path <name> | providers | rm <name>
```

For WezTerm, `weztermHelper = true` installs `~/.local/share/drovr/wezterm.lua`, which
reads drovr's state without spawning a process (usage in the file's header).

## Tests

`tests/run.sh` runs drovr against a stub Claude Code; nothing reaches a provider.

## License

GPL-3.0-only.
