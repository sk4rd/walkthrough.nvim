-- The panel is the map: every loaded tour of the repository, its entries with
-- their staged lines and titles, <CR> to open one. Staging is done with git
-- here, so the counts are tested without gitsigns.
local H = require('helpers')
local check, send, w = H.check, H.send, H.w
local st = _G.walkthrough_state
local ui = require('walkthrough.ui')
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

vim.o.columns = 200
-- backup.sh: lines 2-3 changed (2 lines). README.md: lines 2-4 (3 lines).
-- lib/usage.sh: line 5 (1 line). notes.txt is changed too, but in no tour
-- with ranges.
local repo = H.repo({
  ['backup.sh'] = lines(10), ['README.md'] = lines(10, 'r'), ['lib/usage.sh'] = lines(10, 'u'), ['notes.txt'] = lines(4, 'n'),
}, {
  ['backup.sh'] = with(lines(10), { [2] = 'B2', [3] = 'B3' }),
  ['README.md'] = with(lines(10, 'r'), { [2] = 'R2', [3] = 'R3', [4] = 'R4' }),
  ['lib/usage.sh'] = with(lines(10, 'u'), { [5] = 'U5' }),
  ['notes.txt'] = with(lines(4, 'n'), { [1] = 'N1' }),
})
vim.cmd('cd ' .. vim.fn.fnameescape(repo))
local backup, readme, usage, notes = repo .. '/backup.sh', repo .. '/README.md', repo .. '/lib/usage.sh', repo .. '/notes.txt'

local function panel_lines()
  return vim.api.nvim_buf_get_lines(st.panel_buf, 0, -1, false)
end
-- The row (1-based) of the first panel line that matches.
local function row_of(pattern)
  for i, l in ipairs(panel_lines()) do
    if l:match(pattern) then
      return i
    end
  end
end
local function width()
  return vim.api.nvim_win_get_width(st.panel_win)
end
-- An entry line as the map writes it: the counts end one cell before the edge.
local function entry(prefix, path, counts)
  local text = prefix .. path
  if not counts then
    return text
  end
  return text .. string.rep(' ', width() - 1 - vim.fn.strdisplaywidth(text) - #counts) .. counts
end
local function hl_on(row, hl)
  return H.marks(function(d, m)
    return m[2] == row - 1 and d.hl_group == hl
  end, st.panel_buf) > 0
end
-- Marks of the map live in their own namespace.
local map_ns = vim.api.nvim_get_namespaces().walkthrough_map
local function map_hl(row, hl, col)
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(st.panel_buf, map_ns, { row - 1, 0 }, { row - 1, -1 }, { details = true })) do
    if m[4].hl_group == hl and (col == nil or m[3] == col) then
      return true
    end
  end
  return false
end
local function counts_shown(pattern)
  return H.wait(function()
    return H.panel_text():match(pattern) ~= nil
  end)
end
local function press_enter_on(row)
  vim.api.nvim_set_current_win(st.panel_win)
  vim.api.nvim_win_set_cursor(st.panel_win, { row, 0 })
  vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'x', false)
end
local function code_file()
  return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(st.code_win))
end
-- The panel window of the tab, with a width that does not depend on how big
-- the headless screen is.
local function fix_width(n)
  vim.api.nvim_win_set_width(st.panel_win, n)
  ui.update_map()
end

-- Two tours with groups -------------------------------------------------------------------
assert(send('load', { group = 'Configurable destination', steps = {
  { file = backup, title = 'the destination can be set', hunks = { { from = 2, to = 3, group = 'Configurable destination' } } },
  { file = readme, title = 'documents the variable', hunks = { { from = 2, to = 4, group = 'Configurable destination' } } },
} }) == 'ok')
assert(send('load', { group = 'Usage check', steps = {
  { file = usage, title = 'adds the usage check', hunks = { { from = 5, group = 'Usage check' } } },
} }) == 'ok')
-- The second commit is added without taking over; the checks below start on it.
w.group('Usage check')
fix_width(40)
check('the panel is a plain scratch buffer: no filetype, no markdown', vim.bo[st.panel_buf].filetype == '' and vim.bo[st.panel_buf].buftype == 'nofile'
  and vim.bo[st.panel_buf].modifiable == false)
check('the panel window does not wrap: the map fits by itself', vim.wo[st.panel_win].wrap == false)
check('default panel_width is 40', require('walkthrough.state').config.panel_width == 40)

counts_shown('lib/usage%.sh%s+0/1')
check('map: every loaded tour of the repository, headed by its group', H.panel_text() == table.concat({
  'Configurable destination',
  entry('  ✓ ', 'backup.sh', '0/2'),
  '    the destination can be set',
  entry('    ', 'README.md', '0/3'),
  '    documents the variable',
  'Usage check',
  entry('> ✓ ', 'lib/usage.sh', '0/1'),
  '    adds the usage check',
}, '\n'), H.panel_text())
check('map: paths are relative to the repository root', row_of('^> ✓ lib/usage%.sh') ~= nil and not H.panel_text():find(repo, 1, true))

