-- Decisions on proposals and findings are collected and can be changed until
-- `send` (or `inbox`) delivers them; a thread can be continued after it was
-- declined or done; writing on a proposal asks for another one. The agent's
-- channel is stubbed: config.sender collects the messages, vim.ui.input
-- answers from a variable (tests/init.lua sets `input = 'ui'`).
local H = require('helpers')
local check, send, w = H.check, H.send, H.w
local st = _G.walkthrough_state
local store = require('walkthrough.store')
local thread = require('walkthrough.thread')
local log, find = H.capture_notify()

local function status()
  return vim.json.decode(w.status())
end
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

local repo = H.repo({ ['a.txt'] = lines(30), ['b.txt'] = lines(6, 'b') }, {})
vim.cmd('cd ' .. vim.fn.fnameescape(repo))
local a, b = repo .. '/a.txt', repo .. '/b.txt'
local root = store.root_of(a)
local function tour()
  return {
    group = 'A',
    steps = {
      {
        file = a, title = 'one',
        notes = {
          { line = 6, text = 'six', verdict = 'simplify', detail = 'why six', evidence = 'read' },
          { line = 12, text = 'twelve', verdict = 'remove' },
          { line = 15, text = 'fifteen', verdict = 'keep' },
        },
      },
      { file = b, title = 'two' },
    },
  }
end
local function open()
  w.discard()
  w.close()
  vim.cmd('silent! %bwipeout!')
  reset_log()
  sent, answer = {}, nil
  st.config.sender = collecting
  vim.fn.writefile(lines(30), a)
  assert(send('load', tour()) == 'ok')
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
local function note(n)
  return st.history[1].notes[n]
end
-- The virtual lines under `row` of the file, as plain strings.
local function virt_at(row)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(vim.fn.bufnr(a), H.ns, { row - 1, 0 }, { row - 1, -1 }, { details = true })) do
    for _, vl in ipairs(m[4].virt_lines or {}) do
      table.insert(out, H.vtext(vl))
    end
  end
  return out
end
local function label_at(row)
  return virt_at(row)[1]
end
local function dim_at(row)
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(vim.fn.bufnr(a), H.ns, { row - 1, 0 }, { row - 1, -1 }, { details = true })) do
    if m[4].virt_lines and m[4].virt_lines[1] then
      return m[4].virt_lines[1][1][2] == 'WalkthroughThreadDim'
    end
  end
end
local function last_line()
  local panel = vim.api.nvim_buf_get_lines(st.panel_buf, 0, -1, false)
  return panel[#panel]
end
local function badge_at(row)
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(vim.fn.bufnr(a), H.ns, { row - 1, 0 }, { row - 1, -1 }, { details = true })) do
    if m[4].virt_text then
      local out = {}
      for _, chunk in ipairs(m[4].virt_text) do
        table.insert(out, chunk[1])
      end
      return table.concat(out)
    end
  end
  return ''
end
local function press(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), 'x', false)
end
local function float_text()
  local win = thread.win()
  return win and table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), '\n') or ''
