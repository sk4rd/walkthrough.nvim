# walkthrough.nvim

Review code changes you didn't write by hand, one feature at a time, and
turn each feature into a clean commit. [Claude Code](https://claude.com/claude-code)
drives annotated tours of the diff in Neovim: highlighted code on the left,
an explanation panel on the right, numbered notes on the lines that matter.
You read, ask, approve by staging, and commit.

The repository has two halves:

| Path | What |
|---|---|
| `lua/walkthrough/` | the Neovim plugin: highlights, notes, panel, diff overlay, staging |
| `claude/skills/walkthrough/` | the Claude side: the `/walkthrough` skill, `tour.sh`, `commit-check.sh`, a hook |

Claude talks to Neovim over its server socket (`nvim --server … --remote-expr`).

## Requirements

- Neovim 0.10+
- [gitsigns.nvim](https://github.com/lewis6991/gitsigns.nvim) for staging
- [claudecode.nvim](https://github.com/coder/claudecode.nvim) to ask Claude about a note (optional)
- `git`, `jq`; `nix` for the build part of the commit check (optional)

## Install

### Neovim plugin

With Nix (flake input, no flake inside this repo):

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

Or any plugin manager. `setup()` is optional:

```lua
require('walkthrough').setup({
  panel_side = 'left', -- panel left of the code (default) or 'right'
  panel_width = 70,
  panel_min_width = 30, -- the panel never shrinks below this
  code_min_ratio = 0.5, -- the code window keeps at least half the screen
})
```

The default layout is `[ Claude | panel | code ]`, with the explanation in
the middle. For that, open the Claude terminal on the left, e.g. in
claudecode.nvim: `terminal = { split_side = 'left' }`.

### Claude side

Link `claude/skills/walkthrough` to `~/.claude/skills/walkthrough`, then add
the hook to `~/.claude/settings.json`:

```json
{ "hooks": { "UserPromptSubmit": [ { "hooks": [ {
  "type": "command",
  "command": "~/.claude/skills/walkthrough/hooks/visual-mode.sh",
  "timeout": 10
} ] } ] } }
```

The hook tells Claude on every prompt of a walkthrough session whether a
Neovim with the plugin is reachable, so it opens tours instead of
explaining in chat.

### Keys

The plugin defines no global keys (the panel's `<CR>` and `a` are local to
it). Suggested mappings:

```lua
local w = function(fn, ...) local a = { ... } return function() require('walkthrough')[fn](unpack(a)) end end
vim.keymap.set('n', ']w', w('step', 1), { desc = 'Next walkthrough step' })
vim.keymap.set('n', '[w', w('step', -1), { desc = 'Previous walkthrough step' })
vim.keymap.set('n', ']n', w('note', 1), { desc = 'Next walkthrough note' })
vim.keymap.set('n', '[n', w('note', -1), { desc = 'Previous walkthrough note' })
vim.keymap.set('n', '<leader>an', w('ask_line'), { desc = 'Ask Claude about the note on this line' })
vim.keymap.set('n', '<leader>gw', w('stage_group'), { desc = 'Stage walkthrough group in file' })
vim.keymap.set('n', '<leader>aw', w('close'), { desc = 'Close walkthrough' })
```

To let gitsigns' own staging register new files first (`git add -N`), wrap
it: `require('walkthrough').with_tracked(0, function() gitsigns.stage_hunk() end)`.

## Workflow

1. In Neovim, start Claude (claudecode.nvim) and run `/walkthrough`,
   optionally with a scope: `/walkthrough the vpn changes`.
2. Claude groups the changes by feature and suggests an order. Each group
   becomes one commit.
3. Claude opens a group as a tour. Page with `]w` / `[w` and `]n` / `[n`.
4. Ask about a note with `<leader>an` (or `a` in the panel). For SIMPLIFY /
   REMOVE notes the request is typed for you; edit it and press Enter.
5. Approve by staging: `<leader>gw` stages exactly this group's lines in the
   file. Green turns to muted ✓.
6. Run the commit check (`claude/skills/walkthrough/commit-check.sh`): what
   is staged, then a build of every NixOS host from exactly the index. Commit.

## What you see

| Mark | Meaning |
|---|---|
| blue `▎` bar | the lines this step is about |
| green line | change of this group, not staged |
| muted line + `✓` | change of this group, staged |
| red / grey `- old line` | deleted line, unstaged / staged |
| `·` + `→ group` | change of another group: leave it |
| `?` + `not in any group` | change the grouping missed |
| `⚠ mixed hunk` | one git hunk mixes groups: stage with `<leader>gw` or by selection |
| `1`, `KEEP`, `SIMPLIFY`, `REMOVE`, `DONE` | note number and verdict |

`:help walkthrough` has the full reference, including the step format.

## Tests

```sh
tests/run.sh
```

Runs headless in a throwaway git repository. The staging tests need
gitsigns.nvim on Neovim's packpath and are skipped without it.

## License

MIT
