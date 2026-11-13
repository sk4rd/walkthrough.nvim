-- The user's side of the review: threads on the code (questions and change
-- requests, with the replies under them), decisions on the agent's
-- proposals and findings, and the requests to the agent that come out of
-- them (ask, change, send, inbox, explain). Everything is stored on the
-- tour, so it is saved with it (store.lua) and its lines follow edits
-- (anchor.lua).
--
-- A question is sent at once. A change request is collected until `send`,
-- because the user usually writes several. A decision on a proposal or a
-- finding is collected too: it can be changed or taken back until `send`
-- delivers it, together with the change requests and the replies. What could
-- not be delivered stays in the thread and goes out with the next `send`.
--
-- Entry points that need the cursor (ask, change, decide, explain, thread)
-- work in the current window on any file: the file is found among the steps
-- of the loaded tours (tours.entries), and a file that no tour lists gets an
-- entry in the tour `Other files`, made on demand. The shown step is not
-- touched. The wrappers in init.lua turn their errors into notifications.
local st = require('walkthrough.state')
local ui = require('walkthrough.ui')
local tour = require('walkthrough.tour')
local tours = require('walkthrough.tours')
local store = require('walkthrough.store')
local send = require('walkthrough.send')
local compact = require('walkthrough.compact')
local commit = require('walkthrough.commit')
local request = require('walkthrough.request')
local input = require('walkthrough.input')

local M = {}

--- The kinds of item `inbox` lists: the kinds of thread, a decision on a
--- proposal or a finding, a request for a commit message and a request for
--- the map. The documents name every one (tests/docs_spec.lua).
M.inbox_kinds = vim.tbl_extend('error', tour.thread_kinds, { decision = true, commit = true, map = true })

local function notify(msg, level)
  vim.notify('walkthrough: ' .. msg, level or vim.log.levels.INFO)
end

-- The name a tour goes by in messages to the agent: its group, or `Other
-- files`; nil for the unnamed tour.
local function group_name(t)
  return t.extra and tours.OTHER or t.group
end

local function active()
  local t = tours.active()
  local step = t and t.steps[t.pos]
  if not step then
    error('no review open', 0)
  end
  return t, step
end

local function abs(step)
  return vim.fn.fnamemodify(step.file, ':p')
end

local function short(step)
  return vim.fn.fnamemodify(step.file, ':~:.')
end

local function where(from, to)
  return to > from and ('%d-%d'):format(from, to) or tostring(from)
end

