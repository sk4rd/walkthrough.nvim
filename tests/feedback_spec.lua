-- The user's side of the review: comments (P-4), decisions on notes, send
-- and inbox, explain simpler/deeper (U-6), checks (P-6) and evidence labels
-- (P-9). The agent's channel is stubbed: config.sender collects the messages,
-- vim.ui.input answers from a variable.
local H = require('helpers')
local check, send, w = H.check, H.send, H.w
local st = _G.walkthrough_state
local store = require('walkthrough.store')
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
st.config.sender = function(msg)
  table.insert(sent, msg)
end
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
        file = a, title = 'one', from = 5, to = 8, panel = '# One',
        notes = {
          { line = 6, text = 'six', verdict = 'simplify', detail = 'why six', evidence = 'read' },
          { line = 12, text = 'twelve', verdict = 'remove' },
          { line = 15, text = 'fifteen', verdict = 'keep' },
        },
        check = { question = 'What is l5?', answer = 'SECRET-ANSWER' },
      },
      { file = b, title = 'two', panel = 'plain' },
    },
  }
end
local function open()
  w.discard() -- a fresh review: nothing saved comes back
  w.close()
  vim.cmd('silent! %bwipeout!')
  reset_log()
  sent = {}
  vim.fn.writefile(lines(20), a)
  assert(send('load', tour()) == 'ok')
  vim.cmd('edit! ' .. vim.fn.fnameescape(a))
end
local function code_win()
  return st.code_win
end
local function at(line)
  vim.api.nvim_set_current_win(code_win())
  vim.api.nvim_win_set_cursor(0, { line, 0 })
end
local function comments()
  return st.history[1].comments or {}
end
local function virt(pattern)
  return H.marks(function(d)
    return d.virt_lines ~= nil and d.virt_lines[1] ~= nil and d.virt_lines[1][1][1]:match(pattern) ~= nil
  end, vim.fn.bufnr(a))
end
local function panel_line_of(pattern)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(st.panel_buf, 0, -1, false)) do
    if l:match(pattern) then
      return i
    end
  end
end
local function in_panel(line)
  vim.api.nvim_set_current_win(st.panel_win)
  vim.api.nvim_win_set_cursor(st.panel_win, { line, 0 })
end

open()

-- Comments: add -----------------------------------------------------------------------
at(3)
w.comment('question', 'why this?')
local c = comments()[1]
check('comment: stored on the cursor line', c and c.id == 'c1' and c.from == 3 and c.to == 3 and c.type == 'question'
  and c.text == 'why this?', vim.inspect(comments()))
check('comment: shown under its line', virt('^» c1 question: why this%?$') == 1)
check('comment: shown in the panel', H.panel_text():match('## Your comments') and H.panel_text():match('### %(c1%) line 3 · question\nwhy this%?'),
  H.panel_text())
