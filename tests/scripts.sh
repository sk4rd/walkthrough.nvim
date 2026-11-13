#!/usr/bin/env bash
# Tests for the shell scripts of the skill (commit-check.sh, tour.sh and the
# hooks), in temporary repositories. tour.sh and the hooks talk to a fake `nvim`
# placed first in PATH; the plan review hook also gets one round trip with a
# real headless Neovim (skipped when nvim or jq is missing).
#
#   tests/scripts.sh
#
# Exit code is non-zero when a check fails.
set -u

root=$(cd "$(dirname "$0")/.." && pwd -P)
skill=$root/skills/walkthrough
work=$(mktemp -d "${TMPDIR:-/tmp}/walkthrough-scripts.XXXXXX")
real_nvim=$(command -v nvim || true) # before the fake one goes first in PATH
rt_pid=
cleanup() {
  [[ -z $rt_pid ]] || kill "$rt_pid" 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
unset WALKTHROUGH_CHECK WALKTHROUGH_NVIM NVIM

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() {
  fail=$((fail + 1))
  echo "FAIL $1"
  if [[ -n ${2:-} ]]; then
    while IFS= read -r l; do echo "     | $l"; done <<<"$2"
  fi
}

# expect <name> <want exit> <want output substring or ''> <got exit> <output>
expect() {
  local name=$1 want=$2 sub=$3 got=$4 out=$5
  if [[ $got != "$want" ]]; then
    bad "$name (exit $got, want $want)" "$out"
  elif [[ -n $sub && $out != *"$sub"* ]]; then
    bad "$name (output lacks '$sub')" "$out"
  else
    ok "$name"
  fi
}

new_repo() { # new_repo <name>: a repository with one commit, cwd inside
  local d=$work/$1
  mkdir -p "$d"
  cd "$d" || exit 1
  git init -q
  echo good >a.txt
  git add a.txt
  git commit -qm base
}

# ---- commit-check.sh

check=$skill/commit-check.sh

new_repo nothing
out=$("$check" 2>&1); expect "commit-check: nothing staged" 1 "(nothing staged)" $? "$out"

new_repo custom-pass
echo more >>a.txt; git add a.txt
echo stray >untracked.txt
out=$(WALKTHROUGH_CHECK='test -f a.txt && test ! -e untracked.txt' "$check" 2>&1)
expect "commit-check: custom check passes, runs on the index only" 0 "check ok" $? "$out"

new_repo custom-new
echo bad >a.txt; git add a.txt
out=$(WALKTHROUGH_CHECK='! grep -q bad a.txt' "$check" 2>&1)
expect "commit-check: custom check fails newly" 1 "this commit breaks it" $? "$out"

new_repo custom-old
echo more >>a.txt; git add a.txt
out=$(WALKTHROUGH_CHECK='false' "$check" 2>&1)
expect "commit-check: custom check fails already at HEAD" 1 "already broken" $? "$out"

new_repo file-check
mkdir .walkthrough
printf '#!/bin/sh\ngrep -q good a.txt\n' >.walkthrough/check
chmod +x .walkthrough/check
echo good2 >>a.txt; git add a.txt .walkthrough/check
out=$("$check" 2>&1); expect "commit-check: .walkthrough/check from the index passes" 0 "check ok" $? "$out"
git commit -qm check
echo nope >a.txt; git add a.txt
out=$("$check" 2>&1); expect "commit-check: .walkthrough/check fails newly" 1 "this commit breaks it" $? "$out"

new_repo env-wins
echo more >>a.txt; git add a.txt
mkdir .walkthrough; printf '#!/bin/sh\nexit 1\n' >.walkthrough/check; chmod +x .walkthrough/check
git add .walkthrough/check
out=$(WALKTHROUGH_CHECK='true' "$check" 2>&1)
expect "commit-check: WALKTHROUGH_CHECK takes precedence" 0 "check ok" $? "$out"

new_repo none
echo more >>a.txt; git add a.txt
out=$("$check" 2>&1); expect "commit-check: no check defined" 0 "no check defined" $? "$out"

if command -v nix >/dev/null 2>&1; then
  new_repo broken-flake
  echo '{ outputs = ' >flake.nix; git add flake.nix
  out=$("$check" 2>&1)
  got=$?
  expect "commit-check: broken flake exits non-zero" 1 "does not evaluate" $got "$out"
  [[ $out == *skipping* ]] && bad "commit-check: broken flake is not reported as skipped" "$out"

  new_repo plain-flake
  echo '{ outputs = _: { }; }' >flake.nix; git add flake.nix
  out=$("$check" 2>&1); expect "commit-check: flake without hosts is no check" 0 "no check defined" $? "$out"
else
  echo "skip commit-check: broken flake (nix is not installed)"
fi

# ---- tour.sh and the hook, with a fake nvim

fake=$work/fakebin
mkdir -p "$fake"
cat >"$fake/nvim" <<'FAKE'
#!/bin/sh
# Records the arguments; FAKE_NVIM_FAIL=1 behaves like an unreachable socket.
[ "${FAKE_NVIM_FAIL:-}" = 1 ] && { echo "E247: no such socket" >&2; exit 2; }
echo "$*" >>"$FAKE_NVIM_LOG"
# Remember the file the plugin would read.
for a in "$@"; do
  case $a in *"walkthrough'."*"('"*) f=${a#*\(\'}; f=${f%\'\)}; cp "$f" "$FAKE_NVIM_LOG.arg" 2>/dev/null ;; esac
  case $a in *".plan('"*) echo "$f" >"$FAKE_NVIM_LOG.path" ;; esac
