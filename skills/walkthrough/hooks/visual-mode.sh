#!/usr/bin/env bash
# Optional, and specific to Claude Code (a UserPromptSubmit hook). The skill
# works without it: SKILL.md tells the agent to run `tour.sh --status` itself.
#
# Enforce the walkthrough's visual mode. On every prompt of a session that runs /walkthrough, check whether a Neovim
# with the walkthrough module is reachable (tour.sh --status) and tell Claude
# the result as a rule, so it never decides from guesses. Other sessions get
# nothing. A session counts as a walkthrough when the prompt starts with
# /walkthrough or the transcript (a Claude Code file whose format is not
# documented, so this may stop working) shows that the skill was invoked.
set -u

input=$(cat)
prompt=$(jq -r '.prompt // ""' <<<"$input")
transcript=$(jq -r '.transcript_path // ""' <<<"$input")

# In a walkthrough if this prompt starts one, or the session ran /walkthrough
# before (a user message that is the skill invocation itself; mentions of the
# word in tool output do not count).
active=0
if [[ $prompt =~ ^[[:space:]]*/walkthrough ]]; then
  active=1
elif [[ -f $transcript ]] && jq -e -n '
    first(inputs | select(.type == "user"
      and (.message.content | type) == "string"
      and (.message.content | startswith("<command-message>walkthrough</command-message>")))) | true
  ' "$transcript" >/dev/null 2>&1; then
  active=1
fi
((active)) || exit 0

# Find tour.sh next to this script's real location. Follow a symlinked script
# by hand (readlink -f is GNU only); a symlinked skill directory needs nothing
# extra because hooks/ is a real directory inside it.
script=$0
while [[ -L $script ]]; do
  link=$(readlink "$script")
  case $link in
    /*) script=$link ;;
    *) script="$(dirname "$script")/$link" ;;
  esac
done
tour="$(cd "$(dirname "$script")" && pwd -P)/../tour.sh"
if status=$("$tour" --status 2>&1); then
  msg="Walkthrough visual mode is ON (checked by hook: tour.sh --status -> $status). A Neovim with the walkthrough module is reachable. Show every group as a tour with tour.sh (one call per group) and update it with tour.sh --patch after edits. Do not present a group only in chat."
else
  msg="Walkthrough visual mode is OFF (checked by hook: tour.sh --status -> $status). Use chat mode, or ask the user to open Neovim or pick a socket."
fi
jq -n --arg m "$msg" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $m}}'
