-- Plan review: the agent's plan opens in a tab of its own while a hook waits.
-- The hook script is tested in tests/scripts.sh; here the two socket entry
-- points it calls (plan, plan_result), the annotations, feedback, approval,
-- revisions, persistence and the plan's isolation from the other actions.
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
      table.insert(out, vl[1][1])
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
-- Two windows in the first tab, to see that they are left alone.
vim.cmd('edit ' .. vim.fn.fnameescape(H.work .. '/f.txt'))
vim.cmd('vsplit ' .. vim.fn.fnameescape(H.work .. '/g.txt'))
local first_tab = vim.api.nvim_get_current_tabpage()
local before = {}
for _, win in ipairs(vim.api.nvim_tabpage_list_wins(first_tab)) do
  before[win] = vim.api.nvim_win_get_buf(win)
end
local plan_text = text_of(lines(12))
local id = open('sess-1', plan_text)
check('plan answers with the session id and a counter', id == 'sess-1-1', id)
check('plan opens a new tab', #vim.api.nvim_list_tabpages() == 2)
local plan_tab = vim.api.nvim_get_current_tabpage()
check('the plan tab is current', plan_tab ~= first_tab)
local same = true
for win, buf in pairs(before) do
  same = same and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf
    and vim.api.nvim_win_get_tabpage(win) == first_tab
end
check('the windows of the other tab are not touched', same and #vim.api.nvim_tabpage_list_wins(first_tab) == 2)
check('the plan tab has one window', #vim.api.nvim_tabpage_list_wins(plan_tab) == 1)
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
check('without mapped keys the winbar names the commands', vim.wo[0].winbar:find(':Walkthrough ask', 1, true) ~= nil
  and vim.wo[0].winbar:find(':Walkthrough change', 1, true) ~= nil, vim.wo[0].winbar)
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
check('errors open no tab', #vim.api.nvim_list_tabpages() == 2 and #tours.plans() == 1)

-- A second session is a review of its own, in its own tab.
local id2 = open('sess-2', 'one\ntwo')
check('another session gets its own review and tab', id2 == 'sess-2-1' and #vim.api.nvim_list_tabpages() == 3
  and #tours.plans() == 2)
check('the session id is made safe for a file name', open('a/b c:d', 'x') == 'a_b_c_d-1')
check('a plan text with carriage returns and a final newline is stored cleanly',
  vim.deep_equal(vim.fn.readfile(plans_dir .. '/a_b_c_d-1.md'), { 'x' }))
reset()

-- Annotating ------------------------------------------------------------------------------------

id = open('sess-1', plan_text)
plan_buf = vim.api.nvim_get_current_buf()
check('ask in a plan answers nothing at once', (w.ask('why twelve steps?', { 2, 2 }) or true) and #sent == 0)
local t1 = thread_of(id, 't1')
check('a question on a plan is collected, as a draft', t1 and t1.kind == 'question' and t1.state == 'draft'
  and t1.sent == 0 and t1.from == 2 and t1.to == 2)
check('change collects a change request', (w.change('merge steps 3 and 4', { 3, 4 }) or true) and #sent == 0
  and thread_of(id, 't2').kind == 'change' and thread_of(id, 't2').state == 'draft')
check('the notification names plan feedback', find('plan feedback delivers it') ~= nil)
check('both threads are drawn under their lines', vim.deep_equal(marks_rows(plan_buf), { 2, 4 }), vim.inspect(marks_rows(plan_buf)))
check('a drawn thread says that it is not sent', marks_text(plan_buf):find('not sent', 1, true) ~= nil)
reset_log()
w.send()
check('send is refused in a plan and points to feedback', find('plan feedback') ~= nil and #sent == 0
  and thread_of(id, 't1').state == 'draft', vim.inspect(log))
check('inbox does not list the plan', vim.json.decode(w.inbox()).items[1] == nil)
check('inbox with all does not list the plan either', vim.json.decode(w.inbox(true)).items[1] == nil)
w.ask('and the order?', { 2, 2 })
check('a second question on the same lines replies in the thread', #thread_of(id, 't1').messages == 2
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
check('the tab stays open', #vim.api.nvim_list_tabpages() == 2 and vim.api.nvim_buf_is_valid(plan_buf))
check('the winbar says that the feedback was sent', vim.wo[0].winbar:find('feedback sent; waiting for the revised plan', 1, true) ~= nil,
  vim.wo[0].winbar)
check('status says feedback-sent', status().plan.state == 'feedback-sent')
local r = result(id)
check('plan_result hands the feedback out', r.state == 'feedback' and type(r.message) == 'string', vim.inspect(r))
local msg = r.message
check('the message counts the items', msg:find('(3 items)', 1, true) ~= nil, msg)
check('the message numbers each item with its kind, thread and lines',
  msg:find('1. Question t1 on plan line 2:', 1, true) ~= nil
  and msg:find('2. Change request t2 on plan lines 3-4:', 1, true) ~= nil
  and msg:find('3. Change request t4 on plan lines 6-12:', 1, true) ~= nil, msg)
check('the plan lines are quoted', msg:find('   > p2\n', 1, true) ~= nil and msg:find('   > p3\n   > p4\n', 1, true) ~= nil)
check('both messages of a thread are given', msg:find('User: why twelve steps?', 1, true) ~= nil
  and msg:find('User: and the order?', 1, true) ~= nil)
check('the text of a change request is given', msg:find('User: merge steps 3 and 4', 1, true) ~= nil)
local quoted = 0
for l in vim.gsplit(msg:match('3%. Change request.-\n\n') or '', '\n') do
  if l:match('^   > ') then
    quoted = quoted + 1
  end
end
check('at most five lines are quoted', quoted == 5, quoted)
check('the rest is counted', msg:find('(2 more lines)', 1, true) ~= nil, msg)
check('the message ends with what the agent should do',
  msg:match('Answer each question and revise the plan for each change request, replying to every item with a patch '
    .. '{ "thread": "<id>", "answer": "..." } %(tour.sh %-%-patch%) before presenting the plan again%.$') ~= nil, msg)
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
check('feedback twice before the pick-up sends the annotations once', r.state == 'feedback'
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
local tabs = #vim.api.nvim_list_tabpages()
check('a second call of the same session answers the same id', open('sess-1', text_of(revised)) == id)
check('the revision opens no new tab', #vim.api.nvim_list_tabpages() == tabs and #tours.plans() == 1)
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
check('the next feedback has only what is new', msg:find('(1 item)', 1, true) ~= nil and msg:find('and the new first line?', 1, true) ~= nil
  and not msg:find('why twelve', 1, true), msg)
w.change('again', { 4, 4 })
w.plan_feedback()
msg = result(id).message
check('an annotation on rewritten text says so', msg:find('was changed after this was written', 1, true) ~= nil
  or msg:find('Change request t2', 1, true) == nil, msg)
check('an earlier answer of the agent is part of the thread', msg:find('Earlier in this thread:', 1, true) ~= nil
  and msg:find('You (agent): merged', 1, true) ~= nil, msg)
reset()

-- Approving -------------------------------------------------------------------------------------------

local home = vim.api.nvim_get_current_tabpage()
id = open('sess-1', plan_text)
plan_buf = vim.api.nvim_get_current_buf()
reset_log()
w.plan_approve()
check('approve closes the tab', #vim.api.nvim_list_tabpages() == 1 and vim.api.nvim_get_current_tabpage() == home)
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
check('approve with annotations drops them and says how many', find('plan approved; dropped 2 annotations that were still open') ~= nil,
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
vim.cmd('tabclose')
check('closing the tab leaves the plan pending', #tours.plans() == 1 and result(id).state == 'pending'
  and #vim.api.nvim_list_tabpages() == 1)
vim.cmd('Walkthrough plan')
check(':Walkthrough plan reopens the closed tab', #vim.api.nvim_list_tabpages() == 2
  and vim.api.nvim_buf_get_name(0) == plans_dir .. '/' .. id .. '.md', #vim.api.nvim_list_tabpages() .. ' ' .. vim.api.nvim_buf_get_name(0))
check('the reopened tab has its keys and bar', vim.fn.maparg('A', 'n', false, true).buffer == 1
  and vim.wo[0].winbar:find('A approve', 1, true) ~= nil)
local reopened = vim.api.nvim_get_current_tabpage()
vim.cmd('tabprevious')
vim.cmd('Walkthrough plan')
check(':Walkthrough plan goes to the open tab', vim.api.nvim_get_current_tabpage() == reopened and #vim.api.nvim_list_tabpages() == 2)
vim.cmd('Walkthrough plan nonsense')
check('an unknown argument is reported', find('plan takes') ~= nil)
vim.cmd('tabprevious')
-- Approve and feedback work from outside the tab when there is one plan.
w.ask('from far', { 1, 1 })
check('ask outside the plan is no plan thread', #(plan_of(id).steps[1].threads or {}) == 0)
vim.cmd('Walkthrough plan feedback')
check(':Walkthrough plan feedback asks when there is nothing to send', #prompts >= 1)
answer = 'text from the command'
vim.cmd('Walkthrough plan feedback')
check(':Walkthrough plan feedback sends from outside the tab', result(id).state == 'feedback')
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

id = open('sess-1', plan_text)
plan_buf = vim.api.nvim_get_current_buf()
w.ask('why?', { 3, 3 })
vim.api.nvim_feedkeys('F', 'x', false)
check('F sends the feedback', result(id).state == 'feedback')
local plan_tab_now = vim.api.nvim_get_current_tabpage()
vim.api.nvim_feedkeys('A', 'x', false)
check('A approves', #tours.plans() == 0 and result(id).state == 'approve' and #vim.api.nvim_list_tabpages() == 1)
check('A and F are not mapped outside the plan', vim.fn.maparg('A', 'n') == '' and vim.fn.maparg('F', 'n') == '')
check('the plan tab is gone', not vim.api.nvim_tabpage_is_valid(plan_tab_now))
reset()

-- The winbar names the keys that are mapped.
vim.keymap.set('n', '<leader>wa', '<Plug>(walkthrough-ask)')
id = open('sess-1', plan_text)
check('the winbar names a mapped key and a command for the other', vim.wo[0].winbar:find('<leader>wa ask', 1, true) ~= nil
  and vim.wo[0].winbar:find(':Walkthrough change', 1, true) ~= nil, vim.wo[0].winbar)
vim.keymap.set('n', '<leader>wc', '<Plug>(walkthrough-change)')
vim.cmd('doautocmd BufWinEnter')
check('the bar follows keys mapped later', vim.wo[0].winbar:find('<leader>wc change', 1, true) ~= nil, vim.wo[0].winbar)
vim.keymap.del('n', '<leader>wa')
vim.keymap.del('n', '<leader>wc')
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
check('the restored review is shown in a tab', vim.api.nvim_buf_get_name(0) == plans_dir .. '/sess-1-1.md'
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
check(':Walkthrough plan restores a saved plan after a restart', #tours.plans() == 1 and #vim.api.nvim_list_tabpages() == 2
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
  and vim.api.nvim_buf_is_valid(plan_buf) and #vim.api.nvim_list_tabpages() == 3)
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
vim.api.nvim_set_current_tabpage(vim.api.nvim_win_get_tabpage(vim.fn.win_findbuf(a_buf)[1]))
w.ask('only in a', { 1, 1 })
check('a thread goes to the plan of the buffer', #plan_of(a).steps[1].threads == 1 and #(plan_of(b).steps[1].threads or {}) == 0)
check('status reports the plan in the current buffer', status().plan.id == a)
w.plan_feedback()
check('feedback goes to the plan of the buffer', result(a).state == 'feedback' and result(b).state == 'pending')
vim.cmd('tabnew')
reset_log()
w.plan_approve()
check('approve outside a plan tab asks which one when there are several', find('several plans') ~= nil and #tours.plans() == 2)
w.plan_approve(b)
check('a plan can be approved by id', #tours.plans() == 1 and result(b).state == 'approve' and result(a).state == 'pending')
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
