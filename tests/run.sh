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
    git -C "$1" config user.name t && git -C "$1" config user.email t@t &&
    git -C "$1" add -A && git -C "$1" -c user.name=t -c user.email=t@t commit -qm init
}
git_repo "$tmp/priv"
git_repo "$tmp/other"
mkdir -p "$tmp/brief" && echo brief >"$tmp/brief/a.txt"

cat >"$XDG_CONFIG_HOME/drovr/config.json" <<EOF
{
  "claude": "$here/stub-claude",
  "defaultProvider": "deep",
  "stallSeconds": 5,
  "allowedRepos": ["$tmp/priv"],
  "providers": {
    "deep": { "baseUrl": "https://deep.example/anthropic", "model": "deep-pro", "keyFile": "$tmp/key",
              "price": { "input": 1, "cachedInput": 0.1, "output": 2 }, "effort": "medium",
              "models": { "deep-flash": { "price": { "input": 0.5, "output": 1 }, "effort": "low" } } },
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

# models and effort: per-model price and default effort, kept across follow-ups
expect "models lists the provider's model with its defaults" "deep-pro*\$1/\$2*medium*(default)" d models
expect "and the extra model with its own" "deep-flash*\$0.5/\$1*low" d models
grep -q -- "--model deep-pro --effort medium" "$STUB_LOG" && ok "default run passes the provider's model and effort" || no "default model flags"
: >"$STUB_LOG"
expect "run names model and effort" "deep-flash at low effort" in_dir "$tmp/brief" d run fl --scratch "$tmp/brief" --model deep-flash "t"
d wait fl 20 >/dev/null
grep -q -- "--model deep-flash --effort low" "$STUB_LOG" && ok "model's own default effort" || no "flash flags" "$(cat "$STUB_LOG")"
# 1M in x 0.5 + 1M cached x 0.5 (no cachedInput: charged as input) + 1M out x 1 = 2
expect "cost uses the model's price, not the provider's" "deep-flash low*\$2 " d list
grep -q '"model":"deep-flash","effort":"low"' "$XDG_STATE_HOME/drovr/spend.jsonl" && ok "ledger records model and effort" || no "ledger model"
: >"$STUB_LOG"
d prompt fl "more" >/dev/null
d wait fl 20 >/dev/null
grep -q -- "--resume sid-new.*--model deep-flash --effort low" "$STUB_LOG" && ok "follow-up keeps model and effort" || no "follow-up flags" "$(cat "$STUB_LOG")"
: >"$STUB_LOG"
in_dir "$tmp/brief" d run fx --scratch "$tmp/brief" --model deep-flash --effort max "t" >/dev/null
d wait fx 20 >/dev/null
grep -q -- "--model deep-flash --effort max" "$STUB_LOG" && ok "--effort overrides the default" || no "effort override"
expect "bad effort is refused" "wants one of: low medium high xhigh max" in_dir "$tmp/brief" d run fb --scratch "$tmp/brief" --effort huge "t"
expect "unpriced model cannot carry a budget" "needs a price for model 'zzz-1' on provider 'deep'" in_dir "$tmp/brief" d run fz --scratch "$tmp/brief" --model zzz-1 --budget 1 "t"
expect "unpriced model runs, with a note" "no price for zzz-1 on deep" in_dir "$tmp/brief" d run fu --scratch "$tmp/brief" --model zzz-1 "t"
d wait fu 20 >/dev/null
expect "passthrough --model is refused" "use drovr's own --model" in_dir "$tmp/brief" d run fp --scratch "$tmp/brief" "t" -- --model=x
expect "passthrough --effort is refused" "use drovr's own --effort" in_dir "$tmp/brief" d run fp --scratch "$tmp/brief" "t" -- --effort low

# edit mode and rm
expect "edit mode starts" "acceptEdits" in_dir "$tmp/priv" d run ed --edit --via alt "edit"
d wait ed 20 >/dev/null
git -C "$tmp/priv" rev-parse -q --verify drovr-ed >/dev/null && ok "edit worktree on branch drovr-ed" || no "edit branch"
echo dirty >"$(d path ed)/new.txt"
expect "rm refuses a dirty worktree" "worktree has changes" d rm ed
rm "$(d path ed)/new.txt"
expect "rm removes a clean one" "removed ed" d rm ed

# diff and merge
base="$(git -C "$tmp/priv" symbolic-ref --short HEAD)"
in_dir "$tmp/priv" d run mw --edit --via alt "write a file. Then say what you did." >/dev/null
d wait mw 20 >/dev/null
expect "diff shows the worker's new file" "worker.txt" d diff mw
git -C "$tmp/priv" checkout -q -b elsewhere
expect "merge refuses when the repo moved to another branch" "switch back first" d merge mw
git -C "$tmp/priv" checkout -q "$base"
expect "merge succeeds" "merged mw into $base" d merge mw
[ -f "$tmp/priv/worker.txt" ] && git -C "$tmp/priv" log --oneline -1 "$base" -- worker.txt | grep -qx "[0-9a-f]* drovr mw: write a file" &&
  ok "worker's file is committed and merged" || no "merged content"
! git -C "$tmp/priv" rev-parse -q --verify drovr-mw >/dev/null && [ ! -e "$XDG_STATE_HOME/drovr/mw" ] &&
  ok "branch and worker are gone after merge" || no "merge cleanup"

in_dir "$tmp/priv" d run mm --edit --via alt "write another" >/dev/null
d wait mm 20 >/dev/null
echo "review fix" >>"$(d path mm)/worker.txt"
git -C "$(d path mm)" add -A && git -C "$(d path mm)" commit -qm "review fix"
expect "merge -m succeeds" "merged mm into $base" d merge mm -m $'feat: a proper subject\n\nWith a body.'
[ "$(git -C "$tmp/priv" log -1 --format=%s "$base")" = "feat: a proper subject" ] &&
  [ "$(git -C "$tmp/priv" log -1 --format=%b "$base")" = "With a body." ] &&
  ! git -C "$tmp/priv" log --format=%s "$base" | grep -q "review fix" &&
  ok "merge -m squashes worker and review commits into one with the message" || no "merge -m result" "$(git -C "$tmp/priv" log --oneline -3 "$base")"

in_dir "$tmp/priv" d run cw --edit --via alt "conflict on a" >/dev/null
d wait cw 20 >/dev/null
echo "repo version" >"$tmp/priv/a.txt" && git -C "$tmp/priv" -c user.name=t -c user.email=t@t commit -qam "repo edit"
head_before="$(git -C "$tmp/priv" rev-parse HEAD)"
expect "conflicting merge is aborted" "nothing changed, worker kept" d merge cw
[ "$(git -C "$tmp/priv" rev-parse HEAD)" = "$head_before" ] && ! git -C "$tmp/priv" rev-parse -q --verify MERGE_HEAD >/dev/null &&
  [ "$(cat "$tmp/priv/a.txt")" = "repo version" ] && [ -d "$XDG_STATE_HOME/drovr/cw" ] &&
  ok "repo untouched and worker kept after a conflict" || no "conflict state"

in_dir "$tmp/priv" d run nc --edit --via alt "look only" >/dev/null
d wait nc 20 >/dev/null
expect "merge with no changes is refused" "changed nothing" d merge nc
expect "read-only worker cannot be merged" "only --edit workers" d merge rr
expect "scratch worker has no diff" "has no worktree" d diff sc

grep -q "token=sk-test-key apikey=$" "$STUB_LOG" && ok "ANTHROPIC_API_KEY blanked next to the token" || no "api key blanking"

# running worker: progress and status
STUB_SLEEP=3 d run slow --scratch "$tmp/brief" "slow" >/dev/null
expect "status shows running" "1▶" d status
d wait slow 20 >/dev/null

# stall: a silent worker is stopped, not waited on forever
d run hg --scratch "$tmp/brief" "hang" >/dev/null
d wait hg 30 >/dev/null
[ "$(cat "$XDG_STATE_HOME/drovr/hg/exit")" = 124 ] && ok "silent worker is stopped (exit 124)" || no "stall exit"
expect "list says stalled" "stalled" d list
expect "read says why it stopped" "stalled: no output for 5s" d read hg
pgrep -f "sleep 60" >/dev/null && no "stalled worker's process group is gone" || ok "stalled worker's process group is gone"

# budget: one wallet per worker, plus a daily one, both only shrinking
expect "budget must be a number" "positive USD" in_dir "$tmp/brief" d run b0 --scratch "$tmp/brief" --budget abc "t"
expect "budget needs a price" "needs a price for model 'alt-1' on provider 'alt'" in_dir "$tmp/brief" d run b1 --scratch "$tmp/brief" --via alt --budget 1 "t"
d run bg --scratch "$tmp/brief" --budget 1 "spend" >/dev/null
d wait bg 30 >/dev/null
[ "$(cat "$XDG_STATE_HOME/drovr/bg/exit")" = 124 ] && ok "worker past its budget is stopped" || no "budget exit"
expect "list says over-budget" "over-budget" d list
expect "read names the cap" 'spent past the $1 left' d read bg
expect "no follow-up once the budget is gone" "has no budget left" d prompt bg "more"
jq '.dailyBudget = 1' "$XDG_CONFIG_HOME/drovr/config.json" >"$tmp/daily.json"
DROVR_CONFIG="$tmp/daily.json" bash "$drovr" run dy --scratch "$tmp/brief" "t" >/dev/null
DROVR_CONFIG="$tmp/daily.json" bash "$drovr" wait dy 20 >/dev/null
expect "today's spend already exceeds dailyBudget" "no-budget" env DROVR_CONFIG="$tmp/daily.json" bash "$drovr" list
expect "dailyBudget needs a price too" "needs a price" in_dir "$tmp/brief" env DROVR_CONFIG="$tmp/daily.json" bash "$drovr" run d2 --scratch "$tmp/brief" --via alt "t"

# dailyWarn and dailySoftLimit: a warning, then no new calls, never a cut-off call
jq '.dailyWarn = 1 | .dailySoftLimit = 1000' "$XDG_CONFIG_HOME/drovr/config.json" >"$tmp/warn.json"
expect "past dailyWarn, run warns" "⚠ today's drovr spend is" in_dir "$tmp/brief" env DROVR_CONFIG="$tmp/warn.json" bash "$drovr" run wn --scratch "$tmp/brief" "t"
DROVR_CONFIG="$tmp/warn.json" bash "$drovr" wait wn 20 >/dev/null
expect "status shows the warning" '⚠$' env DROVR_CONFIG="$tmp/warn.json" bash "$drovr" status
expect "list shows the warning" "(warning at \$1)" env DROVR_CONFIG="$tmp/warn.json" bash "$drovr" list
grep -q "^$(date +%F) [0-9.]*$" "$XDG_STATE_HOME/drovr/warning" && ok "status-bar file carries day and spend" || no "warning file"
jq '.dailySoftLimit = 1' "$XDG_CONFIG_HOME/drovr/config.json" >"$tmp/soft.json"
expect "past dailySoftLimit, run is refused" "reached dailySoftLimit \$1" in_dir "$tmp/brief" env DROVR_CONFIG="$tmp/soft.json" bash "$drovr" run sl --scratch "$tmp/brief" "t"
expect "and so is a follow-up" "reached dailySoftLimit" env DROVR_CONFIG="$tmp/soft.json" bash "$drovr" prompt wn "more"
expect "soft limit needs a price" "needs a price" in_dir "$tmp/brief" env DROVR_CONFIG="$tmp/soft.json" bash "$drovr" run sp --scratch "$tmp/brief" --via alt "t"

# nudge: an answer that announces an action gets one "continue"
: >"$STUB_LOG"
d run an --scratch "$tmp/brief" "announce" >/dev/null
d wait an 20 >/dev/null
[ "$(grep -c '^argv:' "$STUB_LOG")" = 2 ] && grep -q "Continue:" "$STUB_LOG" &&
  ok "announced action gets exactly one nudge" || no "nudge" "$(grep -c '^argv:' "$STUB_LOG") calls"
expect "the nudge's answer is the one read" "answer to: Continue" d read an
expect "both calls are counted" '$6.2' d list
jq '.nudge = false' "$XDG_CONFIG_HOME/drovr/config.json" >"$tmp/nonudge.json"
: >"$STUB_LOG"
DROVR_CONFIG="$tmp/nonudge.json" bash "$drovr" run an2 --scratch "$tmp/brief" "announce" >/dev/null
DROVR_CONFIG="$tmp/nonudge.json" bash "$drovr" wait an2 20 >/dev/null
[ "$(grep -c "^argv:" "$STUB_LOG")" = 1 ] && ok "nudge: false turns it off" || no "nudge off" "$(grep -c "^argv:" "$STUB_LOG") calls; $(cat "$XDG_STATE_HOME/drovr/an2/err.log")"

# schema: validated answer, one repair, otherwise not done
cat >"$tmp/schema.json" <<'EOF'
{ "type": "object", "required": ["done", "files"], "additionalProperties": false,
  "properties": { "done": { "type": "boolean" }, "files": { "type": "array", "items": { "type": "string" } } } }
EOF
expect "schema must be a JSON object" "not a JSON object" in_dir "$tmp/brief" d run s0 --scratch "$tmp/brief" --schema "$tmp/brief/a.txt" "t"
: >"$STUB_LOG"
d run sg --scratch "$tmp/brief" --schema "$tmp/schema.json" "json-good" >/dev/null
d wait sg 20 >/dev/null
grep -q "matches this JSON Schema" "$STUB_LOG" && ok "task carries the schema" || no "schema in task"
expect "read --json gives the checked object" '"done": true' d read sg --json
d run sb --scratch "$tmp/brief" --schema "$tmp/schema.json" "json-bad" >/dev/null
d wait sb 20 >/dev/null
grep -q -- '- $.done: expected boolean, got string' "$STUB_LOG" && ok "repair prompt quotes the validator" || no "repair prompt"
expect "repaired answer passes" '"done": false' d read sb --json
STUB_UNFIXABLE=1 d run su --scratch "$tmp/brief" --schema "$tmp/schema.json" "json-bad" >/dev/null
d wait su 20 >/dev/null
expect "still invalid after one repair is NOT DONE" 'NOT DONE' d read su
d read su >/dev/null 2>&1; [ $? = 3 ] && ok "read exits 3 when invalid" || no "invalid exit"
expect "errors are listed" 'missing "done"' d read su
expect "read --json refuses" "no valid JSON result" d read su --json
expect "list says invalid" "invalid" d list
: >"$STUB_LOG"
d prompt sg "again"
d wait sg 20 >/dev/null
grep -q "matches this JSON Schema" "$STUB_LOG" && ok "follow-up carries the schema too" || no "schema on prompt"

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

# schema checker (function only)
# shellcheck disable=SC2154 # schema_jq comes from the sourced drovr.sh
sc() { jq -Rs --argjson schema "$1" "$schema_jq" <<<"$2" | jq -c .errors; }
[ "$(sc '{"type":"integer"}' '3')" = '[]' ] && [ "$(sc '{"type":"integer"}' '3.5')" != '[]' ] &&
  ok "integer is a whole number" || no "integer"
[ "$(sc '{"enum":["a","b"]}' '"c"')" = '["$: must be one of [\"a\",\"b\"]"]' ] && ok "enum" || no "enum" "$(sc '{"enum":["a","b"]}' '"c"')"
[ "$(sc '{"type":"array","minItems":1}' '[]')" = '["$: fewer than 1 items"]' ] && ok "minItems" || no "minItems"
[ "$(sc '{"type":"object"}' 'no json here')" = '["no JSON at the end of the answer"]' ] && ok "prose without JSON is an error" || no "no json"
[ "$(sc '{"type":"object"}' $'```json\n{"a":1}\n```\nthen\n```json\n{"b":2}\n```')" = '[]' ] &&
  [ "$(jq -Rs --argjson schema '{}' "$schema_jq" <<<$'```json\n{"a":1}\n```\n```json\n{"b":2}\n```' | jq -c .value)" = '{"b":2}' ] &&
  ok "the last fence wins" || no "last fence"

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
