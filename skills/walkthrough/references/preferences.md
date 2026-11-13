# Preferences

These are the author's own preferences. `SKILL.md` tells the agent to read
this file. Replace it with yours: the method in `SKILL.md` and the protocol in
`format.md` do not depend on it.

## The learner

Check the agent's memory for the learner's level before explaining. Explain
what they are weak in, and skip what they know.

## Answer style

An answer under a line is short:

- One to three sentences.
- Name the concept by its real, searchable name.
- When a concept is new, give one official link.
- Give one example from this code.

Show concepts in use, not trivial output. Include command output only when it
reveals something the source does not. No analogies unless the learner asks
for one. A longer explanation belongs in a finding's `detail`, or in an answer
after the learner asked for it ("deeper").

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

## The notes file

Save the map (commits, files, ranges, and a status for each commit: not
started, in progress, understood, committed) to
`~/.claude/learning/<project>/review-<scope>.md`, outside the repository.
Keep it updated. It survives context compaction.

## Rules

- Never run `nixos-rebuild switch` (or any `switch`) without asking. Prefer
  `build`.
- "Skip the questions" means: just explain.

## Wrap-up

When all commits are done, ask the learner to summarise the architecture and
say how they would debug the most likely failure. Fill the gaps. List the
open decisions.
