-- Where text is typed: the centered float (lua/walkthrough/input.lua) for a
-- question, a change request, a reply and the free text of plan feedback, and
-- `input = 'ui'` for those who have their own input UI. The other specs run
-- with `ui` (tests/init.lua) and stub vim.ui.input; this one runs the float.
--
-- Keys reach the float through nvim_feedkeys. A headless script starts Insert
-- mode only after the first key of the typeahead was run, so every typed text
-- starts with <C-l> (a redraw, harmless in Normal mode, not mapped by the
-- float): the text that follows shows that the float opened in Insert mode.
local H = require('helpers')
local check, send, w = H.check, H.send, H.w
local st = _G.walkthrough_state
local input = require('walkthrough.input')
local thread = require('walkthrough.thread')
local store = require('walkthrough.store')
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
local function press(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), 'x', false)
end
-- Text typed into a prompt that was just opened.
local function type_in(keys)
  press('<C-l>' .. keys)
end
local function title_of(win)
  local out = {}
  for _, chunk in ipairs(vim.api.nvim_win_get_config(win).title or {}) do
    table.insert(out, type(chunk) == 'table' and chunk[1] or chunk)
  end
  return table.concat(out)
end
local function footer_of(win)
  local out = {}
  for _, chunk in ipairs(vim.api.nvim_win_get_config(win).footer or {}) do
    table.insert(out, type(chunk) == 'table' and chunk[1] or chunk)
  end
  return table.concat(out)
end
local function buf_lines(win)
  return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
end

local sent = {}
st.config.sender = function(msg)
  table.insert(sent, msg)
end
-- `ui` mode must not be reached while the float is on.
local ui_calls = {}
vim.ui.input = function(opts, cb)
  table.insert(ui_calls, opts)
  cb(nil)
end
st.config.input = 'float'
check('the default of the option is the float', require('walkthrough.state').config.input == 'float')

local repo = H.repo({ ['a.txt'] = lines(30), ['b.txt'] = lines(6, 'b') }, {})
vim.cmd('cd ' .. vim.fn.fnameescape(repo))
local a = repo .. '/a.txt'
local function open()
  w.discard()
  w.close()
  vim.cmd('silent! %bwipeout!')
  vim.cmd('silent! only')
  reset_log()
  sent, ui_calls = {}, {}
  st.config.input = 'float'
  assert(send('load', { group = 'A', steps = { { file = a, title = 'one' }, { file = repo .. '/b.txt', title = 'two' } } }) == 'ok')
  vim.cmd('edit! ' .. vim.fn.fnameescape(a))
end
local function at(line, col)
  vim.api.nvim_set_current_win(st.code_win)
  vim.api.nvim_win_set_cursor(0, { line, col or 0 })
end
local function th(id)
  for _, x in ipairs(st.history[1].threads or {}) do
    if x.id == id then
      return x
    end
  end
end
-- A headless script never fires TextChanged (a running Neovim does, as soon as
-- the text changed): fire it here; the plugin's own handler resizes the window.
local function text_changed()
  vim.api.nvim_exec_autocmds('TextChanged', { buffer = vim.api.nvim_win_get_buf(input.win()) })
end
local function cancel_prompt()
  press('<C-l><Esc><Esc>')
end

-- The window ---------------------------------------------------------------------------------
vim.o.columns = 200
open()
at(7)
w.ask()
local win = input.win()
check('the question prompt is a float of its own', win ~= nil and vim.api.nvim_win_get_config(win).relative == 'editor'
  and vim.api.nvim_get_current_win() == win)
check('the title names what is written and where', title_of(win) == ' Question on a.txt:7 ', title_of(win))
check('the footer names the keys', footer_of(win):match('Enter') and footer_of(win):match('Ctrl%-j') and footer_of(win):match('Esc')
  and footer_of(win):match('q cancel'), footer_of(win))
check('it has a border', vim.api.nvim_win_get_config(win).border ~= nil and vim.api.nvim_win_get_config(win).border[1] ~= '')
local config = vim.api.nvim_win_get_config(win)
check('wide screen: 70 columns', config.width == 70, config.width)
local total_w, total_h = config.width + 2, config.height + 2
check('centered on the screen', math.abs(config.col * 2 + total_w - vim.o.columns) <= 1
  and math.abs(config.row * 2 + total_h - (vim.o.lines - vim.o.cmdheight)) <= 1, vim.inspect({ config.row, config.col, vim.o.lines }))
