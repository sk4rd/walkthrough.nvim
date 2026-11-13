-- T-1: positions follow edits. Unit tests on plain tables (anchor.lua), then
-- the same through the editor: redraw after a save or an outside edit,
-- patches after an edit, status() and staging.
local H = require('helpers')
local check, send, w = H.check, H.send, H.w
local anchor = require('walkthrough.anchor')
local st = _G.walkthrough_state

local function status()
  return vim.json.decode(w.status())
end

-- Unit -------------------------------------------------------------------------

local base = { 'a1', 'a2', 'a3', 'a4', 'a5', 'a6', 'a7', 'a8', 'a9', 'a10' }

--- A step over `base` with a note on line 3 and a group range 5-6, edited
--- into `new` and synced.
local function sync(new, step)
  step = step or {
    _snap = vim.deepcopy(base),
    from = 5, to = 6,
    notes = { { line = 3, n = 1 } },
    hunks = { { from = 5, to = 6, group = 'A' } },
  }
  anchor.sync_step(step, new)
  return step
end
local function edit(fn)
  local lines = vim.deepcopy(base)
  fn(lines)
  return lines
end

local s = sync(edit(function(l) table.insert(l, 1, 'new') end))
check('unit: insert above shifts everything', s.notes[1].line == 4 and s.hunks[1].from == 6 and s.hunks[1].to == 7
  and s.from == 6 and s.to == 7 and not s.notes[1].stale and not s.hunks[1].stale)
check('unit: _snap is the new file', vim.deep_equal(s._snap, edit(function(l) table.insert(l, 1, 'new') end)))

s = sync(edit(function(l) table.remove(l, 1) end))
check('unit: delete above shifts everything up', s.notes[1].line == 2 and s.hunks[1].from == 4 and s.hunks[1].to == 5
  and not s.hunks[1].stale)

s = sync(edit(function(l) l[5] = 'changed' end))
check('unit: edit inside a range keeps it, not stale', s.hunks[1].from == 5 and s.hunks[1].to == 6 and not s.hunks[1].stale)

s = sync(edit(function(l) table.insert(l, 6, 'extra') end))
check('unit: insert inside a range grows it', s.hunks[1].from == 5 and s.hunks[1].to == 7 and not s.hunks[1].stale)

s = sync(edit(function(l) table.remove(l, 6) end))
check('unit: delete inside a range shrinks it', s.hunks[1].from == 5 and s.hunks[1].to == 5 and not s.hunks[1].stale)

s = sync(edit(function(l) table.insert(l, 5, 'before') end))
check('unit: insert directly before a range is not part of it', s.hunks[1].from == 6 and s.hunks[1].to == 7
  and not s.hunks[1].stale)

s = sync(edit(function(l) table.insert(l, 7, 'after') end))
check('unit: insert directly after a range is not part of it', s.hunks[1].from == 5 and s.hunks[1].to == 6
  and not s.hunks[1].stale)

s = sync(edit(function(l) l[4], l[5] = 'x4', 'x5' end))
check('unit: rewrite across the start marks the range stale', s.hunks[1].stale == true)
s = sync(edit(function(l) l[6], l[7] = 'x6', 'x7' end))
check('unit: rewrite across the end marks the range stale', s.hunks[1].stale == true)
s = sync(edit(function(l) table.remove(l, 4); table.remove(l, 4) end))
check('unit: deletion reaching into the range marks it stale', s.hunks[1].stale == true)

s = sync(edit(function(l) table.remove(l, 5); table.remove(l, 5) end))
check('unit: everything deleted collapses onto the line the deletion is shown on',
  s.hunks[1].from == 4 and (s.hunks[1].to or 4) == 4 and not s.hunks[1].stale, vim.inspect(s.hunks))
s = sync(edit(function(l) table.remove(l, 1); table.remove(l, 1) end), {
  _snap = vim.deepcopy(base), hunks = { { from = 1, to = 2, group = 'A' } } })
check('unit: collapse at the top lands on line 1', s.hunks[1].from == 1 and (s.hunks[1].to or 1) == 1)

