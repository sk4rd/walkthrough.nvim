-- The user's side of the review: comments on the code, decisions on the
-- agent's verdicts, answers to checks, and the requests to the agent that
-- come out of them (send, inbox, explain). Everything is stored on the tour,
-- so it is saved with it (store.lua) and its lines follow edits (anchor.lua).
--
-- Entry points that need the cursor (comment, decide, explain) look at the
-- window they are called from: the code window on the step's file, or the
-- panel. The wrappers in init.lua turn their errors into notifications.
local st = require('walkthrough.state')
local ui = require('walkthrough.ui')
local tour = require('walkthrough.tour')
local tours = require('walkthrough.tours')
local store = require('walkthrough.store')
local send = require('walkthrough.send')

local M = {}

local function notify(msg, level)
  vim.notify('walkthrough: ' .. msg, level or vim.log.levels.INFO)
end

local function active()
  local t = tours.active()
  local step = t and t.steps[t.pos]
  if not step then
    error('no tour open', 0)
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

-- Is the current window showing `step`'s file?
local function in_step_file(step)
  return vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf()) == abs(step)
end

-- The note the user means: in the panel, the one whose `### [n]` heading is
-- under the cursor; in the code, the first note on the cursor line.
local function note_here(step)
  if st.panel_win and vim.api.nvim_get_current_win() == st.panel_win then
    local n = ui.note_under_cursor()
    return n and tour.find_note(step, n)
  end
  if not in_step_file(step) then
    return nil
  end
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local best
  for _, note in ipairs(step.notes or {}) do
    if note.line == line and (not best or note.n < best.n) then
      best = note
    end
  end
  return best
end

local function read_lines(step, cache)
  cache[step] = cache[step] or vim.fn.readfile(step.file)
  return cache[step]
end

-- The first line of the code a message is about, trimmed and capped.
local function first_code_line(step, line, cache)
  local text = vim.trim(read_lines(step, cache)[line] or '')
  return #text > 100 and (text:sub(1, 97) .. '...') or text
end

-- Comments ------------------------------------------------------------------------

--- Comment on code of the current step. `type` is question (default), issue
--- or suggestion. The lines are, in this order: `range` ({ from, to }), the
--- selection when called from visual mode, the cursor line. Without `text`
--- the user is asked; an empty answer cancels.
function M.comment(ctype, text, range)
  ctype = (ctype == nil or ctype == '') and 'question' or ctype
  if not tour.comment_types[ctype] then
    error('comment type must be question, issue or suggestion', 0)
  end
  local t, step = active()
  local buf = vim.api.nvim_get_current_buf()
  if not in_step_file(step) then
    error("this file is not the current step's file", 0)
  end
  if vim.bo[buf].modified then
    -- The lines are those of the saved file, which is what edits are followed on.
    error('save the file first: comments are anchored to the saved file', 0)
  end
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
  from, to = math.max(1, math.min(from, to, last)), math.max(1, math.min(math.max(from, to), last))

  local function add(answer)
    answer = vim.trim(answer or '')
    if answer == '' then
      return
    end
    if not vim.tbl_contains(t.steps, step) then
      return notify('the tour changed meanwhile; the comment was not added', vim.log.levels.WARN)
    end
    -- Numbers first follow the edits made since they were written.
    pcall(tour.sync, step)
    step.comments = step.comments or {}
    local c = { id = tour.new_comment_id(t), from = from, to = to, type = ctype, text = answer }
    table.insert(step.comments, c)
    store.save()
    ui.update()
    notify(('comment %s added (%s, line %s)'):format(c.id, ctype, where(from, to)))
  end

  if text and vim.trim(text) ~= '' then
    return add(text)
  end
  vim.ui.input({ prompt = ('Your %s on line %s: '):format(ctype, where(from, to)) }, add)
end