-- The file of the current buffer, if it is one a thread can be about: a
-- normal buffer with a name. Nil otherwise.
local function file_of(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == '' or vim.bo[buf].buftype ~= '' then
    return nil
  end
  return vim.fn.fnamemodify(name, ':p')
end

-- Saved (the repository of `root`, else the active tour's), redrawn, and the
-- map, an open thread float and the threads on other buffers told.
local function changed(root)
  store.save(root)
  ui.update()
end

-- The tours "the repository" means for a send: those of the file in the
-- current window when a loaded tour lists it, else of the active tour, else
-- all of them.
local function scope()
  local buf = vim.api.nvim_get_current_buf()
  local file = file_of(buf)
  local e = file and tours.entries(file)[1]
  if e and not e.t.plan then
    return tours.in_root(e.t.root)
  end
  return tours.scope()
end

-- The plan review (plan.lua) the current buffer shows, else nil. In a plan
-- both kinds of thread are collected, because the agent is waiting in a
-- hook; what goes out is `plan feedback`, not `send`.
local function plan_here()
  local file = file_of(vim.api.nvim_get_current_buf())
  local e = file and tours.entries(file)[1]
  return e and e.t.plan and e.t or nil
end

-- Threads and notes ------------------------------------------------------------------

local function finished(th)
  return th.state == 'done' or th.state == 'declined'
end

-- The threads of `step` that cover a line of `from`..`to`, the ones still
-- open first, then by place.
local function threads_at(step, from, to)
  local out = {}
  for _, th in ipairs(step.threads or {}) do
    if th.from <= to and th.to >= from then
      table.insert(out, th)
    end
  end
  table.sort(out, function(a, b)
    if finished(a) ~= finished(b) then
      return finished(b)
    end
    if a.from ~= b.from then
      return a.from < b.from
    end
    return a.id < b.id
  end)
  return out
end

-- The notes of `step` on lines `from`..`to`, in number order.
local function notes_at(step, from, to)
  local out = {}
  for _, note in ipairs(step.notes or {}) do
    if note.line >= from and note.line <= to then
      table.insert(out, note)
    end
  end
  table.sort(out, function(a, b)
    return a.n < b.n
  end)
  return out
end

--- What the user means by the cursor line: on a file that a loaded tour
--- lists, the entry with the thread or the note on that line (else the first
--- entry of the file); elsewhere (the map, a file in no tour) the shown step
--- of the active tour, with no thread. `{ t, si, step, thread, note }`;
--- raises without any of them.
function M.here()
  -- In the compact view the cursor row stands for a line of an entry's file.
  local info = compact.info_of(vim.api.nvim_get_current_buf())
  if info then
    local meta = info.view.rows[vim.api.nvim_win_get_cursor(0)[1]]
    local step = meta and meta.si and info.t.steps[meta.si]
    if step then
      local line = meta.new
      local th = line and threads_at(step, line, line)[1]
      local note = line and notes_at(step, line, line)[1]
      return { t = info.t, si = meta.si, step = step, thread = th, note = note }
    end
  end
  local file = file_of(vim.api.nvim_get_current_buf())
  local entries = file and tours.entries(file) or {}
  if #entries > 0 then
    local line = vim.api.nvim_win_get_cursor(0)[1]
    for _, e in ipairs(entries) do
      local th, note = threads_at(e.step, line, line)[1], notes_at(e.step, line, line)[1]
      if th or note then
        return { t = e.t, si = e.si, step = e.step, thread = th, note = note }
      end
    end
    local e = entries[1]
    return { t = e.t, si = e.si, step = e.step }
  end
  local t, step = active()
  return { t = t, si = t.pos, step = step }
end

-- Items -----------------------------------------------------------------------------
--
-- What goes to the agent: { kind = 'thread' | 'decision', si, step, thread |
-- note, mark() }. `mark` records the delivery.

local function step_index(t, step)
  for i, s in ipairs(t.steps) do
    if s == step then
      return i
    end
  end
end

local function thread_item(t, si, step, th)
  return {
    kind = 'thread', t = t, si = si, step = step, thread = th,
    mark = function()
      th.sent = #th.messages
      th.state = 'waiting'
    end,
  }
end

-- A thread becomes accepted or declined only now that the agent is told.
local function decision_item(t, si, step, x)
  return {
    kind = 'decision', t = t, si = si, step = step, thread = x.id and x or nil, note = x.n and x or nil,
    mark = function()
      x.decision_sent = true
      if x.id then
        x.state = tour.thread_decision(x) == 'accept' and 'accepted' or 'declined'
      end
    end,
  }
end

-- Messages and what is expected ------------------------------------------------------

local function squash(text, cap)
  text = tour.text_of(text):gsub('%s*\n%s*', ' / ')
  return (#text > cap and (text:sub(1, cap - 3) .. '...') or text)
end

-- The text the user wrote as it was written: its lines kept, the lines after
-- the first indented under the label, the whole capped.
local function written(text, cap, indent)
  text = vim.trim(tour.text_of(text))
  if #text > cap then
    text = text:sub(1, cap - 3) .. '...'
  end
  return (text:gsub('\n', '\n' .. indent))
end

-- Up to three lines of the code on `from`..`to`, trimmed and capped.
local function code_lines(step, from, to, cache)
  cache[step] = cache[step] or vim.fn.readfile(step.file)
  local out = {}
  for line = from, math.min(to, from + 2) do
    local text = vim.trim(cache[step][line] or '')
    table.insert(out, #text > 100 and (text:sub(1, 97) .. '...') or text)
  end
  return out
end

local kind_label = { question = 'Question', change = 'Change request' }

-- Whether the last message of the agent before message `first` of `th` is a
-- proposal: the user then answers it.
local function answers_proposal(th, first)
  for i = first - 1, 1, -1 do
    if th.messages[i].by == 'agent' then
      return th.messages[i].proposal == true
    end
  end
  return false
end

-- One sentence of what is expected, with the exact patch form.
local function expectation(item)
  local th = item.thread
  if item.kind == 'thread' then
    local d, sent = tour.thread_decision(th)
    if d == 'accept' and sent then
      -- A reply written after the acceptance: the proposal still stands.
      return ('Your proposal in this thread was accepted: apply it, taking this message into account, then report'
        .. ' with a patch: { "thread": "%s", "answer": "<what you changed>", "done": true }'):format(th.id)
    end
    if th.kind == 'question' then
      return ('Answer it without changing any code, with a patch: { "thread": "%s", "answer": "..." }'):format(th.id)
    end
    if answers_proposal(th, tour.pending_index(th) or (#th.messages + 1)) then
      return ('The user asks you to revise your proposal: reply with a new proposal, as a patch:'
        .. ' { "thread": "%s", "answer": "<the new proposal>", "proposal": true }. Do not edit any code.'):format(th.id)
    end
    return ('Do not edit any code yet: reply with a proposal of what you would change, as a patch:'
      .. ' { "thread": "%s", "answer": "<the proposal>", "proposal": true }'):format(th.id)
  end
  if th then
    if tour.thread_decision(th) == 'accept' then
      return ('The user accepted your proposal: apply it now, then report with a patch:'
        .. ' { "thread": "%s", "answer": "<what you changed>", "done": true }'):format(th.id)
    end
    return 'The user declined your proposal: leave the code as it is; no patch is needed.'
  end
  local n = item.note
  if n.decision == 'reject' then
    return 'Leave the code as it is and acknowledge; do not change the verdict.'
  end
  if (n.verdict == 'simplify' or n.verdict == 'remove') and item.t ~= tours.active() then
    -- A patch with "step" and "note" reaches the tour on screen only.
    return 'Apply it, then tell the user what you changed. (This note is in another commit than the one on screen,'
      .. ' so it cannot be patched to done from here.)'
  end
  if n.verdict == 'simplify' or n.verdict == 'remove' then
    return ('Apply it, then patch the note to done: { "step": %d, "note": %d, "verdict": "done" }'):format(item.si, n.n)
  end
  return 'Nothing to change; acknowledge.'
end

-- The messages of `th` before message `upto`, one short line each.
local function conversation(th, upto)
  local out = {}
  for i = 1, upto - 1 do
    local m = th.messages[i]
    table.insert(out, ('     %s%s: %s'):format(m.by == 'user' and 'User' or 'You (agent)',
      m.proposal and ' (proposal)' or '', squash(m.text, 300)))
  end
  return out
end

-- Where an item is, for its line in the message: the step (and, when the
-- message spans several tours, the group) of a change, or `Other files`.
local function place(item, tour_of_item, many)
  if tour_of_item.extra then
    return ', ' .. tours.OTHER
  end
  local out = ', step ' .. item.si
  if many and tour_of_item.group then
    out = out .. (', commit "%s"'):format(tour_of_item.group)
  end
  return out
end

--- The items as one markdown message for the agent, numbered, with the
--- references (`msg.refs`) for the senders that attach files. The same
--- format serves one item and a batch. The items may come from several tours
--- (`item.t`, else `t`): each then names its group, or `Other files`.
function M.build_message(t, items)
  local cache = {}
  local distinct, order = {}, {}
  for _, item in ipairs(items) do
    local it = item.t or t
    if not distinct[it] then
      distinct[it] = true
      table.insert(order, it)
    end
  end
  local many = #order > 1
  local only = order[1] or t
  local subject
  if many then
    subject = 'the commits of this repository'
  elseif only.extra then
    subject = 'files in no map ("' .. tours.OTHER .. '")'
  else
    subject = only.group and ('commit "' .. only.group .. '"') or 'the map'
  end
  local lines = {
    ('Walkthrough: feedback from the user on %s (%d item%s). Answer by patching the map in place.')
      :format(subject, #items, #items == 1 and '' or 's'),
  }
  local refs = {}
  for i, item in ipairs(items) do
    local step, th, n = item.step, item.thread, item.note
    local it = item.t or t
    local file = short(step)
    local from, to
    table.insert(lines, '')
    if th then
      from, to = th.from, th.to
      if item.kind == 'thread' then
        table.insert(lines, ('%d. %s %s at %s:%s%s'):format(i, kind_label[th.kind], th.id, file, where(from, to), place(item, it, many)))
      else
        table.insert(lines, ('%d. Decision on your proposal in thread %s (%s) at %s:%s%s: the user %s it.'):format(
          i, th.id, th.kind, file, where(from, to), place(item, it, many),
          tour.thread_decision(th) == 'accept' and 'accepted' or 'declined'))
      end
    else
      from, to = n.line, n.line
      table.insert(lines, ('%d. Decision on finding [%d] at %s:%d%s%s'):format(
        i, n.n, file, n.line, place(item, it, many), n.verdict and (', your verdict: ' .. n.verdict) or ''))
    end
    table.insert(lines, '   Code:')
    for _, l in ipairs(code_lines(step, from, to, cache)) do
      table.insert(lines, '     ' .. l)
    end
    if th and th.stale then
      table.insert(lines, '   (The code on these lines was changed after the thread was started.)')
    end
    -- A finding on these lines is part of what the user is looking at.
    for _, note in ipairs(th and notes_at(step, from, to) or { n }) do
      table.insert(lines, ('   Finding [%d]%s: %s'):format(
        note.n, note.verdict and (' (verdict: ' .. note.verdict .. ')') or '', squash(note.text, 300)))
      if note.detail then
        table.insert(lines, '   Detail: ' .. squash(note.detail, 600))
      end
    end
    if th then
      -- A thread item carries the messages from its first undelivered one.
      local first = item.kind == 'thread' and tour.pending_index(th) or (#th.messages + 1)
      first = first or (#th.messages + 1)
      if first > 1 then
        table.insert(lines, '   Conversation so far:')
        vim.list_extend(lines, conversation(th, first))
      end
      for j = first, #th.messages do
        if th.messages[j].by == 'user' then
          table.insert(lines, '   User: ' .. written(th.messages[j].text, 1000, '         '))
        end
      end
    else
      table.insert(lines, '   User: ' .. (n.decision == 'accept' and 'accepted' or 'rejected') .. ' your verdict.')
    end
    table.insert(lines, '   Expected: ' .. expectation(item))
    table.insert(refs, { file = abs(step), from = from, to = to })
  end
  return { text = table.concat(lines, '\n'), refs = refs }
end

-- What there is to tell the agent ----------------------------------------------------

-- The items of tour `t` that were not delivered yet, in tour order: threads
-- with a message of the user the agent has not been given, decisions on
-- proposals and decisions on notes. With `all`, threads the agent was given
-- and has not answered yet are included.
local function collect(t, all)
  local items = {}
  for si, step in ipairs(t.steps) do
    pcall(tour.sync, step)
    local threads = vim.list_slice(step.threads or {})
    table.sort(threads, function(a, b)
      if a.from ~= b.from then
        return a.from < b.from
      end
      return a.id < b.id
    end)
    for _, th in ipairs(threads) do
      if tour.unsent_decision(th) then
        table.insert(items, decision_item(t, si, step, th))
      end
      if not finished(th) and (tour.pending_index(th) or (all and th.state == 'waiting')) then
        table.insert(items, thread_item(t, si, step, th))
      end
    end
    for _, note in ipairs(step.notes or {}) do
      if note.decision and not note.decision_sent then
        table.insert(items, decision_item(t, si, step, note))
      end
    end
  end
  return items
end

-- The items of all of `list` (tours), the tours of a change in order, then
-- `Other files`.
local function collect_all(list, all)
  local items = {}
  for _, t in ipairs(list) do
    vim.list_extend(items, collect(t, all))
  end
  return items
end

-- Save the repositories the items belong to.
local function save_roots(items)
  local done = {}
  for _, item in ipairs(items) do
    local key = item.t.root or ''
    if not done[key] then
      done[key] = true
      store.save(item.t.root)
    end
  end
end

-- Hand the items to the agent and mark them delivered. Raises when the
-- sender does; nothing is marked then.
local function deliver(items)
  local ok, err = pcall(function()
    send.send(M.build_message(items[1].t, items))
  end)
  if not ok then
    error(err, 0)
  end
  for _, item in ipairs(items) do
    item.mark()
  end
  save_roots(items)
end

-- Deliver at once. A failure is not an error: the items stay undelivered
-- (a thread stays a draft) and the user is told they go out with `send`.
local function deliver_now(items, what)
  local ok, err = pcall(deliver, items)
  changed(items[1].t.root)
  if ok then
    notify(what .. ' sent')
    return true
  end
  notify(('%s was not sent (%s); it is kept for send'):format(what, tour.clean_error(err)), vim.log.levels.WARN)
  return false
end

--- Send every undelivered item of the repository (all its tours) to the
--- agent as one message. Items count as sent only when the sender did not
--- raise.
function M.send()
  if plan_here() then
    return notify('a plan is answered with feedback, not send: use :Walkthrough plan feedback', vim.log.levels.WARN)
  end
  local list = scope()
  if #list == 0 then
    error('no review open', 0)
  end
  local items = collect_all(list, false)
  if #items == 0 then
    return notify('nothing to send: no new thread message or decision')
  end
  deliver(items)
  changed(items[1].t.root)
  notify(('sent %d item%s'):format(#items, #items == 1 and '' or 's'))
end

--- The same items as JSON, for an agent that pulls instead of being pushed
--- to: { "group", "items": [...] }, the items of all tours of the repository,
--- each with its tour's `group` (`Other files` for files in no tour). They
--- count as delivered afterwards (a request for a commit message, `{ "kind":
--- "commit", "group", "stat" }`, is listed until it is answered, and a request
--- for the map, `{ "kind": "map", "root", "base", "files" }`, until the map
--- arrives). With `all` the threads that wait for an answer are listed too. "ok"-style socket entry point: never raises, and
--- works with no step shown.
function M.inbox(all)
  local ok, res = pcall(function()
    local list = scope()
    if #list == 0 then
      return vim.json.encode({ items = {} })
    end
    all = all == true or all == 1 or all == 'all' or all == 'true'
    local out = {}
    local items = collect_all(list, all)
    for _, item in ipairs(items) do
      local step, th = item.step, item.thread
      local file = abs(step)
      local count = #out + 1
      if item.kind == 'thread' then
        local messages = {}
        for i, m in ipairs(th.messages) do
          messages[i] = { by = m.by, text = m.text, proposal = m.proposal }
        end
        table.insert(out, {
          kind = th.kind, id = th.id, step = item.si, file = file, from = th.from, to = th.to,
          state = th.state, messages = messages, new = (th.sent or 0) + 1, stale = th.stale,
        })
      elseif th then
        local last = tour.last_message(th, 'agent')
        local d = tour.thread_decision(th)
        table.insert(out, {
          kind = 'decision', id = th.id, step = item.si, file = file, from = th.from, to = th.to,
          decision = d, state = d == 'accept' and 'accepted' or 'declined', text = last and last.text,
        })
      else
        local n = item.note
        table.insert(out, {
          kind = 'decision', step = item.si, note = n.n, verdict = n.verdict, decision = n.decision,
          file = file, line = n.line, text = tour.text_of(n.text),
        })
      end
      out[count].group = group_name(item.t)
      item.mark()
    end
    save_roots(items)
    -- A request for a commit message stays listed until it is answered or the
    -- dialog is closed: it is not marked as delivered.
    local roots = {}
    for _, t in ipairs(list) do
      roots[t.root] = true
    end
    for _, req in ipairs(commit.pending(roots)) do
      table.insert(out, { kind = 'commit', group = req.group, stat = req.stat })
    end
    -- The same for a request for the map.
    vim.list_extend(out, request.pending(roots))
    local active = tours.active()
    return vim.json.encode({ group = active and active.group or nil, items = out })
  end)
  return ok and res or ('error: ' .. tour.clean_error(res))
end

-- Writing ---------------------------------------------------------------------------

--- Add `text` as a message of the user to `th` (of `step`, in tour `t`). A
--- question is sent at once, a change request is collected until `send`.
--- Returns whether it went out. Writing in a thread
--- - that has a proposal asks for another one: a decision marked and not sent
---   is cleared (one that was sent stands: the agent is applying it);
--- - that is closed (declined or done) continues it: it is open again, and
---   its old decision is no longer the state of affairs.
function M.reply(t, step, th, text)
  text = vim.trim(text or '')
  if text == '' then
    return false
  end
  local decision, sent = tour.thread_decision(th)
  local closed = finished(th)
  table.insert(th.messages, { by = 'user', text = text })
  if closed or (decision and not sent) then
    th.decision, th.decision_sent = nil, nil
  elseif decision then
    -- A thread stored before decisions were collected has it as its state only.
    th.decision, th.decision_sent = decision, true
  end
  th.state = 'draft'
  if th.kind == 'question' and not t.plan then
    return deliver_now({ thread_item(t, step_index(t, step), step, th) }, 'question ' .. th.id)
  end
  changed(t.root)
  notify(('reply added to %s; %s delivers it'):format(th.id, t.plan and 'plan feedback' or 'send'))
  return false
end

-- The lines the user means: `range` ({ from, to }), the selection when
-- called from visual mode, the cursor line.
local function lines_of(buf, range)
  local from, to
  if range then
    from, to = range[1], range[2]
  elseif vim.fn.mode():match('^[vV\22]') then
    from, to = vim.fn.line('v'), vim.fn.line('.')
    vim.cmd('normal! \27')
  else
    from = vim.api.nvim_win_get_cursor(0)[1]
    to = from
  end
  local last = vim.api.nvim_buf_line_count(buf)
  return math.max(1, math.min(from, to, last)), math.max(1, math.min(math.max(from, to), last))
end

local function id_number(th)
  return tonumber(tostring(th.id):match('^t(%d+)$')) or 0
end

-- The thread that writing on `from`..`to` goes into, with its entry: an open
-- thread of the entries on those lines, else the newest closed one (declined
-- or done), which writing continues. Nil when there is none.
local function thread_for(entries, from, to)
  local closed, closed_e
  for _, e in ipairs(entries) do
    for _, th in ipairs(threads_at(e.step, from, to)) do
      if not finished(th) then
        return e, th
      end
      if not closed or id_number(th) > id_number(closed) then
        closed, closed_e = th, e
      end
    end
  end
  return closed_e, closed
end

-- Write on the lines of the current buffer: a reply in the thread there (an
-- open one, else a closed one, which is continued), else a new thread of `kind`. The buffer is any file, in or out of a
-- repository, in any window; nothing is switched. Without `text` the user is
-- asked; an empty answer cancels.
local function write(kind, text, range)
  local buf = vim.api.nvim_get_current_buf()
  -- In the compact view the rows are translated to lines of the entry's file.
  local info = compact.info_of(buf)
  local file, from, to, picked
  if info then
    local r1, r2 = lines_of(buf, range)
    picked = compact.resolve(info, r1, r2)
    file = abs(picked.step)
    from, to = picked.from, picked.to
    if compact.modified_buf(file) then
      error('save the file first: threads are anchored to the saved file', 0)
    end
  else
    file = file_of(buf)
    if not file then
      error('threads go on files: this buffer is not one', 0)
    end
    if vim.bo[buf].modified then
      -- The lines are those of the saved file, which is what edits are followed on.
      error('save the file first: threads are anchored to the saved file', 0)
    end
  end
  if vim.fn.filereadable(file) == 0 then
    error('save the file first: it does not exist on disk yet', 0)
  end
  if not info then
    from, to = lines_of(buf, range)
  end

  local function add(answer)
    answer = vim.trim(answer or '')
    if answer == '' then
      return
    end
    -- The prompt may have been open for a while.
    if not vim.api.nvim_buf_is_valid(buf) or compact.modified_buf(file) or (not info and vim.bo[buf].modified)
      or vim.fn.filereadable(file) == 0 then
      return notify('the file changed meanwhile; the thread was not added', vim.log.levels.WARN)
    end
    local root = store.root_of(file)
    -- A session may be starting: the repository's saved tours come first.
    store.merge_saved(root)
    local entries = tours.entries(file, root)
    -- Numbers first follow the edits made since they were written.
    for _, e in ipairs(entries) do
      pcall(tour.sync, e.step)
    end
    local e, th = thread_for(entries, from, to)
    if th then
      return M.reply(e.t, e.step, th, answer)
    end
    -- The entry the cursor is in, else the first of the file; a file no tour
    -- lists gets an entry in `Other files`.
    for _, x in ipairs(picked and entries or {}) do
      e = e or (x.step == picked.step and x or nil)
    end
    e = e or entries[1] or tours.extra_entry(root, file)
    local t, step = e.t, e.step
    step.threads = step.threads or {}
    local th = {
      id = tours.new_thread_id(t), kind = kind, from = from, to = to,
      messages = { { by = 'user', text = answer } }, state = 'draft', sent = 0,
    }
    table.insert(step.threads, th)
    -- A question is sent at once, except in a plan: the agent is waiting in
    -- its hook and gets everything together, with `plan feedback`.
    if kind == 'question' and not t.plan then
      return deliver_now({ thread_item(t, e.si, step, th) }, 'question ' .. th.id)
    end
    changed(t.root)
    notify(('%s %s added (line %s); %s delivers it'):format(
      kind == 'question' and 'question' or 'change request', th.id, where(from, to),
      t.plan and 'plan feedback' or 'send'))
  end

  if text and vim.trim(text) ~= '' then
    return add(text)
  end
  local _, open = thread_for(tours.entries(file), from, to)
  local title, prompt
  if open then
    title = ('Reply in %s'):format(open.id)
    prompt = ('%s on line %s: '):format(title, where(from, to))
  else
    local what = kind == 'question' and 'Question' or 'Change request'
    title = ('%s on %s:%s'):format(what, vim.fn.fnamemodify(file, ':~:.'), where(from, to))
    prompt = ('Your %s on line %s: '):format(kind == 'question' and 'question' or 'change request', where(from, to))
  end
  input.ask({ title = title, prompt = prompt }, add)
end

--- Ask a question about the code: on `range` ({ from, to }), the selection
--- or the cursor line. It is sent at once. If the lines carry a thread of the
--- user, the text is a reply in it, whatever its kind (see M.reply).
function M.ask(text, range)
  return write('question', text, range)
end

--- Request a change of the code on those lines. It is collected: `send`
--- delivers it, and the agent answers with a proposal.
function M.change(text, range)
  return write('change', text, range)
end

--- Remove `th` from `step`. An entry of `Other files` left without threads
--- goes too, and so does that tour when it has no entry left.
function M.delete_thread(step, th)
  local owner
  for _, t in ipairs(st.tours) do
    if vim.tbl_contains(t.steps, step) then
      owner = t
    end
  end
  for i, x in ipairs(step.threads or {}) do
    if x == th then
      table.remove(step.threads, i)
      break
    end
  end
  if owner and owner.extra and #step.threads == 0 then
    for i, x in ipairs(owner.steps) do
      if x == step then
        table.remove(owner.steps, i)
        break
      end
    end
    owner.pos = math.max(1, math.min(owner.pos or 1, #owner.steps))
    if st.drawn and st.drawn.step == step then
      ui.clear()
    end
    if #owner.steps == 0 then
      tours.remove(owner)
    end
  end
  changed(owner and owner.root)
  notify('thread ' .. th.id .. ' deleted')
end

--- Delete the thread under the cursor: on a line of the code it covers.
function M.thread_delete()
  local target = M.here()
  if not target.thread then
    return notify('no thread here')
  end
  M.delete_thread(target.step, target.thread)
end

-- Decisions -----------------------------------------------------------------------

--- Decide on what `target` (see `here`) holds. Nothing is sent: the decision
--- is marked, and `send` delivers it with the other items. Until then it can
--- be changed (the other key) or taken back (`kind` nil). The proposal of a
--- thread stays `proposed` until `send` makes it accepted or declined; a note
--- carries the decision itself. After `send` the decision stands: to go on,
--- the user writes on the line, which continues the thread.
function M.decide_on(target, kind)
  local t, th, note = target.t, target.thread, target.note
  if t.plan then
    return notify('a plan has no proposals to decide: say it in the feedback', vim.log.levels.WARN)
  end
  if th and th.state == 'proposed' then
    if kind == nil then
      if not th.decision then
        return notify('thread ' .. th.id .. ': nothing to take back')
      end
      th.decision, th.decision_sent = nil, nil
      changed(t.root)
      return notify('thread ' .. th.id .. ': decision cleared')
    end
    th.decision, th.decision_sent = kind, nil
    changed(t.root)
    return notify(('thread %s: %s, not sent; send delivers it'):format(
      th.id, kind == 'accept' and 'accepted' or 'declined'))
  end
  if th and not note and tour.thread_decision(th) and not tour.unsent_decision(th) then
    return notify(('thread %s: the decision was sent; write on the line to continue the thread'):format(th.id),
      vim.log.levels.WARN)
  end
  if note then
    if note.decision and note.decision_sent then
      return notify(('finding [%d]: the decision was sent; write on the line to go on'):format(note.n),
        vim.log.levels.WARN)
    end
    if not kind and not note.decision then
      return notify(('finding [%d]: nothing to take back'):format(note.n))
    end
    note.decision, note.decision_sent = kind, nil
    changed(t.root)
    if not kind then
      return notify(('finding [%d]: decision cleared'):format(note.n))
    end
    return notify(('finding [%d]: %s, not sent; send delivers it'):format(
      note.n, kind == 'accept' and 'accepted' or 'rejected'))
  end
  notify('nothing to decide here')
end

--- The user's stance on what is under the cursor: 'accept', 'reject', or
--- nil / 'clear' to take it back. A proposal in a thread and a finding (note)
--- can be decided; the decision is delivered by `send`.
function M.decide(kind)
  if kind == 'clear' then
    kind = nil
  end
  if kind ~= nil and not tour.decisions[kind] then
    error('decide takes accept, reject or clear', 0)
  end
  M.decide_on(M.here(), kind)
end

-- Explaining ----------------------------------------------------------------------

local levels = {
  simpler = 'plainer words; name each concept and say what it does; give one concrete example from this code;'
    .. ' assume no knowledge.',
  deeper = 'say why it is built this way, what the alternatives are, which edge cases matter and how it connects'
    .. ' to the rest of the code.',
}

--- Ask the agent to rewrite the last message of the agent in the thread of
--- `target` (see `here`), or the detail of its note, 'simpler' or 'deeper'.
--- It is sent at once. The level is kept on the tour (`depth`) for the
--- answers that follow.
function M.explain_on(target, level)
  if not levels[level] then
    error('explain takes simpler or deeper', 0)
  end
  local t, step, th, note = target.t, target.step, target.thread, target.note
  if t.plan then
    return notify('a plan has no answers to explain: ask again in a thread', vim.log.levels.WARN)
  end
  -- A thread is rewritten when it has something of the agent to rewrite.
  if th and not tour.last_message(th, 'agent') then
    th = nil
    if not note then
      return notify('there is no answer in this thread to explain yet')
    end
  end
  if not th and not note then
    return notify('put the cursor on a thread or a note to explain it simpler or deeper')
  end
  local lines = {
    ('Walkthrough: explain this %s.'):format(level),
    t.extra and ('%s: %s'):format(tours.OTHER, short(step))
      or ('Entry %d/%d: "%s" (%s)'):format(target.si, #t.steps, step.title or short(step), short(step)),
  }
  local ref
  if th then
    vim.list_extend(lines, {
      ('Target: your last message in thread %s (%s) at %s:%s'):format(th.id, th.kind, short(step), where(th.from, th.to)),
      'Current text:',
      tour.last_message(th, 'agent').text,
      '',
      'Rewrite it with a patch, which replaces that message:',
      '  ' .. ('{ "thread": "%s", "answer": "<the new text>", "replace": true }'):format(th.id),
    })
    ref = { file = abs(step), from = th.from, to = th.to }
  else
    vim.list_extend(lines, {
      ('Target: finding [%d] at %s:%d%s'):format(
        note.n, short(step), note.line, note.verdict and (', verdict: ' .. note.verdict) or ''),
      'Current explanation:',
      tour.text_of(note.detail or note.text),
      '',
      'Rewrite this explanation in place with a patch, keeping the same step and note numbers:',
      '  ' .. ('{ "step": %d, "note": %d, "detail": "<the new explanation>" }'):format(target.si, note.n),
    })
    ref = { file = abs(step), from = note.line, to = note.line }
  end
  vim.list_extend(lines, {
    ('Level, %s: %s'):format(level, levels[level]),
    ('The user wants %s explanations from now on: write the following answers at this level.'):format(level),
  })
  send.send({ text = table.concat(lines, '\n'), refs = { ref } })
  t.depth = level
  store.save(t.root)
  notify(('asked for a %s explanation; later answers are written at that level'):format(level))
end

--- `explain_on` for the thread or note under the cursor.
function M.explain(level)
  if not levels[level] then
    error('explain takes simpler or deeper', 0)
  end
  M.explain_on(M.here(), level)
end

return M
