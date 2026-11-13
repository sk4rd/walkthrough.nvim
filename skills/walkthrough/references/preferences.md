# Teaching preferences

These are the author's own preferences. `SKILL.md` tells the agent to read
this file. Replace it with yours: the review method in `SKILL.md` and the
protocol in `format.md` do not depend on it.

## The learner

Check the agent's memory for the learner's level before explaining. Explain
what they are weak in, and skip what they know.

## Panel text

Per step, at most about 12 lines:

    # <step title>
    One or two sentences: what this code does and why it changed.
    ## Concepts
    - **`import`** (essential): evaluates a file, returns its value. [link]
    ## In use
    `path:line` + short snippet

- Name concepts by their real, searchable name. Essential ones get a
  sentence and a link. Look-up-later ones get one line.
- At most 2 "in use" examples, from this repository where possible.
- Show concepts in use, not trivial output. Include command output only when
  it reveals something the source does not.
- No analogies unless the learner asks for one.

## Links

Official sources only. Never invent a URL. If unsure, link a section or a
search page, or give the `:help` tag.

- Nix language: https://nix.dev/manual/nix/latest/language/
- Tutorials: https://nix.dev
- NixOS options and manual: https://search.nixos.org/options and the NixOS
  manual
- Library functions: https://noogle.dev
- Neovim: `:help <tag>`
- Lua: the Lua reference manual

## The map file

Save the map (groups, files, ranges, and a status for each group: not
started, in progress, understood, committed) to
`~/.claude/learning/<project>/review-<scope>.md`, outside the repository.
Keep it updated. It survives context compaction.

## Rules

- Never run `nixos-rebuild switch` (or any `switch`) without asking. Prefer
  `build`.
- "Skip the questions" means: just explain.

## Wrap-up

When all groups are done, ask the learner to summarise the architecture and
say how they would debug the most likely failure. Fill the gaps. List the
open decisions.
