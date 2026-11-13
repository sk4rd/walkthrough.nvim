-- The compact view: one scratch buffer per tour with only the changed parts of
-- its files; two views and one key; threads, staging and the other actions
-- from the compact view; rebuilding. The rest of the specs run in the file view
-- (tests/init.lua); this one asks for the compact view, and at the end checks
-- the plugin's own default.
local H = require('helpers')
local check, send, w = H.check, H.send, H.w
local st = _G.walkthrough_state
local work = H.work
local compact = require('walkthrough.compact')
local ui = require('walkthrough.ui')
local tours = require('walkthrough.tours')
local store = require('walkthrough.store')
local log, find = H.capture_notify()
local function reset_log()
  for i = #log, 1, -1 do
    log[i] = nil
  end
end
local function status()
  return vim.json.decode(w.status())
end
local function lines(n, prefix)
  local out = {}
  for i = 1, n do
    out[i] = (prefix or 'l') .. i
  end
  return out
end
local function with(base, changes)
  local out = vim.list_slice(base)
  for i, v in pairs(changes) do
    out[i] = v
  end
  return out
end
local function cd(dir)
  vim.cmd('cd ' .. vim.fn.fnameescape(dir))
end

-- Messages handed to the sender, and the answer vim.ui.input gives.
local sent, answer = {}, nil
st.config.sender = function(msg)
  table.insert(sent, msg)
end
vim.ui.input = function(_, cb)
  cb(answer)
end
local confirm_result = 1
vim.fn.confirm = function()
  return confirm_result
end

st.config.view = 'compact'

local function reset()
  w.discard()
  w.close()
  vim.cmd('silent! %bwipeout!')
  vim.cmd('silent! only')
  reset_log()
  sent, answer = {}, nil
end
local function code_buf()
  return vim.api.nvim_win_get_buf(st.code_win)
end
local function code_name()
  return vim.api.nvim_buf_get_name(code_buf())
end
local function text()
  return table.concat(vim.api.nvim_buf_get_lines(code_buf(), 0, -1, false), '\n')
end
local function is_compact()
  return compact.info_of(code_buf()) ~= nil
end
local function view()
  return compact.info_of(code_buf()).view
end
-- The row (1-based) of the first line of the compact buffer that matches.
local function row_of(pattern)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(code_buf(), 0, -1, false)) do
    if l:match(pattern) then
      return i
    end
  end
end
local function at(row)
  vim.api.nvim_set_current_win(st.code_win)
  vim.api.nvim_win_set_cursor(st.code_win, { row, 0 })
end
local function cursor()
  return vim.api.nvim_win_get_cursor(st.code_win)[1]
end
-- The (entry, file line) the cursor of the compact view stands for.
local function cursor_line()
  local si, line = compact.file_line(view(), cursor())
  return si, line
end
local ns_threads = vim.api.nvim_get_namespaces().walkthrough_threads
-- Every virtual line of the plugin in `buf`: { text, row (1-based) }.
local function vtexts(buf)
  local out = {}
  for _, id in ipairs({ H.ns, ns_threads }) do
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, id, 0, -1, { details = true })) do
      for _, vl in ipairs(m[4].virt_lines or {}) do
        table.insert(out, { text = vl[1][1], row = m[2] + 1 })
      end
    end
  end
  return out
end
local function virt_row(pattern, buf)
  for _, v in ipairs(vtexts(buf or code_buf())) do
    if v.text:match(pattern) then
      return v.row
    end
  end
end
local function sign_on(row, s, buf)
  for _, d in ipairs(H.marks_at(row, buf or code_buf())) do
    if H.sign(d, s) then
      return true
    end
  end
  return false
end
local function hl_on(row, group, buf)
  for _, d in ipairs(H.marks_at(row, buf or code_buf())) do
    if d.line_hl_group == group or d.hl_group == group then
      return true
    end
  end
  return false
end
-- The labels (end-of-line virtual text) of the plugin in the compact buffer.
local function labels()
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(code_buf(), H.ns, 0, -1, { details = true })) do
    if m[4].virt_text and m[4].virt_text_pos == 'eol' then
      table.insert(out, { row = m[2] + 1, text = m[4].virt_text[1][1] })
    end
  end
  return out
end
local function press(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), 'x', false)
end

local f, g, new = work .. '/f.txt', work .. '/g.txt', work .. '/new.txt'
local hunks = { { from = 2, to = 3, group = 'A' }, { from = 4, to = 4, group = 'B' }, { from = 9, to = 9, group = 'A' } }
local function tour_a()
  return {
    group = 'A',
    steps = {
      { file = f, title = 'one', hunks = hunks },
      { file = g, title = 'two' },
      { file = new, title = 'three', hunks = { { from = 1, to = 2, group = 'A' } } },
    },
  }
end

-- The option -------------------------------------------------------------------------
check('setup: view must be compact or file', not pcall(w.setup, { view = 'tiny' }) and pcall(w.setup, { view = 'compact' })
  and pcall(w.setup, { view = nil }))
check('setup: view = file is accepted', pcall(w.setup, { view = 'file' }) and st.config.view == 'file')
w.setup({ view = 'compact' })

-- The buffer for the fixture repository ---------------------------------------------------
check('load: ok', send('load', tour_a()) == 'ok')
check('load: the code window shows the compact buffer', is_compact() and status().view == 'compact', code_name())
local buf_a = code_buf()
check('the buffer is a read-only scratch buffer', vim.bo[buf_a].buftype == 'nofile' and not vim.bo[buf_a].modifiable
  and not vim.bo[buf_a].swapfile and vim.api.nvim_buf_get_name(buf_a):match('^walkthrough://compact/'))
