-- P-10: the base version of the step's file in a float, and `path:line`
-- references in the panel.
local H = require('helpers')
local check, send, w = H.check, H.send, H.w
local st = _G.walkthrough_state
local log, find = H.capture_notify()
local function reset_log()
  for i = #log, 1, -1 do
    log[i] = nil
  end
end
local function lines(n, prefix)
  local out = {}
  for i = 1, n do
    out[i] = (prefix or 'l') .. i
  end
  return out
end
local function floats()
  return vim.tbl_filter(function(win)
    return vim.api.nvim_win_get_config(win).relative ~= ''
  end, vim.api.nvim_list_wins())
end

-- A repository with a file in a subdirectory, committed twice; the working
-- tree has three lines inserted above the focus and the focus line rewritten.
local dir = H.repo({ ['sub/x.lua'] = lines(10), ['b.txt'] = lines(4, 'b') }, {})
vim.cmd('cd ' .. vim.fn.fnameescape(dir))
local second = lines(10)
second[2] = 'second2'
vim.fn.writefile(second, dir .. '/sub/x.lua')
H.git_in(dir, 'commit', '-qam', 'second')
local work = { 'n1', 'n2', 'n3' }
vim.list_extend(work, second)
work[3 + 6] = 'changed6'
vim.fn.writefile(work, dir .. '/sub/x.lua')
local x = dir .. '/sub/x.lua'
local function open(step)
  w.discard()
  w.close()
  vim.cmd('silent! %bwipeout!')
  reset_log()
  assert(send('load', { group = 'A', steps = { vim.tbl_extend('force', { file = x }, step) } }) == 'ok')
end

-- Base view ---------------------------------------------------------------------------------
open({ from = 9, to = 10, diff = true })
w.base()
local fl = floats()
check('base: a float opened, nothing else', #fl == 1)
local win = fl[1]
local buf = vim.api.nvim_win_get_buf(win)
local expected = vim.split(H.git_in(dir, 'show', 'HEAD:sub/x.lua'), '\n', { plain = true })
check('base: its content is `git show HEAD:path`', vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), expected),
  vim.inspect(vim.api.nvim_buf_get_lines(buf, 0, -1, false)))
check('base: filetype of the file', vim.bo[buf].filetype == 'lua', vim.bo[buf].filetype)
check('base: read-only scratch buffer', vim.bo[buf].modifiable == false and vim.bo[buf].buftype == 'nofile')
check('base: the cursor is on the line of the focus start (three lines were inserted above)', vim.api.nvim_win_get_cursor(win)[1] == 6,
  vim.api.nvim_win_get_cursor(win)[1])
local cfg = vim.api.nvim_win_get_config(win)
check('base: centered', cfg.relative == 'editor' and math.abs((cfg.col + cfg.width / 2) - vim.o.columns / 2) <= 2
  and math.abs((cfg.row + cfg.height / 2) - vim.o.lines / 2) <= 3, vim.inspect(cfg))