-- Highlights: the active heading, the marker, the dim parts --------------------------------
local usage_row = row_of('^> ✓ lib/usage')
check('highlight: the active tour\'s heading stands out, the other one does not', map_hl(row_of('^Usage check'), 'WalkthroughMapActive')
  and map_hl(row_of('^Configurable'), 'WalkthroughMapHeading') and not map_hl(row_of('^Configurable'), 'WalkthroughMapActive'))
check('highlight: the marker is on the shown entry only', map_hl(usage_row, 'WalkthroughMapMarker', 0)
  and not map_hl(row_of('^%s+✓ backup'), 'WalkthroughMapMarker'))
check('highlight: the seen mark is dim, and an entry not seen has none', map_hl(usage_row, 'WalkthroughMapSeen', 2)
  and map_hl(row_of('^%s+✓ backup'), 'WalkthroughMapSeen', 2) and not map_hl(row_of('^    README'), 'WalkthroughMapSeen'))
check('highlight: titles are dim, on their own line', map_hl(row_of('^    adds the usage'), 'WalkthroughMapTitle')
  and map_hl(row_of('^    the destination'), 'WalkthroughMapTitle'))
check('highlight: counts are marked', map_hl(usage_row, 'WalkthroughMapCount'))
check('the cursor of the panel is on the shown entry', vim.api.nvim_win_get_cursor(st.panel_win)[1] == usage_row)

-- The bar ------------------------------------------------------------------------------------
local function bar()
  return (H.panel_winbar():gsub('%%#[%w]*#', ''):gsub('%%%*', ''):gsub('%%%%', '%%'))
end
check('bar: group, staged of this tour, seen of this tour', counts_shown('0/1') and H.wait(function()
  return bar():match('^ Usage check  · staged 0/1 · seen 1/1') ~= nil
end), bar())
check('bar: the hints follow, with the reduced key list', bar():match('<CR> open · s stage · S stage all · %? all keys$') ~= nil, bar())

-- <CR> on an entry of another tour --------------------------------------------------------------
local readme_row = row_of('README%.md')
press_enter_on(readme_row)
check('<CR> on an entry of another tour switches to it and shows its file', status().group == 'Configurable destination' and status().step == 2
  and code_file() == readme, vim.inspect(status()))
check('<CR>: the cursor stays in the panel', vim.api.nvim_get_current_win() == st.panel_win)
check('<CR>: the marker and the heading follow, the entry is seen', H.panel_text():match('\n> ✓ README%.md') ~= nil
  and map_hl(row_of('^Configurable'), 'WalkthroughMapActive') and map_hl(row_of('^Usage'), 'WalkthroughMapHeading')
  and not H.panel_text():match('> ✓ lib/usage'), H.panel_text())
check('<CR>: the bar is that of the other tour', H.wait(function()
  return bar():match('^ Configurable destination  · staged 0/5 · seen 2/2') ~= nil
end), bar())
check('<CR>: the tour keeps where it was', st.tours[1].pos == 2 and st.tours[2].pos == 1)

-- <CR> on the title line opens the same entry --------------------------------------------------
press_enter_on(row_of('^    the destination can be set'))
check('<CR> on a title line opens its entry', status().step == 1 and code_file() == backup and H.panel_text():match('\n> ✓ backup%.sh') ~= nil,
  vim.inspect(status()))
press_enter_on(row_of('^    adds the usage check'))
check('<CR> on a title line of another tour', status().group == 'Usage check' and code_file() == usage)
-- On a heading the tour shows the step where it was left.
press_enter_on(row_of('^Configurable'))
check('<CR> on a heading shows that tour where it was left', status().group == 'Configurable destination' and status().step == 1
  and code_file() == backup)

-- A step that cannot be shown leaves everything as it was ----------------------------------------
local keep = vim.fn.readfile(readme)
vim.fn.delete(readme)
reset_log()
press_enter_on(row_of('README%.md'))
check('<CR> on an entry that cannot be shown reports it and changes nothing', find('cannot read file') ~= nil and status().step == 1
  and status().group == 'Configurable destination' and code_file() == backup and st.tours[1].pos == 1, vim.inspect(log))
vim.fn.writefile(keep, readme)

-- Staged lines per file, before and after staging ----------------------------------------------------
check('counts: nothing is staged yet', H.panel_text():match('backup%.sh%s+0/2') and H.panel_text():match('README%.md%s+0/3'), H.panel_text())
H.git_in(repo, 'add', 'backup.sh')
ui.refresh_progress(true)
check('counts: a staged file is complete, the others are not', H.panel_text():match('backup%.sh%s+2/2') ~= nil
  and H.panel_text():match('README%.md%s+0/3') ~= nil and H.panel_text():match('usage%.sh%s+0/1') ~= nil, H.panel_text())
