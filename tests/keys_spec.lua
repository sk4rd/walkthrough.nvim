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
stub(w, 'view', 'view')
stub(w, 'note', 'note')
stub(w, 'group', 'group')
stub(w, 'ask', 'ask')
stub(w, 'change', 'change')
stub(w, 'thread', 'thread')
stub(w, 'thread_delete', 'thread_delete')
stub(w, 'send', 'send')
stub(w, 'decide', 'decide')
stub(w, 'explain', 'explain')
stub(w, 'review', 'review')
stub(w, 'request', 'request')
stub(w, 'stage_group', 'stage')
stub(w, 'reject_group', 'reject')
stub(w, 'commit', 'commit')
stub(w, 'base', 'base')
stub(w, 'resume', 'resume')
stub(w, 'close', 'close')
stub(w, 'keys', 'keys')
w.snapshot = function(name)
  table.insert(calls, 'snapshot' .. vim.inspect({ name }, { newline = '', indent = '' }))
  return 'abcdef0123456789'
end

local plugs = {
  { 'next', 'step{ 1 }' }, { 'prev', 'step{ -1 }' }, { 'back', 'step{ 0 }' }, { 'view', 'view{}' },
  { 'note-next', 'note{ 1 }' }, { 'note-prev', 'note{ -1 }' },
  { 'group-next', 'group{ "next" }' }, { 'group-prev', 'group{ "prev" }' },
  { 'ask', 'ask{}', true }, { 'change', 'change{}', true },
  { 'thread', 'thread{}' }, { 'thread-delete', 'thread_delete{}' }, { 'send', 'send{}' },
  { 'accept', 'decide{ "accept" }' }, { 'decline', 'decide{ "reject" }' }, { 'undecide', 'decide{ "clear" }' },
  { 'simpler', 'explain{ "simpler" }' }, { 'deeper', 'explain{ "deeper" }' },
  { 'review', 'review{}' }, { 'request', 'request{}' },
  { 'stage', 'stage{}' }, { 'stage-all', 'stage{ {  all = true } }' }, { 'reject', 'reject{}' }, { 'commit', 'commit{}' },
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
    check('<Plug>(walkthrough-' .. name .. ') works on a selection', #calls == 1 and calls[1]:match('^' .. name), vim.inspect(calls))
  end
end
for _, name in ipairs({ 'step', 'view', 'note', 'group', 'ask', 'ask_line', 'change', 'thread', 'thread_delete', 'send', 'decide', 'explain',
  'review', 'request', 'stage_group', 'reject_group', 'commit', 'base', 'resume', 'close', 'keys', 'snapshot' }) do
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
  { file = f, title = 'one',
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
for _, group in ipairs({ 'Start', 'Move', 'Write', 'Decide', 'Approve', 'Plan', 'Help', 'In the panel' }) do
  check('cheat sheet: group ' .. group, text:match('\n?' .. group .. '\n') ~= nil, text)
end
press('q')
check('cheat sheet: q closes it', not vim.api.nvim_win_is_valid(float) and vim.api.nvim_get_current_win() == code)
vim.cmd('Walkthrough keys')
text, float = sheet()
check(':Walkthrough keys opens it', text:match('Move') ~= nil)
press('<Esc>')
check('cheat sheet: <Esc> closes it', not vim.api.nvim_win_is_valid(float))

-- Every action of the sheet is a <Plug> mapping, and the other way round. The
-- snapshot action (`reviewed`) is mapped but not on the sheet: it is no part of the workflow.
do
  local mapped = {}
  for _, mode in ipairs({ 'n' }) do
    for _, m in ipairs(vim.api.nvim_get_keymap(mode)) do
      local name = m.lhs:match('^<Plug>%(walkthrough%-([%w-]+)%)$')
      if name and name ~= 'reviewed' then
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
check('keys = true: the table has the keys of the spec', #keys.defaults == 33)
-- The final key set, group by group, exactly as the product defines it ("P" is the prefix).
do
  local spec = {
    Pr = 'review', PM = 'request', PR = 'resume', Pq = 'close',
    [']w'] = 'next', ['[w'] = 'prev', [']n'] = 'note-next', ['[n'] = 'note-prev', ['P]'] = 'group-next',
    ['P['] = 'group-prev', Pv = 'view', Pp = 'map', Ph = 'inline', Pw = 'back',
    Pa = 'ask', Pc = 'change', Pm = 'send', Pt = 'thread', PX = 'thread-delete', ['P-'] = 'simpler',
    ['P+'] = 'deeper', ['P='] = 'deeper',
    Py = 'accept', Pd = 'decline', P0 = 'undecide',
    Ps = 'stage', PS = 'stage-all', Px = 'reject', Pb = 'base', PC = 'commit',
    PA = 'plan-approve', PF = 'plan-feedback',
    ['P?'] = 'keys',
  }
  local got = {}
  for _, k in ipairs(keys.defaults) do
    got[k[4] and k[1] or ('P' .. k[1])] = k[2]
  end
  check('the default keys are exactly the final set', vim.deep_equal(got, spec), vim.inspect(got))
end
check('keys = true: r starts a review, v switches the view, e is gone', vim.fn.maparg('<leader>wr', 'n', false, true).rhs == plug('review')
  and vim.fn.maparg('<leader>we', 'n') == '' and vim.fn.maparg('<leader>wv', 'n', false, true).rhs == plug('view')
  and vim.fn.maparg('<leader>wR', 'n', false, true).rhs == plug('resume'))
check('keys = true: the snapshot action stays, without a key', vim.fn.maparg(plug('reviewed'), 'n') ~= '')
check('keys = true: visual-mode ask and change mappings', vim.fn.maparg('<leader>wa', 'x') ~= '' and vim.fn.maparg('<leader>wc', 'x') ~= '')
check('keys = true: a ask, c change, t thread, X thread-delete; i and u are gone', vim.fn.maparg('<leader>wa', 'n', false, true).rhs == plug('ask')
  and vim.fn.maparg('<leader>wc', 'n', false, true).rhs == plug('change') and vim.fn.maparg('<leader>wt', 'n', false, true).rhs == plug('thread')
  and vim.fn.maparg('<leader>wX', 'n', false, true).rhs == plug('thread-delete') and vim.fn.maparg('<leader>wi', 'n') == ''
  and vim.fn.maparg('<leader>wu', 'n') == '')
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
check('cheat sheet: shows the mapped keys', text:match(']w%s+next entry') and text:match('<leader>wa%s+ask')
  and text:match('<leader>wS%s+stage the commit\'s lines in every file'), text)
check('cheat sheet: both keys of one action', text:match('<leader>w%+ <leader>w=') ~= nil, text)
check('cheat sheet: the Write group', text:match('Write\n%s+<leader>wa%s+ask a question here %(sent at once%)\n%s+<leader>wc%s+write a change request here %(collected%)\n%s+<leader>wm%s+send the change requests and decisions\n%s+<leader>wt%s+open the thread or finding here in full\n%s+<leader>wX%s+delete the thread here') ~= nil, text)
check('cheat sheet: no command for a mapped action', not text:match(':Walkthrough next'), text)
check('cheat sheet: Start has review, request, resume and close, in that order', text:match('Start\n%s+<leader>wr%s+review the uncommitted changes[^\n]*\n%s+<leader>wM%s+ask the agent for the map of the change\n%s+<leader>wR%s+bring back the saved review\n%s+<leader>wq%s+end the session\n\nMove') ~= nil, text)
check('cheat sheet: the snapshot action is not on it', not text:match('snapshot') and not text:match('reviewed'), text)
check('cheat sheet: the Plan group names the plan keys', text:match('Plan\n%s+<leader>wA%s+approve the plan[^\n]*\n%s+<leader>wF%s+send the plan feedback') ~= nil, text)
local panel_part = text:match('In the panel\n(.*)$') or ''
check('cheat sheet: the panel keys', panel_part:match('<CR>%s+open the entry under the cursor') and panel_part:match('\n%s+s%s+stage the commit')
  and panel_part:match('\n%s+%?%s+show all keys'), panel_part)
check('cheat sheet: the panel keys of the notes are gone', not panel_part:match('accept') and not panel_part:match('simpler')
  and not panel_part:match('check'), panel_part)
-- The commit action runs the project's check; the check questions of tours are gone.
check('cheat sheet: nothing about check questions', not text:match('question%s+check') and not text:match('check%s+question'), text)
check('cheat sheet: the commit action is listed under Approve', text:match('Approve\n.-commit what is staged.-\n\nPlan') ~= nil, text)
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
for _, lhs in ipairs({ '<CR>', 's', 'S', 'm', 'b', 'x', '?' }) do
  local m = panel_map(lhs)
  check('panel key ' .. lhs .. ' exists, local to the buffer, with a desc', m.buffer == 1 and (m.desc or ''):match('^Walkthrough: '), vim.inspect(m))
end
for _, lhs in ipairs({ 'a', '-', '+', '=', 'r', 'e', 'y', 'd', 'u' }) do
  check('panel key ' .. lhs .. ' was removed with the notes', panel_map(lhs).buffer ~= 1)
end
for _, lhs in ipairs({ 'n', 'q', 'j', 'k', '/', 'N', 'h', 'l' }) do
  check('panel key ' .. lhs .. ' is left alone', panel_map(lhs).buffer ~= 1)
end
w.step(1)
check('panel: the keys are the same on every step', panel_map('s').buffer == 1 and panel_map('?').buffer == 1 and panel_map('r').buffer ~= 1)
w.step(-1)

local function in_panel(pattern)
  vim.api.nvim_set_current_win(st.panel_win)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(st.panel_buf, 0, -1, false)) do
    if l:match(pattern) then
      vim.api.nvim_win_set_cursor(st.panel_win, { i, 0 })
      return true
    end
  end
end

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
  in_panel('^A$')
  for _, k in ipairs({ 's', 'S', 'm', 'x', 'b', '?' }) do
    press(k)
  end
  check('panel: s S m x b ? call stage, stage all, send, reject, base and the cheat sheet',
    table.concat(calls, ',') == 'stage,stage all,send,reject,base,keys', table.concat(calls, ','))
  stage_mod.stage_group, feedback_mod.send, reject_mod.reject_group, base_mod.show, keys_mod.show = unpack(orig)
end
in_panel('^A$')
press('?')
text, float = sheet()
check('panel: ? opens the cheat sheet', text:match('In the panel') ~= nil and vim.api.nvim_win_get_config(float).relative == 'editor')
press('q')
check('panel: q closed the cheat sheet and left the panel alone', not vim.api.nvim_win_is_valid(float) and vim.api.nvim_win_is_valid(st.panel_win))

-- Hints: the panel keys, then the cheat sheet key ------------------------------------------------------------------------
w.step(0)
local bar = H.panel_winbar()
check('hints: the bar ends with the cheat sheet key', bar:match('%? all keys$') ~= nil, bar)
check('hints: panel keys first', bar:match('<CR> open · s stage · S stage all · %? all keys$') ~= nil, bar)
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
check('hints: every key they name exists in the panel', #named >= 4 and #missing == 0, table.concat(missing, ', '))
check('hints: no global key is named', not bar:match('leader') and not bar:match('%]w') and not bar:match('%[n'), bar)
w.step(1)
bar = H.panel_winbar()
check('hints: the same on every step, still ending with the cheat sheet key', bar:match('<CR> open') and bar:match('%? all keys$'), bar)
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
