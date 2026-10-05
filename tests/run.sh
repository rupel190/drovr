#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016 # `check && ok || no` is safe (ok never fails); '$6.2' is a literal
# drovr tests: a stub stands in for Claude Code, so nothing reaches a provider.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
drovr="$here/../drovr.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home" XDG_STATE_HOME="$tmp/state" XDG_CONFIG_HOME="$tmp/config"
export STUB_LOG="$tmp/stub.log" WEZTERM_PANE=7
mkdir -p "$HOME" "$XDG_CONFIG_HOME/drovr"
echo "sk-test-key" >"$tmp/key"

git_repo() { # git_repo <dir>: a repo with one commit
  mkdir -p "$1" && git -C "$1" init -q && echo a >"$1/a.txt" &&
    git -C "$1" add -A && git -C "$1" -c user.name=t -c user.email=t@t commit -qm init
}
git_repo "$tmp/priv"
git_repo "$tmp/other"
mkdir -p "$tmp/brief" && echo brief >"$tmp/brief/a.txt"

cat >"$XDG_CONFIG_HOME/drovr/config.json" <<EOF
{
  "claude": "$here/stub-claude",
  "defaultProvider": "deep",
  "allowedRepos": ["$tmp/priv"],
  "providers": {
    "deep": { "baseUrl": "https://deep.example/anthropic", "model": "deep-pro", "keyFile": "$tmp/key",
              "price": { "input": 1, "cachedInput": 0.1, "output": 2 } },
    "alt":  { "baseUrl": "https://alt.example", "model": "alt-1", "keyFile": "$tmp/key", "authVar": "ANTHROPIC_API_KEY" },
    "nokey": { "baseUrl": "https://x.example", "model": "x", "keyFile": "$tmp/missing" }
  }
}
EOF

pass=0 fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
no() { fail=$((fail + 1)); echo "FAIL $1"; [ -z "${2:-}" ] || echo "     $2"; }
expect() { # expect <name> <pattern> <command...>: output (stdout+stderr) matches pattern
  local name="$1" pat="$2" out
  shift 2
  out="$("$@" 2>&1)"
  if [[ "$out" == *$pat* ]]; then ok "$name"; else no "$name" "got: ${out//$'\n'/ | }"; fi
}
d() { bash "$drovr" "$@"; }
in_dir() { (cd "$1" && shift && "$@"); }

# config and providers
expect "providers lists all, default first-class" "alt deep nokey (default: deep)" d providers
expect "unknown provider is refused" "unknown provider 'zzz'" in_dir "$tmp/brief" d run x --scratch "$tmp/brief" --via zzz "t"
expect "missing config is reported" "no config at" env DROVR_CONFIG="$tmp/none.json" bash "$drovr" providers
expect "bad worker name is refused" "bad name" in_dir "$tmp/brief" d run Bad --scratch "$tmp/brief" "t"

# repo gate
expect "outside git is refused" "not inside a git repo" in_dir "$tmp/brief" d run x "t"
expect "private, not allowlisted, is refused" "neither public nor in allowedRepos" in_dir "$tmp/other" d run x "t"
expect "allowlisted without DROVR.md is refused" "has no DROVR.md" in_dir "$tmp/priv" d run x "t"
printf 'providers: alt\n' >"$tmp/priv/DROVR.md"
git -C "$tmp/priv" add -A && git -C "$tmp/priv" -c user.name=t -c user.email=t@t commit -qm drovr
expect "DROVR.md provider limit applies" "allows only: alt" in_dir "$tmp/priv" d run x "t"

# repo mode: worktree of HEAD, without untracked files
echo "SECRET=1" >"$tmp/priv/.env"
expect "allowlisted repo starts" "started on alt" in_dir "$tmp/priv" d run rr --via alt "deny something"
d wait rr 20 >/dev/null
wt="$(d path rr)"
[ -f "$wt/a.txt" ] && [ ! -e "$wt/.env" ] && ok "worktree has committed files, not untracked .env" || no "worktree contents" "$(ls -A "$wt")"
expect "read returns the answer" "answer to: deny something" d read rr
expect "read reports denials" "drovr: denied Read /etc/shadow" d read rr
grep -q "apikey=sk-test-key" "$STUB_LOG" && ok "authVar ANTHROPIC_API_KEY carries the key" || no "authVar"