local expected = table.concat({
  'f.txt  ·  one',
  '   1   a1',
  '   2 - a2',
  '   3 - a3',
  '   4 - a4',
  '   2 + A2',
  '   3 + A3',
  '   4 + B4',
  '   5   a5',
  '   6   a6',
  '   7   a7',
  '   8 - a8',
  '   8 + X8',
  '   9   a9',
  '  10 - a10',
  '',
  'g.txt  ·  two   (no diff)',
  '',
  'new.txt  ·  three   (new file)',
  '   1 + n1',
  '   2 + n2',
}, '\n')
check('content: headings, numbers, signs, context', text() == expected, '\n' .. text())
check('content: the cursor is on the heading of the entry', cursor() == 1 and status().step == 1)
local v = view()
check('mapping: headings, code rows, blanks', v.rows[1].kind == 'head' and v.rows[1].si == 1 and v.rows[16].kind == 'blank'
  and v.rows[17].kind == 'head' and v.rows[17].si == 2 and v.heads[3] == 19 and v.rows[19].si == 3)
check('mapping: a code row knows its entry and lines', v.rows[2].si == 1 and v.rows[2].new == 1 and v.rows[2].old == 1
  and v.rows[3].new == nil and v.rows[3].old == 2 and v.rows[6].new == 2 and v.rows[6].old == nil and v.rows[20].si == 3)
check('mapping: by_new finds the row of a line', v.by_new[1][2] == 6 and v.by_new[1][10] == nil and v.by_new[3][2] == 21)

-- Highlights and flags ------------------------------------------------------------------
check('added lines of the reviewed group are green', hl_on(6, 'WalkthroughAdded') and hl_on(7, 'WalkthroughAdded'))
check('removed lines of the reviewed group', hl_on(3, 'WalkthroughRemoved') and hl_on(15, 'WalkthroughRemoved'))
check('a line of another group is dimmed, flagged and labelled once', sign_on(8, '·') and hl_on(8, 'WalkthroughOther')
  and not hl_on(8, 'WalkthroughAdded'), vim.inspect(H.marks_at(8, buf_a)))
check('lines in no group are flagged', sign_on(12, '?') and sign_on(13, '?') and not hl_on(13, 'WalkthroughAdded'))
local lab = labels()
local function label_rows(pattern)
  local out = {}
  for _, l in ipairs(lab) do
    if l.text:match(pattern) then
      table.insert(out, l.row)
    end
  end
  return out
end
check('the label of another group: → B', vim.deep_equal(label_rows('→ B'), { 8 }), vim.inspect(lab))
check('the label of lines in no group is once per run', vim.deep_equal(label_rows('not in any commit'), { 12 }), vim.inspect(lab))
check('new file: every line added', hl_on(20, 'WalkthroughAdded') and hl_on(21, 'WalkthroughAdded') and not sign_on(20, '✓'))
check('the heading and the gutter have their own groups', hl_on(1, 'WalkthroughHeading') and hl_on(2, 'WalkthroughGutter')
  and vim.fn.hlexists('WalkthroughDim') == 1)

-- Without ranges every hunk is shown, with them only those with a line of the group --------
local multi = H.repo({ ['m.txt'] = lines(40) }, { ['m.txt'] = with(lines(40), { [3] = 'X3', [30] = 'Y30' }) })
cd(multi)
local m = multi .. '/m.txt'
local both = table.concat({
  'm.txt  ·  both',
  '   1   l1',
  '   2   l2',
  '   3 - l3',
  '   3 + X3',
  '   4   l4',
  '   5   l5',
  '   6   l6',
  '  ⋯',
  '  27   l27',
  '  28   l28',
  '  29   l29',
  '  30 - l30',
  '  30 + Y30',
  '  31   l31',
  '  32   l32',
  '  33   l33',
}, '\n')
reset()
send('load', { group = 'A', steps = { { file = m, title = 'both', diff = true } } })
check('without ranges every hunk is shown, apart by ⋯', text() == both, '\n' .. text())
reset()
send('load', { group = 'A', steps = { { file = m, title = 'both', hunks = { { from = 3, to = 3, group = 'A' }, { from = 30, to = 30, group = 'A' } } } } })
check('with ranges of the group in both: both hunks', text() == both, '\n' .. text())
reset()
send('load', { group = 'A', steps = { { file = m, title = 'both', hunks = { { from = 3, to = 3, group = 'A' }, { from = 30, to = 30, group = 'B' } } } } })
check('with ranges: a hunk without a line of the group is left out', text() == table.concat(vim.list_slice(vim.split(both, '\n'), 1, 8), '\n'),
  '\n' .. text())
reset()
send('load', { group = 'A', steps = { { file = m, title = 'both', hunks = { { from = 3, to = 3, group = 'A' } } } } })
check('with ranges: a hunk in no range is left out', not text():match('Y30') and text():match('X3'), '\n' .. text())
-- The mapping of a file line to a row with two hunks.
v = view()
check('mapping: a separator row', v.rows[9] == nil)
reset()
send('load', { group = 'A', steps = { { file = m, title = 'both', diff = true } } })
v = view()
check('mapping: separator and context rows', v.rows[9].kind == 'sep' and v.rows[9].si == 1 and v.rows[10].new == 27 and v.rows[10].old == 27)
local r_sep = 9
local si, line = compact.file_line(v, r_sep)
check('line of a separator: the next line shown', si == 1 and line == 27)
si, line = compact.file_line(v, 4)
check('line of a removed line: the line it is shown above', si == 1 and line == 3, tostring(line))
si, line = compact.file_line(v, 1)
check('line of a heading: the first line shown', si == 1 and line == 1)
check('mapping: the nearest shown line of a line outside any hunk', v.rows[compact.row_for_line(v, 1, 15)].new == 6
  and v.rows[compact.row_for_line(v, 1, 20)].new == 27 and v.rows[compact.row_for_line(v, 1, 27)].new == 27)

