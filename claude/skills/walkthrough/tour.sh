#!/usr/bin/env bash
# Send a walkthrough step or tour to a running Neovim, or patch it.
#
#   tour.sh step.json        send a step file
#   tour.sh - <<'EOF'        send a step from stdin
#   { "file": "...", ... }
#   EOF
#   tour.sh --patch - <<EOF  change parts of the tour in place, e.g.
#   { "note": 3, "verdict": "done", "text": "..." }
#   EOF
#   tour.sh --status         print the current step as JSON
#   tour.sh --close          remove highlights and close the panel
#
# Socket: $WALKTHROUGH_NVIM, else $NVIM (set inside Neovim's terminal),
# else the only Neovim socket in $XDG_RUNTIME_DIR.
set -euo pipefail

find_socket() {
  local s=${WALKTHROUGH_NVIM:-${NVIM:-}}
  if [[ -n $s ]]; then
    echo "$s"
    return
  fi
  shopt -s nullglob
  local socks=("${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"/nvim.*.0)
  if ((${#socks[@]} == 1)); then
    echo "${socks[0]}"
  elif ((${#socks[@]} == 0)); then
    echo "tour.sh: no running Neovim found" >&2
    exit 1
  else
    echo "tour.sh: several Neovims running, set WALKTHROUGH_NVIM to one of:" >&2
    printf '  %s\n' "${socks[@]}" >&2
    exit 1
  fi
}

sock=$(find_socket)

if [[ ${1:-} == --close ]]; then
  nvim --server "$sock" --remote-expr "v:lua.require'walkthrough'.close()" >/dev/null
  exit 0
fi
if [[ ${1:-} == --status ]]; then
  nvim --server "$sock" --remote-expr "v:lua.require'walkthrough'.status()"
  echo
  exit 0
fi

fn=load
if [[ ${1:-} == --patch ]]; then
  fn=patch
  shift
fi

step=${1:?usage: tour.sh [--patch] step.json | tour.sh [--patch] - | tour.sh --status | tour.sh --close}
if [[ $step == - ]]; then
  step=$(mktemp --suffix=.json)
  trap 'rm -f "$step"' EXIT
  cat >"$step"
fi
step=$(realpath "$step")

# Vimscript single-quoted strings escape ' by doubling it.
result=$(nvim --server "$sock" --remote-expr "v:lua.require'walkthrough'.$fn('${step//\'/\'\'}')")
echo "$result"
[[ $result == ok ]]