--- Delete the comment under the cursor: on a line of the code it covers, or
--- on its `### (c1)` heading in the panel.
function M.comment_delete()
  local _, step = active()
  local id
  if st.panel_win and vim.api.nvim_get_current_win() == st.panel_win then
    id = ui.comment_under_cursor()
  elseif in_step_file(step) then
    local line = vim.api.nvim_win_get_cursor(0)[1]
    for _, c in ipairs(step.comments or {}) do
      if line >= c.from and line <= c.to then
        id = c.id
        break
      end
    end
  end
  if not id then
    return notify('no comment here')
  end
  for i, c in ipairs(step.comments) do
    if c.id == id then
      table.remove(step.comments, i)
      break
    end
  end
  store.save()
  ui.update()
  notify('comment ' .. id .. ' deleted')
end

-- Decisions -----------------------------------------------------------------------

--- The user's stance on the verdict of the note under the cursor: 'accept',
--- 'reject', or nil / 'clear' to take it back.
function M.decide(kind)
  if kind == 'clear' then
    kind = nil
  end
  if kind ~= nil and not tour.decisions[kind] then
    error('decide takes accept, reject or clear', 0)
  end
  local _, step = active()
  local note = note_here(step)
  if not note then
    return notify('no note here')
  end
  note.decision = kind
  note.decision_sent = nil
  store.save()
  ui.update()
  notify(kind and ('note [%d] %s'):format(note.n, kind == 'accept' and 'accepted' or 'rejected')
    or ('note [%d]: decision cleared'):format(note.n))
end

-- What there is to tell the agent --------------------------------------------------

-- The unsent items of tour `t`, in tour order: comments, decisions on
-- notes and replies to checks. With `all`, comments that were sent already
-- but are not resolved are included. Each item carries `mark()`.
local function collect(t, all)
  local items = {}
  for si, step in ipairs(t.steps) do
    pcall(tour.sync, step)
    local comments = vim.list_slice(step.comments or {})
    table.sort(comments, function(a, b)
      return a.from < b.from
    end)
    for _, c in ipairs(comments) do
      if not c.resolved and (all or not c.sent) then
        table.insert(items, {
          kind = 'comment', si = si, step = step, c = c,
          mark = function() c.sent = true end,
        })
      end
    end
    for _, note in ipairs(step.notes or {}) do
      if note.decision and not note.decision_sent then
        table.insert(items, {
          kind = 'decision', si = si, step = step, note = note,
          mark = function() note.decision_sent = true end,
        })
      end
    end
    local check = step.check
    if check and check.reply and not check.reply_sent then
      table.insert(items, {
        kind = 'check', si = si, step = step, check = check,
        mark = function() check.reply_sent = true end,
      })
    end
  end
  return items
end

local function expectation(item)
  if item.kind == 'comment' then
    local c = item.c
    if c.type == 'question' then
      return ('Answer it with a patch: { "comment": "%s", "answer": "..." }'):format(c.id)
    end
    return ('Reply with a patch { "comment": "%s", "answer": "..." }; if you agree, change the code first and add'
      .. ' "resolved": true.'):format(c.id)
  elseif item.kind == 'decision' then
    local n = item.note
    if n.decision == 'reject' then
      return 'Leave the code as it is and acknowledge; do not change the verdict.'
    end
    if n.verdict == 'simplify' or n.verdict == 'remove' then
      return ('Apply it, then patch the note to done: { "step": %d, "note": %d, "verdict": "done" }'):format(item.si, n.n)
    end
    return 'Nothing to change; acknowledge.'
  end
  return ('Compare it with your answer and patch your feedback into the check (send the question and answer'
    .. ' again with it): { "step": %d, "check": { "question": "...", "answer": "...", "feedback": "..." } }'):format(item.si)
end

