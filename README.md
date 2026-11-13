# walkthrough.nvim

In Neovim, annotate an agent's plan, its change, or any code; the working
agent session answers and proposes next to the line; approved work becomes
small commits that stand on their own.

Words used below. The **map** is the ordered list of commits of a change, each
with its files and one sentence per file. A **commit** is a set of lines, maybe
from several files and only part of a file, that builds on its own; commits are
ordered so that nothing depends on a later one. A **thread** is something you
wrote on lines, with the replies under it: a **question** or a **change
request**. A **finding** is a remark of the agent on a line, with a verdict
(`keep`, `simplify`, `remove`, `moved`) and how it knows (`ran`, `read`,
`opinion`). The **compact view** and the **file view** are the two ways to look
at a change.

The **working session** is the agent session next to Neovim. If it is busy,
your message waits and the thread shows "waiting". The agent never stages,
commits or edits on its own: edits follow a proposal you accepted, commits
follow your confirmation.

## The three scenarios

`P` in the keys is the prefix, `<leader>w` with `keys = true`.
### Review a finished change

1. `Pr` (`:Walkthrough review`) lists the changed files from git. No agent is
   involved. Nothing opens on its own.
2. `PM` (`:Walkthrough request`) asks the working session for the map: ordered
   commits, one sentence per file, every changed line assigned to a commit,
   and findings.
3. Read in the compact view. `]w` `[w` move between entries, `P]` `P[` between
   commits, `Pv` jumps to the same line in the real file and back. Lines of
   other commits are dimmed and labelled; lines in no commit are flagged.
4. Annotate. `Pa` asks a question; the answer appears under the line.
   `Pc` writes a change request; it is collected, `Pm` sends all of them, and
   the agent replies to each with a proposal. `Py` accepts a proposal or a
   finding, `Pd` declines it. A decision is collected too: the label says
   `(accepted, not sent)`, you can change it or take it back with `P0`, and
   `Pm` sends it together with the change requests. To ask for a different
   proposal, write on the lines again (`Pa`, `Pc` or `r` in the thread float):
   your message goes into the same thread. Writing on a declined or done
   thread continues it. The text is typed in a small centered window: `<CR>`
   sends, `<C-j>` starts a new line, `<Esc>` in Normal mode or `q` cancels.
   `P-` and `P+` ask for a simpler or a deeper answer; the level is
   remembered. `Pt` opens a long thread in full.
