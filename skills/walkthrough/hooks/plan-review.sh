#!/usr/bin/env bash
# Optional, and specific to Claude Code: a PermissionRequest hook for
# ExitPlanMode that lets you review the agent's plan in Neovim. Settings
# (~/.claude/settings.json; the timeout is in seconds, the hook waits for you):
#
#   { "hooks": { "PermissionRequest": [ { "matcher": "ExitPlanMode", "hooks": [ {
#     "type": "command",
#     "command": "~/.claude/skills/walkthrough/hooks/plan-review.sh",
#     "timeout": 86400
#   } ] } ] } }
#
# Claude Code runs this when the agent wants to leave plan mode and waits for
# it. The hook input (JSON on stdin, with tool_input.plan) goes to Neovim
# (the socket entry point plan()), then Neovim is asked about once a second
# (plan_result()) until the user decides:
#   approve   prints the allow decision, with the tool input as it came;
#   feedback  prints the deny decision, with the user's message for the agent.
# Whenever Neovim cannot do the review (no Neovim, several without
# $WALKTHROUGH_NVIM, no plugin, an error, Neovim closed while waiting) it prints
# nothing and exits 0, which leaves Claude Code's normal permission prompt in
# place. Hook documentation: https://code.claude.com/docs/en/hooks
#
# $WALKTHROUGH_PLAN_POLL is the pause between two questions in seconds
# (default 1); the tests shorten it.
set -u

tmp=
cleanup() {
  [[ -z $tmp ]] || rm -f "$tmp"
}
trap cleanup EXIT
# Claude Code stopping the hook (a timeout, the user's Escape) is no error.
trap 'exit 0' HUP INT TERM

command -v jq >/dev/null 2>&1 || exit 0
command -v nvim >/dev/null 2>&1 || exit 0

# The hook input goes to a file: Neovim reads it by path.
# BSD mktemp needs the X's at the end of the template (no --suffix).
tmp=$(mktemp "${TMPDIR:-/tmp}/walkthrough-plan.XXXXXX") || exit 0
case $tmp in
  /*) ;;
  *) tmp="$PWD/$tmp" ;;
esac
cat >"$tmp"

# Only the plan of ExitPlanMode is ours.
jq -e '.tool_name == "ExitPlanMode" and ((.tool_input.plan? // "") | type == "string" and test("\\S"))' \
  "$tmp" >/dev/null 2>&1 || exit 0

# Find tour.sh next to this script's real location, and ask it for the socket,
# so the hook finds Neovim the way the agent does. Follow a symlinked script by
# hand (readlink -f is GNU only).
script=$0
while [[ -L $script ]]; do
  link=$(readlink "$script")
  case $link in
    /*) script=$link ;;
    *) script="$(dirname "$script")/$link" ;;
  esac
done
tour="$(cd "$(dirname "$script")" && pwd -P)/../tour.sh"
sock=$("$tour" --socket 2>/dev/null) || exit 0
[[ -n $sock ]] || exit 0

# Call a function of the plugin; a Vimscript string escapes ' by doubling it.
call() {
  nvim --server "$sock" --remote-expr "v:lua.require'walkthrough'.$1" 2>/dev/null
}

id=$(call "plan('${tmp//\'/\'\'}')") || exit 0
[[ $id =~ ^[A-Za-z0-9._-]+$ ]] || exit 0 # an "error: ..." line, or nothing

errors=0
while :; do
  if res=$(call "plan_result('$id')") && [[ $res != error:* ]]; then
    state=$(jq -r '.state // ""' <<<"$res" 2>/dev/null) || state=
    case $state in
      pending) errors=0 ;;
      approve)
        # The tool input is passed on unchanged: ExitPlanMode needs it with allow.
        out=$(jq -ce '{hookSpecificOutput: {hookEventName: "PermissionRequest",
          decision: {behavior: "allow", updatedInput: .tool_input}}}' "$tmp") && printf '%s\n' "$out"
        exit 0
        ;;
      feedback)
        out=$(jq -ce 'select(.message | type == "string")
          | {hookSpecificOutput: {hookEventName: "PermissionRequest",
          decision: {behavior: "deny", message: .message}}}' <<<"$res") && printf '%s\n' "$out"
        exit 0
        ;;
      *) errors=$((errors + 1)) ;;
    esac
  else
    errors=$((errors + 1))
  fi
  # Neovim gone, or something it does not understand, three times in a row.
  ((errors < 3)) || exit 0
  sleep "${WALKTHROUGH_PLAN_POLL:-1}"
done
