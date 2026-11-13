-- Integration tests for load, patch and step: validation (T-2), transactions
-- (T-3), panel (T-7), repositories without history (T-10), unsaved buffers
-- (T-12), stable note numbers (T-13), winbar (T-14), deleted-line cap.
local H = require('helpers')
local check, send, w = H.check, H.send, H.w
local f, g = H.work .. '/f.txt', H.work .. '/g.txt'
local function status()
  return vim.json.decode(w.status())
end
local function all_marks(buf)
  return #vim.api.nvim_buf_get_extmarks(buf or 0, H.ns, 0, -1, {})
end
local function badges()
  return H.marks(function(d)
    return d.virt_text ~= nil
  end)
end
local function reset()
  w.close()
  vim.cmd('silent! %bwipeout!')
end

-- T-2: validation happens in load, before anything is shown ----------------------
local res = send('load', { steps = {
  { file = f, panel = '# One', notes = { { line = 2, text = 'n' } } },
  { file = g, notes = { { text = 'no line' } } },
} })
check('T-2: load names the bad step and note', res == 'error: step 2, note 1: "line" is missing', res)
check('T-2: nothing was shown', status().step == 0 and all_marks() == 0 and H.panel_text() == '')

check('T-2: hunk without from', send('load', { file = f, hunks = { { group = 'A' } } }) == 'error: hunk 1: "from" is missing')
check('T-2: note past the end of the file', send('load', { file = g, notes = { { line = 2 } } }):match('past the end') ~= nil)
check('T-2: unknown field is reported', send('load', { steps = { { file = f }, { file = g, titel = 'x' } } })
  == 'error: step 2: unknown step field "titel"')
check('T-2: error has no plugin path and one line', (function()
  local r = send('load', { file = f, notes = { { line = 'x' } } })
  return not r:match('lua/walkthrough') and not r:match('\n')
end)())
check('T-2: not an object', w.load((function()
  local p = vim.fn.tempname()
  vim.fn.writefile({ '[1, 2]' }, p)
  return p
end)()) == 'error: a tour or step must be a JSON object')
check('T-2: missing json file does not raise', pcall(w.load, '/nonexistent/x.json') and w.load('/nonexistent/x.json'):match('^error:') ~= nil)

-- A valid tour still loads; the step with only a file is fine.
check('valid tour loads', send('load', { group = 'A', steps = { { file = f, panel = '# One', notes = { { line = 2, text = 'n' } } }, { file = g } } }) == 'ok')

-- T-2: step() stays put when the target cannot be shown ---------------------------
local log, find = H.capture_notify()
local keep = vim.fn.readfile(g)
vim.fn.delete(g)
w.step(1)
check('T-2: failed step() notifies', find('cannot read file') ~= nil, vim.inspect(log))
check('T-2: failed step() stays on the step', status().step == 1 and vim.fn.expand('%:t') == 'f.txt')
check('T-2: failed step() leaves the step drawn', badges() >= 1 and H.panel_text():match('# One') ~= nil)
vim.fn.writefile(keep, g)
w.step(1)
check('step() moves once the file is back', status().step == 2)
check('step() does not raise on a bad argument', pcall(w.step, nil))
check('step() reports a missing step', (function()
  w.step(5)
  return find('no later step') ~= nil
end)())

