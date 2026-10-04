# cw — cheap Claude Code workers on DeepSeek, run headless.
# CW_ALLOWED (newline-separated repo roots) is prepended by claude-workers.nix.

state_root="${XDG_STATE_HOME:-$HOME/.local/state}/cw"

die() { echo "cw: $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
usage: cw run <name> [--edit] <task> [-- <claude args>...]
       cw prompt <name> <text>      follow-up turn in the same session
       cw wait <name> [seconds]     block until the turn ends (default: no limit)
       cw read <name>               print the worker's final answer
       cw list
       cw rm <name>                 drop the worker (and its worktree, if clean)
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
  done <<<"$CW_ALLOWED"
  return 1
}

# launch <dir> <worker-state> <claude args...>: one headless turn, detached so it
# outlives the calling shell (Claude's Bash tool reaps its children).
launch() {
  local cwd="$1" w="$2"
  shift 2
  rm -f "$w/exit"
  # shellcheck disable=SC2016 # expanded by the inner bash, on purpose
  setsid -f bash -c '
    cd "$1" || exit 1
    w="$2"; shift 2
    env -u WEZTERM_PANE claude-ds -p "$@" --output-format json >"$w/out.json" 2>"$w/err.log"
    echo $? >"$w/exit"
  ' cw-worker "$cwd" "$w" "$@"
}

cmd_run() {
  local name="${1:-}" edit=0 task
  [ -n "$name" ] || usage
  shift
  if [ "${1:-}" = "--edit" ]; then edit=1; shift; fi
  task="${1:-}"
  [ -n "$task" ] || usage
  shift
  [ "${1:-}" != "--" ] || shift

  local w repo cwd mode
  w="$(worker_dir "$name")"
  [ ! -e "$w" ] || die "worker '$name' exists; 'cw rm $name' first"
  repo="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repo"
  allowed "$repo" || die "$repo is not in my.claude.workers.allowedRepos"

  mkdir -p "$w"
  if [ "$edit" = 1 ]; then
    # Own worktree: a worker never edits the checkout you (or another session) work in.
    cwd="$w/wt"
    git -C "$repo" worktree add -q -b "cw/$name" "$cwd" || { rm -rf "$w"; die "worktree add failed"; }
    mode=acceptEdits
  else
    cwd="$PWD"
    mode=default
  fi
  printf '%s\n' "$cwd" >"$w/cwd"
  printf '%s\n' "$repo" >"$w/repo"
  printf '%s\n' "$mode" >"$w/mode"
  launch "$cwd" "$w" "$task" --permission-mode "$mode" "$@"
  echo "cw: $name started in $cwd ($mode)"
}

cmd_prompt() {
  local name="${1:-}" text="${2:-}" w sid
  [ -n "$name" ] && [ -n "$text" ] || usage
  w="$(worker_dir "$name")"
  [ -d "$w" ] || die "no worker '$name'"
  [ -e "$w/exit" ] || die "'$name' is still running; 'cw wait $name' first"
  sid="$(jq -r '.session_id // empty' "$w/out.json" 2>/dev/null)"
  [ -n "$sid" ] || die "'$name' has no session to resume (see $w/err.log)"
  launch "$(cat "$w/cwd")" "$w" "$text" --resume "$sid" --permission-mode "$(cat "$w/mode")"
  echo "cw: $name resumed"
}

cmd_wait() {
  local name="${1:-}" limit="${2:-0}" w waited=0
  [ -n "$name" ] || usage
  w="$(worker_dir "$name")"
  [ -d "$w" ] || die "no worker '$name'"
  until [ -e "$w/exit" ]; do
    if [ "$limit" -gt 0 ] && [ "$waited" -ge "$limit" ]; then
      echo "cw: $name still running after ${limit}s" >&2
      exit 124
    fi
    sleep 1
    waited=$((waited + 1))
  done
  echo "cw: $name finished (exit $(cat "$w/exit"))"
}

cmd_read() {
  local name="${1:-}" w
  [ -n "$name" ] || usage
  w="$(worker_dir "$name")"
  [ -e "$w/exit" ] || die "'$name' has not finished"
  if ! jq -e -r '.result' "$w/out.json" 2>/dev/null; then
    echo "cw: no result; stderr follows" >&2
    cat "$w/err.log" >&2
    exit 1
  fi
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
    printf '%-20s %-12s %s\n' "$name" "$status" "$(cat "$w/cwd" 2>/dev/null)"
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
      die "worktree has changes; commit or discard them (branch cw/$name stays either way)"
  fi
  rm -rf "$w"
  echo "cw: removed $name"
}

case "${1:-}" in
  run) shift; cmd_run "$@" ;;
  prompt) shift; cmd_prompt "$@" ;;
  wait) shift; cmd_wait "$@" ;;
  read) shift; cmd_read "$@" ;;
  list) cmd_list ;;
  rm) shift; cmd_rm "$@" ;;
  *) usage ;;
esac
