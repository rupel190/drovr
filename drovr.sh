#!/usr/bin/env bash
# shellcheck disable=SC2016 # single-quoted $vars are jq variables, not shell ones
# drovr — hand tasks to headless Claude Code workers on Anthropic-compatible backends.
# Needs bash, jq, git, coreutils, sed and setsid (util-linux). Config: see README.
set -euo pipefail

config_file="${DROVR_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/drovr/config.json}"
state_root="${XDG_STATE_HOME:-$HOME/.local/state}/drovr"
# One Claude config for every worker and provider: none of your settings, MCP servers,
# CLAUDE.md or memory reach a worker, and its transcripts stay out of ~/.claude.
worker_config="${XDG_STATE_HOME:-$HOME/.local/state}/drovr-claude"

# --restricted confines the file tools to the worker's directory and drops every
# command-running tool; five tools also cut the prompt from ~17.5k to ~3.1k tokens.
worker_flags=(--restricted --strict-mcp-config --tools "Read,Grep,Glob,Edit,Write")

self="$(readlink -f "${BASH_SOURCE[0]}")"

die() { echo "drovr: $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
usage: drovr run <name> [--edit | --scratch <dir>] [--via <provider>] [--budget <usd>]
                 [--schema <file>] <task> [-- <claude args>...]
       drovr prompt <name> <text>      follow-up turn in the same session
       drovr wait <name> [seconds]     block until the turn ends (default: no limit)
       drovr read <name> [--json]      print the worker's final answer (--json: only its
                                       schema-checked JSON)
       drovr diff <name>               what the worker changed (repo workers)
       drovr merge <name> [-m <msg>]   commit an --edit worker's changes (as one commit with
                                       <msg>), merge them, clean up
       drovr path <name>               the worker's working directory
       drovr list                      workers with cost, turn and current action
       drovr status                    one-line summary for a prompt or status bar
       drovr providers
       drovr claude <provider> [args]  run Claude Code against a provider
       drovr rm <name>                 drop the worker (and its worktree, if clean)
EOF
  exit 2
}

# cfg <jq args...>: query the config file.
cfg() {
  [ -r "$config_file" ] || die "no config at $config_file (see README)"
  jq -r "$@" "$config_file"
}

providers() { cfg '.providers // {} | keys[]'; }
default_provider() { cfg '.defaultProvider // (.providers // {} | keys[0]) // empty'; }

has_provider() {
  [ -n "$1" ] && [ "$(cfg --arg p "$1" '.providers // {} | has($p)')" = true ]
}

worker_dir() {
  [[ "$1" =~ ^[a-z][a-z0-9-]{0,31}$ ]] || die "bad name '$1' (a-z, 0-9, -)"
  echo "$state_root/$1"
}

