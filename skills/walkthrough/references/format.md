# Protocol reference

The full reference is `:help walkthrough` (file `doc/walkthrough.txt`). This
file is the short copy for the agent. A test checks that every field the
plugin accepts is named here.

All commands are `tour.sh` (next to `SKILL.md`). Each prints Neovim's answer
and exits non-zero on `error: ...`. Several Neovims: set
`WALKTHROUGH_NVIM=<socket>`.

| Command | Does |
|---|---|
| `tour.sh file.json` or `tour.sh -` (stdin) | send a tour, or one step |
| `tour.sh --patch file.json` or `--patch -` | change the tour in place |
| `tour.sh --status` | where the user is (JSON) |
| `tour.sh --inbox [--all]` | what the user wrote since the last call (JSON) |
| `tour.sh --snapshot [name]` | record the working tree as `refs/walkthrough/<name>` |
| `tour.sh --close` | clear the screen and forget the tours |

## Errors

The answer is `ok`, JSON, a commit id, or `error: <one line>`. A failed load
or patch changed nothing: read the line, fix the JSON, send it again. Unknown
fields are errors, so a typo is reported. Lines are 1-based and inclusive and
mean the file as it is on disk now. Text fields take a string or a list of
strings (one per line).

## Tour

```json
{ "group": "Shared LAN constants", "start": 1, "steps": [ ... ] }
```

| Field | Type | Rule |
|---|---|---|
| `group` | string | name of the tour; the default `group` of its steps |
| `steps` | list | required, not empty |
| `start` | integer | 1 or more; the step shown first |

Sending a tour with the same `group` replaces the loaded one and keeps what
the user did (seen steps, comments, check answers). A different `group` is a
separate tour. A file with no `steps` is one step; it is appended to the
active tour.

## Step

| Field | Type | Rule |
|---|---|---|
| `file` | string | required; an existing file; use an absolute path |
| `title` | string | shown in the winbar |
| `group` | string | default: the tour's `group` |
| `total` | number | step count to show when more steps will follow |
| `from` | integer | 1 or more; first line of the focus |
| `to` | integer | `from` or more; needs `from` |
| `diff` | `true`, `false` or a git ref | `true`: uncommitted changes against HEAD, staged lines muted. A ref (string): plain diff against it. Default `true` when `hunks` is given |
| `hunks` | list of hunks | every changed range of the file, by group |
| `notes` | list of notes | |
| `panel` | text | markdown explanation |
| `check` | check | a question for the user |

## Hunk

| Field | Type | Rule |
|---|---|---|
| `from` | integer | required; 1 or more |
| `to` | integer | `from` or more; default `from` |
| `group` | string | default: the step's `group` |

Ranges of one step must not overlap. Changed lines in a range of the step's
group are drawn in full; in another group's range they are dimmed; in no
range they are flagged. A deleted line counts as being on the line where it
is shown, so it cannot have a group of its own.

## Note

| Field | Type | Rule |
|---|---|---|
| `line` | integer | required; 1 or more; not past the end of the file |
| `text` | text | a few words, drawn under the line |
| `detail` | text | longer explanation; the panel shows it instead of `text` |
| `verdict` | string | `keep`, `simplify`, `remove`, `done`, `moved` |
| `evidence` | string | `ran`, `read`, `opinion` |

Notes are numbered 1, 2, ... in list order. Numbers are stable: a patch never
renumbers them and never reuses one.

Verdicts: `keep` (fine as it is), `simplify`, `remove`, `done` (a suggestion
that was applied), `moved` (code that was only relocated).
Evidence: `ran` (you ran something that shows it), `read` (inferred from
reading), `opinion` (a judgement).

## Check

| Field | Type | Rule |
|---|---|---|
| `question` | text | required; not empty |
| `answer` | text | hidden until the user reveals it |
| `feedback` | text | your remark on the user's answer (send it with a patch) |

## Patch

