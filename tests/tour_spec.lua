-- Unit tests for the pure parts: git.parse_hunks, tour.validate_step and
-- patch application. No windows are opened.
local H = require('helpers')
local check = H.check
local git = require('walkthrough.git')
local tour = require('walkthrough.tour')

local f = H.work .. '/f.txt' -- 9 lines
local function valid(step, opts)
  return tour.validate_step(step, opts)
end
local function rejects(name, step, pattern, opts)
  local ok, err = valid(step, opts)
  check(name, ok == nil and err ~= nil and err:match(pattern) ~= nil, err)
end

-- git.parse_hunks ---------------------------------------------------------------
local hunks = git.parse_hunks(table.concat({
  'diff --git a/f.txt b/f.txt',
  'index 1..2 100644',
  '--- a/f.txt',
  '+++ b/f.txt',
  '@@ -2,2 +2,2 @@',
  '-a2',
  '-a3',
  '+A2',
  '+A3',
  '@@ -9 +9,0 @@',
  '--- a line that starts with dashes',
  '\\ No newline at end of file',
  '@@ -1 +0,0 @@',
  '-a1',
  '@@ -5,0 +6 @@',
  '+new',
}, '\n'))
check('parse_hunks: four hunks', #hunks == 4, vim.inspect(hunks))
check('parse_hunks: replaced lines', hunks[1].start == 2 and hunks[1].count == 2 and #hunks[1].removed == 2
  and hunks[1].removed[1] == 'a2')
check('parse_hunks: missing count means 1, +N,0 means none', hunks[2].start == 9 and hunks[2].count == 0)
check('parse_hunks: removed line starting with dashes kept', hunks[2].removed[1] == '-- a line that starts with dashes',
  vim.inspect(hunks[2].removed))
check('parse_hunks: deletion at the top starts at 0', hunks[3].start == 0 and hunks[3].count == 0 and hunks[3].removed[1] == 'a1')
check('parse_hunks: pure addition', hunks[4].start == 6 and hunks[4].count == 1 and #hunks[4].removed == 0)
check('parse_hunks: empty text', #git.parse_hunks('') == 0)
check('first_line keeps one line', git.first_line('usage: git\n  more\n') == 'usage: git')

-- tour.validate_step ------------------------------------------------------------
check('valid: file only', valid({ file = f }))
check('valid: everything', valid({
  file = f, title = 't', group = 'A', total = 3, from = 2, to = 3, diff = 'HEAD', panel = { 'a', 'b' },
  hunks = { { from = 1, to = 2, group = 'A' }, { from = 4 } },
  notes = { { line = 2, text = { 'x', 'y' }, detail = 'd', verdict = 'keep' } },
}))
rejects('file missing', {}, '"file" is missing')
rejects('file not a string', { file = 3 }, '"file" must be a string')
rejects('file unreadable', { file = H.work .. '/nope' }, 'cannot read file')
rejects('message names the step', { file = f, title = 3 }, '^step 2: "title" must be a string', { index = 2 })
rejects('group must be a string', { file = f, group = 1 }, '"group" must be a string')
rejects('total must be a number', { file = f, total = 'x' }, '"total"')
rejects('from must be an integer', { file = f, from = 1.5 }, '"from" must be an integer')
rejects('from must be >= 1', { file = f, from = 0 }, '"from" must be an integer >= 1')
rejects('to without from', { file = f, to = 3 }, '"to" needs "from"')
rejects('from after to', { file = f, from = 5, to = 2 }, 'must not be after')
rejects('diff type', { file = f, diff = 3 }, '"diff"')
check('diff false is valid', valid({ file = f, diff = false }))
rejects('panel type', { file = f, panel = 3 }, '"panel"')
rejects('panel list of non-strings', { file = f, panel = { 'a', 3 } }, '"panel"')
rejects('unknown step field', { file = f, titel = 'x' }, 'unknown step field "titel"')
rejects('notes must be a list', { file = f, notes = { line = 1 } }, '"notes" must be a list')
rejects('note line missing', { file = f, notes = { { text = 'x' } } }, '^note 1: "line" is missing')
rejects('note line missing (index)', { file = f, notes = { { line = 1 }, { text = 'x' } } }, '^step 2, note 2: "line" is missing', { index = 2 })
rejects('note line integer', { file = f, notes = { { line = 'a' } } }, '"line" must be an integer')
rejects('note line >= 1', { file = f, notes = { { line = 0 } } }, '"line" must be an integer >= 1')
rejects('note line past the end', { file = f, notes = { { line = 10 } } }, 'past the end of the file %(9 lines%)')
check('note on the last line', valid({ file = f, notes = { { line = 9 } } }))
rejects('note text type', { file = f, notes = { { line = 1, text = 3 } } }, '"text"')
rejects('note detail type', { file = f, notes = { { line = 1, detail = { 1 } } } }, '"detail"')
rejects('note verdict', { file = f, notes = { { line = 1, verdict = 'great' } } }, '"verdict" must be one of')
rejects('unknown note field', { file = f, notes = { { line = 1, txt = 'x' } } }, 'unknown note field "txt"')
rejects('note number from JSON', { file = f, notes = { { line = 1, n = 1 } } }, 'unknown note field "n"')
check('note number on stored steps', valid({ file = f, next_note = 2, notes = { { line = 1, n = 1 } } }, { stored = true }))
rejects('next_note from JSON', { file = f, next_note = 2 }, 'unknown step field "next_note"')
rejects('hunks must be a list', { file = f, hunks = { from = 1 } }, '"hunks" must be a list')
rejects('hunk without from', { file = f, hunks = { { group = 'A' } } }, '^hunk 1: "from" is missing')
rejects('hunk from type', { file = f, hunks = { { from = 'a' } } }, '"from" must be an integer')
rejects('hunk to before from', { file = f, hunks = { { from = 5, to = 4 } } }, '"to" must be an integer >= "from"')
rejects('hunk group type', { file = f, hunks = { { from = 1, group = 2 } } }, '"group" must be a string')
rejects('unknown hunk field', { file = f, hunks = { { from = 1, frm = 2 } } }, 'unknown hunk field "frm"')
rejects('overlapping hunks', { file = f, hunks = { { from = 1, to = 3 }, { from = 3, to = 4 } } }, 'hunk 2: overlaps hunk 1')
check('touching hunks are fine', valid({ file = f, hunks = { { from = 1, to = 3 }, { from = 4, to = 4 } } }))

-- tour.prepare_tour -------------------------------------------------------------
local t = tour.prepare_tour({ group = 'G', start = 9, steps = {
  { file = f, notes = { { line = 1 }, { line = 2 } }, hunks = { { from = 1 } } },
  { file = f, group = 'own' },
} })
check('prepare_tour: group, diff default, start clamped',
  t and t.steps[1].group == 'G' and t.steps[1].diff == true and t.steps[2].group == 'own' and t.start == 2, vim.inspect(t))
check('prepare_tour: notes numbered 1..k, next free number remembered',
  t and t.steps[1].notes[1].n == 1 and t.steps[1].notes[2].n == 2 and t.steps[1].next_note == 3)
local _, err = tour.prepare_tour({ steps = { { file = f }, { file = f, notes = { { text = 'x' } } } } })
check('prepare_tour: names the bad step', err == 'step 2, note 1: "line" is missing', err)
_, err = tour.prepare_tour({ steps = {} })
check('prepare_tour: empty steps', err == '"steps" is empty', err)

-- Patching ----------------------------------------------------------------------
local function history()
  return tour.prepare_tour({ group = 'G', steps = {
    { file = f, panel = 'p', from = 2, to = 4, notes = { { line = 1, text = 'one' }, { line = 2, text = 'two', detail = 'dd' }, { line = 3, text = 'three' } } },
    { file = f, title = 'second' },
  } }).steps
end
local function ns(step)
  return vim.tbl_map(function(n) return n.n end, step.notes)
end

local h = history()
local changed, moved = tour.apply_patches(h, 1, { { note = 1, remove = true } })
check('patch: remove keeps the other numbers', changed and vim.deep_equal(ns(changed[1]), { 2, 3 }), vim.inspect(changed))
check('patch: history itself untouched', #h[1].notes == 3)
check('patch: remove is not a move', not moved[1])

changed = tour.apply_patches(h, 1, { { note = 1, remove = true }, { note = 4, line = 5, text = 'new' } })
check('patch: new note gets the next free number', changed and vim.deep_equal(ns(changed[1]), { 2, 3, 4 }) and changed[1].next_note == 5,
  vim.inspect(changed))
changed = tour.apply_patches(h, 1, { { note = 3, remove = true }, { note = 4, line = 5 } })
check('patch: numbers are not reused after a removal', changed and vim.deep_equal(ns(changed[1]), { 1, 2, 4 }), vim.inspect(changed))

_, err = tour.apply_patches(h, 1, { { note = 7, line = 5 } })
check('patch: new note must have the next free number', err and err:match('must be number 4'), err)
_, err = tour.apply_patches(h, 1, { { note = 4, text = 'no line' } })
check('patch: new note needs a line', err and err:match('"line"'), err)
_, err = tour.apply_patches(h, 1, { { note = 9, remove = true } })
check('patch: removing an unknown note fails', err and err:match('has no note 9'), err)

changed = tour.apply_patches(h, 1, { { note = 2, unset = { 'detail' } } })
check('patch: unset a note field', changed and changed[1].notes[2].detail == nil and changed[1].notes[2].text == 'two', vim.inspect(changed))
changed, moved = tour.apply_patches(h, 1, { { unset = { 'panel', 'to' } } })
check('patch: unset step fields', changed and changed[1].panel == nil and changed[1].to == nil and changed[1].from == 2)
check('patch: unsetting from/to counts as a move', moved[1] == true)
_, err = tour.apply_patches(h, 1, { { unset = { 'bogus' } } })
check('patch: unset of an unknown field fails', err and err:match('unknown step field "bogus"'), err)
_, err = tour.apply_patches(h, 1, { { note = 1, unset = { 'line' } } })
check('patch: unsetting a required field fails validation', err and err:match('note 1: "line" is missing'), err)
_, err = tour.apply_patches(h, 1, { { note = 1, unset = { 'n' } } })
check('patch: the note number cannot be unset', err and err:match('unknown note field "n"'), err)

changed, moved = tour.apply_patches(h, 1, { { step = 2, title = 'renamed' }, { from = 3, to = 3 } })
check('patch: several steps', changed and changed[2].title == 'renamed' and changed[1].from == 3 and moved[1], vim.inspect(changed))
check('patch: other step left alone', h[2].title == 'second')

changed = tour.apply_patches(h, 1, { { notes = { { line = 1, text = 'a' }, { line = 2, text = 'b' } } } })
check('patch: replaced notes are numbered from 1', changed and vim.deep_equal(ns(changed[1]), { 1, 2 }) and changed[1].next_note == 3)

changed = tour.apply_patches(h, 2, { { hunks = { { from = 1, to = 2 } } } })
check('patch: hunks turn the diff on', changed and changed[2].diff == true)

_, err = tour.apply_patches(h, 1, { { titel = 'x' } })
check('patch: unknown step field', err == 'patch 1: unknown step field "titel"', err)
_, err = tour.apply_patches(h, 1, { { note = 1, txt = 'x' } })
check('patch: unknown note field', err == 'patch 1: unknown note field "txt"', err)
_, err = tour.apply_patches(h, 1, { { step = 5, title = 'x' } })
check('patch: unknown step', err == 'patch 1: there is no step 5', err)

-- A failing item anywhere leaves everything untouched, even when earlier
-- items would have worked, and the same list can be resent after a fix.
local before = vim.deepcopy(h)
changed, err = tour.apply_patches(h, 1, { { note = 1, remove = true }, { note = 9, text = 'typo' } })
check('patch: failing list returns an error', changed == nil and err ~= nil)
check('patch: failing list changes nothing', vim.deep_equal(h, before))
_, err = tour.apply_patches(h, 1, { { from = 1, to = 2 }, { notes = { { line = 99 } } } })
check('patch: result is validated', err and err:match('past the end'), err)
check('patch: still nothing changed', vim.deep_equal(h, before))

H.finish()