allowed() {
  local repo="$1" root roots
  roots="$(cfg '.allowedRepos // [] | .[]')"
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    root="${root%/}"
    [[ "$repo" == "$root" || "$repo" == "$root"/* ]] && return 0
  done <<<"$roots"
  return 1
}

# public_url <repo>: origin as an anonymous https URL, or nothing.
public_url() {
  local url rest
  url="$(git -C "$1" remote get-url origin 2>/dev/null)" || return 1
  case "$url" in
    git@*:*) rest="${url#git@}"; echo "https://${rest/://}" ;;
    ssh://* | git+ssh://* | https://*) rest="${url#*://}"; echo "https://${rest#*@}" ;;
    *) return 1 ;;
  esac
}

# Public = readable with no credentials at all; checked against the remote, not guessed.
is_public() {
  local url
  url="$(public_url "$1")" || return 1
  GIT_TERMINAL_PROMPT=0 timeout 15 git -c credential.helper= -c core.askPass=true \
    ls-remote --exit-code "$url" HEAD >/dev/null 2>&1
}

# DROVR.md at the repo root says what may leave the repo; an optional
# "providers: a, b" line limits which backends may see it.
repo_providers() {
  [ -f "$1/DROVR.md" ] || return 0
  sed -n 's/^providers:[[:space:]]*//p' "$1/DROVR.md" | head -n1 | tr ',' ' '
}

# drovr claude <provider> [args]: Claude Code pointed at the provider. The key is read
# from its keyFile here, so it never appears on a command line or in the config.
cmd_claude() {
  local p="${1:-}"
  has_provider "$p" || die "unknown provider '$p' (have: $(providers | xargs))"
  shift
  local base model small keyfile authvar claude
  base="$(cfg --arg p "$p" '.providers[$p].baseUrl')"
  model="$(cfg --arg p "$p" '.providers[$p].model')"
  small="$(cfg --arg p "$p" '.providers[$p].smallModel // empty')"
  keyfile="$(cfg --arg p "$p" '.providers[$p].keyFile')"
  authvar="$(cfg --arg p "$p" '.providers[$p].authVar // "ANTHROPIC_AUTH_TOKEN"')"
  claude="$(cfg '.claude // "claude"')"
  [[ "$authvar" =~ ^ANTHROPIC_(AUTH_TOKEN|API_KEY)$ ]] || die "provider '$p': authVar must be ANTHROPIC_AUTH_TOKEN or ANTHROPIC_API_KEY"
  [ -r "$keyfile" ] || die "provider '$p': key file $keyfile not readable"

  export "$authvar"="$(<"$keyfile")"
  # Blank the other one, so Claude Code cannot fall back to Anthropic's own auth.
  if [ "$authvar" = ANTHROPIC_AUTH_TOKEN ]; then export ANTHROPIC_API_KEY=""; else export ANTHROPIC_AUTH_TOKEN=""; fi
  export ANTHROPIC_BASE_URL="$base" ANTHROPIC_MODEL="$model"
  [ -z "$small" ] || export ANTHROPIC_DEFAULT_HAIKU_MODEL="$small"
  export CLAUDE_WORKER=1
  # The default (10 retries, growing waits) turns a bad key into minutes of silence.
  export CLAUDE_CODE_MAX_RETRIES=3
  exec "$claude" "$@"
}

# launch <dir> <worker-state> <provider> <claude args...>: one headless turn, detached so it
# outlives the calling shell (an agent's shell tool reaps its children).
launch() {
  local cwd="$1" w="$2" via="$3"
  shift 3
  rm -f "$w/exit" "$w/stopped" "$w/invalid" "$w/result.json" "$w/err.log"
  mkdir -p "$worker_config"
  # Each turn appends to events.jsonl; progress reads from this offset on.
  touch "$w/events.jsonl"
  wc -l <"$w/events.jsonl" >"$w/offset"
  setsid -f "$self" _turn "$w" "$cwd" "$via" "$@" </dev/null >/dev/null 2>>"$w/err.log"
}

price_of() { cfg --arg p "$1" '.providers[$p].price // empty | tojson' 2>/dev/null || true; }

# call_cost <worker> <line>: USD of the claude call whose events start after <line>. Exact
# once its result event exists. Before that, input is exact (each assistant message carries
# it) but output is only streamed as thinking-token counts and content, so it is estimated.
call_cost() {
  local w="$1" off="$2" price
  price="$(price_of "$(cat "$w/via" 2>/dev/null)")"
  [ -n "$price" ] || return 0
  tail -n +"$((off + 1))" "$w/events.jsonl" 2>/dev/null | jq -rs --argjson p "$price" '
    def usd(u; out): ((u.input_tokens // 0) + (u.cache_creation_input_tokens // 0)) * ($p.input // 0)
      + (u.cache_read_input_tokens // 0) * ($p.cachedInput // $p.input // 0) + out * ($p.output // 0);
    ([.[] | select(.type == "result")] | last) as $r
    | if $r then usd($r.usage // {}; $r.usage.output_tokens // 0) / 1e6
      else
        ([.[] | select(.type == "assistant")] | group_by(.message.id) | map(.[0].message.usage // {})) as $in
        | ([.[] | select(.subtype == "thinking_tokens") | .estimated_tokens_delta // 0] | add // 0) as $think
        | ([.[] | select(.type == "assistant") | .message.content[]?
            | (.text // "") + (if .type == "tool_use" then (.input | tojson) else "" end) | length] | add // 0) as $chars
        | (($in | map(usd(.; 0)) | add // 0) + usd({}; $think + $chars / 4)) / 1e6
      end'
}

# add_spend <worker> <usd>: the worker's running total, and the day's ledger across workers.
add_spend() {
  local w="$1" usd="$2"
  [ -n "$usd" ] || return 0
  jq -n --argjson a "$(cat "$w/spent" 2>/dev/null || echo 0)" --argjson b "$usd" '$a + $b' >"$w/spent.tmp" &&
    mv "$w/spent.tmp" "$w/spent"
  jq -nc --arg day "$(date +%F)" --arg worker "${w##*/}" --argjson usd "$usd" \
    '{day: $day, worker: $worker, usd: $usd}' >>"$state_root/spend.jsonl"
  # Past dailyWarn: "<day> <usd>" in a file, so a status bar can show it without parsing
  # the ledger. It carries its day, so it expires on its own.
  local warn today
  warn="$(cfg '.dailyWarn // empty')"
  [ -n "$warn" ] || return 0
  today="$(spent_today)"
  [ "$(jq -n --argjson t "$today" --argjson w "$warn" '$t >= $w')" = true ] || return 0
  echo "$(date +%F) $(today_usd)" >"$state_root/warning"
}

spent_today() {
  jq -s --arg day "$(date +%F)" 'map(select(.day == $day) | .usd) | add // 0' \
    "$state_root/spend.jsonl" 2>/dev/null || echo 0
}

# today_usd: the day's spend, rounded to cents.
today_usd() { jq -n --argjson t "$(spent_today)" '$t * 100 | round / 100'; }

# warning: "today's drovr spend is $X (warning at $Y)" once past dailyWarn, else nothing.
# Counted from the ledger, so it holds even before the next spend writes the status file.
warning() {
  local warn
  warn="$(cfg '.dailyWarn // empty')"
  [ -n "$warn" ] || return 0
  [ "$(jq -n --argjson t "$(spent_today)" --argjson w "$warn" '$t >= $w')" = true ] || return 0
  echo "today's drovr spend is \$$(today_usd) (warning at \$$warn)"
}

# soft_limit_hit: the day's spend reached dailySoftLimit. Unlike dailyBudget it never stops
# a call that is running; it only refuses new calls, so no turn is cut off halfway.
soft_limit_hit() {
  local soft
  soft="$(cfg '.dailySoftLimit // empty')"
  [ -n "$soft" ] && [ "$(jq -n --argjson t "$(spent_today)" --argjson s "$soft" '$t >= $s')" = true ]
}

soft_limit_note() {
  echo "today's drovr spend \$$(today_usd) reached dailySoftLimit \$$(cfg '.dailySoftLimit'); raise it in the config to go on"
}

# budget_left <worker>: USD this worker may still spend, or nothing when uncapped. Its own
# --budget minus what it spent, capped by dailyBudget minus what every worker spent today.
# Both only shrink, so a follow-up or a nudge never gets fresh money.
budget_left() {
  local w="$1" own daily today
  own="$(cat "$w/budget" 2>/dev/null)" || own=""
  daily="$(cfg '.dailyBudget // empty')"
  [ -n "$own$daily" ] || return 0
  today="$(spent_today)"
  jq -nr --arg own "$own" --arg daily "$daily" --argjson spent "$(cat "$w/spent" 2>/dev/null || echo 0)" \
    --argjson today "${today:-0}" '
    [(if $own != "" then ($own | tonumber) - $spent else empty end),
     (if $daily != "" then ($daily | tonumber) - $today else empty end)] | min'
}

# Checks the JSON an answer ends with (last ```json fence, else the whole answer) against a
# JSON Schema subset: type, enum, required, properties, additionalProperties: false, items,
# minItems, minLength. Prints {value, errors}.
# shellcheck disable=SC2034 # used through cmd_turn
read -r -d '' schema_jq <<'JQ' || true
def check($s; $p):
  . as $v | ($v | type) as $t
  | if ($s | type) != "object" then empty else
    (if $s.type == null then empty
     else ([$s.type] | flatten) as $ts
       | if any($ts[]; . == $t or (. == "integer" and $t == "number" and ($v | floor) == $v)) then empty
         else "\($p): expected \($ts | join(" or ")), got \($t)" end end),
    (if $s.enum == null or any($s.enum[]; . == $v) then empty
     else "\($p): must be one of \($s.enum | tojson)" end),
    (if $t == "string" and $s.minLength != null and ($v | length) < $s.minLength
     then "\($p): shorter than \($s.minLength)" else empty end),
    (if $t == "object" then
       (($s.required // [])[] | select(. as $k | $v | has($k) | not) | "\($p): missing \"\(.)\""),
       ($v | to_entries[] | . as $e
         | if ($s.properties // {}) | has($e.key) then ($e.value | check($s.properties[$e.key]; "\($p).\($e.key)"))
           elif $s.additionalProperties == false then "\($p): unexpected \"\($e.key)\""
           else empty end)
     else empty end),
    (if $t == "array" then
       (if $s.minItems != null and ($v | length) < $s.minItems then "\($p): fewer than \($s.minItems) items" else empty end),
       (if $s.items != null then ($v | to_entries[] | .key as $i | .value | check($s.items; "\($p)[\($i)]")) else empty end)
     else empty end)
  end;
def last_fence:
  [splits("\n")] | reduce .[] as $l ({in: false, buf: [], last: null};
    if ($l | test("^\\s*```")) then
      (if .in then {in: false, buf: [], last: (.buf | join("\n"))} else .in = true | .buf = [] end)
    elif .in then .buf += [$l] else . end) | .last;
((last_fence // .) | try fromjson catch null) as $v
| if $v == null then {value: null, errors: ["no JSON at the end of the answer"]}
  else {value: $v, errors: [$v | check($schema; "$")]} end
JQ

schema_note() {
  printf '\n\nEnd your final message with a JSON object in a ```json fence that matches this JSON Schema:\n%s' \
    "$(jq -c . "$1")"
}

# announced <worker> <line>: the call's answer ends by announcing an action instead of taking
# it ("Let me update the config:"), a habit of some cheaper models.
announced() {
  local last
  last="$(tail -n +"$(($2 + 1))" "$1/events.jsonl" | jq -rs '[.[] | select(.type == "result")] | last | .result // ""' |
    sed '/^[[:space:]]*$/d' | tail -n1)"
  grep -Eiq "^[[:space:]]*((now|next|then),? )?(let me|i'll|i will|i'm going to|i am going to)\\b|:[[:space:]]*\$" <<<"$last"
}

# cmd_turn (`drovr _turn`, run detached by launch): one turn, supervised. Each claude call is
# stopped when it goes silent for stallSeconds or spends past the budget. Then, at most once
# each: a nudge if the answer announced an action it never took, and a repair if the answer's
# JSON fails the worker's schema. Writes out.json and, last, exit.
cmd_turn() {
  local w="$1" cwd="$2" via="$3" rc=0 sid out
  shift 3
  set +e
  cd "$cwd" || { echo 1 >"$w/exit"; return; }
  call "$w" "$via" "$@" || rc=$?
  if [ "$rc" = 0 ] && [ ! -e "$w/stopped" ] && [ "$(cfg '.nudge != false')" = true ] && announced "$w" "$(cat "$w/call_offset")"; then
    sid="$(session_of "$w")"
    call "$w" "$via" "Continue: do what you just said you would, then give your final answer." \
      --resume "$sid" --permission-mode "$(cat "$w/mode")" || rc=$?
  fi
  if [ "$rc" = 0 ] && [ ! -e "$w/stopped" ] && [ -f "$w/schema.json" ]; then
    out="$(check_answer "$w")"
    if [ "$(jq '.errors | length' <<<"$out")" != 0 ]; then
      sid="$(session_of "$w")"
      call "$w" "$via" "Your final JSON did not match the schema:
$(jq -r '.errors[] | "- " + .' <<<"$out")
Reply with only the corrected JSON object in a \`\`\`json fence." \
        --resume "$sid" --permission-mode "$(cat "$w/mode")" || rc=$?
      out="$(check_answer "$w")"
    fi
    if [ "$(jq '.errors | length' <<<"$out")" = 0 ]; then
      jq '.value' <<<"$out" >"$w/result.json"
    else
      jq -r '.errors[]' <<<"$out" >"$w/invalid"
      [ "$rc" != 0 ] || rc=3
    fi
  fi
  [ ! -e "$w/stopped" ] || rc=124
  # The turn's final result event, in the shape `read` and `prompt` expect.
  jq -c 'select(.type == "result")' "$w/events.jsonl" 2>/dev/null | tail -n1 >"$w/out.json"
  echo "$rc" >"$w/exit"
}

# check_answer <worker>: {value, errors} for the answer of the last call against its schema.
check_answer() {
  tail -n +"$(($(cat "$1/call_offset") + 1))" "$1/events.jsonl" |
    jq -rs '[.[] | select(.type == "result")] | last | .result // ""' |
    jq -Rs --argjson schema "$(cat "$1/schema.json")" "$schema_jq"
}

session_of() { jq -rs 'map(.session_id // empty) | last // empty' "$1/events.jsonl" 2>/dev/null; }

# call <worker> <provider> <claude args...>: one claude call in its own process group, watched.
call() {
  local w="$1" via="$2" off pid size last=-1 quiet=0 stall left rc=0
  shift 2
  off="$(wc -l <"$w/events.jsonl")"
  echo "$off" >"$w/call_offset"
  if soft_limit_hit; then
    echo "soft-limit: $(soft_limit_note)" >"$w/stopped"
    return 125
  fi
  left="$(budget_left "$w")"
  if [ -n "$left" ] && [ "$(jq -n --argjson l "$left" '$l <= 0')" = true ]; then
    echo "no-budget: nothing left of the budget" >"$w/stopped"
    return 125
  fi
  stall="$(cfg '.stallSeconds // 600')"
  setsid env -u WEZTERM_PANE CLAUDE_CONFIG_DIR="$worker_config" "$self" claude "$via" -p "$@" "${worker_flags[@]}" \
    --output-format stream-json --verbose >>"$w/events.jsonl" 2>>"$w/err.log" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    sleep 1
    size="$(stat -c %s "$w/events.jsonl")"
    if [ "$size" != "$last" ]; then
      last="$size" quiet=0
      if [ -n "$left" ] && [ "$(jq -n --argjson s "$(call_cost "$w" "$off")" --argjson l "$left" '$s > $l')" = true ]; then
        halt "$w" "$pid" "over-budget: spent past the \$$(jq -n --argjson l "$left" '$l * 10000 | round / 10000') left"
      fi
    else
      quiet=$((quiet + 1))
      if [ "$stall" -gt 0 ] && [ "$quiet" -ge "$stall" ]; then
        halt "$w" "$pid" "stalled: no output for ${quiet}s"
      fi
    fi
  done
  wait "$pid" || rc=$?
  add_spend "$w" "$(call_cost "$w" "$off")"
  return "$rc"
}

# halt <worker> <pid> <reason>: stop a call's whole process group and say why.
halt() {
  [ -e "$1/stopped" ] || echo "$3" >"$1/stopped"
  kill -TERM -- "-$2" 2>/dev/null
  sleep 2
  kill -KILL -- "-$2" 2>/dev/null || true
}

cmd_run() {
  local name="${1:-}" edit=0 scratch="" public=0 via="" budget="" schema="" task note
  [ -n "$name" ] || usage
  shift
  while :; do
    case "${1:-}" in
      --edit) edit=1; shift ;;
      --scratch) scratch="${2:-}"; shift 2 || usage ;;
      --via) via="${2:-}"; shift 2 || usage ;;
      --budget) budget="${2:-}"; shift 2 || usage ;;
      --schema) schema="${2:-}"; shift 2 || usage ;;
      *) break ;;
    esac
  done
  [ -n "$via" ] || via="$(default_provider)"
  has_provider "$via" || die "unknown provider '$via' (have: $(providers | xargs))"
  task="${1:-}"
  [ -n "$task" ] || usage
  shift
  [ "${1:-}" != "--" ] || shift
  if [ -n "$budget" ]; then
    [[ "$budget" =~ ^[0-9]+(\.[0-9]+)?$ ]] && [ "$(jq -n "$budget > 0")" = true ] || die "--budget wants a positive USD amount"
  fi
  if [ -n "$budget" ] || [ -n "$(cfg '.dailyBudget // .dailySoftLimit // .dailyWarn // empty')" ]; then
    # A budget is only as good as the price it is counted in; 0 is fine for a free model.
    [ -n "$(price_of "$via")" ] || die "a budget needs a price for provider '$via' (see README)"
  fi
  ! soft_limit_hit || die "$(soft_limit_note)"
  if [ -n "$schema" ]; then
    jq -e 'type == "object"' "$schema" >/dev/null 2>&1 || die "--schema '$schema' is not a JSON object"
    task="$task$(schema_note "$schema")"
  fi

  local w repo cwd mode only
  w="$(worker_dir "$name")"
  [ ! -e "$w" ] || die "worker '$name' exists; 'drovr rm $name' first"

  if [ -n "$scratch" ]; then
    # Scratch: the worker sees only the brief you prepared, never the repo.
    [ "$edit" = 0 ] || die "--edit and --scratch are exclusive"
    [ -d "$scratch" ] || die "scratch dir '$scratch' does not exist"
    mkdir -p "$w/scratch"
    cp -r "$scratch"/. "$w/scratch"/
    cwd="$w/scratch"
    repo=-
    mode=acceptEdits
  else
    repo="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repo (or use --scratch)"
    if allowed "$repo"; then
      [ -f "$repo/DROVR.md" ] || die "$repo has no DROVR.md saying what may leave it (or use --scratch)"
    elif is_public "$repo"; then
      public=1
    else
      die "$repo is neither public nor in allowedRepos (or use --scratch)"
    fi
    only="$(repo_providers "$repo")"
    [ -z "$only" ] || [[ " $only " == *" $via "* ]] || die "$repo allows only: $only"

    # Always a worktree of your local HEAD: local commits included; ignored and
    # untracked files (.env, local data) and your uncommitted edits are not.
    mkdir -p "$w"
    cwd="$w/wt"
    if [ "$edit" = 1 ]; then
      git -C "$repo" worktree add -q -b "drovr-$name" "$cwd" HEAD || { rm -rf "$w"; die "worktree add failed"; }
      mode=acceptEdits
    else
      git -C "$repo" worktree add -q --detach "$cwd" HEAD || { rm -rf "$w"; die "worktree add failed"; }
      mode=default
    fi
  fi
  printf '%s\n' "$cwd" >"$w/cwd"
  printf '%s\n' "$repo" >"$w/repo"
  printf '%s\n' "$mode" >"$w/mode"
  printf '%s\n' "$via" >"$w/via"
  printf '%s\n' "$task" >"$w/task"
  [ -z "$budget" ] || printf '%s\n' "$budget" >"$w/budget"
  [ -z "$schema" ] || jq . "$schema" >"$w/schema.json"
  # The branch merge will go back into; empty when detached or in scratch mode.
  [ "$repo" = - ] || git -C "$repo" symbolic-ref --short -q HEAD >"$w/base" || : >"$w/base"
  launch "$cwd" "$w" "$via" "$task" --permission-mode "$mode" "$@"
  echo "drovr: $name started on $via in $cwd ($mode$([ "$public" = 0 ] || echo ", public repo"))"
  note="$(warning)"
  [ -z "$note" ] || echo "drovr: ⚠ $note" >&2
}

cmd_prompt() {
  local name="${1:-}" text="${2:-}" w sid left note
  [[ -n "$name" && -n "$text" ]] || usage
  w="$(worker_dir "$name")"
  [ -d "$w" ] || die "no worker '$name'"
  [ -e "$w/exit" ] || die "'$name' is still running; 'drovr wait $name' first"
  # From any event, so a turn that was stopped before its result can still be resumed.
  sid="$(session_of "$w")"
  [ -n "$sid" ] || die "'$name' has no session to resume (see $w/err.log)"
  left="$(budget_left "$w")"
  [ -z "$left" ] || [ "$(jq -n --argjson l "$left" '$l > 0')" = true ] || die "'$name' has no budget left"
  ! soft_limit_hit || die "$(soft_limit_note)"
  [ ! -f "$w/schema.json" ] || text="$text$(schema_note "$w/schema.json")"
  launch "$(cat "$w/cwd")" "$w" "$(cat "$w/via")" "$text" --resume "$sid" --permission-mode "$(cat "$w/mode")"
  echo "drovr: $name resumed"
  note="$(warning)"
  [ -z "$note" ] || echo "drovr: ⚠ $note" >&2
}

cmd_wait() {
  local name="${1:-}" limit="${2:-0}" w waited=0
  [ -n "$name" ] || usage
  w="$(worker_dir "$name")"
  [ -d "$w" ] || die "no worker '$name'"
  until [ -e "$w/exit" ]; do
    if [ "$limit" -gt 0 ] && [ "$waited" -ge "$limit" ]; then
      echo "drovr: $name still running after ${limit}s" >&2
      exit 124
    fi
    sleep 1
    waited=$((waited + 1))
  done
  echo "drovr: $name finished (exit $(cat "$w/exit"))"
}

cmd_read() {
  local name="" json=0 w
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1; shift ;;
      *) [ -z "$name" ] || usage; name="$1"; shift ;;
    esac
  done
  [ -n "$name" ] || usage
  w="$(worker_dir "$name")"
  [ -e "$w/exit" ] || die "'$name' has not finished"
  if [ "$json" = 1 ]; then
    [ -f "$w/schema.json" ] || die "'$name' has no schema (run it with --schema)"
    [ -f "$w/result.json" ] || die "'$name' has no valid JSON result; 'drovr read $name' says why"
    cat "$w/result.json"
    return
  fi
  # A stopped turn may still have an earlier answer; it is printed, but the exit says stopped.
  [ ! -e "$w/stopped" ] || echo "drovr: $name was stopped, $(cat "$w/stopped")" >&2
  if ! jq -e -r '.result' "$w/out.json" 2>/dev/null; then
    echo "drovr: no result; stderr follows" >&2
    cat "$w/err.log" >&2
    exit 1
  fi
  # Talking back: what the worker wanted and was refused, for you to decide on.
  jq -r '.permission_denials[]? | "drovr: denied \(.tool_name) \(.tool_input.file_path // .tool_input.path // .tool_input.pattern // "")"' \
    "$w/out.json" >&2
  if [ -e "$w/invalid" ]; then
    echo "drovr: NOT DONE: the answer's JSON fails the schema, after one repair:" >&2
    sed 's/^/drovr:   /' "$w/invalid" >&2
    exit 3
  fi
  [ ! -e "$w/stopped" ] || exit 124
}

# progress <worker>: "turn N  <last tool> <target>" for the turn in flight.
progress() {
  local w="$1" off cwd line
  off="$(cat "$w/offset" 2>/dev/null)" || off=0
  cwd="$(cat "$w/cwd" 2>/dev/null)" || cwd=""
  line="$(tail -n +"$((off + 1))" "$w/events.jsonl" 2>/dev/null | jq -rs '
    [.[] | select(.type == "assistant")] as $a
    | ([$a[].message.id] | unique | length) as $n
    | ([$a[].message.content[]? | select(.type == "tool_use")] | last) as $t
    | "turn \($n)" + (if $t then "  \($t.name) \(($t.input.file_path // $t.input.path // $t.input.pattern // "") | tostring)" else "" end)
  ' 2>/dev/null)" || line=""
  [[ "$line" != *" $cwd" ]] || line="${line%"$cwd"}."
  echo "${line//"$cwd"\//}"
}

# cost <worker>: USD so far, from the provider's price (per 1M tokens): every finished call,
# plus an estimate for the one in flight.
cost() {
  local w="$1" running=0
  [ -n "$(price_of "$(cat "$w/via" 2>/dev/null)")" ] || return 0
  [ -e "$w/exit" ] || running="$(call_cost "$w" "$(cat "$w/call_offset" 2>/dev/null || echo 0)")"
  jq -nr --argjson s "$(cat "$w/spent" 2>/dev/null || echo 0)" --argjson r "${running:-0}" \
    '"$" + (($s + $r) * 10000 | round / 10000 | tostring)'
}

cmd_list() {
  local w name status detail note
  [ -d "$state_root" ] || return 0
  for w in "$state_root"/*/; do
    [ -f "$w/cwd" ] || continue
    w="${w%/}"
    name="${w##*/}"
    if [ ! -e "$w/exit" ]; then
      status=running
      detail="$(progress "$w")"
    else
      if [ -e "$w/stopped" ]; then status="$(cut -d: -f1 "$w/stopped")"
      elif [ -e "$w/invalid" ]; then status=invalid
      elif [ "$(cat "$w/exit")" = 0 ]; then status="done"
      else status="failed($(cat "$w/exit"))"; fi
      detail="$(jq -r '"turn \(.num_turns // "?")" + (if (.permission_denials | length) > 0 then "  \(.permission_denials | length) denied" else "" end)' "$w/out.json" 2>/dev/null)" || detail=""
    fi
    printf '%-16s %-12s %-9s %-9s %s\n' "$name" "$status" "$(cat "$w/via" 2>/dev/null)" "$(cost "$w")" "$detail"
  done
  note="$(warning)"
  [ -z "$note" ] || echo "⚠ $note"
}

# status: one line for a prompt or status bar ("2▶ 1✓ 1✗"), empty when idle.
cmd_status() {
  local w run=0 ok=0 bad=0 out=()
  for w in "$state_root"/*/; do
    [ -f "$w/cwd" ] || continue
    if [ ! -e "$w/exit" ]; then run=$((run + 1))
    elif [ "$(cat "$w/exit")" = 0 ]; then ok=$((ok + 1))
    else bad=$((bad + 1)); fi
  done
  [ "$run" = 0 ] || out+=("$run▶")
  [ "$ok" = 0 ] || out+=("$ok✓")
  [ "$bad" = 0 ] || out+=("$bad✗")
  [ -z "$(warning)" ] || out+=("⚠\$$(today_usd)")
  [ "${#out[@]}" = 0 ] || echo "${out[*]}"
}

# worker_repo <name>: state dir of a finished worker that has a worktree.
worker_repo() {
  local w
  w="$(worker_dir "$1")"
  [ -d "$w" ] || die "no worker '$1'"
  [ -e "$w/exit" ] || die "'$1' is still running"
  [ -d "$w/wt" ] || die "'$1' has no worktree (scratch worker: see 'drovr path $1')"
  echo "$w"
}

cmd_diff() {
  local name="${1:-}" w
  [ -n "$name" ] || usage
  w="$(worker_repo "$name")"
  # Staging inside the worker's own worktree is harmless and shows new files too.
  git -C "$w/wt" add -A
  git -C "$w/wt" --no-pager diff --cached --stat
  git -C "$w/wt" --no-pager diff --cached
}

cmd_merge() {
  local name="" message="" w repo base current subject start
  while [ $# -gt 0 ]; do
    case "$1" in
      -m | --message) message="${2:-}"; shift 2 || usage ;;
      *) [ -z "$name" ] || usage; name="$1"; shift ;;
    esac
  done
  [ -n "$name" ] || usage
  w="$(worker_repo "$name")"
  [ "$(cat "$w/mode")" = acceptEdits ] || die "'$name' is read-only; only --edit workers can be merged"
  repo="$(cat "$w/repo")"
  base="$(cat "$w/base" 2>/dev/null)" || base=""
  [ -n "$base" ] || die "'$name' started on a detached HEAD; merge branch drovr-$name by hand"
  current="$(git -C "$repo" symbolic-ref --short -q HEAD)" || current=""
  [ "$current" = "$base" ] || die "$repo is on '${current:-detached}', '$name' started from '$base'; switch back first"

  git -C "$w/wt" add -A
  if [ -n "$message" ]; then
    # One commit with your message: everything since the worker started, including
    # commits made in its worktree during review.
    start="$(git -C "$w/wt" merge-base "$base" HEAD)"
    git -C "$w/wt" reset -q --soft "$start"
    git -C "$w/wt" diff --cached --quiet ||
      git -C "$w/wt" commit -q -m "$message" || die "commit in the worker's worktree failed"
  elif ! git -C "$w/wt" diff --cached --quiet; then
    # The task's first sentence, trimmed at a word boundary.
    subject="$(head -n1 "$w/task" 2>/dev/null | sed 's/\.[[:space:]].*$//; s/\.$//')" || subject=""
    [ "${#subject}" -le 60 ] || subject="${subject:0:60}" subject="${subject% *}…"
    git -C "$w/wt" commit -q -m "drovr $name: ${subject:-changes}" || die "commit in the worker's worktree failed"
  fi
  [ -n "$(git -C "$repo" rev-list "$base..drovr-$name")" ] || die "'$name' changed nothing; 'drovr rm $name' to drop it"

  if ! git -C "$repo" merge -q --no-edit "drovr-$name"; then
    git -C "$repo" merge --abort 2>/dev/null || true
    die "merging drovr-$name into $base failed (conflict, or your uncommitted edits touch the same files); nothing changed, worker kept"
  fi
  git -C "$repo" worktree remove "$w/wt"
  git -C "$repo" branch -q -d "drovr-$name"
  rm -rf "$w"
  echo "drovr: merged $name into $base"
}

cmd_rm() {
  local name="${1:-}" w
  [ -n "$name" ] || usage
  w="$(worker_dir "$name")"
  [ -d "$w" ] || die "no worker '$name'"
  [ -e "$w/exit" ] || die "'$name' is still running"
  if [ -d "$w/wt" ]; then
    # No --force: uncommitted worker edits stop the removal instead of vanishing.
    git -C "$(cat "$w/repo")" worktree remove "$w/wt" ||
      die "worktree has changes; commit or discard them (branch drovr-$name stays either way)"
  fi
  rm -rf "$w"
  echo "drovr: removed $name"
}

main() {
  case "${1:-}" in
    run) shift; cmd_run "$@" ;;
    prompt) shift; cmd_prompt "$@" ;;
    wait) shift; cmd_wait "$@" ;;
    read) shift; cmd_read "$@" ;;
    list) cmd_list ;;
    status) cmd_status ;;
    path) [ -n "${2:-}" ] || usage; cat "$(worker_dir "$2")/cwd" ;;
    providers) echo "$(providers | xargs) (default: $(default_provider))" ;;
    claude) shift; cmd_claude "$@" ;;
    diff) shift; cmd_diff "$@" ;;
    merge) shift; cmd_merge "$@" ;;
    rm) shift; cmd_rm "$@" ;;
    _turn) shift; cmd_turn "$@" ;;
    *) usage ;;
  esac
}

# Sourcing (tests) defines the functions without running anything.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
