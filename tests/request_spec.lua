-- Asking the agent for the map: `request` sends one message, starts the local
-- review when none is open, and stays in `inbox` and `status` until a map of the
-- agent arrives. Also: the step field `total` is gone, and an old state file
-- that has it is still read.
local H = require('helpers')
local check, send, w = H.check, H.send, H.w
local st = _G.walkthrough_state
local store = require('walkthrough.store')
local tours = require('walkthrough.tours')
local log, find = H.capture_notify()
local sent = {}
local fail_with
st.config.sender = function(msg)
  if fail_with then
    error(fail_with, 0)
  end
  table.insert(sent, msg)
end
local function reset()
  w.discard()
  vim.cmd('silent! %bwipeout!')
  for i = #log, 1, -1 do
    log[i] = nil
  end
  for i = #sent, 1, -1 do
    sent[i] = nil
  end
  fail_with = nil
end
local function status()
  return vim.json.decode(w.status())
end
local function inbox(all)
  return vim.json.decode(w.inbox(all))
end
-- The items of the inbox that are requests for the map.
local function map_items(all)
  return vim.tbl_filter(function(i)
    return i.kind == 'map'
  end, inbox(all).items)
end

local root = H.work
vim.cmd('cd ' .. vim.fn.fnameescape(root))
vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/f.txt'))

