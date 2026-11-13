-- T-9: the :Walkthrough command, <Plug> mappings, opt-in keys, and key hints
-- that name only keys that exist.
local H = require('helpers')
local check, send, w = H.check, H.send, H.w
local log, find = H.capture_notify()
local function status()
  return vim.json.decode(w.status())
end
local function reset_log()
  for i = #log, 1, -1 do
    log[i] = nil
  end
end
local f, g = H.work .. '/f.txt', H.work .. '/g.txt'

-- Defined, safe to source twice, and nothing is required by sourcing ----------------
local file = vim.api.nvim_get_runtime_file('plugin/walkthrough.lua', false)[1]
check('plugin file is on the runtimepath', file ~= nil)
check(':Walkthrough exists', vim.fn.exists(':Walkthrough') == 2)
local loaded = package.loaded.walkthrough
package.loaded.walkthrough = nil
check('sourcing twice works', pcall(vim.cmd.source, file) and pcall(vim.cmd.source, file))
check('sourcing does not load the module', package.loaded.walkthrough == nil)
package.loaded.walkthrough = loaded

-- <Plug> mappings ------------------------------------------------------------------
for _, name in ipairs({ 'next', 'prev', 'note-next', 'note-prev', 'ask', 'change', 'thread', 'thread-delete', 'stage', 'close', 'send', 'review' }) do
  check('<Plug>(walkthrough-' .. name .. ') exists', vim.fn.maparg('<Plug>(walkthrough-' .. name .. ')', 'n') ~= '')
end
for _, name in ipairs({ 'ask', 'change' }) do
  check('<Plug>(walkthrough-' .. name .. ') exists in visual mode too', vim.fn.maparg('<Plug>(walkthrough-' .. name .. ')', 'x') ~= '')
end

-- No keys by default, and the hints name none ---------------------------------------
check('no global key by default', vim.fn.maparg(']w', 'n') == '' and vim.fn.maparg('<leader>wa', 'n') == '')
send('load', { group = 'A', steps = {
  { file = f, title = 'one', notes = { { line = 2, text = 'a' }, { line = 8, text = 'b' } } },
  { file = g, title = 'two' },
  { file = f, title = 'three' },
} })
local bar = H.panel_winbar()
check('hints: panel keys always', bar:match('<CR> open') and bar:match('s stage') and bar:match('S stage all'), bar)
check('hints: no global key is named when none is mapped', not bar:match('%]w') and not bar:match('%[w') and not bar:match('leader'), bar)
check('hints: end with the cheat sheet key of the panel', bar:match('%? all keys$') ~= nil, bar)

-- Subcommands ----------------------------------------------------------------------
vim.cmd('Walkthrough next')
check(':Walkthrough next', status().step == 2)
vim.cmd('Walkthrough prev')
check(':Walkthrough prev', status().step == 1)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.cmd('Walkthrough note-next')
check(':Walkthrough note-next', vim.api.nvim_win_get_cursor(0)[1] == 2)
vim.cmd('Walkthrough note-prev')
check(':Walkthrough note-prev finds no earlier thread or finding', find('no earlier thread or finding') ~= nil)
reset_log()
vim.cmd('Walkthrough status')
check(':Walkthrough status shows the status', log[1] and log[1].msg:match('entry 1/3 of "A"') and log[1].msg:match('seen 2'), vim.inspect(log))
reset_log()
vim.cmd('Walkthrough stage')
-- A step without ranges is staged as a whole file (tests/progress_spec.lua);
-- here only that the command reaches it.
check(':Walkthrough stage reaches stage_group', find('gitsigns') ~= nil, vim.inspect(log))
reset_log()
vim.cmd('Walkthrough stage everything')
check(':Walkthrough stage <bad arg> is an error', log[1] and log[1].level == vim.log.levels.ERROR, vim.inspect(log))
reset_log()
vim.cmd('Walkthrough group')
check(':Walkthrough group lists the tours', log[1] and log[1].msg:match('A: entry 1/3'), vim.inspect(log))
reset_log()
local asked
require('walkthrough.state').config.sender = function(msg)
  asked = msg
end
vim.api.nvim_win_set_cursor(0, { 2, 0 })
vim.cmd('Walkthrough ask why is this here')
check(':Walkthrough ask reaches ask: a thread, sent', asked and asked.text:match('User: why is this here') and #log >= 1
  and not log[1].msg:match('unknown subcommand'), vim.inspect(log))
vim.cmd('Walkthrough change rename it')
check(':Walkthrough change on the lines of a question thread makes it a change request', _G.walkthrough_state.history[1].threads[1].messages[2].text == 'rename it'
  and _G.walkthrough_state.history[1].threads[1].kind == 'change' and #_G.walkthrough_state.history[1].threads == 1,
  vim.inspect(_G.walkthrough_state.history[1].threads))