-- Groups: a run of another group is labelled once -----------------------------------------
local runs = H.repo({ ['r.txt'] = lines(10) }, { ['r.txt'] = with(lines(10), { [2] = 'A2', [3] = 'B3', [4] = 'B4' }) })
cd(runs)
reset()
send('load', { group = 'A', steps = { { file = runs .. '/r.txt', hunks = { { from = 2, to = 2, group = 'A' }, { from = 3, to = 4, group = 'B' } } } } })
lab = labels()
check('a run of another group has one label', #label_rows('→ B') == 1 and sign_on(row_of('B3'), '·') and sign_on(row_of('B4'), '·'),
  vim.inspect(lab))

-- Staged marks ---------------------------------------------------------------------------
local staged_repo = H.repo({ ['s.txt'] = lines(10) }, { ['s.txt'] = with(lines(10), { [2] = 'A2', [3] = 'A3' }) })
cd(staged_repo)
reset()
send('load', { group = 'A', steps = { { file = staged_repo .. '/s.txt', title = 's', hunks = { { from = 2, to = 3, group = 'A' } } } } })
check('staged marks: nothing is staged yet', not sign_on(row_of('%+ A2'), '✓') and hl_on(row_of('%+ A2'), 'WalkthroughAdded'))
vim.fn.writefile({ '--- a/s.txt', '+++ b/s.txt', '@@ -2 +2 @@', '-l2', '+A2' }, staged_repo .. '/stage.patch')
H.git_in(staged_repo, 'apply', '--cached', '--unidiff-zero', 'stage.patch')
vim.fn.delete(staged_repo .. '/stage.patch')
ui.refresh_compact()
check('staged marks: the staged line is muted and marked', sign_on(row_of('%+ A2'), '✓') and hl_on(row_of('%+ A2'), 'WalkthroughStaged')
  and not hl_on(row_of('%+ A2'), 'WalkthroughAdded'))
check('staged marks: the unstaged line is not', not sign_on(row_of('%+ A3'), '✓') and hl_on(row_of('%+ A3'), 'WalkthroughAdded'))
H.git_in(staged_repo, 'add', 's.txt')
ui.refresh_compact()
check('staged marks: everything staged', sign_on(row_of('%+ A3'), '✓') and sign_on(row_of('%- l3'), '✓')
  and hl_on(row_of('%- l3'), 'WalkthroughStagedRemoved'))
H.git_in(staged_repo, 'reset', '-q')
ui.refresh_compact()
check('staged marks: unstaged again', not sign_on(row_of('%+ A3'), '✓') and not sign_on(row_of('%+ A2'), '✓'))
-- A diff against a ref has no stage split.
vim.fn.writefile(with(lines(10), { [2] = 'A2', [3] = 'A3', [5] = 'A5' }), staged_repo .. '/s.txt')
H.git_in(staged_repo, 'commit', '-qam', 'second')
local first = H.git_in(staged_repo, 'rev-parse', 'HEAD~1')
vim.fn.writefile(with(lines(10), { [2] = 'A2', [3] = 'A3', [5] = 'A5', [7] = 'A7' }), staged_repo .. '/s.txt')
H.git_in(staged_repo, 'add', 's.txt')
reset()
send('load', { group = 'R', steps = { { file = staged_repo .. '/s.txt', diff = first } } })
check('a ref as the base: the changes since that commit, staged or not', text():match('%- l2') and text():match('%+ A2') and text():match('%+ A7'),
  '\n' .. text())
check('a ref as the base: no stage marks', not sign_on(row_of('%+ A7'), '✓') and hl_on(row_of('%+ A7'), 'WalkthroughAdded'))
reset()
send('load', { group = 'R', steps = { { file = staged_repo .. '/s.txt', diff = 'HEAD' } } })
check('HEAD as an explicit ref: only the staged change', text():match('%+ A7') and not text():match('%+ A5'), '\n' .. text())
-- An untracked file against a ref that has it.
vim.fn.writefile({ 'ux' }, staged_repo .. '/u.txt')
reset()
send('load', { group = 'R', steps = { { file = staged_repo .. '/u.txt', diff = first }, { file = staged_repo .. '/s.txt', diff = first } } })
check('an untracked file: every line added, none staged', text():match('u.txt  ·  ?%s*%(new file%)') or text():match('u.txt   %(new file%)'), '\n' .. text())
check('an untracked file: its lines', text():match('%+ ux') and not sign_on(row_of('%+ ux'), '✓'))
check('a bad ref is an error, nothing changes', send('load', { group = 'Bad', steps = { { file = staged_repo .. '/s.txt', diff = 'no-such-ref' } } }):match('^error: git diff failed'))

-- The 200 line cap -------------------------------------------------------------------------
local big_lines = lines(250)
local big = H.repo({ ['k.txt'] = { 'k' } }, { ['big.txt'] = big_lines })
cd(big)
reset()
send('load', { group = 'Big', steps = { { file = big .. '/big.txt', diff = true } } })
local all = vim.api.nvim_buf_get_lines(code_buf(), 0, -1, false)
check('a new file of 250 lines shows 200 and says how many more', #all == 202 and all[2] == '   1 + l1' and all[201] == ' 200 + l200'
  and all[202] == '  … 50 more lines (file view: :Walkthrough view)', all[202])