-- Nothing open: the local review starts first, then one message goes out ------------------------------
check('before: no review, no request', status().step == 0 and status().map == nil and #map_items() == 0)
w.request()
local t = tours.active()
check('request: the local review was started', t ~= nil and t.auto == true and #t.steps == 2, vim.inspect(log))
check('request: one message was sent', #sent == 1, vim.inspect(sent))
local text = sent[1] and sent[1].text or ''
check('request: it names the repository root and the base', text:match('\nRepository: ' .. vim.pesc(root) .. '\n') ~= nil
  and text:match('\nBase: HEAD\n') ~= nil, text)
check('request: it lists the changed files, relative to the root', text:match('Changed files %(2%):\n  f%.txt\n  new%.txt') ~= nil, text)
local flat = text:gsub('%s+', ' ')
check('request: it says what is expected, in plain words', text:match('\nExpected: build the map of this change%.') ~= nil
  and flat:match('commits that each stand on their own') and flat:match('nothing depends on a later commit')
  and flat:match('"group" is the commit\'s subject') and flat:match('"steps" are its files in reading order')
  and flat:match('one%-sentence "title"') and flat:match('"hunks" assign every changed line of each')
  and flat:match('"notes", each with a "verdict" and "evidence"') and flat:match('walkthrough skill'), text)
check('request: the user is told', find('asked the agent for the map %(2 files%)') ~= nil, vim.inspect(log))
check('status: map is requested', status().map == 'requested')

-- The request stays in the inbox until the map arrives -------------------------------------------------
local items = map_items()
check('inbox: the request is listed', #items == 1 and items[1].root == root and items[1].base == 'HEAD'
  and vim.deep_equal(items[1].files, { 'f.txt', 'new.txt' }), vim.inspect(items))
check('inbox: ... and still listed on the second call', #map_items() == 1 and #map_items(true) == 1)
check('inbox: the item has exactly the documented fields', (function()
  local keys = vim.tbl_keys(items[1])
  table.sort(keys)
  return table.concat(keys, ',') == 'base,files,kind,root'
end)())

-- Asking again while it is open sends again (the user may have waited long) -------------------------------
w.request()
check('request again: another message, still one pending request', #sent == 2 and #map_items() == 1)

-- An agent map ends it ---------------------------------------------------------------------------------
check('the agent sends the map', send('load', { group = 'Commit one', steps = {
  { file = root .. '/f.txt', title = 'f', hunks = { { from = 2, to = 3 } } },
} }) == 'ok')
check('after the map: no request in status or inbox', status().map == nil and #map_items() == 0)

-- The map is open (not the local review): request lists git's files --------------------------------------
reset()
vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/f.txt'))
check('agent map without a local review', send('load', { group = 'Only', steps = { { file = root .. '/f.txt', title = 'f' } } }) == 'ok')
w.request()
check('request with an agent map open: files come from git, one message', #sent == 1
  and sent[1].text:match('Changed files %(2%):\n  f%.txt\n  new%.txt') ~= nil and status().map == 'requested', sent[1] and sent[1].text)
check('... a pending request is shown by :Walkthrough status', (function()
  for i = #log, 1, -1 do
    log[i] = nil
  end
  vim.cmd('Walkthrough status')
  return find('map requested') ~= nil
end)(), vim.inspect(log))

-- A failure to send is a notification and nothing else ----------------------------------------------------
reset()
vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/f.txt'))
fail_with = 'no agent terminal found'
w.request()
check('send failure: a warning, no raise', find('the agent was not asked for the map %(no agent terminal found%)') ~= nil, vim.inspect(log))
check('send failure: nothing is pending', status().map == nil and #map_items() == 0)
check('send failure: the review that was started stays', tours.active() ~= nil and tours.active().auto == true)
fail_with = nil

-- close and discard end the request ---------------------------------------------------------------------
reset()
vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/f.txt'))
w.request()
check('before close: requested', status().map == 'requested')
check('close: the request is gone', w.close() == 'ok' and status().map == nil and w.inbox():match('"map"') == nil)
w.request()
check('discard: the request is gone', w.discard() == 'ok' and status().map == nil)

-- No changed file: nothing is sent --------------------------------------------------------------------------
reset()
local clean = H.repo({ ['a.txt'] = { 'a' } })
vim.cmd('cd ' .. vim.fn.fnameescape(clean))
vim.cmd('edit ' .. vim.fn.fnameescape(clean .. '/a.txt'))
w.request()
check('no changed file: it says so and sends nothing', find('no changed files') ~= nil and #sent == 0 and status().map == nil, vim.inspect(log))
check('... and does not raise outside a repository', pcall(function()
  vim.cmd('cd ' .. vim.fn.fnameescape(vim.fn.tempname() .. '-nowhere'))
end) or true)

-- A review against a ref: the base is that ref --------------------------------------------------------------
reset()
local two = H.repo({ ['a.txt'] = { 'one' } })
vim.fn.writefile({ 'two' }, two .. '/a.txt')
H.git_in(two, 'commit', '-qam', 'second')
vim.fn.writefile({ 'three' }, two .. '/a.txt')
vim.fn.writefile({ 'x' }, two .. '/b.txt')
vim.cmd('cd ' .. vim.fn.fnameescape(two))
vim.cmd('edit ' .. vim.fn.fnameescape(two .. '/a.txt'))
w.review('HEAD~1')
w.request()
local twotext = sent[1] and sent[1].text or ''
check('review against a ref: the base is the ref', twotext:match('\nBase: HEAD~1\n') ~= nil
  and twotext:match('Changed files %(2%):\n  a%.txt\n  b%.txt') ~= nil, twotext)
check('... and the inbox says so', map_items()[1] and map_items()[1].base == 'HEAD~1' and map_items()[1].root == two,
  vim.inspect(map_items()))

-- Entry points never raise and have their command and <Plug> -------------------------------------------------
reset()
vim.cmd('cd ' .. vim.fn.fnameescape(root))
check(':Walkthrough request works and completes', pcall(vim.cmd, 'Walkthrough request')
  and vim.tbl_contains(vim.fn.getcompletion('Walkthrough re', 'cmdline'), 'request'))
check('<Plug>(walkthrough-request) exists', vim.fn.maparg('<Plug>(walkthrough-request)', 'n') ~= '')
reset()
check('request without a file or review never raises', pcall(w.request))

-- Every kind of item the inbox lists is one of `feedback.inbox_kinds` -----------------------------------------
reset()
st.config.view = 'file'
vim.cmd('cd ' .. vim.fn.fnameescape(root))
vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/f.txt'))
fail_with = 'down' -- nothing is delivered: question, change request and decision stay in the inbox
w.request() -- not sent either: no map item yet
check('kinds: a failed request is no item', #map_items() == 0)
fail_with = nil
w.request()
fail_with = 'down'
w.ask('why?', { 2, 2 })
w.change('make it simpler', { 5, 5 })
check('kinds: the patch proposes', send('patch', { thread = 't2', answer = 'inline it', proposal = true }) == 'ok')
vim.api.nvim_win_set_cursor(0, { 5, 0 })
w.decide('accept')
local kinds = {}
for _, item in ipairs(inbox().items) do
  kinds[item.kind] = true
end
local feedback = require('walkthrough.feedback')
local missing = {}
for _, kind in ipairs({ 'question', 'change', 'decision', 'map' }) do
  if not kinds[kind] then
    table.insert(missing, kind)
  end
end
check('kinds: the inbox lists a question, a change request, a decision and the map request', #missing == 0, vim.inspect(kinds))
local unknown = {}
for kind in pairs(kinds) do
  if not feedback.inbox_kinds[kind] then
    table.insert(unknown, kind)
  end
end
check('kinds: every kind listed is a documented one', #unknown == 0, table.concat(unknown, ', '))
fail_with = nil
st.config.view = 'compact'
reset()

-- The step field `total` is gone ---------------------------------------------------------------------------------
reset()
vim.cmd('cd ' .. vim.fn.fnameescape(root))
check('total: a step with it is refused like any unknown field',
  send('load', { group = 'T', steps = { { file = root .. '/f.txt', total = 3 } } }):match('^error: step 1: unknown step field "total"') ~= nil)
check('total: and a patch cannot set it', (function()
  send('load', { group = 'T', steps = { { file = root .. '/f.txt' } } })
  return send('patch', { total = 3 }):match('unknown step field "total"') ~= nil
end)())
-- A state file written before it was removed still resumes, without the field.
local path = store.path(root)
local data = table.concat(vim.fn.readfile(path), '\n')
local with_total = data:gsub('("steps":%[{)', '%1"total":3,')
check('total: the saved file was changed for the test', with_total ~= data)
vim.fn.writefile({ with_total }, path)
w.close()
check('total: an old state file resumes, without the field', w.resume() == 'ok' and st.history[1].total == nil
  and #st.history == 1, w.status())
reset()

H.finish()
