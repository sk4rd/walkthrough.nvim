-- Plan review: the agent's plan opens in a window of the current tab, next to
-- the agent's terminal, while a hook waits.
-- The hook script is tested in tests/scripts.sh; here the two socket entry
-- points it calls (plan, plan_result), the comments, feedback, approval,
-- revisions, persistence and the plan's isolation from the other actions, and
-- (at the end) which window the plan takes and what comes back afterwards.
-- The agent's channel is stubbed: nothing may go through it in a plan.
local H = require('helpers')
local check, send, w = H.check, H.send, H.w
local st = _G.walkthrough_state
local tours = require('walkthrough.tours')
local store = require('walkthrough.store')
local log, find = H.capture_notify()
local ns_threads = vim.api.nvim_get_namespaces().walkthrough_threads

local sent = {}
st.config.sender = function(msg)
  table.insert(sent, msg)
end
local answer, prompts = nil, {}
vim.ui.input = function(opts, cb)
  table.insert(prompts, opts.prompt)
  cb(answer)
end

local function reset_log()
  for i = #log, 1, -1 do
    log[i] = nil
  end
end
local function status()
  return vim.json.decode(w.status())
end
-- Whether a notification contains `text` (plain).
local function said(text)
  for _, n in ipairs(log) do
    if n.msg:find(text, 1, true) then
      return true
    end
  end
  return false
end
local function lines(n, prefix)
  local out = {}
  for i = 1, n do
    out[i] = (prefix or 'p') .. i
  end
  return out
end
local function text_of(list)
  return table.concat(list, '\n')
end

check('the state directory is the one run.sh made', st.config.state_dir == vim.env.WALKTHROUGH_STATE_DIR
  and not st.config.state_dir:find(H.work, 1, true), st.config.state_dir)
local plans_dir = st.config.state_dir .. '/plans'

-- What the hook sends (the fields the documentation lists).
local function input(session, plan_text)
  return {
    hook_event_name = 'PermissionRequest', tool_name = 'ExitPlanMode', session_id = session, cwd = H.work,
    tool_input = { plan = plan_text, planFilePath = '/home/u/.claude/plans/x.md' },
  }
end
local function open(session, plan_text)
  return send('plan', input(session, plan_text))
end
local function result(id)
  local res = w.plan_result(id)
  local ok, data = pcall(vim.json.decode, res)
  return ok and data or res
end
local function buf_text(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end
local function plan_of(id)
  for _, t in ipairs(tours.plans()) do
    if t.plan_id == id then
      return t
    end
  end
end
local function thread_of(id, tid)
  for _, th in ipairs(plan_of(id).steps[1].threads or {}) do
    if th.id == tid then
      return th
    end
  end
end
local function marks_text(buf)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns_threads, 0, -1, { details = true })) do
    for _, vl in ipairs(m[4].virt_lines or {}) do
      table.insert(out, H.vtext(vl))
    end
  end
  return table.concat(out, '\n')
end
local function marks_rows(buf)
  local rows = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns_threads, 0, -1, {})) do
    table.insert(rows, m[2] + 1)
  end
  table.sort(rows)
  return rows
end

-- A clean slate: every plan gone, with its files, and the state directory.
local function reset()
  for _, t in ipairs(tours.plans()) do
    pcall(w.plan_approve, t.plan_id)
  end
  w.close()
  st.tours, st.active, st.plan_results, st.plan_order, st.plan_counters = {}, 0, {}, {}, {}
  st.restored, st.dir_roots = {}, {}
  vim.cmd('silent! tabonly')
  vim.cmd('silent! only')
  vim.cmd('silent! %bwipeout!')
  assert(st.config.state_dir == vim.env.WALKTHROUGH_STATE_DIR)
  vim.fn.delete(st.config.state_dir, 'rf')
  sent, answer, prompts = {}, nil, {}
  reset_log()
end

-- Opening ----------------------------------------------------------------------------------

reset()
-- Two windows in the first tab; the plan takes the current one and leaves the
-- other alone.
vim.cmd('edit ' .. vim.fn.fnameescape(H.work .. '/f.txt'))
vim.cmd('vsplit ' .. vim.fn.fnameescape(H.work .. '/g.txt'))
local first_tab = vim.api.nvim_get_current_tabpage()
local first_win = vim.api.nvim_get_current_win()
local g_buf = vim.api.nvim_get_current_buf()
local other_win = vim.fn.win_getid(vim.fn.winnr('#'))
local other_buf = vim.api.nvim_win_get_buf(other_win)
local plan_text = text_of(lines(12))
local id = open('sess-1', plan_text)
check('plan answers with the session id and a counter', id == 'sess-1-1', id)
check('plan opens in the current tab and creates no tab', #vim.api.nvim_list_tabpages() == 1
  and vim.api.nvim_get_current_tabpage() == first_tab)
check('the plan takes the window that was current, in Normal mode', vim.api.nvim_get_current_win() == first_win
  and vim.api.nvim_win_get_buf(first_win) ~= g_buf and vim.fn.mode() == 'n')