-- The items as one markdown message for the agent, numbered, with the
-- references (`msg.refs`) for the senders that attach files.
local function build_message(t, items)
  local cache = {}
  local lines = {
    ('Walkthrough: feedback from the user on %s (%d item%s). Answer by patching the tour in place.')
      :format(t.group and ('group "' .. t.group .. '"') or 'the tour', #items, #items == 1 and '' or 's'),
  }
  local refs = {}
  for i, item in ipairs(items) do
    local step = item.step
    local file = short(step)
    table.insert(lines, '')
    if item.kind == 'comment' then
      local c = item.c
      table.insert(lines, ('%d. Comment %s (%s) at %s:%s, step %d'):format(i, c.id, c.type, file, where(c.from, c.to), item.si))
      table.insert(lines, '   Code: `' .. first_code_line(step, c.from, cache) .. '`')
      if c.stale then
        table.insert(lines, '   (The code on these lines was changed after the comment was written.)')
      end
      table.insert(lines, '   User: ' .. table.concat(tour.to_lines(c.text), ' / '))
      if c.answer then
        table.insert(lines, '   Your earlier answer: ' .. tour.text_of(c.answer):gsub('\n', ' / '))
      end
      table.insert(refs, { file = abs(step), from = c.from, to = c.to })
    elseif item.kind == 'decision' then
      local n = item.note
      table.insert(lines, ('%d. Decision on note [%d] at %s:%d, step %d%s'):format(
        i, n.n, file, n.line, item.si, n.verdict and (', your verdict: ' .. n.verdict) or ''))
      table.insert(lines, '   Code: `' .. first_code_line(step, n.line, cache) .. '`')
      table.insert(lines, '   Note: ' .. tour.text_of(n.text):gsub('\n', ' / '))
      table.insert(lines, '   User: ' .. (n.decision == 'accept' and 'accepted' or 'rejected') .. ' your verdict.')
      table.insert(refs, { file = abs(step), from = n.line, to = n.line })
    else
      local check = item.check
      table.insert(lines, ('%d. Answer to the check of step %d (%s)'):format(i, item.si, file))
      table.insert(lines, '   Question: ' .. tour.text_of(check.question):gsub('\n', ' / '))
      if check.answer then
        table.insert(lines, '   Your answer: ' .. tour.text_of(check.answer):gsub('\n', ' / '))
      end
      table.insert(lines, '   User: ' .. check.reply:gsub('\n', ' / '))
      table.insert(refs, { file = abs(step), from = step.from, to = step.to or step.from })
    end
    table.insert(lines, '   Expected: ' .. expectation(item))
  end
  return { text = table.concat(lines, '\n'), refs = refs }
end

--- Send every unsent item of the active tour to the agent as one message.
--- Items count as sent only when the sender did not raise.
function M.send()
  local t = tours.active()
  if not t then
    error('no tour open', 0)
  end
  local items = collect(t, false)
  if #items == 0 then
    return notify('nothing to send: no new comment, decision or answer')
  end
  local ok, err = pcall(send.send, build_message(t, items))
  if not ok then
    error(err, 0)
  end
  for _, item in ipairs(items) do
    item.mark()
  end
  store.save()
  notify(('sent %d item%s'):format(#items, #items == 1 and '' or 's'))
end

--- The same items as JSON, for an agent that pulls instead of being pushed
--- to: { "group", "items": [...] }. They count as sent afterwards. With `all`
--- the comments that were sent but are not resolved are listed too.
--- "ok"-style socket entry point: never raises.
function M.inbox(all)
  local ok, res = pcall(function()
    local t = tours.active()
    if not t then
      return vim.json.encode({ items = {} })
    end
    all = all == true or all == 1 or all == 'all' or all == 'true'
    local items = collect(t, all)
    local out = {}
    for _, item in ipairs(items) do
      local step = item.step
      local file = abs(step)
      if item.kind == 'comment' then
        local c = item.c
        table.insert(out, {
          kind = 'comment', id = c.id, type = c.type, step = item.si, file = file,
          from = c.from, to = c.to, text = c.text,
        })
      elseif item.kind == 'decision' then
        local n = item.note
        table.insert(out, {
          kind = 'decision', step = item.si, note = n.n, verdict = n.verdict, decision = n.decision,
          file = file, line = n.line, text = tour.text_of(n.text),
        })
      else
        table.insert(out, {
          kind = 'check', step = item.si, question = tour.text_of(item.check.question), reply = item.check.reply,
        })
      end
      item.mark()
    end
    store.save()
    return vim.json.encode({ group = t.group, items = out })
  end)
  return ok and res or ('error: ' .. tour.clean_error(res))
end

-- Explaining ----------------------------------------------------------------------

local levels = {
  simpler = 'plainer words; name each concept and say what it does; give one concrete example from this code;'
    .. ' assume no knowledge.',
  deeper = 'say why it is built this way, what the alternatives are, which edge cases matter and how it connects'
    .. ' to the rest of the code.',
}

--- Ask the agent to rewrite an explanation 'simpler' or 'deeper': the note
--- under the cursor if there is one, else the whole step. The level is kept
--- on the tour (`depth`) for the steps that follow.
function M.explain(level)
  if not levels[level] then
    error('explain takes simpler or deeper', 0)
  end
  local t, step = active()
  local note = note_here(step)
  local pos = t.pos
  local lines = {
    ('Walkthrough: explain this %s.'):format(level),
    ('Step %d/%d: "%s" (%s)'):format(pos, #t.steps, step.title or short(step), short(step)),
  }
  local refs, patch
  if note then
    table.insert(lines, ('Target: note [%d] at %s:%d%s'):format(
      note.n, short(step), note.line, note.verdict and (', verdict: ' .. note.verdict) or ''))
    vim.list_extend(lines, { 'Current explanation:', tour.text_of(note.detail or note.text) })
    refs = { { file = abs(step), from = note.line, to = note.line } }
    patch = ('{ "step": %d, "note": %d, "detail": "<the new explanation>" }'):format(pos, note.n)
  else
    local from, to = step.from, step.to or step.from
    table.insert(lines, 'Target: the explanation of the whole step' .. (from and (' (focus %s:%s)'):format(short(step), where(from, to)) or ''))
    vim.list_extend(lines, { 'Current explanation:', step.panel and tour.text_of(step.panel) or '(none yet)' })
    refs = { { file = abs(step), from = from, to = to } }
    patch = ('{ "step": %d, "panel": "<the new explanation>" }'):format(pos)
  end
  vim.list_extend(lines, {
    '',
    'Rewrite this explanation in place with a patch, keeping the same step and note numbers:',
    '  ' .. patch,
    ('Level, %s: %s'):format(level, levels[level]),
    ('The user wants %s explanations from now on: write the following steps at this level.'):format(level),
  })
  send.send({ text = table.concat(lines, '\n'), refs = refs })
  t.depth = level
  store.save()
  notify(('asked for a %s explanation; the tour\'s depth is now "%s"'):format(level, level))
end

-- Checks --------------------------------------------------------------------------

--- 'reveal' shows the answer of the current step's check; 'answer' asks the
--- user for their own answer and queues it for `send`.
function M.check(action)
  if action ~= 'reveal' and action ~= 'answer' then
    error('check takes reveal or answer', 0)
  end
  local t, step = active()
  local check = step.check
  if not check then
    error('this step has no check', 0)
  end
  if action == 'reveal' then
    if not check.answer then
      error('this check has no answer to reveal', 0)
    end
    check.revealed = true
    store.save()
    ui.update()
    return
  end
  vim.ui.input({ prompt = 'Your answer: ', default = check.reply }, function(text)
    text = vim.trim(text or '')
    if text == '' then
      return
    end
    if not vim.tbl_contains(t.steps, step) or step.check ~= check then
      return notify('the step changed meanwhile; the answer was not saved', vim.log.levels.WARN)
    end
    check.reply = text
    check.reply_sent = nil
    store.save()
    ui.update()
    notify('answer saved; it goes to the agent with the next send')
  end)
end

return M
