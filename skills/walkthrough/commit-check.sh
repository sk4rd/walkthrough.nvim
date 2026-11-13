#!/usr/bin/env bash
# Check that what is staged would make a good commit on its own. Neovim runs
# it in the background for :Walkthrough commit (in the repository root); it can
# be run by hand too.
#
#   commit-check.sh              staged/unstaged summary, then run the check
#   commit-check.sh host ...     with the Nix check (3): build only these hosts
#
# Exit status: 0 when the check passed or none is defined, 1 when nothing is
# staged or the check failed.
#
# The check runs on exactly the index (git checkout-index into a temp dir), so
# it tests what the commit will contain, without touching the working tree.
# Which check runs, first match wins:
#   1. $WALKTHROUGH_CHECK            a command line, run with sh -c
#   2. .walkthrough/check            an executable file in the index
#   3. flake.nix                     builds every nixosConfigurations host
#                                    (a Nix example, used only when 1 and 2
#                                    are absent)
#   4. none                          prints "no check defined", exit 0
# Commands 1 and 2 run with the index checkout as working directory. If the
# check fails, it is run again on HEAD to tell a new failure from an old one.
# Prints a short summary; on a failure only the end of the output.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

echo "== staged (goes into the commit)"
git diff --cached --stat | tail -n 25
if git diff --cached --quiet; then
  echo "(nothing staged)"
  exit 1
fi

echo "== not staged (stays out)"
unstaged=$(git diff --name-only)
untracked=$(git ls-files --others --exclude-standard)
while IFS= read -r f; do
  [[ -n $f ]] && echo "  modified: $f"
done <<<"$unstaged"
while IFS= read -r f; do
  [[ -n $f ]] && echo "  untracked: $f"
done <<<"$untracked"
[[ -z $unstaged && -z $untracked ]] && echo "  (nothing)"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/walkthrough-check.XXXXXX")
base=
trap 'rm -rf "$tmp" ${base:+"$base"}' EXIT
git checkout-index -a --prefix="$tmp/"

# Export HEAD into a new temp dir ($base); false when there is no HEAD.
export_head() {
  git rev-parse --verify -q HEAD >/dev/null || return 1
  base=$(mktemp -d "${TMPDIR:-/tmp}/walkthrough-base.XXXXXX")
  git archive HEAD | tar -x -C "$base"
}

# ---- 1 and 2: a check the project defines

custom=
if [[ -n ${WALKTHROUGH_CHECK:-} ]]; then
  custom="env"
elif [[ -x $tmp/.walkthrough/check ]]; then
  custom="file"
fi

run_custom() { # run_custom <dir>; output on stdout and stderr
  if [[ $custom == env ]]; then
    (cd "$1" && sh -c "$WALKTHROUGH_CHECK") 2>&1
  else
    (cd "$1" && ./.walkthrough/check) 2>&1
  fi
}

if [[ -n $custom ]]; then
  echo "== running the check on the index"
  if log=$(run_custom "$tmp"); then
    echo "check ok"
    exit 0
  fi
  echo "check FAILED"
  echo "$log" | tail -n 30
  if ! export_head; then
    echo "== no HEAD to compare with"
  elif [[ $custom == file && ! -x $base/.walkthrough/check ]]; then
    echo "== the check does not exist at HEAD, nothing to compare with"
  elif run_custom "$base" >/dev/null; then
    echo "== the check passes at HEAD, so this commit breaks it"
  else
    echo "== the check fails at HEAD too: already broken, not caused by this commit"
  fi
  exit 1
fi

# ---- 3: build the NixOS hosts

if [[ ! -f $tmp/flake.nix ]]; then
  echo "== no check defined (set WALKTHROUGH_CHECK or add .walkthrough/check)"
  exit 0
fi

# Nix reports one root error and then a "dependency failed" error for every
# derivation above it. Keep only the root causes (failed builders, eval errors).
root_errors() {
  awk '
    /^error:/ { if (block != "" && block !~ /dependenc(y|ies) failed/) print block; block = $0; next }
    /^ / && block != "" { block = block "\n" $0; next }
    { if (block != "" && block !~ /dependenc(y|ies) failed/) print block; block = "" }
    END { if (block != "" && block !~ /dependenc(y|ies) failed/) print block }
  ' | tail -n 30
}

hosts=()
if (($# > 0)); then
  hosts=("$@")
else
  # Never hide the output: a flake that does not evaluate is the failure this
  # check exists for. Only a flake without the attribute has no hosts.
  if ! out=$(nix eval --raw "path:$tmp#nixosConfigurations" \
    --apply 'c: builtins.concatStringsSep "\n" (builtins.attrNames c)' 2>&1); then
    if grep -q 'does not provide attribute' <<<"$out"; then
      out=
    else
      echo "== listing the hosts FAILED: the flake in the index does not evaluate"
      echo "$out" | root_errors
      exit 1
    fi
  fi
  while IFS= read -r h; do
    [[ -n $h ]] && hosts+=("$h")
  done <<<"$out"
fi
if ((${#hosts[@]} == 0)); then
  echo "== no check defined (flake.nix has no nixosConfigurations)"
  exit 0
fi

build() { # build <flake dir> <host...>; prints the log on failure
  local dir=$1 h targets=()
  shift
  for h in "$@"; do
    targets+=("path:$dir#nixosConfigurations.$h.config.system.build.toplevel")
  done
  nix build --no-link --keep-going "${targets[@]}" 2>&1
}

echo "== building the index: ${hosts[*]}"
if log=$(build "$tmp" "${hosts[@]}"); then
  echo "build ok"
  exit 0
fi

# Which hosts failed, and were they already broken before this commit?
failed=()
for h in "${hosts[@]}"; do
  grep -q "nixos-system-$h-" <<<"$log" && failed+=("$h")
done
((${#failed[@]} == 0)) && failed=("${hosts[@]}") # eval error: no host named

echo "build FAILED for: ${failed[*]}"
echo "$log" | root_errors

if ! export_head; then
  echo "== no HEAD to compare with"
  exit 1
fi
for h in "${failed[@]}"; do
  if build "$base" "$h" >/dev/null; then
    echo "== $h builds at HEAD, so this commit breaks it"
  else
    echo "== $h fails at HEAD too: already broken, not caused by this commit"
  fi
done
exit 1