check('the other window is not touched', vim.api.nvim_win_is_valid(other_win) and vim.api.nvim_win_get_buf(other_win) == other_buf
  and #vim.api.nvim_tabpage_list_wins(first_tab) == 2)
local plan_buf = vim.api.nvim_get_current_buf()
check('the plan is stored as a file named by the id', vim.api.nvim_buf_get_name(plan_buf) == plans_dir .. '/sess-1-1.md',
  vim.api.nvim_buf_get_name(plan_buf))
check('the file holds the plan text', vim.fn.readfile(plans_dir .. '/sess-1-1.md')[12] == 'p12'
  and #vim.fn.readfile(plans_dir .. '/sess-1-1.md') == 12)
check('the buffer shows the plan', vim.deep_equal(buf_text(plan_buf), lines(12)))
check('the buffer is markdown', vim.bo[plan_buf].filetype == 'markdown')
check('the buffer is read-only', vim.bo[plan_buf].modifiable == false and vim.bo[plan_buf].readonly == true)
check('typing into the plan fails', not pcall(vim.api.nvim_buf_set_lines, plan_buf, 0, 1, false, { 'x' }))
check('a notification says that a plan is waiting', find('plan is waiting') ~= nil)
check('the plan is no tour of the review', tours.count() == 0 and st.active == 0 and #tours.plans() == 1)
check('the plan tour is flagged and has one entry without a diff', tours.plans()[1].plan == true
  and #tours.plans()[1].steps == 1 and tours.plans()[1].steps[1].diff == false)
check('plan_id and session are kept on the tour', tours.plans()[1].plan_id == 'sess-1-1'
  and tours.plans()[1].plan_session == 'sess-1')
check('the winbar names approve and feedback', vim.wo[0].winbar:find('A approve', 1, true) ~= nil
  and vim.wo[0].winbar:find('F feedback', 1, true) ~= nil, vim.wo[0].winbar)
check('without mapped keys the winbar names the command that writes a comment', vim.wo[0].winbar:find(':Walkthrough ask to comment', 1, true) ~= nil
  and vim.wo[0].winbar:find('change', 1, true) == nil, vim.wo[0].winbar)
check('the winbar says that the plan waits for the user', vim.wo[0].winbar:find('waiting for you', 1, true) ~= nil)
check('the keys A and F are mapped in the buffer', vim.fn.maparg('A', 'n', false, true).buffer == 1
  and vim.fn.maparg('F', 'n', false, true).buffer == 1)

-- Errors never raise and open nothing.
local bad = { tour = vim.deepcopy(input('sess-x', 'text')) }
bad.tour.tool_name = 'Bash'
check('a hook input of another tool is an error', send('plan', bad.tour):match('^error: ') ~= nil, send('plan', bad.tour))
check('a hook input without plan text is an error', send('plan', input('sess-x', '  \n ')):match('^error: ') ~= nil)
check('a hook input without tool_input is an error', send('plan', { tool_name = 'ExitPlanMode' }):match('^error: ') ~= nil)
check('a file that is no JSON is an error', w.plan((function()
  local p = vim.fn.tempname()
  vim.fn.writefile({ '{nope' }, p)
  return p
end)()):match('^error: ') ~= nil)
check('a missing file is an error', w.plan('/no/such/file'):match('^error: ') ~= nil)
check('an error answer is one short line', not send('plan', bad.tour):find('\n'))
check('errors open no tab and no window', #vim.api.nvim_list_tabpages() == 1 and #vim.api.nvim_tabpage_list_wins(first_tab) == 2
  and #tours.plans() == 1)

-- A second session is a review of its own, shown in the same window.
local id2 = open('sess-2', 'one\ntwo')
check('another session gets its own review and the same window', id2 == 'sess-2-1' and #vim.api.nvim_list_tabpages() == 1
  and #vim.api.nvim_tabpage_list_wins(first_tab) == 2 and #tours.plans() == 2
  and vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(first_win)) == plans_dir .. '/sess-2-1.md')
check('the session id is made safe for a file name', open('a/b c:d', 'x') == 'a_b_c_d-1')
check('a plan text with carriage returns and a final newline is stored cleanly',
  vim.deep_equal(vim.fn.readfile(plans_dir .. '/a_b_c_d-1.md'), { 'x' }))
reset()

-- Commenting ------------------------------------------------------------------------------------

id = open('sess-1', plan_text)
plan_buf = vim.api.nvim_get_current_buf()
check('ask in a plan answers nothing at once', (w.ask('why twelve steps?', { 2, 2 }) or true) and #sent == 0)
local t1 = thread_of(id, 't1')
check('a comment on a plan is collected, as a draft', t1 and t1.kind == 'comment' and t1.state == 'draft'
  and t1.sent == 0 and t1.from == 2 and t1.to == 2)
check('change collects a comment too', (w.change('merge steps 3 and 4', { 3, 4 }) or true) and #sent == 0
  and thread_of(id, 't2').kind == 'comment' and thread_of(id, 't2').state == 'draft')
check('the notification names the comment and the key that sends it', said('comment t2 added (lines 3-4); F sends it'),
  vim.inspect(log))
check('both threads are drawn under their lines', vim.deep_equal(marks_rows(plan_buf), { 2, 4 }), vim.inspect(marks_rows(plan_buf)))
check('a drawn thread says that it is not sent', marks_text(plan_buf):find('not sent', 1, true) ~= nil)
reset_log()
w.send()
check('send is refused in a plan and points to feedback', find('plan feedback') ~= nil and #sent == 0
  and thread_of(id, 't1').state == 'draft', vim.inspect(log))
check('inbox does not list the plan', vim.json.decode(w.inbox()).items[1] == nil)
check('inbox with all does not list the plan either', vim.json.decode(w.inbox(true)).items[1] == nil)
w.ask('and the order?', { 2, 2 })
check('a second ask on the same lines replies in the thread', #thread_of(id, 't1').messages == 2
  and thread_of(id, 't3') == nil and #sent == 0)
check('status counts the plan threads', status().plan.threads == 2 and status().plan.id == id
  and status().plan.state == 'pending', w.status())
check('status lists the plan in no group', status().groups == nil and status().step == 0)
-- A thread by prompt, with the range of a visual selection.
answer = 'is this safe?'
vim.api.nvim_win_set_cursor(0, { 8, 0 })
w.ask()
check('ask prompts when it has no text', thread_of(id, 't3') and thread_of(id, 't3').from == 8
  and thread_of(id, 't3').messages[1].text == 'is this safe?' and #sent == 0)
w.thread_delete()
check('a thread of the plan can be deleted', thread_of(id, 't3') == nil)
reset_log()
vim.api.nvim_win_set_cursor(0, { 2, 0 })
w.decide('accept')
check('a decision is refused in a plan', find('no proposals') ~= nil and #sent == 0)
reset_log()
w.explain('simpler')
check('explain is refused in a plan', find('no answers to explain') ~= nil and #sent == 0)

-- Feedback ---------------------------------------------------------------------------------------

w.change('rewrite all of this', { 6, 12 })
local ok_fb = pcall(w.plan_feedback)
check('plan_feedback does not raise', ok_fb)
check('the plan stays on screen', #vim.api.nvim_list_tabpages() == 1 and vim.api.nvim_buf_is_valid(plan_buf)
  and vim.api.nvim_win_get_buf(0) == plan_buf)
check('the winbar says that the feedback was sent', vim.wo[0].winbar:find('feedback sent; waiting for the revised plan', 1, true) ~= nil,
  vim.wo[0].winbar)
check('status says feedback-sent', status().plan.state == 'feedback-sent')
local r = result(id)
check('plan_result hands the feedback out', r.state == 'feedback' and type(r.message) == 'string', vim.inspect(r))
local msg = r.message
check('the message counts the comments', msg:find('(3 comments)', 1, true) ~= nil, msg)
check('the message numbers each comment with its thread and lines',
  msg:find('1. Comment t1 on plan line 2:', 1, true) ~= nil
  and msg:find('2. Comment t2 on plan lines 3-4:', 1, true) ~= nil
  and msg:find('3. Comment t4 on plan lines 6-12:', 1, true) ~= nil, msg)
check('the plan lines are quoted', msg:find('   > p2\n', 1, true) ~= nil and msg:find('   > p3\n   > p4\n', 1, true) ~= nil)
check('both messages of a thread are given', msg:find('User: why twelve steps?', 1, true) ~= nil
  and msg:find('User: and the order?', 1, true) ~= nil)
check('the text of the second comment is given', msg:find('User: merge steps 3 and 4', 1, true) ~= nil)
local quoted = 0
for l in vim.gsplit(msg:match('3%. Comment.-\n\n') or '', '\n') do
  if l:match('^   > ') then
    quoted = quoted + 1
  end
end
check('at most five lines are quoted', quoted == 5, quoted)
check('the rest is counted', msg:find('(2 more lines)', 1, true) ~= nil, msg)
check('the message ends with what the agent should do',
  msg:match('Reply to every comment with a patch { "thread": "<id>", "answer": "..." } %(tour.sh %-%-patch%), '
    .. 'and revise the plan where a comment asks for a change or shows that one is needed, '
    .. 'before presenting the plan again%.$') ~= nil, msg)
check('the message has no word of a question or a change request', not msg:lower():find('question', 1, true)
  and not msg:lower():find('change request', 1, true), msg)
check('the feedback goes out once', result(id).state == 'pending' and result(id).state == 'pending')
check('the threads count as delivered', thread_of(id, 't1').state == 'waiting' and thread_of(id, 't1').sent == 2
  and thread_of(id, 't2').state == 'waiting')
check('nothing went through the sender', #sent == 0)
check('plan_result of an unknown review is an error', w.plan_result('nope'):match('^error: unknown plan review nope') ~= nil,
  w.plan_result('nope'))
check('a plan_result error is one line', not w.plan_result('no\npe'):find('\n', 8))
check('the threads show as waiting', marks_text(plan_buf):find('waiting', 1, true) ~= nil)

-- Nothing new to say: asks what should change; an empty answer cancels.
reset_log()
prompts, answer = {}, ''
w.plan_feedback()
check('a second feedback with nothing new asks what should change', #prompts == 1 and prompts[1] == 'What should change? ')
check('an empty answer sends nothing', result(id).state == 'pending' and find('no feedback sent') ~= nil)
answer = 'please add a rollback step\nand a test plan'
w.plan_feedback()
r = result(id)
check('free text becomes the feedback', r.state == 'feedback' and r.message:find('please add a rollback step', 1, true) ~= nil
  and r.message:find('feedback from the user on your plan', 1, true) ~= nil, vim.inspect(r))
check('a multi-line free text stays together', r.message:find('and a test plan', 1, true) ~= nil)
check('free text leaves the threads alone', thread_of(id, 't1').state == 'waiting')
-- A message written between the feedback and its pick-up stays a draft.
w.ask('one more thing', { 2, 2 })
w.plan_feedback()
w.ask('too late', { 2, 2 })
check('a late message is collected', thread_of(id, 't1').state == 'draft' and #thread_of(id, 't1').messages == 4)
r = result(id)
check('only what was in the feedback counts as delivered', r.state == 'feedback' and thread_of(id, 't1').state == 'draft'
  and thread_of(id, 't1').sent == 3, thread_of(id, 't1').sent)
w.plan_feedback()
w.plan_feedback()
r = result(id)
check('feedback twice before the pick-up sends the comments once', r.state == 'feedback'
  and select(2, r.message:gsub('User: too late', '')) == 1 and result(id).state == 'pending', r.message)
answer = 'free text, queued'
w.plan_feedback()
reset_log()
w.plan_feedback()
check('a free-text feedback not yet taken says it is on its way', find('on its way') ~= nil)
check('and the queued text is still the one handed out', result(id).message:find('free text, queued', 1, true) ~= nil)
answer = nil

-- A revision --------------------------------------------------------------------------------------------

-- The agent answers (the plan keeps its threads), then shows a changed plan.
check('the agent answers a thread of the plan', send('patch', { thread = 't1', answer = 'twelve, because of the order' }) == 'ok')
check('the answer is drawn in the plan', marks_text(plan_buf):find('twelve, because of the order', 1, true) ~= nil)
check('the thread is answered', thread_of(id, 't1').state == 'answered')
check('a thread patch needs no step', send('patch', { thread = 't2', answer = 'merged', proposal = true }) == 'ok')
local revised = lines(12)
table.insert(revised, 1, 'new first line')
revised[4] = 'p3 rewritten' -- was line 3 (the first of t2's lines)
reset_log()
local wins = vim.api.nvim_list_wins()
check('a second call of the same session answers the same id', open('sess-1', text_of(revised)) == id)
check('the revision opens no new tab and no window', #vim.api.nvim_list_tabpages() == 1 and #tours.plans() == 1
  and vim.deep_equal(vim.api.nvim_list_wins(), wins))
check('the revision is current again', vim.api.nvim_get_current_buf() == plan_buf)
check('the revised text is in the buffer and the file', vim.deep_equal(buf_text(plan_buf), revised)
  and vim.deep_equal(vim.fn.readfile(plans_dir .. '/sess-1-1.md'), revised))
check('the buffer stays unmodified and read-only', vim.bo[plan_buf].modified == false and vim.bo[plan_buf].modifiable == false)
check('the threads were kept', #plan_of(id).steps[1].threads == 3, #plan_of(id).steps[1].threads)
check('a thread moved along with its line', thread_of(id, 't1').from == 3 and thread_of(id, 't1').to == 3
  and not thread_of(id, 't1').stale, vim.inspect(thread_of(id, 't1')))
check('a thread on rewritten lines is stale', thread_of(id, 't2').stale == true and thread_of(id, 't2').from == 4,
  vim.inspect(thread_of(id, 't2')))
check('an untouched thread below moved too', thread_of(id, 't4').from == 7 and thread_of(id, 't4').to == 13
  and not thread_of(id, 't4').stale)
check('the threads are drawn at their new lines', vim.deep_equal(marks_rows(plan_buf), { 3, 5, 13 }), vim.inspect(marks_rows(plan_buf)))
check('the agent\'s answer is still drawn after the revision', marks_text(plan_buf):find('twelve, because of the order', 1, true) ~= nil)
check('the state is pending again', status().plan.state == 'pending' and result(id).state == 'pending')
check('the winbar says that the plan waits for the user again', vim.wo[0].winbar:find('waiting for you', 1, true) ~= nil)
check('the revision is announced', find('plan was revised') ~= nil)
-- The stale flag reaches the agent.
w.ask('and the new first line?', { 1, 1 })
w.plan_feedback()
msg = result(id).message
check('the next feedback has only what is new', msg:find('(1 comment)', 1, true) ~= nil and msg:find('and the new first line?', 1, true) ~= nil
  and not msg:find('why twelve', 1, true), msg)
w.change('again', { 4, 4 })
w.plan_feedback()
msg = result(id).message
check('a comment on rewritten text says so', msg:find('was changed after this was written', 1, true) ~= nil
  or msg:find('Comment t2', 1, true) == nil, msg)
check('an earlier answer of the agent is part of the thread', msg:find('Earlier in this thread:', 1, true) ~= nil
  and msg:find('You (agent): merged', 1, true) ~= nil, msg)
reset()

-- Approving -------------------------------------------------------------------------------------------

local home = vim.api.nvim_get_current_tabpage()
vim.cmd('edit ' .. vim.fn.fnameescape(H.work .. '/f.txt'))
local home_win, home_buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
id = open('sess-1', plan_text)
plan_buf = vim.api.nvim_get_current_buf()
reset_log()
w.plan_approve()
check('approve gives the window its buffer back', #vim.api.nvim_list_tabpages() == 1 and vim.api.nvim_get_current_tabpage() == home
  and #vim.api.nvim_tabpage_list_wins(home) == 1 and vim.api.nvim_get_current_win() == home_win
  and vim.api.nvim_win_get_buf(home_win) == home_buf)
check('approve deletes the buffer and the file', not vim.api.nvim_buf_is_valid(plan_buf)
  and vim.fn.filereadable(plans_dir .. '/sess-1-1.md') == 0)
check('approve deletes the plan tour', #tours.plans() == 0 and status().plan == nil and status().step == 0)
check('plan_result answers approve', result(id).state == 'approve' and result(id).state == 'approve')
check('approve with nothing open says only that', find('plan approved') ~= nil and not find('dropped'), vim.inspect(log))
check('the state file of the plan is gone', #vim.fn.glob(st.config.state_dir .. '/*.json', false, true) == 0)

id = open('sess-1', plan_text)
check('a new plan of the session gets the next number', id == 'sess-1-2', id)
check('the old approval is not mistaken for the new plan', result(id).state == 'pending' and result('sess-1-1').state == 'approve')
w.ask('q1', { 1, 1 })
w.change('c1', { 2, 2 })
reset_log()
w.plan_approve()
check('approve with comments drops them and says how many', find('plan approved; dropped 2 comments that were still open') ~= nil,
  vim.inspect(log))
check('the state file is gone after dropping them', #vim.fn.glob(st.config.state_dir .. '/*.json', false, true) == 0)
reset_log()
w.plan_approve()
check('approve with no plan says so', find('no plan is waiting for review') ~= nil)
w.plan_feedback()
check('feedback with no plan says so', find('no plan is waiting for review') ~= nil)

-- The commands ---------------------------------------------------------------------------------------

id = open('sess-1', plan_text)
plan_buf = vim.api.nvim_get_current_buf()
vim.cmd('vsplit ' .. vim.fn.fnameescape(H.work .. '/g.txt'))
local file_win = vim.api.nvim_get_current_win()
local plan_win = vim.fn.win_findbuf(plan_buf)[1]
vim.api.nvim_win_close(plan_win, true)
check('closing the plan window leaves the plan pending', #tours.plans() == 1 and result(id).state == 'pending'
  and #vim.api.nvim_list_tabpages() == 1 and vim.api.nvim_buf_is_valid(plan_buf))
vim.cmd('Walkthrough plan')
check(':Walkthrough plan shows the closed plan again, in the current tab', #vim.api.nvim_list_tabpages() == 1
  and vim.api.nvim_buf_get_name(0) == plans_dir .. '/' .. id .. '.md', #vim.api.nvim_list_tabpages() .. ' ' .. vim.api.nvim_buf_get_name(0))
check('the shown plan has its keys and bar', vim.fn.maparg('A', 'n', false, true).buffer == 1
  and vim.wo[0].winbar:find('A approve', 1, true) ~= nil)
local reopened = vim.api.nvim_get_current_win()
check('... in the window that was left, without a new one', reopened == file_win and #vim.api.nvim_tabpage_list_wins(0) == 1)
vim.cmd('vsplit ' .. vim.fn.fnameescape(H.work .. '/g.txt'))
file_win = vim.api.nvim_get_current_win()
vim.cmd('Walkthrough plan')
check(':Walkthrough plan goes to the window that shows it', vim.api.nvim_get_current_win() == reopened
  and #vim.api.nvim_tabpage_list_wins(0) == 2 and #vim.fn.win_findbuf(plan_buf) == 1 and file_win ~= reopened)
vim.cmd('Walkthrough plan nonsense')
check('an unknown argument is reported', find('plan takes') ~= nil)
-- Approve and feedback work from outside the plan window when there is one plan.
vim.cmd('tabnew')
w.ask('from far', { 1, 1 })
check('ask outside the plan is no plan thread', #(plan_of(id).steps[1].threads or {}) == 0)
vim.cmd('Walkthrough plan feedback')
check(':Walkthrough plan feedback asks when there is nothing to send', #prompts >= 1)
answer = 'text from the command'
vim.cmd('Walkthrough plan feedback')
check(':Walkthrough plan feedback sends from outside the plan window', result(id).state == 'feedback')
vim.cmd('Walkthrough plan approve')
check(':Walkthrough plan approve approves', #tours.plans() == 0 and result(id).state == 'approve')
reset_log()
vim.cmd('Walkthrough plan')
check(':Walkthrough plan with none says so', find('no plan is waiting for review') ~= nil)
check('the completion offers approve and feedback', vim.deep_equal(vim.fn.getcompletion('Walkthrough plan ', 'cmdline'),
  { 'approve', 'feedback' }))
check('the <Plug> mappings exist', vim.fn.maparg('<Plug>(walkthrough-plan-feedback)', 'n') ~= ''
  and vim.fn.maparg('<Plug>(walkthrough-plan-approve)', 'n') ~= '')
local keys_mod = require('walkthrough.keys')
check('the cheat sheet lists both actions', vim.tbl_contains(keys_mod.actions(), 'plan-feedback')
  and vim.tbl_contains(keys_mod.actions(), 'plan-approve'))
check('the default keys are PA and PF', (function()
  local found = {}
  for _, k in ipairs(keys_mod.defaults) do
    if k[2]:match('^plan') then
      found[k[2]] = k[1] .. (k[4] and '!' or '')
    end
  end
  return vim.deep_equal(found, { ['plan-approve'] = 'A', ['plan-feedback'] = 'F' })
end)())
reset()

-- The keys in the plan ---------------------------------------------------------------------------------

vim.cmd('edit ' .. vim.fn.fnameescape(H.work .. '/g.txt'))
local g_before = vim.api.nvim_get_current_buf()
id = open('sess-1', plan_text)
plan_buf = vim.api.nvim_get_current_buf()
w.ask('why?', { 3, 3 })
vim.api.nvim_feedkeys('F', 'x', false)
check('F sends the feedback', result(id).state == 'feedback')
vim.api.nvim_feedkeys('A', 'x', false)
check('A approves', #tours.plans() == 0 and result(id).state == 'approve' and #vim.api.nvim_list_tabpages() == 1)
check('A and F are not mapped outside the plan', vim.fn.maparg('A', 'n') == '' and vim.fn.maparg('F', 'n') == '')
check('the plan is gone from the window', not vim.api.nvim_buf_is_valid(plan_buf) and vim.api.nvim_get_current_buf() == g_before)
reset()

-- The winbar names the keys that are mapped.
vim.keymap.set('n', '<leader>wa', '<Plug>(walkthrough-ask)')
id = open('sess-1', plan_text)
check('the winbar names a mapped key as the one that writes a comment', vim.wo[0].winbar:find('<leader>wa comment', 1, true) ~= nil
  and vim.wo[0].winbar:find(':Walkthrough', 1, true) == nil, vim.wo[0].winbar)
vim.keymap.del('n', '<leader>wa')
vim.keymap.set('n', '<leader>wc', '<Plug>(walkthrough-change)')
vim.cmd('doautocmd BufWinEnter')
check('the bar follows keys mapped later, either key', vim.wo[0].winbar:find('<leader>wc comment', 1, true) ~= nil
  and vim.wo[0].winbar:find('ask', 1, true) == nil, vim.wo[0].winbar)
vim.keymap.del('n', '<leader>wc')
reset()

-- One kind of comment ------------------------------------------------------------------------------------

-- In a plan `ask` and `change` do the same: they write a comment.
local function plan_threads()
  return plan_of(id).steps[1].threads or {}
end
local function press(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), 'x', false)
end
local function go(line)
  vim.api.nvim_win_set_cursor(0, { line, 0 })
end

reset()
id = open('sess-1', text_of(lines(30)))
plan_buf = vim.api.nvim_get_current_buf()
check('a plan that arrives says to write comments, then A and F', said('walkthrough: a plan is waiting for review: '
  .. 'write comments on its lines, then A approves and F sends them'), vim.inspect(log))
reset_log()

-- With text, by the API, one line and a range.
w.ask('by ask', { 2, 2 })
check('ask with text writes a comment', thread_of(id, 't1') and thread_of(id, 't1').kind == 'comment'
  and thread_of(id, 't1').state == 'draft' and #sent == 0)
check('the notification names the comment, its line and F', said('walkthrough: comment t1 added (line 2); F sends it'), vim.inspect(log))
reset_log()
w.change('by change', { 4, 4 })
check('change with text writes a comment', thread_of(id, 't2') and thread_of(id, 't2').kind == 'comment'
  and thread_of(id, 't2').state == 'draft' and #sent == 0)
w.ask('ask on a range', { 6, 8 })
w.change('change on a range', { 10, 12 })
check('ask on a range writes a comment on those lines', thread_of(id, 't3').kind == 'comment' and thread_of(id, 't3').from == 6
  and thread_of(id, 't3').to == 8)
check('change on a range writes a comment on those lines', thread_of(id, 't4').kind == 'comment' and thread_of(id, 't4').from == 10
  and thread_of(id, 't4').to == 12)
check('a range is named in the notification', said('comment t4 added (lines 10-12); F sends it'), vim.inspect(log))

-- The commands, with and without a range.
reset_log()
go(14)
vim.cmd('Walkthrough ask by the command ask')
vim.cmd('Walkthrough change by the command change')
check(':Walkthrough ask writes a comment, and :Walkthrough change replies in it', thread_of(id, 't5') and thread_of(id, 't5').kind == 'comment'
  and #thread_of(id, 't5').messages == 2 and thread_of(id, 't6') == nil, vim.inspect(plan_threads()))
vim.cmd('16,17Walkthrough change a range by the command')
vim.cmd('18,19Walkthrough ask a range by the other command')
check('commands with a range write comments', thread_of(id, 't6') and thread_of(id, 't6').kind == 'comment'
  and thread_of(id, 't6').from == 16 and thread_of(id, 't6').to == 17 and thread_of(id, 't7').kind == 'comment'
  and thread_of(id, 't7').from == 18 and thread_of(id, 't7').to == 19, vim.inspect(plan_threads()))

-- The <Plug> mappings, in Normal and in Visual mode.
answer = 'by the key'
go(1)
press('<Plug>(walkthrough-ask)')
answer = 'by the other key'
go(3)
press('<Plug>(walkthrough-change)')
check('the keys write comments', thread_of(id, 't8') and thread_of(id, 't8').kind == 'comment'
  and thread_of(id, 't8').from == 1 and thread_of(id, 't9') and thread_of(id, 't9').kind == 'comment'
  and thread_of(id, 't9').from == 3, vim.inspect(plan_threads()))
answer = 'selected, ask'
go(24)
press('Vj<Plug>(walkthrough-ask)')
answer = 'selected, change'
go(27)
press('Vj<Plug>(walkthrough-change)')
check('a selection gives a comment on its lines, with either key', thread_of(id, 't10') and thread_of(id, 't10').kind == 'comment'
  and thread_of(id, 't10').from == 24 and thread_of(id, 't10').to == 25 and thread_of(id, 't11') and thread_of(id, 't11').kind == 'comment'
  and thread_of(id, 't11').from == 27 and thread_of(id, 't11').to == 28 and vim.fn.mode() == 'n', vim.inspect(plan_threads()))
check('nothing of this was sent', #sent == 0)

-- Without text the prompt says what is written; in 'ui' mode it is the prompt of vim.ui.input.
answer, prompts = nil, {}
w.ask(nil, { 21, 21 })
w.change(nil, { 21, 23 })
check('the prompt of a new comment names the plan and the line, whichever key', prompts[1] == 'Comment on plan line 21: '
  and prompts[2] == 'Comment on plan lines 21-23: ', vim.inspect(prompts))
check('cancelling the prompt writes nothing', thread_of(id, 't12') == nil)
go(2)
w.ask()
w.change()
check('the prompt on lines with a comment is a reply, whichever key', prompts[3] == 'Reply in t1 on line 2: '
  and prompts[4] == 'Reply in t1 on line 2: ', vim.inspect(prompts))
answer = 'typed in the prompt'
w.change(nil, { 21, 22 })
check('the text from the prompt is a comment', thread_of(id, 't12') and thread_of(id, 't12').kind == 'comment'
  and thread_of(id, 't12').messages[1].text == 'typed in the prompt', vim.inspect(plan_threads()))
answer = nil

-- A second write on the same lines is a reply in the thread, the kind stays.
local before = #plan_threads()
reset_log()
w.change('second, by change', { 2, 2 })
w.ask('third, by ask', { 2, 2 })
check('writing again with either key replies in the thread', #plan_threads() == before and #thread_of(id, 't1').messages == 3
  and thread_of(id, 't1').messages[2].text == 'second, by change' and thread_of(id, 't1').messages[3].text == 'third, by ask'
  and thread_of(id, 't1').kind == 'comment' and #sent == 0, vim.inspect(thread_of(id, 't1')))
check('the notification of a reply names F', said('reply added to t1; F sends it'), vim.inspect(log))
check('the feedback module does not turn a comment into a change request',
  (require('walkthrough.feedback').reply(plan_of(id), plan_of(id).steps[1], thread_of(id, 't1'), 'direct, as a change', 'change') or true)
  and thread_of(id, 't1').kind == 'comment' and #thread_of(id, 't1').messages == 4)
-- The thread float names the kind a comment.
go(2)
w.thread()
local heading = vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]
check('the thread float heading says comment', heading:find('t1 · comment · ', 1, true) == 1 and not heading:find('question', 1, true),
  heading)
require('walkthrough.thread').close()
check('the float lines for a comment thread', require('walkthrough.thread').lines({
  t = plan_of(id), si = 1, step = plan_of(id).steps[1], thread = thread_of(id, 't1'),
})[1]:find(' · comment · ', 1, true) ~= nil)

-- What makes no sense for a comment still refuses.
reset_log()
go(2)
w.decide('accept')
w.explain('deeper')
check('decisions and explanations are still refused in a plan', said('no proposals') and said('no answers to explain') and #sent == 0,
  vim.inspect(log))

-- The message of the feedback: label, the final instruction, no question and no change request.
w.plan_feedback()
r = result(id)
check('all comments reach the agent in one message with "Comment" labels', r.state == 'feedback'
  and r.message:find('2. Comment t1 on plan line 2:', 1, true) ~= nil
  and r.message:find('Comment t4 on plan lines 10-12:', 1, true) ~= nil
  and r.message:find('Comment t11 on plan lines 27-28:', 1, true) ~= nil
  and r.message:find('(12 comments)', 1, true) ~= nil, vim.inspect(r))
check('the message has neither "Question" nor "Change request"', not r.message:find('Question', 1, true)
  and not r.message:find('Change request', 1, true) and not r.message:find('annotat', 1, true), r.message)
check('the message says to reply to every comment and to revise the plan where one asks for it',
  r.message:find('Reply to every comment with a patch', 1, true) ~= nil
  and r.message:find('revise the plan where a comment asks for a change or shows that one is needed', 1, true) ~= nil
  and r.message:sub(-#'before presenting the plan again.') == 'before presenting the plan again.', r.message)

check('a reply in a thread that was sent is a draft again, as a comment', (function()
  w.plan_feedback()
  result(id)
  w.ask('after the feedback', { 2, 2 })
  return thread_of(id, 't1').state == 'draft' and thread_of(id, 't1').kind == 'comment'
end)())

-- The agent answers a comment thread as before; the kind stays.
check('the agent answers a comment with an answer patch', send('patch', { thread = 't1', answer = 'fine' }) == 'ok'
  and thread_of(id, 't1').state == 'answered' and thread_of(id, 't1').kind == 'comment')
check('the answer patch is checked against a plan: a comment is valid there', send('patch', { thread = 't2', answer = 'ok too' }) == 'ok')

-- Dropping comments at approve: one, and several.
reset()
id = open('sess-1', plan_text)
w.ask('only one', { 1, 1 })
reset_log()
w.plan_approve()
check('approve says it dropped one comment', said('plan approved; dropped 1 comment that was still open'), vim.inspect(log))
id = open('sess-1', plan_text)
w.change('first', { 1, 1 })
w.ask('second', { 3, 3 })
reset_log()
w.plan_approve()
check('approve says it dropped several comments', said('plan approved; dropped 2 comments that were still open'), vim.inspect(log))

-- A plan saved with the two kinds of before loads with comments, and keeps every message.
reset()
id = open('sess-1', plan_text)
w.ask('old question', { 2, 2 })
w.change('old change request', { 4, 4 })
send('patch', { thread = 't2', answer = 'old proposal', proposal = true })
w.ask('reply to the old question', { 2, 2 })
local old_root = plan_of(id).root
local old_path = store.path(old_root)
local old = vim.json.decode(table.concat(vim.fn.readfile(old_path), '\n'))
local old_threads = old.tours[1].steps[1].threads
check('the saved plan has comments', old_threads[1].kind == 'comment' and old_threads[2].kind == 'comment')
old_threads[1].kind, old_threads[2].kind = 'question', 'change'
vim.fn.writefile({ vim.json.encode(old) }, old_path)
local reread = store.read(old_root)
local reread_threads = reread and reread.tours[1].steps[1].threads
check('store.read turns a saved question and change request of a plan into comments, with their messages',
  reread_threads and #reread_threads == 2 and reread_threads[1].kind == 'comment' and reread_threads[2].kind == 'comment'
  and #reread_threads[1].messages == 2 and #reread_threads[2].messages == 2
  and reread_threads[1].messages[1].text == 'old question' and reread_threads[2].messages[2].text == 'old proposal',
  vim.inspect(reread and reread.tours[1].steps[1].threads))
-- A restart: the saved plan with old kinds comes back through the usual path.
st.tours, st.active, st.plan_results, st.plan_order, st.plan_counters = {}, 0, {}, {}, {}
st.restored, st.dir_roots = {}, {}
vim.cmd('silent! tabonly')
vim.cmd('silent! %bwipeout!')
reset_log()
vim.cmd('Walkthrough plan')
check('a plan with old kinds is restored with comments and without an error', #tours.plans() == 1 and #plan_threads() == 2
  and thread_of(id, 't1').kind == 'comment' and thread_of(id, 't2').kind == 'comment'
  and #thread_of(id, 't1').messages == 2 and not said('cannot'), vim.inspect(log))
check('... the threads are drawn and the old proposal stays the thread\'s state', #marks_rows(vim.api.nvim_get_current_buf()) == 2
  and thread_of(id, 't2').state == 'proposed')
w.ask('and again', { 4, 4 })
check('writing on the restored thread replies in it', #thread_of(id, 't2').messages == 3 and thread_of(id, 't2').kind == 'comment')
w.plan_feedback()
check('the feedback of a restored plan labels them comments', result(id).message:find('Comment t1 on plan line 2:', 1, true) ~= nil)
-- The same through the session that revises it.
reset()
id = open('sess-1', plan_text)
w.ask('q', { 2, 2 })
old_root = plan_of(id).root
old_path = store.path(old_root)
old = vim.json.decode(table.concat(vim.fn.readfile(old_path), '\n'))
old.tours[1].steps[1].threads[1].kind = 'question'
vim.fn.writefile({ vim.json.encode(old) }, old_path)
st.tours, st.active, st.plan_results, st.plan_order, st.plan_counters = {}, 0, {}, {}, {}
st.restored, st.dir_roots = {}, {}
vim.cmd('silent! tabonly')
vim.cmd('silent! %bwipeout!')
check('a revision of a session with a saved question finds it as a comment', open('sess-1', text_of(lines(12))) == id
  and thread_of(id, 't1').kind == 'comment')
-- A comment that is saved on a tour of code is no thread: the step is dropped, as for any bad step.
reset()

-- Persistence and restart ------------------------------------------------------------------------------

id = open('sess-1', plan_text)
plan_buf = vim.api.nvim_get_current_buf()
w.ask('survives?', { 5, 5 })
w.change('and this', { 6, 7 })
local plan_root = plan_of(id).root
local saved_path = store.path(plan_root)
check('a plan under review is saved', vim.fn.filereadable(saved_path) == 1)
local saved = vim.json.decode(table.concat(vim.fn.readfile(saved_path), '\n'))
check('the saved tour is flagged as a plan with its id and session', #saved.tours == 1 and saved.tours[1].plan == true
  and saved.tours[1].plan_id == id and saved.tours[1].plan_session == 'sess-1' and saved.tours[1].plan_state == 'pending')
check('the saved plan has no queued feedback field', saved.tours[1].plan_result == nil)
local read = store.read(plan_root)
check('the plan is read back, never pruned as committed', read and #read.tours == 1 and read.tours[1].plan == true
  and #read.tours[1].steps[1].threads == 2)

-- A restart: nothing is loaded, the tab is gone, the file and the state stay.
st.tours, st.active, st.plan_results, st.plan_order, st.plan_counters = {}, 0, {}, {}, {}
st.restored, st.dir_roots = {}, {}
vim.cmd('silent! tabonly')
vim.cmd('silent! %bwipeout!')
check('after the restart no plan is loaded', #tours.plans() == 0 and status().plan == nil)
check('a closed Neovim leaves the hook to fall back: the id is unknown', w.plan_result(id):match('^error: ') ~= nil)
local revised2 = lines(12)
table.insert(revised2, 1, 'inserted')
local id_again = open('sess-1', text_of(revised2))
check('the same session finds its saved review and revises it', id_again == id and #tours.plans() == 1, id_again)
check('the saved threads came back and moved', #plan_of(id).steps[1].threads == 2 and thread_of(id, 't1').from == 6
  and thread_of(id, 't2').from == 7 and thread_of(id, 't2').to == 8, vim.inspect(plan_of(id).steps[1].threads))
check('the restored review is shown in the current tab', vim.api.nvim_buf_get_name(0) == plans_dir .. '/sess-1-1.md'
  and vim.deep_equal(buf_text(0), revised2))
check('the restored threads are drawn', vim.deep_equal(marks_rows(vim.api.nvim_get_current_buf()), { 6, 8 }),
  vim.inspect(marks_rows(vim.api.nvim_get_current_buf())))
w.plan_approve()

-- :Walkthrough plan brings a saved plan back by itself.
id = open('sess-2', 'a\nb\nc')
w.ask('later', { 2, 2 })
st.tours, st.active = {}, 0
st.restored, st.dir_roots = {}, {}
vim.cmd('silent! tabonly')
vim.cmd('silent! %bwipeout!')
vim.cmd('Walkthrough plan')
check(':Walkthrough plan restores a saved plan after a restart', #tours.plans() == 1 and #vim.api.nvim_list_tabpages() == 1
  and #plan_of(id).steps[1].threads == 1)
-- The next plan of another session does not collide with the file that is there.
local id3 = open('sess-2', 'again')
check('a saved review counts for its session', id3 == id and #tours.plans() == 1)
reset()

-- The files of an earlier run do not give an id twice.
vim.fn.mkdir(plans_dir, 'p')
vim.fn.writefile({ 'old' }, plans_dir .. '/sess-9-1.md')
check('a plan file that is still there is not reused', open('sess-9', 'new') == 'sess-9-2')
reset()

-- The plan and the other actions -----------------------------------------------------------------------

id = open('sess-1', plan_text)
plan_buf = vim.api.nvim_get_current_buf()
w.ask('q', { 2, 2 })
local f_plan = vim.api.nvim_get_current_tabpage()
vim.cmd('tabnew')
vim.cmd('edit ' .. vim.fn.fnameescape(H.work .. '/f.txt'))
local cwd_before = vim.fn.getcwd()
vim.cmd('cd ' .. vim.fn.fnameescape(H.work))
reset_log()
w.map()
check('the map shows nothing for a plan alone', find('nothing to show') ~= nil and st.panel_win == nil)
w.group('next')
check('group has no tour to switch to', find('no review open') ~= nil)
reset_log()
w.stage_group()
w.stage_group({ all = true })
w.reject_group()
check('stage, stage all and reject have no tour to work on with a plan alone', #tours.plans() == 1
  and find('no review open') ~= nil and thread_of(id, 't1').state == 'draft', vim.inspect(log))
reset_log()
w.commit()
check('commit has nothing to do with a plan alone', #tours.plans() == 1 and thread_of(id, 't1').state == 'draft', vim.inspect(log))
w.review()
check('review starts a review of the repository', tours.count() == 1 and st.tours[tours.find(nil)].auto == true
  and #tours.plans() == 1, #st.tours)
check('the plan is not the unnamed tour', select(2, tours.find(nil)).plan == nil)
check('status keeps the plan apart from the groups', #status().groups == 1 and status().plan.id == id
  and status().plan.threads == 1, w.status())
check('the review is not the plan', st.active ~= 0 and tours.active().plan == nil and tours.active().auto)
check('the panel map does not list the plan', not H.panel_text():find('plans', 1, true) and not H.panel_text():find('sess-1', 1, true),
  H.panel_text())
check('a send from the review does not carry the plan', (function()
  w.send()
  return #sent == 0
end)())
check('inbox of the review does not list the plan', #vim.json.decode(w.inbox(true)).items == 0)
w.commit()
check('commit does not touch the plan', #tours.plans() == 1 and thread_of(id, 't1').state == 'draft')
local agent_tour = {
  group = 'A', steps = { { file = H.work .. '/f.txt', title = 'one', from = 2, to = 3 } },
}
check('an agent tour of a group replaces the review, not the plan', send('load', agent_tour) == 'ok' and #tours.plans() == 1
  and tours.count() == 1 and tours.active().group == 'A')
check('a tour with no group does not replace the plan', send('load', { steps = { { file = H.work .. '/g.txt' } } }) == 'ok'
  and #tours.plans() == 1 and tours.count() == 2)
-- A patch with step numbers addresses the tours, a thread patch also the plan.
check('a thread patch reaches the plan next to a loaded tour', send('patch', { thread = 't1', answer = 'fine' }) == 'ok'
  and thread_of(id, 't1').state == 'answered')
check('step 2 of the shown tour does not exist (the plan is no step)', send('patch', { step = 2, title = 'x' }):match('^error: ') ~= nil)

-- close leaves the plan; the plan does not make a state file of the review's repository.
w.close()
check('close leaves the plan review alone', #tours.plans() == 1 and tours.count() == 0 and result(id).state == 'pending'
  and vim.api.nvim_buf_is_valid(plan_buf) and #vim.api.nvim_list_tabpages() == 2)
check('close does not answer the hook', st.plan_results[id] == nil)
w.discard()
check('discard leaves the plan review and its marks alone', #tours.plans() == 1 and vim.api.nvim_buf_is_valid(plan_buf)
  and vim.deep_equal(marks_rows(plan_buf), { 2 }) and result(id).state == 'pending')
check('the plan\'s threads are still drawn after close', vim.deep_equal(marks_rows(plan_buf), { 2 }), vim.inspect(marks_rows(plan_buf)))
check('close leaves the plan in the saved state', vim.fn.filereadable(store.path(plan_of(id).root)) == 1)
vim.cmd('cd ' .. vim.fn.fnameescape(cwd_before))
check('the plan can still be approved after close', (function()
  vim.api.nvim_set_current_tabpage(f_plan)
  w.plan_approve()
  return #tours.plans() == 0 and result(id).state == 'approve'
end)())
reset()

-- Several plans -------------------------------------------------------------------------------------------

local a = open('sess-a', 'a1\na2')
local a_buf = vim.api.nvim_get_current_buf()
local b = open('sess-b', 'b1\nb2')
local b_buf = vim.api.nvim_get_current_buf()
check('two sessions, two reviews', a ~= b and #tours.plans() == 2)
check('the newest plan is shown in the window of the first', #vim.api.nvim_tabpage_list_wins(0) == 1
  and #vim.fn.win_findbuf(a_buf) == 0 and #vim.fn.win_findbuf(b_buf) == 1)
-- The user brings the first one back in that window.
vim.cmd('buffer ' .. a_buf)
w.ask('only in a', { 1, 1 })
check('a thread goes to the plan of the buffer', #plan_of(a).steps[1].threads == 1 and #(plan_of(b).steps[1].threads or {}) == 0)
check('status reports the plan in the current buffer', status().plan.id == a)
w.plan_feedback()
check('feedback goes to the plan of the buffer', result(a).state == 'feedback' and result(b).state == 'pending')
vim.cmd('tabnew')
reset_log()
w.plan_approve()
check('approve outside a plan window asks which one when there are several', find('several plans') ~= nil and #tours.plans() == 2)
w.plan_approve(b)
check('a plan can be approved by id', #tours.plans() == 1 and result(b).state == 'approve' and result(a).state == 'pending')
reset()

-- Where the plan is shown ---------------------------------------------------------------------------------
--
-- In a window of the current tab that holds code, next to the agent's terminal;
-- when the review ends the window shows what it showed before.

local long = vim.fn.tempname() .. '.txt'
vim.fn.writefile(lines(100, 'c'), long)
local f, g = H.work .. '/f.txt', H.work .. '/g.txt'
-- The agent's terminal: `cat` in a split at the right edge, left in Normal mode.
local function agent_terminal()
  vim.cmd('botright vsplit')
  vim.cmd('terminal cat')
  vim.cmd('stopinsert')
  return vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
end
local function view_of(win)
  return vim.api.nvim_win_call(win, vim.fn.winsaveview)
end
local function same_view(a, b)
  return a.lnum == b.lnum and a.col == b.col and a.topline == b.topline
end
local function buf_of(win)
  return vim.api.nvim_win_get_buf(win)
end
local function is_float(win)
  return vim.api.nvim_win_get_config(win).relative ~= ''
end
local function plan_win_of(buf)
  return vim.fn.win_findbuf(buf)[1]
end

-- A terminal next to code: the plan takes the code window, nothing else moves.
reset()
vim.cmd('edit ' .. vim.fn.fnameescape(long))
local code_win, code_buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
vim.api.nvim_win_set_cursor(code_win, { 60, 3 })
vim.cmd('normal! zt')
local code_view = view_of(code_win)
local term_win, term_buf = agent_terminal()
local term_size = { vim.api.nvim_win_get_width(term_win), vim.api.nvim_win_get_height(term_win) }
local wins = vim.api.nvim_tabpage_list_wins(0)
id = open('sess-1', plan_text)
plan_buf = vim.api.nvim_get_current_buf()
check('terminal: the plan opens in the current tab and no tab is created', #vim.api.nvim_list_tabpages() == 1)
check('terminal: the plan is in the code window, which has the focus', vim.api.nvim_get_current_win() == code_win
  and buf_of(code_win) == plan_buf and vim.deep_equal(vim.api.nvim_tabpage_list_wins(0), wins))
check('terminal: the terminal keeps its buffer, window and size', vim.api.nvim_win_is_valid(term_win) and buf_of(term_win) == term_buf
  and vim.bo[term_buf].buftype == 'terminal' and vim.api.nvim_win_get_width(term_win) == term_size[1]
  and vim.api.nvim_win_get_height(term_win) == term_size[2])
check('terminal: the plan window is in Normal mode', vim.api.nvim_get_mode().mode == 'n')
w.ask('why?', { 3, 3 })
w.plan_approve()
check('terminal: after approve the window shows its buffer again, in the same place', buf_of(code_win) == code_buf
  and same_view(view_of(code_win), code_view), vim.inspect({ view_of(code_win), code_view }))
check('terminal: ... the focus is back in the terminal', vim.api.nvim_get_current_win() == term_win)
check('terminal: ... which is untouched', buf_of(term_win) == term_buf and vim.deep_equal(vim.api.nvim_tabpage_list_wins(0), wins)
  and vim.api.nvim_win_get_width(term_win) == term_size[1])
check('terminal: the plan buffer is gone', not vim.api.nvim_buf_is_valid(plan_buf))

-- Only the terminal on screen: a split for the plan, closed again afterwards.
reset()
term_win, term_buf = agent_terminal()
vim.cmd('only')
local full = vim.api.nvim_win_get_width(term_win)
id = open('sess-1', plan_text)
plan_buf = vim.api.nvim_get_current_buf()
local split_win = plan_win_of(plan_buf)
check('split: the plan is in a new window of the tab', #vim.api.nvim_tabpage_list_wins(0) == 2 and #vim.api.nvim_list_tabpages() == 1
  and split_win ~= term_win and vim.api.nvim_get_current_win() == split_win)
check('split: ... on the left, so the terminal stays on the right', vim.api.nvim_win_get_position(split_win)[2]
  < vim.api.nvim_win_get_position(term_win)[2])
check('split: the terminal keeps its buffer and stays on screen', vim.api.nvim_win_is_valid(term_win) and buf_of(term_win) == term_buf
  and vim.api.nvim_win_get_width(term_win) > 0)
check('split: the plan window is in Normal mode', vim.api.nvim_get_mode().mode == 'n')
w.plan_approve()
check('split: approve closes the split', #vim.api.nvim_tabpage_list_wins(0) == 1 and not vim.api.nvim_win_is_valid(split_win))
check('split: ... the terminal has the focus and its width back', vim.api.nvim_get_current_win() == term_win
  and buf_of(term_win) == term_buf and vim.api.nvim_win_get_width(term_win) == full)
-- A revision shows the plan again in the same split.
id = open('sess-1', plan_text)
split_win = plan_win_of(vim.api.nvim_get_current_buf())
vim.api.nvim_set_current_win(term_win)
check('split: a revised plan opens no window and takes the focus', open('sess-1', text_of(lines(3))) == id
  and #vim.api.nvim_tabpage_list_wins(0) == 2 and vim.api.nvim_get_current_win() == split_win
  and vim.deep_equal(buf_text(vim.api.nvim_get_current_buf()), lines(3)))
w.plan_approve()

-- A window that does not hold code (a sidebar) is not taken either; the split
-- goes on the side of the terminal that faces the middle.
reset()
vim.cmd('terminal cat')
vim.cmd('stopinsert')
term_win, term_buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
vim.cmd('botright vsplit')
vim.cmd('enew')
vim.bo.buftype = 'nofile'
local side_win, side_buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
vim.api.nvim_set_current_win(term_win)
id = open('sess-1', plan_text)
split_win = plan_win_of(vim.api.nvim_get_current_buf())
check('sidebar: a scratch window is not taken', buf_of(side_win) == side_buf and #vim.api.nvim_tabpage_list_wins(0) == 3
  and split_win ~= side_win and split_win ~= term_win)
check('sidebar: the split is beside the terminal, on the side of the middle', vim.api.nvim_win_get_position(split_win)[2]
  > vim.api.nvim_win_get_position(term_win)[2] and vim.api.nvim_win_get_position(split_win)[2]
  < vim.api.nvim_win_get_position(side_win)[2])
w.plan_approve()
check('sidebar: approve closes that split', #vim.api.nvim_tabpage_list_wins(0) == 2 and vim.api.nvim_get_current_win() == term_win)
reset()

-- The map panel is never taken: with a panel and a terminal only, there is a split.
vim.cmd('edit ' .. vim.fn.fnameescape(f))
check('panel: a review is loaded with its map', send('load', { group = 'A', steps = { { file = f, title = 'one' } } }) == 'ok'
  and st.panel_win ~= nil and vim.api.nvim_win_is_valid(st.panel_win))
local panel_win, panel_buf = st.panel_win, st.panel_buf
local panel_text = H.panel_text()
term_win, term_buf = agent_terminal()
vim.api.nvim_win_close(st.code_win, true)
check('panel: only the panel and the terminal are on screen', #vim.api.nvim_tabpage_list_wins(0) == 2)
id = open('sess-1', plan_text)
split_win = plan_win_of(vim.api.nvim_get_current_buf())
check('panel: the plan gets a window of its own', #vim.api.nvim_tabpage_list_wins(0) == 3 and split_win ~= panel_win
  and buf_of(panel_win) == panel_buf and H.panel_text() == panel_text and buf_of(term_win) == term_buf)
w.plan_approve()
check('panel: ... which is closed again, the panel is as it was', #vim.api.nvim_tabpage_list_wins(0) == 2
  and vim.api.nvim_win_is_valid(panel_win) and buf_of(panel_win) == panel_buf and H.panel_text() == panel_text)
reset()

-- A float is never taken, even when it is the current window.
vim.cmd('terminal cat')
vim.cmd('stopinsert')
term_win, term_buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
local float_buf = vim.fn.bufadd(f)
vim.fn.bufload(float_buf)
local float = vim.api.nvim_open_win(float_buf, true, { relative = 'editor', row = 1, col = 1, width = 30, height = 5 })
id = open('sess-1', plan_text)
split_win = plan_win_of(vim.api.nvim_get_current_buf())
check('float: the plan gets a split, the float is untouched', split_win ~= float and not is_float(split_win)
  and vim.api.nvim_win_is_valid(float) and is_float(float) and buf_of(float) == float_buf and buf_of(term_win) == term_buf)
w.plan_approve()
check('float: ... which is closed again; the float is still there', vim.api.nvim_win_is_valid(float) and is_float(float)
  and buf_of(float) == float_buf and not vim.api.nvim_win_is_valid(split_win))
reset()

-- A window fixed to its buffer is never taken.
vim.cmd('edit ' .. vim.fn.fnameescape(f))
local fixed = vim.api.nvim_get_current_win()
vim.wo[fixed].winfixbuf = true
local fixed_buf = vim.api.nvim_get_current_buf()
term_win, term_buf = agent_terminal()
vim.api.nvim_set_current_win(fixed)
id = open('sess-1', plan_text)
split_win = plan_win_of(vim.api.nvim_get_current_buf())
check('winfixbuf: the plan gets a split, the window keeps its buffer', split_win ~= fixed and buf_of(fixed) == fixed_buf
  and #vim.api.nvim_tabpage_list_wins(0) == 3 and buf_of(term_win) == term_buf)
w.plan_approve()
check('winfixbuf: ... which is closed again', #vim.api.nvim_tabpage_list_wins(0) == 2 and vim.api.nvim_get_current_win() == fixed)
-- ... but another window that fits is taken, even when the fixed one is current.
vim.cmd('leftabove vsplit ' .. vim.fn.fnameescape(g))
local free = vim.api.nvim_get_current_win()
vim.api.nvim_set_current_win(fixed)
id = open('sess-1', plan_text)
check('winfixbuf: another window that holds code is taken', buf_of(free) == vim.api.nvim_get_current_buf()
  and vim.api.nvim_get_current_win() == free and buf_of(fixed) == fixed_buf and #vim.api.nvim_tabpage_list_wins(0) == 3)
w.plan_approve()
check('winfixbuf: ... and given back', vim.api.nvim_buf_get_name(buf_of(free)) == g and vim.api.nvim_get_current_win() == fixed)
vim.wo[fixed].winfixbuf = false
reset()

-- No code window: the window used most recently that holds code (`#`), not the others.
vim.cmd('edit ' .. vim.fn.fnameescape(f))
local win_a = vim.api.nvim_get_current_win()
vim.cmd('rightbelow vsplit ' .. vim.fn.fnameescape(g))
local win_b = vim.api.nvim_get_current_win()
vim.cmd('rightbelow vsplit ' .. vim.fn.fnameescape(long))
local win_c = vim.api.nvim_get_current_win()
term_win, term_buf = agent_terminal()
vim.api.nvim_set_current_win(win_a)
vim.api.nvim_set_current_win(win_c)
vim.api.nvim_set_current_win(win_b)
vim.api.nvim_set_current_win(term_win)
local bufs = { [win_a] = buf_of(win_a), [win_b] = buf_of(win_b), [win_c] = buf_of(win_c) }
id = open('sess-1', plan_text)
check('recent: the window used last before the terminal is taken', vim.api.nvim_get_current_win() == win_b
  and buf_of(win_a) == bufs[win_a] and buf_of(win_c) == bufs[win_c] and #vim.api.nvim_tabpage_list_wins(0) == 4)
w.plan_approve()
check('recent: ... and given back, the focus is in the terminal', buf_of(win_b) == bufs[win_b]
  and vim.api.nvim_get_current_win() == term_win)
-- The current window comes first when it holds code.
vim.api.nvim_set_current_win(win_a)
id = open('sess-1', plan_text)
check('recent: the current window is taken when it holds code', vim.api.nvim_get_current_win() == win_a
  and buf_of(win_b) == bufs[win_b])
w.plan_approve()
reset()

-- The code window of a review comes first, even if another window is current.
vim.cmd('edit ' .. vim.fn.fnameescape(f))
check('code window: a review is loaded', send('load', { group = 'A', steps = { { file = f, title = 'one' } } }) == 'ok')
local review_win, review_buf = st.code_win, buf_of(st.code_win)
vim.api.nvim_set_current_win(review_win)
vim.cmd('rightbelow vsplit ' .. vim.fn.fnameescape(g))
local g_win = vim.api.nvim_get_current_win()
local g_buf2 = vim.api.nvim_get_current_buf()
term_win, term_buf = agent_terminal()
vim.api.nvim_set_current_win(g_win)
id = open('sess-1', plan_text)
check('code window: the plan takes the code window of the review', vim.api.nvim_get_current_win() == review_win
  and st.code_win == review_win and buf_of(g_win) == g_buf2)
w.plan_approve()
check('code window: ... gives it back, the focus returns to where it came from', buf_of(review_win) == review_buf
  and vim.api.nvim_get_current_win() == g_win)
reset()

-- Several plans: one window; what comes back at the end is what was there before the first.
vim.cmd('edit ' .. vim.fn.fnameescape(long))
code_win, code_buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
vim.api.nvim_win_set_cursor(code_win, { 40, 2 })
vim.cmd('normal! zt')
code_view = view_of(code_win)
term_win, term_buf = agent_terminal()
wins = vim.api.nvim_tabpage_list_wins(0)
local a1 = open('sess-a', 'a1\na2')
local a1_buf = plan_win_of(vim.api.nvim_get_current_buf()) and vim.api.nvim_get_current_buf()
vim.api.nvim_set_current_win(term_win)
local b1 = open('sess-b', 'b1\nb2')
local b1_buf = vim.api.nvim_get_current_buf()
check('several: a second plan is shown in the same window, which has the focus', a1 ~= b1 and #tours.plans() == 2
  and vim.deep_equal(vim.api.nvim_tabpage_list_wins(0), wins) and vim.api.nvim_get_current_win() == code_win
  and buf_of(code_win) == b1_buf and #vim.api.nvim_list_tabpages() == 1)
vim.api.nvim_set_current_win(term_win)
vim.cmd('Walkthrough plan')
check('several: :Walkthrough plan goes to the same window, with the newest plan', vim.api.nvim_get_current_win() == code_win
  and buf_of(code_win) == b1_buf and vim.deep_equal(vim.api.nvim_tabpage_list_wins(0), wins))
w.plan_approve(b1)
check('several: when the newest is approved, the other one takes the window', #tours.plans() == 1
  and buf_of(code_win) == a1_buf and vim.api.nvim_get_current_win() == code_win and not vim.api.nvim_buf_is_valid(b1_buf)
  and vim.deep_equal(vim.api.nvim_tabpage_list_wins(0), wins))
w.plan_approve(a1)
check('several: at the very end the buffer from before the first plan is back, in the same place',
  buf_of(code_win) == code_buf and same_view(view_of(code_win), code_view) and vim.api.nvim_get_current_win() == term_win)
-- The other way round: the older one first.
local a2 = open('sess-a', 'a1\na2')
vim.api.nvim_set_current_win(term_win)
local b2 = open('sess-b', 'b1\nb2')
b1_buf = vim.api.nvim_get_current_buf()
w.plan_approve(a2)
check('several: approving the older one keeps the newest on screen', #tours.plans() == 1 and buf_of(code_win) == b1_buf
  and vim.api.nvim_get_current_win() == code_win)
w.plan_approve(b2)
check('several: ... and the end restores the first buffer', buf_of(code_win) == code_buf and same_view(view_of(code_win), code_view))
reset()

-- A revised plan, with the user in the terminal, opens no window and takes the focus.
vim.cmd('edit ' .. vim.fn.fnameescape(f))
code_win = vim.api.nvim_get_current_win()
term_win = agent_terminal()
id = open('sess-1', plan_text)
plan_buf = vim.api.nvim_get_current_buf()
wins = vim.api.nvim_tabpage_list_wins(0)
vim.api.nvim_set_current_win(term_win)
check('revised: the same review answers', open('sess-1', text_of(lines(5))) == id)
check('revised: no window and no tab is opened, the plan window has the focus', vim.deep_equal(vim.api.nvim_tabpage_list_wins(0), wins)
  and #vim.api.nvim_list_tabpages() == 1 and vim.api.nvim_get_current_win() == code_win and vim.api.nvim_get_current_buf() == plan_buf
  and vim.deep_equal(buf_text(plan_buf), lines(5)))
w.plan_approve()
check('revised: the end gives the focus back to the terminal', vim.api.nvim_get_current_win() == term_win)
reset()

-- The user leaves the plan window: the plan stays pending and can be shown again.
vim.cmd('edit ' .. vim.fn.fnameescape(f))
code_win, code_buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
term_win, term_buf = agent_terminal()
vim.api.nvim_set_current_win(code_win)
id = open('sess-1', plan_text)
plan_buf = vim.api.nvim_get_current_buf()
w.ask('why?', { 2, 2 })
vim.cmd('edit ' .. vim.fn.fnameescape(g))
check('left: another buffer in the plan window leaves the plan pending', #tours.plans() == 1 and result(id).state == 'pending'
  and vim.api.nvim_buf_is_valid(plan_buf) and #vim.fn.win_findbuf(plan_buf) == 0)
local ok_show = pcall(vim.cmd, 'Walkthrough plan')
check('left: :Walkthrough plan shows it again in the same window', ok_show and vim.api.nvim_get_current_win() == code_win
  and buf_of(code_win) == plan_buf and #vim.api.nvim_tabpage_list_wins(0) == 2 and #vim.api.nvim_list_tabpages() == 1)
check('left: ... with its threads and keys', vim.deep_equal(marks_rows(plan_buf), { 2 }) and vim.fn.maparg('A', 'n', false, true).buffer == 1)
w.plan_approve()
check('left: the end gives back what the window showed before the plan came back', vim.api.nvim_buf_get_name(buf_of(code_win)) == g)
-- :bdelete of the plan.
id = open('sess-1', plan_text)
plan_buf = vim.api.nvim_get_current_buf()
w.ask('why?', { 3, 3 })
local ok_bd = pcall(vim.cmd, 'bdelete')
check(':bdelete of the plan leaves it pending and does not raise', ok_bd and #tours.plans() == 1 and result(id).state == 'pending'
  and vim.fn.filereadable(plans_dir .. '/' .. id .. '.md') == 1)
ok_show = pcall(vim.cmd, 'Walkthrough plan')
plan_buf = vim.fn.bufnr(plans_dir .. '/' .. id .. '.md')
check('left: after :bdelete, :Walkthrough plan shows the plan again with text, threads and keys', ok_show
  and buf_of(vim.api.nvim_get_current_win()) == plan_buf and vim.deep_equal(buf_text(plan_buf), lines(12))
  and vim.deep_equal(marks_rows(plan_buf), { 3 }) and vim.fn.maparg('A', 'n', false, true).buffer == 1
  and #vim.api.nvim_list_tabpages() == 1)
w.plan_approve()
-- Closing the window of a split made for the plan.
reset()
term_win, term_buf = agent_terminal()
vim.cmd('only')
id = open('sess-1', plan_text)
plan_buf = vim.api.nvim_get_current_buf()
vim.cmd('close')
check('left: closing the split leaves the plan pending', #tours.plans() == 1 and result(id).state == 'pending'
  and #vim.api.nvim_tabpage_list_wins(0) == 1 and vim.api.nvim_get_current_win() == term_win)
vim.cmd('Walkthrough plan')
check('left: :Walkthrough plan makes a split again', #vim.api.nvim_tabpage_list_wins(0) == 2 and vim.api.nvim_get_current_buf() == plan_buf
  and buf_of(term_win) == term_buf)
w.plan_approve()
check('left: ... and approve closes it', #vim.api.nvim_tabpage_list_wins(0) == 1 and buf_of(term_win) == term_buf)
reset()

-- A buffer that cannot be left (unsaved changes, 'nohidden') keeps its window.
vim.o.hidden = false
vim.cmd('edit ' .. vim.fn.fnameescape(f))
local dirty_win, dirty_buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(dirty_buf, 0, 1, false, { 'changed' })
term_win = agent_terminal()
vim.api.nvim_set_current_win(dirty_win)
local ok_dirty = pcall(open, 'sess-1', plan_text)
id = 'sess-1-1'
check('unsaved: the plan opens in a split and the buffer with changes keeps its window', ok_dirty and #tours.plans() == 1
  and buf_of(dirty_win) == dirty_buf and vim.bo[dirty_buf].modified and #vim.api.nvim_tabpage_list_wins(0) == 3
  and vim.api.nvim_get_current_win() ~= dirty_win)
w.plan_approve()
check('unsaved: approve closes the split', #vim.api.nvim_tabpage_list_wins(0) == 2 and buf_of(dirty_win) == dirty_buf)
vim.o.hidden = true
vim.api.nvim_set_current_win(dirty_win)
vim.bo[dirty_buf].modified = false
reset()

-- The buffer from before is gone: another listed buffer, else an empty one; no error.
vim.cmd('edit ' .. vim.fn.fnameescape(g))
local g_listed = vim.api.nvim_get_current_buf()
vim.cmd('edit ' .. vim.fn.fnameescape(f))
code_win, code_buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
term_win = agent_terminal()
vim.api.nvim_set_current_win(code_win)
id = open('sess-1', plan_text)
vim.api.nvim_buf_delete(code_buf, { force = true })
local ok_gone = pcall(w.plan_approve)
check('gone: approve does not raise, the window shows another listed buffer', ok_gone and buf_of(code_win) == g_listed
  and #tours.plans() == 0 and vim.api.nvim_get_current_win() == code_win)
id = open('sess-1', plan_text)
vim.api.nvim_buf_delete(g_listed, { force = true })
ok_gone = pcall(w.plan_approve)
local shown_now = buf_of(code_win)
check('gone: ... else an empty buffer; the window stays', ok_gone and vim.api.nvim_win_is_valid(code_win)
  and vim.api.nvim_buf_get_name(shown_now) == '' and vim.bo[shown_now].buftype == '' and #vim.api.nvim_tabpage_list_wins(0) == 2)
reset()

-- A review under way ---------------------------------------------------------------------------------------
-- The plan takes the code window of the review; afterwards the view is back and works.

local function review_checks(view_name)
  st.config.view = view_name
  vim.cmd('edit ' .. vim.fn.fnameescape(f))
  local tour_a = {
    group = 'A',
    steps = { { file = f, title = 'one', hunks = { { from = 2, to = 3, group = 'A' } } }, { file = g, title = 'two' } },
  }
  check(view_name .. ': a review is loaded with its map', send('load', tour_a) == 'ok' and st.panel_win ~= nil
    and status().view == view_name)
  local win, panel = st.code_win, st.panel_win
  local shown = buf_of(win)
  local before_status, before_panel = w.status(), H.panel_text()
  local before_view = view_of(win)
  local before_marks = H.marks(function()
    return true
  end, shown)
  local review_term = agent_terminal()
  local n_wins = #vim.api.nvim_tabpage_list_wins(0)
  local nid = open('sess-1', plan_text)
  check(view_name .. ': the plan takes the code window, the map panel stays', buf_of(win) == vim.fn.bufnr(plans_dir .. '/' .. nid .. '.md')
    and st.panel_win == panel and vim.api.nvim_win_is_valid(panel) and H.panel_text() == before_panel
    and #vim.api.nvim_tabpage_list_wins(0) == n_wins and vim.api.nvim_get_current_win() == win)
  check(view_name .. ': the view buffer is not wiped while the plan is shown', vim.api.nvim_buf_is_valid(shown)
    and (view_name == 'file' or st.compact[shown] ~= nil))
  w.ask('and this?', { 2, 2 })
  w.plan_approve(nid)
  check(view_name .. ': afterwards the window shows the view again, in the same place', buf_of(win) == shown
    and st.code_win == win and same_view(view_of(win), before_view) and vim.api.nvim_get_current_win() == review_term)
  check(view_name .. ': the map panel and status are as before', st.panel_win == panel and H.panel_text() == before_panel
    and w.status() == before_status, w.status() .. '\n' .. before_status)
  check(view_name .. ': the marks of the review are still drawn', H.marks(function()
    return true
  end, shown) == before_marks and before_marks > 0, H.marks(function()
    return true
  end, shown) .. ' ' .. before_marks)
  -- It works: next step, previous step, the other view.
  vim.api.nvim_set_current_win(win)
  local ok_next = pcall(w.step, 1)
  check(view_name .. ': afterwards next step works', ok_next and status().step == 2, w.status())
  pcall(w.step, -1)
  local ok_view = pcall(w.view)
  check(view_name .. ': ... and the other view works', ok_view and status().view ~= view_name, w.status())
  reset()
end
review_checks('compact')
review_checks('file')
st.config.view = 'file'

-- Terminal mode ---------------------------------------------------------------------------------------------
-- A Neovim that runs its main loop, driven over RPC: Terminal mode only exists there.

local child_state = vim.fn.tempname()
vim.fn.mkdir(child_state, 'p')
local child_addr = vim.fn.tempname()
local child_job = vim.fn.jobstart({
  'nvim', '--headless', '--listen', child_addr, '-i', 'NONE', '-n', '--cmd', 'set rtp^=' .. vim.env.WALKTHROUGH_ROOT,
  '-u', vim.env.WALKTHROUGH_ROOT .. '/tests/init.lua',
}, { cwd = H.work, env = { XDG_STATE_HOME = child_state, WALKTHROUGH_STATE_DIR = child_state .. '/walkthrough' } })
vim.wait(5000, function()
  return vim.uv.fs_stat(child_addr) ~= nil
end, 20)
local chan = vim.fn.sockconnect('pipe', child_addr, { rpc = true })
local function remote(code)
  return vim.rpcrequest(chan, 'nvim_exec_lua', code, {})
end
local function typed(keys)
  vim.rpcrequest(chan, 'nvim_input', keys)
end
local function remote_wait(code)
  return vim.wait(5000, function()
    return remote(code)
  end, 10)
end
local plan_file = vim.fn.tempname()
vim.fn.writefile({ vim.json.encode(input('sess-t', text_of(lines(6)))) }, plan_file)

-- The user types to the agent in Terminal mode when the plan arrives.
remote([[
  vim.cmd('edit f.txt')
  _G.code_win = vim.api.nvim_get_current_win()
  vim.cmd('botright vsplit')
  vim.cmd('terminal cat')
  _G.term_win = vim.api.nvim_get_current_win()
  _G.term_buf = vim.api.nvim_get_current_buf()
]])
typed('i')
check('mode: the user is typing in the terminal (Terminal mode)', remote_wait([[return vim.api.nvim_get_mode().mode == 't']]))
local cid = vim.rpcrequest(chan, 'nvim_exec_lua', 'return require("walkthrough").plan(...)', { plan_file })
check('mode: the plan was opened over RPC', cid == 'sess-t-1', cid)
check('mode: the plan window has the focus, in Normal mode', remote_wait([[return vim.api.nvim_get_mode().mode == 'n'
  and vim.api.nvim_get_current_win() == _G.code_win and vim.api.nvim_buf_get_name(0):match('sess%-t%-1%.md$') ~= nil]]))
typed('j')
check('mode: the first key in the plan is a Normal mode key', remote_wait([[return vim.api.nvim_win_get_cursor(0)[1] == 2]]))
typed('A')
check('mode: A approves; the terminal has the focus and Terminal mode is on again', remote_wait([[return vim.api.nvim_get_mode().mode == 't'
  and vim.api.nvim_get_current_win() == _G.term_win and vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(_G.code_win)):match('f%.txt$') ~= nil]]))
typed('hi')
check('mode: what is typed now goes to the agent', remote_wait([[return table.concat(vim.api.nvim_buf_get_lines(_G.term_buf, 0, -1, false), '\n'):find('hi', 1, true) ~= nil]]))
check('mode: ... and nothing of the keys pressed in the plan did', remote([[local text = table.concat(vim.api.nvim_buf_get_lines(_G.term_buf, 0, -1, false), '\n')
  return text:find('j', 1, true) == nil and text:find('A', 1, true) == nil]]))

-- The user is inserting text in the code window when the plan arrives.
typed('<C-\\><C-n>')
remote_wait([[return vim.api.nvim_get_mode().mode ~= 't']])
remote([[
  vim.api.nvim_set_current_win(_G.code_win)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
]])
typed('i')
check('mode: the user is inserting in the code window', remote_wait([[return vim.api.nvim_get_mode().mode == 'i']]))
vim.fn.writefile({ vim.json.encode(input('sess-u', 'x\ny\nz')) }, plan_file)
cid = vim.rpcrequest(chan, 'nvim_exec_lua', 'return require("walkthrough").plan(...)', { plan_file })
check('mode: Insert mode is left when the plan comes', cid == 'sess-u-1' and remote_wait([[return vim.api.nvim_get_mode().mode == 'n'
  and vim.api.nvim_buf_get_name(0):match('sess%-u%-1%.md$') ~= nil]]))
typed('j')
check('mode: the first key in the plan moves the cursor and types nothing', remote_wait([[return vim.api.nvim_win_get_cursor(0)[1] == 2]])
  and remote([[return vim.api.nvim_buf_get_lines(vim.fn.bufnr('f.txt'), 0, 1, false)[1] == 'a1']]))
typed('A')
check('mode: after A the code window shows its buffer in Normal mode', remote_wait([[return vim.api.nvim_get_mode().mode == 'n'
  and vim.api.nvim_get_current_win() == _G.code_win and vim.api.nvim_buf_get_name(0):match('f%.txt$') ~= nil]]))
vim.fn.jobstop(child_job)
vim.fn.delete(child_state, 'rf')
vim.fn.delete(long)
reset()

-- A lot of approvals do not pile up.
for i = 1, 25 do
  local x = open('bulk-' .. i, 'x')
  w.plan_approve(x)
end
check('only the latest approvals are kept for the hook', #st.plan_order == 20 and st.plan_results['bulk-25-1'] ~= nil
  and st.plan_results['bulk-1-1'] == nil)
reset()

H.finish()