done
case $* in
  # The plan review: plan() answers FAKE_PLAN_REPLY (default plan-1); every
  # plan_result() answers the next line of the file FAKE_PLAN_SCRIPT (the last
  # one again when it runs out), where DIE stands for a Neovim that is gone.
  *".plan('"*) printf '%s' "${FAKE_PLAN_REPLY:-plan-1}" ;;
  *".plan_result('"*)
    n=$(cat "$FAKE_NVIM_LOG.n" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" >"$FAKE_NVIM_LOG.n"
    line=$(sed -n "${n}p" "$FAKE_PLAN_SCRIPT"); [ -n "$line" ] || line=$(tail -n 1 "$FAKE_PLAN_SCRIPT")
    [ "$line" = DIE ] && { echo "E247: no such socket" >&2; exit 2; }
    printf '%s' "$line" ;;
  *status*) printf '{"step":1}' ;;
  *snapshot*"'bad"*) printf 'error: snapshot name must start with a letter' ;;
  *snapshot*) printf 'abc123def' ;;
  *inbox*) printf '{"items":[]}' ;;
  *) printf 'ok' ;;
esac
FAKE
chmod +x "$fake/nvim"
export FAKE_NVIM_LOG=$work/nvim.log
export PATH=$fake:$PATH
export WALKTHROUGH_NVIM=$work/no-such-socket

cd "$work" || exit 1
tour=$skill/tour.sh
echo '{"file":"x"}' >step.json
: >"$FAKE_NVIM_LOG"
out=$("$tour" step.json 2>&1); expect "tour.sh: file argument" 0 "ok" $? "$out"
if grep -q "load('$work/step.json')" "$FAKE_NVIM_LOG"; then ok "tour.sh: relative path is made absolute"; else bad "tour.sh: relative path is made absolute" "$(cat "$FAKE_NVIM_LOG")"; fi
out=$(echo '{"file":"y"}' | "$tour" - 2>&1); expect "tour.sh: stdin" 0 "ok" $? "$out"
if [[ $(cat "$FAKE_NVIM_LOG.arg") == '{"file":"y"}' ]]; then ok "tour.sh: stdin content reaches the file"; else bad "tour.sh: stdin content reaches the file"; fi
out=$(echo '{}' | "$tour" --patch - 2>&1); expect "tour.sh: --patch" 0 "ok" $? "$out"
if grep -q "patch('" "$FAKE_NVIM_LOG"; then ok "tour.sh: --patch calls patch"; else bad "tour.sh: --patch calls patch"; fi
out=$("$tour" --status 2>&1); expect "tour.sh: --status" 0 '{"step":1}' $? "$out"
out=$("$tour" --inbox 2>&1); expect "tour.sh: --inbox" 0 '{"items":[]}' $? "$out"
if grep -q "inbox()" "$FAKE_NVIM_LOG"; then ok "tour.sh: --inbox calls inbox() without an argument"; else bad "tour.sh: --inbox calls inbox() without an argument" "$(tail -n 1 "$FAKE_NVIM_LOG")"; fi
out=$("$tour" --inbox --all 2>&1); expect "tour.sh: --inbox --all" 0 '{"items":[]}' $? "$out"
if grep -q "inbox(v:true)" "$FAKE_NVIM_LOG"; then ok "tour.sh: --inbox --all calls inbox(v:true)"; else bad "tour.sh: --inbox --all calls inbox(v:true)" "$(tail -n 1 "$FAKE_NVIM_LOG")"; fi
out=$("$tour" --inbox --nope 2>&1); expect "tour.sh: --inbox rejects other arguments" 2 "usage" $? "$out"
out=$("$tour" --snapshot 2>&1); expect "tour.sh: --snapshot prints the commit id" 0 "abc123def" $? "$out"
if grep -q "snapshot('')" "$FAKE_NVIM_LOG"; then ok "tour.sh: --snapshot without a name calls snapshot('')"; else bad "tour.sh: --snapshot without a name calls snapshot('')" "$(tail -n 1 "$FAKE_NVIM_LOG")"; fi
out=$("$tour" --snapshot step-1 2>&1); expect "tour.sh: --snapshot name" 0 "abc123def" $? "$out"
if grep -q "snapshot('step-1')" "$FAKE_NVIM_LOG"; then ok "tour.sh: --snapshot passes the name"; else bad "tour.sh: --snapshot passes the name" "$(tail -n 1 "$FAKE_NVIM_LOG")"; fi
out=$("$tour" --snapshot "bad'name" 2>&1); expect "tour.sh: --snapshot exits non-zero on an error line" 1 "error: snapshot name" $? "$out"
if grep -q "snapshot('bad''name')" "$FAKE_NVIM_LOG"; then ok "tour.sh: --snapshot doubles a single quote"; else bad "tour.sh: --snapshot doubles a single quote" "$(tail -n 1 "$FAKE_NVIM_LOG")"; fi
out=$("$tour" --close 2>&1); expect "tour.sh: --close" 0 "" $? "$out"
out=$(FAKE_NVIM_FAIL=1 "$tour" --status 2>&1); expect "tour.sh: unreachable Neovim fails" 2 "" $? "$out"

