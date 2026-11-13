# Protocol reference

This is the complete protocol between an agent and the walkthrough.nvim
plugin, in short. The full reference for people is `:help walkthrough`
(`doc/walkthrough.txt`). A test (`tests/docs_spec.lua`) checks that every field,
verdict, evidence value, thread state and inbox kind the plugin knows is named
here.

Words: the **map** is the ordered list of commits of a change. One
**commit** is a set of lines, from several files and maybe only part of a file,
that builds on its own. Its **entries** are its files, in reading order. The
JSON names are older than these words and stay: a commit is sent as an object
with a `group` and `steps`, an entry is a step. A **finding** is a note.

All commands are `tour.sh` (next to `SKILL.md`). Each prints Neovim's answer
and exits non-zero on `error: ...`. With several Neovims, set
`WALKTHROUGH_NVIM=<socket>`.

## `tour.sh`

| Command | Does |
|---|---|
| `tour.sh file.json` or `tour.sh -` (stdin) | send one commit of the map (or one entry) |
| `tour.sh --patch file.json` or `--patch -` | change what is loaded, in place |
| `tour.sh --status` | where the user is (JSON) |
| `tour.sh --inbox [--all]` | what the user wrote since the last call (JSON); `--all` also lists the threads that wait for an answer |
| `tour.sh --snapshot [name]` | record the working tree as `refs/walkthrough/<name>` (default `reviewed`) and print the commit id; not part of the workflow |
| `tour.sh --close` | end the session: clear the screen, forget the loaded commits; the user's threads on files that no map lists are deleted |
| `tour.sh --socket` | print the socket that would be used; exit 1 and a message on stderr when there is none |

The socket is `$WALKTHROUGH_NVIM`, else `$NVIM` (set inside Neovim's terminal),
else the only Neovim socket in `$XDG_RUNTIME_DIR`. `--status` prints what
Neovim answers and `--close` prints nothing; neither checks the answer. The
others exit non-zero on an error.

## Errors

The answer is `ok`, JSON, a commit id, or `error: <one line>`. A failed send
or patch changed nothing: read the line, fix the JSON, send it again. Unknown
fields are errors, so a typo is reported. Lines are 1-based and inclusive and
mean the file as it is on disk now. Text fields take a string or a list of
strings (one per line). JSON `null` is dropped when the file is read; use
`unset` to remove a field.

## A commit of the map

```json
{ "group": "Share the LAN constants", "start": 1, "steps": [ ... ] }
```

| Field | Type | Rule |
|---|---|---|
| `group` | string | the commit's subject; the default `group` of its entries |
| `steps` | list | required, not empty: the entries |
| `start` | integer | 1 or more, limited to the number of entries; the entry shown first (default 1) |

Other keys at this level are ignored. Send commits in map order: the map lists
them in the order they were sent. The first commit of a map is the one the
user sees (it replaces the local review, if there is one). A later commit of
the same repository is added to the map without switching: the user's view and
position do not move, and Neovim only says that the commit was added. Sending a
commit with the same `group` replaces the loaded one in place and keeps what the
user did (seen entries and threads of entries with the same `file` and `title`,
depth) and where they are: the replaced commit stays on screen if it was, at the
same entry, unless you give `start`. A different `group` is another commit. A file with no
`steps` is one entry; it is appended to the active commit. A commit with a
`group` also replaces the user's local review (`:Walkthrough review`, a map
without a `group` made from git) and takes its threads over, by file. When the
map that was asked for arrives this way, the request ends (`--inbox` stops
listing `kind: "map"`).

## Entry (a `steps` item)

| Field | Type | Rule |
|---|---|---|
| `file` | string | required; an existing file; use an absolute path |
| `title` | string | one sentence saying what changed in this file; the map panel shows it under the file name |
| `group` | string | default: the commit's `group` |
| `from` | integer | 1 or more; first line of the focus |
| `to` | integer | `from` or more; needs `from` |
| `diff` | `true`, `false` or a git ref | `true`: uncommitted changes against HEAD, staged lines muted. A ref (string): a plain diff against it (`HEAD~2`, a branch), with no staged marks. Default `true` when `hunks` is given |
| `hunks` | list of hunks | the changed lines of this file, by commit |
| `notes` | list of notes | the findings on this file |

If the request's `base` is not `HEAD`, give every entry `"diff": "<base>"`.

## Hunk (a range of lines, assigned to a commit)