-- A collapsed range landing in a neighbour's range is dropped, so the step
-- stays valid (ranges written by the agent never overlap).
do
  local step = { file = H.work .. '/f.txt', _snap = vim.deepcopy(base),
    hunks = { { from = 2, to = 3, group = 'A' }, { from = 4, to = 4, group = 'B' }, { from = 8, to = 8, group = 'B' } } }
  local now = vim.deepcopy(base)
  table.remove(now, 4)
  anchor.sync_step(step, now)
  check('unit: a range collapsing into a neighbour is dropped', #step.hunks == 2
    and step.hunks[1].from == 2 and step.hunks[1].to == 3 and step.hunks[2].from == 7, vim.inspect(step.hunks))
  local two = { file = H.work .. '/f.txt', _snap = vim.deepcopy(base),
    hunks = { { from = 2, to = 3, group = 'A' }, { from = 4, to = 5, group = 'B' } } }
  now = vim.deepcopy(base)
  now[3], now[4] = 'x3', 'x4'
  anchor.sync_step(two, now)
  check('unit: an edit across two ranges makes both stale', two.hunks[1].stale and two.hunks[2].stale, vim.inspect(two.hunks))
  two.file = H.work .. '/g.txt'
  check('unit: stale ranges may touch without failing validation',
    require('walkthrough.tour').validate_step({ file = two.file, hunks = {
      { from = 2, to = 4, group = 'A', stale = true }, { from = 4, to = 5, group = 'B', stale = true } } }, { stored = true }) == true)
end

s = sync(edit(function(l) l[3] = 'rewritten' end))
check('unit: a note on a rewritten line is stale and stays', s.notes[1].line == 3 and s.notes[1].stale == true)
s = sync(edit(function(l) table.remove(l, 3) end))
check('unit: a note on a deleted line is stale, at the nearest line', s.notes[1].stale == true and s.notes[1].line == 2,
  vim.inspect(s.notes))
s = sync(edit(function(l) table.insert(l, 1, 'new') end))
check('unit: stale is not set by an unrelated edit', s.notes[1].stale == nil)

local indented = vim.tbl_map(function(l) return '    ' .. l end, base)
s = sync(indented)
check('unit: a whitespace-only reindent changes nothing', s.notes[1].line == 3 and not s.notes[1].stale
  and s.hunks[1].from == 5 and not s.hunks[1].stale and s.from == 5)
check('unit: the reindented file is the new snapshot', s._snap[1] == '    a1')

s = sync(edit(function(l) l[5] = 'x' end), {
  _snap = vim.deepcopy(base), from = 5, to = 6, notes = {}, hunks = { { from = 5, to = 6, group = 'A', stale = true } } })
check('unit: stale stays set', s.hunks[1].stale == true)

check('unit: sync_step reports a change', anchor.sync_step({ _snap = vim.deepcopy(base), from = 3 }, edit(function(l) table.insert(l, 1, 'n') end))
  and not anchor.sync_step({ _snap = vim.deepcopy(base), from = 3 }, edit(function(l) l[9] = 'z' end)))

local hk = anchor.diff(base, edit(function(l) table.insert(l, 1, 'n') end))
check('unit: map_line below a deletion', select(1, anchor.map_line(anchor.diff(base, edit(function(l) table.remove(l, 2) end)), 5)) == 4)
check('unit: diff returns indices', #hk == 1 and hk[1][1] == 0 and hk[1][4] == 1)

-- Through the editor -----------------------------------------------------------

local function line_of(text, buf)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(buf or 0, 0, -1, false)) do
    if l:find(text, 1, true) then
      return i
    end
  end
end
local function has_note(line)
  return H.marks(function(d) return d.virt_lines ~= nil end) > 0 and vim.iter(H.marks_at(line)):any(function(d)
    return d.virt_lines ~= nil
  end)
end
local function badge_text(line)
  local out = {}
  for _, d in ipairs(H.marks_at(line)) do
    for _, c in ipairs(d.virt_text or {}) do
      table.insert(out, c[1])
    end
  end
  return table.concat(out)
end
local function on(line, pred)
  return H.marks(pred) >= 0 and vim.iter(H.marks_at(line)):any(pred)
end

-- The regression of the audit: one line inserted at the top, then saved.
local gs = H.gitsigns()
H.capture_notify()
local log, find = H.capture_notify()
check('regression: load', send('load', { group = 'A', steps = { {
  file = H.work .. '/f.txt', from = 2, to = 3,
  hunks = { { from = 2, to = 3, group = 'A' }, { from = 4, to = 4, group = 'B' }, { from = 9, to = 9, group = 'A' } },
  notes = { { line = 2, text = 'note on A2' } },
} } }) == 'ok')
if gs then
  H.attach()
end
vim.api.nvim_buf_set_lines(0, 0, 0, false, { 'user-added' })
vim.cmd('write')
-- The extmarks follow the edit at once; wait for the redraw from disk, which
-- is what moves the stored numbers.
H.wait(function() return st.history[1].notes[1].line == 3 and not vim.bo.modified and has_note(3) end)
local A2, A3, B4, X8, UA = line_of('A2'), line_of('A3'), line_of('B4'), line_of('X8'), line_of('user-added')
local function reviewed(l) return on(l, function(d) return d.line_hl_group == 'WalkthroughAdded' end) end
check('regression: the note is on the line with A2', has_note(A2) and not has_note(UA) and badge_text(A2):match('1'),
  badge_text(A2))
