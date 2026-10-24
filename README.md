# drovr

drovr hands tasks from your Claude Code session to headless workers on cheaper
Anthropic-compatible backends like DeepSeek. Named after a *drover*, who moves a herd to
its destination and hands it over: drovr moves tasks out and brings results back.

A worker is `claude -p` pointed at another `ANTHROPIC_BASE_URL`. No daemon, no multiplexer.

## Workers

drovr workers always run restricted. For privacy, they only see the folder they're given.
For security, they get no shell and none of your settings or credentials. Against leaks,
every read is confined by the tool itself, not left to the model's judgement.

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

## Providers

Any backend with an Anthropic-compatible Messages endpoint works. Endpoints below are from
each provider's own docs (October 2026); model ids change often, so check there. Only
DeepSeek is tested with drovr so far.

| Provider | `baseUrl` | Example `model` |
|---|---|---|
| [DeepSeek](https://api-docs.deepseek.com/guides/anthropic_api) | `https://api.deepseek.com/anthropic` | `deepseek-v4-pro`, `deepseek-flash` |
| [Moonshot (Kimi)](https://platform.kimi.ai/docs/api/overview) | `https://api.moonshot.ai/anthropic` | see docs |
| [Z.ai (GLM)](https://docs.z.ai/devpack/tool/claude) | `https://api.z.ai/api/anthropic` | `GLM-5.3-Flash` |
| [MiniMax](https://platform.minimax.io/docs/token-plan/claude-code) | `https://api.minimax.io/anthropic` | `MiniMax-M3` |
| [Alibaba Model Studio (Qwen)](https://www.alibabacloud.com/help/en/model-studio/claude-code) | `https://dashscope.aliyuncs.com/apps/anthropic` | depends on plan |
| [OpenRouter](https://openrouter.ai/docs/cookbook/coding-agents/claude-code-integration) | `https://openrouter.ai/api` | any OpenRouter model slug |
| [Ollama](https://docs.ollama.com/api/anthropic-compatibility) (local) | `http://localhost:11434` | any pulled model; key file may hold `ollama` |

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
      "price": { "input": 1.32, "cachedInput": 0.044, "output": 3.96 },
      "effort": "medium",
      "models": {
        "deepseek-flash": { "price": { "input": 0.3, "cachedInput": 0.006, "output": 1.2 }, "effort": "low" }
      }
    }
  }
}
```

The key is read from `keyFile` at launch, never stored in the config. `authVar` picks
`ANTHROPIC_AUTH_TOKEN` (default) or `ANTHROPIC_API_KEY`; `price` (USD per 1M tokens) is
optional and fills the cost column of `drovr list`. Budgets need it; use 0 for a free model.
`effort` is the main model's default effort; `models` lists the provider's other models,
each with its own price and default effort (see [Models and effort](#models-and-effort)).

Optional top-level keys: `stallSeconds` (default 600, 0 turns it off), `dailyWarn`,
`dailySoftLimit` and `dailyBudget` (USD per day, all workers together) and `nudge` (default
true). See [Supervision](#supervision).

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
drovr run <name> [--edit | --scratch <dir>] [--via <provider>] [--model <id>] [--effort <level>]
          [--budget <usd>] [--schema <file>] "<task>"
drovr wait <name> [seconds]
drovr read <name>        # answer, then any denied tool calls
drovr read <name> --json # only the schema-checked JSON (--schema workers)
drovr prompt <name> "<follow-up>"
drovr list               # each worker: status, cost, turn, current action
drovr status             # one line for a prompt or status bar: "2▶ 1✓ 1✗"
drovr diff <name>        # what a repo worker changed
drovr merge <name> [-m <msg>]  # --edit worker: commit (as one commit with <msg>), merge into its start branch, clean up
drovr models             # each provider's models: price per 1M tokens (in/out), default effort
drovr claude <provider>  # Claude Code against a provider, for a quick check
drovr path <name> | providers | rm <name>
```

For WezTerm, `weztermHelper = true` installs `~/.local/share/drovr/wezterm.lua`, which
reads drovr's state without spawning a process (usage in the file's header).

## Models and effort

`--model <id>` runs a worker on another model of the same provider, and `--effort
low|medium|high|xhigh|max` sets how much it thinks; without them it gets the model's
defaults from the config. Both hold for every call of that worker, follow-ups, nudges and
repairs included, and `drovr list` and the spend ledger record them. Pass them to drovr,
not after `--`: drovr refuses `-- --model`, because costs and follow-ups would not know.

Each model is priced on its own. A model with no `models` entry has no price, so its cost
stays blank and it cannot carry a budget: drovr never charges it at the provider's price.

Measured on DeepSeek V4 Pro (2026-10, one short arithmetic task, four runs each): every
`max` run thought longer than every `low` run, typically 2–3×, but one `max` run spent 23k
thinking tokens on a question the others answered in under 1k. Give `max` a `--budget`.
Whether more effort gives better answers was not measured.

## Supervision

Every turn runs under a small supervisor, because a cheap model failing quietly costs more
than one failing loudly.

- **Silence, not slowness, stops a worker.** A model that is thinking still streams events
  every few tokens, so a worker with no event for `stallSeconds` is stuck: drovr stops its
  whole process group and `read` says `stalled`. A long but busy turn is never cut short.
  One silence is normal: while the model writes a single large block (a big `Write`), no
  event arrives until the block is done — about 20 s for 1.6k tokens on DeepSeek. The
  default 600 s covers Claude Code's 32k output cap at ~55 tokens/s; raise it for a slower
  provider.
- **Budgets only shrink.** `--budget <usd>` caps one worker across all of its turns,
  follow-ups included; `dailyBudget` caps all workers together per day (a ledger in
  `~/.local/state/drovr/spend.jsonl`). Each call gets the smaller of what is left, and is
  stopped when it spends past it (`over-budget`). Input cost is exact while a call runs;
  output is estimated from the streamed thinking-token counts and content until the call
  ends, when the provider's usage replaces the estimate.
- **Two softer daily lines.** Past `dailyWarn`, `run`, `prompt`, `list` and `status` show
  `⚠`, and so does the WezTerm helper. Past `dailySoftLimit`, drovr refuses new calls
  (`soft-limit`) but lets a running one finish; `dailyBudget` is the hard line that stops a
  call mid-way.
- **One nudge for an announced action.** Some cheaper models end with "Let me update the
  config:" and stop. When the answer's last line announces an action like that, drovr
  resumes the worker once with "continue". `"nudge": false` turns it off.
- **A schema, one repair, then "not done".** `--schema <file>` appends the schema to the task
  (and to every follow-up) and checks the JSON the answer ends with: the last ```` ```json ````
  fence, else the whole answer. A failing answer gets one repair turn that quotes the
  errors; if that fails too, `read` prints `NOT DONE` with the errors and exits 3, and
  `read --json` refuses. drovr checks a subset of JSON Schema without dependencies: `type`,
  `enum`, `required`, `properties`, `additionalProperties: false`, `items`, `minItems` and
  `minLength`.

Claude Code has its own `--max-budget-usd` and `--json-schema`; drovr does not use them,
because the first prices tokens with Claude Code's own table, which does not know other
providers' models, and the second needs structured-output support from the provider.

## Tests

`tests/run.sh` runs drovr against a stub Claude Code; nothing reaches a provider.

## License

GPL-3.0-only.