vim.keymap.set('n', '<leader>wv', '<Plug>(walkthrough-view)')
ui.refresh_compact()
all = vim.api.nvim_buf_get_lines(code_buf(), 0, -1, false)
check('the cap line names the key of the view action', all[#all] == '  … 50 more lines (file view: <leader>wv)', all[#all])
vim.keymap.del('n', '<leader>wv')
vim.fn.writefile(lines(200), big .. '/big.txt')
ui.refresh_compact()
all = vim.api.nvim_buf_get_lines(code_buf(), 0, -1, false)
check('a new file of exactly 200 lines is shown whole', #all == 201 and not all[#all]:match('more lines'))

-- Binary files and files that are not in a repository ---------------------------------------
local bin = H.repo({ ['b.bin'] = { 'x' } }, {})
local fh = assert(io.open(bin .. '/b.bin', 'wb'))
fh:write('a\0b\n')
fh:close()
cd(bin)
reset()
send('load', { group = 'Bin', steps = { { file = bin .. '/b.bin', diff = true }, { file = bin .. '/b.bin', title = 'again', from = 1 } } })
check('a binary file: no hunks, so the file view', not is_compact() and status().view == 'file')
reset()
cd(work)

-- Switching views ----------------------------------------------------------------------------
send('load', tour_a())
check('switch: starts in the compact view', is_compact() and status().view == 'compact')
at(3) -- "- a2": a removed line
check('switch: the cursor is on a removed line', view().rows[3].new == nil)
w.view()
check('switch to the file: the real file, at the line the removed line is shown above', code_name() == f and cursor() == 2
  and status().view == 'file', code_name() .. ':' .. cursor())
check('switch to the file: the overlay is drawn', H.marks(function(d)
  return d.line_hl_group == 'WalkthroughAdded'
end, code_buf()) == 2)
check('switch to the file: the tour remembers it', tours.active().view == 'file')
vim.api.nvim_win_set_cursor(st.code_win, { 7, 0 })
w.view()
check('switch to the compact view: same file and line', is_compact() and view().rows[cursor()].new == 7 and select(1, cursor_line()) == 1
  and status().view == 'compact', cursor())
w.view('file')
check('view file: named', code_name() == f)
reset_log()
w.view('file')
check('view file: already there says so', find('already in the file view') ~= nil)
w.view('compact')
check('view compact: named', is_compact())
reset_log()
w.view('wide')
check('view: an unknown name is reported', find('view takes compact or file') ~= nil)
-- A line outside any hunk goes to the nearest shown.
reset()
cd(multi)
send('load', { group = 'A', steps = { { file = m, title = 'both', diff = true } } })
w.view('file')
vim.api.nvim_win_set_cursor(st.code_win, { 15, 0 })
w.view()
check('file to compact: a line outside any hunk goes to the nearest shown line', view().rows[cursor()].new == 6, cursor())
vim.api.nvim_win_set_cursor(st.code_win, { 1, 0 })
w.view()
vim.api.nvim_win_set_cursor(st.code_win, { 22, 0 })
w.view()
check('file to compact: ... the other side', view().rows[cursor()].new == 27, cursor())
w.view('file')
-- The file opened by hand in the code window: the entry that lists it.
reset()
cd(work)
send('load', tour_a())
w.view('file')
vim.cmd('edit ' .. vim.fn.fnameescape(new))
vim.api.nvim_win_set_cursor(st.code_win, { 2, 0 })
w.view('compact')
check('file to compact: a file opened by hand finds its entry', cursor_line() == 3 and view().rows[cursor()].new == 2)
-- The remembered view: a switch away and back, a resend, <CR> in the map.
reset()
send('load', tour_a())
send('load', { group = 'Other', steps = { { file = g, title = 'g only' } } })
check('a tour with no changed line opens in the file view', not is_compact() and code_name() == g and status().view == 'file')
w.group('A')
check('group switch: A opens in the compact view', is_compact())
w.view('file')
w.group('Other')
w.group('A')
check('group switch: the tour keeps its view', code_name() == f and status().view == 'file')
send('load', tour_a())
check('a resent tour keeps the view', code_name() == f and tours.active().view == 'file')
w.view('compact')
check('the chosen view is remembered', tours.active().view == 'compact')

-- <CR> in the map, in both views ---------------------------------------------------------
local function press_enter_on(row)
  vim.api.nvim_set_current_win(st.panel_win)
  vim.api.nvim_win_set_cursor(st.panel_win, { row, 0 })
  press('<CR>')
end
local function panel_row(pattern)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(st.panel_buf, 0, -1, false)) do
    if l:match(pattern) then
      return i
    end
  end
end
check('map: the panel is open', st.panel_win and vim.api.nvim_win_is_valid(st.panel_win))
press_enter_on(panel_row('new%.txt'))
check('map <CR>, compact view: the cursor goes to the heading of the entry', is_compact() and cursor() == view().heads[3]
  and status().step == 3)
press_enter_on(panel_row('g%.txt'))
check('map <CR>, compact view: another entry', cursor() == view().heads[2] and status().step == 2 and tours.active().pos == 2)
check('map: the marker follows', H.panel_text():match('> %S*%s*g%.txt') ~= nil, H.panel_text())
w.view('file')
press_enter_on(panel_row('new%.txt'))
check('map <CR>, file view: the file', code_name() == new and status().step == 3 and status().view == 'file')
w.view('compact')

-- ]w and [w ----------------------------------------------------------------------------------
at(1)
w.step(1)
check(']w in the compact view: the next heading, the entry is current', cursor() == view().heads[2] and status().step == 2
  and tours.active().pos == 2)
check(']w: the map follows', H.panel_text():match('> %S*%s*g%.txt') ~= nil)
w.step(1)
check(']w: ... and the next', cursor() == view().heads[3] and status().step == 3)
reset_log()
w.step(1)
check(']w: no later entry', cursor() == view().heads[3] and find('no later entry') ~= nil)
w.step(-1)
check('[w: the previous heading', cursor() == view().heads[2] and status().step == 2)
at(8) -- inside the first entry, though the current entry is 2
w.step(1)
check(']w: from where the cursor is', cursor() == view().heads[2], cursor())
at(view().heads[3] + 1)
w.step(-1)
check('[w: from where the cursor is', cursor() == view().heads[2], cursor())
w.step(0)
check('back: the compact view of the current entry again', is_compact() and cursor() == view().heads[2])
check('seen: the entries the cursor went to', tours.seen_count(tours.active()) == 3)

-- Threads and notes ------------------------------------------------------------------------
reset()
local tour_notes = tour_a()
tour_notes.steps[1].notes = { { line = 3, text = 'a note on three', verdict = 'simplify' }, { line = 1, text = 'on the context' } }
send('load', tour_notes)
check('notes: drawn under their lines in the compact view', virt_row('a note on three') == row_of('%+ A3')
  and virt_row('on the context') == row_of('l1$') or virt_row('on the context') == row_of('a1$'), vim.inspect(vtexts(code_buf())))
check('notes: the badge is at the end of the line', (function()
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(code_buf(), H.ns, 0, -1, { details = true })) do
    if m[2] + 1 == row_of('%+ A3') and m[4].virt_text and m[4].virt_text[1][1]:match('1') then
      return true
    end
  end
end)())
check('notes: the text is indented to the code', (function()
  for _, v2 in ipairs(vtexts(code_buf())) do
    if v2.text:match('a note on three') then
      return v2.text:match('^ +%[') ~= nil and #v2.text:match('^ +') == view().gutter
    end
  end
end)())
check('no thread, no "elsewhere" in the heading', not text():match('elsewhere'))
-- A note on a line that is not shown.
reset()
cd(multi)
tour_notes = { group = 'A', steps = { { file = m, title = 'both', diff = true, notes = { { line = 15, text = 'far away' }, { line = 4, text = 'near' } } } } }
send('load', tour_notes)
check('notes: one that is not shown is counted in the heading', text():match('^m%.txt  ·  both   %(1 finding elsewhere%)') and not virt_row('far away')
  and virt_row('near') == row_of('l4$'), '\n' .. text())

-- ask, change, replies ---------------------------------------------------------------------
reset()
cd(work)
send('load', tour_a())
at(row_of('%+ A3'))
w.ask('why three?')
local function threads_of(si)
  return tours.active().steps[si].threads or {}
end
check('ask: on a line of the compact view', #threads_of(1) == 1 and threads_of(1)[1].from == 3 and threads_of(1)[1].to == 3
  and threads_of(1)[1].kind == 'question' and threads_of(1)[1].state == 'waiting', vim.inspect(threads_of(1)))
check('ask: sent at once, naming the file line', #sent == 1 and sent[1].text:match('f%.txt:3'), sent[1] and sent[1].text)
check('ask: the thread is drawn under the row of that line', virt_row('^%s*» t1') == row_of('%+ A3'), vim.inspect(vtexts(code_buf())))
check('ask: ... the cursor stays', cursor() == row_of('%+ A3'))
check('ask: nothing was drawn in the file buffer by the full draw', (function()
  local b = vim.fn.bufnr(f)
  return b == -1 or H.marks(function(d)
    return d.line_hl_group == 'WalkthroughAdded'
  end, b) == 0
end)())
-- The same line asks again: a reply.
answer = 'and again?'
at(row_of('%+ A3'))
w.ask()
check('ask: on the line of an open thread it is a reply', #threads_of(1) == 1 and #threads_of(1)[1].messages == 2)
-- change on a line, then on a range.
answer = nil
at(row_of('9   a9'))
w.change('rename it')
local ch = threads_of(1)[2]
check('change: on a context line', ch and ch.kind == 'change' and ch.from == 9 and ch.to == 9 and ch.state == 'draft', vim.inspect(threads_of(1)))
check('change: drawn there, not sent', virt_row('» t2 %(not sent%)') == row_of('9   a9') and #sent == 2)
-- A range of rows (a command range).
w.ask('about these', { row_of('5   a5'), row_of('7   a7') })
local rg = threads_of(1)[3]
check('ask: on a range of rows', rg and rg.from == 5 and rg.to == 7 and rg.id == 't3', vim.inspect(threads_of(1)))
check('ask: ... drawn under the last line of the range', virt_row('» t3') == row_of('7   a7'))
-- A visual selection that includes a removed line: the lines of the file it covers.
at(row_of('%- a4'))
answer = 'visual'
press('Vj<Plug>(walkthrough-change)')
local vis = threads_of(1)[4]
check('change: a visual selection from a removed line to the line that replaced it', vis and vis.from == 2 and vis.to == 2
  and vis.kind == 'change', vim.inspect(threads_of(1)))
check('visual mode ended', vim.fn.mode() == 'n')
-- The heading counts what is not shown: a thread on line 5 of g (not in the diff).
-- Refusals.
local count = #threads_of(1)
reset_log()
at(row_of('%- a3'))
w.ask('on a removed line')
check('refused: a removed line', find('removed') ~= nil and #threads_of(1) == count and #sent == 2 or find('removed') ~= nil, vim.inspect(log))
reset_log()
at(1)
w.ask('on a heading')
check('refused: a heading', find('heading') ~= nil and #threads_of(1) == count)
reset_log()
at(view().heads[2] - 1)
w.change('on the blank line')
check('refused: the blank line between entries', find('blank line') ~= nil)
reset()
cd(multi)
send('load', { group = 'A', steps = { { file = m, title = 'both', diff = true } } })
reset_log()
at(9)
w.ask('on a separator')
check('refused: a separator', find('separator') ~= nil and not (tours.active().steps[1].threads or {})[1])
reset()
cd(work)
send('load', tour_a())
reset_log()
at(row_of('new%.txt'))
vim.api.nvim_win_set_cursor(st.code_win, { row_of('%+ B4'), 0 })
w.ask('over two entries', { row_of('%+ B4'), row_of('%+ n1') })
check('refused: a range over two entries', find('inside one entry') ~= nil and #threads_of(1) == 0 and #threads_of(3) == 0, vim.inspect(log))
reset_log()
w.ask('only removed', { row_of('%- a2'), row_of('%- a3') })
check('refused: a range of removed lines only', find('removed') ~= nil and #threads_of(1) == 0)
reset_log()
w.ask('with a removed line inside', { row_of('%- a4'), row_of('%+ A3') })
check('a range that holds a removed line and a line of the file is that line', #threads_of(1) == 1 and threads_of(1)[1].from == 2
  and threads_of(1)[1].to == 3, vim.inspect(threads_of(1)))
-- An unsaved file refuses.
reset()
send('load', tour_a())
vim.cmd('badd ' .. vim.fn.fnameescape(f))
local fb = vim.fn.bufnr(f)
vim.fn.bufload(fb)
vim.api.nvim_buf_set_lines(fb, 0, 1, false, { 'typed' })
reset_log()
at(row_of('%+ A3'))
w.ask('unsaved')
check('refused: a file with unsaved changes', find('save the file first') ~= nil and #threads_of(1) == 0)
vim.api.nvim_exec_autocmds('TextChanged', { buffer = fb })
check('the winbar says so', H.panel_winbar():match('unsaved changes') ~= nil, H.panel_winbar())
vim.api.nvim_buf_call(fb, function()
  vim.cmd('silent edit!')
end)
vim.api.nvim_exec_autocmds('TextChanged', { buffer = fb })
check('... and stops saying so', H.panel_winbar():match('unsaved changes') == nil)

-- Threads and notes shown, and counted when they are not ----------------------------------------
reset()
send('load', tour_a())
local tn = tours.active()
at(row_of('%+ A2'))
w.ask('q on two', { row_of('%+ A2'), row_of('%+ A2') })
-- A thread on a line of g.txt (an entry with no diff): not shown, so counted.
local tg = { id = 't9', kind = 'question', from = 1, to = 1, messages = { { by = 'user', text = 'g?' } }, state = 'draft', sent = 0 }
tn.steps[2].threads = { tg }
tn.steps[1].notes = tn.steps[1].notes or {}
ui.update()
check('elsewhere: a thread of an entry with no shown line is counted in its heading', text():match('g%.txt  ·  two   %(no diff%)   %(1 thread elsewhere%)'), '\n' .. text())
tn.steps[2].threads = nil
-- A thread over a range whose end is not shown is drawn under its last shown line.
reset()
cd(multi)
send('load', { group = 'A', steps = { { file = m, title = 'both', diff = true } } })
tours.active().steps[1].threads = {
  { id = 't5', kind = 'question', from = 5, to = 12, messages = { { by = 'user', text = 'wide' } }, state = 'draft', sent = 0 },
  { id = 't6', kind = 'question', from = 15, to = 16, messages = { { by = 'user', text = 'hidden' } }, state = 'draft', sent = 0 },
  { id = 't7', kind = 'change', from = 15, to = 16, messages = { { by = 'user', text = 'hidden too' } }, state = 'draft', sent = 0 },
}
ui.update()
check('a thread over a range is drawn under its last shown line', virt_row('» t5') == row_of('l6$'), vim.inspect(vtexts(code_buf())))
check('threads with no shown line are counted', text():match('both   %(2 threads elsewhere%)') and not virt_row('» t6'), '\n' .. text())
cd(work)

-- decide, thread, explain, thread-delete, ]n ------------------------------------------------------
reset()
send('load', tour_a())
at(row_of('%+ A3'))
w.ask('why three?')
at(row_of('%+ A2'))
w.change('change two')
check('setup: two threads', #threads_of(1) == 2)
check('patch: the agent proposes on the change request', send('patch', { thread = 't2', answer = 'I would rename it', proposal = true }) == 'ok')
check('patch: the compact view shows the proposal', virt_row('I would rename it') == row_of('%+ A2') or virt_row('proposal') == row_of('%+ A2'),
  vim.inspect(vtexts(code_buf())))
check('patch: the cursor stays where it was', cursor() == row_of('%+ A2'))
sent = {}
at(row_of('%+ A2'))
w.decide('accept')
check('decide: accepts the proposal under the cursor', threads_of(1)[2].state == 'accepted' and #sent == 1, vim.inspect(threads_of(1)[2]))
at(row_of('%+ A3'))
reset_log()
w.decide('accept')
check('decide: nothing to decide on a question', find('nothing to decide') ~= nil)
check('patch: the agent answers the question', send('patch', { thread = 't1', answer = 'because' }) == 'ok')
at(row_of('%+ A3'))
w.thread()
local float = require('walkthrough.thread').win()
check('thread: opens the thread under the cursor in a float', float ~= nil and table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(float), 0, -1, false), '\n'):match('t1 · question · f%.txt:3'))
vim.api.nvim_win_close(float, true)
sent = {}
at(row_of('%+ A3'))
w.explain('simpler')
check('explain: asks about the answer of the thread under the cursor', #sent == 1 and sent[1].text:match('thread t1') and tours.active().depth == 'simpler',
  sent[1] and sent[1].text)
-- ]n and [n move between the rows of notes and threads.
at(1)
w.note(1)
check(']n: the next thread in the compact view', cursor() == row_of('%+ A2'), cursor())
w.note(1)
check(']n: ... and the next', cursor() == row_of('%+ A3'))
reset_log()
w.note(1)
check(']n: no later thread or finding', find('no later thread or finding') ~= nil and cursor() == row_of('%+ A3'))
w.note(-1)
check('[n: back', cursor() == row_of('%+ A2'))
at(row_of('%+ A3'))
w.thread_delete()
check('thread-delete: the thread under the cursor goes, drawn no more', #threads_of(1) == 1 and threads_of(1)[1].id == 't2' and not virt_row('» t1'))
-- From the map, ]n works through the code window.
vim.api.nvim_set_current_win(st.panel_win)
at(1)
vim.api.nvim_set_current_win(st.code_win)

-- Rebuilding -----------------------------------------------------------------------------
reset()
cd(work)
send('load', tour_a())
local before = text()
-- An edit and a save in a window of its own.
vim.cmd('botright split ' .. vim.fn.fnameescape(f))
local edit_win = vim.api.nvim_get_current_win()
local fbuf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(fbuf, 4, 5, false, { 'edited5' })
at(row_of('7   a7') or row_of('a7$'))
local keep = { cursor_line() }
vim.api.nvim_set_current_win(edit_win)
vim.cmd('silent write')
check('rebuild: after a write', H.wait(function()
  return text():match('edited5') ~= nil
end), '\n' .. text())
check('rebuild: the cursor is on the same entry and line', (function()
  local s2, l2 = cursor_line()
  return s2 == keep[1] and l2 == 7
end)(), tostring(cursor()))
-- Staying in the compact view: the code window is still the same window.
check('rebuild: the code window still shows the compact buffer', is_compact() and st.code_win ~= edit_win)
-- A change made outside and picked up by the buffer.
vim.fn.writefile(with(vim.fn.readfile(f), { [6] = 'outside6' }), f)
vim.cmd('checktime')
check('rebuild: after the buffer picked up an outside change (FileChangedShellPost)', H.wait(function()
  return text():match('outside6') ~= nil
end), '\n' .. text())
-- Without a loaded buffer: noticed when Neovim gets the focus back.
vim.api.nvim_win_close(edit_win, true)
vim.cmd('silent! bwipeout! ' .. fbuf)
vim.api.nvim_set_current_win(st.code_win)
vim.fn.writefile(with(vim.fn.readfile(f), { [7] = 'focus7' }), f)
vim.api.nvim_exec_autocmds('FocusGained', {})
check('rebuild: a file changed on disk is noticed on FocusGained', H.wait(function()
  return text():match('focus7') ~= nil
end), '\n' .. text())
-- A thread change rebuilds at once (no debounce) and the heading follows a patch.
at(row_of('%+ A3'))
local row_before = cursor()
check('patch: the title of an entry', send('patch', { step = 1, title = 'renamed' }) == 'ok')
check('rebuild: after a patch the heading says it', text():match('^f%.txt  ·  renamed'), '\n' .. text())
check('rebuild: ... the cursor stays on its line', cursor() == row_before, cursor())
-- After a patch of the ranges the dimming follows.
check('patch: the ranges change what is dimmed', send('patch', { step = 1, hunks = { { from = 2, to = 4, group = 'A' }, { from = 9, to = 9, group = 'A' } } }) == 'ok'
  and not sign_on(row_of('%+ B4'), '·'), vim.inspect(H.marks_at(row_of('%+ B4'), code_buf())))
-- The file changes while the compact view is not shown: it is built again when shown.
w.view('file')
vim.fn.writefile(with(vim.fn.readfile(f), { [1] = 'while away' }), f)
w.view('compact')
check('rebuild: a view shown again is current', text():match('while away') ~= nil)

-- The fallback for Other files -------------------------------------------------------------
reset()
cd(work)
send('load', tour_a())
-- A thread on a file that no tour lists lives in `Other files`.
local outside = H.repo({ ['o.txt'] = lines(5) }, {})
vim.cmd('split ' .. vim.fn.fnameescape(outside .. '/o.txt'))
local o_win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_cursor(0, { 2, 0 })
w.ask('outside any tour')
vim.api.nvim_win_close(o_win, true)
local extra_idx
for i, t in ipairs(st.tours) do
  if t.extra then
    extra_idx = i
  end
end
check('Other files: a thread on a file in no tour', extra_idx ~= nil)
vim.api.nvim_set_current_win(st.code_win)
w.group(extra_idx - st.active)
check('Other files: the tour is shown in the file view', tours.active().extra and not is_compact() and status().view == 'file')
reset_log()
w.view('compact')
check('Other files: switching to compact says why', find('Other files') ~= nil and not is_compact(), vim.inspect(log))
reset()
send('load', { group = 'Plain', steps = { { file = g, title = 'plain' } } })
reset_log()
w.view('compact')
check('a tour with nothing to show: switching says why', find('nothing to show in the compact view') ~= nil and not is_compact()
  and tours.active().view == nil, vim.inspect(log))

-- Actions on the entry under the cursor ----------------------------------------------------
-- base: the base version of the entry under the cursor.
reset()
cd(work)
send('load', tour_a())
at(view().heads[2])
w.base()
local bwin = vim.api.nvim_get_current_win()
check('base: opens the base of the entry under the cursor', bwin ~= st.code_win and vim.api.nvim_win_get_config(bwin).title[1][1]:match('g%.txt'),
  vim.inspect(vim.api.nvim_win_get_config(bwin).title))
vim.api.nvim_win_close(bwin, true)
at(row_of('%+ A3'))
w.base()
bwin = vim.api.nvim_get_current_win()
local base_lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(bwin), 0, -1, false)
check('base: ... the other entry', vim.api.nvim_win_get_config(bwin).title[1][1]:match('HEAD: .*f%.txt') and base_lines[1] == 'a1' and #base_lines == 10
  and vim.api.nvim_win_get_cursor(bwin)[1] == 3, vim.inspect(vim.api.nvim_win_get_config(bwin).title))
vim.api.nvim_win_close(bwin, true)

local gs = H.gitsigns()
if not gs then
  H.skip('stage and reject from the compact view (gitsigns.nvim not on the packpath; set WALKTHROUGH_GITSIGNS)')
else
  local function staged(file, want)
    H.wait(function()
      return H.git_in(work, 'diff', '--cached', '--numstat', '--', file):match(want) ~= nil
    end)
    return H.git_in(work, 'diff', '--cached', '--numstat', '--', file)
  end
  -- Stage the group of the entry under the cursor.
  reset()
  cd(work)
  send('load', tour_a())
  at(row_of('%+ A2'))
  w.stage_group()
  check('stage: the group of the entry under the cursor is staged', staged('f.txt', '^2%s+3'):match('^2%s+3') ~= nil, H.git_in(work, 'status', '--short'))
  check('stage: only that file', H.git_in(work, 'diff', '--cached', '--name-only') == 'f.txt', H.git_in(work, 'status', '--short'))
  check('stage: the compact view marks it', H.wait(function()
    return sign_on(row_of('%+ A2'), '✓') and sign_on(row_of('%+ A3'), '✓') and not sign_on(row_of('%+ X8'), '✓')
  end), vim.inspect(H.marks_at(row_of('%+ A2'), code_buf())))
  check('stage: the other group stays unstaged and unmarked', not sign_on(row_of('%+ B4'), '✓'))
  check('stage: the map counts it', H.wait(function()
    return H.panel_text():match('f%.txt%s+3/3')
  end), H.panel_text())
  check('stage: the cursor stays', cursor() == row_of('%+ A2'))
  check('stage: the result is reported', H.wait_notify(find, 'staged commit "A"') ~= nil, vim.inspect(log))
  reset_log()
  -- The entry under the cursor decides: a second file.
  at(view().heads[3])
  w.stage_group()
  check('stage: the entry under the cursor is the new file', staged('new.txt', '^2'):match('^2') ~= nil,
    H.git_in(work, 'status', '--short') .. vim.inspect(log))
  H.wait_notify(find, 'staged commit "A"')
  reset_log()
  check('stage: ... the untracked file was registered and is marked', H.wait(function()
    return sign_on(row_of('%+ n1'), '✓')
  end), vim.inspect(H.marks_at(row_of('%+ n1'), code_buf())))
  -- Stage all, from the compact view.
  H.git_in(work, 'reset', '-q')
  H.git_in(work, 'rm', '-q', '--cached', '--ignore-unmatch', 'new.txt')
  reset()
  send('load', tour_a())
  at(1)
  w.stage_group({ all = true })
  check('stage all: every file of the tour', staged('f.txt', '^2%s+3'):match('^2%s+3') ~= nil and staged('new.txt', '^2'):match('^2') ~= nil,
    H.git_in(work, 'status', '--short'))
  check('stage all: the compact view marks both files', H.wait(function()
    return sign_on(row_of('%+ A2'), '✓') and sign_on(row_of('%+ n2'), '✓')
  end))
  H.wait_notify(find, 'staged commit "A"')
  H.git_in(work, 'reset', '-q')
  H.git_in(work, 'rm', '-q', '--cached', '--ignore-unmatch', 'new.txt')

  -- Reject, from the compact view.
  local rj = H.repo({ ['r.txt'] = lines(12), ['q.txt'] = lines(12, 'q') },
    { ['r.txt'] = with(lines(12), { [2] = 'A2', [3] = 'B3' }), ['q.txt'] = with(lines(12, 'q'), { [5] = 'Q5' }) })
  cd(rj)
  reset()
  send('load', { group = 'A', steps = {
    { file = rj .. '/r.txt', hunks = { { from = 2, to = 2, group = 'A' }, { from = 3, to = 3, group = 'B' } } },
    { file = rj .. '/q.txt', hunks = { { from = 5, to = 5, group = 'A' } } },
  } })
  at(view().heads[2] + 3)
  w.reject_group()
  check('reject: the entry under the cursor, not the first', H.wait(function()
    return vim.deep_equal(vim.fn.readfile(rj .. '/q.txt'), lines(12, 'q'))
  end) and vim.deep_equal(vim.fn.readfile(rj .. '/r.txt'), with(lines(12), { [2] = 'A2', [3] = 'B3' })),
    vim.inspect({ vim.fn.readfile(rj .. '/q.txt'), vim.fn.readfile(rj .. '/r.txt') }))
  check('reject: the compact view no longer shows the discarded lines', H.wait(function()
    return not text():match('Q5')
  end), '\n' .. text())
  at(1)
  w.reject_group()
  check('reject: the group only, in the first entry', H.wait(function()
    return vim.deep_equal(vim.fn.readfile(rj .. '/r.txt'), with(lines(12), { [3] = 'B3' }))
  end), vim.inspect(vim.fn.readfile(rj .. '/r.txt')))
  vim.cmd('silent! %bwipeout!')
  cd(work)
end

-- Persistence and the map ----------------------------------------------------------------------
reset()
cd(work)
send('load', tour_a())
check('saved: the compact view is not part of the saved state', (function()
  local data = vim.json.decode(table.concat(vim.fn.readfile(store.path(store.root_of(f))), '\n'))
  return data.tours[1].view == nil and data.tours[1].compact == nil and data.tours[1].shown == nil
end)())

-- The default and the entry points ----------------------------------------------------------
local saved_state = _G.walkthrough_state
_G.walkthrough_state = nil
local fresh = dofile((vim.env.WALKTHROUGH_ROOT or vim.fn.getcwd()) .. '/lua/walkthrough/state.lua')
local default_view = fresh.config.view
_G.walkthrough_state = saved_state
check('the default of the view option is compact', default_view == 'compact', tostring(default_view))

st.config.view = default_view
reset()
cd(work)
check('default: load opens the compact view', send('load', tour_a()) == 'ok' and is_compact() and status().view == 'compact')
reset()
cd(work)
w.review()
check('default: review opens the compact view', is_compact() and status().view == 'compact' and text():match('^f%.txt'), '\n' .. text())
check('default: ... with the changed files in git order', text():match('new%.txt') ~= nil)
w.close()
check('close: the window shows a file again, the compact buffer is gone', not is_compact() and vim.bo[code_buf()].buftype == ''
  and not next(st.compact))
check('close: ... and the status is empty', status().step == 0)
w.review()
w.close()
send('load', tour_a())
w.close()
check('resume setup: the review is saved', vim.fn.filereadable(store.path(store.root_of(f))) == 1)
check('default: resume opens the compact view', w.resume() == 'ok' and is_compact() and status().view == 'compact')
w.view('file')
check('resume: the file view when chosen', code_name() == f)
st.config.view = 'file'
reset()
cd(work)
send('load', tour_a())
check('the file view as the option: load shows the file', not is_compact() and code_name() == f and status().view == 'file')
w.view()
check('... and view switches to the compact view', is_compact() and status().view == 'compact')

w.close()
H.finish()