check('regression: A2 and A3 are the reviewed group', reviewed(A2) and reviewed(A3))
check('regression: B4 is group B', on(B4, function(d) return H.sign(d, '·') end) and badge_text(B4):match('→ B'))
check('regression: X8 and the new line are in no group', on(X8, function(d) return H.sign(d, '?') end)
  and on(UA, function(d) return H.sign(d, '?') end) and badge_text(X8):match('not in any commit'))
check('regression: nothing is stale', status().stale == nil and not badge_text(A2):match('code changed'))
check('regression: numbers moved', st.history[1].notes[1].line == A2 and st.history[1].from == A2 and st.history[1].to == A3)

if gs then
  H.wait(function()
    return vim.iter(gs.get_hunks() or {}):any(function(h) return h.added.start == 1 end)
  end)
  w.stage_group()
  H.wait_notify(find, 'staged commit')
  H.wait(function() return H.git('diff', '--cached', '--numstat', '--', 'f.txt') ~= '' end)
  local diff = H.git('diff', '--cached', '-U0', '--', 'f.txt')
  check('regression: stages A2, A3 and the deletion of a10', diff:match('%-a2\n%-a3\n%+A2\n%+A3') ~= nil
    and diff:match('%-a10') ~= nil, diff)
  check('regression: leaves B4, X8 and the new line alone', not diff:match('B4') and not diff:match('X8')
    and not diff:match('user%-added'), diff)
else
  check('regression: staging needs gitsigns.nvim', false, 'gitsigns not installed')
end
w.close()

-- An edit from outside Neovim, followed by a reload.
local function fresh(lines, work, tour_steps)
  w.close()
  vim.cmd('silent! %bwipeout!')
  local dir = H.repo({ ['d.txt'] = lines }, work and { ['d.txt'] = work } or nil)
  tour_steps = tour_steps or {}
  tour_steps.file = dir .. '/d.txt'
  assert(send('load', { group = 'A', steps = { tour_steps } }) == 'ok')
  return dir, dir .. '/d.txt'
end

local dir, file = fresh(base, nil, { from = 4, to = 4, notes = { { line = 5, text = 'n' }, { line = 8, text = 'm' } } })
local external = vim.deepcopy(base)
table.insert(external, 1, 'outside')
external[7] = 'rewritten' -- was a6... after the insert a5 is line 6
vim.fn.writefile(external, file)
vim.cmd('checktime')
H.wait(function() return st.history[1].notes[1].line == 6 end)
check('external edit: a reload redraws on the right lines', st.history[1].notes[1].line == 6 and has_note(6)
  and st.history[1].notes[2].line == 9 and has_note(9) and st.history[1].from == 5)
check('external edit: nothing stale', status().stale == nil)

-- A note on a rewritten line and on a deleted line, and status().
vim.fn.writefile(vim.tbl_filter(function(l) return l ~= 'a8' end, vim.tbl_map(function(l)
  return l == 'a5' and 'changed5' or l
end, external)), file)
vim.cmd('checktime')
H.wait(function() return st.history[1].notes[1].stale end)
local stat = status()
check('stale: both notes are listed by status()', stat.stale and #stat.stale == 2
  and stat.stale[1].kind == 'note' and stat.stale[1].step == 1 and stat.stale[1].note == 1 and stat.stale[1].line == 6
  and stat.stale[2].note == 2, vim.inspect(stat))
check('stale: the note is drawn with a label', badge_text(6):match('%(code changed%)') ~= nil, badge_text(6))
check('stale: the deleted line\'s note stays at the nearest line', st.history[1].notes[2].line == 8
  or st.history[1].notes[2].line == 7, vim.inspect(st.history[1].notes))

-- A patch after an edit: its numbers are for the new file, the rest shifts.
dir, file = fresh(base, nil, { from = 2, to = 2, notes = { { line = 3, text = 'a' }, { line = 9, text = 'b' } },
  hunks = { { from = 3, to = 4, group = 'A' } } })
local edited = vim.deepcopy(base)
table.insert(edited, 1, 'top')
vim.fn.writefile(edited, file) -- not reloaded: no redraw has happened
check('patch: step 1 state before', st.history[1].notes[1].line == 3)
check('patch after edit: ok', send('patch', { { note = 2, line = 7 }, { note = 1, text = 'renamed' }, { from = 5, to = 6 } }) == 'ok')
local step = st.history[1]
check('patch after edit: the patched number is taken as given', step.notes[2].line == 7 and not step.notes[2].stale)
check('patch after edit: other positions were shifted', step.notes[1].line == 4 and step.hunks[1].from == 4
  and step.hunks[1].to == 5 and step.from == 5 and step.to == 6, vim.inspect(step))
check('patch after edit: the snapshot is the new file', vim.deep_equal(step._snap, edited))