vim.cmd('Walkthrough thread-delete')
check(':Walkthrough thread-delete', #(_G.walkthrough_state.history[1].threads or {}) == 0)

reset_log()
vim.cmd('Walkthrough frobnicate')
check('unknown subcommand: one-line error', #log == 1 and log[1].level == vim.log.levels.ERROR
  and log[1].msg:match('unknown subcommand "frobnicate"') and not log[1].msg:match('\n'), vim.inspect(log))
check('unknown subcommand did not change anything', status().step == 1)

-- Completion -----------------------------------------------------------------------
local function complete(line)
  return vim.fn.getcompletion(line, 'cmdline')
end
check('completion: all subcommands', (function()
  local c = complete('Walkthrough ')
  for _, name in ipairs({ 'next', 'prev', 'note-next', 'note-prev', 'ask', 'stage', 'close', 'status', 'group', 'resume', 'review', 'discard' }) do
    if not vim.tbl_contains(c, name) then
      return false
    end
  end
  return true
end)())
check('completion: prefix', vim.deep_equal(complete('Walkthrough st'), { 'stage', 'status' }), vim.inspect(complete('Walkthrough st')))
check('completion: the user\'s commands', (function()
  local c = complete('Walkthrough ')
  for _, name in ipairs({ 'ask', 'change', 'thread', 'thread-delete', 'decide', 'send', 'explain', 'reject', 'base', 'back' }) do
    if not vim.tbl_contains(c, name) then
      return false
    end
  end
  return true
end)())
check('completion: arguments', vim.deep_equal(complete('Walkthrough decide '), { 'accept', 'reject', 'clear' })
  and vim.deep_equal(complete('Walkthrough explain '), { 'simpler', 'deeper' })
  and vim.deep_equal(complete('Walkthrough ask '), {}), vim.inspect(complete('Walkthrough ask ')))
check('completion: the removed comment subcommands are gone', not vim.tbl_contains(complete('Walkthrough '), 'comment')
  and not vim.tbl_contains(complete('Walkthrough '), 'comment-delete'))
check('completion: the removed check subcommand is gone', not vim.tbl_contains(complete('Walkthrough '), 'check'))
check('completion: stage all', vim.deep_equal(complete('Walkthrough stage '), { 'all' }))
check('completion: group names', vim.deep_equal(complete('Walkthrough group '), { 'next', 'prev', 'A' }), vim.inspect(complete('Walkthrough group ')))

-- The Plug mappings do the same ------------------------------------------------------
local function press(plug)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Plug>(walkthrough-' .. plug .. ')', true, true, true), 'x', false)
end
press('next')
check('<Plug>(walkthrough-next)', status().step == 2)
press('prev')
check('<Plug>(walkthrough-prev)', status().step == 1)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
press('note-next')
check('<Plug>(walkthrough-note-next)', vim.api.nvim_win_get_cursor(0)[1] == 2)
press('note-prev')
press('stage')
check('<Plug>(walkthrough-stage) reaches stage_group', find('gitsigns') ~= nil)

-- keys = true: only keys that are still free ----------------------------------------------
vim.keymap.set('n', ']w', function() vim.g.my_own_key = true end)
check('setup(keys = true) works', pcall(w.setup, { keys = true }))
check('keys: an existing mapping is kept', vim.fn.maparg(']w', 'n', false, true).callback ~= nil)
local expect = {
  ['[w'] = 'prev', [']n'] = 'note-next', ['[n'] = 'note-prev',
  ['<leader>wa'] = 'ask', ['<leader>ws'] = 'stage', ['<leader>wq'] = 'close',
  ['<leader>wc'] = 'change', ['<leader>wt'] = 'thread', ['<leader>wX'] = 'thread-delete', ['<leader>wm'] = 'send',
  ['<leader>wr'] = 'review',
}
for lhs, name in pairs(expect) do
  check('keys: ' .. lhs .. ' -> ' .. name, vim.fn.maparg(lhs, 'n', false, true).rhs == '<Plug>(walkthrough-' .. name .. ')')
end
check('keys: <leader>wa and <leader>wc also work on a selection', vim.fn.maparg('<leader>wc', 'x', false, true).rhs == '<Plug>(walkthrough-change)'
  and vim.fn.maparg('<leader>wa', 'x', false, true).rhs == '<Plug>(walkthrough-ask)')
check('keys: the comment keys are gone', vim.fn.maparg('<leader>wi', 'n') == '' and vim.fn.maparg('<leader>wu', 'n') == '')
check('keys: the old agent-plugin keys are not taken', vim.fn.maparg('<leader>ac', 'n') == '' and vim.fn.maparg('<leader>as', 'n') == ''
  and vim.fn.maparg('<leader>an', 'n') == '' and vim.fn.maparg('<leader>gw', 'n') == '' and vim.fn.maparg('<leader>aw', 'n') == '')
vim.api.nvim_feedkeys(']w', 'x', false)
check('keys: pressing the kept key runs the user\'s function', vim.g.my_own_key == true)

-- Hints follow the mappings -----------------------------------------------------------------
w.step(1)
bar = H.panel_winbar()
check('hints: global keys are not listed, the cheat sheet key ends the bar', not bar:match('%[w') and not bar:match('%]n')
  and not bar:match('leader') and bar:match('%? all keys$'), bar)
check('hints: panel keys remain', bar:match('<CR> open') ~= nil)
check('hints: the removed panel keys are not named', not bar:match('a ask') and not bar:match('simpler') and not bar:match('reveal'), bar)

press('close')
check('<Plug>(walkthrough-close)', status().step == 0)
H.finish()