| Field | Type | Rule |
|---|---|---|
| `from` | integer | required; 1 or more |
| `to` | integer | `from` or more; default `from` |
| `group` | string | default: the entry's `group` |

Ranges of one entry must not overlap. List **every** changed line of the file:
the lines of this commit without `group` (or with its own), the lines of other
commits with their `group`. A changed line in a range of the entry's commit is
drawn in full and is what `stage` stages; in another commit's range it is
dimmed and labelled with that commit; in no range it is flagged. A deleted
line has no line of its own: it counts as being on the line where it is shown,
so a deletion next to another commit's change goes with that change. Say so in
a note when it happens.

## Note (a finding)

| Field | Type | Rule |
|---|---|---|
| `line` | integer | required; 1 or more; not past the end of the file |
| `text` | text | a few words, drawn under the line |
| `detail` | text | longer explanation; shown under `text`, 6 lines at most |
| `verdict` | string | `keep`, `simplify`, `remove`, `done`, `moved` |
| `evidence` | string | `ran`, `read`, `opinion` |

Notes are numbered 1, 2, ... in list order. Numbers are stable: a patch never
renumbers them and never reuses one (except when it replaces the whole list).

Verdicts: `keep` (fine as it is), `simplify` (can be simpler; say how), `remove`
(not needed), `done` (a suggestion that was applied), `moved` (code that was
only relocated; find it with `git diff -M --color-moved`). Evidence: `ran` (you
ran something that shows it), `read` (inferred from reading), `opinion` (a
judgement). Never label a guess `ran`.

## Patch

`tour.sh --patch -` takes one patch or a list. `step` is the 1-based number of
an entry of the active commit; it defaults to the current entry.

```json
[ { "step": 2, "from": 12, "to": 15, "title": "new sentence" },
  { "step": 2, "unset": ["title", "to"] },
  { "step": 2, "note": 3, "verdict": "done", "detail": "Applied: ..." },
  { "step": 2, "note": 4, "line": 30, "text": "a new finding" },
  { "step": 2, "note": 1, "remove": true },
  { "step": 2, "note": 3, "unset": ["detail"] },
  { "thread": "t1", "answer": "Because ..." },
  { "thread": "t2", "answer": "I would ...", "proposal": true },
  { "thread": "t2", "answer": "Applied: ...", "done": true },
  { "thread": "t3", "answer": "The same, simpler: ...", "replace": true },
  { "commit_message": "feat(net): share the LAN constants", "group": "Share the LAN constants" } ]
```

- Entry patch: any entry field (`file`, `title`, `group`, `from`, `to`, `diff`,
  `hunks`, `notes`). A list (`hunks`, `notes`) is replaced as a whole;
  replacing `notes` numbers them from 1 again.
- `unset`: a list of field names to remove (entry fields, or note fields in a
  note patch).
- Note patch: `note` is the note's number. It changes the fields it names.
  Giving `line` says where the note is now and clears its "code changed" mark.
  `remove: true` drops the note.
- New note: `note` is the next free number (one above the highest ever used in
  the entry) and `line` is required. A wrong number is answered with the right
  one.
- Thread patch: `thread` is an id such as `t1`. Ids are unique in the whole
  repository (the user may write on any file, also on files that are in no
  map), so `step` is not needed; the thread is found in any commit. The keys:
  `thread`, `step`, `answer` (text), `proposal`, `replace`, `done` (booleans).
  `answer` appends a message of yours; the state becomes `answered`, or
  `proposed` with `proposal`. `replace` rewrites your last message instead
  (for "simpler" and "deeper"); the state stays. `done` closes the thread (the
  state becomes `done`), with or without an `answer`. `proposal` and `replace`
  need `answer`; `replace` cannot go with `done` or `proposal`; `done` cannot
  go with `proposal`. A patch addresses a note or a thread, not both.
- Commit message: `commit_message` (a string, or a list of strings that are
  joined as lines) and `group`, the commit it is for (default: the active
  commit). It answers a commit request. Rejected when no commit of that `group`
  is loaded. No other keys.
- The list is applied to copies and checked as a whole. If any item fails,
  nothing changes. Numbers you write refer to the file as it is on disk now.
- You cannot: create or delete a thread, write for the user, decide, stage,
  reject or commit, or set the plugin's own fields (`stale`, `seen`,
  `threads`, `decision`, `decision_sent`).

## `--status`

