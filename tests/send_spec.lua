-- The "ask" path: paths with spaces are escaped (T-8). claudecode.nvim itself
-- is replaced by stubs that record what they are asked.
local H = require('helpers')
local check, send, w = H.check, H.send, H.w

local calls = {}
for _, name in ipairs({ 'ClaudeCodeAdd', 'ClaudeCodeFocus' }) do
  vim.api.nvim_create_user_command(name, function(o)
    table.insert(calls, name .. ' ' .. o.args)
  end, { nargs = '*', force = true })
end
local typed = {}
package.loaded['claudecode.terminal'] = {
  send_to_terminal = function(text, opts)
    table.insert(typed, { text = text, submit = opts.submit })
  end,
}

local dir = H.work .. '/with space'
vim.fn.mkdir(dir)
local file = dir .. '/my file.txt'
vim.fn.writefile({ 'one', 'two', 'three' }, file)
send('load', { file = file, notes = { { line = 2, text = 'trim', verdict = 'simplify', detail = 'why' } } })
vim.api.nvim_win_set_cursor(0, { 2, 0 })
w.ask_line()

check('ask: three commands', #calls == 3, vim.inspect(calls))
check('ask: context file is first', calls[1] and calls[1]:match('^ClaudeCodeAdd .*%-walkthrough%-note%.md$') ~= nil, vim.inspect(calls))
check('ask: path with spaces is escaped', calls[2] == ('ClaudeCodeAdd %s/my\\ file.txt 2 2'):format(dir:gsub(' ', '\\ ')), vim.inspect(calls))
check('ask: agent is focused', calls[3] == 'ClaudeCodeFocus ')
check('ask: the context file holds the note', (function()
  local path = calls[1]:match('^ClaudeCodeAdd (.*)$')
  local text = table.concat(vim.fn.readfile(path), '\n')
  return text:match('Note %[1%] on') and text:match('verdict: simplify') and text:match('Inline: trim') and text:match('why')
end)())
vim.wait(1000, function()
  return #typed > 0
end, 20)
check('ask: simplify note pre-types a request without sending it', #typed == 1 and typed[1].submit == false
  and typed[1].text == 'Apply the simplification from note [1]: ', vim.inspect(typed))

-- Without claudecode `auto` falls back (here: the clipboard) and a forced
-- 'claudecode' tells the user, who never gets an error.
vim.api.nvim_del_user_command('ClaudeCodeAdd')
local _, find = H.capture_notify()
check('ask: no claudecode does not raise', pcall(w.ask_line))
check('ask: ... auto falls back to the clipboard', find('copied to the clipboard') ~= nil)
require('walkthrough.state').config.sender = 'claudecode'
check('ask: forced claudecode does not raise', pcall(w.ask_line))
check('ask: ... and says so', find('needs claudecode%.nvim') ~= nil)
require('walkthrough.state').config.sender = 'auto'

w.close()
H.finish()
