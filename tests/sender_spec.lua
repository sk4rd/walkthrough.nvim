-- Senders (P-5): terminal (bracketed paste into a real :terminal, submitted or
-- not), clipboard, a function, and what `auto` picks. The claudecode sender
-- has its own tests in send_spec.lua. The messages come from asking a question.
local H = require('helpers')
local check, send, w = H.check, H.send, H.w
local st = _G.walkthrough_state
local sender = require('walkthrough.send')
local log, find = H.capture_notify()

local f = H.work .. '/f.txt'
send('load', { steps = { { file = f, title = 'one', notes = { { line = 2, text = 'trim', verdict = 'simplify' } } } } })
local code_win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_cursor(code_win, { 2, 0 })
-- Asking on `line`: every ask starts a new thread.
local function ask(line, text)
  st.history[1].threads = nil
  vim.api.nvim_set_current_win(code_win)
  vim.api.nvim_win_set_cursor(code_win, { line or 2, 0 })
  w.ask(text or 'why trim?')
end

local function terminal_lines(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
end
-- A terminal running `cat` in a split of the current tab, named as an agent.
local function agent_terminal(name, stay)
  vim.cmd('botright split')
  vim.cmd('terminal cat')
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_name(buf, name)
  local win = vim.api.nvim_get_current_win()
  vim.cmd('stopinsert')
  if not stay then
    vim.api.nvim_set_current_win(code_win)
  end
  return buf, win
end

-- auto: nothing to talk to ------------------------------------------------------
check('auto: no claudecode and no terminal gives the clipboard', sender.resolve() == 'clipboard')

-- clipboard ---------------------------------------------------------------------
st.config.sender = 'clipboard'
local reg = vim.fn.has('clipboard') == 1 and '+' or '"'
local saved_reg = vim.fn.getreg(reg)
check('clipboard: ask does not raise', pcall(ask))
local text = vim.fn.getreg(reg)
check('clipboard: the text is in the register (' .. reg .. ')', text:match('Question t1 at f%.txt:2, step 1') ~= nil
  and text:match('User: why trim%?') ~= nil and text:match('Finding %[1%] %(verdict: simplify%): trim') ~= nil
  and text:match('f%.txt:2%-2') ~= nil and text:match('{ "thread": "t1", "answer": "%.%.%." }') ~= nil, text)
check('clipboard: the user is told', find('copied to the clipboard') ~= nil)
check('clipboard: a question that was copied counts as sent', st.history[1].threads[1].state == 'waiting')
vim.fn.setreg(reg, saved_reg)

-- function ----------------------------------------------------------------------
local got
st.config.sender = function(msg)
  got = msg
end
ask()
check('function: receives the message', got ~= nil and got.text:match('User: why trim%?') ~= nil
  and #got.refs == 1 and got.refs[1].file == vim.fn.fnamemodify(f, ':p') and got.refs[1].from == 2 and got.refs[1].to == 2
  and got.prefill == nil, vim.inspect(got))
check('function: receives submit, on by default', got.submit == true)
st.config.submit = false
ask()
check('function: ... and false when the option is off', got.submit == false)
st.config.submit = true
ask(4)
check('function: a line without a finding sends the code and no finding', got.text:match('Question t%d+ at f%.txt:4, step 1') ~= nil
  and not got.text:match('Finding'), vim.inspect(got))
st.config.sender = function()
  error('boom', 0)
end
check('function: a failing sender is reported, not raised', pcall(ask) and find('boom') ~= nil)
check('function: ... and the question is kept', st.history[1].threads[1].state == 'draft')
st.config.sender = 'nonsense'
check('unknown sender is reported, not raised', pcall(ask) and find('unknown sender') ~= nil)
check('setup rejects an unknown sender', not pcall(w.setup, { sender = 'nonsense' }))
check('setup accepts a function sender', pcall(w.setup, { sender = function() end }))

-- terminal ----------------------------------------------------------------------
st.config.sender = 'terminal'
check('terminal: no terminal is an error message', pcall(ask) and find('no agent terminal found') ~= nil)

-- A terminal in another tab and one here: the one here wins.
vim.cmd('tabnew')
local other = agent_terminal('codex-elsewhere', true)
vim.cmd('tabprevious')
check('terminal: found by name, case-insensitively', sender.find_terminal() == other)
local buf, win = agent_terminal('Claude-Agent')
check('terminal: the one shown in this tab is preferred', sender.find_terminal() == buf)
check('auto: resolves to the terminal', (function()
  st.config.sender = 'auto'
  return sender.resolve() == 'terminal'
end)())
st.config.sender = 'terminal'

-- Not an agent: a terminal named otherwise is left alone.
local plain, plain_win = agent_terminal('just-a-shell')
vim.api.nvim_set_current_win(code_win)
check('terminal: other terminals are ignored', sender.find_terminal() == buf)
vim.api.nvim_win_close(plain_win, true)
vim.api.nvim_buf_delete(plain, { force = true })

local sent = {}
local real = vim.api.nvim_chan_send
vim.api.nvim_chan_send = function(chan, data)
  table.insert(sent, data)
  return real(chan, data)
end
ask()
check('terminal: the bracketed paste goes first, alone', #sent == 1 and sent[1]:sub(1, 6) == '\27[200~' and sent[1]:sub(-6) == '\27[201~'
  and not sent[1]:find('\r', 1, true), vim.inspect(sent))
-- Enter in the same write as the text is read as part of the paste: it is a
-- write of its own, after a pause.
check('terminal: ... then a carriage return on its own', H.wait(function()
  return #sent == 2
end) and sent[2] == '\r', vim.inspect(sent))
check('terminal: the bytes arrive', H.wait(function()
  local t = terminal_lines(buf)
  return t:match('Question t%d+ at f%.txt:2') and t:match('User: why trim%?')
end), terminal_lines(buf))
check('terminal: the focus stays in the code window', vim.api.nvim_get_current_win() == code_win and vim.fn.mode() == 'n')
check('terminal: the question is waiting', st.history[1].threads[1].state == 'waiting')

-- submit = false: as before, nothing is submitted and the focus moves.
st.config.submit = false
sent = {}
ask()
vim.api.nvim_chan_send = real
check('terminal, submit off: one bracketed paste', #sent == 1 and sent[1]:sub(1, 6) == '\27[200~' and sent[1]:sub(-6) == '\27[201~', vim.inspect(sent))
check('terminal, submit off: nothing is submitted (no newline before the end)', #sent == 1 and sent[1]:sub(-7, -7) ~= '\n'
  and sent[1]:sub(-7, -7) ~= '\r', vim.inspect(sent))
check('terminal, submit off: focus moves to the terminal window', vim.api.nvim_get_current_win() == win)
vim.cmd('stopinsert')
vim.api.nvim_set_current_win(code_win)
st.config.submit = true

-- A function that decides which terminal is an agent.
st.config.terminal_pattern = function(name)
  return name:match('Claude%-Agent') ~= nil
end
check('terminal_pattern: a function decides', sender.find_terminal() == buf)
st.config.terminal_pattern = function()
  return false
end
check('terminal_pattern: ... and can reject all', sender.find_terminal() == nil)
st.config.terminal_pattern = { 'agent' }
check('terminal_pattern: a custom list', sender.find_terminal() == buf)
st.config.terminal_pattern = { 'claude', 'codex', 'opencode', 'gemini', 'aider', '%f[%w]amp%f[%W]' }

-- The default list, against real terminals: these names are agents ...
vim.api.nvim_buf_delete(buf, { force = true })
vim.api.nvim_buf_delete(other, { force = true })
local function is_found(name)
  local tb, tw = agent_terminal(name)
  local found = sender.find_terminal() == tb
  vim.api.nvim_win_close(tw, true)
  vim.api.nvim_buf_delete(tb, { force = true })
  return found
end
for _, name in ipairs({ 'claude', 'Codex', 'opencode', 'gemini', 'aider --model x', 'amp', 'some/path/amp --x' }) do
  check('default pattern matches ' .. name, is_found(name))
end
-- ... and these are not.
for _, name in ipairs({ 'bash', 'camp', 'zsh sample', 'htop' }) do
  check('default pattern ignores ' .. name, not is_found(name))
end

-- auto with a (fake) claudecode ---------------------------------------------------
st.config.sender = 'auto'
vim.api.nvim_create_user_command('ClaudeCodeAdd', function() end, { nargs = '*', force = true })
check('auto: claudecode wins when its command exists', sender.resolve() == 'claudecode')
vim.api.nvim_del_user_command('ClaudeCodeAdd')
check('auto: ... and not otherwise', sender.resolve() == 'clipboard')

check(':checkhealth section runs', pcall(require('walkthrough.health').check))

w.close()
H.finish()
