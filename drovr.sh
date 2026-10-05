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
usage: drovr run <name> [--edit | --scratch <dir>] [--via <provider>] <task> [-- <claude args>...]
       drovr prompt <name> <text>      follow-up turn in the same session
       drovr wait <name> [seconds]     block until the turn ends (default: no limit)
       drovr read <name>               print the worker's final answer
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
  rm -f "$w/exit"
  mkdir -p "$worker_config"
  # Each turn appends to events.jsonl; progress reads from this offset on.
  touch "$w/events.jsonl"
  wc -l <"$w/events.jsonl" >"$w/offset"
  # shellcheck disable=SC2016 # expanded by the inner bash, on purpose
  DROVR_WORKER_CONFIG="$worker_config" setsid -f bash -c '
    cd "$1" || exit 1
    self="$2"; w="$3"; via="$4"; shift 4
    env -u WEZTERM_PANE CLAUDE_CONFIG_DIR="$DROVR_WORKER_CONFIG" "$self" claude "$via" -p "$@" \
      --output-format stream-json --verbose >>"$w/events.jsonl" 2>"$w/err.log"
    rc=$?
    # The turn'"'"'s final result event, in the shape `read` and `prompt` expect.
    jq -c "select(.type == \"result\")" "$w/events.jsonl" 2>/dev/null | tail -n1 >"$w/out.json"
    echo $rc >"$w/exit"
  ' drovr-worker "$cwd" "$self" "$w" "$via" "$@" "${worker_flags[@]}"
}

cmd_run() {
  local name="${1:-}" edit=0 scratch="" public=0 via="" task
  [ -n "$name" ] || usage
  shift
  while :; do
    case "${1:-}" in
      --edit) edit=1; shift ;;
      --scratch) scratch="${2:-}"; shift 2 || usage ;;
      --via) via="${2:-}"; shift 2 || usage ;;
      *) break ;;
    esac
  done
  [ -n "$via" ] || via="$(default_provider)"
  has_provider "$via" || die "unknown provider '$via' (have: $(providers | xargs))"
  task="${1:-}"
  [ -n "$task" ] || usage
  shift
  [ "${1:-}" != "--" ] || shift

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
  launch "$cwd" "$w" "$via" "$task" --permission-mode "$mode" "$@"
  echo "drovr: $name started on $via in $cwd ($mode$([ "$public" = 0 ] || echo ", public repo"))"
}

cmd_prompt() {
  local name="${1:-}" text="${2:-}" w sid
  [[ -n "$name" && -n "$text" ]] || usage
  w="$(worker_dir "$name")"
  [ -d "$w" ] || die "no worker '$name'"
  [ -e "$w/exit" ] || die "'$name' is still running; 'drovr wait $name' first"
  sid="$(jq -r '.session_id // empty' "$w/out.json" 2>/dev/null)" || sid=""
  [ -n "$sid" ] || die "'$name' has no session to resume (see $w/err.log)"
  launch "$(cat "$w/cwd")" "$w" "$(cat "$w/via")" "$text" --resume "$sid" --permission-mode "$(cat "$w/mode")"
  echo "drovr: $name resumed"
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
  local name="${1:-}" w
  [ -n "$name" ] || usage
  w="$(worker_dir "$name")"
  [ -e "$w/exit" ] || die "'$name' has not finished"
  if ! jq -e -r '.result' "$w/out.json" 2>/dev/null; then
    echo "drovr: no result; stderr follows" >&2
    cat "$w/err.log" >&2
    exit 1
  fi
  # Talking back: what the worker wanted and was refused, for you to decide on.
  jq -r '.permission_denials[]? | "drovr: denied \(.tool_name) \(.tool_input.file_path // .tool_input.path // .tool_input.pattern // "")"' \
    "$w/out.json" >&2
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

# cost <worker>: USD over every finished turn, from the provider's price (per 1M tokens).
cost() {
  local w="$1" price
  price="$(cfg --arg p "$(cat "$w/via" 2>/dev/null)" '.providers[$p].price // empty | tojson' 2>/dev/null)" || return 0
  [ -n "$price" ] || return 0
  jq -rs --argjson p "$price" '
    [.[] | select(.type == "result") | .usage // {}] as $u
    | if ($u | length) == 0 then empty else
      ($u | map(((.input_tokens // 0) + (.cache_creation_input_tokens // 0)) * ($p.input // 0)
               + (.cache_read_input_tokens // 0) * ($p.cachedInput // $p.input // 0)
               + (.output_tokens // 0) * ($p.output // 0)) | add / 1e6)
      | "$" + (. * 10000 | round / 10000 | tostring) end
  ' "$w/events.jsonl" 2>/dev/null || true
}

cmd_list() {
  local w name status detail
  [ -d "$state_root" ] || return 0
  for w in "$state_root"/*/; do
    [ -f "$w/cwd" ] || continue
    w="${w%/}"
    name="${w##*/}"
    if [ ! -e "$w/exit" ]; then
      status=running
      detail="$(progress "$w")"
    else
      if [ "$(cat "$w/exit")" = 0 ]; then status="done"; else status="failed($(cat "$w/exit"))"; fi
      detail="$(jq -r '"turn \(.num_turns // "?")" + (if (.permission_denials | length) > 0 then "  \(.permission_denials | length) denied" else "" end)' "$w/out.json" 2>/dev/null)" || detail=""
    fi
    printf '%-16s %-10s %-9s %-9s %s\n' "$name" "$status" "$(cat "$w/via" 2>/dev/null)" "$(cost "$w")" "$detail"
  done
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
  [ "${#out[@]}" = 0 ] || echo "${out[*]}"
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
    rm) shift; cmd_rm "$@" ;;
    *) usage ;;
  esac
}

# Sourcing (tests) defines the functions without running anything.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
