#!/usr/bin/env bash
# Tests for the shell scripts of the skill (commit-check.sh, tour.sh and the
# hook), in temporary repositories. No Neovim is started: tour.sh and the hook
# talk to a fake `nvim` placed first in PATH.
#
#   tests/scripts.sh
#
# Exit code is non-zero when a check fails.
set -u

root=$(cd "$(dirname "$0")/.." && pwd -P)
skill=$root/skills/walkthrough
work=$(mktemp -d "${TMPDIR:-/tmp}/walkthrough-scripts.XXXXXX")
trap 'rm -rf "$work"' EXIT

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
done
case $* in
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
else
  echo "skip hook tests (jq is not installed)"
fi

echo
echo "scripts: $pass passed, $fail failed"
((fail == 0))