check('counts: the bar sums the tour up', H.wait(function()
  return bar():match('^ Configurable destination  · staged 2/5 · seen') ~= nil
end), bar())
-- Part of a file: stage line 2 of README.md only.
local patch = vim.fn.tempname()
vim.fn.writefile({
  'diff --git a/README.md b/README.md', '--- a/README.md', '+++ b/README.md', '@@ -2 +2 @@', '-r2', '+R2',
}, patch)
H.git_in(repo, 'apply', '--cached', '--unidiff-zero', patch)
ui.refresh_progress(true)
check('counts: part of a file counts by line', H.panel_text():match('README%.md%s+1/3') ~= nil, H.panel_text())
-- The debounced path reaches the map as well (the refresh a stage causes).
H.git_in(repo, 'add', 'README.md')
vim.api.nvim_exec_autocmds('User', { pattern = 'GitSignsUpdate', data = { buffer = vim.fn.bufnr(backup) } })
check('counts: the refresh after a stage redraws the map by itself', counts_shown('README%.md%s+3/3'), H.panel_text())
H.git_in(repo, 'reset', '-q')
ui.refresh_progress(true)
check('counts: unstaging brings them back', H.panel_text():match('backup%.sh%s+0/2') ~= nil and H.panel_text():match('README%.md%s+0/3') ~= nil,
  H.panel_text())

-- No numbers without ranges or without a diff ---------------------------------------------------------
assert(send('load', { steps = {
  { file = notes, title = 'plain file, no ranges' },
  { file = usage, title = 'ranges but no diff', diff = false, hunks = { { from = 5 } } },
  { file = readme },
} }) == 'ok')
fix_width(40)
counts_shown('README')
check('an unnamed tour is headed Changes', row_of('^Changes$') ~= nil and map_hl(row_of('^Changes$'), 'WalkthroughMapActive'), H.panel_text())
check('no numbers for an entry without ranges or without a diff, and none for a file without a title line', (function()
  local r = row_of('^> ✓ notes%.txt$')
  return r ~= nil and panel_lines()[r + 1] == '    plain file, no ranges' and panel_lines()[r + 2] == '    lib/usage.sh'
    and panel_lines()[r + 3] == '    ranges but no diff' and panel_lines()[r + 4] == '    README.md' and panel_lines()[r + 5] == nil
end)(), H.panel_text())
check('bar: the unnamed tour is called Changes, with no staged part', H.wait(function()
  return bar():match('^ Changes  · seen 1/3') ~= nil and not bar():match('staged')
end), bar())
check('all three tours are in the map, in the order they were loaded', (function()
  local a, b, c = row_of('^Configurable'), row_of('^Usage check'), row_of('^Changes$')
  return a and b and c and a < b and b < c
end)(), H.panel_text())

-- The map follows patch, step, group and resume ---------------------------------------------------
send('patch', { step = 2, title = 'ranges but no diff, patched' })
check('patch: a title of another step is redrawn', row_of('^    ranges but no diff, patched$') ~= nil, H.panel_text())
w.step(1)
check('step: the marker moves', H.panel_text():match('\n  ✓ notes%.txt\n') ~= nil and H.panel_text():match('\n> ✓ lib/usage%.sh\n') ~= nil, H.panel_text())
w.group('Usage check')
check('group: the other tour is active', map_hl(row_of('^Usage check'), 'WalkthroughMapActive')
  and map_hl(row_of('^Changes$'), 'WalkthroughMapHeading') and H.panel_text():match('\n> ✓ lib/usage%.sh') ~= nil, H.panel_text())
-- The numbers come from a refresh of their own; compare what stays.
local function without_counts()
  return (H.panel_text():gsub('[ \t]+%d+/%d+', ''))
end
local before = without_counts()
w.close()
check('close: the map is gone', st.panel_win == nil)
check('resume', w.resume() == 'ok')
check('resume: the map is back as it was', without_counts() == before, H.panel_text())
check('resume: ... and the numbers are counted again', counts_shown('README%.md%s+0/3'), H.panel_text())
check('resume: the saved tours are all there', #st.tours == 3 and status().group == 'Usage check')

-- Another width: long paths are cut from the left, the counts stay at the edge ------------------------
w.close()
w.discard()
local deep = 'a/very/long/directory/name/for/a/script.sh'
vim.fn.mkdir(repo .. '/a/very/long/directory/name/for/a', 'p')
vim.fn.writefile(lines(5), repo .. '/' .. deep)
H.git_in(repo, 'add', deep)
vim.fn.writefile(with(lines(5), { [2] = 'S2' }), repo .. '/' .. deep)
assert(send('load', { group = 'Deep', steps = { { file = repo .. '/' .. deep, hunks = { { from = 2, group = 'Deep' } } } } }) == 'ok')
fix_width(30)
counts_shown('0/1')
local deep_line = panel_lines()[2]
check('narrow: the path is cut at the left, the file name stays', deep_line:match('^> ✓ ….*script%.sh%s+0/1$') ~= nil
  and vim.fn.strdisplaywidth(deep_line) <= width() - 1, deep_line)
vim.api.nvim_win_set_width(st.panel_win, 60)
-- A headless run never fires WinResized (a running Neovim does).
vim.api.nvim_exec_autocmds('WinResized', {})
check('wider: the map is laid out again for the new width', H.wait(function()
  return panel_lines()[2]:match('^> ✓ a/very/long/directory/name/for/a/script%.sh%s+0/1$') ~= nil
end), panel_lines()[2])

w.discard()
H.finish()
