-- The claudecode sender: the context file and the references, paths with
-- spaces escaped (T-8), and `submit`: one line typed and submitted with the
-- focus left alone, or typed without submitting and the focus moved.
-- claudecode.nvim itself is replaced by stubs that record what they are asked.
local H = require('helpers')
local check, send, w = H.check, H.send, H.w
local st = require('walkthrough.state')

local calls = {}
for _, name in ipairs({ 'ClaudeCodeAdd', 'ClaudeCodeFocus' }) do
  vim.api.nvim_create_user_command(name, function(o)
    table.insert(calls, name .. ' ' .. o.args)
  end, { nargs = '*', force = true })
end
local typed = {}
-- Claude's terminal: a terminal buffer with a job (`cat`), and what is
-- written to its channel.
local agent_buf, agent_chan
do
  local win = vim.api.nvim_get_current_win()
  vim.cmd('botright split')
  vim.cmd('terminal cat')
  agent_buf = vim.api.nvim_get_current_buf()
  agent_chan = vim.bo[agent_buf].channel
  vim.cmd('stopinsert')
  vim.cmd('hide')
  vim.api.nvim_set_current_win(win)
end
local keys = {}
local real_chan_send = vim.api.nvim_chan_send
vim.api.nvim_chan_send = function(chan, data)
  if chan == agent_chan then
    table.insert(keys, data)
  end
  return real_chan_send(chan, data)
end
package.loaded['claudecode.terminal'] = {
  send_to_terminal = function(text, opts)
    table.insert(typed, { text = text, submit = opts.submit })
  end,
  get_active_terminal_bufnr = function()
    return agent_buf
  end,
}

local dir = H.work .. '/with space'
vim.fn.mkdir(dir)
local file = dir .. '/my file.txt'
vim.fn.writefile({ 'one', 'two', 'three' }, file)
send('load', { file = file, notes = { { line = 2, text = 'trim', verdict = 'simplify', detail = 'why' } } })
vim.api.nvim_win_set_cursor(0, { 2, 0 })
st.config.sender = 'claudecode'
w.ask('why trim?')

check('ask: two commands, the context file and the line', #calls == 2, vim.inspect(calls))
check('ask: context file is first', calls[1] and calls[1]:match('^ClaudeCodeAdd .*%-walkthrough%-note%.md$') ~= nil, vim.inspect(calls))
check('ask: path with spaces is escaped', calls[2] == ('ClaudeCodeAdd %s/my\\ file.txt 2 2'):format(dir:gsub(' ', '\\ ')), vim.inspect(calls))
check('ask: submit is on by default', st.config.submit == true)
check('ask: the agent is not focused', not vim.tbl_contains(calls, 'ClaudeCodeFocus '), vim.inspect(calls))
check('ask: the context file holds the question and the finding', (function()
  local path = calls[1]:match('^ClaudeCodeAdd (.*)$')
  local text = table.concat(vim.fn.readfile(path), '\n')
  return text:match('Question t1 at') and text:match('User: why trim%?') and text:match('Finding %[1%] %(verdict: simplify%): trim')
    and text:match('Detail: why')
end)())
vim.wait(1000, function()
  return #typed > 0
end, 20)
-- Enter in the same write as the text is read as part of what was pasted and
-- submits nothing: the line is typed without it, and Enter follows on its own.
check('ask: one line is typed, without Enter', #typed == 1 and typed[1].submit == false and #keys == 0, vim.inspect({ typed, keys }))
check('ask: ... then Enter is pressed on its own in the agent terminal', H.wait(function()
  return #keys == 1
end) and keys[1] == '\r', vim.inspect(keys))
check('ask: ... it points at the context file', typed[1] and typed[1].text:match('^Walkthrough: act on the feedback in .*%-walkthrough%-note%.md')
  ~= nil and not typed[1].text:match('\n'), vim.inspect(typed))
check('ask: ... and the thread is waiting', _G.walkthrough_state.history[1].threads[1].state == 'waiting')

-- submit = false: as before, the line is typed but not sent and the focus moves.
calls, typed = {}, {}
check('setup accepts submit', pcall(w.setup, { submit = false }))
check('setup rejects a submit that is not a boolean', not pcall(w.setup, { submit = 'yes' }))
vim.api.nvim_win_set_cursor(0, { 3, 0 })
w.ask('and three?')
check('submit = false: the agent is focused', vim.tbl_contains(calls, 'ClaudeCodeFocus '), vim.inspect(calls))
vim.wait(1000, function()
  return #typed > 0
end, 20)
check('submit = false: the line is typed but not submitted', #typed == 1 and typed[1].submit == false
  and typed[1].text:match('^Walkthrough: act on the feedback in'), vim.inspect(typed))
vim.wait(500)
check('submit = false: no Enter follows', #keys == 1, vim.inspect(keys))
w.setup({ submit = true })

-- A claudecode.nvim that does not say which terminal is Claude's: it types
-- and submits by itself, as before.
do
  local term = package.loaded['claudecode.terminal']
  local get = term.get_active_terminal_bufnr
  term.get_active_terminal_bufnr = nil
  calls, typed, keys = {}, {}, {}
  require('walkthrough.send').send({ text = 'hello', refs = {} })
  vim.wait(1000, function()
    return #typed > 0
  end, 20)
  vim.wait(500)
  check('no known terminal: claudecode types and submits', #typed == 1 and typed[1].submit == true and #keys == 0, vim.inspect({ typed, keys }))
  term.get_active_terminal_bufnr = get
end

-- A prefill (a message from outside the thread flow) is what is typed, unsubmitted, when submit is off.
calls, typed = {}, {}
require('walkthrough.send').send({ text = 'hello', refs = {}, prefill = 'Apply it: ', submit = false })
vim.wait(1000, function()
  return #typed > 0
end, 20)
check('prefill: typed, not submitted, with the focus moved', #typed == 1 and typed[1].text == 'Apply it: ' and typed[1].submit == false
  and vim.tbl_contains(calls, 'ClaudeCodeFocus '), vim.inspect({ typed, calls }))

-- Without claudecode `auto` falls back (here: the clipboard) and a forced
-- 'claudecode' tells the user, who never gets an error.
vim.api.nvim_del_user_command('ClaudeCodeAdd')
local _, find = H.capture_notify()
st.config.sender = 'auto'
local reg = vim.fn.has('clipboard') == 1 and '+' or '"'
local keep = vim.fn.getreg(reg)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
check('ask: no claudecode does not raise', pcall(w.ask, 'fallback?'))
check('ask: ... auto falls back to the clipboard', find('copied to the clipboard') ~= nil)
vim.fn.setreg(reg, keep)
st.config.sender = 'claudecode'
vim.api.nvim_win_set_cursor(0, { 1, 0 })
check('ask: forced claudecode does not raise', pcall(w.ask, 'forced?'))
check('ask: ... says so and keeps the question as a draft', find('needs claudecode%.nvim') ~= nil and find('kept for send') ~= nil)
st.config.sender = 'auto'

w.close()
H.finish()