`{"step":0}` when nothing is open. With only threads on files outside every
map it is `{"step":0, "threads":{...}, "groups":[...]}`. Otherwise:

```json
{ "step": 2, "total": 3, "title": "the constants", "file": "/p/net.nix",
  "group": "Share the LAN constants", "seen": 2, "view": "compact",
  "groups": [ { "group": "Share the LAN constants", "steps": 3, "seen": 2, "current": true },
              { "group": "Other files", "extra": true, "steps": 1, "seen": 0, "current": false } ],
  "stale": [ { "step": 2, "kind": "note", "note": 1, "line": 12 } ],
  "depth": "simpler", "threads": { "draft": 0, "waiting": 1, "answered": 2, "proposed": 0 },
  "commit": { "group": "Share the LAN constants", "check": "running", "message": false },
  "plan": { "id": "s1-1", "state": "pending", "threads": 2 }, "map": "requested" }
```

| Field | Meaning |
|---|---|
| `step`, `total` | current entry (1-based) and number of entries of the active commit |
| `title`, `file`, `group` | of the current entry |
| `seen` | entries of the active commit the user has been shown. The only evidence of what the user looked at |
| `view` | `compact` (the changed parts of the files in one buffer) or `file` (the real file): the view on screen. Line numbers in your entries, notes and threads are always those of the file |
| `groups` | the loaded commits: `group`, `steps`, `seen`, `current`. `Other files` (with `extra: true`) holds the user's threads on files that are in no map |
| `stale` | absent when nothing is stale. Else a list: `{step, kind:"note", note, line}`, `{step, kind:"hunk", from, to, group}`, `{step, kind:"missing"}` (the file cannot be read). Patch each one |
| `depth` | `simpler` or `deeper`: the level the user asked for; write at that level. Absent otherwise |
| `threads` | absent when there is nothing to count. Else the number of threads of the whole repository in the states `draft`, `waiting`, `answered`, `proposed` |
| `commit` | present while the user has a commit dialog open: `group`, `check` (`running`, `passed`, `failed` or `none`) and `message` (true when the message area holds text) |
| `plan` | present while a plan is under review: `id`, `state` (`pending`: the user decides; `feedback-sent`) and `threads`. The plan is no entry of `groups` |
| `map` | `requested` while the user's request for the map has not been answered by a map. Absent otherwise |

Positions follow edits by themselves. Only `stale` entries need a patch.

## `--inbox`

`{"group": "...", "items": [...]}` for all commits of the repository. Each item
counts as delivered after the call; `--all` also lists the threads that wait for
an answer. Items of commits come in entry order, threads sorted by line; items
for `Other files` (files that are in no map; `group` says so) come last and need
no map: answer them with a thread patch as usual.

