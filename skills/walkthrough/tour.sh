#!/usr/bin/env bash
# Talk to a running Neovim (walkthrough.nvim): send one commit of the map,
# patch it, and read what the user wrote.
#
#   tour.sh commit.json      send one commit of the map from a file
#   tour.sh - <<'EOF'        send one commit of the map from stdin
#   { "group": "<the commit's subject>", "steps": [ { "file": "...", ... } ] }
#   EOF
#   tour.sh --patch - <<EOF  change what is loaded in place, e.g. answer a thread
#   { "thread": "t1", "answer": "..." }
#   EOF
#   tour.sh --status         print where the user is as JSON
#   tour.sh --inbox [--all]  print what the user wrote since the last call
#                            (questions, change requests, decisions, requests
#                            for a commit message or for the map) as JSON;
#                            --all adds the threads that wait for an answer
#   tour.sh --snapshot [name]
#                            record the working tree as refs/walkthrough/<name>
#                            (default: reviewed) and print the commit id; not
#                            part of the workflow
#   tour.sh --close          end the session: clear the marks, close the panel
#   tour.sh --socket         print the socket that would be used (exit 1 and a
#                            message on stderr when there is none); hooks
#                            use it to find Neovim the same way
#
# A file, --patch, --inbox and --snapshot print Neovim's answer ("ok", JSON, a
# commit id or "error: ...") and exit non-zero on an error. --status prints its
# answer and --close nothing; neither checks it. The fields are described in
# references/format.md, next to SKILL.md.
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

if [[ ${1:-} == --socket ]]; then
  echo "$sock"
  exit 0
fi
if [[ ${1:-} == --close ]]; then
  nvim --server "$sock" --remote-expr "v:lua.require'walkthrough'.close()" >/dev/null
  exit 0
fi
if [[ ${1:-} == --status ]]; then
  nvim --server "$sock" --remote-expr "v:lua.require'walkthrough'.status()"
  echo
  exit 0
fi

if [[ ${1:-} == --inbox ]]; then
  all=
  case ${2:-} in
    --all) all="v:true" ;;
    "") ;;
    *) echo "usage: tour.sh --inbox [--all]" >&2; exit 2 ;;
  esac
  result=$(nvim --server "$sock" --remote-expr "v:lua.require'walkthrough'.inbox($all)")
  echo "$result"
  [[ $result != error:* ]]
  exit
fi
if [[ ${1:-} == --snapshot ]]; then
  name=${2:-}
  # Vimscript single-quoted strings escape ' by doubling it.
  result=$(nvim --server "$sock" --remote-expr "v:lua.require'walkthrough'.snapshot('${name//\'/\'\'}')")
  echo "$result"
  [[ $result != error:* ]]
  exit
fi

fn="load"
if [[ ${1:-} == --patch ]]; then
  fn="patch"
  shift
fi

step=${1:?usage: tour.sh [--patch] commit.json | tour.sh [--patch] - | tour.sh --status | tour.sh --inbox [--all] | tour.sh --snapshot [name] | tour.sh --socket | tour.sh --close}
if [[ $step == - ]]; then
  # BSD mktemp needs the X's at the end of the template (no --suffix).
  step=$(mktemp "${TMPDIR:-/tmp}/walkthrough.XXXXXX")
  trap 'rm -f "$step"' EXIT
  cat >"$step"
fi
# Neovim resolves the path in its own working directory, so make it absolute
# (realpath is not available everywhere).
case $step in
  /*) ;;
  *) step="$PWD/$step" ;;
esac

# Vimscript single-quoted strings escape ' by doubling it.
result=$(nvim --server "$sock" --remote-expr "v:lua.require'walkthrough'.$fn('${step//\'/\'\'}')")
echo "$result"
[[ $result == ok ]]
