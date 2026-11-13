# walkthrough.nvim

Review code changes you did not write by hand, one feature at a time, and
turn each feature into a clean commit. A coding agent explains the diff as
annotated tours inside Neovim. You read, ask, answer questions, and approve
a feature by staging it.

## What a review looks like

1. **Map.** You ask your agent to review the changes (with Claude Code:
   `/walkthrough`). The agent sorts the diff by intent into groups, one
   group per commit, and proposes an order.
2. **Tour.** The agent sends a group to Neovim. Each step opens a file, marks
   the lines it is about, draws the uncommitted diff over the code and shows
   numbered notes and an explanation in a panel. Page with `]w` and `]n`
   (see [Keys](#keys)).
3. **Ask and comment.** Press `a` in the panel, or run `:Walkthrough ask`, to
   ask about a note. Run `:Walkthrough comment` to write a question, an issue
   or a suggestion on any line. `:Walkthrough send` gives them to the agent,
   which answers in place, next to the code.
4. **Check.** Important steps carry a question about intent or a failure mode.
   Think first, answer with `e`, then reveal the answer with `r`.
5. **Decide.** Each note has a verdict (`KEEP`, `SIMPLIFY`, `REMOVE`, `MOVED`)
   and an evidence label (`ran`, `read`, `opinion`). `:Walkthrough decide
   accept` or `reject` tells the agent what you think of it.
6. **Stage.** `:Walkthrough stage` stages exactly the lines of this group
   ([`git add`](https://git-scm.com/docs/git-add)), even when another group
   changed the same file. Green lines become muted lines with a check mark.
7. **Commit check.** The agent runs `commit-check.sh`. It tests exactly what is
   staged, in a temporary copy of the index, and says whether a failure is new
   or was there before.
8. **Commit.** You commit, then take the next group.

**Incremental variant**, while the agent is still working: the agent runs
`tour.sh --snapshot` at the start and after each chunk you reviewed
(`:Walkthrough reviewed` does the same from Neovim). Tours then use
`"diff": "refs/walkthrough/reviewed"` and show only what changed since.
See `:help walkthrough-incremental`.

## Requirements

- Neovim 0.10 or newer, and `git`.
- [gitsigns.nvim](https://github.com/lewis6991/gitsigns.nvim) for staging,
  rejecting and the staged counter.
- Optional: [claudecode.nvim](https://github.com/coder/claudecode.nvim) to send
  requests to Claude Code; `jq` for the Claude Code hook; `nix` for the Nix
  example of the commit check.

`:checkhealth walkthrough` shows what is missing.

## Install

### The plugin

With any plugin manager. For example with
[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{ 'sk4rd/walkthrough.nvim', dependencies = { 'lewis6991/gitsigns.nvim' },
  opts = { keys = true } }
```

With Nix, as a flake input without a flake of its own:

```nix
# flake.nix
inputs.walkthrough-nvim = { url = "github:sk4rd/walkthrough.nvim"; flake = false; };

# wherever you build Neovim
plugins = [
  (pkgs.vimUtils.buildVimPlugin {
    pname = "walkthrough-nvim";
    version = "unstable";
    src = inputs.walkthrough-nvim;
  })
];
```

`setup()` is optional. The options are in the table below.

### The skill

The agent side is a skill in the [Agent Skills](https://agentskills.io/specification)
layout: `skills/walkthrough/` with `SKILL.md`, `references/`, `tour.sh` and
`commit-check.sh`. Link that directory into the skills directory of your
agent. For Claude Code:

```sh
ln -s "$PWD/skills/walkthrough" ~/.claude/skills/walkthrough
```

The old path `claude/skills/walkthrough` is a symlink to it and still works.

`references/preferences.md` holds the author's teaching style (learner level,
panel template, link sources, a notes file). `SKILL.md` tells the agent to
read it. Replace it with your own.

Optional, Claude Code only: `skills/walkthrough/hooks/visual-mode.sh` is a
`UserPromptSubmit` hook that tells Claude on each prompt of a walkthrough
session whether Neovim is reachable. Without it the skill runs
`tour.sh --status` itself. To use it, add to `~/.claude/settings.json`:

```json
{ "hooks": { "UserPromptSubmit": [ { "hooks": [ {
  "type": "command",
  "command": "~/.claude/skills/walkthrough/hooks/visual-mode.sh",
  "timeout": 10
} ] } ] } }
```

## Setup options

| Option | Default | Meaning |
|---|---|---|
| `panel_side` | `'left'` | `'left'` or `'right'` of the code. Left gives `[ agent \| panel \| code ]` |
| `panel_width` | `70` | width of the panel |
| `panel_min_width` | `30` | the panel never shrinks below this |
| `code_min_ratio` | `0.5` | the code window keeps at least this share of the screen |
| `max_removed_lines` | `10` | deleted lines shown per hunk before `… N more` |
| `sender` | `'auto'` | `'auto'`, `'claudecode'`, `'terminal'`, `'clipboard'` or `function(msg)` |
| `terminal_pattern` | `{ 'claude', 'codex', 'opencode', 'gemini', 'aider', 'amp' }` | which terminal buffer is the agent (the default list matches `amp` as a whole word) |
| `state_dir` | `stdpath('state') .. '/walkthrough'` | where the review is saved |
| `keys` | `false` | `true` maps the [default keys](#keys) under `<leader>w`; a string is the prefix; `false` maps nothing |

## Commands

`:Walkthrough {subcommand}`, with completion.

| Subcommand | Does |
|---|---|
| `next`, `prev`, `back` | move between steps; `back` shows the current step again |
| `note-next`, `note-prev` | jump between notes |
| `group [name\|next\|prev\|n]` | switch between loaded tours, or list them |
| `ask` | ask the agent about the note on this line |
| `comment [question\|issue\|suggestion] [text]` | comment on this line, or on a range or selection |
| `comment-delete` | delete the comment here |
| `decide accept\|reject\|clear` | your stance on the verdict of this note |
| `send` | send new comments, decisions and check answers to the agent |
| `explain simpler\|deeper` | ask for a rewrite; the agent writes later steps at that level |
| `check reveal\|answer` | show the answer of the step's check, or type yours |
| `stage [all]` | stage the group in this file, or in every file of the tour |
| `reject` | discard the group's unstaged lines in this file (asks first) |
| `base` | show the file as it was before the change, in a float |
| `reviewed [name]` | record the working tree as `refs/walkthrough/<name>` |
| `keys` | show the key cheat sheet |
| `status` | one line about the review |
| `resume`, `discard`, `close` | bring back, delete or forget the saved review |

## Keys

Every action has a `<Plug>(walkthrough-...)` mapping; the list is in
`:help walkthrough-mappings`. The plugin maps no global key by default.
`keys = true` maps the keys below under the prefix `<leader>w`;
`keys = '<leader>r'` (any string) uses that prefix instead. A key is mapped
only if it is still free. `<leader>w?` shows a cheat sheet with the keys that
are mapped right now (`:Walkthrough keys` does the same).

| Key | Does | Key | Does |
|---|---|---|---|
| `]w` `[w` | next / previous step | `P-` | simpler |
| `]n` `[n` | next / previous note | `P+` `P=` | deeper |
| `Pw` | show the current step again | `Pr` | reveal the check |
| `P]` `P[` | next / previous tour | `Pe` | answer the check |
| `Pa` | ask | `Ps` | stage (this file) |
| `Pc` `Pi` `Pu` | comment: question / issue / suggestion | `PS` | stage all |
| `PX` | delete the comment here | `Px` | discard the group's unstaged lines |
| `Pm` | send to the agent | `Pb` | base view |
| `Py` `Pd` `P0` | accept / decline / clear the note's verdict | `Pv` | record a reviewed snapshot |
| | | `PR` `Pq` | resume / close |

`P` is the prefix. `]w`, `[w`, `]n` and `[n` do not use it.

In the panel: `<CR>` jumps to the note under the cursor, or opens a
`path:line`; `a` asks; `-` and `+` ask for a simpler or deeper explanation;
`r` and `e` reveal and answer the check; `s` and `S` stage; `y`, `d` and `u`
accept, decline and clear the note's verdict; `m` sends; `b` shows the base;
`x` discards the group's unstaged lines; `?` shows the cheat sheet.

The default layout is `[ agent | panel | code ]`: the panel sits left of the
code, next to an agent terminal on the far left. For claudecode.nvim that is
`terminal = { split_side = 'left' }`.

## What you see

| Mark | Meaning |
|---|---|
| blue `▎` bar | the lines this step is about |
| green line | change of this group, not staged |
| muted line and `✓` | change of this group, staged |
| `- old line` (red, or grey when staged) | deleted line |
| `·` and `→ group` | change of another group: leave it |
| `?` and `not in any group` | change the grouping missed |
| `?` and `stale range` | an edit cut into the range; the agent must update it |
| `⚠ mixed hunk` | one git hunk mixes groups: use `:Walkthrough stage` |
| number, `KEEP` `SIMPLIFY` `REMOVE` `DONE` | note number and verdict |
| `MOVED` (grey) | the code was only relocated, not changed |
| `ran` `read` `opinion` | how the agent knows what the note says |
| `(code changed)` | the line of the note was rewritten after the note was written |
| `» c1 question: …` and `↳ …` | your comment and the agent's answer |
| `✓ accepted` `✗ rejected` | your decision on a verdict |

## Using another agent than Claude Code

The tour side needs only a shell: `tour.sh` talks to Neovim's socket. Any
agent that can run commands and read `SKILL.md` can drive it.

- **Sending to the agent:** `sender` chooses how `ask`, `send` and `explain`
  reach it. `'terminal'` pastes into an agent running in a Neovim terminal
  buffer, `'clipboard'` copies, a function can do anything.
- **Pulling instead:** `tour.sh --inbox` prints what you wrote (comments,
  decisions, check answers) as JSON, so an agent without an editor
  integration can poll it. `--inbox --all` also lists open comments that were
  sent before.

## Tests

```sh
tests/run.sh       # the plugin, in headless Neovim; needs gitsigns.nvim
tests/scripts.sh   # tour.sh, commit-check.sh and the hook
```

`tests/docs_spec.lua` checks that the documents name every field, verdict,
subcommand and option the code has.

## More

- `:help walkthrough`: the full reference (`doc/walkthrough.txt`).
- `skills/walkthrough/references/format.md`: the protocol for the agent.
- `skills/walkthrough/SKILL.md`: the review method.

## License

MIT
