# drovr — hand tasks to headless Claude Code workers on Anthropic-compatible backends.
# DROVR_ALLOWED, DROVR_PROVIDERS and DROVR_DEFAULT are prepended by drovr.nix.

state_root="${XDG_STATE_HOME:-$HOME/.local/state}/drovr"
# One Claude config for every worker and provider: none of your settings, MCP servers,
# CLAUDE.md or memory reach a worker, and its transcripts stay out of claude-sync.
worker_config="${XDG_STATE_HOME:-$HOME/.local/state}/drovr-claude"

# --restricted confines the file tools to the worker's directory and drops every
# command-running tool; five tools also cut the prompt from ~17.5k to ~3.1k tokens.
worker_flags=(--restricted --strict-mcp-config --tools "Read,Grep,Glob,Edit,Write")

die() { echo "drovr: $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
usage: drovr run <name> [--edit | --scratch <dir>] [--via <provider>] <task> [-- <claude args>...]
       drovr prompt <name> <text>      follow-up turn in the same session
       drovr wait <name> [seconds]     block until the turn ends (default: no limit)
       drovr read <name>               print the worker's final answer
       drovr path <name>               the worker's working directory
       drovr list
       drovr providers
       drovr rm <name>                 drop the worker (and its worktree, if clean)
EOF
  exit 2
}

worker_dir() {
  [[ "$1" =~ ^[a-z][a-z0-9-]{0,31}$ ]] || die "bad name '$1' (a-z, 0-9, -)"
  echo "$state_root/$1"
}

allowed() {
  local repo="$1" root
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    root="${root%/}"
    [[ "$repo" == "$root" || "$repo" == "$root"/* ]] && return 0
  done <<<"$DROVR_ALLOWED"
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

# launch <dir> <worker-state> <provider> <claude args...>: one headless turn, detached so it
# outlives the calling shell (Claude's Bash tool reaps its children).
launch() {
  local cwd="$1" w="$2" via="$3"
  shift 3
  rm -f "$w/exit"
  mkdir -p "$worker_config"
  # shellcheck disable=SC2016 # expanded by the inner bash, on purpose
  DROVR_CONFIG="$worker_config" setsid -f bash -c '
    cd "$1" || exit 1
    w="$2"; via="$3"; shift 3
    env -u WEZTERM_PANE CLAUDE_CONFIG_DIR="$DROVR_CONFIG" "claude-$via" -p "$@" --output-format json >"$w/out.json" 2>"$w/err.log"
    echo $? >"$w/exit"
  ' drovr-worker "$cwd" "$w" "$via" "$@" "${worker_flags[@]}"
}

cmd_run() {
  local name="${1:-}" edit=0 scratch="" public=0 via="$DROVR_DEFAULT" task
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
  [[ " $DROVR_PROVIDERS " == *" $via "* ]] || die "unknown provider '$via' (have: $DROVR_PROVIDERS)"
  task="${1:-}"
  [ -n "$task" ] || usage
  shift
  [ "${1:-}" != "--" ] || shift

  local w repo cwd mode
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
      die "$repo is neither public nor in my.claude.drovr.allowedRepos (or use --scratch)"
    fi
    local only
    only="$(repo_providers "$repo")"
    [ -z "$only" ] || [[ " $only " == *" $via "* ]] || die "$repo allows only: $only"
  fi

  mkdir -p "$w"
  if [ -n "$scratch" ]; then
    :
  else
    # Always a worktree of your local HEAD: local commits included; ignored and
    # untracked files (.env, local data) and your uncommitted edits are not.
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
  [ -n "$name" ] && [ -n "$text" ] || usage
  w="$(worker_dir "$name")"
  [ -d "$w" ] || die "no worker '$name'"
  [ -e "$w/exit" ] || die "'$name' is still running; 'drovr wait $name' first"
  sid="$(jq -r '.session_id // empty' "$w/out.json" 2>/dev/null)"
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

cmd_list() {
  local w name status
  [ -d "$state_root" ] || return 0
  for w in "$state_root"/*/; do
    [ -d "$w" ] || continue
    w="${w%/}"
    name="${w##*/}"
    if [ ! -e "$w/exit" ]; then
      status=running
    elif [ "$(cat "$w/exit")" = 0 ]; then
      status="done"
    else
      status="failed($(cat "$w/exit"))"
    fi
    printf '%-20s %-12s %-10s %s\n' "$name" "$status" "$(cat "$w/via" 2>/dev/null)" "$(cat "$w/cwd" 2>/dev/null)"
  done
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

case "${1:-}" in
  run) shift; cmd_run "$@" ;;
  prompt) shift; cmd_prompt "$@" ;;
  wait) shift; cmd_wait "$@" ;;
  read) shift; cmd_read "$@" ;;
  list) cmd_list ;;
  path) [ -n "${2:-}" ] || usage; cat "$(worker_dir "$2")/cwd" ;;
  providers) echo "$DROVR_PROVIDERS (default: $DROVR_DEFAULT)" ;;
  rm) shift; cmd_rm "$@" ;;
  *) usage ;;
esac
