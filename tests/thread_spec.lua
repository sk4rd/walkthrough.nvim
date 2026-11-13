-- Threads on screen: the lines under the code, their labels and cap, the
-- count line of the map, the thread float with its keys, and ]n over notes
-- and threads. The agent's channel is stubbed as in feedback_spec.lua.
local H = require('helpers')
local check, send, w = H.check, H.send, H.w
local st = _G.walkthrough_state
local ui = require('walkthrough.ui')
local thread = require('walkthrough.thread')
local log, find = H.capture_notify()

local function lines(n, prefix)
  local out = {}
  for i = 1, n do
    out[i] = (prefix or 'l') .. i
  end
  return out
end
local function reset_log()
  for i = #log, 1, -1 do
    log[i] = nil
  end
end

local sent, answer = {}, nil
local function collecting(msg)
  table.insert(sent, msg)
end
st.config.sender = collecting
vim.ui.input = function(_, cb)
  cb(answer)
end
local confirms = {}
local confirm_result = 2
vim.fn.confirm = function(msg, choices, default)
  table.insert(confirms, { msg, choices, default })
  return confirm_result
end

vim.o.columns = 160
local repo = H.repo({ ['a.txt'] = lines(30), ['b.txt'] = lines(6, 'b') }, {})
vim.cmd('cd ' .. vim.fn.fnameescape(repo))
local a, b = repo .. '/a.txt', repo .. '/b.txt'
local function open()
  w.discard()
  w.close()
  vim.cmd('silent! %bwipeout!')
  reset_log()
  sent, answer = {}, nil
  confirms = {}
  st.config.sender = collecting
  vim.fn.writefile(lines(30), a)
  assert(send('load', {
    group = 'A',
    steps = {
      {
        file = a, title = 'one',
        notes = {
          { line = 6, text = 'six', verdict = 'simplify', detail = { 'why six', 'because' }, evidence = 'read' },
          { line = 12, text = 'twelve', verdict = 'remove' },
        },
      },
      { file = b, title = 'two' },
    },
  }) == 'ok')
  vim.cmd('edit! ' .. vim.fn.fnameescape(a))
end
local function at(line)
  vim.api.nvim_set_current_win(st.code_win)
  vim.api.nvim_win_set_cursor(0, { line, 0 })
end
local function threads()
  return st.history[1].threads or {}
end
local function th(id)
  for _, x in ipairs(threads()) do
    if x.id == id then
      return x
    end
  end
end
local abuf = function()
  return vim.fn.bufnr(a)
end
-- The virtual lines under `row` (1-based), as plain strings.
local function virt_at(row)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(abuf(), H.ns, { row - 1, 0 }, { row - 1, -1 }, { details = true })) do
    for _, vl in ipairs(m[4].virt_lines or {}) do
      table.insert(out, H.vtext(vl))
    end
  end
  return out
end
local function float_text()
  local win = thread.win()
  return win and table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), '\n') or ''
end
local function press(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), 'x', false)
end

-- Labels ---------------------------------------------------------------------------------------------
open()
at(3)
w.change('rename it')
local labels = {
  { 'draft', 'not sent' }, { 'waiting', 'waiting' }, { 'proposed', 'proposal' }, { 'accepted', 'accepted' },
  { 'declined', 'declined' }, { 'done', 'done' },
}
for _, l in ipairs(labels) do
  th('t1').state = l[1]
  ui.update()
  check('label: ' .. l[1] .. ' is shown as "' .. l[2] .. '" after the id', virt_at(3)[1] == ('» t1 (%s) you: rename it'):format(l[2]), vim.inspect(virt_at(3)))
end
th('t1').state = 'answered'
ui.update()
check('label: answered needs none', virt_at(3)[1] == '» t1 you: rename it', vim.inspect(virt_at(3)))
check('label: the agent\'s message is a second line, only the last of each', (function()
  table.insert(th('t1').messages, { by = 'agent', text = 'first answer' })
  table.insert(th('t1').messages, { by = 'user', text = 'newer question' })
  table.insert(th('t1').messages, { by = 'agent', text = 'last answer' })
  ui.update()
  return vim.deep_equal(virt_at(3), { '» t1 you: newer question', '  ↳ last answer' })
end)(), vim.inspect(virt_at(3)))
for _, state in ipairs({ 'done', 'declined' }) do
  th('t1').state = state
  ui.update()
  check('dimming: ' .. state .. ' is dimmed', H.marks(function(d)
    return d.virt_lines and d.virt_lines[1][1][2] == 'WalkthroughThreadDim'
  end, abuf()) == 1)
