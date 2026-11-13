---
name: walkthrough
description: Walk the user through code changes that already exist (uncommitted diff, a commit range, or a branch) so they understand and can review them, one feature at a time, as tours in Neovim or in chat. Use when the user invokes /walkthrough or says they need help reviewing or understanding existing or agent-written changes.
---

Help a person understand code they did not write by hand, so they can
explain, defend or remove each change and turn it into clean commits.
Scope: $ARGUMENTS (default: the uncommitted diff).

Read `references/preferences.md` now: it holds the author's teaching style
(learner level, panel template, link sources). Users replace that file with
their own. The protocol (fields, patches, output of `--status` and
`--inbox`) is in `references/format.md`. Commands below are in this
directory: `tour.sh`, `commit-check.sh`.

## 0. Mode

Run `tour.sh --status` first. If it prints JSON, use visual mode: show every
group as a tour in Neovim, without asking. If it prints an error (no running
Neovim, several Neovims), use chat mode, or ask which Neovim and set
`WALKTHROUGH_NVIM=<socket>`. Never guess from `$NVIM`; run the command. (A
Claude Code hook, `hooks/visual-mode.sh`, can add the result to every prompt.
It is optional.)

## 1. Map (no edits)

- Read `git status`, `git diff HEAD --stat` and `git diff HEAD -U0` (staged,
  unstaged, untracked files).
- Group the changes by intent, not by file. One group is one commit that
  builds on its own. Order the groups so dependencies come first.
- List every changed range of every file in `hunks`, with its group. Split a
  hunk that serves two groups by line. Anything that fits no group becomes its
  own group or is flagged. Never drop it.
- Summarise generated and lock files (`flake.lock`, `package-lock.json`, ...)
  in one step instead of touring them.
- Detect moved code with `git diff -M --color-moved`. Give moved blocks a
  note with `"verdict": "moved"` so the user does not review them as new.
- Staging means "approved for this commit". If the index already holds
  staged changes, offer `git reset` (index only) and, for new files,
  `git add -N <file>`. Ask first.
- Present the groups: one line and a size each. Recommend an order (smallest
  self-contained first unless the user names one). Let the user choose.

## 2. One group at a time

Send the group as ONE tour, in one call. It opens at `start` (default: the
first step):

    tour.sh - <<'EOF'
    { "group": "Shared LAN constants",
      "steps": [{
        "file": "/absolute/path.nix", "title": "the constants",
        "from": 10, "to": 20,
        "hunks": [{ "from": 10, "to": 20, "group": "Shared LAN constants" },
                  { "from": 41, "to": 41, "group": "Other feature" }],
        "notes": [{ "line": 12, "text": "few words", "verdict": "simplify",
                    "evidence": "read", "detail": "the explanation" }],
        "panel": "markdown",
        "check": { "question": "...", "answer": "..." }
    }] }
    EOF

- Steps stand alone: the user pages through them in any order, so each one
  names its own context.
- Keep panel text short. Name each concept by its real, searchable name and
  link the official documentation the first time (see the preferences file).
  Do not use analogies unless asked.
- Walk the chunks in logical order, not file order: what, why, how it
  connects. Say how to verify it works, and run what is safe to run.
- Give each important step a `check`: one question on intent, data flow or a
  failure mode. The user sees the question; the answer stays hidden until they
  reveal it. Skip it for trivial steps. On a wrong answer, hint; do not reveal.
- Never claim the user understands something that `--status` does not show:
  `seen` (steps shown) and `check` (`open`, `revealed`, `answered`). Admit
  when you cannot tell why something is there.

## 3. Verdicts and evidence

- Judge each chunk: `keep`, `simplify`, `remove` (or `moved`). Look for
  unused options, duplicated logic, leftovers of the old approach,
  unrequested behaviour, hardcoded values. Do not defend the code by default.
- Where you can, get the verdicts from a second look with fresh context: a
  subagent or a separate review pass that did not write the code. The context
  that wrote the code tends to defend it.
- Label every note with `evidence`: `ran` (you ran something that shows it),
  `read` (you inferred it from the code) or `opinion`. Do not label a guess
  `ran`.
- Known limit: a deleted line counts as being on the line where it is
  shown, so a deletion next to another group's change cannot be split from
  it, and staging one group stages both. When that happens, say so in a note.

## 4. After edits and from the user

- After ANY edit to a toured file, run `tour.sh --status`. Positions follow
  edits by themselves; patch only what it lists under `stale`, and any note
  or panel text that describes code you changed. Use `tour.sh --patch -`,
  never resend the tour. Mark applied suggestions `"verdict": "done"` and say
  what changed in `detail`.
- Read the user's side with `tour.sh --inbox`:
  - a comment: answer it with a comment patch (`answer`); if you agree on an
    issue or suggestion, change the code first and set `resolved`;
  - an accepted `simplify` or `remove` decision: apply it, patch the note to
    `done`;
  - a rejected decision: leave the code as it is;
  - the answer to a check: patch your `feedback` into the check.
- Honour `depth` from `--status` (`simpler` or `deeper`) in later steps, and
  when asked to explain simpler or deeper.
- Edit code only when asked, one small change at a time.

## 5. Approve and commit

- Never stage, reject or commit for the user unless they ask. They approve a
  group with `:Walkthrough stage`; they may reject it with `:Walkthrough
  reject`.
- When a group is staged, run `commit-check.sh`. It lists staged and
  unstaged files and runs a check on exactly the index, saying whether a
  failure is new or already broken at HEAD. Point out files from other
  groups, or files of this group that are missing. Then propose a commit
  message. The user commits, or you when asked.
- The check is whatever the project defines, first match wins:
  `$WALKTHROUGH_CHECK` (a command line), an executable `.walkthrough/check`
  in the index, or (a Nix example) building every `nixosConfigurations` host.
  If none exists, say "no check defined" and explain that the user can add an
  executable `.walkthrough/check` that exits non-zero on failure.
- Wait for the user before the next group.

## 6. Incremental review (while you implement)

- At the start of a task run `tour.sh --snapshot`. After each chunk the user
  has reviewed, run it again to move the point forward.
- Tour only what changed since: map `git diff refs/walkthrough/reviewed` and
  give every step `"diff": "refs/walkthrough/reviewed"`. This works for files
  that are new too.

## Rules

- No edits unless asked. "Skip the questions" means: just explain.
- Output of `tour.sh` is `ok`, JSON or `error: ...`. Fix the JSON and resend:
  a failed load or patch changed nothing.
- A deleted file cannot be a step. Tour `git show HEAD:<path>` written to a
  temporary file.
- Refer to commands (`:Walkthrough stage`), not to key names: users map their
  own.
- When all groups are done, finish as `references/preferences.md` says.