-- A patch that sets a note's line clears its stale flag.
step.notes[1].stale = true
step.hunks[1].stale = true
check('patch: setting the line clears stale', send('patch', { note = 1, line = 4 }) == 'ok' and st.history[1].notes[1].stale == nil
  and st.history[1].hunks[1].stale == true)
check('patch: replacing hunks clears their flags', send('patch', { hunks = { { from = 3, to = 4, group = 'A' } } }) == 'ok'
  and st.history[1].hunks[1].stale == nil)

-- A failed patch changes nothing, apart from the sync.
local before = vim.deepcopy(st.history[1])
check('patch: failure', send('patch', { { note = 1, line = 5 }, { note = 1, verdict = 'bogus' } }):match('^error') ~= nil)
check('patch: failure leaves the tour as it was', vim.deep_equal(st.history[1], before))

-- Internal fields never come in through JSON.
check('json: _snap is rejected', send('load', { file = file, _snap = { 'x' } }):match('unknown step field "_snap"') ~= nil)
check('json: note stale is rejected', send('load', { file = file, notes = { { line = 1, stale = true } } })
  :match('unknown note field "stale"') ~= nil)
check('json: hunk stale is rejected', send('load', { file = file, hunks = { { from = 1, stale = true } } })
  :match('unknown hunk field "stale"') ~= nil)
check('patch: stale cannot be set', send('patch', { hunks = { { from = 1, stale = true } } }):match('"stale"') ~= nil
  and send('patch', { notes = { { line = 1, stale = true } } }):match('"stale"') ~= nil)

-- status(): hunk ranges, and a file that is gone.
dir, file = fresh(base, nil, { hunks = { { from = 5, to = 6, group = 'G' } } })
local rewritten = vim.deepcopy(base)
rewritten[4], rewritten[5] = 'x4', 'x5'
vim.fn.writefile(rewritten, file)
stat = status()
check('status: lists a stale range', stat.stale and #stat.stale == 1 and vim.deep_equal(stat.stale[1],
  { step = 1, kind = 'hunk', from = 5, to = 6, group = 'G' }), vim.inspect(stat))
check('status: stays absent when nothing is stale', (function()
  local d, f = fresh(base, nil, {})
  return status().stale == nil and w.status():match('"stale"') == nil
end)())

-- Two steps, the second one's file is deleted.
local d2 = H.repo({ ['a.txt'] = base, ['b.txt'] = base })
w.close()
assert(send('load', { steps = { { file = d2 .. '/a.txt' }, { file = d2 .. '/b.txt' } } }) == 'ok')
vim.fn.delete(d2 .. '/b.txt')
stat = status()
check('status: a missing file is reported and skipped', stat.step == 1 and stat.stale and #stat.stale == 1
  and stat.stale[1].step == 2 and stat.stale[1].kind == 'missing', vim.inspect(stat))

-- Unsaved changes: no redraw from disk, the marks follow the edit by themselves.
dir, file = fresh(base, nil, { notes = { { line = 5, text = 'n' } } })
vim.cmd('edit ' .. vim.fn.fnameescape(file))
vim.api.nvim_buf_set_lines(0, 0, 0, false, { 'typed' })
check('unsaved: the note follows the edit as an extmark', has_note(6) and st.history[1].notes[1].line == 5)
vim.cmd('write')
H.wait(function() return st.history[1].notes[1].line == 6 end)
check('unsaved: after saving, sync moves the number', st.history[1].notes[1].line == 6 and has_note(6))

-- Staging refuses while a range of the reviewed group is stale.
if gs then
  local changed = vim.deepcopy(base)
  changed[2], changed[3] = 'A2', 'A3'
  dir, file = fresh(base, changed, { hunks = { { from = 2, to = 3, group = 'A' } } })
  H.attach()
  local rw = vim.deepcopy(changed)
  rw[3], rw[4] = 'Z3', 'Z4' -- reaches over the end of the range
  vim.fn.writefile(rw, file)
  vim.cmd('checktime')
  H.wait(function() return st.history[1].hunks[1].stale end)
  log, find = H.capture_notify()
  w.stage_group()
  local n = find('were edited')
  check('stage_group refuses on a stale range', n ~= nil and n.level == vim.log.levels.WARN, vim.inspect(log))
  vim.wait(300, function() return H.git_in(dir, 'diff', '--cached', '--stat') ~= '' end)
  check('stage_group refuses: nothing was staged', H.git_in(dir, 'diff', '--cached', '--stat') == '')
  check('stale range is drawn as such', on(3, function(d) return H.sign(d, '?') end)
    and badge_text(2):match('stale range') ~= nil and not reviewed(2), badge_text(2))
else
  check('stage_group refusal needs gitsigns.nvim', false, 'gitsigns not installed')
end

w.close()
H.finish()
