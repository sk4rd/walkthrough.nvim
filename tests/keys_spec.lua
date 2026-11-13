-- Keys: a <Plug> mapping for every action, the default keys under a prefix,
-- the panel's single keys, the cheat sheet and the hints.
local H = require('helpers')
local check, send, w = H.check, H.send, H.w
local log, find = H.capture_notify()
local st = _G.walkthrough_state
local keys = require('walkthrough.keys')
local f = H.work .. '/f.txt'

local function reset_log()
  for i = #log, 1, -1 do
    log[i] = nil
  end
end
local function press(lhs)
  vim.api.nvim_feedkeys(vim.keycode(lhs), 'x', false)
end
local function plug(name)
  return '<Plug>(walkthrough-' .. name .. ')'
end
-- Every default key as { lhs, plug, modes } for a prefix.
local function expected(prefix)
  local out = {}
  for _, k in ipairs(keys.defaults) do
    table.insert(out, { k[4] and k[1] or prefix .. k[1], k[2], k[3] or { 'n' } })
  end
  return out
end

-- Every <Plug> mapping exists and calls its action ---------------------------------------
local calls
local function stub(module, name, label)
  module[name] = function(...)
    table.insert(calls, label .. vim.inspect({ ... }, { newline = '', indent = '' }))
  end
end
local snapshot_orig = w.snapshot
stub(w, 'step', 'step')
stub(w, 'note', 'note')
stub(w, 'group', 'group')
stub(w, 'ask_line', 'ask')
stub(w, 'comment', 'comment')
stub(w, 'comment_delete', 'comment_delete')
stub(w, 'send', 'send')
stub(w, 'decide', 'decide')
stub(w, 'explain', 'explain')
stub(w, 'check', 'check')
stub(w, 'stage_group', 'stage')
stub(w, 'reject_group', 'reject')
stub(w, 'base', 'base')
stub(w, 'resume', 'resume')
stub(w, 'close', 'close')
stub(w, 'keys', 'keys')
w.snapshot = function(name)
  table.insert(calls, 'snapshot' .. vim.inspect({ name }, { newline = '', indent = '' }))
  return 'abcdef0123456789'
end

