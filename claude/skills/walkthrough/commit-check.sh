#!/usr/bin/env bash
# Check that what is staged would make a good commit on its own.
#
#   commit-check.sh              staged/unstaged summary, then build every
#                                nixosConfigurations host from the index
#   commit-check.sh host ...     build only these hosts
#
# The build uses exactly the index (git checkout-index into a temp dir), so
# it tests what the commit will contain, without touching the working tree.
# Prints a short summary; on a failed build only the end of the error.
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
[[ -n $unstaged ]] && echo "$unstaged" | sed 's/^/  modified: /'
[[ -n $untracked ]] && echo "$untracked" | sed 's/^/  untracked: /'
[[ -z $unstaged && -z $untracked ]] && echo "  (nothing)"

if [[ ! -f flake.nix ]]; then
  echo "== no flake.nix, skipping the build"
  exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
git checkout-index -a --prefix="$tmp/"

if (($# > 0)); then
  hosts=("$@")
else
  mapfile -t hosts < <(nix eval --raw "path:$tmp#nixosConfigurations" \
    --apply 'c: builtins.concatStringsSep "\n" (builtins.attrNames c)' 2>/dev/null || true)
fi
if ((${#hosts[@]} == 0)); then
  echo "== no nixosConfigurations found, skipping the build"
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

base=$(mktemp -d)
trap 'rm -rf "$tmp" "$base"' EXIT
git archive HEAD | tar -x -C "$base"
for h in "${failed[@]}"; do
  if build "$base" "$h" >/dev/null; then
    echo "== $h builds at HEAD, so this commit breaks it"
  else
    echo "== $h fails at HEAD too: already broken, not caused by this commit"
  fi
done
exit 1