A thread's states are: `draft` (written, not delivered), `waiting` (delivered,
not answered), `answered`, `proposed` (your proposal awaits the user),
`accepted` and `declined` (the user's decision on a proposal, delivered),
`done`. `declined` and `done` threads are closed, but the user can continue
one by writing on its lines: it then comes back as a `question` or `change`
item with the earlier messages and the new one after `new`.

The user marks decisions and sends them with the change requests and replies
(`send`), so `--inbox` and a `Walkthrough:` message can hold all kinds at once.
A decision is never delivered before that. You cannot set a decision or a state
other than with `answer`, `proposal`, `replace` and `done`; a new proposal puts
the thread back to `proposed` and the old decision is void.

| `kind` | Fields | Reply |
|---|---|---|
| `question` | `id`, `group`, `step`, `file`, `from`, `to`, `state`, `messages` (list of `by`, `text`, `proposal`), `new` (index of the first message you have not seen), `stale` | `{ "thread": "t1", "answer": "..." }`. Change no code |
| `change` | the same | a proposal and no edit yet: `{ "thread": "t1", "answer": "...", "proposal": true }`. If the message before `new` is your proposal, the user asks you to revise it: a new proposal, no edit (the text message says so in `Expected:`) |
| `decision` on a proposal | `id`, `group`, `step`, `file`, `from`, `to`, `decision` (`accept` or `reject`), `state`, `text` | `accept`: apply it, then `{ "thread": "t1", "answer": "<what you changed>", "done": true }`. `reject`: leave the code |
| `decision` on a finding | `group`, `step`, `note`, `verdict`, `decision`, `file`, `line`, `text` | `accept` of `simplify` or `remove`: apply it, then `{ "step": 2, "note": 1, "verdict": "done" }`. `reject`: leave the code |
| `commit` | `group`, `stat` (the text of `git diff --cached --stat`) | `{ "commit_message": "...", "group": "..." }`. Listed until a message arrived or the dialog closed; reading does not deliver it |
| `map` | `root`, `base`, `files` (relative to `root`) | build the map and send it (below). Listed until a map arrives, `--close` or the review is discarded; reading does not deliver it |

A thread on a plan (see Plan review) has the kind `comment`, the only kind
there. `--inbox` does not list it: it reaches you in the plan feedback message.
Reply as to a `question`: `{ "thread": "t1", "answer": "..." }`.

```json
{ "group": "Share the LAN constants", "items": [
  { "kind": "question", "id": "t1", "group": "Share the LAN constants", "step": 1,
    "file": "/p/net.nix", "from": 10, "to": 12, "state": "waiting", "new": 1,
    "messages": [ { "by": "user", "text": "why a set here?" } ] },
  { "kind": "decision", "id": "t2", "group": "Share the LAN constants", "step": 1,
    "file": "/p/net.nix", "from": 20, "to": 20, "decision": "accept", "state": "accepted",
    "text": "I would inline it." },
  { "kind": "commit", "group": "Share the LAN constants", "stat": " net.nix | 2 +-" },
  { "kind": "map", "root": "/p", "base": "HEAD", "files": ["net.nix", "host.nix"] } ] }
```

The messages that start with `Walkthrough:` carry the same items as text, each
with an `Expected:` line that says what to do. The commit request names the
rules for the message: Conventional Commits. One line. Add further lines only
when the change is really complex. Never add a Co-authored-by line (such lines
are removed anyway).

## Building the map

The user's request (`kind: "map"`) gives the repository `root`, the `base`
(`HEAD`, or the ref of the review) and the changed `files`. Sort the changes
into commits that each stand on their own, ordered so that nothing depends on
a later commit. Send one commit per call, in order. An entry of a file that
several commits touch appears in each of them, with `hunks` that assign every
changed line to a commit (its own without `group`, the others with theirs).

```json
{ "group": "Share the LAN constants",
  "steps": [ {
    "file": "/p/net.nix", "title": "the constants move into one set",
    "from": 10, "to": 20,
    "hunks": [ { "from": 10, "to": 20 },
               { "from": 41, "to": 41, "group": "Use the constants in the firewall" } ],
    "notes": [ { "line": 12, "text": "one use only", "verdict": "simplify",
                 "evidence": "read", "detail": "Inline it: nothing else reads it." } ]
  } ] }
```

## Commit

Approval has two steps. The user stages a commit's lines (step one), then asks
for the commit (step two): Neovim runs `commit-check.sh` on the index, sends
you a request (also listed in `--inbox` as `kind: "commit"`) and shows your
message with the check result in an editable float. The user confirms and
Neovim makes the commit; you never stage or commit. After the commit its
threads are gone and the next commit of the map is shown.

## Plan review

A hook, not you, hands your plan to Neovim when you leave plan mode (Claude
Code: a `PermissionRequest` hook for `ExitPlanMode`, `hooks/plan-review.sh`).
You wait in the hook. The user writes comments on the plan and approves it, or
sends feedback: the hook denies leaving plan mode with one message that lists
the comments, each labelled `Comment t1 on plan line 4:` (or `lines 4-6`), with
the plan lines it is about and the user's text. A comment is a thread of kind
`comment`: the only kind on a plan, whichever key the user used. Reply to
**every** comment with a thread patch (`{ "thread": "t1", "answer": "..." }`)
before you present the plan again, and revise the plan where a comment asks for
a change or shows that one is needed. Showing
the revised plan reaches the same review: the threads stay and follow their
lines (rewritten lines make a thread stale), and your answers are drawn under
the user's lines. The socket entry points the hook uses are `plan` (the hook
input file; answers a review id) and `plan_result` (the id; `{"state":"pending"}`,
`{"state":"approve"}` or `{"state":"feedback","message":"..."}`, a feedback
once).

## Limits to know

- A deletion next to another commit's change cannot be split from it. Say so
  in a note.
- A deleted file cannot be an entry. Write `git show HEAD:<path>` to a
  temporary file and use that.
- `stage` and `reject` refuse while a range of the commit is stale: patch
  `hunks` first.