`tour.sh --patch -` takes one patch or a list. `step` is the 1-based step
number; it defaults to the current step.

```json
[ { "step": 2, "from": 12, "to": 15, "panel": "new text" },
  { "step": 2, "unset": ["panel", "to"] },
  { "step": 2, "note": 3, "verdict": "done", "detail": "Applied: ..." },
  { "step": 2, "note": 4, "line": 30, "text": "a new note" },
  { "step": 2, "note": 1, "remove": true },
  { "step": 2, "note": 3, "unset": ["detail"] },
  { "comment": "c1", "answer": "Because ...", "resolved": true } ]
```

- Step patch: any step field. A list (`hunks`, `notes`) is replaced as a
  whole; replacing `notes` numbers them from 1 again. `check` is replaced; the
  user's record stays when the question is the same.
- `unset`: a list of field names to remove (step fields, or note fields in a
  note patch). JSON `null` does not work: it is dropped.
- Note patch: `note` is the note's number. Giving `line` says where the note
  is now and clears its "code changed" mark.
- New note: `note` is the next free number (one above the highest ever used in
  the step) and `line` is required. A wrong number is answered with the right
  one.
- `remove: true` with `note` drops the note.
- Comment patch: `comment` is an id such as `c1`. Allowed keys: `comment`,
  `step`, `answer` (text), `resolved` (boolean). It cannot be combined with
  `note`.
- The list is applied to copies and checked as a whole. If any item fails,
  nothing changes. Numbers you write refer to the file as it is on disk now.
- You cannot set the plugin's own fields (`stale`, `seen`, `comments`,
  `decision`, the state of a check).

## `--status`

`{"step":0}` when no tour is open. Otherwise:

| Field | Meaning |
|---|---|
| `step`, `total` | current step (1-based) and number of steps |
| `title`, `file`, `group` | of the current step |
| `seen` | steps of the active tour the user has been shown |
| `groups` | loaded tours: `group`, `steps`, `seen`, `current`, `checks` (`total`, `answered`, `revealed`) |
| `stale` | absent when nothing is stale. Else a list: `{step, kind:"note", note, line}`, `{step, kind:"hunk", from, to, group}`, `{step, kind:"missing"}`. Patch each one |
| `depth` | `simpler` or `deeper`: the level the user asked for; write at that level |
| `check` | the current step's check: `open`, `revealed` or `answered` |

Positions follow edits by themselves. Only `stale` entries need a patch.
`seen` and `check` are the only evidence of what the user read and answered.

## `--inbox`

`{"group": "...", "items": [...]}`. Each item counts as sent after the call;
`--all` also lists comments that were sent but are not resolved.

| `kind` | Fields | Answer with |
|---|---|---|
| `comment` | `id`, `type` (`question`, `issue`, `suggestion`), `step`, `file`, `from`, `to`, `text` | a comment patch: `answer`; for an issue or suggestion you agree with, change the code first, then add `resolved: true` |
| `decision` | `step`, `note` (number), `verdict`, `decision` (`accept` or `reject`), `file`, `line`, `text` | accepted `simplify`/`remove`: apply it, patch the note to `done`. Rejected: leave the code alone |
| `check` | `step`, `question`, `reply` | a `check` patch with the question, the answer and `feedback` |

## Incremental review

`tour.sh --snapshot [name]` prints the commit id of the working tree it
recorded under `refs/walkthrough/<name>` (default `reviewed`; a name starts
with a letter or digit and may contain letters, digits, `.`, `_`, `-`). Index,
working tree, HEAD and branches are not touched. A step with
`"diff": "refs/walkthrough/reviewed"` marks only what changed after it, also
in files that are untracked.

## Limits to know

- A deletion next to another group's change cannot be split from it. Say so
  in a note.
- A deleted file cannot be a step. Write `git show HEAD:<path>` to a
  temporary file and tour that.
- `stage` refuses while a range of the group is stale: patch `hunks` first.