end
th('t1').state = 'waiting'
ui.update()
check('dimming: an open thread is not', H.marks(function(d)
  return d.virt_lines and d.virt_lines[1][1][2] == 'WalkthroughThread'
end, abuf()) == 1)
th('t1').stale = true
ui.update()
check('label: a thread whose code changed says so', virt_at(3)[1] == '» t1 (waiting) you: newer question (code changed)', vim.inspect(virt_at(3)))
th('t1').stale = nil

-- Cap -------------------------------------------------------------------------------------------------
open()
at(20)
w.change(string.rep('a fairly long request that goes on ', 30))
local width = vim.api.nvim_win_get_width(st.code_win) - vim.fn.getwininfo(st.code_win)[1].textoff
local out = virt_at(20)
local fits = true
for _, l in ipairs(out) do
  fits = fits and vim.fn.strdisplaywidth(l) <= width
end
check('cap: a long thread is cut at 6 virtual lines, each fits the window', #out == 6 and fits, vim.inspect(out))
check('cap: ... ending with the command when no key is mapped', out[6] == '    … full thread: :Walkthrough thread', vim.inspect(out))
vim.keymap.set('n', '<leader>wt', '<Plug>(walkthrough-thread)')
ui.update()
out = virt_at(20)
check('cap: ... or with the key mapped to the thread action', #out == 6 and out[6] == '    … full thread: <leader>wt', vim.inspect(out))
vim.keymap.del('n', '<leader>wt')
th('t1').messages[1].text = 'short'
table.insert(th('t1').messages, { by = 'agent', text = 'one two three four five six seven' })
ui.update()
check('cap: a short thread has no hint', #virt_at(20) == 2 and not virt_at(20)[2]:match('full thread'), vim.inspect(virt_at(20)))
th('t1').messages[2].text = string.rep('word ', 400)
ui.update()
out = virt_at(20)
check('cap: a long answer is cut too, the user\'s line stays', #out == 6 and out[1] == '» t1 (not sent) you: short' and out[2]:match('^  ↳ word') and out[6]:match('full thread'),
  vim.inspect(out))

-- The map counts threads --------------------------------------------------------------------------------
open()
local base_panel = H.panel_text()
check('map: no threads, no count line', not base_panel:match('waiting') and not base_panel:match('not sent'), base_panel)
at(3)
w.ask('q1')
at(4)
w.ask('q2')
at(9)
w.change('c1')
at(10)
w.change('c2')
send('patch', { thread = 't3', answer = 'p', proposal = true })
local panel = vim.api.nvim_buf_get_lines(st.panel_buf, 0, -1, false)
check('map: the last line counts waiting, proposals and not sent', panel[#panel] == '2 waiting · 1 proposal · 1 not sent', vim.inspect(panel))
check('map: ... below the entries, which are unchanged', H.panel_text():sub(1, #base_panel) == base_panel, H.panel_text())
send('patch', { thread = 't1', answer = 'a' })
panel = vim.api.nvim_buf_get_lines(st.panel_buf, 0, -1, false)
check('map: it follows a patch (an answered thread is not counted)', panel[#panel] == '1 waiting · 1 proposal · 1 not sent', vim.inspect(panel))
send('patch', { thread = 't3', done = true })
send('patch', { thread = 't2', done = true })
panel = vim.api.nvim_buf_get_lines(st.panel_buf, 0, -1, false)
check('map: zero parts are left out', panel[#panel] == '1 not sent', vim.inspect(panel))
at(10)
w.send()
panel = vim.api.nvim_buf_get_lines(st.panel_buf, 0, -1, false)
check('map: and it follows send', panel[#panel] == '1 waiting', vim.inspect(panel))
send('patch', { thread = 't4', done = true })
check('map: no line when there is nothing to count', H.panel_text() == base_panel, H.panel_text())
at(16)
w.change('c3')
at(11)
w.change('c4')
send('patch', { thread = 't5', answer = 'p', proposal = true })
send('patch', { thread = 't6', answer = 'p', proposal = true })
panel = vim.api.nvim_buf_get_lines(st.panel_buf, 0, -1, false)
check('map: proposals are plural', panel[#panel] == '2 proposals', vim.inspect(panel))

-- ]n and [n over notes and threads --------------------------------------------------------------------------------
open()
at(3)
w.ask('t')
at(9)
w.change('c')
at(13)
w.ask('range', { 13, 14 })
vim.api.nvim_win_set_cursor(0, { 1, 0 })
local stops = {}
for _ = 1, 7 do
  w.note(1)
  table.insert(stops, vim.api.nvim_win_get_cursor(0)[1])
end
check(']n visits notes and threads in line order', vim.deep_equal(stops, { 3, 6, 9, 12, 13, 13, 13 }), vim.inspect(stops))
reset_log()
w.note(1)
check(']n past the last says so', find('no later thread or finding') ~= nil)
stops = {}
for _ = 1, 5 do
  w.note(-1)
  table.insert(stops, vim.api.nvim_win_get_cursor(0)[1])
end
check('[n goes back the same way', vim.deep_equal(stops, { 12, 9, 6, 3, 3 }), vim.inspect(stops))

-- The float: a thread ---------------------------------------------------------------------------------------------------
open()
at(10)
w.change('simplify these', { 10, 12 })
w.send()
send('patch', { thread = 't1', answer = { 'I would inline x.', 'And drop y.' }, proposal = true })
at(11)
local before = vim.api.nvim_get_current_win()
w.thread()
local float = thread.win()
check('float: a centered float, entered', float ~= nil and float ~= before and vim.api.nvim_get_current_win() == float
  and vim.api.nvim_win_get_config(float).relative == 'editor')
local text = float_text()
check('float: heading with id, kind, place and state', vim.startswith(text, 't1 · change · a.txt:10-12 · proposed'), text)
check('float: the code lines of the range', text:match('  10  l10\n  11  l11\n  12  l12') ~= nil, text)
check('float: every message, the proposal marked', text:find('You: simplify these\n\nAgent (proposal): I would inline x.\n' .. string.rep(' ', 18) .. 'And drop y.', 1, true) ~= nil, text)
check('float: plain text in a scratch buffer that cannot be changed', vim.bo.modifiable == false and vim.bo.buftype == 'nofile')
press('q')
check('float: q closes it and the cursor is back', thread.win() == nil and vim.api.nvim_get_current_win() == before)
w.thread()
press('<Esc>')
check('float: <Esc> closes it', thread.win() == nil)
at(1)
reset_log()
w.thread()
check('float: nothing on the line says so', thread.win() == nil and find('no thread or note') ~= nil)
vim.cmd('Walkthrough thread')
check(':Walkthrough thread with nothing there', thread.win() == nil)
at(10)
vim.cmd('Walkthrough thread')
check(':Walkthrough thread opens it', thread.win() ~= nil)
press('q')
vim.api.nvim_feedkeys(vim.keycode('<Plug>(walkthrough-thread)'), 'x', false)
check('<Plug>(walkthrough-thread) opens it', thread.win() ~= nil)

-- Keys: accept, decline and take back. Nothing is sent until send.
sent = {}
press('y')
check('float key y: marks the acceptance, nothing is sent, the float says so', th('t1').decision == 'accept' and th('t1').state == 'proposed'
  and #sent == 0 and float_text():match('^t1 · change · a%.txt:10%-12 · %(accepted, not sent%)') ~= nil, float_text())
press('d')
check('float key d: switches it to declined', th('t1').decision == 'reject' and #sent == 0
  and float_text():match('^t1 · change · a%.txt:10%-12 · %(declined, not sent%)') ~= nil, float_text())
press('u')
check('float key u: takes the decision back', th('t1').decision == nil and th('t1').state == 'proposed'
  and float_text():match('^t1 · change · a%.txt:10%-12 · proposed') ~= nil, float_text())
press('y')
press('q')
w.send()
check('float: send delivers the acceptance', th('t1').state == 'accepted' and #sent == 1 and sent[1].text:match('the user accepted it'))
at(10)
w.thread()
reset_log()
press('d')
check('float key d: after send the decision cannot be changed', th('t1').state == 'accepted' and #sent == 1
  and find('write on the line to continue the thread') ~= nil and find('write on the line').level == vim.log.levels.WARN)
reset_log()
press('u')
check('float key u: ... nor taken back', th('t1').state == 'accepted' and find('write on the line to continue the thread') ~= nil)
check('float: ... and it reads accepted', float_text():match('^t1 · change · a%.txt:10%-12 · accepted') ~= nil, float_text())
press('q')

open()
at(10)
w.change('another', { 10, 12 })
w.send()
send('patch', { thread = 't1', answer = 'p', proposal = true })
at(10)
w.thread()
sent = {}
press('d')
check('float key d: marks the decline, nothing is sent', th('t1').decision == 'reject' and th('t1').state == 'proposed' and #sent == 0
  and float_text():match('%(declined, not sent%)') ~= nil, float_text())
press('q')
w.send()
check('float: send delivers the decline', th('t1').state == 'declined' and #sent == 1 and sent[1].text:match('declined it'))
at(10)
w.thread()
check('float: ... and it reads declined', float_text():match(' · declined') ~= nil, float_text())
press('q')

-- Keys: reply
open()
at(5)
w.ask('what is five?')
send('patch', { thread = 't1', answer = 'a number' })
at(5)
w.thread()
sent = {}
answer = 'and six?'
press('r')
check('float key r: replies in a question, sent at once, float re-rendered', #th('t1').messages == 3 and th('t1').messages[3].text == 'and six?'
  and #sent == 1 and th('t1').state == 'waiting' and float_text():match('You: and six%?') ~= nil
  and float_text():match(' · waiting') ~= nil, float_text())
answer = '  '
press('r')
check('float key r: an empty reply cancels', #th('t1').messages == 3 and #sent == 1)
press('q')
at(9)
w.change('change five')
at(9)
w.thread()
answer = 'also this'
sent = {}
press('r')
check('float key r: a reply in a change request is collected', #th('t2').messages == 2 and #sent == 0 and th('t2').state == 'draft'
  and float_text():match('You: also this') ~= nil)
press('q')
at(6)
w.thread()
reset_log()
press('r')
check('float key r: a note has no thread to reply in', find('no thread to reply in') ~= nil)
press('q')
-- A closed thread is continued by a reply.
send('patch', { thread = 't2', done = true })
at(9)
w.thread()
answer = 'one more thing'
sent = {}
press('r')
check('float key r: a closed thread is continued: open again, the message not sent', #th('t2').messages == 3
  and th('t2').messages[3].text == 'one more thing' and th('t2').state == 'draft' and #sent == 0
  and float_text():match('You: one more thing') ~= nil and float_text():match(' · draft') ~= nil, float_text())
press('q')

-- Keys: simpler and deeper
open()
at(5)
w.ask('what is five?')
send('patch', { thread = 't1', answer = 'a number' })
at(5)
w.thread()
sent = {}
press('-')
check('float key -: asks for a simpler rewrite of the last message', #sent == 1 and sent[1].text:match('explain this simpler')
  and sent[1].text:match('"replace": true') and st.tours[1].depth == 'simpler')
press('+')
check('float key +: deeper', #sent == 2 and sent[2].text:match('explain this deeper') and st.tours[1].depth == 'deeper')
press('=')
check('float key =: deeper too', #sent == 3 and sent[3].text:match('explain this deeper'))
send('patch', { thread = 't1', answer = 'a number, such as five', replace = true })
check('float: re-rendered when a patch arrives', float_text():match('Agent: a number, such as five') ~= nil
  and not float_text():match('Agent: a number\n'), float_text())
send('patch', { thread = 't1', answer = 'and more', done = true })
check('float: ... and when the state changes', float_text():match('^t1 · question · a%.txt:5 · done') ~= nil
  and float_text():match('Agent: and more') ~= nil, float_text())
press('q')

-- Keys: delete
at(5)
w.thread()
confirm_result = 2
press('X')
check('float key X: asks with the default on cancel, and keeps the thread on cancel', #confirms == 1 and confirms[1][3] == 2
  and confirms[1][1]:match('t1') and #threads() == 1 and thread.win() ~= nil, vim.inspect(confirms))
confirm_result = 1
press('X')
check('float key X: deletes the thread on yes and closes the float', #threads() == 0 and thread.win() == nil)
check('float key X: and the lines under the code are gone', #virt_at(5) == 0)

-- The float: a note ------------------------------------------------------------------------------------------------------
open()
at(6)
w.thread()
text = float_text()
check('float: a finding, in full', text:match('^Finding %[1%] · a%.txt:6') and text:match('Verdict: simplify') and text:match('Evidence: read')
  and text:match('Decision: none') and text:match('\nsix\n') and text:match('Detail:\nwhy six\nbecause'), text)
sent = {}
press('y')
check('float key y: marks the finding, nothing is sent, the float says so', st.history[1].notes[1].decision == 'accept' and #sent == 0
  and float_text():match('Decision: accepted %(not sent%)') ~= nil, float_text())
press('d')
check('float key d: switches it to rejected', st.history[1].notes[1].decision == 'reject' and #sent == 0
  and float_text():match('Decision: rejected %(not sent%)') ~= nil, float_text())
press('u')
check('float key u: takes it back', st.history[1].notes[1].decision == nil and float_text():match('Decision: none') ~= nil, float_text())
reset_log()
press('X')
check('float key X: a note cannot be deleted', #st.history[1].notes == 2 and #confirms == 0 and thread.win() ~= nil)
press('-')
check('float key -: rewrites the detail of a note', sent[#sent].text:match('"detail": "<the new explanation>"') ~= nil)
send('patch', { note = 1, detail = 'plainer detail' })
check('float: re-rendered when the note changes', float_text():match('Detail:\nplainer detail') ~= nil, float_text())
send('patch', { note = 1, remove = true })
check('float: closed when its note is gone', thread.win() == nil)

-- A tour that is gone closes the float
open()
at(5)
w.ask('x')
w.thread()
w.close()
ui.refresh_float()
check('float: closed when the tour is gone', thread.win() == nil)

w.close()
-- The state of a thread has its own colour; the label of another commit is grey.
do
  local function hl(name)
    return vim.api.nvim_get_hl(0, { name = name })
  end
  check('colours: the state links to DiagnosticInfo', hl('WalkthroughState').link == 'DiagnosticInfo', vim.inspect(hl('WalkthroughState')))
  -- A block: the grey of Comment as the background, like the other badges.
  local comment = vim.api.nvim_get_hl(0, { name = 'Comment', link = false })
  check('colours: the label of another commit is a grey block', hl('WalkthroughOtherLabel').bg == comment.fg
    and hl('WalkthroughOtherLabel').bg ~= nil, vim.inspect(hl('WalkthroughOtherLabel')))
  w.close()
  local f = H.work .. '/f.txt'
  check('colours: load', send('load', { steps = { { file = f, title = 't' } } }) == 'ok')
  vim.api.nvim_set_current_win(st.code_win)
  vim.cmd('edit ' .. vim.fn.fnameescape(f))
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  w.change('make it shorter')
  local found
  for _, name in ipairs({ 'walkthrough', 'walkthrough_threads' }) do
    local id = vim.api.nvim_get_namespaces()[name]
    for _, m in ipairs(id and vim.api.nvim_buf_get_extmarks(0, id, 0, -1, { details = true }) or {}) do
      for _, vl in ipairs(m[4].virt_lines or {}) do
        for _, chunk in ipairs(vl) do
          if chunk[1] == '(not sent)' then
            found = chunk[2]
          end
        end
      end
    end
  end
  check('colours: the state is a chunk of its own, in WalkthroughState', found == 'WalkthroughState', tostring(found))
  w.close()
end

H.finish()