-- T-3: load is transactional -------------------------------------------------------
reset()
check('T-3: old tour', send('load', { steps = { { file = g, title = 'old tour', panel = '# Old', notes = { { line = 1, text = 'o' } } } } }) == 'ok')
local before_marks = all_marks()
res = send('load', { file = f, from = 2, to = 3, diff = 'no-such-ref', panel = '# New' })
check('T-3: bad ref is reported', res:match('^error: git diff failed') ~= nil and not res:match('\n'), res)
check('T-3: status still the old tour', status().step == 1 and status().title == 'old tour')
check('T-3: code window shows the old step', vim.fn.expand('%:t') == 'g.txt')
check('T-3: marks are the old step\'s', all_marks() == before_marks and before_marks > 0, all_marks())
check('T-3: panel is the old step\'s', H.panel_text():match('# Old') ~= nil and not H.panel_text():match('# New'))
check('T-3: winbar says step 1/1', H.panel_winbar():match('Step 1/1') ~= nil)
reset()
res = send('load', { file = f, from = 2, to = 3, diff = 'no-such-ref', panel = '# New' })
check('T-3: failed first load draws nothing', res:match('^error:') ~= nil and all_marks() == 0 and status().step == 0)
reset()
check('T-3: failed lone step is not added to the history', (function()
  send('load', { group = 'A', steps = { { file = g, title = 'one' } } })
  local r = send('load', { file = f, diff = 'no-such-ref' })
  return r:match('^error:') ~= nil and status().total == 1 and vim.fn.expand('%:t') == 'g.txt'
end)())