5. `Ps` stages the lines of the current commit in this file, `PS` in every
   file ([`git add`](https://git-scm.com/docs/git-add)), also where a file
   holds lines of other commits. `Px` discards the commit's unstaged lines.
6. `PC` commits. The project's check runs on exactly what is staged, you write
   the message or ask the agent for one with `<C-g>`, Neovim runs
   [`git commit`](https://git-scm.com/docs/git-commit). A failing check is
   shown but does not block. Then the commit's threads are deleted and the next
   commit is current.

When the agent sends the map as several commits, the first one is the current
one. A later commit is added to the map without changing the view, and a
notification names it. Go to it with `P]` or `<CR>` in the map.

### Ask about existing code

With no review open, `Pa` works on any line of any saved file in a repository.
It starts a session silently: no map, no panel, only threads under lines. They
survive a restart and are deleted when you close the session with `Pq`.

### Review a plan

When the agent leaves plan mode, a hook hands the plan to Neovim and the agent
waits. The plan opens in a new tab. Write questions (`Pa`) and change requests
(`Pc`) on its lines. Press `A` to approve, or `F` to send your annotations back.
The agent revises the plan and shows it again in the same tab, with its replies
under your lines. Without a reachable Neovim, the agent's normal prompt
appears. Claude Code first; the hook is the only part specific to it.

## Requirements

- Neovim 0.10 or newer, and `git`.
- [gitsigns.nvim](https://github.com/lewis6991/gitsigns.nvim) for staging,
  reject and the staged counter.
- Optional: [claudecode.nvim](https://github.com/coder/claudecode.nvim) to send
  messages to Claude Code; `jq` for the Claude Code hooks; `nix` for the Nix
  example of the commit check. `:checkhealth walkthrough` shows what is missing.

## Install

### The plugin

With any plugin manager, for example [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{ 'sk4rd/walkthrough.nvim', dependencies = { 'lewis6991/gitsigns.nvim' },
  opts = { keys = true } }
```

With Nix, as a flake input without a flake of its own, built with
`pkgs.vimUtils.buildVimPlugin`:

```nix
inputs.walkthrough-nvim = { url = "github:sk4rd/walkthrough.nvim"; flake = false; };
# plugins = [ (pkgs.vimUtils.buildVimPlugin {
#   pname = "walkthrough-nvim"; version = "unstable"; src = inputs.walkthrough-nvim; }) ];
```

`setup()` is optional, but call it to get your threads back after a restart.

### The skill

The agent side is a skill in the [Agent Skills](https://agentskills.io/specification)
layout (`skills/walkthrough/`: `SKILL.md`, `references/`, `tour.sh`,
`commit-check.sh`). Link it into the skills directory of your agent. For Claude
Code:

```sh
ln -s "$PWD/skills/walkthrough" ~/.claude/skills/walkthrough
```

The old path `claude/skills/walkthrough` is a symlink to it and still works.
Replace `references/preferences.md` (the author's own style) with yours.

### Two optional hooks (Claude Code)

Both are [hooks](https://code.claude.com/docs/en/hooks), set in
`~/.claude/settings.json` (timeouts in seconds). `hooks/plan-review.sh` is a
`PermissionRequest` hook for `ExitPlanMode`; it opens the plan in Neovim and
waits for you:

```json
{ "hooks": { "PermissionRequest": [ { "matcher": "ExitPlanMode", "hooks": [
  { "type": "command", "command": "~/.claude/skills/walkthrough/hooks/plan-review.sh",
    "timeout": 86400 } ] } ] } }
```

`hooks/visual-mode.sh` is a `UserPromptSubmit` hook that tells Claude, on each
prompt of a session that uses the skill, whether Neovim is reachable (without it
the skill runs `tour.sh --status` itself):

```json
{ "hooks": { "UserPromptSubmit": [ { "hooks": [
  { "type": "command", "command": "~/.claude/skills/walkthrough/hooks/visual-mode.sh",
    "timeout": 10 } ] } ] } }
```

## Setup options

| Option | Default | Meaning |
|---|---|---|
| `panel_side` | `'left'` | `'left'` or `'right'` of the code. Left gives `[ agent \| panel \| code ]` (claudecode.nvim: `terminal = { split_side = 'left' }`) |
| `panel_width` | `40` | width of the map panel |
| `panel_min_width` | `30` | the panel never shrinks below this |
| `code_min_ratio` | `0.5` | the code window keeps at least this share of the screen |
| `max_removed_lines` | `10` | deleted lines shown per hunk in the file view before `… N more` |
| `view` | `'compact'` | the view a review opens in: `'compact'` or `'file'` |
| `sender` | `'auto'` | `'auto'`, `'claudecode'`, `'terminal'`, `'clipboard'` or `function(msg)` |
| `submit` | `true` | `true`: a message is submitted and the focus stays; `false`: typed only, the focus moves to the agent |
| `input` | `'float'` | where text is typed: `'float'` (a centered window) or `'ui'` (`vim.ui.input`, for your own input UI) |
| `terminal_pattern` | `{ 'claude', 'codex', 'opencode', 'gemini', 'aider', 'amp' }` | which terminal buffer is the agent (`amp` matches as a whole word) |
| `state_dir` | `stdpath('state') .. '/walkthrough'` | where the review is saved |
| `keys` | `false` | `true` maps the keys below under `<leader>w`; a string is the prefix; `false` maps nothing |

## Keys

Every action has a `<Plug>(walkthrough-...)` mapping and a `:Walkthrough`
subcommand; both are listed in `:help walkthrough-mappings` and
`:help walkthrough-commands`. The plugin maps no global key by default. A key
is mapped only if it is still free. `P?` (`:Walkthrough keys`) shows a cheat
sheet with the keys that are mapped right now. `]w` `[w` `]n` `[n` do not use
the prefix.

| Group | Keys |
|---|---|
| Start | `Pr` review, `PM` request (ask the agent for the map), `PR` resume, `Pq` close |
| Move | `]w` `[w` next / previous entry, `]n` `[n` next / previous thread or finding, `P]` `P[` next / previous commit, `Pv` switch compact / file view, `Pp` map panel, `Pw` back to the current entry |
| Write | `Pa` ask (also on a selection), `Pc` change request (also on a selection), `Pm` send, `Pt` open the thread, `PX` delete the thread, `P-` simpler, `P+` `P=` deeper |
| Decide | `Py` accept, `Pd` decline, `P0` clear (all three only mark; `Pm` sends) |
| Approve | `Ps` stage, `PS` stage all, `Px` reject (discard the commit's unstaged lines), `Pb` base, `PC` commit |
| Plan | `PA` approve the plan, `PF` send plan feedback |
| Help | `P?` cheat sheet |

Panel: `<CR>` opens the entry, `s` `S` stage, `m` sends, `b` base, `x` reject,
`?` cheat sheet. Thread float (`Pt`): `r` replies, `y` `d` accept / decline,
`u` takes the decision back, `-` `+` `=` simpler / deeper, `X` deletes, `q`
closes. Input window: `<CR>` sends, `<C-j>` new line, `<Esc>` (Normal mode) or
`q` cancels. Plan: `A` approves, `F`
sends feedback. Commit dialog: `<CR>` or `:w` commits, `<C-g>` asks the agent
for a message, `<C-r>` takes a message the agent proposed while you typed, `q`
cancels.

## What you see

**Compact view** (the default): one read-only buffer with the changed parts of
the current commit's files. Each file has a heading with its sentence, then its
hunks with 3 lines of context and `⋯` between them:

```
backup.sh  ·  the destination can be set from outside
   8   fi
     - dest=/tmp/backups
  10 + dest=${BACKUP_DIR:-/tmp/backups}
  11
```

**File view**: the real file, editable, with LSP, and the diff drawn over it.
`Pv` switches at the same line. Every action works in both views. **Map panel**
(`Pp`): every loaded commit with its files, the lines staged per file (`2/3`)
and the sentence below; `>` marks the entry on screen, `✓` the entries you saw;
`Other files` is the last heading: threads on files in no map.

| Mark | Meaning |
|---|---|
| green line | change of this commit, not staged |
| muted line and `✓` | change of this commit, staged |
| `- old line` (red, or grey when staged) | deleted line |
| `·` and `→ commit` | change of another commit: leave it |
| `?` and `not in any commit` / `stale range` | a change the map did not assign / an edit cut into the range |
| number, `KEEP` `SIMPLIFY` `REMOVE` `DONE` `MOVED` | a finding and its verdict; its `detail` follows, dimmed |
| `ran` `read` `opinion`, `✓ accepted` `✗ rejected` | how the agent knows; your decision on a finding (`, not sent` until `Pm`) |
| `» t1 (waiting) you: …` and `↳ …` | your thread and the agent's last message |

A thread's label after its id says where it stands: `(not sent)` (a change
request waiting for `Pm`), `(waiting)`, `(proposal)` (accept or decline it),
`(accepted, not sent)` and `(declined, not sent)` (marked, `Pm` sends it),
`(accepted)` and `(declined)` (sent), `(done)`. An answered thread has no
label. `(code
changed)` means the lines were rewritten after the thread was written; a thread
longer than 6 lines ends with `… full thread: <key>`.

## Using another agent than Claude Code

Everything the agent does goes through a shell script: `tour.sh` talks to
Neovim's server socket (`:help --listen`, `:help --remote-expr`). Any agent
that can run commands and read `SKILL.md` can drive it.

- **Sending to the agent:** `sender` chooses how your messages reach it:
  `'terminal'` pastes into an agent in a Neovim terminal buffer, `'clipboard'`
  copies, a function can do anything.
- **Pulling instead:** `tour.sh --inbox` prints what you wrote (questions,
  change requests, decisions, requests for a commit message or for the map) as
  JSON, so an agent without an editor integration can poll it. `--inbox --all`
  also lists the threads that wait for an answer.

## Tests and more

`tests/run.sh` runs the plugin in headless Neovim (it needs gitsigns.nvim);
`tests/scripts.sh` tests `tour.sh`, `commit-check.sh` and the hooks.
`tests/docs_spec.lua` checks that the documents name what the code has.

- `:help walkthrough`: the full reference (`doc/walkthrough.txt`).
- `skills/walkthrough/references/format.md`: the protocol for the agent.
- `skills/walkthrough/SKILL.md`: how the agent works with you.

License: MIT