check('comment: the marks sit under line 3', #H.marks_at(3, vim.fn.bufnr(a)) > 0)

-- The user is asked when there is no text; an empty answer cancels.
answer = 'asked text'
at(4)
w.comment('issue')
check('comment: without text the user is asked', #comments() == 2 and comments()[2].text == 'asked text' and comments()[2].type == 'issue'
  and comments()[2].from == 4, vim.inspect(comments()))
answer = '   '
w.comment('question')
check('comment: an empty answer cancels', #comments() == 2)
answer = nil
w.comment('question')
check('comment: no answer (escape) cancels', #comments() == 2)
w.comment_delete()
check('comment delete: the comment under the cursor goes', #comments() == 1 and comments()[1].id == 'c1')

-- Visual mode, through the real mapping.
answer = 'about these'
at(10)
vim.api.nvim_feedkeys(vim.keycode('Vj<Plug>(walkthrough-comment)'), 'x', false)
local v = comments()[2]
check('comment: visual selection covers its lines', v and v.from == 10 and v.to == 11 and v.type == 'question' and v.text == 'about these'
  and v.id == 'c3', vim.inspect(comments()))
check('comment: visual mode ended', vim.fn.mode() == 'n')
check('comment: ids are never reused after a delete', v and v.id == 'c3')
check('comment: shown under the last selected line', #H.marks_at(11, vim.fn.bufnr(a)) > 0)
check('comment: panel heading names the range', H.panel_text():match('### %(c3%) line 10%-11 · question') ~= nil, H.panel_text())

-- By command range.
answer = nil
vim.cmd('normal! 17GVj\27')
vim.cmd("'<,'>Walkthrough comment suggestion use a loop")
local r = comments()[3]
check('comment: command range with type and text', r and r.from == 17 and r.to == 18 and r.type == 'suggestion'
  and r.text == 'use a loop', vim.inspect(comments()))
vim.cmd('Walkthrough comment what about this')
check(':Walkthrough comment without a type is a question', comments()[4] and comments()[4].type == 'question'
  and comments()[4].text == 'what about this' and comments()[4].from == vim.api.nvim_win_get_cursor(0)[1], vim.inspect(comments()))
w.comment('nonsense', 'x')
check('comment: an unknown type is refused', #comments() == 4 and find('must be question, issue or suggestion') ~= nil)
vim.api.nvim_set_current_win(st.panel_win)
reset_log()
w.comment('question', 'from the panel')
check('comment: only in the code window on the step\'s file', #comments() == 4 and find('not the current step') ~= nil)
vim.api.nvim_set_current_win(code_win())

-- Delete through the panel heading.
in_panel(panel_line_of('^### %(c3%)'))
w.comment_delete()
check('comment delete: on the panel heading', #comments() == 3 and not comments()[2].id:match('^c3$'), vim.inspect(comments()))
check('comment delete: its marks are gone', virt('^» c3 ') == 0 and H.panel_text():match('%(c3%)') == nil)
at(1)
reset_log()
w.comment_delete()
check('comment delete: nothing under the cursor says so', find('no comment here') ~= nil and #comments() == 3)

-- Comments follow edits -------------------------------------------------------------------
-- (c1 line 3, c4 = comments()[3]... find them by id.)
local function by_id(id)
  for _, x in ipairs(comments()) do
    if x.id == id then
      return x
    end
  end
end
local new = lines(20)
table.insert(new, 1, 'top1')
table.insert(new, 1, 'top2')
vim.fn.writefile(new, a)
local s = status()
check('comment anchored: two lines inserted above move it down', by_id('c1').from == 5 and by_id('c1').to == 5
  and not by_id('c1').stale, vim.inspect(comments()))
check('comment anchored: a range moves as a whole', by_id('c4').from == 19 and by_id('c4').to == 20, vim.inspect(comments()))
vim.cmd('edit!')
check('comment anchored: and is drawn there', #H.marks_at(5, vim.fn.bufnr(a)) > 0 and virt('^» c1 ') == 1)
-- Rewrite the commented line: stale.
new[5] = 'rewritten'
vim.fn.writefile(new, a)
status()
check('comment stale: the commented line was rewritten', by_id('c1').stale == true, vim.inspect(by_id('c1')))
vim.cmd('edit!')
w.step(0)
check('comment stale: ... and says so on screen and in the panel', virt('^» c1 question: why this%? %(code changed%)$') == 1 and H.panel_text():match('### %(c1%) line 5 · question %(code changed%)'),
  H.panel_text())
-- Deleted code is stale as well.
local gone = vim.deepcopy(new)
table.remove(gone, 19)
table.remove(gone, 19)
vim.fn.writefile(gone, a)
status()
check('comment stale: a deleted range is stale too', by_id('c4').stale == true and by_id('c5').stale == true, vim.inspect(comments()))
vim.fn.writefile(new, a)
vim.cmd('edit!')
open()

-- Patches: answers -----------------------------------------------------------------------------
at(3)
w.comment('question', 'why this?')
at(9)
w.comment('issue', 'bug here')
check('answer: c1 and c2 exist', #comments() == 2)
check('answer: patch with step', send('patch', { step = 1, comment = 'c1', answer = 'because' }) == 'ok'
  and comments()[1].answer == 'because')
check('answer: shown as a second line and in the panel', H.marks(function(d)
  return d.virt_lines and d.virt_lines[2] and d.virt_lines[2][1][1]:match('↳ because') ~= nil
end, vim.fn.bufnr(a)) == 1 and H.panel_text():match('↳ because') ~= nil)
check('answer: patch without step searches the tour', send('patch', { comment = 'c2', answer = { 'one', 'two' }, resolved = true }) == 'ok'
  and comments()[2].resolved == true and comments()[2].answer[2] == 'two', vim.inspect(comments()))
check('answer: resolved comments are dimmed', H.marks(function(d)
  return d.virt_lines and d.virt_lines[1][1][2] == 'WalkthroughCommentResolved'
end, vim.fn.bufnr(a)) == 1 and H.panel_text():match('### %(c2%) line 9 · issue · resolved') ~= nil, H.panel_text())
check('answer: a patch can reopen', send('patch', { comment = 'c2', resolved = false }) == 'ok' and comments()[2].resolved == false)
check('answer: wrong step', send('patch', { step = 2, comment = 'c1', answer = 'x' }):match('^error: patch 1: there is no comment c1 in step 2$') ~= nil)
check('answer: unknown comment', send('patch', { comment = 'c9', answer = 'x' }):match('^error: patch 1: there is no comment c9$') ~= nil)

-- The agent cannot create, delete, re-type or edit them.
local before = vim.deepcopy(comments())
for name, p in pairs({
  new = { comment = 'c9', text = 'x', from = 1, to = 1 },
  delete = { comment = 'c1', remove = true },
  retype = { comment = 'c1', type = 'issue' },
  retext = { comment = 'c1', text = 'x' },
  move = { comment = 'c1', from = 2 },
  sent = { comment = 'c1', sent = false },
  both = { comment = 'c1', note = 1, answer = 'x' },
  bad_answer = { comment = 'c1', answer = 5 },
  bad_resolved = { comment = 'c1', resolved = 'yes' },
}) do
  local res = send('patch', p)
  check('agent: ' .. name .. ' is refused', res:match('^error: ') ~= nil and not res:match('\n') and vim.deep_equal(comments(), before), res)
end
check('agent: "comments" is not a step field', send('patch', { comments = { { id = 'c7', from = 1, to = 1, type = 'question', text = 'x' } } })
  :match('unknown step field "comments"') ~= nil)
check('agent: JSON cannot carry comments either', send('load', { steps = { { file = a, comments = {} } } }):match('unknown step field "comments"') ~= nil)
check('agent: a failed list changes nothing', send('patch', { { comment = 'c1', answer = 'changed' }, { comment = 'c9', answer = 'x' } }):match('^error:') ~= nil
  and comments()[1].answer == 'because')

-- Decisions --------------------------------------------------------------------------------------
at(6)
w.decide('accept')
local note = st.history[1].notes[1]
check('decide: stored on the note under the cursor', note.decision == 'accept' and st.history[1].notes[2].decision == nil)
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
check('decide: panel heading carries verdict, evidence and decision', H.panel_text():match('### %[1%] line 6 · simplify · read · ✓ accepted') ~= nil,
  H.panel_text())
w.decide('reject')
check('decide: reject replaces it', note.decision == 'reject'
  and H.panel_text():match('✗ rejected') ~= nil)
w.decide(nil)
check('decide: nil clears it', st.history[1].notes[1].decision == nil and H.panel_text():match('rejected') == nil)
w.decide('accept')
w.decide('clear')
check('decide: "clear" clears it too', st.history[1].notes[1].decision == nil)
reset_log()
w.decide('maybe')
check('decide: other values are refused', find('accept, reject or clear') ~= nil and st.history[1].notes[1].decision == nil)
at(1)
reset_log()
w.decide('accept')
check('decide: no note on the line', find('no note here') ~= nil)
-- From the panel heading.
in_panel(panel_line_of('^### %[2%]'))
vim.cmd('Walkthrough decide reject')
check('decide: on the note\'s panel heading', st.history[1].notes[2].decision == 'reject')
check('decide: the agent cannot set it (patch)', send('patch', { note = 1, decision = 'accept' }):match('unknown note field "decision"') ~= nil)
check('decide: ... nor with a replaced list of notes', send('patch', { notes = { { line = 3, text = 'x', decision = 'accept' } } })
  :match('unknown note field "decision"') ~= nil)
check('decide: ... nor from JSON', send('load', { steps = { { file = a, notes = { { line = 3, decision = 'accept' } } } } })
  :match('unknown note field "decision"') ~= nil)
at(6)
w.decide('accept')

-- Evidence ---------------------------------------------------------------------------------------
check('evidence: validated', send('load', { file = a, notes = { { line = 1, text = 'x', evidence = 'guess' } } })
  :match('^error: note 1: "evidence" must be one of opinion, ran, read$') ~= nil)
check('evidence: patch', send('patch', { note = 2, evidence = 'ran' }) == 'ok' and st.history[1].notes[2].evidence == 'ran')
check('evidence: heading', H.panel_text():match('### %[2%] line 12 · remove · ran') ~= nil, H.panel_text())
check('evidence: dim label after the verdict badge', H.marks(function(d)
  if not (d.virt_text and #d.virt_text >= 3) then
    return false
  end
  local last = d.virt_text[#d.virt_text]
  return last[1] == ' ran' and last[2] == 'WalkthroughEvidence'
end, vim.fn.bufnr(a)) == 1)
check('evidence: the other values', send('patch', { note = 3, evidence = 'opinion' }) == 'ok' and H.panel_text():match('keep · opinion') ~= nil)

-- send() -----------------------------------------------------------------------------------------
-- State: c1 (answered), c2 (resolved); add one more comment, decisions on
-- notes 1 (accept) and 2 (reject).
at(14)
w.comment('suggestion', 'rename it')
send('patch', { comment = 'c2', resolved = true })
sent = {}
w.send()
check('send: one message', #sent == 1, #sent)
local msg = sent[1]
check('send: numbered items with path:line', msg and msg.text:match('\n1%. Comment c1 %(question%) at a%.txt:3, step 1') ~= nil
  and msg.text:match('\n2%. Comment c3 %(suggestion%) at a%.txt:14, step 1') ~= nil, msg and msg.text)
check('send: ... first line of the code and the user\'s text', msg.text:match('Code: `l3`') and msg.text:match('User: why this%?')
  and msg.text:match('Code: `l14`') and msg.text:match('User: rename it'), msg.text)
check('send: resolved comments are not sent', not msg.text:match('c2'))
check('send: decision with what is expected', msg.text:match('Decision on note %[1%] at a%.txt:6, step 1, your verdict: simplify')
  and msg.text:match('accepted your verdict') and msg.text:match('{ "step": 1, "note": 1, "verdict": "done" }'), msg.text)
check('send: rejected decision says to leave the code', msg.text:match('note %[2%] at a%.txt:12') and msg.text:match('rejected your verdict')
  and msg.text:match('Leave the code as it is and acknowledge'), msg.text)
check('send: a question is answered with a comment patch', msg.text:match('{ "comment": "c1", "answer": "..." }') ~= nil)
check('send: references for the senders', #msg.refs == 4 and msg.refs[1].file == a and msg.refs[1].from == 3 and msg.refs[1].to == 3
  and msg.refs[2].from == 14 and msg.refs[3].from == 6 and msg.refs[4].from == 12, vim.inspect(msg.refs))
check('send: items are marked sent', comments()[1].sent and comments()[3].sent and st.history[1].notes[1].decision_sent
  and st.history[1].notes[2].decision_sent, vim.inspect(comments()))
reset_log()
w.send()
check('send: with nothing left it says so', #sent == 1 and find('nothing to send') ~= nil)
-- A decision that changed is sent again; a failing sender marks nothing.
at(6)
w.decide('reject')
st.config.sender = function()
  error('terminal is gone', 0)
end
reset_log()
w.send()
check('send: a raising sender marks nothing sent', st.history[1].notes[1].decision_sent == nil and find('terminal is gone') ~= nil
  and find('sent 1') == nil, vim.inspect(log))
st.config.sender = function(m)
  table.insert(sent, m)
end
w.send()
check('send: ... and it goes out on the next try', #sent == 2 and st.history[1].notes[1].decision_sent == true
  and sent[2].text:match('rejected your verdict') ~= nil)
check('send: the message mentions the group', sent[2].text:match('group "A"') ~= nil)

-- inbox ------------------------------------------------------------------------------------------
at(16)
w.comment('issue', 'check this')
w.decide('accept') -- no note on line 16: nothing happens
at(15)
w.decide('accept')
local res = w.inbox()
local inbox = vim.json.decode(res)
check('inbox: group and items', inbox.group == 'A' and #inbox.items == 2, res)
local ic, idc = inbox.items[1], inbox.items[2]
check('inbox: comment item shape', ic.kind == 'comment' and ic.id == 'c4' and ic.type == 'issue' and ic.step == 1 and ic.file == a
  and ic.from == 16 and ic.to == 16 and ic.text == 'check this', res)
check('inbox: decision item shape', idc.kind == 'decision' and idc.step == 1 and idc.note == 3 and idc.verdict == 'keep'
  and idc.decision == 'accept' and idc.file == a and idc.line == 15 and idc.text == 'fifteen', res)
check('inbox: marks them sent', comments()[4].sent == true and st.history[1].notes[3].decision_sent == true
  and #vim.json.decode(w.inbox()).items == 0)
check('inbox: nothing left is an empty list', w.inbox():match('"items":%[%]') ~= nil and vim.json.decode(w.inbox()).group == 'A', w.inbox())
local all = vim.json.decode(w.inbox(true))
local ids = vim.tbl_map(function(i) return i.id end, all.items)
check('inbox(all): sent comments that are not resolved', vim.deep_equal(ids, { 'c1', 'c3', 'c4' }), vim.inspect(ids))
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
open()

-- explain ----------------------------------------------------------------------------------------
at(6)
w.explain('simpler')
local ex = sent[1]
check('explain: a request for the note under the cursor', ex and ex.text:match('explain this simpler') and ex.text:match('Target: note %[1%] at a%.txt:6, verdict: simplify')
  and ex.text:match('Current explanation:\nwhy six') and ex.text:match('{ "step": 1, "note": 1, "detail": "<the new explanation>" }')
  and ex.text:match('keeping the same step and note numbers'), ex and ex.text)
check('explain: simpler means plainer words and an example', ex.text:match('plainer words; name each concept and say what it does; give one concrete example from this code'))
check('explain: references the note', ex.refs[1].file == a and ex.refs[1].from == 6 and ex.refs[1].to == 6)
check('explain: status reports the depth', status().depth == 'simpler')
at(2)
w.explain('deeper')
ex = sent[2]
check('explain: without a note the whole step', ex.text:match('Target: the explanation of the whole step') and ex.text:match('Current explanation:\n# One')
  and ex.text:match('{ "step": 1, "panel": "<the new explanation>" }') and ex.text:match('why it is built this way'), ex.text)
check('explain: ... referencing the focus', ex.refs[1].from == 5 and ex.refs[1].to == 8)
check('explain: the opposite level switches the depth', status().depth == 'deeper')
check('explain: the depth is on the tour and saved', st.tours[1].depth == 'deeper')
-- From the panel heading.
in_panel(panel_line_of('^### %[2%]'))
w.explain('simpler')
check('explain: on a panel heading it is that note', sent[3].text:match('Target: note %[2%] at a%.txt:12') ~= nil and status().depth == 'simpler')
-- Panel keys.
in_panel(1)
vim.api.nvim_feedkeys('+', 'x', false)
check('explain: panel key +', status().depth == 'deeper' and #sent == 4)
vim.api.nvim_feedkeys('-', 'x', false)
check('explain: panel key -', status().depth == 'simpler' and #sent == 5)
vim.api.nvim_feedkeys('=', 'x', false)
check('explain: panel key =', status().depth == 'deeper' and #sent == 6)
vim.cmd('Walkthrough explain simpler')
check(':Walkthrough explain simpler', status().depth == 'simpler' and #sent == 7)
reset_log()
vim.cmd('Walkthrough explain louder')
check(':Walkthrough explain: bad level', find('explain takes simpler or deeper') ~= nil and #sent == 7)
check('explain: hints name the keys', H.panel_winbar():match('%- simpler') and H.panel_winbar():match('%+ deeper'), H.panel_winbar())
-- A failing sender leaves the depth alone.
st.config.sender = function()
  error('nobody listens', 0)
end
reset_log()
w.explain('deeper')
check('explain: a failing sender does not change the depth', status().depth == 'simpler' and find('nobody listens') ~= nil)
st.config.sender = function(m)
  table.insert(sent, m)
end
check('explain: no depth before any request', (function()
  open()
  return status().depth == nil
end)())

-- Checks -------------------------------------------------------------------------------------------
local function stepinfo()
  return status()
end
check('check: open at first', stepinfo().check == 'open')
check('check: the question is in the panel, the answer is not', H.panel_text():match('## Check\nWhat is l5%?') ~= nil
  and not H.panel_text():match('SECRET%-ANSWER'), H.panel_text())
check('check: the hints name r and e', H.panel_winbar():match('r reveal') and H.panel_winbar():match('e answer'), H.panel_winbar())
check('check: r and e are mapped in the panel', (function()
  local keys = {}
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(st.panel_buf, 'n')) do
    keys[m.lhs] = true
  end
  return keys.r and keys.e
end)())
check('check: counts in the groups', vim.deep_equal(status().groups[1].checks, { total = 1, answered = 0, revealed = 0 }), vim.inspect(status().groups))
in_panel(1)
vim.api.nvim_feedkeys('r', 'x', false)
check('check: r reveals the answer', H.panel_text():match('### Answer\nSECRET%-ANSWER') ~= nil and stepinfo().check == 'revealed'
  and st.history[1].check.revealed == true, H.panel_text())
check('check: counts follow', status().groups[1].checks.revealed == 1 and status().groups[1].checks.answered == 0)
-- Own answer first.
answer = 'my own idea'
vim.api.nvim_feedkeys('e', 'x', false)
check('check: e stores the reply and shows it', st.history[1].check.reply == 'my own idea' and H.panel_text():match('### Your answer\nmy own idea') ~= nil)
check('check: answered wins over revealed', stepinfo().check == 'answered'
  and vim.deep_equal(status().groups[1].checks, { total = 1, answered = 1, revealed = 1 }), vim.inspect(status()))
answer = ''
w.check('answer')
check('check: an empty answer cancels', st.history[1].check.reply == 'my own idea')
-- The reply goes out with send and inbox.
sent = {}
w.send()
check('check: the reply is sent with the other items', #sent == 1 and sent[1].text:match('Answer to the check of step 1') and sent[1].text:match('Question: What is l5%?')
  and sent[1].text:match('User: my own idea') and sent[1].text:match('"feedback": "..."'), sent[1] and sent[1].text)
check('check: ... and marked sent', st.history[1].check.reply_sent == true and #sent == 1)
-- Feedback from the agent.
check('check: patch with feedback', send('patch', { step = 1, check = { question = 'What is l5?', answer = 'SECRET-ANSWER', feedback = 'Close enough.' } }) == 'ok')
check('check: the reply, the reveal and the sent flag survive an unchanged question', st.history[1].check.reply == 'my own idea'
  and st.history[1].check.revealed == true and st.history[1].check.reply_sent == true)
check('check: feedback is shown under the reply', H.panel_text():match('### Your answer\nmy own idea\n\n### Feedback\nClose enough%.') ~= nil, H.panel_text())
check('check: the agent cannot fake a reply', send('patch', { check = { question = 'What is l5?', reply = 'x' } }):match('unknown check field "reply"') ~= nil)
check('check: ... or from JSON', send('load', { steps = { { file = a, check = { question = 'q', revealed = true } } } }):match('unknown check field "revealed"') ~= nil)
-- Persistence while the question is the same.
w.close()
check('check: resume', w.resume() == 'ok')
check('check: state survives close and resume', st.history[1].check.reply == 'my own idea' and st.history[1].check.revealed == true
  and st.history[1].check.reply_sent == true and st.history[1].check.feedback == 'Close enough.')
-- A new question starts afresh.
check('check: patch with another question', send('patch', { step = 1, check = { question = 'What is l6?', answer = 'six' } }) == 'ok')
check('check: ... drops reply, reveal and sent flag', st.history[1].check.reply == nil and st.history[1].check.revealed == nil
  and st.history[1].check.reply_sent == nil and stepinfo().check == 'open', vim.inspect(st.history[1].check))
check('check: ... and the panel forgets them', not H.panel_text():match('my own idea') and not H.panel_text():match('Your answer')
  and not H.panel_text():match('### Answer') and not H.panel_text():match('Feedback'), H.panel_text())
-- Steps without a check.
w.step(1)
check('check: no check, no key hints', not H.panel_winbar():match('r reveal') and not H.panel_winbar():match('e answer'), H.panel_winbar())
check('check: ... no keys', (function()
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(st.panel_buf, 'n')) do
    if m.lhs == 'r' or m.lhs == 'e' then
      return false
    end
  end
  return true
end)())
check('check: ... no check field in status', stepinfo().check == nil)
reset_log()
w.check('reveal')
check('check: reveal on a step without one says so', find('this step has no check') ~= nil)
w.check('nonsense')
check('check: unknown action', find('check takes reveal or answer') ~= nil)
check('check: validation', send('load', { steps = { { file = a, check = { answer = 'x' } } } }):match('^error: step 1, check: "question" is missing$') ~= nil
  and send('load', { steps = { { file = a, check = { question = 5 } } } }):match('"question" must be a string or a list of strings') ~= nil
  and send('load', { steps = { { file = a, check = 'q' } } }):match('check: must be an object') ~= nil
  and send('load', { steps = { { file = a, check = { question = 'q', hint = 'x' } } } }):match('unknown check field "hint"') ~= nil)
-- A check without an answer cannot be revealed.
w.step(-1)
send('patch', { step = 1, check = { question = 'No answer?' } })
reset_log()
w.check('reveal')
check('check: nothing to reveal', find('no answer to reveal') ~= nil and not st.history[1].check.revealed)
vim.cmd('Walkthrough check bogus')
check(':Walkthrough check: bad action', find('check takes reveal or answer') ~= nil)

-- The mappings and commands ---------------------------------------------------------------------------
open()
at(7)
answer = 'by plug'
vim.api.nvim_feedkeys(vim.keycode('<Plug>(walkthrough-comment)'), 'x', false)
check('<Plug>(walkthrough-comment) in normal mode asks and adds', comments()[1] and comments()[1].text == 'by plug' and comments()[1].from == 7
  and comments()[1].type == 'question', vim.inspect(comments()))
vim.api.nvim_feedkeys(vim.keycode('<Plug>(walkthrough-send)'), 'x', false)
check('<Plug>(walkthrough-send) sends', #sent == 1 and sent[1].text:match('by plug') ~= nil)
vim.cmd('Walkthrough comment-delete')
check(':Walkthrough comment-delete', #comments() == 0)
vim.cmd('Walkthrough comment issue it hurts')
vim.cmd('Walkthrough send')
check(':Walkthrough comment and :Walkthrough send', #sent == 2 and sent[2].text:match('it hurts') ~= nil)

-- Persistence of everything --------------------------------------------------------------------------
open()
at(3)
w.comment('question', 'persist me')
at(9)
w.comment('issue', 'and me')
send('patch', { comment = 'c1', answer = 'answered', resolved = true })
at(6)
w.decide('reject')
w.explain('deeper')
answer = 'a reply'
w.check('answer')
w.send()
w.decide('accept') -- a changed decision is not sent yet
local snapshot = vim.deepcopy({ comments(), st.history[1].notes, st.history[1].check })
local counter = st.tours[1].next_comment
w.close()
check('persistence: the state file holds comments and the depth', (function()
  local data = vim.json.decode(table.concat(vim.fn.readfile(store.path(root)), '\n'))
  return data.tours[1].depth == 'deeper' and #data.tours[1].steps[1].comments == 2 and data.tours[1].next_comment == counter
end)())
check('persistence: resume', w.resume() == 'ok')
check('persistence: comments, decisions and check are back', vim.deep_equal({ comments(), st.history[1].notes, st.history[1].check }, snapshot),
  vim.inspect({ comments(), st.history[1].notes, st.history[1].check }))
check('persistence: depth is back', status().depth == 'deeper')
check('persistence: comments are drawn again', virt('^» c1 question: persist me$') == 1 and H.panel_text():match('%(c2%) line 9') ~= nil)
at(12)
w.comment('question', 'after resume')
check('persistence: ids go on counting', comments()[3] and comments()[3].id == 'c3')
w.comment_delete()
at(13)
w.comment('question', 'once more')
check('persistence: ... and a deleted id is not reused after a resume', comments()[3].id == 'c4')
-- A resend of the tour keeps what the user wrote.
w.close()
assert(w.resume() == 'ok')
assert(send('load', tour()) == 'ok')
check('persistence: a resent tour keeps comments, depth and counter', #comments() == 3 and st.tours[1].depth == 'deeper'
  and (st.tours[1].next_comment or 0) >= 5, vim.inspect(comments()))
w.close()
vim.cmd('silent! %bwipeout!')

H.finish()
