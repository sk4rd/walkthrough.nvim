-- The user's side of the review: threads (questions sent at once, change
-- requests collected), replies, send and inbox, the agent's patches, accept
-- and decline, the messages to the agent, explain simpler/deeper and evidence
-- labels. The agent's channel is stubbed: config.sender collects the
-- messages, vim.ui.input answers from a variable.
local H = require('helpers')
local check, send, w = H.check, H.send, H.w
local st = _G.walkthrough_state
local store = require('walkthrough.store')
local feedback = require('walkthrough.feedback')
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
local function cd(dir)
  vim.cmd('cd ' .. vim.fn.fnameescape(dir))
end
local function reset_log()
  for i = #log, 1, -1 do
    log[i] = nil
  end
end

-- Messages handed to the sender, and the answer vim.ui.input gives.
local sent, answer = {}, nil
local function collecting(msg)
  table.insert(sent, msg)
end
st.config.sender = collecting
vim.ui.input = function(opts, cb)
  cb(answer)
end

local repo = H.repo({ ['a.txt'] = lines(20), ['b.txt'] = lines(6, 'b') }, {})
cd(repo)
local a, b = repo .. '/a.txt', repo .. '/b.txt'
local root = store.root_of(a)
local function tour()
  return {
    group = 'A',
    steps = {
      {
        file = a, title = 'one', from = 5, to = 8,
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
  w.discard() -- a fresh review: nothing saved comes back
  w.close()
  vim.cmd('silent! %bwipeout!')
  reset_log()
  sent = {}
  st.config.sender = collecting
  vim.fn.writefile(lines(20), a)
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
local function virt(pattern)
  return H.marks(function(d)
    return d.virt_lines ~= nil and d.virt_lines[1] ~= nil and H.vtext(d.virt_lines[1]):match(pattern) ~= nil
  end, vim.fn.bufnr(a))
end
local function dimmed()
  return H.marks(function(d)
    return d.virt_lines and d.virt_lines[1][1][2] == 'WalkthroughThreadDim'
  end, vim.fn.bufnr(a))
end
local function raising()
  st.config.sender = function()
    error('terminal is gone', 0)
  end
end

open()

-- ask: a new question ---------------------------------------------------------------------
at(3)
w.ask('why this?')
local q = threads()[1]
check('ask: a thread on the cursor line', q and q.id == 't1' and q.kind == 'question' and q.from == 3 and q.to == 3
  and #q.messages == 1 and q.messages[1].by == 'user' and q.messages[1].text == 'why this?', vim.inspect(threads()))
check('ask: sent at once, through the sender', #sent == 1 and q.state == 'waiting' and q.sent == 1, vim.inspect({ #sent, q }))
check('ask: the message asks for an answer patch', sent[1] and sent[1].text:match('Question t1 at a%.txt:3, step 1')
  and sent[1].text:match('User: why this%?') and sent[1].text:match('{ "thread": "t1", "answer": "%.%.%." }'), sent[1] and sent[1].text)
check('ask: the sender is told to submit by default', sent[1].submit == true)
check('ask: the reference is the line', #sent[1].refs == 1 and sent[1].refs[1].file == a and sent[1].refs[1].from == 3
  and sent[1].refs[1].to == 3, vim.inspect(sent[1].refs))
check('ask: shown under its line, with the state', virt('^» t1 %(waiting%) you: why this%?$') == 1)
check('ask: the panel is the map and says nothing of the text', not H.panel_text():match('why this'), H.panel_text())
check('ask: and is saved', (function()
  local data = vim.json.decode(table.concat(vim.fn.readfile(store.path(root)), '\n'))
  local saved = data.tours[1].steps[1].threads[1]
  return saved.id == 't1' and saved.state == 'waiting' and data.tours[1].next_thread == 2 and data.tours[1].steps[1].comments == nil
end)())

-- ask: prompt, empty answer, visual mode, command range ------------------------------------------
answer = 'asked text'
at(4)
w.ask()
check('ask: without text the user is asked', #threads() == 2 and threads()[2].messages[1].text == 'asked text' and threads()[2].from == 4)
answer = '   '
at(5)
w.ask()
check('ask: an empty answer cancels', #threads() == 2 and #sent == 2)
answer = nil
w.ask()
check('ask: no answer (escape) cancels', #threads() == 2 and #sent == 2)
reset_log()
w.thread_delete()
check('thread delete: nothing under the cursor says so', #threads() == 2 and find('no thread here') ~= nil)
at(4)
w.thread_delete()
check('thread delete: the thread under the cursor goes', #threads() == 1 and threads()[1].id == 't1' and virt('^» t2 ') == 0)

answer = 'about these'
at(10)
vim.api.nvim_feedkeys(vim.keycode('Vj<Plug>(walkthrough-ask)'), 'x', false)
local v = threads()[2]
check('ask: a visual selection covers its lines', v and v.from == 10 and v.to == 11 and v.kind == 'question' and v.id == 't3'
  and v.state == 'waiting', vim.inspect(threads()))
check('ask: ... ids are never reused after a delete, visual mode ended', v.id == 't3' and vim.fn.mode() == 'n')
check('ask: ... drawn under the last selected line', #H.marks_at(11, vim.fn.bufnr(a)) > 0 and virt('^» t3 ') == 1)
check('ask: ... and the message names the range and the first lines', sent[#sent].text:match('Question t3 at a%.txt:10%-11')
  and sent[#sent].text:match('     l10\n     l11\n') and sent[#sent].refs[1].to == 11, sent[#sent].text)
answer = nil
vim.cmd('normal! 17GVj\27')
vim.cmd("'<,'>Walkthrough ask what is this")
local r = threads()[3]
check(':Walkthrough ask with a range and text', r and r.from == 17 and r.to == 18 and r.messages[1].text == 'what is this'
  and r.state == 'waiting', vim.inspect(threads()))
at(19)
vim.cmd('Walkthrough ask and this')
check(':Walkthrough ask without a range uses the cursor line', threads()[4] and threads()[4].from == 19
  and threads()[4].messages[1].text == 'and this', vim.inspect(threads()))
check('ask_line is the old name of ask', w.ask_line == w.ask)
local r_count = #threads()
vim.api.nvim_set_current_win(st.panel_win)
reset_log()
w.ask('from the panel')
check('ask: only on a file, not in the map', #threads() == r_count and find('this buffer is not one') ~= nil)
at(1)
vim.cmd('normal! ix')
reset_log()
w.ask('unsaved')
check('ask: an unsaved buffer is refused', #threads() == r_count and find('save the file first') ~= nil)
vim.cmd('edit!')

-- ask: the finding on the line is context -------------------------------------------------------------
open()
at(6)
w.ask('is this needed?')
check('ask: a note on the line is included, with verdict and detail', sent[1] and sent[1].text:match('Finding %[1%] %(verdict: simplify%): six')
  and sent[1].text:match('Detail: why six'), sent[1] and sent[1].text)
at(2)
w.ask('no note here')
check('ask: no finding, no finding context', not sent[2].text:match('Finding'), sent[2].text)

-- ask: failure keeps a draft ---------------------------------------------------------------------------
open()
raising()
at(3)
reset_log()
w.ask('are you there?')
q = th('t1')
check('ask: a failing sender keeps the question as a draft', q and q.state == 'draft' and q.sent == 0 and #q.messages == 1
  and #sent == 0, vim.inspect(threads()))
check('ask: ... and says it is kept for send', find('terminal is gone') ~= nil and find('kept for send') ~= nil, vim.inspect(log))
check('ask: ... shown as not sent', virt('^» t1 %(not sent%) you: are you there%?$') == 1)
st.config.sender = collecting
w.send()
check('send: a draft goes out with the next send', #sent == 1 and q.state == 'waiting' and q.sent == 1
  and sent[1].text:match('Question t1') ~= nil, vim.inspect(sent))
-- No agent at all: the real senders.
open()
st.config.sender = 'terminal'
at(3)
reset_log()
w.ask('nobody?')
check('ask: no agent terminal keeps a draft and does not raise', th('t1') and th('t1').state == 'draft'
  and find('no agent terminal found') ~= nil and find('kept for send') ~= nil, vim.inspect(log))
st.config.sender = collecting

-- Replies ----------------------------------------------------------------------------------------------
open()
at(3)
w.ask('first')
send('patch', { thread = 't1', answer = 'because' })
at(3)
w.ask('and then?')
q = th('t1')
check('reply: asking on the lines of a thread appends to it', #threads() == 1 and #q.messages == 3 and q.messages[3].by == 'user'
  and q.messages[3].text == 'and then?', vim.inspect(threads()))
check('reply: a reply in a question is sent at once, with the conversation', #sent == 2 and q.state == 'waiting' and q.sent == 3
  and sent[2].text:match('Conversation so far:\n     User: first\n     You %(agent%): because\n')
  and sent[2].text:match('User: and then%?') and select(2, sent[2].text:gsub('User: first', '')) == 1, sent[2].text)
check('reply: the last user message and the last answer are drawn', virt('^» t1 %(waiting%) you: and then%?$') == 1
  and H.marks(function(d)
    return d.virt_lines and d.virt_lines[2] and d.virt_lines[2][1][1]:match('↳ because') ~= nil
  end, vim.fn.bufnr(a)) == 1)
-- A change request on a question's lines is a reply too.
answer = 'via change'
at(3)
w.change()
check('reply: change on the lines of a question replies in it (and is sent: it is a question)', #threads() == 1
  and #q.messages == 4 and q.messages[4].text == 'via change' and #sent == 3, vim.inspect(threads()))
-- A change thread: a reply to it is collected, even when written with ask.
at(9)
w.change('rename it')
at(9)
w.ask('and add a test')
local c = th('t2')
check('reply: ask on the lines of a change request replies in it', #threads() == 2 and #c.messages == 2 and c.messages[2].text == 'and add a test',
  vim.inspect(threads()))
check('reply: ... collected, not sent', #sent == 3 and c.state == 'draft' and c.sent == 0)
-- Closed threads take no reply: a new thread starts.
send('patch', { thread = 't2', answer = 'done it', done = true })
at(9)
w.ask('different matter')
check('reply: lines of a done thread start a new thread', #threads() == 3 and th('t3') and th('t3').messages[1].text == 'different matter'
  and #th('t2').messages == 3, vim.inspect(threads()))
at(14)
w.change('declined one')
send('patch', { thread = 't4', answer = 'a proposal', proposal = true })
w.decide('reject')
at(14)
w.ask('after declining')
check('reply: lines of a declined thread start a new thread', #threads() == 5 and th('t4').state == 'declined'
  and th('t5').messages[1].text == 'after declining', vim.inspect(threads()))

-- Change requests: collected ---------------------------------------------------------------------------
open()
at(9)
w.change('rename it')
c = th('t1')
check('change: a change thread, collected as a draft', c and c.kind == 'change' and c.state == 'draft' and c.sent == 0 and #sent == 0,
  vim.inspect(threads()))
check('change: shown as not sent', virt('^» t1 %(not sent%) you: rename it$') == 1)
answer = 'second one'
at(14)
vim.api.nvim_feedkeys(vim.keycode('<Plug>(walkthrough-change)'), 'x', false)
check('change: the mapping asks and adds, nothing is sent', th('t2') and th('t2').kind == 'change' and th('t2').from == 14
  and th('t2').messages[1].text == 'second one' and #sent == 0)
answer = nil
vim.cmd('normal! 17GVj\27')
vim.cmd("'<,'>Walkthrough change use a loop")
check(':Walkthrough change takes a range and text', th('t3') and th('t3').from == 17 and th('t3').to == 18
  and th('t3').kind == 'change' and #sent == 0)

-- send: everything not yet delivered in one message ---------------------------------------------------------
at(12)
w.ask('a question in between')
check('send: the question went out at once, the requests did not', #sent == 1 and th('t4').state == 'waiting' and th('t1').state == 'draft')
sent = {}
w.send()
check('send: one message with the three requests', #sent == 1 and sent[1].text:match('%(3 items%)'), sent[1] and sent[1].text)
local msg = sent[1]
check('send: numbered items with kind, id and path:lines', msg.text:match('\n1%. Change request t1 at a%.txt:9, step 1')
  and msg.text:match('\n2%. Change request t2 at a%.txt:14, step 1') and msg.text:match('\n3%. Change request t3 at a%.txt:17%-18, step 1'),
  msg.text)
check('send: ... each with its code and the user\'s text', msg.text:match('     l9\n') and msg.text:match('User: rename it')
  and msg.text:match('User: second one') and msg.text:match('User: use a loop'), msg.text)
check('send: ... and the expected patch, a proposal before any edit', msg.text:match('Do not edit any code yet')
  and msg.text:match('{ "thread": "t1", "answer": "<the proposal>", "proposal": true }'), msg.text)
check('send: references for the senders', #msg.refs == 3 and msg.refs[1].from == 9 and msg.refs[3].to == 18, vim.inspect(msg.refs))
check('send: the threads are delivered and wait', th('t1').state == 'waiting' and th('t1').sent == 1 and th('t2').state == 'waiting'
  and th('t3').state == 'waiting', vim.inspect(threads()))
check('send: ... and the question that was sent at once is not sent again', not msg.text:match('t4'))
reset_log()
w.send()
check('send: with nothing left it says so', #sent == 1 and find('nothing to send') ~= nil)

-- inbox ------------------------------------------------------------------------------------------------
open()
at(9)
w.change('rename it')
w.send()
send('patch', { thread = 't1', answer = 'maybe', proposal = true })
at(9)
w.ask('why not?') -- a reply in the change thread: collected
at(14)
w.change('and this')
at(3)
w.ask('a question')
local res = w.inbox()
local inbox = vim.json.decode(res)
check('inbox: group and items in line order', inbox.group == 'A' and #inbox.items == 2, res)
local i1, i2 = inbox.items[1], inbox.items[2]
check('inbox: the thread with a new reply', i1.kind == 'change' and i1.id == 't1' and i1.step == 1 and i1.file == a and i1.from == 9
  and i1.to == 9 and i1.state == 'draft' and #i1.messages == 3 and i1.new == 3 and i1.messages[2].by == 'agent'
  and i1.messages[2].proposal == true and i1.messages[3].text == 'why not?', res)
check('inbox: ... and the other undelivered one, whole', i2.kind == 'change' and i2.id == 't2' and i2.new == 1 and #i2.messages == 1, res)
check('inbox: the question was sent at once, so it is not listed', not res:match('"t3"'))
check('inbox: marks them delivered', th('t1').sent == 3 and th('t1').state == 'waiting' and th('t2').state == 'waiting'
  and #vim.json.decode(w.inbox()).items == 0)
check('inbox: nothing left is an empty list', w.inbox():match('"items":%[%]') ~= nil and vim.json.decode(w.inbox()).group == 'A')
local all = vim.json.decode(w.inbox(true))
local ids = vim.tbl_map(function(i) return i.id end, all.items)
check('inbox(all): also the threads that wait for an answer', vim.deep_equal(ids, { 't3', 't1', 't2' }), vim.inspect(ids))
local waiting_item
for _, i in ipairs(all.items) do
  if i.id == 't2' then
    waiting_item = i
  end
end
check('inbox(all): a delivered thread has no new message', waiting_item and waiting_item.new == #waiting_item.messages + 1, vim.inspect(waiting_item))
send('patch', { thread = 't2', answer = 'ok' })
check('inbox(all): an answered thread is not waiting any more', not w.inbox(true):match('"t2"'))
check('inbox: no tour is an empty list, not an error', (function()
  local keep = st.tours
  st.tours, st.active = {}, 0
  local r = w.inbox()
  st.tours, st.active = keep, 1
  return r:match('^{"items":%[%]}$') ~= nil
end)())
check('inbox: a broken tour is an error line, not a raise', (function()
  local keep = st.tours[1].steps
  st.tours[1].steps = 5
  local ok, r = pcall(w.inbox)
  st.tours[1].steps = keep
  return ok and r:match('^error: [^\n]+$') ~= nil
end)())

-- Patches: the agent's side ---------------------------------------------------------------------------------
open()
at(3)
w.ask('why this?')
at(9)
w.change('rename it')
check('patch: answer appends an agent message', send('patch', { step = 1, thread = 't1', answer = 'because' }) == 'ok'
  and #th('t1').messages == 2 and th('t1').messages[2].by == 'agent' and th('t1').messages[2].text == 'because'
  and th('t1').messages[2].proposal == nil and th('t1').state == 'answered' and th('t1').sent == 2, vim.inspect(th('t1')))
check('patch: ... shown as a second line', H.marks(function(d)
  return d.virt_lines and d.virt_lines[2] and d.virt_lines[2][1][1]:match('↳ because') ~= nil
end, vim.fn.bufnr(a)) == 1)
check('patch: without a step the ids are searched in the tour; a list is a text with lines; proposal flags it',
  send('patch', { thread = 't2', answer = { 'one', 'two' }, proposal = true }) == 'ok'
  and th('t2').messages[2].text == 'one\ntwo' and th('t2').messages[2].proposal == true and th('t2').state == 'proposed',
  vim.inspect(th('t2')))
check('patch: ... a message of the user that was not sent stays pending', require('walkthrough.tour').pending_index(th('t2')) == 1
  and th('t2').sent == 0)
check('patch: replace rewrites the last agent message, state unchanged', send('patch', { thread = 't1', answer = 'simpler words', replace = true }) == 'ok'
  and #th('t1').messages == 2 and th('t1').messages[2].text == 'simpler words' and th('t1').state == 'answered')
check('patch: ... a proposal stays one', send('patch', { thread = 't2', answer = 'shorter', replace = true }) == 'ok'
  and th('t2').messages[2].proposal == true and th('t2').messages[2].text == 'shorter' and th('t2').state == 'proposed')
check('patch: done with an answer appends it and closes', send('patch', { thread = 't1', answer = 'finished', done = true }) == 'ok'
  and #th('t1').messages == 3 and th('t1').messages[3].text == 'finished' and th('t1').state == 'done')
check('patch: done alone closes', send('patch', { thread = 't2', done = true }) == 'ok' and th('t2').state == 'done' and #th('t2').messages == 2)
check('patch: done threads are dimmed', dimmed() == 2)
check('patch: the step may be named', send('patch', { step = 2, thread = 't1', answer = 'x' })
  :match('^error: patch 1: there is no thread t1 in step 2$') ~= nil)
check('patch: unknown thread', send('patch', { thread = 't9', answer = 'x' }):match('^error: patch 1: there is no thread t9$') ~= nil)
check('patch: a thread id must be a string', send('patch', { thread = 5, answer = 'x' }):match('"thread" must be a thread id') ~= nil)

-- The agent cannot create, delete, re-type, decide or write for the user.
local before = vim.deepcopy(threads())
for name, p in pairs({
  new = { thread = 't9', text = 'x', from = 1, to = 1 },
  delete = { thread = 't1', remove = true },
  user_message = { thread = 't1', by = 'user', text = 'x' },
  messages = { thread = 't1', messages = {} },
  state = { thread = 't1', state = 'accepted' },
  kind = { thread = 't1', kind = 'change' },
  move = { thread = 't1', from = 2 },
  sent = { thread = 't1', sent = 0 },
  decision = { thread = 't1', decision = 'accept' },
  resolved = { thread = 't1', resolved = true },
  both = { thread = 't1', note = 1, answer = 'x' },
  bad_answer = { thread = 't1', answer = 5 },
  empty_answer = { thread = 't1', answer = '  ' },
  bad_proposal = { thread = 't1', answer = 'x', proposal = 'yes' },
  bad_done = { thread = 't1', done = 'yes' },
  bad_replace = { thread = 't1', answer = 'x', replace = 1 },
  done_and_proposal = { thread = 't1', answer = 'x', done = true, proposal = true },
  replace_and_done = { thread = 't1', answer = 'x', done = true, replace = true },
  proposal_alone = { thread = 't1', proposal = true },
  replace_alone = { thread = 't1', replace = true },
  nothing = { thread = 't1' },
}) do
  local res = send('patch', p)
  check('agent: ' .. name .. ' is refused', res:match('^error: ') ~= nil and not res:match('\n') and vim.deep_equal(threads(), before), res)
end
check('agent: nothing to replace', (function()
  open()
  at(3)
  w.change('x')
  local res = send('patch', { thread = 't1', answer = 'y', replace = true })
  return res:match('has no message of the agent to replace') ~= nil and #th('t1').messages == 1
end)())
open()
at(3)
w.ask('why?')
check('agent: "threads" is not a step field', send('patch', { threads = { { id = 't7' } } }):match('unknown step field "threads"') ~= nil)
check('agent: JSON cannot carry threads either', send('load', { steps = { { file = a, threads = {} } } }):match('unknown step field "threads"') ~= nil)
check('agent: "comment" is gone', send('patch', { comment = 'c1' }):match('unknown step field "comment"') ~= nil)
check('agent: a failed list changes nothing', send('patch', { { thread = 't1', answer = 'changed' }, { thread = 't9', answer = 'x' } }):match('^error:') ~= nil
  and #th('t1').messages == 1 and th('t1').state == 'waiting')
check('agent: two patches for one thread in a list apply in order', send('patch', { { thread = 't1', answer = 'one', proposal = true },
  { thread = 't1', answer = 'two', replace = true } }) == 'ok' and #th('t1').messages == 2 and th('t1').messages[2].text == 'two'
  and th('t1').state == 'proposed')

-- State transitions, end to end -----------------------------------------------------------------------------
open()
at(3)
w.ask('why?')
local trail = { th('t1').state }
send('patch', { thread = 't1', answer = 'because' })
table.insert(trail, th('t1').state)
at(3)
w.ask('and?')
table.insert(trail, th('t1').state)
send('patch', { thread = 't1', answer = 'that is why' })
table.insert(trail, th('t1').state)
check('flow: question -> waiting -> answered -> reply -> waiting -> answered', table.concat(trail, ',') == 'waiting,answered,waiting,answered'
  and #th('t1').messages == 4, table.concat(trail, ','))
check('flow: the counts are in the status', vim.deep_equal(status().threads, { draft = 0, waiting = 0, answered = 1, proposed = 0 }),
  vim.inspect(status().threads))

open()
check('flow: no threads, no field in the status', status().threads == nil)
at(9)
w.change('rename it')
trail = { th('t1').state }
w.send()
table.insert(trail, th('t1').state)
send('patch', { thread = 't1', answer = 'I would rename x to y', proposal = true })
table.insert(trail, th('t1').state)
check('flow: the status counts a proposal', status().threads and status().threads.proposed == 1, vim.inspect(status()))
sent = {}
at(9)
w.decide('accept')
table.insert(trail, th('t1').state)
check('flow: accept is sent at once', #sent == 1 and th('t1').decision_sent == true and th('t1').state == 'accepted'
  and sent[1].text:match('the user accepted it') and sent[1].text:match('{ "thread": "t1", "answer": "<what you changed>", "done": true }')
  and sent[1].text:match('You %(agent%) %(proposal%): I would rename x to y'), sent[1] and sent[1].text)
send('patch', { thread = 't1', answer = 'renamed', done = true })
table.insert(trail, th('t1').state)
check('flow: change -> draft -> waiting -> proposed -> accepted -> done', table.concat(trail, ',') == 'draft,waiting,proposed,accepted,done',
  table.concat(trail, ','))
check('flow: the drawing follows', virt('^» t1 %(done%) you: rename it$') == 1)

-- Declined.
open()
at(9)
w.change('rename it')
w.send()
send('patch', { thread = 't1', answer = 'rename x', proposal = true })
sent = {}
at(9)
w.decide('reject')
check('flow: declined is sent at once and says to leave the code', th('t1').state == 'declined' and #sent == 1
  and sent[1].text:match('the user declined it') and sent[1].text:match('leave the code as it is'), sent[1] and sent[1].text)
check('flow: ... and is dimmed', dimmed() == 1 and virt('^» t1 %(declined%) you:') == 1)
sent = {}
w.send()
check('flow: and is not sent again', #sent == 0)

-- Decisions: on nothing, on a note, failures ------------------------------------------------------------------
open()
at(1)
reset_log()
w.decide('accept')
check('decide: nothing here says so', find('nothing to decide here') ~= nil and #sent == 0)
at(3)
w.ask('q')
reset_log()
w.decide('accept')
check('decide: a thread that is not a proposal is nothing to decide', find('nothing to decide here') ~= nil and th('t1').state == 'waiting')
at(6)
w.decide('accept')
local note = st.history[1].notes[1]
check('decide: on a note, stored and sent at once', note.decision == 'accept' and note.decision_sent == true and #sent == 2
  and sent[2].text:match('Decision on finding %[1%] at a%.txt:6, step 1, your verdict: simplify') and sent[2].text:match('accepted your verdict')
  and sent[2].text:match('{ "step": 1, "note": 1, "verdict": "done" }'), sent[2] and sent[2].text)
check('decide: badge next to the verdict', H.marks(function(d)
  if not d.virt_text then
    return false
  end
  local txt = {}
  for _, ch in ipairs(d.virt_text) do
    table.insert(txt, ch[1])
  end
  local joined = table.concat(txt)
  return joined:match('SIMPLIFY') and joined:match('✓ accepted') and joined:match('read') ~= nil
end, vim.fn.bufnr(a)) == 1)
w.decide('reject')
check('decide: reject replaces it and is sent again, leaving the code', note.decision == 'reject' and #sent == 3
  and sent[3].text:match('rejected your verdict') and sent[3].text:match('Leave the code as it is and acknowledge'), sent[3] and sent[3].text)
w.decide(nil)
check('decide: nil clears it, nothing is sent', note.decision == nil and #sent == 3)
w.decide('accept')
w.decide('clear')
check('decide: "clear" clears it too', note.decision == nil)
reset_log()
w.decide('maybe')
check('decide: other values are refused', find('accept, reject or clear') ~= nil and note.decision == nil)
at(15)
w.decide('accept')
check('decide: a keep verdict has nothing to apply', sent[#sent].text:match('Nothing to change; acknowledge'), sent[#sent].text)
at(12)
vim.cmd('Walkthrough decide reject')
check('decide: with the command on the note\'s line', st.history[1].notes[2].decision == 'reject')
vim.api.nvim_set_current_win(st.panel_win)
reset_log()
w.decide('accept')
check('decide: not from the panel, which does not list notes', find('nothing to decide here') ~= nil and st.history[1].notes[2].decision == 'reject')
vim.api.nvim_set_current_win(st.code_win)
check('decide: the agent cannot set it (patch)', send('patch', { note = 1, decision = 'accept' }):match('unknown note field "decision"') ~= nil)
check('decide: ... nor with a replaced list of notes', send('patch', { notes = { { line = 3, text = 'x', decision = 'accept' } } })
  :match('unknown note field "decision"') ~= nil)
check('decide: ... nor from JSON', send('load', { steps = { { file = a, notes = { { line = 3, decision = 'accept' } } } } })
  :match('unknown note field "decision"') ~= nil)

-- A decision that could not be sent stays for the next send.
open()
at(9)
w.change('rename it')
w.send()
send('patch', { thread = 't1', answer = 'rename x', proposal = true })
raising()
reset_log()
at(9)
w.decide('accept')
check('decide: a failing sender keeps the decision and says so', th('t1').state == 'accepted' and not th('t1').decision_sent
  and find('kept for send') ~= nil, vim.inspect(log))
w.decide('clear')
check('decide: ... it can still be taken back', th('t1').state == 'proposed')
w.decide('accept')
st.config.sender = collecting
sent = {}
w.send()
check('decide: ... and goes out with send', th('t1').decision_sent == true and #sent == 1 and sent[1].text:match('the user accepted it'), vim.inspect(sent))
at(6)
raising()
w.decide('accept')
check('decide: a note decision that failed is not marked sent', st.history[1].notes[1].decision == 'accept' and not st.history[1].notes[1].decision_sent)
st.config.sender = collecting
sent = {}
w.send()
check('decide: ... and goes out with send', st.history[1].notes[1].decision_sent == true and #sent == 1)
check('decide: ... the inbox lists a thread decision', (function()
  at(14)
  w.change('another')
  w.send()
  send('patch', { thread = 't2', answer = 'p', proposal = true })
  at(14)
  raising()
  w.decide('reject')
  local items = vim.json.decode(w.inbox()).items
  st.config.sender = collecting
  return #items == 1 and items[1].kind == 'decision' and items[1].id == 't2' and items[1].decision == 'reject'
    and items[1].text == 'p'
end)())

-- A reply written meanwhile does not hide the decision: both go out together.
open()
at(9)
w.change('rename it')
w.send()
send('patch', { thread = 't1', answer = 'rename x', proposal = true })
raising()
at(9)
w.decide('accept')
st.config.sender = collecting
at(9)
w.ask('and keep the old name as an alias')
check('decide: a reply keeps an undelivered acceptance', th('t1').state == 'accepted' and not th('t1').decision_sent and #th('t1').messages == 3)
sent = {}
w.send()
check('decide: ... and send delivers the decision and the reply in one message', #sent == 1 and sent[1].text:match('%(2 items%)')
  and sent[1].text:match('the user accepted it') and sent[1].text:match('and keep the old name') and th('t1').decision_sent == true
  and sent[1].text:match('taking this message into account') and not sent[1].text:match('Do not edit any code yet'),
  sent[1] and sent[1].text)

-- The messages to the agent --------------------------------------------------------------------------------
open()
at(10)
w.change('simplify these', { 10, 13 })
at(15)
w.ask('what is 15?')
sent = {}
w.send()
msg = sent[1]
check('message: up to three lines of the code', msg.text:match('Change request t1 at a%.txt:10%-13, step 1\n   Code:\n     l10\n     l11\n     l12\n   ')
  and not msg.text:match('     l13'), msg.text)
check('message: a finding inside the range is part of it', msg.text:match('Finding %[2%] %(verdict: remove%): twelve') ~= nil, msg.text)
check('message: a stale thread says the code changed', (function()
  th('t1').stale = true
  local m = feedback.build_message(st.tours[1], { { kind = 'thread', si = 1, step = st.history[1], thread = th('t1') } })
  th('t1').stale = nil
  return m.text:match('The code on these lines was changed') ~= nil
end)())
check('message: one format for one item and a batch', (function()
  local m = feedback.build_message(st.tours[1], { { kind = 'thread', si = 1, step = st.history[1], thread = th('t2') } })
  return m.text:match('%(1 item%)') and m.text:match('\n1%. Question t2 at a%.txt:15, step 1') and #m.refs == 1
end)())
check('message: the header names the commit and the way to answer', msg.text:match('^Walkthrough: feedback from the user on commit "A" %(1 item%)')
  and msg.text:match('Answer by patching the map'), msg.text)

-- Explain ----------------------------------------------------------------------------------------------------
open()
at(6)
w.explain('simpler')
local ex = sent[1]
check('explain: on a note, a request for the detail', ex and ex.text:match('explain this simpler') and ex.text:match('Target: finding %[1%] at a%.txt:6, verdict: simplify')
  and ex.text:match('Current explanation:\nwhy six') and ex.text:match('{ "step": 1, "note": 1, "detail": "<the new explanation>" }')
  and ex.text:match('keeping the same step and note numbers'), ex and ex.text)
check('explain: simpler means plainer words and an example', ex.text:match('plainer words; name each concept and say what it does; give one concrete example from this code'))
check('explain: references the note', ex.refs[1].file == a and ex.refs[1].from == 6 and ex.refs[1].to == 6)
check('explain: sent at once, to be submitted', ex.submit == true)
check('explain: status reports the depth', status().depth == 'simpler')
at(2)
reset_log()
w.explain('deeper')
check('explain: off a thread and a note it says so and sends nothing', #sent == 1 and find('put the cursor on a thread or a note') ~= nil
  and status().depth == 'simpler', vim.inspect(log))
at(3)
w.ask('what is this?')
sent = {}
reset_log()
w.explain('deeper')
check('explain: a thread without an answer has nothing to rewrite', #sent == 0 and find('no answer in this thread') ~= nil)
send('patch', { thread = 't1', answer = 'a plain answer' })
w.explain('deeper')
ex = sent[1]
check('explain: on a thread, the last agent message is replaced', ex and ex.text:match('explain this deeper')
  and ex.text:match('Target: your last message in thread t1 %(question%) at a%.txt:3')
  and ex.text:match('Current text:\na plain answer') and ex.text:match('{ "thread": "t1", "answer": "<the new text>", "replace": true }')
  and ex.text:match('why it is built this way') and ex.text:match('write the following answers at this level'), ex and ex.text)
check('explain: the depth is on the tour', status().depth == 'deeper' and st.tours[1].depth == 'deeper')
send('patch', { thread = 't1', answer = 'a deeper answer', replace = true })
check('explain: and the rewrite lands in place', #th('t1').messages == 2 and th('t1').messages[2].text == 'a deeper answer')
vim.api.nvim_set_current_win(st.panel_win)
reset_log()
w.explain('deeper')
check('explain: not from the panel', find('put the cursor on') ~= nil)
at(3)
vim.cmd('Walkthrough explain simpler')
check(':Walkthrough explain simpler', status().depth == 'simpler' and #sent == 2)
reset_log()
vim.cmd('Walkthrough explain louder')
check(':Walkthrough explain: bad level', find('explain takes simpler or deeper') ~= nil and #sent == 2)
raising()
reset_log()
w.explain('deeper')
check('explain: a failing sender does not change the depth', status().depth == 'simpler' and find('terminal is gone') ~= nil)
st.config.sender = collecting
open()
check('explain: no depth before any request', status().depth == nil)

-- Evidence ---------------------------------------------------------------------------------------------------
check('evidence: validated', send('load', { file = a, notes = { { line = 1, text = 'x', evidence = 'guess' } } })
  :match('^error: note 1: "evidence" must be one of opinion, ran, read$') ~= nil)
check('evidence: patch', send('patch', { note = 2, evidence = 'ran' }) == 'ok' and st.history[1].notes[2].evidence == 'ran')
check('evidence: dim label after the verdict badge', H.marks(function(d)
  if not (d.virt_text and #d.virt_text >= 3) then
    return false
  end
  local last = d.virt_text[#d.virt_text]
  return last[1] == ' ran' and last[2] == 'WalkthroughEvidence'
end, vim.fn.bufnr(a)) == 1)

-- Removed things are gone ---------------------------------------------------------------------------------------
check('removed: no comment functions', w.comment == nil and w.comment_delete == nil and require('walkthrough.send').ask_line == nil)
reset_log()
vim.cmd('Walkthrough comment x')
check('removed: no comment subcommand', find('unknown subcommand "comment"') ~= nil)
vim.cmd('Walkthrough comment-delete')
check('removed: no comment-delete subcommand', find('unknown subcommand "comment%-delete"') ~= nil)
check('removed: no comment <Plug> mappings', vim.fn.maparg('<Plug>(walkthrough-comment)', 'n') == ''
  and vim.fn.maparg('<Plug>(walkthrough-comment-issue)', 'n') == '' and vim.fn.maparg('<Plug>(walkthrough-comment-delete)', 'n') == '')

-- Threads follow edits ----------------------------------------------------------------------------------------------
open()
at(3)
w.ask('why this?')
at(10)
w.change('two lines', { 10, 11 })
local new = lines(20)
table.insert(new, 1, 'top1')
table.insert(new, 1, 'top2')
vim.fn.writefile(new, a)
status()
check('anchored: two lines inserted above move a thread down', th('t1').from == 5 and th('t1').to == 5 and not th('t1').stale, vim.inspect(threads()))
check('anchored: a range moves as a whole', th('t2').from == 12 and th('t2').to == 13, vim.inspect(threads()))
vim.cmd('edit!')
check('anchored: and is drawn there', #H.marks_at(5, vim.fn.bufnr(a)) > 0 and virt('^» t1 ') == 1)
new[5] = 'rewritten'
vim.fn.writefile(new, a)
status()
check('stale: the line of a thread was rewritten', th('t1').stale == true, vim.inspect(th('t1')))
vim.cmd('edit!')
w.step(0)
check('stale: ... and says so on screen', virt('^» t1 %(waiting%) you: why this%? %(code changed%)$') == 1)
local gone = vim.deepcopy(new)
table.remove(gone, 12)
table.remove(gone, 12)
vim.fn.writefile(gone, a)
status()
check('stale: a deleted range is stale too', th('t2').stale == true, vim.inspect(threads()))
vim.fn.writefile(new, a)
vim.cmd('edit!')

-- The mappings and commands ----------------------------------------------------------------------------------------------
open()
at(7)
answer = 'by plug'
vim.api.nvim_feedkeys(vim.keycode('<Plug>(walkthrough-ask)'), 'x', false)
check('<Plug>(walkthrough-ask) in normal mode asks, adds and sends', threads()[1] and threads()[1].messages[1].text == 'by plug'
  and threads()[1].from == 7 and #sent == 1)
vim.cmd('Walkthrough thread-delete')
check(':Walkthrough thread-delete', #threads() == 0)
vim.cmd('Walkthrough change it hurts')
vim.api.nvim_feedkeys(vim.keycode('<Plug>(walkthrough-send)'), 'x', false)
check(':Walkthrough change, then <Plug>(walkthrough-send)', #sent == 2 and sent[2].text:match('it hurts') ~= nil)
vim.api.nvim_feedkeys(vim.keycode('<Plug>(walkthrough-simpler)'), 'x', false)
check('<Plug>(walkthrough-simpler) with nothing to explain says so', #sent == 2)

-- Persistence of everything -------------------------------------------------------------------------------------------------
open()
at(3)
w.ask('persist me')
send('patch', { thread = 't1', answer = 'answered' })
at(9)
w.change('and me')
w.send()
send('patch', { thread = 't2', answer = 'proposal', proposal = true })
at(9)
w.decide('accept')
at(6)
w.decide('reject')
w.explain('deeper')
at(14)
w.change('draft only')
local snapshot = vim.deepcopy({ threads(), st.history[1].notes })
local counter = st.tours[1].next_thread
w.close()
check('persistence: the state file holds threads and the depth', (function()
  local data = vim.json.decode(table.concat(vim.fn.readfile(store.path(root)), '\n'))
  return data.version == 2 and data.tours[1].depth == 'deeper' and #data.tours[1].steps[1].threads == 3
    and data.tours[1].next_thread == counter
end)())
check('persistence: resume', w.resume() == 'ok')
check('persistence: threads and decisions are back', vim.deep_equal({ threads(), st.history[1].notes }, snapshot),
  vim.inspect({ threads(), st.history[1].notes }))
check('persistence: depth is back', status().depth == 'deeper')
check('persistence: threads are drawn again', virt('^» t1 you: persist me$') == 1)
at(12)
w.ask('after resume')
check('persistence: ids go on counting', th('t4') ~= nil)
w.thread_delete()
at(13)
w.change('once more')
check('persistence: ... and a deleted id is not reused after a resume', th('t5') ~= nil and th('t4') == nil)
-- A resend of the tour keeps what the user wrote.
w.close()
assert(w.resume() == 'ok')
assert(send('load', tour()) == 'ok')
check('persistence: a resent tour keeps threads, depth and counter', #threads() == 4 and st.tours[1].depth == 'deeper'
  and (st.tours[1].next_thread or 0) >= 6, vim.inspect(threads()))
w.close()
vim.cmd('silent! %bwipeout!')

H.finish()
