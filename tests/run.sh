#!/usr/bin/env bash
# Run the regression suite headless: tests/test.lua and every
# tests/*_spec.lua, each in its own Neovim and in a fresh throwaway git
# repository.
#
#   tests/run.sh
#
# The plugin is loaded from this checkout. Staging tests need gitsigns.nvim,
# either on Neovim's packpath or in the directory $WALKTHROUGH_GITSIGNS (CI
# clones it there). Without it they are skipped. Exit code is non-zero when
# any check failed.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
passed=0
failed=0

# A repository with a committed base and a working tree that differs.
fixture() {
  local work=$1
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
}

for spec in "$root"/tests/test.lua "$root"/tests/*_spec.lua; do
  [[ -f $spec ]] || continue
  name=$(basename "$spec")
  work=$(mktemp -d)
  # Review state goes to a directory of its own, never to the user's real one
  # and never into the fixture repository.
  state=$(mktemp -d)
  fixture "$work"
  echo "== $name"
  code=0
  out=$(cd "$work" && XDG_STATE_HOME=$state WALKTHROUGH_STATE_DIR=$state/walkthrough \
    WALKTHROUGH_ROOT=$root WORK=$work timeout 180 nvim --headless -i NONE -n \
    --cmd "set rtp^=$root" -u "$root/tests/init.lua" \
    -c "luafile $spec" -c 'qall!' 2>&1) || code=$?
  rm -rf "$work" "$state"
  echo "$out"
  p=$(grep -c '^PASS' <<<"$out" || true)
  f=$(grep -c '^FAIL' <<<"$out" || true)
  # A file that crashed or hung never reaches its DONE line.
  if ! grep -q '^DONE' <<<"$out"; then
    echo "FAIL $name did not run to the end (exit code $code)"
    f=$((f + 1))
  fi
  passed=$((passed + p))
  failed=$((failed + f))
done

echo "total: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