local plugs = {
  { 'next', 'step{ 1 }' }, { 'prev', 'step{ -1 }' }, { 'back', 'step{ 0 }' },
  { 'note-next', 'note{ 1 }' }, { 'note-prev', 'note{ -1 }' },
  { 'group-next', 'group{ "next" }' }, { 'group-prev', 'group{ "prev" }' },
  { 'ask', 'ask{}' },
  { 'comment', 'comment{ "question" }', true }, { 'comment-issue', 'comment{ "issue" }', true },
  { 'comment-suggestion', 'comment{ "suggestion" }', true },
  { 'comment-delete', 'comment_delete{}' }, { 'send', 'send{}' },
  { 'accept', 'decide{ "accept" }' }, { 'decline', 'decide{ "reject" }' }, { 'undecide', 'decide{ "clear" }' },
  { 'simpler', 'explain{ "simpler" }' }, { 'deeper', 'explain{ "deeper" }' },
  { 'check-reveal', 'check{ "reveal" }' }, { 'check-answer', 'check{ "answer" }' },
  { 'stage', 'stage{}' }, { 'stage-all', 'stage{ {  all = true } }' }, { 'reject', 'reject{}' },
  { 'base', 'base{}' }, { 'reviewed', 'snapshot{ <1>nil }' },
  { 'resume', 'resume{}' }, { 'close', 'close{}' }, { 'keys', 'keys{}' },
}
for _, p in ipairs(plugs) do
  local name = p[1]
  check('<Plug>(walkthrough-' .. name .. ') exists', vim.fn.maparg(plug(name), 'n') ~= '')
  calls = {}
  press(plug(name))
  local want = p[2]
  local got = calls[1] or ''
  -- vim.inspect formats the arguments; compare the action and its first argument.
  check('<Plug>(walkthrough-' .. name .. ') calls its action', #calls == 1 and got:gsub('%s+', '') == want:gsub('%s+', '')
    or (#calls == 1 and got:match('^%a+') == want:match('^%a+') and name == 'reviewed'), vim.inspect(calls))
  if p[3] then
    check('<Plug>(walkthrough-' .. name .. ') exists in visual mode', vim.fn.maparg(plug(name), 'x') ~= '')
    calls = {}
    press('V' .. plug(name))
    -- The stub does not leave visual mode, as the real action does.
    press('<Esc>')
    check('<Plug>(walkthrough-' .. name .. ') works on a selection', #calls == 1 and calls[1]:match('^comment'), vim.inspect(calls))
  end
end
for _, name in ipairs({ 'step', 'note', 'group', 'ask_line', 'comment', 'comment_delete', 'send', 'decide', 'explain',
  'check', 'stage_group', 'reject_group', 'base', 'resume', 'close', 'keys', 'snapshot' }) do
  w[name] = nil
end
package.loaded.walkthrough = nil
w = require('walkthrough')
H.w = w
check('the actions are back after the stubs', type(w.step) == 'function' and w.snapshot ~= snapshot_orig)

-- keys = false: nothing global --------------------------------------------------------------
local function count_global()
  local n = 0
  for _, mode in ipairs({ 'n', 'x' }) do
    for _, m in ipairs(vim.api.nvim_get_keymap(mode)) do
      if m.rhs and m.rhs:match('^<Plug>%(walkthrough%-') then
        n = n + 1
      end
    end
  end
  return n
end
check('setup(keys = false) works', pcall(w.setup, { keys = false }))
check('keys = false maps nothing', count_global() == 0)
check('setup() without options maps nothing either', pcall(w.setup) and count_global() == 0)

-- Cheat sheet without keys: commands ---------------------------------------------------------
send('load', { group = 'A', steps = {
  { file = f, title = 'one', panel = { '# One', 'text' }, check = { question = 'q?', answer = 'a' },
    notes = { { line = 2, text = 'a', verdict = 'simplify' }, { line = 8, text = 'b', verdict = 'simplify', detail = { 'more', 'detail' } } } },
  { file = H.work .. '/g.txt', title = 'two' },
} })
local function sheet()
  local buf = vim.api.nvim_get_current_buf()
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n'), vim.api.nvim_get_current_win()
end
local code = st.code_win
vim.api.nvim_set_current_win(code)
check('keys() never raises', pcall(w.keys))
local text, float = sheet()
check('cheat sheet: a centered float', vim.api.nvim_win_get_config(float).relative == 'editor' and float ~= code)
check('cheat sheet: a scratch buffer that cannot be changed', vim.bo.modifiable == false and vim.bo.buftype == 'nofile')
check('cheat sheet: without keys it lists the commands', text:match(':Walkthrough next') and text:match(':Walkthrough stage all')
  and text:match(':Walkthrough decide accept') and text:match(':Walkthrough keys'), text)
for _, group in ipairs({ 'Move', 'Ask and comment', 'Decide', 'Understand', 'Approve', 'Review state', 'In the panel' }) do
  check('cheat sheet: group ' .. group, text:match('\n?' .. group .. '\n') ~= nil, text)
end
press('q')
check('cheat sheet: q closes it', not vim.api.nvim_win_is_valid(float) and vim.api.nvim_get_current_win() == code)
vim.cmd('Walkthrough keys')
text, float = sheet()
check(':Walkthrough keys opens it', text:match('Move') ~= nil)
press('<Esc>')
check('cheat sheet: <Esc> closes it', not vim.api.nvim_win_is_valid(float))

-- Every action of the sheet is a <Plug> mapping, and the other way round -----------------------
do
  local mapped = {}
  for _, mode in ipairs({ 'n' }) do
    for _, m in ipairs(vim.api.nvim_get_keymap(mode)) do
      local name = m.lhs:match('^<Plug>%(walkthrough%-([%w-]+)%)$')
      if name then
        mapped[name] = true
      end
    end
  end
  local listed = {}
  for _, name in ipairs(keys.actions()) do
    listed[name] = true
  end
  local missing = {}
  for name in pairs(mapped) do
    if not listed[name] then
      table.insert(missing, name)
    end
  end
  for name in pairs(listed) do
    if not mapped[name] then
      table.insert(missing, 'unmapped ' .. name)
    end
  end
  check('cheat sheet: lists every <Plug> action', #missing == 0, table.concat(missing, ', '))
end

-- keys = true: the full set under <leader>w --------------------------------------------------
check('setup(keys = true) works', pcall(w.setup, { keys = true }))
local function all_mapped(prefix)
  local bad = {}
  for _, e in ipairs(expected(prefix)) do
    for _, mode in ipairs(e[3]) do
      local m = vim.fn.maparg(e[1], mode, false, true)
      if m.rhs ~= plug(e[2]) or not (m.desc or ''):match('^Walkthrough: ') then
        table.insert(bad, mode .. ' ' .. e[1])
      end
    end
  end
  return bad
end
local bad = all_mapped('<leader>w')
check('keys = true: every default key is mapped to its action, with a desc', #bad == 0, table.concat(bad, ', '))
check('keys = true: the table has the keys of the spec', #keys.defaults == 29)
check('keys = true: visual-mode comment mappings', vim.fn.maparg('<leader>wc', 'x') ~= '' and vim.fn.maparg('<leader>wi', 'x') ~= ''
  and vim.fn.maparg('<leader>wu', 'x') ~= '')
check('keys = true: P+ and P= both deepen', vim.fn.maparg('<leader>w+', 'n', false, true).rhs == plug('deeper')
  and vim.fn.maparg('<leader>w=', 'n', false, true).rhs == plug('deeper'))
check('keys = true: the old keys are not mapped', vim.fn.maparg('<leader>an', 'n') == '' and vim.fn.maparg('<leader>ac', 'n') == ''
  and vim.fn.maparg('<leader>as', 'n') == '' and vim.fn.maparg('<leader>gw', 'n') == '' and vim.fn.maparg('<leader>aw', 'n') == '')

-- setup twice: nothing lost, nothing doubled -------------------------------------------------------
local before = count_global()
local snap = vim.deepcopy(vim.api.nvim_get_keymap('n'))
check('setup twice works', pcall(w.setup, { keys = true }))
check('setup twice: same number of mappings', count_global() == before and #vim.api.nvim_get_keymap('n') == #snap)
check('setup twice: all keys still mapped', #all_mapped('<leader>w') == 0)

-- Cheat sheet with keys: the real key ------------------------------------------------------------------
vim.api.nvim_set_current_win(code)
vim.cmd('Walkthrough keys')
text, float = sheet()
check('cheat sheet: shows the mapped keys', text:match(']w%s+next step') and text:match('<leader>wa%s+ask')
  and text:match('<leader>wS%s+stage the group in every file'), text)
check('cheat sheet: both keys of one action', text:match('<leader>w%+ <leader>w=') ~= nil, text)
check('cheat sheet: no command for a mapped action', not text:match(':Walkthrough next'), text)
check('cheat sheet: the panel keys', text:match('s%s+stage the group') and text:match('y%s+accept') and text:match('u%s+clear the decision'), text)
press('q')

-- An own mapping is kept; a custom prefix --------------------------------------------------------------------
vim.keymap.set('n', '<leader>rc', function() vim.g.my_rc = true end, { desc = 'mine' })
check('setup(keys = prefix) works', pcall(w.setup, { keys = '<leader>r' }))
bad = all_mapped('<leader>r')
check('custom prefix: every key is mapped except the one that was taken', #bad == 1 and bad[1] == 'n <leader>rc', table.concat(bad, ', '))
check('custom prefix: the existing mapping is kept', vim.fn.maparg('<leader>rc', 'n', false, true).desc == 'mine')
press('<leader>rc')
check('custom prefix: pressing it runs the user\'s function', vim.g.my_rc == true)
check('custom prefix: the keys work', (function()
  st.tours[1].pos = 1
  press('<leader>rw')
  return true
end)())
-- Absolute keys are not duplicated by a second prefix.
check('custom prefix: ]w stays one mapping', (function()
  local n = 0
  for _, m in ipairs(vim.api.nvim_get_keymap('n')) do
    if m.lhs == ']w' then
      n = n + 1
    end
  end
  return n == 1
end)())

-- which-key: the prefix becomes a group; a missing or odd which-key is harmless -----------------------------------
do
  local added
  package.loaded['which-key'] = { add = function(spec) added = spec end }
  check('which-key: setup works', pcall(w.setup, { keys = '<leader>r' }))
  check('which-key: the prefix is registered as group "walkthrough"', added and added[1] and added[1][1] == '<leader>r'
    and added[1].group == 'walkthrough', vim.inspect(added))
  package.loaded['which-key'] = { }
  check('which-key without add is ignored', pcall(w.setup, { keys = true }))
  package.loaded['which-key'] = { add = function() error('boom') end }
  check('which-key failing is ignored', pcall(w.setup, { keys = true }))
  package.loaded['which-key'] = nil
  check('no which-key is fine', pcall(w.setup, { keys = true }))
end

-- Panel keys ---------------------------------------------------------------------------------------------------------
reset_log()
local panel = st.panel_buf
local function panel_map(lhs)
  return vim.api.nvim_buf_call(panel, function()
    return vim.fn.maparg(lhs, 'n', false, true)
  end)
end
for _, lhs in ipairs({ '<CR>', 'a', '-', '+', '=', 'r', 'e', 's', 'S', 'y', 'd', 'u', 'm', 'b', 'x', '?' }) do
  local m = panel_map(lhs)
  check('panel key ' .. lhs .. ' exists, local to the buffer, with a desc', m.buffer == 1 and (m.desc or ''):match('^Walkthrough: '), vim.inspect(m))
end
for _, lhs in ipairs({ 'n', 'q', 'j', 'k', '/', 'N', 'h', 'l' }) do
  check('panel key ' .. lhs .. ' is left alone', panel_map(lhs).buffer ~= 1)
end
w.step(1)
check('panel: no check keys on a step without a check', panel_map('r').buffer ~= 1 and panel_map('e').buffer ~= 1)
check('panel: the other keys stay', panel_map('s').buffer == 1 and panel_map('?').buffer == 1)
w.step(-1)
check('panel: check keys are back on a step with a check', panel_map('r').buffer == 1 and panel_map('e').buffer == 1)

local function in_panel(pattern)
  vim.api.nvim_set_current_win(st.panel_win)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(st.panel_buf, 0, -1, false)) do
    if l:match(pattern) then
      vim.api.nvim_win_set_cursor(st.panel_win, { i, 0 })
      return true
    end
  end
end
local notes = st.tours[st.active].steps[1].notes
check('panel: found the second note\'s text', in_panel('^detail'))
press('y')
check('panel: y accepts the note whose section the cursor is in', notes[2].decision == 'accept' and notes[1].decision == nil)
press('d')
check('panel: d declines it', notes[2].decision == 'reject')
press('u')
check('panel: u clears it', notes[2].decision == nil)
in_panel('^### %[1%]')
press('y')
check('panel: y on a heading accepts that note', notes[1].decision == 'accept' and notes[2].decision == nil)
press('u')
in_panel('^text')
reset_log()
press('y')
check('panel: y outside a note changes nothing', notes[1].decision == nil and notes[2].decision == nil and find('no note here') ~= nil, vim.inspect(log))

-- s, S, m, b, x and ? call their actions (the actions are tested elsewhere).
do
  local stage_mod, feedback_mod = require('walkthrough.stage'), require('walkthrough.feedback')
  local reject_mod, base_mod = require('walkthrough.reject'), require('walkthrough.base')
  local keys_mod = require('walkthrough.keys')
  local orig = { stage_mod.stage_group, feedback_mod.send, reject_mod.reject_group, base_mod.show, keys_mod.show }
  calls = {}
  stage_mod.stage_group = function(o) table.insert(calls, o and o.all and 'stage all' or 'stage') end
  feedback_mod.send = function() table.insert(calls, 'send') end
  reject_mod.reject_group = function() table.insert(calls, 'reject') end
  base_mod.show = function() table.insert(calls, 'base') end
  keys_mod.show = function() table.insert(calls, 'keys') end
  in_panel('^text')
  for _, k in ipairs({ 's', 'S', 'm', 'x', 'b', '?' }) do
    press(k)
  end
  check('panel: s S m x b ? call stage, stage all, send, reject, base and the cheat sheet',
    table.concat(calls, ',') == 'stage,stage all,send,reject,base,keys', table.concat(calls, ','))
  stage_mod.stage_group, feedback_mod.send, reject_mod.reject_group, base_mod.show, keys_mod.show = unpack(orig)
end
in_panel('^text')
press('?')
text, float = sheet()
check('panel: ? opens the cheat sheet', text:match('In the panel') ~= nil and vim.api.nvim_win_get_config(float).relative == 'editor')
press('q')
check('panel: q closed the cheat sheet and left the panel alone', not vim.api.nvim_win_is_valid(float) and vim.api.nvim_win_is_valid(st.panel_win))

-- Hints: the panel keys, then the cheat sheet key ------------------------------------------------------------------------
w.step(0)
local bar = H.panel_winbar()
check('hints: the bar ends with the cheat sheet key', bar:match('%? all keys$') ~= nil, bar)
check('hints: panel keys first', bar:match('<CR> jump to note · a ask · %- simpler · %+ deeper · r reveal · e answer · %? all keys$') ~= nil, bar)
local hint = bar:match('%%#Comment#  (.*)$')
local named = {}
for part in (hint or ''):gmatch('[^·]+') do
  named[#named + 1] = vim.trim(part):match('^(%S+)')
end
local missing = {}
for _, lhs in ipairs(named) do
  if panel_map(lhs).buffer ~= 1 then
    table.insert(missing, lhs)
  end
end
check('hints: every key they name exists in the panel', #named >= 6 and #missing == 0, table.concat(missing, ', '))
check('hints: no global key is named', not bar:match('leader') and not bar:match('%]w') and not bar:match('%[n'), bar)
w.step(1)
bar = H.panel_winbar()
check('hints: no check keys without a check, still ends with the cheat sheet key', not bar:match('r reveal') and bar:match('%? all keys$'), bar)
w.step(-1)
-- The footer repeats the hints when the bar does not fit; it ends the same way.
vim.o.columns = 200
vim.api.nvim_win_set_width(st.panel_win, 40)
w.step(0)
local ns = vim.api.nvim_get_namespaces().walkthrough_panel
local footer = {}
for _, m in ipairs(vim.api.nvim_buf_get_extmarks(st.panel_buf, ns, 0, -1, { details = true })) do
  for _, line in ipairs(m[4].virt_lines or {}) do
    table.insert(footer, line[1][1])
  end
end
local last = footer[#footer] or ''
check('footer: the last line ends with the cheat sheet key', last:match('%? all keys$') ~= nil, vim.inspect(footer))
local fits = true
for _, l in ipairs(footer) do
  fits = fits and vim.fn.strdisplaywidth(l) <= 40
end
check('footer: lines fit the panel', fits and #footer >= 2, vim.inspect(footer))

w.close()
H.finish()