-- T-3: patch is transactional -----------------------------------------------------
reset()
send('load', { steps = { { file = f, notes = { { line = 1, text = 'one' }, { line = 2, text = 'two' }, { line = 3, text = 'three' } } } } })
local st = _G.walkthrough_state
local patch = { { note = 1, remove = true }, { note = 9, text = 'typo: no such note' } }
res = send('patch', patch)
check('T-3: failing patch is reported', res:match('^error: patch 2: step 1 has no note 9') ~= nil, res)
check('T-3: failing patch changes nothing', #st.history[1].notes == 3 and badges() == 3)
check('T-3: resending the same patch gives the same answer', send('patch', patch) == res and #st.history[1].notes == 3)
patch[2] = { note = 2, text = 'fixed' }
check('T-3: corrected list applies once', send('patch', patch) == 'ok' and #st.history[1].notes == 2 and badges() == 2)
-- A patch that validates but cannot be drawn is rolled back too.
res = send('patch', { diff = 'no-such-ref' })
check('T-3: patch that cannot be drawn is rolled back', res:match('^error:') ~= nil and st.history[1].diff == nil and badges() == 2, res)

-- T-13: stable note numbers, unset -------------------------------------------------
check('T-13: remove did not renumber', (function()
  return st.history[1].notes[1].n == 2 and st.history[1].notes[2].n == 3
end)())
local headings = H.panel_text()
check('T-13: panel headings keep their numbers', headings:match('### %[2%] line 2') and headings:match('### %[3%] line 3')
  and not headings:match('### %[1%]'), headings)
check('T-13: note_lines use the numbers', st.note_lines[2] == 2 and st.note_lines[3] == 3 and st.note_lines[1] == nil, vim.inspect(st.note_lines))
check('T-13: add a note as number 4', send('patch', { note = 4, line = 5, text = 'added' }) == 'ok' and st.note_lines[4] == 5)
check('T-13: number 1 is not reused', send('patch', { note = 1, line = 6, text = 'x' }):match('must be number 5') ~= nil)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
w.note(1)
check('T-13: note navigation uses the numbers', vim.api.nvim_win_get_cursor(0)[1] == 2)
check('T-13: unset a step field', send('patch', { unset = { 'notes' } }) == 'ok' and st.history[1].notes == nil)
send('patch', { title = 'has title', panel = 'text', from = 2, to = 3 })
check('T-13: unset panel and to', send('patch', { unset = { 'panel', 'to' } }) == 'ok' and st.history[1].panel == nil
  and st.history[1].to == nil and st.history[1].from == 2)
check('T-13: unset an unknown field fails', send('patch', { unset = { 'bogus' } }):match('^error:') ~= nil)

-- T-7: the panel always follows the step -------------------------------------------
reset()
send('load', { steps = { { file = f, title = 'First', panel = '# One', notes = { { line = 2, text = 'n' } } }, { file = g, title = 'Second' }, { file = f } } })
w.step(1)
check('T-7: step without panel shows its title', H.panel_text() == '# Second', H.panel_text())
w.step(1)
check('T-7: step without title shows the file name', H.panel_text():match('^# .*f%.txt$') ~= nil, H.panel_text())
w.step(-2)
check('T-7: going back shows the first panel again', H.panel_text():match('# One') and H.panel_text():match('### %[1%]'))

-- T-14: the code window's winbar is not touched ------------------------------------
reset()
vim.cmd('edit ' .. f)
vim.go.winbar = 'mine' -- global: a window-local value would not follow the window to another buffer
send('load', { group = 'Feature', steps = { { file = f, title = 'Look here' }, { file = g, title = 'Next' } } })
local code = st.code_win
check('T-14: code winbar untouched while a tour runs', vim.wo[code].winbar == 'mine', vim.wo[code].winbar)

local bar = H.panel_winbar()
check('T-14: panel winbar has step, group and title', bar:match('Step 1/2') and bar:match('Feature') and bar:match('Look here'), bar)
w.step(1)
bar = H.panel_winbar()
check('T-14: winbar follows the step', bar:match('Step 2/2') and bar:match('Next'), bar)
check('T-14: no keys that do not exist', not bar:match('%[w') and not bar:match('leader'), bar)
w.close()
check('T-14: code winbar untouched after close', vim.wo[code].winbar == 'mine')
vim.go.winbar = ''

-- T-10: no repository, no commits -----------------------------------------------------
reset()
local nogit = vim.fn.tempname()
vim.fn.writefile({ 'x', 'y' }, nogit)
res = send('load', { file = nogit, hunks = { { from = 1, to = 1 } }, notes = { { line = 2, text = 'n' } } })
check('T-10: file outside a repository loads', res == 'ok', res)
check('T-10: ... without an overlay, with its note', H.marks(function(d)
  return d.line_hl_group == 'WalkthroughAdded'
end) == 0 and badges() == 1)
check('T-10: diff against a ref outside a repository loads', send('load', { file = nogit, diff = 'main' }) == 'ok')
res = send('load', { file = nogit, diff = 'main', notes = { { line = 9 } } })
check('T-10: errors never carry git usage text', not res:match('usage') and not res:match('\n'), res)

reset()
local fresh = H.repo(nil, { ['n.txt'] = { 'one', 'two', 'three' } })
res = send('load', { file = fresh .. '/n.txt', hunks = { { from = 1, to = 2, group = 'A' } }, group = 'A' })
check('T-10: repository without commits loads', res == 'ok', res)
check('T-10: ... every line counts as new', H.marks(function(d)
  return d.sign_text == nil and d.line_hl_group == 'WalkthroughAdded'
end) == 2 and H.marks(function(d)
  return d.sign_text and vim.trim(d.sign_text) == '?'
end) == 1)
res = send('load', { file = fresh .. '/n.txt', diff = 'HEAD' })
check('T-10: ... also with an explicit HEAD', res == 'ok' and H.marks(function(d)
  return d.line_hl_group == 'WalkthroughAdded'
end) == 3, res)
vim.fn.system({ 'git', '-C', fresh, 'add', 'n.txt' })
send('patch', { diff = true })
check('T-10: a staged new file shows as staged', H.marks(function(d)
  return d.sign_text and vim.trim(d.sign_text) == '✓'
end) == 3 or H.marks(function(d)
  return d.line_hl_group == 'WalkthroughStaged'
end) == 3)

-- Unsaved changes (T-12) ----------------------------------------------------------------
reset()
local repo = H.repo({ ['u.txt'] = { 'u1', 'u2', 'u3' } }, { ['u.txt'] = { 'u1', 'U2', 'u3' } })
local uf = repo .. '/u.txt'
send('load', { file = uf, diff = true, from = 1, to = 2 })
check('T-12: overlay drawn for a saved buffer', H.marks(function(d)
  return d.line_hl_group == 'WalkthroughAdded'
end) == 1)
check('T-12: no notice yet', not H.panel_winbar():match('unsaved'))
vim.api.nvim_buf_set_lines(0, 2, 3, false, { 'typed' })
-- Typing fires these; a script edit needs the event sent by hand.
vim.api.nvim_exec_autocmds('TextChanged', { buffer = 0 })
check('T-12: unsaved notice appears at once', H.panel_winbar():match('unsaved changes: save to refresh') ~= nil, H.panel_winbar())
-- The file also changes on disk. checktime would raise FileChangedShell and,
-- in a real session, a prompt that blocks the remote caller.
local asked = false
vim.api.nvim_create_autocmd('FileChangedShell', {
  once = true,
  callback = function()
    asked = true
    vim.v.fcs_choice = ''
  end,
})
vim.fn.writefile({ 'u1', 'U2', 'u3', 'more on disk' }, uf)
check('T-12: patch of the focus does not run checktime', send('patch', { from = 2, to = 2 }) == 'ok' and not asked)
check('T-12: no overlay on an unsaved buffer', H.marks(function(d)
  return d.line_hl_group == 'WalkthroughAdded'
end) == 0)
check('T-12: the focus bar is still drawn', H.marks(function(d)
  return H.sign(d, '▎')
end) == 1)
check('T-12: unsaved notice stays', H.panel_winbar():match('unsaved') ~= nil)
vim.cmd('silent! edit!')
vim.wait(100)
check('T-12: notice goes away once saved or reloaded', not H.panel_winbar():match('unsaved'), H.panel_winbar())

-- Deleted lines are capped -------------------------------------------------------------
reset()
local long = {}
for i = 1, 20 do
  long[i] = 'l' .. i
end
local cut = vim.deepcopy(long)
for _ = 1, 15 do
  table.remove(cut, 3)
end
repo = H.repo({ ['c.txt'] = long }, { ['c.txt'] = cut })
send('load', { file = repo .. '/c.txt', diff = true })
local vl
for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, H.ns, 0, -1, { details = true })) do
  if m[4].virt_lines then
    vl = m[4].virt_lines
  end
end
check('cap: 10 removed lines and a summary', vl and #vl == 11 and vl[1][1][1] == '- l3' and vl[11][1][1] == '… 5 more removed lines',
  vim.inspect(vl))
w.setup({ max_removed_lines = 3 })
send('patch', { title = 'again' })
vl = nil
for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, H.ns, 0, -1, { details = true })) do
  if m[4].virt_lines then
    vl = m[4].virt_lines
  end
end
check('cap: configurable', vl and #vl == 4 and vl[4][1][1] == '… 12 more removed lines', vim.inspect(vl))
w.setup({ max_removed_lines = 10 })

-- Entry points never raise -------------------------------------------------------------------
reset()
for _, name in ipairs({ 'setup', 'load', 'patch', 'status', 'close', 'step', 'note', 'ask_line', 'stage_group',
  'with_tracked', 'clear', 'panel', 'annotate', 'keep_code_wide' }) do
  check('API: ' .. name, type(w[name]) == 'function')
end
check('socket: patch without a tour', send('patch', { title = 'x' }) == 'error: patch 1: no tour is open')
check('socket: patch of a non-object', (function()
  local p = vim.fn.tempname()
  vim.fn.writefile({ '3' }, p)
  return w.patch(p) == 'error: patch 1: must be an object'
end)())
check('socket: close returns ok', w.close() == 'ok')
check('socket: status without tour', w.status() == '{"step":0}')
log, find = H.capture_notify()
check('user: stage_group without a tour does not raise', pcall(w.stage_group))
check('user: ask_line without a tour does not raise', pcall(w.ask_line))
check('user: note without a tour does not raise', pcall(w.note, 1))

H.finish()