# scratch mode: flags, environment, isolation
: >"$STUB_LOG"
expect "scratch starts anywhere" "started on deep" in_dir "$tmp/other" d run sc --scratch "$tmp/brief" "hello"
d wait sc 20 >/dev/null
log="$(cat "$STUB_LOG")"
[[ "$log" == *"--restricted"* && "$log" == *"--strict-mcp-config"* && "$log" == *"Read\\,Grep\\,Glob\\,Edit\\,Write"* ]] &&
  ok "restricted flags and five tools passed" || no "worker flags" "$log"
[[ "$log" == *"--permission-mode acceptEdits"* ]] && ok "scratch runs acceptEdits" || no "scratch mode"
[[ "$log" == *"pane=unset"* ]] && ok "WEZTERM_PANE removed" || no "WEZTERM_PANE" "$log"
[[ "$log" == *"config=$XDG_STATE_HOME/drovr-claude"* ]] && ok "isolated CLAUDE_CONFIG_DIR" || no "config dir" "$log"
[[ "$log" == *"base=https://deep.example/anthropic model=deep-pro token=sk-test-key"* ]] && ok "provider env and key" || no "provider env" "$log"
[[ "$log" == *"worker=1 retries=3"* ]] && ok "worker marker and retry cap" || no "worker env" "$log"
[[ "$log" == *"cwd=$XDG_STATE_HOME/drovr/sc/scratch"* ]] && ok "scratch runs in its copy" || no "scratch cwd" "$log"
[[ "$log" != *"sk-test-key "*"argv"* ]] && ! grep -q "argv:.*sk-test-key" "$STUB_LOG" && ok "key never on the command line" || no "key in argv"

# follow-up, list, cost, status
expect "prompt resumes the session" "resumed" d prompt sc "again"
d wait sc 20 >/dev/null
grep -q -- "--resume sid-new" "$STUB_LOG" && ok "resume passes the session id" || no "resume id"
# two turns x (1M in x 1 + 1M cached x 0.1 + 1M out x 2) = 6.2
expect "list shows cost over both turns" '$6.2' d list
expect "list shows turns" "turn 2" d list
expect "status counts" "2✓" d status

# edit mode and rm
expect "edit mode starts" "acceptEdits" in_dir "$tmp/priv" d run ed --edit --via alt "edit"
d wait ed 20 >/dev/null
git -C "$tmp/priv" rev-parse -q --verify drovr-ed >/dev/null && ok "edit worktree on branch drovr-ed" || no "edit branch"
echo dirty >"$(d path ed)/new.txt"
expect "rm refuses a dirty worktree" "worktree has changes" d rm ed
rm "$(d path ed)/new.txt"
expect "rm removes a clean one" "removed ed" d rm ed

# running worker: progress and status
STUB_SLEEP=3 d run slow --scratch "$tmp/brief" "slow" >/dev/null
expect "status shows running" "1▶" d status
d wait slow 20 >/dev/null

# claude subcommand
expect "missing key file is reported" "key file $tmp/missing not readable" d claude nokey -p hi

# url normalisation (functions only)
# shellcheck source=/dev/null
source "$drovr"
set +eu # drovr's strict mode came along with the functions
for case in "git@github.com:o/r.git|https://github.com/o/r.git" "ssh://git@host.org/o/r|https://host.org/o/r" \
            "https://user@gitlab.com/o/r|https://gitlab.com/o/r" "https://github.com/o/r|https://github.com/o/r"; do
  git -C "$tmp/other" remote remove origin 2>/dev/null; git -C "$tmp/other" remote add origin "${case%%|*}"
  got="$(public_url "$tmp/other")"
  [ "$got" = "${case#*|}" ] && ok "public_url ${case%%|*}" || no "public_url ${case%%|*}" "got $got"
done

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