end
-- A change request on `line`, sent, and the agent's proposal for it.
local function proposed(line, text)
  at(line)
  w.change(text or 'rename it')
  w.send()
  send('patch', { thread = 't' .. #threads(), answer = 'I would rename x to y', proposal = true })
  sent = {}
end

-- Marking a decision on a proposal -------------------------------------------------------------------
open()
proposed(9)
local t1 = th('t1')
check('setup: a proposal', t1.state == 'proposed' and label_at(9) == '» t1 (proposal) you: rename it', label_at(9))
at(9)
w.decide('accept')
check('accept: nothing is sent', #sent == 0)
check('accept: the thread is still proposed, the decision is marked', t1.state == 'proposed' and t1.decision == 'accept' and not t1.decision_sent)
check('accept: the label under the code', label_at(9) == '» t1 (accepted, not sent) you: rename it', label_at(9))
check('accept: it is not dimmed', dim_at(9) == false)
check('accept: the map counts it as not sent, not as a proposal', last_line() == '1 not sent', last_line())
check('accept: status counts it as not sent', vim.deep_equal(status().threads, { draft = 1, waiting = 0, answered = 0, proposed = 0 }),
  vim.inspect(status().threads))
check('accept: the thread float says so', (function()
  w.thread()
  local text = float_text()
  press('q')
  return text:match('^t1 · change · a%.txt:9 · %(accepted, not sent%)') ~= nil
end)())
w.decide('reject')
check('switching: the other key changes it, nothing is sent', t1.decision == 'reject' and t1.state == 'proposed' and #sent == 0
  and label_at(9) == '» t1 (declined, not sent) you: rename it' and dim_at(9) == false, label_at(9))
check('switching: ... and it still counts as not sent', last_line() == '1 not sent')
w.decide('accept')
check('switching: ... and back', t1.decision == 'accept' and label_at(9) == '» t1 (accepted, not sent) you: rename it')
w.decide('clear')
check('clearing: back to a proposal', t1.decision == nil and t1.state == 'proposed' and label_at(9) == '» t1 (proposal) you: rename it'
  and last_line() == '1 proposal', label_at(9) .. ' / ' .. tostring(last_line()))
reset_log()
w.decide(nil)
check('clearing: with nothing marked says so', find('nothing to take back') ~= nil)
check('the status counts a proposal again', status().threads.proposed == 1 and status().threads.draft == 0, vim.inspect(status().threads))
vim.cmd('Walkthrough decide accept')
check(':Walkthrough decide accept marks it', t1.decision == 'accept' and #sent == 0)
vim.cmd('Walkthrough decide clear')
check(':Walkthrough decide clear takes it back', t1.decision == nil and t1.state == 'proposed')

-- send delivers the decision ---------------------------------------------------------------------------------
w.decide('accept')
w.send()
check('send: one message with the decision', #sent == 1 and sent[1].text:match('%(1 item%)')
  and sent[1].text:match('Decision on your proposal in thread t1 %(change%) at a%.txt:9, step 1: the user accepted it%.'), sent[1] and sent[1].text)
check('send: ... and says to apply it and to patch done', sent[1].text:match('Expected: The user accepted your proposal: apply it now, then report with a patch:'
  .. ' { "thread": "t1", "answer": "<what you changed>", "done": true }'), sent[1].text)
check('send: now the thread is accepted, the decision told', t1.state == 'accepted' and t1.decision_sent == true)
check('send: the label has no "not sent" any more', label_at(9) == '» t1 (accepted) you: rename it', label_at(9))
check('send: ... and the map no longer counts it', last_line() == nil or not tostring(last_line()):match('not sent'), tostring(last_line()))
reset_log()
w.decide('clear')
check('after send: clearing is refused and says to write on the line', t1.state == 'accepted' and t1.decision == 'accept'
  and find('write on the line to continue the thread') ~= nil and find('write on the line').level == vim.log.levels.WARN, vim.inspect(log))
reset_log()
w.decide('reject')
check('after send: the other key is refused too', t1.state == 'accepted' and t1.decision == 'accept' and find('write on the line to continue the thread') ~= nil)
check('after send: nothing more goes out', (function()
  sent = {}
  w.send()
  return #sent == 0
end)())
send('patch', { thread = 't1', answer = 'renamed', done = true })
check('done: the agent reports', th('t1').state == 'done' and label_at(9) == '» t1 (done) you: rename it' and dim_at(9) == true,
  tostring(th('t1').state) .. ' ' .. tostring(label_at(9)))

-- Declined ---------------------------------------------------------------------------------------------------------
open()
proposed(9)
at(9)
w.decide('reject')
w.send()
check('decline: send delivers it and says to leave the code', #sent == 1 and th('t1').state == 'declined' and th('t1').decision_sent == true
  and sent[1].text:match('the user declined it') and sent[1].text:match('Expected: The user declined your proposal: leave the code as it is; no patch is needed%.'),
  sent[1] and sent[1].text)
check('decline: the label is (declined) and dimmed', label_at(9) == '» t1 (declined) you: rename it' and dim_at(9) == true)
reset_log()
w.decide('accept')
check('decline: after send, accept is refused', th('t1').state == 'declined' and find('write on the line to continue the thread') ~= nil)

-- Everything in one message --------------------------------------------------------------------------------------------
open()
proposed(9)
at(14)
w.change('another change')
at(17)
w.ask('why seventeen?')
at(9)
w.decide('accept')
at(6)
w.decide('accept')
at(12)
w.decide('reject')
check('collected: questions went out at once, nothing else did', #sent == 1 and sent[1].text:match('Question t3'), vim.inspect(sent))
sent = {}
w.send()
local msg = sent[1]
check('one message: the decisions and the change request together', #sent == 1 and msg.text:match('%(4 items%)')
  and msg.text:match('Decision on your proposal in thread t1') and msg.text:match('Change request t2 at a%.txt:14')
  and msg.text:match('Decision on finding %[1%] at a%.txt:6') and msg.text:match('Decision on finding %[2%] at a%.txt:12'), msg and msg.text)
check('one message: the question that went out at once is not in it', not msg.text:match('Question t3'))
check('one message: states and labels after it', th('t1').state == 'accepted' and th('t1').decision_sent == true
  and th('t2').state == 'waiting' and note(1).decision_sent == true and note(2).decision_sent == true
  and label_at(9) == '» t1 (accepted) you: rename it' and label_at(14) == '» t2 (waiting) you: another change', vim.inspect({ label_at(9), label_at(14) }))
check('findings: Expected for an accepted simplify finding', msg.text:match('Expected: Apply it, then patch the note to done: { "step": 1, "note": 1, "verdict": "done" }'), msg.text)
check('findings: Expected for a declined one', msg.text:match('Expected: Leave the code as it is and acknowledge; do not change the verdict%.'), msg.text)
check('findings: the badge no longer says "not sent"', badge_at(6):match('✓ accepted') and not badge_at(6):match('not sent'), badge_at(6))

-- A finding's decision ----------------------------------------------------------------------------------------------------
open()
at(12)
w.decide('accept')
check('finding: marked, nothing is sent', note(2).decision == 'accept' and not note(2).decision_sent and #sent == 0)
check('finding: the badge has the hint', badge_at(12):match('REMOVE') and badge_at(12):match('✓ accepted, not sent'), badge_at(12))
check('finding: it counts as not sent in the map and the status', last_line() == '1 not sent' and status().threads.draft == 1,
  tostring(last_line()) .. ' ' .. vim.inspect(status().threads))
w.decide('reject')
check('finding: the other key switches it', note(2).decision == 'reject' and badge_at(12):match('✗ rejected, not sent') and #sent == 0, badge_at(12))
w.decide('clear')
check('finding: clearing removes it', note(2).decision == nil and not badge_at(12):match('accepted') and not badge_at(12):match('rejected')
  and not tostring(last_line()):match('not sent'), tostring(last_line()))
w.decide('accept')
w.send()
check('finding: send delivers it; an accepted remove is applied and patched to done', #sent == 1 and note(2).decision_sent == true
  and sent[1].text:match('Decision on finding %[2%] at a%.txt:12, step 1, your verdict: remove')
  and sent[1].text:match('accepted your verdict') and sent[1].text:match('{ "step": 1, "note": 2, "verdict": "done" }'), sent[1] and sent[1].text)
reset_log()
w.decide('clear')
check('finding: after send, clearing is refused', note(2).decision == 'accept' and find('write on the line') ~= nil)
reset_log()
w.decide('reject')
check('finding: ... and so is the other key', note(2).decision == 'accept' and find('write on the line') ~= nil)

-- inbox ----------------------------------------------------------------------------------------------------------------------
open()
proposed(9)
at(14)
w.change('and this')
at(9)
w.decide('accept')
at(15)
w.decide('reject')
local res = w.inbox()
local inbox = vim.json.decode(res)
local kinds = vim.tbl_map(function(i) return i.kind .. (i.id and (':' .. i.id) or '') end, inbox.items)
check('inbox: lists the decisions with the change request', #inbox.items == 3 and vim.deep_equal(kinds, { 'decision:t1', 'change:t2', 'decision' }),
  res)
local d1, d3 = inbox.items[1], inbox.items[3]
check('inbox: a thread decision', d1.decision == 'accept' and d1.state == 'accepted' and d1.id == 't1' and d1.text == 'I would rename x to y', res)
check('inbox: a finding decision', d3.note == 3 and d3.decision == 'reject' and d3.verdict == 'keep', res)
check('inbox: marks them as told', th('t1').state == 'accepted' and th('t1').decision_sent == true and note(3).decision_sent == true
  and #vim.json.decode(w.inbox()).items == 0)
reset_log()
at(9)
w.decide('clear')
check('inbox: ... and then a decision cannot be taken back', th('t1').state == 'accepted' and find('write on the line') ~= nil)

-- Writing on a proposal asks for another ----------------------------------------------------------------------------------------
open()
proposed(9)
at(9)
w.decide('accept')
answer = 'use a loop instead'
at(9)
w.ask()
local r1 = th('t1')
check('revise: the reply is added to the same thread', #threads() == 1 and #r1.messages == 3 and r1.messages[3].by == 'user'
  and r1.messages[3].text == 'use a loop instead', vim.inspect(threads()))
check('revise: it clears the decision that was not sent', r1.decision == nil and r1.decision_sent == nil and r1.state == 'draft')
check('revise: collected like any reply in a change thread', #sent == 0 and label_at(9) == '» t1 (not sent) you: use a loop instead', label_at(9))
check('revise: the map has no decision to count, only the reply', last_line() == '1 not sent', tostring(last_line()))
w.send()
check('revise: Expected says to revise the proposal with a new proposal patch', #sent == 1
  and sent[1].text:match('Expected: The user asks you to revise your proposal: reply with a new proposal, as a patch:'
  .. ' { "thread": "t1", "answer": "<the new proposal>", "proposal": true }. Do not edit any code%.')
  and sent[1].text:match('User: use a loop instead') and not sent[1].text:match('accepted'), sent[1] and sent[1].text)
check('revise: the conversation shows the proposal', sent[1].text:match('You %(agent%) %(proposal%): I would rename x to y'))
send('patch', { thread = 't1', answer = 'a loop it is', proposal = true })
check('a new proposal puts the thread back to proposed', th('t1').state == 'proposed' and label_at(9):match('^» t1 %(proposal%)'), label_at(9))

-- The same with the change key, and with a decision that is marked on a finding
open()
proposed(9)
at(9)
w.decide('reject')
answer = 'and keep the old name'
at(9)
w.change()
check('revise: the change key does the same', #threads() == 1 and #th('t1').messages == 3 and th('t1').decision == nil and th('t1').state == 'draft')

-- From the thread float
open()
proposed(9)
at(9)
w.decide('accept')
at(9)
w.thread()
answer = 'something else please'
press('r')
check('revise: r in the float does the same, and the float shows it', #th('t1').messages == 3 and th('t1').decision == nil
  and th('t1').state == 'draft' and float_text():match('You: something else please') and float_text():match(' · draft'), float_text())
press('q')

-- A decision that was sent stands; a reply goes to the agent that is applying it
open()
proposed(9)
at(9)
w.decide('accept')
w.send()
sent = {}
answer = 'also in b.txt'
at(9)
w.ask()
check('reply after an accepted proposal was sent: the decision stands', th('t1').decision == 'accept' and th('t1').decision_sent == true
  and th('t1').state == 'draft')
w.send()
check('... and Expected says to apply it with this message in mind', #sent == 1 and sent[1].text:match('Your proposal in this thread was accepted: apply it, taking this message into account'),
  sent[1] and sent[1].text)

-- A new proposal from the agent clears a stale decision ----------------------------------------------------------------------------
open()
proposed(9)
at(9)
w.decide('accept')
send('patch', { thread = 't1', answer = 'a different idea', proposal = true })
check('new proposal: an unsent decision is cleared', th('t1').state == 'proposed' and th('t1').decision == nil and not th('t1').decision_sent
  and label_at(9):match('^» t1 %(proposal%)'), label_at(9))
at(9)
w.decide('accept')
w.send()
send('patch', { thread = 't1', answer = 'one more idea', proposal = true })
check('new proposal: a decision that was sent is cleared too', th('t1').state == 'proposed' and th('t1').decision == nil
  and th('t1').decision_sent == nil)
at(9)
w.decide('reject')
check('new proposal: and it can be decided again', th('t1').decision == 'reject' and label_at(9):match('%(declined, not sent%)'))
send('patch', { thread = 't1', answer = 'plain answer to something' })
check('a plain answer does not keep a decision that was not sent', th('t1').decision == nil and th('t1').state == 'answered')

-- The agent still cannot decide ---------------------------------------------------------------------------------------------------------
check('agent: "decision" in a thread patch is refused', send('patch', { thread = 't1', decision = 'accept' }):match('^error: ') ~= nil)
check('agent: ... and "decision_sent"', send('patch', { thread = 't1', decision_sent = true }):match('^error: ') ~= nil)

-- Continuing a closed thread ---------------------------------------------------------------------------------------------------------------
-- Declined.
open()
proposed(9)
at(9)
w.decide('reject')
w.send()
sent = {}
answer = 'an alias instead?'
at(9)
w.ask()
local c = th('t1')
check('declined: writing on the lines continues the same thread', #threads() == 1 and #c.messages == 3 and c.messages[3].text == 'an alias instead?')
check('declined: it is open again, the message not sent, the old decision gone', c.state == 'draft' and c.decision == nil and c.decision_sent == nil
  and label_at(9) == '» t1 (not sent) you: an alias instead?' and dim_at(9) == false, label_at(9))
w.send()
check('declined: Expected for a change thread is to revise with a proposal', #sent == 1
  and sent[1].text:match('Expected: The user asks you to revise your proposal: reply with a new proposal'), sent[1] and sent[1].text)
check('declined: the thread waits again', th('t1').state == 'waiting')
-- Done, a change thread, from the line.
open()
proposed(9)
at(9)
w.decide('accept')
w.send()
send('patch', { thread = 't1', answer = 'renamed', done = true })
sent = {}
at(9)
w.change('now rename y as well')
c = th('t1')
check('done: writing with the change key continues the same thread', #threads() == 1 and #c.messages == 4 and c.messages[4].text == 'now rename y as well'
  and c.state == 'draft' and c.decision == nil and #sent == 0, vim.inspect(threads()))
w.send()
check('done: Expected for a change thread is a proposal, not an edit', #sent == 1
  and sent[1].text:match('Expected: Do not edit any code yet: reply with a proposal of what you would change, as a patch:'
    .. ' { "thread": "t1", "answer": "<the proposal>", "proposal": true }')
  and sent[1].text:match('Conversation so far:') and sent[1].text:match('You %(agent%): renamed'), sent[1] and sent[1].text)
-- A question thread.
open()
at(5)
w.ask('what is five?')
send('patch', { thread = 't1', answer = 'a number', done = true })
sent = {}
answer = 'and what is six?'
at(5)
w.ask()
c = th('t1')
check('done question: writing continues the thread and sends at once', #threads() == 1 and #c.messages == 3 and c.state == 'waiting'
  and #sent == 1, vim.inspect(threads()))
check('done question: Expected is an answer', sent[1].text:match('Expected: Answer it without changing any code, with a patch: { "thread": "t1", "answer": "%.%.%." }'),
  sent[1] and sent[1].text)
-- From the float's r.
open()
proposed(9)
at(9)
w.decide('reject')
w.send()
at(9)
w.thread()
answer = 'try once more'
sent = {}
press('r')
check('declined, float r: continues the thread', #threads() == 1 and #th('t1').messages == 3 and th('t1').state == 'draft' and th('t1').decision == nil
  and float_text():match('You: try once more') and float_text():match(' · draft'), float_text())
press('q')
w.send()
check('declined, float r: and send tells the agent to revise', #sent == 1 and sent[1].text:match('revise your proposal'))
open()
proposed(9)
at(9)
w.decide('accept')
w.send()
send('patch', { thread = 't1', answer = 'done', done = true })
at(9)
w.thread()
answer = 'one more change'
sent = {}
press('r')
check('done, float r: continues the thread', #threads() == 1 and #th('t1').messages == 4 and th('t1').state == 'draft'
  and float_text():match('You: one more change'), float_text())
press('q')
w.send()
check('done, float r: Expected is a proposal', sent[1] and sent[1].text:match('Expected: Do not edit any code yet'), sent[1] and sent[1].text)
-- The closed thread is found even when the lines are a part of its range.
open()
at(10)
w.change('simplify these', { 10, 12 })
w.send()
send('patch', { thread = 't1', done = true })
answer = 'on one line of it'
at(11)
w.ask()
check('closed thread: a line inside its range continues it', #threads() == 1 and #th('t1').messages == 2, vim.inspect(threads()))
-- Two closed threads on the same lines: the newest is continued; an open one comes first.
open()
at(9)
w.change('first')
send('patch', { thread = 't1', done = true })
at(9)
w.change('second')
check('closed thread: continued', #threads() == 1 and #th('t1').messages == 2)
send('patch', { thread = 't1', done = true })
th('t1').to = 9
local second = { id = 't2', kind = 'change', from = 9, to = 9, messages = { { by = 'user', text = 'x' } }, state = 'done', sent = 1 }
table.insert(st.history[1].threads, second)
answer = 'newest'
at(9)
w.change()
check('closed threads: the newest is continued', #second.messages == 2 and #th('t1').messages == 2 and second.state == 'draft', vim.inspect(threads()))

-- Questions still go out at once -------------------------------------------------------------------------------------------------------------------
open()
at(3)
w.ask('why this?')
check('question: sent at once', #sent == 1 and th('t1').state == 'waiting')
send('patch', { thread = 't1', answer = 'because' })
sent = {}
at(3)
w.ask('and then?')
check('question: a reply is sent at once as well', #sent == 1 and th('t1').state == 'waiting')

-- Stored state from before ------------------------------------------------------------------------------------------------------------------------------
open()
proposed(9)
at(9)
w.decide('accept')
w.send()
proposed(14)
at(14)
w.decide('reject')
local path = store.path(root)
local data = vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
local stored = data.tours[1].steps[1].threads
check('stored: a thread with a sent decision keeps the decision and its state', stored[1].state == 'accepted' and stored[1].decision_sent == true
  and stored[2].state == 'proposed' and stored[2].decision == 'reject' and stored[2].decision_sent == nil, vim.inspect(stored))
-- The way it was written before: no `decision` field, the state said it all.
stored[1].decision = nil
stored[2].decision = nil
stored[2].state = 'declined'
-- ... and a third, accepted but never told (the sender had failed).
table.insert(stored, {
  id = 't3', kind = 'change', from = 20, to = 20, messages = { { by = 'user', text = 'old' }, { by = 'agent', text = 'p', proposal = true } },
  state = 'accepted', sent = 1,
})
data.tours[1].next_thread = 4
vim.fn.writefile({ vim.json.encode(data) }, path)
w.close()
check('stored: resume reads it', w.resume() == 'ok')
c = th('t1')
check('stored: the sent acceptance is still accepted and told', c.state == 'accepted' and c.decision_sent == true
  and label_at(9) == '» t1 (accepted) you: rename it', label_at(9))
check('stored: clearing it is refused', (function()
  reset_log()
  at(9)
  w.decide('clear')
  return th('t1').state == 'accepted' and find('write on the line') ~= nil
end)())
check('stored: a decision that was never told is a decision marked and not sent', th('t2').state == 'proposed' and th('t2').decision == 'reject'
  and not th('t2').decision_sent and label_at(14) == '» t2 (declined, not sent) you: rename it', label_at(14))
check('stored: ... and so is the third', th('t3').state == 'proposed' and th('t3').decision == 'accept' and not th('t3').decision_sent)
sent = {}
w.send()
check('stored: send delivers the decisions that were not told', #sent == 1 and sent[1].text:match('%(2 items%)') and th('t2').state == 'declined'
  and th('t3').state == 'accepted' and th('t3').decision_sent == true, sent[1] and sent[1].text)
check('stored: a reply in an old accepted thread keeps its acceptance', (function()
  answer = 'fine, and also this'
  at(9)
  w.ask()
  sent = {}
  w.send()
  return th('t1').decision == 'accept' and th('t1').decision_sent == true
    and sent[1] and sent[1].text:match('was accepted: apply it, taking this message into account') ~= nil
end)())

-- Old thread state with a decision that was sent loads without the field
open()
proposed(9)
local plain = vim.deepcopy(th('t1'))
plain.state, plain.decision_sent = 'declined', true
st.history[1].threads[1] = plain
store.save(root)
w.close()
check('stored: a declined thread without `decision` loads', w.resume() == 'ok' and th('t1').state == 'declined' and label_at(9) == '» t1 (declined) you: rename it',
  label_at(9))
at(9)
answer = 'continue this one'
w.ask()
check('stored: ... and can be continued', #threads() == 1 and #th('t1').messages == 3 and th('t1').state == 'draft')

-- A change request written in a question thread: the thread becomes a change request ------------------------------
open()
at(20)
w.ask('what is line 20 for?')
local q = threads()[#threads()]
check('convert: a question thread, sent at once', q.kind == 'question' and q.state == 'waiting' and #sent == 1)
send('patch', { thread = q.id, answer = 'it holds the limit' })
check('convert: answered', th(q.id).state == 'answered')
sent = {}
local prompts = {}
vim.ui.input = function(opts, cb)
  table.insert(prompts, opts.prompt)
  cb(answer)
end
answer = 'then make the limit configurable'
reset_log()
at(20)
w.change()
check('convert: the prompt says it is a change request in the thread', prompts[1] ~= nil
  and prompts[1]:match('^Change request in ' .. q.id) ~= nil, vim.inspect(prompts))
check('convert: no new thread; the question thread is a change request now', #threads() == 1 and th(q.id).kind == 'change'
  and #th(q.id).messages == 3 and th(q.id).messages[3].text == 'then make the limit configurable', vim.inspect(threads()))
check('convert: it is collected, not sent', #sent == 0 and th(q.id).state == 'draft'
  and find('is a change request now; send delivers it') ~= nil, vim.inspect(log))
w.send()
check('convert: send asks for a proposal, not for an answer', #sent == 1 and sent[1].text:match('Change request ' .. q.id) ~= nil
  and sent[1].text:match('reply with a proposal') ~= nil and not sent[1].text:match('Answer it without changing any code'), sent[1] and sent[1].text)
send('patch', { thread = q.id, answer = 'I would read it from LIMIT', proposal = true })
check('convert: the proposal can be decided', th(q.id).state == 'proposed' and (function()
  at(20)
  w.decide('accept')
  return th(q.id).decision == 'accept'
end)())
-- The other way round a question stays a reply: a change request keeps its proposal flow.
prompts, sent = {}, {}
answer = 'why from the environment?'
at(20)
w.ask()
check('convert: a question in a change request is a reply in it', prompts[1] ~= nil and prompts[1]:match('^Reply in ' .. q.id) ~= nil
  and th(q.id).kind == 'change' and #threads() == 1 and #sent == 0, vim.inspect({ prompts, th(q.id).kind }))
-- The same with the text given, and in the thread float the reply key changes nothing.
open()
at(21)
w.ask('q?')
q = threads()[#threads()]
w.change('do it')
check('convert: with the text given as an argument', th(q.id).kind == 'change' and #threads() == 1)
open()
at(22)
w.ask('q2?')
q = threads()[#threads()]
answer = 'a follow-up'
w.ask()
check('convert: a question in a question thread stays a question', th(q.id).kind == 'question' and #th(q.id).messages == 2)
vim.ui.input = function(_, cb)
  cb(answer)
end

-- Plan reviews: nothing changes there -----------------------------------------------------------------------------------------------------------------------
check('a plan has no decisions', (function()
  local feedback = require('walkthrough.feedback')
  reset_log()
  feedback.decide_on({ t = { plan = true }, thread = { id = 't1', state = 'proposed' } }, 'accept')
  return find('a plan has no proposals to decide') ~= nil
end)())

w.close()
vim.cmd('silent! %bwipeout!')
H.finish()