check('a small scratch buffer that can be edited', vim.bo[vim.api.nvim_win_get_buf(win)].buftype == 'nofile'
  and vim.bo[vim.api.nvim_win_get_buf(win)].modifiable == true and vim.bo[vim.api.nvim_win_get_buf(win)].bufhidden == 'wipe'
  and vim.api.nvim_win_get_config(win).height == 1)
check('long lines wrap', vim.wo[win].wrap == true)
type_in('typed')
check('it opens in Insert mode: what is typed is text', table.concat(buf_lines(win), '\n') == 'typed', vim.inspect(buf_lines(win)))
cancel_prompt()
check('Esc, Esc cancels: no window, no thread', input.win() == nil and #(st.history[1].threads or {}) == 0)
vim.o.columns = 100
at(7)
w.ask()
config = vim.api.nvim_win_get_config(input.win())
check('narrower screen: 60 % of it', config.width == 60, config.width)
cancel_prompt()
vim.o.columns = 200

-- The titles ------------------------------------------------------------------------------------
at(7)
w.change(nil, { 7, 9 })
check('title: a change request on a range', input.win() and title_of(input.win()) == ' Change request on a.txt:7-9 ', input.win() and title_of(input.win()))
cancel_prompt()
at(7)
w.change()
check('title: a change request on one line', input.win() and title_of(input.win()) == ' Change request on a.txt:7 ')
type_in('first request<CR>')
check('<CR> in Insert mode sends the text: a change request is collected', th('t1') and th('t1').kind == 'change'
  and th('t1').messages[1].text == 'first request' and th('t1').state == 'draft' and #sent == 0, vim.inspect(st.history[1].threads))
at(7)
w.ask()
check('title: a reply names the thread', input.win() and title_of(input.win()) == ' Reply in t1 ', input.win() and title_of(input.win()))
cancel_prompt()
local compact_title
do
  -- In the compact view the place is the entry's file and line, not the buffer's.
  st.tours[1].view = 'compact'
  require('walkthrough.ui').render(st.history[1], 1)
  local row
  for r, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
    if line:match('^%s*12 ') then
      row = r
    end
  end
  if row then
    vim.api.nvim_win_set_cursor(0, { row, 0 })
    w.ask()
    compact_title = input.win() and title_of(input.win())
    cancel_prompt()
  end
  st.tours[1].view = 'file'
  require('walkthrough.ui').render(st.history[1], 1)
end
check('title: in the compact view it still names the file and the line', compact_title == nil or compact_title == ' Question on a.txt:12 ',
  tostring(compact_title))

-- Sending ------------------------------------------------------------------------------------------
open()
at(5)
w.ask()
type_in('why five?<CR>')
local q = th('t1')
check('<CR> in Insert mode: a question is sent at once', q and q.kind == 'question' and q.messages[1].text == 'why five?'
  and q.state == 'waiting' and #sent == 1 and sent[1].text:match('User: why five%?'), vim.inspect(sent))
check('the prompt is closed after sending', input.win() == nil)
at(6)
w.ask()
type_in('why six?<Esc><CR>')
check('<CR> in Normal mode sends too', th('t2') and th('t2').messages[1].text == 'why six?' and #sent == 2 and input.win() == nil,
  vim.inspect(st.history[1].threads))

-- Several lines ----------------------------------------------------------------------------------------
open()
at(9)
w.change()
press('<C-l>line one<C-j>line two<CR>')
local c = th('t1')
check('<C-j> makes a second line and the text arrives with both', c and c.messages[1].text == 'line one\nline two', vim.inspect(c))
w.send()
check('send: the message keeps the lines as written', #sent == 1 and sent[1].text:match('User: line one\n         line two\n') ~= nil,
  sent[1] and sent[1].text)
local function virt_under(row)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, H.ns, { row - 1, 0 }, { row - 1, -1 }, { details = true })) do
    for _, vl in ipairs(m[4].virt_lines or {}) do
      table.insert(out, H.vtext(vl))
    end
  end
  return out
end
check('under the code the lines are wrapped as before', vim.deep_equal(virt_under(9), { '» t1 (waiting) you: line one', '                    line two' })
  or (virt_under(9)[1] or ''):match('line one') and (virt_under(9)[2] or ''):match('line two'), vim.inspect(virt_under(9)))
-- The window grows with the text, up to a limit.
open()
at(9)
w.change()
press('<C-l>a<C-j>b<C-j>c<Esc>')
text_changed()
local win3 = input.win()
check('the window grows with the lines', win3 and vim.api.nvim_win_get_config(win3).height == 3, win3 and vim.api.nvim_win_get_config(win3).height)
local top3 = win3 and vim.api.nvim_win_get_config(win3).row
press('i<C-j>d<C-j>e<C-j>f<C-j>g<C-j>h<C-j>i<C-j>j<C-j>k<C-j>l<C-j>m<Esc>')
text_changed()
check('... up to a sensible height', input.win() and vim.api.nvim_win_get_config(input.win()).height == 10,
  input.win() and vim.api.nvim_win_get_config(input.win()).height)
check('... and stays centered while it grows', top3 and input.win() and vim.api.nvim_win_get_config(input.win()).row < top3)
press('<Esc>')
check('a long text wraps and the window counts the wrapped lines', (function()
  open()
  at(9)
  w.change()
  press('<C-l>' .. string.rep('word ', 40) .. '<Esc>')
  text_changed()
  local h = input.win() and vim.api.nvim_win_get_config(input.win()).height
  press('<Esc>')
  return h and h >= 3
end)())

-- Cancelling ------------------------------------------------------------------------------------------------
open()
local got
local function ask_with_callback(opts)
  got = 'unset'
  input.ask(opts or { title = 'Question on a.txt:1' }, function(text)
    got = text
  end)
end
ask_with_callback()
press('<C-l>text<Esc><Esc>')
check('Esc in Insert mode only leaves it; Esc in Normal mode cancels', got == nil and input.win() == nil)
ask_with_callback()
press('<C-l>text<Esc>')
check('the first Esc only leaves Insert mode: the prompt stays', got == 'unset' and input.win() ~= nil)
press('q')
check('q in Normal mode cancels', got == nil and input.win() == nil)
ask_with_callback()
press('<C-l><CR>')
check('an empty text cancels', got == nil and input.win() == nil)
ask_with_callback()
press('<C-l>  <C-j>  <CR>')
check('a text of blanks cancels', got == nil and input.win() == nil)
ask_with_callback()
vim.api.nvim_win_close(input.win(), true)
check('closing the window cancels', H.wait(function()
  return got == nil
end) and input.win() == nil)
ask_with_callback()
local closing = input.win()
vim.api.nvim_set_current_win(closing)
vim.cmd('close')
check(':close cancels too', H.wait(function()
  return got == nil
end) and input.win() == nil)
ask_with_callback()
press('<C-l>keep<CR>')
check('the callback gets the text', got == 'keep')
ask_with_callback()
press('<C-l>  padded <C-j><CR>')
check('the text is trimmed', got == 'padded')
ask_with_callback()
local first = input.win()
ask_with_callback({ title = 'Reply in t9' })
check('opening a prompt cancels the one that was open', first ~= input.win() and not vim.api.nvim_win_is_valid(first)
  and input.win() ~= nil and title_of(input.win()) == ' Reply in t9 ')
press('<C-l><Esc><Esc>')
check('... and there is one window left to close', input.win() == nil)
-- The callback runs once even if the text is sent and the window is wiped after.
local calls = 0
input.ask({ title = 'x' }, function()
  calls = calls + 1
end)
press('<C-l>once<CR>')
vim.wait(50)
check('the callback runs once', calls == 1)
check('a callback that raises does not raise', pcall(function()
  input.ask({ title = 'x' }, function()
    error('boom')
  end)
  press('<C-l>boom<CR>')
end))

-- Focus, cursor and mode -----------------------------------------------------------------------------------------
open()
vim.cmd('vsplit ' .. vim.fn.fnameescape(repo .. '/b.txt'))
local other = vim.api.nvim_get_current_win()
at(14, 2)
local home = vim.api.nvim_get_current_win()
local wins = #vim.api.nvim_list_wins()
w.ask()
local floating = input.win()
check('the prompt is another window, focused', floating ~= home and vim.api.nvim_get_current_win() == floating)
type_in('where am I?<CR>')
check('after sending the focus is in the window it came from', vim.api.nvim_get_current_win() == home, vim.api.nvim_get_current_win())
check('... the cursor is where it was', vim.deep_equal(vim.api.nvim_win_get_cursor(home), { 14, 2 }), vim.inspect(vim.api.nvim_win_get_cursor(home)))
check('... the mode is Normal, not Insert', vim.api.nvim_get_mode().mode == 'n')
check('... no window was left behind', #vim.api.nvim_list_wins() == wins)
at(14, 2)
w.ask()
cancel_prompt()
check('after cancelling: the same', vim.api.nvim_get_current_win() == home and vim.deep_equal(vim.api.nvim_win_get_cursor(home), { 14, 2 })
  and vim.api.nvim_get_mode().mode == 'n' and #vim.api.nvim_list_wins() == wins)
at(14, 2)
w.ask()
vim.api.nvim_win_close(input.win(), true)
H.wait(function()
  return vim.api.nvim_get_current_win() == home
end)
check('after closing the window: the same', vim.api.nvim_get_current_win() == home and vim.api.nvim_get_mode().mode == 'n'
  and vim.deep_equal(vim.api.nvim_win_get_cursor(home), { 14, 2 }))
vim.api.nvim_set_current_win(other)
at(14, 2)
-- A prompt that came from Insert mode gives Insert mode back.
vim.keymap.set('i', '<F5>', function()
  input.ask({ title = 'from insert' }, function(text)
    got = text
  end)
end)
got = 'unset'
vim.cmd('enew')
press('i<F5>answer<CR>typed after<Esc>')
check('a prompt opened while typing gives Insert mode back', got == 'answer' and table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n') == 'typed after'
  and vim.api.nvim_get_mode().mode == 'n', vim.inspect({ got, vim.api.nvim_buf_get_lines(0, 0, -1, false) }))
vim.keymap.del('i', '<F5>')
vim.cmd('silent! bwipeout!')

-- From the thread float: the reply -----------------------------------------------------------------------------------
open()
at(5)
w.ask()
type_in('what is five?<CR>')
send('patch', { thread = 't1', answer = 'a number' })
at(5)
w.thread()
local tf = thread.win()
sent = {}
press('r')
check('the thread float opens the same prompt, titled with the thread', input.win() and input.win() ~= tf and title_of(input.win()) == ' Reply in t1 ')
-- The key press that opened the prompt already ran Insert mode out (nothing
-- was typed yet), so this one starts it by hand.
press('iand six?<CR>')
check('the reply is added and sent (a question), the focus is back in the thread float', #th('t1').messages == 3
  and th('t1').messages[3].text == 'and six?' and #sent == 1 and vim.api.nvim_get_current_win() == tf and thread.win() == tf,
  vim.inspect({ th('t1').messages, vim.api.nvim_get_current_win(), tf, thread.win() }))
press('q')

-- Plan feedback -----------------------------------------------------------------------------------------------------------
do
  w.discard()
  w.close()
  vim.cmd('silent! %bwipeout!')
  vim.cmd('silent! tabonly')
  vim.cmd('silent! only')
  local res = send('plan', {
    hook_event_name = 'PermissionRequest', tool_name = 'ExitPlanMode', session_id = 'input-session', cwd = H.work,
    tool_input = { plan = table.concat(lines(8, 'p'), '\n'), planFilePath = '/home/u/.claude/plans/x.md' },
  })
  local id = res
  w.plan_feedback()
  local pwin = input.win()
  check('plan feedback: the prompt is titled Plan feedback', pwin and title_of(pwin) == ' Plan feedback ', pwin and title_of(pwin))
  press('<C-l>add a rollback<C-j>and a test plan<CR>')
  local r = vim.json.decode(w.plan_result(id))
  check('plan feedback: the text with both lines becomes the feedback', r.state == 'feedback' and r.message:find('add a rollback', 1, true)
    and r.message:find('and a test plan', 1, true), vim.inspect(r))
  check('plan feedback: the prompt is closed', input.win() == nil)
  w.plan_feedback()
  cancel_prompt()
  check('plan feedback: cancelling sends nothing more', find('no feedback sent') ~= nil)
  pcall(w.plan_approve, id)
  w.close()
  vim.cmd('silent! tabonly')
end

-- input = 'ui' ----------------------------------------------------------------------------------------------------------------
open()
w.setup({ input = 'ui' })
check('setup: ui is accepted', st.config.input == 'ui')
at(7)
vim.ui.input = function(opts, cb)
  table.insert(ui_calls, opts)
  cb('from the ui')
end
w.ask()
check('ui: vim.ui.input is used, no float opens', #ui_calls == 1 and input.win() == nil and th('t1') and th('t1').messages[1].text == 'from the ui'
  and ui_calls[1].prompt:match('Your question on line 7'), vim.inspect(ui_calls))
at(7)
w.ask()
check('ui: a reply is prompted with its thread', ui_calls[2] and ui_calls[2].prompt:match('Reply in t1'), vim.inspect(ui_calls))
w.setup({ input = 'float' })
check('setup: float is accepted', st.config.input == 'float')
local ok, err = pcall(w.setup, { input = 'popup' })
check('setup rejects another value', not ok and tostring(err):match('input must be "float" or "ui"'), tostring(err))
check('... and keeps the option', st.config.input == 'float')
w.setup({ input = 'ui' })
st.config.input = 'float'
at(8)
w.ask()
check('float again after the option is set back', input.win() ~= nil and #ui_calls == 2)
cancel_prompt()

w.close()
vim.cmd('silent! %bwipeout!')
H.finish()
