#!/usr/bin/env bash
# Run the regression suite headless, in a throwaway git repository.
#
#   tests/run.sh
#
# The plugin is loaded from this checkout. Staging tests need gitsigns.nvim
# on Neovim's packpath (any Neovim that has it installed) and are skipped
# without it. Exit code = number of failed checks.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

git() { command git -C "$work" -c user.email=test@example.com -c user.name=test "$@"; }
git init -q
printf '%s\n' a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 >"$work/f.txt"
printf 'x\n' >"$work/g.txt"
git add f.txt g.txt
git commit -qm base
# Group A changes lines 2-3 and deletes a10, group B changes line 4 (one git
# hunk with A's lines), line 8 belongs to no group. new.txt is untracked.
printf '%s\n' a1 A2 A3 B4 a5 a6 a7 X8 a9 >"$work/f.txt"
printf '%s\n' n1 n2 >"$work/new.txt"

cd "$work"
WALKTHROUGH_ROOT=$root WORK=$work nvim --headless -i NONE -n \
  --cmd "set rtp^=$root" -u "$root/tests/init.lua" \
  -c "luafile $root/tests/test.lua"
