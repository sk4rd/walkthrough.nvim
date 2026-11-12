---
name: walkthrough
description: Walk the user through code changes that already exist (uncommitted diff, a commit range, or a branch) so they understand and can review them. Use when the user invokes /walkthrough or says they need help reviewing or understanding existing or vibe-coded changes.
---

Help a learner understand code they did not write by hand, so they can
explain, defend or remove each change, and turn it into clean commits.
Scope: $ARGUMENTS (default: the uncommitted diff). Check memory for their
level; explain what they are weak in, skip what they know.

## 1. Map (no edits)
- Read `git status`, `git diff HEAD --stat` and `git diff HEAD -U0`
  (staged, unstaged and untracked). Group changes by intent, not file
  (e.g. "replace Plasma with Noctalia").
- Assign every hunk to a group as line ranges per file (current line
  numbers); split a hunk serving two groups by line. Anything fitting no
  group becomes its own group or is flagged, never dropped.
- One group = one commit that builds on its own; order groups so
  dependencies are committed first.
- Staging means "approved for this commit". If the index already has staged
  changes, offer `git reset` (index only) plus `git add -N <new files>` so
  the flake still sees them. Ask first.
- Save the map (groups, files, ranges, status: not started / in progress /
  understood / committed) to `~/.claude/learning/<project>/review-<scope>.md`,
  outside the repo. Keep it updated; it survives context compaction.
- Present the groups (one line and size each), recommend an order (smallest
  self-contained first unless the user names one), let the user choose.

## 2. One group at a time
- GOAL: what the group achieves, in plain words.
- WALK: chunks in logical order, not file order: what, why, how it connects.
- JUDGE: verdict per chunk (keep, simplify, remove) with the reason. Hunt
  for unused options, duplicated logic, leftovers of the old approach,
  unrequested behavior, hardcoded values. Don't defend the code by default.
- VERIFY: say how to confirm it works; run what is safe.
- CHECK: one question on intent, data flow or a failure mode (none for
  trivial chunks). On a wrong answer, hint; don't reveal.
- DECIDE: ask what to do with flagged chunks. Edit only when asked, one small
  change at a time.
- COMMIT: when the user has staged the group, run `<base dir>/commit-check.sh`
  (they may run it themselves with `<leader>gk` and send you the output).
  It lists staged vs unstaged files and builds every host from exactly the
  index, saying whether a failure is new or already broken at HEAD. Point
  out files from other groups or this group's missing ones, then propose a
  commit message. The user commits, or you when asked.
- Wait for "next" before the next group.

## Explaining
Panel (or chat) per step, at most ~12 lines:

    # <step title>
    One or two sentences: what this code does and why it changed.
    ## Concepts
    - **`import`** (essential): evaluates a file, returns its value. [link]
    ## In use
    `path:line` + short snippet

- Concepts by their real searchable name. Essential ones get a sentence and
  a link; look-up-later ones one line. At most 2 in-use examples, from this
  repo where possible.
- Links from official sources only: https://nix.dev/manual/nix/latest/language/,
  nix.dev, the NixOS manual, https://noogle.dev, https://search.nixos.org/options,
  Neovim `:help <tag>`, the Lua manual. Never invent a URL; if unsure, link a
  section or search page, or the `:help` tag.
- Show concepts in use, not trivial output; include output only when it
  reveals what the source doesn't. No analogies unless asked.

## Visual mode (Neovim)
Visual mode is the default. A hook (`hooks/visual-mode.sh`) adds "Walkthrough
visual mode is ON/OFF" to every prompt of a walkthrough session; follow it.
Without that note, run `<base dir>/tour.sh --status` yourself: if it prints
JSON, use visual mode for every group without asking. Only an
error ("no running Neovim", several Neovims) means chat mode or asking which
one. Never decide from `$NVIM` or guesses; run the check.
Send each group as ONE tour with `tour.sh`, in one call: every call jumps
to its last step.

    <base dir>/tour.sh - <<'EOF'
    { "group": "Noctalia replaces Plasma",
      "steps": [{
        "file": "/absolute/path.nix",
        "title": "the bar config",
        "from": 10, "to": 20,
        "hunks": [{ "from": 10, "to": 20, "group": "Noctalia replaces Plasma" },
                  { "from": 41, "to": 41, "group": "Shared LAN constants" }],
        "notes": [{ "line": 12, "text": "few words", "verdict": "simplify",
                    "detail": "the explanation" }],
        "panel": "markdown, see Explaining"
    }] }
    EOF

- Only `file` is required (absolute; lines 1-based, inclusive). `from`/`to`
  is the focus. Notes are numbered and get a `### [n]` panel section
  (`detail`, else `text`). Verdicts: keep, simplify, remove, done.
- `hunks` lists EVERY change in the file by group, from the map, and turns
  on the diff overlay (all uncommitted changes vs HEAD; staged ones muted
  with ✓). Other groups are dimmed `→ group`, unlisted changes get `? not
  in any group` (fix the map), mixed unstaged hunks `⚠`. A deletion belongs
  to the range containing the line it is shown on. Use it for new files
  too. `"diff": "<ref>"` instead gives a plain diff against a ref. For a
  deleted file, tour `git show HEAD:<path>` written to a temp file.
- The user pages with `]w`/`[w` and `]n`/`[n`, so each step must stand
  alone. In chat give a short overview and the CHECK question, then wait.
- The user stages (their decision): `<leader>gw` stages this group's ranges
  in the file, `<leader>gh` a hunk or selection. `a` in the panel or
  `<leader>an` on a code line asks you about a note: you get a
  `*-walkthrough-note.md` (step, note, verdict, detail) plus an `@file#L`
  reference, and for simplify/remove notes a typed request like "Apply the
  simplification from note [n]".
- After ANY edit to a toured file, even one moving no lines (a rename),
  update the tour with `tour.sh --patch -` (never resend it): fix line
  numbers and every note and panel describing changed code. Mark applied
  suggestions `"verdict": "done"` with what changed in `detail`.

      [{ "step": 1, "note": 3, "verdict": "done", "text": "renamed",
         "detail": "Applied: ..." },
       { "step": 2, "from": 12, "to": 15, "panel": "..." }]

  `step` defaults to the current one; a note `n+1` with `line` adds one,
  `"remove": true` drops one. Step fields: file, title, from, to, diff,
  hunks, notes, panel, group. The overlay redraws itself.
- Output is `ok` or `error: ...`; fix and resend. `--status` prints the
  current step, `--close` ends the tour. Several Neovims: ask which, then
  set `WALKTHROUGH_NVIM=<socket>`.

## Rules
- No edits unless asked. Never `switch` without asking; prefer `build`.
- Don't claim the user understands what they haven't shown.
- Admit when you can't tell why something is there.
- "skip the questions" means just explain.

## 3. Wrap-up
When all groups are done, have the user summarize the architecture and how
to debug the most likely failure; fill gaps. List open decisions.