vim.api.nvim_feedkeys('q', 'x', false)
check('base: q closes it', #floats() == 0)
w.base()
vim.api.nvim_feedkeys(vim.keycode('<Esc>'), 'x', false)
check('base: <Esc> closes it', #floats() == 0)

-- A step's own ref.
open({ from = 9, to = 9, diff = 'HEAD~1' })
w.base()
buf = vim.api.nvim_win_get_buf(floats()[1])
check('base: the step\'s ref is used', vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1] == 'l2', vim.inspect(vim.api.nvim_buf_get_lines(buf, 0, 3, false)))
check('base: ... and named in the title', vim.api.nvim_win_get_config(floats()[1]).title[1][1]:match('HEAD~1') ~= nil)
vim.api.nvim_feedkeys('q', 'x', false)
open({ from = 9, diff = false })
w.base()
check('base: diff = false falls back to HEAD', #floats() == 1)
vim.api.nvim_feedkeys('q', 'x', false)
open({})
w.base()
check('base: without a focus the cursor is on line 1', #floats() == 1 and vim.api.nvim_win_get_cursor(floats()[1])[1] == 1)
vim.api.nvim_feedkeys('q', 'x', false)

-- A file that does not exist at the base.
vim.fn.writefile({ 'new' }, dir .. '/fresh.lua')
w.discard()
w.close()
send('load', { file = dir .. '/fresh.lua' })
reset_log()
w.base()
local n = find('does not exist at HEAD')
check('base: a file missing at the base says so', n ~= nil and n.msg == 'walkthrough: fresh.lua does not exist at HEAD' and #floats() == 0, vim.inspect(log))
vim.cmd('Walkthrough base')
check(':Walkthrough base works', #log == 2 and #floats() == 0, vim.inspect(log))
w.close()
reset_log()
w.base()
check('base: no tour', find('no tour open') ~= nil)

-- References in the panel ---------------------------------------------------------------------------
vim.fn.writefile(lines(6, 'x'), dir .. '/b.txt')
open({
  from = 9, title = 'one',
  panel = {
    '# One', '',
    'It connects to `sub/x.lua:3` and `b.txt:2`.',
    'Absolute: ' .. dir .. '/b.txt:4.',
    'Not a file: nope/none.lua:1',
    'Plain text without a reference',
  },
})
local function panel_line(pattern)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(st.panel_buf, 0, -1, false)) do
    if l:match(pattern) then
      return i, l
    end
  end
end
local function press_enter(line, col)
  vim.api.nvim_set_current_win(st.panel_win)
  vim.api.nvim_win_set_cursor(st.panel_win, { line, col or 0 })
  vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'x', false)
end
local function code()
  local win = st.code_win
  return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)), vim.api.nvim_win_get_cursor(win)[1]
end
-- The file is relative to the repository root.
local i, l = panel_line('It connects')
press_enter(i, (l:find('b.txt', 1, true)))
local name, line = code()
check('reference: path:line under the cursor opens that file there (relative to the root)', name == dir .. '/b.txt' and line == 2, name .. ':' .. line)
check('reference: the cursor stays in the panel', vim.api.nvim_get_current_win() == st.panel_win)
-- Without the cursor on one, the first that exists.
press_enter(i, 0)
name, line = code()
check('reference: else the first one on the line', name == dir .. '/sub/x.lua' and line == 3, name .. ':' .. line)
-- Back to the current step.
vim.cmd('Walkthrough back')
name, line = code()
check('back: shows the current step again', name == x and line == 9 and vim.json.decode(w.status()).step == 1, name .. ':' .. line)
check('back: Lua API w.step(0)', (function()
  press_enter(i, 0)
  w.step(0)
  return (code()) == x
end)())
-- Absolute path.
press_enter((panel_line('^Absolute')))
name, line = code()
check('reference: absolute path', name == dir .. '/b.txt' and line == 4, name .. ':' .. line)
-- Relative to the working directory.
vim.fn.writefile(lines(6, 'y'), dir .. '/sub/only_here.txt')
w.step(0)
vim.api.nvim_set_current_win(st.panel_win)
vim.api.nvim_buf_call(st.panel_buf, function() end)
st.history[1].panel = 'See only_here.txt:5 now'
require('walkthrough.ui').show_panel(st.history[1], 1, 1)
vim.cmd('cd ' .. vim.fn.fnameescape(dir .. '/sub'))
press_enter((panel_line('only_here')))
name, line = code()
check('reference: relative to the working directory', name == dir .. '/sub/only_here.txt' and line == 5, name .. ':' .. line)
vim.cmd('cd ' .. vim.fn.fnameescape(dir))
-- A reference that does not exist, and a plain line, do nothing.
w.step(0)
local before = code()
press_enter((panel_line('^# One')) or 1)
check('reference: a line without one does nothing', (code()) == before)
st.history[1].panel = { 'Not a file: nope/none.lua:1' }
require('walkthrough.ui').show_panel(st.history[1], 1, 1)
press_enter(1)
check('reference: a missing file does nothing', (code()) == before and #log == 0, vim.inspect(log))
-- A line past the end is clamped.
st.history[1].panel = { 'Far: b.txt:999' }
require('walkthrough.ui').show_panel(st.history[1], 1, 1)
press_enter(1)
name, line = code()
check('reference: a line past the end is clamped', name == dir .. '/b.txt' and line == 6, name .. ':' .. line)
-- Note headings still work.
w.step(0)
send('patch', { note = 1, line = 10, text = 'ten' })
local nh = (panel_line('^### %[1%]'))
press_enter(nh)
check('reference: <CR> on a note heading still jumps to the note', vim.api.nvim_win_get_cursor(st.code_win)[1] == 10)

w.close()
vim.cmd('silent! %bwipeout!')
H.finish()
