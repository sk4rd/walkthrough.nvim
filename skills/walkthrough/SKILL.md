---
name: walkthrough
description: Work with a user who reviews code in Neovim (walkthrough.nvim). Answer the questions and change requests they write on lines, propose before editing, build the map of a change (ordered commits that stand on their own), and write commit messages. Use when a message starts with "Walkthrough:", when the user says they sent something from Neovim, or when they ask to review, split or understand a change.
---

You work next to the user's Neovim. You do not lead a tour: you **answer what
the user writes** and you **propose before you edit**.

Read `references/preferences.md` (the user's own style: level, link sources,
how short to be) and `references/format.md` (the full protocol: fields,
patches, `--status`, `--inbox`). The commands are in this directory: `tour.sh`
and `commit-check.sh`.

Words: the **map** is the ordered list of commits of a change; a **commit**
is a set of lines that builds on its own; its **entries** are its files; a
**thread** is something the user wrote on lines, with the replies under it (a
**question** or a **change request**); a **finding** is your note with a
verdict. In JSON a commit has `group` and `steps`, and a finding is a `note`.

## 1. Mode

Run `tour.sh --status` first. JSON means Neovim is reachable: answer there.
An error means chat mode (no Neovim, or several): answer in chat, or ask which
Neovim and set `WALKTHROUGH_NVIM=<socket>`. Never guess from `$NVIM`; run the
command. (Claude Code only: the optional hook `hooks/visual-mode.sh` adds this
result to every prompt.)

## 2. A message from the user

A message that starts with `Walkthrough:` comes from the user's keys. Do what
its `Expected:` lines say. If the user only says they sent something, read
`tour.sh --inbox` (add `--all` for threads still waiting). Each item has a kind:

| Kind | Do | Reply (`tour.sh --patch -`) |
|---|---|---|
| `question` | answer at the user's level, short. Never change code for a question | `{ "thread": "t1", "answer": "..." }` |
| `change` (change request) | reply with a **proposal** and wait. Edit nothing. If `Expected:` says the user asks you to **revise** your proposal, reply with a new one, not an edit | `{ "thread": "t1", "answer": "<what you would change>", "proposal": true }` |
| `decision` accepted | apply the proposal (or the `simplify` / `remove` finding), then report | `{ "thread": "t1", "answer": "<what you changed>", "done": true }`; for a finding `{ "step": 2, "note": 1, "verdict": "done" }` |
| `decision` rejected | leave the code as it is | none |
| simpler / deeper | rewrite your last answer at that level; keep to it afterwards (`depth` in `--status`) | `{ "thread": "t1", "answer": "<new text>", "replace": true }`; for a finding patch its `detail` |
| `map` | build the map (next section) | `tour.sh` calls |
| `commit` | write the commit message. Only when this item arrives: never send one unasked | `{ "commit_message": "feat(net): ...", "group": "<commit>" }` |

Commit message rules, word for word: "Conventional Commits. One line. Add
further lines only when the change is really complex. Never add a
Co-authored-by line."

A list of patches is applied as a whole: answer several threads in one call.

The user collects change requests, replies and decisions and sends them
together (`send`, or `--inbox`): one message can hold all three kinds. A
decision reaches you only then, and it is final: nothing before it means
accepted. A thread you already closed (declined or done) can come back as a
`question` or `change` item, with the earlier messages: the user continued it.
Do what its `Expected:` line says.

## 3. Building the map

1. Read `git status`, `git diff <base> --stat` and `git diff <base> -U0`
   (`<base>` is in the request; `HEAD` by default). Include untracked files.
2. Sort the change into commits that each stand on their own, ordered so
   that nothing depends on a later commit. Several commits may touch the same
   file. Group by intent, not by file. Anything that fits no commit becomes its
   own commit; never drop it.
3. Send one `tour.sh` call per commit, in order. The first commit you send is
   the one the user sees; later ones are added to the map without switching
   their view. Sending a commit again replaces it where the user is. `group` is the commit's
   subject. The entries are its files in reading order, each with a
   one-sentence `title` and `hunks` that assign **every** changed line of
   that file to a commit: its own lines, and the lines of other commits with
   their `group`. If `<base>` is not `HEAD`, give each entry `"diff": "<base>"`.
4. A generated or lock file (`flake.lock`, `package-lock.json`) gets one entry
   and one sentence.
5. Add findings as `notes` with a `verdict` (`keep`, `simplify`, `remove`,
   `moved`) and `evidence` (`ran`, `read`, `opinion`). Never label a guess
   `ran`. Where you can, get the verdicts from a second look with fresh
   context (a subagent or a separate pass that did not write the code): the
   context that wrote the code tends to defend it. Find moved code with
   `git diff -M --color-moved` and give it `"verdict": "moved"`.
6. The limit: a deleted line cannot be assigned on its own. A deletion next to
   another commit's change goes with that change. Say so in a note.

## 4. After any edit

Run `tour.sh --status` and patch what it lists under `stale`, and any `title`
or note that describes code you changed. Positions otherwise follow edits by
themselves. Use `tour.sh --patch -`; never resend the whole commit for this.

## 5. What only the user does

Staging, rejecting, committing and approving a plan. You never stage or
commit; the user's commit command runs the check and makes the commit. Refer
to commands (`:Walkthrough stage`), never to key names: users map their own.

## 6. The commit check

`commit-check.sh` runs on exactly the index (a copy in a temporary
directory). It lists staged and unstaged files, then runs the project's
check; if it fails, it runs it on HEAD to tell a new failure from an old one.
The check is, first match wins: `$WALKTHROUGH_CHECK` (a command line), an
executable `.walkthrough/check` in the index, or (a Nix example) a build of
every `nixosConfigurations` host. With none it says "no check defined"; the user
can add an executable `.walkthrough/check` that exits non-zero on failure.

## 7. Plan review (Claude Code)

With the optional hook `hooks/plan-review.sh`, leaving plan mode opens your plan
in Neovim. If leaving plan mode is denied with a message that lists the user's
annotations, answer each one with a thread patch, revise the plan, and present
it again. The review continues in the same tab.

## 8. Existing code

Questions can arrive for files that are in no map (`Other files` in `group`).
Answer them the same way with a thread patch. No map is needed.

## 9. Rules

- No edits unless a proposal was accepted or the user asked for one in chat.
- A failed `tour.sh` call changed nothing: read the error, fix, resend.
- Do not say the user understood or read something that `--status` does not
  show (`seen`). Admit when you cannot tell why code is there.

## Example

One commit of the map:

    tour.sh - <<'EOF'
    { "group": "Share the LAN constants",
      "steps": [{
        "file": "/abs/net.nix", "title": "the constants move into one set",
        "hunks": [{ "from": 10, "to": 20 },
                  { "from": 41, "to": 41, "group": "Use the constants in the firewall" }],
        "notes": [{ "line": 12, "text": "one use only", "verdict": "simplify",
                    "evidence": "read", "detail": "Inline it: nothing else reads it." }]
      }] }
    EOF

The patch forms you use most (each is its own call, or an item of one list):

    tour.sh --patch - <<'EOF'
    [ { "thread": "t1", "answer": "A set groups related values under one name. See ..." },
      { "thread": "t2", "answer": "I would inline it in two places.", "proposal": true },
      { "thread": "t2", "answer": "Done: inlined in net.nix and host.nix.", "done": true },
      { "thread": "t3", "answer": "Shorter: ...", "replace": true },
      { "commit_message": "refactor(net): share the LAN constants", "group": "Share the LAN constants" } ]
    EOF
