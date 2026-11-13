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
for _, name in ipairs({ 'next', 'prev', 'note-next', 'note-prev', 'ask', 'stage', 'close', 'comment', 'send' }) do
  check('<Plug>(walkthrough-' .. name .. ') exists', vim.fn.maparg('<Plug>(walkthrough-' .. name .. ')', 'n') ~= '')
end
check('<Plug>(walkthrough-comment) exists in visual mode too', vim.fn.maparg('<Plug>(walkthrough-comment)', 'x') ~= '')

-- No keys by default, and the hints name none ---------------------------------------
check('no global key by default', vim.fn.maparg(']w', 'n') == '' and vim.fn.maparg('<leader>an', 'n') == '')
send('load', { group = 'A', steps = {
  { file = f, title = 'one', notes = { { line = 2, text = 'a' }, { line = 8, text = 'b' } } },
  { file = g, title = 'two' },
  { file = f, title = 'three' },
} })
local bar = H.panel_winbar()
check('hints: panel keys always', bar:match('<CR> jump to note') and bar:match('a ask'), bar)
check('hints: no global key is named when none is mapped', not bar:match('%]w') and not bar:match('%[w') and not bar:match('leader'), bar)

-- Subcommands ----------------------------------------------------------------------
vim.cmd('Walkthrough next')
check(':Walkthrough next', status().step == 2)
vim.cmd('Walkthrough prev')
check(':Walkthrough prev', status().step == 1)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.cmd('Walkthrough note-next')
check(':Walkthrough note-next', vim.api.nvim_win_get_cursor(0)[1] == 2)
vim.cmd('Walkthrough note-prev')
check(':Walkthrough note-prev finds no earlier note', find('no earlier note') ~= nil)
reset_log()
vim.cmd('Walkthrough status')
check(':Walkthrough status shows the status', log[1] and log[1].msg:match('step 1/3 of "A"') and log[1].msg:match('seen 2'), vim.inspect(log))
reset_log()
vim.cmd('Walkthrough stage')
check(':Walkthrough stage on a step without ranges says so', find('lists no group ranges') ~= nil, vim.inspect(log))
reset_log()
vim.cmd('Walkthrough stage everything')
check(':Walkthrough stage <bad arg> is an error', log[1] and log[1].level == vim.log.levels.ERROR, vim.inspect(log))
reset_log()
vim.cmd('Walkthrough group')
check(':Walkthrough group lists the tours', log[1] and log[1].msg:match('A: step 1/3'), vim.inspect(log))
reset_log()
vim.cmd('Walkthrough ask')
check(':Walkthrough ask reaches ask_line', #log >= 1 and not log[1].msg:match('unknown subcommand'), vim.inspect(log))

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
  for _, name in ipairs({ 'next', 'prev', 'note-next', 'note-prev', 'ask', 'stage', 'close', 'status', 'group', 'resume', 'discard' }) do
    if not vim.tbl_contains(c, name) then
      return false
    end
  end
  return true
end)())
check('completion: prefix', vim.deep_equal(complete('Walkthrough st'), { 'stage', 'status' }), vim.inspect(complete('Walkthrough st')))
check('completion: the user\'s commands', (function()
  local c = complete('Walkthrough ')
  for _, name in ipairs({ 'comment', 'comment-delete', 'decide', 'send', 'explain', 'check', 'reject', 'base', 'back' }) do
    if not vim.tbl_contains(c, name) then
      return false
    end
  end
  return true
end)())
check('completion: arguments', vim.deep_equal(complete('Walkthrough decide '), { 'accept', 'reject', 'clear' })
  and vim.deep_equal(complete('Walkthrough explain '), { 'simpler', 'deeper' })
  and vim.deep_equal(complete('Walkthrough check '), { 'reveal', 'answer' })
  and vim.deep_equal(complete('Walkthrough comment '), { 'question', 'issue', 'suggestion' }), vim.inspect(complete('Walkthrough comment ')))
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
check('<Plug>(walkthrough-stage) reaches stage_group', find('lists no group ranges') ~= nil)

-- keys = true: only keys that are still free ----------------------------------------------
vim.keymap.set('n', ']w', function() vim.g.my_own_key = true end)
check('setup(keys = true) works', pcall(w.setup, { keys = true }))
check('keys: an existing mapping is kept', vim.fn.maparg(']w', 'n', false, true).callback ~= nil)
local expect = {
  ['[w'] = 'prev', [']n'] = 'note-next', ['[n'] = 'note-prev',
  ['<leader>an'] = 'ask', ['<leader>gw'] = 'stage', ['<leader>aw'] = 'close',
  ['<leader>ac'] = 'comment', ['<leader>as'] = 'send',
}
for lhs, name in pairs(expect) do
  check('keys: ' .. lhs .. ' -> ' .. name, vim.fn.maparg(lhs, 'n', false, true).rhs == '<Plug>(walkthrough-' .. name .. ')')
end
check('keys: <leader>ac also comments on a selection', vim.fn.maparg('<leader>ac', 'x', false, true).rhs == '<Plug>(walkthrough-comment)')
vim.api.nvim_feedkeys(']w', 'x', false)
check('keys: pressing the kept key runs the user\'s function', vim.g.my_own_key == true)

-- Hints follow the mappings -----------------------------------------------------------------
w.step(1)
bar = H.panel_winbar()
check('hints: a mapped plug key is named', bar:match('%[w prev') and bar:match('%]n next note') and bar:match('an ask')
  and bar:match('stage') and bar:match('close'), bar)
check('hints: a key mapped to something else is not named', not bar:match('%]w next'), bar)
check('hints: panel keys remain', bar:match('<CR> jump to note') ~= nil)
check('hints: the new plug keys are named once mapped', bar:match('ac comment') and bar:match('as send'), bar)
check('hints: no check keys on a step without a check', not bar:match('r reveal') and not bar:match('e answer'), bar)

press('close')
check('<Plug>(walkthrough-close)', status().step == 0)
H.finish()