if command -v jq >/dev/null 2>&1; then
  hook=$skill/hooks/visual-mode.sh
  prompt='{"prompt":"/walkthrough the diff","transcript_path":""}'
  other='{"prompt":"fix the bug","transcript_path":""}'

  out=$(echo "$prompt" | "$hook" 2>&1); expect "hook: ON" 0 "visual mode is ON" $? "$out"
  if [[ $out == *"Send the map with tour.sh, one call per commit; update it with tour.sh --patch."* && $out != *"as a tour"* ]]; then
    ok "hook: the message talks about the map and its commits"
  else
    bad "hook: the message talks about the map and its commits" "$out"
  fi
  out=$(echo "$prompt" | FAKE_NVIM_FAIL=1 "$hook" 2>&1); expect "hook: OFF" 0 "visual mode is OFF" $? "$out"
  out=$(echo "$other" | "$hook" 2>&1); expect "hook: silent outside a walkthrough" 0 "" $? "$out"
  if [[ -z $out ]]; then ok "hook: silent output is empty"; else bad "hook: silent output is empty" "$out"; fi

  printf '%s\n' '{"type":"user","message":{"content":"<command-message>walkthrough</command-message> go"}}' >transcript.jsonl
  out=$(echo "{\"prompt\":\"next\",\"transcript_path\":\"$work/transcript.jsonl\"}" | "$hook" 2>&1)
  expect "hook: session that ran /walkthrough earlier" 0 "visual mode is ON" $? "$out"

  # A skill directory reached through a symlinked directory (installed from a
  # read-only store) and a symlinked script file must still find tour.sh.
  ln -s "$skill" "$work/linked-skill"
  out=$(echo "$prompt" | "$work/linked-skill/hooks/visual-mode.sh" 2>&1)
  expect "hook: symlinked skill directory" 0 "visual mode is ON" $? "$out"
  mkdir -p "$work/bin"
  ln -s "$skill/hooks/visual-mode.sh" "$work/bin/hook"
  out=$(echo "$prompt" | "$work/bin/hook" 2>&1)
  expect "hook: symlinked script file" 0 "visual mode is ON" $? "$out"
  ln -s "$work/bin/hook" "$work/bin/hook2"
  out=$(echo "$prompt" | "$work/bin/hook2" 2>&1)
  expect "hook: chain of symlinks" 0 "visual mode is ON" $? "$out"
  out=$(cd "$work/bin" && echo "$prompt" | ./hook 2>&1)
  expect "hook: symlink run from its own directory" 0 "visual mode is ON" $? "$out"

  # The compatibility path of existing installs.
  out=$("$root/claude/skills/walkthrough/tour.sh" --status 2>&1)
  expect "claude/skills/walkthrough still resolves to tour.sh" 0 '{"step":1}' $? "$out"

  # ---- the plan review hook, with the fake nvim

  plan_hook=$skill/hooks/plan-review.sh
  export WALKTHROUGH_PLAN_POLL=0.05
  mkdir -p "$work/hooktmp"
  # The hook input of Claude Code; the tool input has more than the plan, to
  # see that it is passed on as it came. $1 is the plan text.
  plan_input() {
    jq -n --arg p "$1" '{hook_event_name: "PermissionRequest", tool_name: "ExitPlanMode", session_id: "s1", cwd: "/tmp",
      tool_input: {plan: $p, planFilePath: "/x/plan.md", extra: {n: 1.5, list: [1, [2]], none: null}}}'
  }
  # UTF-8 bytes written out, so that the locale does not matter.
  tricky=$'Plan "quoted"\nback\\slash and \\n literal\n\ttab, non-ascii: \xc3\xa4\xc3\xb6\xc3\xbc \xe2\x9c\x93 \xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e\n\n- last line'
  plan_input "$tricky" >"$work/plan-in.json"
  # Runs the hook on a file, with the temporary directory it uses watched. It
  # sets plan_out and plan_code; the file $FAKE_PLAN_SCRIPT is what Neovim answers.
  run_plan_hook() {
    rm -f "$FAKE_NVIM_LOG.n" "$FAKE_NVIM_LOG.arg" "$FAKE_NVIM_LOG.path"
    : >"$FAKE_NVIM_LOG"
    rm -rf "$work/hooktmp"; mkdir -p "$work/hooktmp"
    plan_out=$(TMPDIR=$work/hooktmp "$plan_hook" <"$1" 2>"$work/plan-err")
    plan_code=$?
  }
  silent() { # silent <name>: no output, exit 0, the temporary file gone
    local gone=yes
    [[ -z $(ls -A "$work/hooktmp") ]] || gone=no
    if [[ $plan_code == 0 && -z $plan_out && $gone == yes ]]; then
      ok "plan hook: $1"
    else
      bad "plan hook: $1" "exit $plan_code, tmp file left: $gone, output: $plan_out"
    fi
  }
  say() { # say <line>...: what Neovim answers to plan_result, one line per call
    printf '%s\n' "$@" >"$work/plan-script"
    export FAKE_PLAN_SCRIPT=$work/plan-script
  }
  allowed() { jq -e '.hookSpecificOutput.decision.behavior == "allow"' <<<"$1" >/dev/null 2>&1; }
  say '{"state":"pending"}'

  jq '.tool_name = "Bash"' "$work/plan-in.json" >"$work/in-bash.json"
  run_plan_hook "$work/in-bash.json"
  silent "another tool is left alone"
  jq 'del(.tool_input.plan)' "$work/plan-in.json" >"$work/in-noplan.json"
  run_plan_hook "$work/in-noplan.json"
  silent "no plan text"
  jq '.tool_input.plan = " \n "' "$work/plan-in.json" >"$work/in-blank.json"
  run_plan_hook "$work/in-blank.json"
  silent "a blank plan"
  jq 'del(.tool_input)' "$work/plan-in.json" >"$work/in-notool.json"
  run_plan_hook "$work/in-notool.json"
  silent "no tool input"
  echo 'not json' >"$work/in-junk.json"
  run_plan_hook "$work/in-junk.json"
  silent "input that is no JSON"
  if [[ ! -s $FAKE_NVIM_LOG ]]; then ok "plan hook: none of those reaches Neovim"; else bad "plan hook: none of those reaches Neovim" "$(cat "$FAKE_NVIM_LOG")"; fi

  # No Neovim: none to find, several, one that does not answer.
  mkdir -p "$work/run-none" "$work/run-two"
  : >"$work/run-two/nvim.1.0"; : >"$work/run-two/nvim.2.0"
  : >"$FAKE_NVIM_LOG"
  rm -rf "$work/hooktmp"; mkdir -p "$work/hooktmp"
  plan_out=$(env -u WALKTHROUGH_NVIM -u NVIM XDG_RUNTIME_DIR="$work/run-none" TMPDIR="$work/hooktmp" "$plan_hook" <"$work/plan-in.json" 2>/dev/null); plan_code=$?
  silent "no Neovim running"
  plan_out=$(env -u WALKTHROUGH_NVIM -u NVIM XDG_RUNTIME_DIR="$work/run-two" TMPDIR="$work/hooktmp" "$plan_hook" <"$work/plan-in.json" 2>/dev/null); plan_code=$?
  silent "several Neovims and no WALKTHROUGH_NVIM"
  if [[ ! -s $FAKE_NVIM_LOG ]]; then ok "plan hook: it asks no Neovim then"; else bad "plan hook: it asks no Neovim then" "$(cat "$FAKE_NVIM_LOG")"; fi
  FAKE_NVIM_FAIL=1 run_plan_hook "$work/plan-in.json"
  silent "a Neovim that does not answer"
  FAKE_PLAN_REPLY='error: the hook input has no tool_input.plan text' run_plan_hook "$work/plan-in.json"
  silent "plan() answers an error"
  if grep -q plan_result "$FAKE_NVIM_LOG"; then bad "plan hook: no questions after an error" "$(cat "$FAKE_NVIM_LOG")"; else ok "plan hook: no questions after an error"; fi
  FAKE_PLAN_REPLY='not an id!' run_plan_hook "$work/plan-in.json"
  silent "an answer that is no id"

  # The hook input reaches Neovim as it is, and the id is asked about.
  say '{"state":"pending"}' '{"state":"approve"}'
  run_plan_hook "$work/plan-in.json"
  if jq -e --slurpfile want "$work/plan-in.json" '. == $want[0]' "$FAKE_NVIM_LOG.arg" >/dev/null 2>&1; then
    ok "plan hook: plan() gets the hook input unchanged"
  else
    bad "plan hook: plan() gets the hook input unchanged" "$(cat "$FAKE_NVIM_LOG.arg")"
  fi
  if grep -q "plan_result('plan-1')" "$FAKE_NVIM_LOG" && [[ $(grep -c plan_result "$FAKE_NVIM_LOG") == 2 ]]; then
    ok "plan hook: it asks plan_result with the id until the answer"
  else
    bad "plan hook: it asks plan_result with the id until the answer" "$(cat "$FAKE_NVIM_LOG")"
  fi

  # Approve: exactly the allow object, with the tool input as it came.
  # shellcheck disable=SC2016 # $in is jq's, not the shell's
  want_allow='{hookSpecificOutput: {hookEventName: "PermissionRequest", decision: {behavior: "allow", updatedInput: $in[0].tool_input}}}'
  if [[ $plan_code == 0 ]] && jq -e --slurpfile in "$work/plan-in.json" ". == $want_allow" <<<"$plan_out" >/dev/null 2>&1; then
    ok "plan hook: approve prints the allow object with the unchanged tool input"
  else
    bad "plan hook: approve prints the allow object with the unchanged tool input" "$plan_code $plan_out"
  fi
  if [[ $(jq -s length <<<"$plan_out") == 1 && $(wc -l <<<"$plan_out") == 1 ]]; then ok "plan hook: approve prints one JSON object"; else bad "plan hook: approve prints one JSON object" "$plan_out"; fi
  if [[ -z $(ls -A "$work/hooktmp") ]]; then ok "plan hook: the temporary file is gone after approve"; else bad "plan hook: the temporary file is gone after approve" "$(ls -A "$work/hooktmp")"; fi
  if [[ ! -e $(cat "$FAKE_NVIM_LOG.path") ]]; then ok "plan hook: the file given to Neovim is deleted"; else bad "plan hook: the file given to Neovim is deleted"; fi
  if [[ -z $(cat "$work/plan-err") ]]; then ok "plan hook: nothing on stderr"; else bad "plan hook: nothing on stderr" "$(cat "$work/plan-err")"; fi

  # Feedback: exactly the deny object, the message unchanged, special characters included.
  msg=$'1. Question t1 on plan line 2:\n   > a "quoted" line with \\ and \\n\n   User: h\xc3\xa4? \xe2\x9c\x93 \xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e\ttab\n\n'
  jq -nc --arg m "$msg" '{state: "feedback", message: $m}' >"$work/plan-script"
  export FAKE_PLAN_SCRIPT=$work/plan-script
  run_plan_hook "$work/plan-in.json"
  # shellcheck disable=SC2016
  want_deny='{hookSpecificOutput: {hookEventName: "PermissionRequest", decision: {behavior: "deny", message: $m}}}'
  if [[ $plan_code == 0 ]] && jq -e --arg m "$msg" ". == $want_deny" <<<"$plan_out" >/dev/null 2>&1; then
    ok "plan hook: feedback prints the deny object with the message unchanged"
  else
    bad "plan hook: feedback prints the deny object with the message unchanged" "$plan_code $plan_out"
  fi
  if [[ $(jq -s length <<<"$plan_out") == 1 && $(wc -l <<<"$plan_out") == 1 ]]; then ok "plan hook: feedback prints one JSON object"; else bad "plan hook: feedback prints one JSON object" "$plan_out"; fi
  if [[ -z $(ls -A "$work/hooktmp") ]]; then ok "plan hook: the temporary file is gone after feedback"; else bad "plan hook: the temporary file is gone after feedback" "$(ls -A "$work/hooktmp")"; fi
  # A feedback without a text is no answer the hook can use.
  say '{"state":"feedback"}'
  run_plan_hook "$work/plan-in.json"
  silent "a feedback without a text"

  # Waiting: pending answers are no errors, however many.
  say '{"state":"pending"}' '{"state":"pending"}' '{"state":"pending"}' '{"state":"pending"}' '{"state":"pending"}' '{"state":"approve"}'
  run_plan_hook "$work/plan-in.json"
  if allowed "$plan_out"; then ok "plan hook: it keeps waiting while the review is pending"; else bad "plan hook: it keeps waiting while the review is pending" "$plan_out"; fi
  # Neovim gone while waiting.
  say '{"state":"pending"}' DIE
  run_plan_hook "$work/plan-in.json"
  silent "Neovim disappears while waiting"
  # Errors three times in a row end the wait; fewer do not.
  say 'error: unknown plan review plan-1'
  run_plan_hook "$work/plan-in.json"
  silent "an error answer three times in a row"
  if [[ $(cat "$FAKE_NVIM_LOG.n") == 3 ]]; then ok "plan hook: exactly three tries"; else bad "plan hook: exactly three tries" "$(cat "$FAKE_NVIM_LOG.n")"; fi
  say 'error: x' 'error: x' '{"state":"pending"}' 'error: x' 'error: x' '{"state":"approve"}'
  run_plan_hook "$work/plan-in.json"
  if allowed "$plan_out"; then ok "plan hook: errors that are not in a row do not end the wait"; else bad "plan hook: errors that are not in a row do not end the wait" "$plan_out"; fi
  say '{"state":"nonsense"}'
  run_plan_hook "$work/plan-in.json"
  silent "an answer it does not know, three times"

  # Stopped by Claude Code while it waits: no output, no file left.
  say '{"state":"pending"}'
  rm -rf "$work/hooktmp"; mkdir -p "$work/hooktmp"
  WALKTHROUGH_PLAN_POLL=0.2 TMPDIR="$work/hooktmp" "$plan_hook" <"$work/plan-in.json" >"$work/plan-term-out" 2>/dev/null &
  hook_pid=$!
  sleep 0.5
  kill -TERM "$hook_pid" 2>/dev/null
  wait "$hook_pid"; plan_code=$?
  plan_out=$(cat "$work/plan-term-out")
  silent "the hook is stopped while it waits"

  # The skill reached through symlinks still finds tour.sh.
  say '{"state":"approve"}'
  plan_out=$(TMPDIR="$work/hooktmp" "$work/linked-skill/hooks/plan-review.sh" <"$work/plan-in.json" 2>/dev/null)
  if allowed "$plan_out"; then ok "plan hook: symlinked skill directory"; else bad "plan hook: symlinked skill directory" "$plan_out"; fi
  ln -s "$plan_hook" "$work/bin/plan-hook"
  plan_out=$(TMPDIR="$work/hooktmp" "$work/bin/plan-hook" <"$work/plan-in.json" 2>/dev/null)
  if allowed "$plan_out"; then ok "plan hook: symlinked script file"; else bad "plan hook: symlinked script file" "$plan_out"; fi
  out=$("$tour" --socket 2>&1); expect "tour.sh: --socket prints the socket" 0 "$work/no-such-socket" $? "$out"
  out=$(env -u WALKTHROUGH_NVIM -u NVIM XDG_RUNTIME_DIR="$work/run-none" "$tour" --socket 2>&1); expect "tour.sh: --socket without a Neovim fails" 1 "no running Neovim" $? "$out"
else
  echo "skip hook tests (jq is not installed)"
fi

# ---- the plan review hook against a real headless Neovim: comment, send
# feedback, a revised plan, an answer of the agent, approve

if [[ -n $real_nvim ]] && command -v jq >/dev/null 2>&1; then
  real_dir=$(dirname "$real_nvim")
  rt_sock=$work/rt.sock
  rt_state=$work/rt-state
  mkdir -p "$work/rt-home" "$work/rt-tmp"
  rt() { "$real_nvim" --server "$rt_sock" --remote-expr "$1" 2>/dev/null; }
  # A hook of the skill, as Claude Code would run it, against the real Neovim.
  rt_hook() { # rt_hook <input> <output>: starts it in the background; sets rt_hook_pid
    PATH=$real_dir:$PATH WALKTHROUGH_NVIM=$rt_sock WALKTHROUGH_PLAN_POLL=0.1 TMPDIR=$work/rt-tmp "$plan_hook" <"$1" >"$2" 2>"$2.err" &
    rt_hook_pid=$!
  }
  rt_wait_for() { # rt_wait_for <expression> <want>: poll Neovim for up to 10 seconds
    local i
    for ((i = 0; i < 100; i++)); do
      [[ $(rt "$1") == "$2" ]] && return 0
      sleep 0.1
    done
    return 1
  }
  rt_finish() { # rt_finish <pid>: wait for the hook to end (10 seconds at most)
    local i
    for ((i = 0; i < 100; i++)); do
      kill -0 "$1" 2>/dev/null || { wait "$1"; return; }
      sleep 0.1
    done
    kill "$1" 2>/dev/null
    wait "$1" 2>/dev/null
    return 99
  }

  (cd "$work/rt-home" && XDG_STATE_HOME="$work/rt-xdg" WALKTHROUGH_STATE_DIR=$rt_state WALKTHROUGH_ROOT=$root exec "$real_nvim" --headless -i NONE -n --listen "$rt_sock" --cmd "set rtp^=$root" -u "$root/tests/init.lua") >"$work/rt-nvim.log" 2>&1 &
  rt_pid=$!
  if rt_wait_for "1" 1; then
    ok "plan round trip: a headless Neovim is up"

    plan_input $'Plan\n1. first step\n2. second step\n3. third step' | jq '.session_id = "rt-sess"' >"$work/rt-in1.json"
    rt_hook "$work/rt-in1.json" "$work/rt-out1"
    h1=$rt_hook_pid
    if rt_wait_for "getline(1)" Plan; then ok "plan round trip: the plan opens in the current window"; else bad "plan round trip: the plan opens in the current window" "$(cat "$work/rt-nvim.log")"; fi
    if [[ $(rt "tabpagenr('\$') . ',' . winnr('\$')") == 1,1 ]]; then ok "plan round trip: no tab and no window is made for it"; else bad "plan round trip: no tab and no window is made for it"; fi
    if [[ $(rt "&modifiable") == 0 ]]; then ok "plan round trip: the plan is read-only"; else bad "plan round trip: the plan is read-only"; fi
    if kill -0 "$h1" 2>/dev/null; then ok "plan round trip: the hook waits"; else bad "plan round trip: the hook waits"; fi

    rt "v:lua.require'walkthrough'.change('make step two smaller', [3, 3])" >/dev/null
    rt "v:lua.require'walkthrough'.ask('why three steps?', [4, 4])" >/dev/null
    status=$(rt "v:lua.require'walkthrough'.status()")
    if [[ $(jq -r '.plan.threads' <<<"$status") == 2 && $(jq -r '.plan.state' <<<"$status") == pending ]]; then ok "plan round trip: both comments are collected, status has the plan"; else bad "plan round trip: both comments are collected, status has the plan" "$status"; fi
    if kill -0 "$h1" 2>/dev/null; then ok "plan round trip: commenting does not release the hook"; else bad "plan round trip: commenting does not release the hook"; fi
    rt "v:lua.require'walkthrough'.plan_feedback()" >/dev/null
    rt_finish "$h1"; code=$?
    out=$(cat "$work/rt-out1")
    if [[ $code == 0 ]] && jq -e '.hookSpecificOutput.decision.behavior == "deny" and .hookSpecificOutput.hookEventName == "PermissionRequest"' <<<"$out" >/dev/null 2>&1; then
      ok "plan round trip: feedback ends the hook with a deny"
    else
      bad "plan round trip: feedback ends the hook with a deny" "$code $out $(cat "$work/rt-out1.err")"
    fi
    fb=$(jq -r '.hookSpecificOutput.decision.message' <<<"$out")
    if [[ $fb == *"Comment t1 on plan line 3:"* && $fb == *"> 2. second step"* && $fb == *"make step two smaller"* && $fb == *"Comment t2 on plan line 4:"* && $fb == *"why three steps?"* && $fb == *'"thread": "<id>"'* && $fb == *"revise the plan where a comment asks for a change"* ]]; then
      ok "plan round trip: the message has both comments, their lines and the instruction"
    else
      bad "plan round trip: the message has both comments, their lines and the instruction" "$fb"
    fi
    if [[ $fb != *Question* && $fb != *"Change request"* ]]; then ok "plan round trip: the message names no question and no change request"; else bad "plan round trip: the message names no question and no change request" "$fb"; fi
    if [[ $(rt "tabpagenr('\$') . ',' . winnr('\$') . ',' . getline(1)") == 1,1,Plan ]]; then ok "plan round trip: the plan stays on screen"; else bad "plan round trip: the plan stays on screen"; fi
    status=$(rt "v:lua.require'walkthrough'.status()")
    if [[ $(jq -r '.plan.state' <<<"$status") == feedback-sent ]]; then ok "plan round trip: the plan waits for the revision"; else bad "plan round trip: the plan waits for the revision" "$status"; fi
    if [[ -z $(ls -A "$work/rt-tmp") ]]; then ok "plan round trip: the hook left no temporary file"; else bad "plan round trip: the hook left no temporary file" "$(ls -A "$work/rt-tmp")"; fi

    # The agent shows a revised plan: a line inserted above, one step rewritten.
    plan_input $'Plan\nNote: revised\n1. first step\n2. second step\n3. third step, rewritten' | jq '.session_id = "rt-sess"' >"$work/rt-in2.json"
    rt_hook "$work/rt-in2.json" "$work/rt-out2"
    h2=$rt_hook_pid
    if rt_wait_for "getline(2)" "Note: revised"; then ok "plan round trip: the revised plan replaces the text in the same window"; else bad "plan round trip: the revised plan replaces the text in the same window"; fi
    if [[ $(rt "tabpagenr('\$') . ',' . winnr('\$')") == 1,1 ]]; then ok "plan round trip: no second tab or window for the revision"; else bad "plan round trip: no second tab or window for the revision"; fi
    th() { rt "luaeval('require(\"walkthrough.tours\").plans()[1].steps[1].threads[$1].$2')"; }
    if [[ $(th 1 from) == 4 && $(th 1 id) == t1 ]]; then ok "plan round trip: the first comment followed its line"; else bad "plan round trip: the first comment followed its line" "$(th 1 from)"; fi
    if [[ $(th 1 kind) == comment && $(th 2 kind) == comment ]]; then ok "plan round trip: both threads are comments, written with ask and change"; else bad "plan round trip: both threads are comments, written with ask and change" "$(th 1 kind) $(th 2 kind)"; fi
    if [[ $(th 2 from) == 5 ]]; then ok "plan round trip: the second comment followed its line"; else bad "plan round trip: the second comment followed its line" "$(th 2 from)"; fi
    if [[ $(th 2 stale) == true ]]; then ok "plan round trip: a thread on a rewritten line is stale"; else bad "plan round trip: a thread on a rewritten line is stale" "$(th 2 stale)"; fi
    if [[ $(th 1 stale) != true ]]; then ok "plan round trip: a thread on an untouched line is not stale"; else bad "plan round trip: a thread on an untouched line is not stale"; fi
    if [[ $(th 2 state) == waiting ]]; then ok "plan round trip: the delivered thread waits for the agent"; else bad "plan round trip: the delivered thread waits for the agent" "$(th 2 state)"; fi
    status=$(rt "v:lua.require'walkthrough'.status()")
    if [[ $(jq -r '.plan.state' <<<"$status") == pending ]]; then ok "plan round trip: the revision is pending again"; else bad "plan round trip: the revision is pending again" "$status"; fi
    if kill -0 "$h2" 2>/dev/null; then ok "plan round trip: the second hook waits"; else bad "plan round trip: the second hook waits"; fi

    # The agent answers the thread (as it does with tour.sh --patch).
    echo '{ "thread": "t2", "answer": "three is the minimum: setup, change, check" }' >"$work/rt-patch.json"
    out=$(PATH=$real_dir:$PATH WALKTHROUGH_NVIM=$rt_sock "$skill/tour.sh" --patch "$work/rt-patch.json" 2>&1)
    if [[ $out == ok ]]; then ok "plan round trip: tour.sh --patch answers a thread of the plan"; else bad "plan round trip: tour.sh --patch answers a thread of the plan" "$out"; fi
    if [[ $(th 2 state) == answered ]]; then ok "plan round trip: the thread is answered"; else bad "plan round trip: the thread is answered" "$(th 2 state)"; fi

    # Approve: the hook gets the allow object, the plan and its file go.
    rt "v:lua.require'walkthrough'.plan_approve()" >/dev/null
    rt_finish "$h2"; code=$?
    out=$(cat "$work/rt-out2")
    # shellcheck disable=SC2016
    want='{hookSpecificOutput: {hookEventName: "PermissionRequest", decision: {behavior: "allow", updatedInput: $in[0].tool_input}}}'
    if [[ $code == 0 ]] && jq -e --slurpfile in "$work/rt-in2.json" ". == $want" <<<"$out" >/dev/null 2>&1; then
      ok "plan round trip: approve ends the hook with the allow object and the tool input"
    else
      bad "plan round trip: approve ends the hook with the allow object and the tool input" "$code $out $(cat "$work/rt-out2.err")"
    fi
    if [[ $(rt "tabpagenr('\$') . ',' . winnr('\$') . ',[' . bufname('%') . ']'") == '1,1,[]' ]]; then ok "plan round trip: the window shows its old buffer again"; else bad "plan round trip: the window shows its old buffer again" "$(rt "bufname('%')")"; fi
    if [[ ! -e $rt_state/plans/rt-sess-1.md ]]; then ok "plan round trip: the plan file is gone"; else bad "plan round trip: the plan file is gone" "$(ls "$rt_state/plans")"; fi
    status=$(rt "v:lua.require'walkthrough'.status()")
    if [[ $(jq -r '.plan // "none"' <<<"$status") == none ]]; then ok "plan round trip: no plan under review afterwards"; else bad "plan round trip: no plan under review afterwards" "$status"; fi
    if [[ -z $(ls -A "$work/rt-tmp") ]]; then ok "plan round trip: no temporary file left"; else bad "plan round trip: no temporary file left"; fi

    # Neovim closing while a hook waits: the hook falls back by itself.
    plan_input $'Another plan' | jq '.session_id = "rt-gone"' >"$work/rt-in3.json"
    rt_hook "$work/rt-in3.json" "$work/rt-out3"
    h3=$rt_hook_pid
    rt_wait_for "getline(1)" "Another plan" >/dev/null
    rt "execute('qall!')" >/dev/null 2>&1
    rt_finish "$h3"; code=$?
    if [[ $code == 0 && ! -s $work/rt-out3 ]]; then ok "plan round trip: closing Neovim leaves the hook silent, exit 0"; else bad "plan round trip: closing Neovim leaves the hook silent, exit 0" "$code $(cat "$work/rt-out3")"; fi
    if [[ -z $(ls -A "$work/rt-tmp") ]]; then ok "plan round trip: no temporary file left after that"; else bad "plan round trip: no temporary file left after that"; fi
  else
    bad "plan round trip: a headless Neovim is up" "$(cat "$work/rt-nvim.log")"
  fi
  kill "$rt_pid" 2>/dev/null
  wait "$rt_pid" 2>/dev/null
  rt_pid=
else
  echo "skip plan round trip (nvim or jq is not installed)"
fi

echo
echo "scripts: $pass passed, $fail failed"
((fail == 0))
