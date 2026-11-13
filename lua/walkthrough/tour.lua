-- The tour as data: validation, normalisation and patching. Pure logic with
-- no windows or buffers, so it can be tested without an editor UI. (It reads
-- files, to check that a step's file and note lines exist.)
local anchor = require('walkthrough.anchor')

local M = {}

-- Verdicts a note may carry.
M.verdicts = { keep = true, simplify = true, remove = true, done = true, moved = true }

-- How a note's claim was established: the agent ran something that shows it,
-- inferred it from reading the code, or it is a judgement.
M.evidence = { ran = true, read = true, opinion = true }
-- What a thread is (a question to answer, or a change request that gets a
-- proposal), where it stands, and the user's stances on a verdict.
M.thread_kinds = { question = true, change = true }
M.thread_states = {
  draft = true, waiting = true, answered = true, proposed = true, accepted = true, declined = true, done = true,
}
M.decisions = { accept = true, reject = true }
-- How deep the explanations are asked to be (see feedback.explain).
M.depths = { simpler = true, deeper = true }

-- Fields of incoming JSON. Anything else is an error, so a typo is reported
-- instead of being silently ignored.
M.step_fields = {
  file = true, title = true, from = true, to = true, diff = true, hunks = true, notes = true, group = true,
}
M.note_fields = { line = true, text = true, verdict = true, detail = true, evidence = true }
M.hunk_fields = { from = true, to = true, group = true }

-- Fields only the plugin writes. Valid on stored steps, never from JSON.
-- _snap: the file's lines that the step's numbers refer to; stale: set when
-- an edit invalidated a note's line or a hunk range (see anchor.lua); seen:
-- the step has been shown to the user; threads: what the user wrote on the
-- code and the replies under it (the agent answers with a patch, see
-- apply_patches).
M.internal_step_fields = { next_note = true, _snap = true, seen = true, threads = true }
-- decision: the user's stance on the verdict ('accept' or 'reject');
-- decision_sent: the agent has been told.
M.internal_note_fields = { n = true, stale = true, decision = true, decision_sent = true }
M.internal_hunk_fields = { stale = true }
-- sent: how many messages the agent has been given; decision_sent: it has
-- been told the user's decision on a proposal.
M.thread_fields = {
  id = true, kind = true, from = true, to = true, messages = true, state = true, sent = true, stale = true,
  decision_sent = true,
}
M.message_fields = { by = true, text = true, proposal = true }
-- What a patch may say about a thread. Creating, deleting and deciding
-- them is the user's.
M.thread_patch_fields = { thread = true, step = true, answer = true, proposal = true, replace = true, done = true }
-- A patch can also deliver the commit message the agent was asked for
-- (commit.lua): `commit_message`, for the tour of `group` (default: the
-- active tour). The message is kept on the tour as `commit_message`, a field
-- only the plugin writes.
M.commit_patch_fields = { commit_message = true, group = true }

local function is_int(v, min)
  return type(v) == 'number' and v == math.floor(v) and v >= (min or -math.huge)
end

-- A string, or a list of strings (one per line).
local function is_text(v)
  if type(v) == 'string' then
    return true
  end
  if type(v) ~= 'table' or not vim.islist(v) then
    return false
  end
  for _, s in ipairs(v) do
    if type(s) ~= 'string' then
      return false
    end
  end
  return true
end

local function unknown_field(t, allowed, internal)
  local bad = {}
  for k in pairs(t) do
    if not allowed[k] and not (internal and internal[k]) then
      table.insert(bad, tostring(k))
    end
  end
  table.sort(bad)
  return bad[1]
end

function M.to_lines(text)
  if type(text) == 'table' then
    return text
  end
  return vim.split(text, '\n', { plain = true })
end

--- A text field (string or list of lines) as one string.
function M.text_of(text)
  if text == nil then
    return ''
  end
  return table.concat(M.to_lines(text), '\n')
end

--- A short, one-line message for the caller of a socket entry point: no
--- plugin path from a stack position, no second line.
function M.clean_error(err)
  local msg = tostring(err):gsub('^.-lua/walkthrough/[%w_]+%.lua:%d+: ', '')
  return (vim.split(msg, '\n', { plain = true })[1])
end

function M.check_file(step)
  if type(step.file) ~= 'string' then
    error('step needs a "file" string', 0)
  end
  -- Without this, a typo would silently open a new empty buffer.
  if vim.fn.filereadable(step.file) == 0 then
    error('cannot read file: ' .. step.file, 0)
  end
end

--- Check one step. `opts.index` names it in messages, `opts.stored` also
--- accepts the plugin's own bookkeeping fields. Returns true, or nil and a
--- message such as `step 2, note 1: "line" is missing`.
function M.validate_step(step, opts)
  opts = opts or {}
  -- A lone step has no number to name it by.
  local where = opts.index and ('step ' .. opts.index) or nil
  local function fail(sub, msg)
    local prefix = table.concat(vim.tbl_filter(function(x) return x end, { where, sub }), ', ')
    return nil, (prefix ~= '' and (prefix .. ': ') or '') .. msg
  end

  if type(step) ~= 'table' or (next(step) ~= nil and vim.islist(step)) then
    return fail(nil, 'must be an object')
  end
  local bad = unknown_field(step, M.step_fields, opts.stored and M.internal_step_fields)
  if bad then
    return fail(nil, ('unknown step field "%s"'):format(bad))
  end

  if step.file == nil then
    return fail(nil, '"file" is missing')
  end
  if type(step.file) ~= 'string' then
    return fail(nil, '"file" must be a string')
  end
  if vim.fn.filereadable(step.file) == 0 then
    return fail(nil, 'cannot read file: ' .. step.file)
  end
  for _, k in ipairs({ 'title', 'group' }) do
    if step[k] ~= nil and type(step[k]) ~= 'string' then
      return fail(nil, ('"%s" must be a string'):format(k))
    end
  end
  if step.next_note ~= nil and not is_int(step.next_note, 1) then
    return fail(nil, '"next_note" must be an integer >= 1')
  end
  if step.seen ~= nil and type(step.seen) ~= 'boolean' then
    return fail(nil, '"seen" must be true or false')
  end
  if step.threads ~= nil then
    if type(step.threads) ~= 'table' or not vim.islist(step.threads) then
      return fail(nil, '"threads" must be a list')
    end
    local ids = {}
    for i, th in ipairs(step.threads) do
      local sub = 'thread ' .. i
      if type(th) ~= 'table' or (next(th) ~= nil and vim.islist(th)) then
        return fail(sub, 'must be an object')
      end
      local bad_t = unknown_field(th, M.thread_fields)
      if bad_t then
        return fail(sub, ('unknown thread field "%s"'):format(bad_t))
      end
      if type(th.id) ~= 'string' or not th.id:match('^t%d+$') then
        return fail(sub, '"id" must look like t1')
      end
      if ids[th.id] then
        return fail(sub, ('id %s is used twice'):format(th.id))
      end
      ids[th.id] = true
      if not is_int(th.from, 1) or not is_int(th.to, th.from) then
        return fail(sub, '"from" and "to" must be integers, 1 <= from <= to')
      end
      if not M.thread_kinds[th.kind] then
        return fail(sub, '"kind" must be question or change')
      end
      if not M.thread_states[th.state] then
        return fail(sub, '"state" is not a thread state')
      end
      if type(th.messages) ~= 'table' or not vim.islist(th.messages) or #th.messages == 0 then
        return fail(sub, '"messages" must be a list with at least one message')
      end
      for j, m in ipairs(th.messages) do
        local msub = ('%s, message %d'):format(sub, j)
        if type(m) ~= 'table' or (next(m) ~= nil and vim.islist(m)) then
          return fail(msub, 'must be an object')
        end
        local bad_m = unknown_field(m, M.message_fields)
        if bad_m then
          return fail(msub, ('unknown message field "%s"'):format(bad_m))
        end
        if m.by ~= 'user' and m.by ~= 'agent' then
          return fail(msub, '"by" must be user or agent')
        end
        if type(m.text) ~= 'string' then
          return fail(msub, '"text" must be a string')
        end
        if m.proposal ~= nil and type(m.proposal) ~= 'boolean' then
          return fail(msub, '"proposal" must be true or false')
        end
      end
      if not is_int(th.sent, 0) or th.sent > #th.messages then
        return fail(sub, '"sent" must be an integer between 0 and the number of messages')
      end
      for _, k in ipairs({ 'stale', 'decision_sent' }) do
        if th[k] ~= nil and type(th[k]) ~= 'boolean' then
          return fail(sub, ('"%s" must be true or false'):format(k))
        end
      end
    end
  end
  if step._snap ~= nil and not (type(step._snap) == 'table' and vim.islist(step._snap) and is_text(step._snap)) then
    return fail(nil, '"_snap" must be a list of strings')
  end

  if step.from ~= nil and not is_int(step.from, 1) then
    return fail(nil, '"from" must be an integer >= 1')
  end
  if step.to ~= nil then
    if not is_int(step.to, 1) then
      return fail(nil, '"to" must be an integer >= 1')
    end
    if step.from == nil then
      return fail(nil, '"to" needs "from"')
    end
    if step.from > step.to then
      return fail(nil, '"from" must not be after "to"')
    end
  end
  if step.diff ~= nil and type(step.diff) ~= 'boolean' and type(step.diff) ~= 'string' then
    return fail(nil, '"diff" must be true, false or a git ref')
  end

  if step.hunks ~= nil then
    if type(step.hunks) ~= 'table' or not vim.islist(step.hunks) then
      return fail(nil, '"hunks" must be a list')
    end
    for i, h in ipairs(step.hunks) do
      local sub = 'hunk ' .. i
      if type(h) ~= 'table' or (next(h) ~= nil and vim.islist(h)) then
        return fail(sub, 'must be an object')
      end
      local bad_h = unknown_field(h, M.hunk_fields, opts.stored and M.internal_hunk_fields)
      if bad_h then
        return fail(sub, ('unknown hunk field "%s"'):format(bad_h))
      end
      if h.from == nil then
        return fail(sub, '"from" is missing')
      end
      if not is_int(h.from, 1) then
        return fail(sub, '"from" must be an integer >= 1')
      end
      if h.to ~= nil and not is_int(h.to, h.from) then
        return fail(sub, '"to" must be an integer >= "from"')
      end
      if h.group ~= nil and type(h.group) ~= 'string' then
        return fail(sub, '"group" must be a string')
      end
      if h.stale ~= nil and type(h.stale) ~= 'boolean' then
        return fail(sub, '"stale" must be true or false')
      end
      for j = 1, i - 1 do
        local o = step.hunks[j]
        -- The ends of a stale range are a best guess after an edit and may
        -- reach into a neighbour; only ranges the agent wrote must not overlap.
        if not h.stale and not o.stale and h.from <= (o.to or o.from) and o.from <= (h.to or h.from) then
          return fail(sub, ('overlaps hunk %d'):format(j))
        end
      end
    end
  end

  if step.notes ~= nil then
    if type(step.notes) ~= 'table' or not vim.islist(step.notes) then
      return fail(nil, '"notes" must be a list')
    end
    local last, seen
    for i, note in ipairs(step.notes) do
      local sub = 'note ' .. i
      if type(note) ~= 'table' or (next(note) ~= nil and vim.islist(note)) then
        return fail(sub, 'must be an object')
      end
      local bad_n = unknown_field(note, M.note_fields, opts.stored and M.internal_note_fields)
      if bad_n then
        return fail(sub, ('unknown note field "%s"'):format(bad_n))
      end
      if note.line == nil then
        return fail(sub, '"line" is missing')
      end
      if not is_int(note.line, 1) then
        return fail(sub, '"line" must be an integer >= 1')
      end
      last = last or #vim.fn.readfile(step.file)
      if note.line > last then
        return fail(sub, ('"line" %d is past the end of the file (%d lines)'):format(note.line, last))
      end
      for _, k in ipairs({ 'text', 'detail' }) do
        if note[k] ~= nil and not is_text(note[k]) then
          return fail(sub, ('"%s" must be a string or a list of strings'):format(k))
        end
      end
      if note.stale ~= nil and type(note.stale) ~= 'boolean' then
        return fail(sub, '"stale" must be true or false')
      end
      if note.verdict ~= nil and not M.verdicts[note.verdict] then
        local names = vim.tbl_keys(M.verdicts)
        table.sort(names)
        return fail(sub, ('"verdict" must be one of %s'):format(table.concat(names, ', ')))
      end
      if note.evidence ~= nil and not M.evidence[note.evidence] then
        local names = vim.tbl_keys(M.evidence)
        table.sort(names)
        return fail(sub, ('"evidence" must be one of %s'):format(table.concat(names, ', ')))
      end
      if note.decision ~= nil and not M.decisions[note.decision] then
        return fail(sub, '"decision" must be accept or reject')
      end
      if note.decision_sent ~= nil and type(note.decision_sent) ~= 'boolean' then
        return fail(sub, '"decision_sent" must be true or false')
      end
      if note.n ~= nil then
        if not is_int(note.n, 1) then
          return fail(sub, '"n" must be an integer >= 1')
        end
        seen = seen or {}
        if seen[note.n] then
          return fail(sub, ('number %d is used twice'):format(note.n))
        end
        seen[note.n] = true
      end
    end
  end
  return true
end

-- Anchors ----------------------------------------------------------------------

--- Remember the file as it is now: the lines the step's numbers refer to.
function M.snapshot(step)
  step._snap = vim.fn.readfile(step.file)
end

--- Move the step's numbers along with the edits made to its file since the
--- last sync (the file on disk is the reference). Returns whether anything
--- moved. Raises when the file cannot be read.
function M.sync(step)
  if vim.fn.filereadable(step.file) == 0 then
    error('cannot read file: ' .. step.file, 0)
  end
  return anchor.sync_step(step, vim.fn.readfile(step.file))
end

-- Notes ------------------------------------------------------------------------

--- Give every note without a number the next free one. Numbers never change
--- and are never reused, so "note [3]" keeps meaning the same note.
function M.number_notes(step)
  local top = 0
  for _, note in ipairs(step.notes or {}) do
    top = math.max(top, note.n or 0)
  end
  local nxt = math.max(step.next_note or 1, top + 1)
  for _, note in ipairs(step.notes or {}) do
    if not note.n then
      note.n, nxt = nxt, nxt + 1
    end
  end
  step.next_note = nxt
end

--- The note with number `n`, and its index in `step.notes`.
function M.find_note(step, n)
  for i, note in ipairs(step.notes or {}) do
    if note.n == n then
      return note, i
    end
  end
end

-- Threads ----------------------------------------------------------------------

--- The thread with this id in `steps`, the step holding it and the step's
--- index. `only` restricts the search to one step index.
function M.find_thread(steps, id, only)
  for i, step in ipairs(steps) do
    if only == nil or only == i then
      for _, th in ipairs(step.threads or {}) do
        if th.id == id then
          return th, step, i
        end
      end
    end
  end
end

--- A new thread id for tour `t` ({ steps, next_thread }): unique within the
--- tour and never used again, even after the thread was deleted. The plugin
--- itself uses tours.new_thread_id, which keeps ids unique across all tours
--- of a repository.
function M.new_thread_id(t)
  local top = 0
  for _, step in ipairs(t.steps) do
    for _, th in ipairs(step.threads or {}) do
      top = math.max(top, tonumber(tostring(th.id):match('^t(%d+)$')) or 0)
    end
  end
  local n = math.max(t.next_thread or 1, top + 1)
  t.next_thread = n + 1
  return 't' .. n
end

--- The index of the first message of the user that the agent has not been
--- given yet, or nil.
function M.pending_index(th)
  for i = (th.sent or 0) + 1, #th.messages do
    if th.messages[i].by == 'user' then
      return i
    end
  end
end

--- The last message of `th` written by `by` ('user' or 'agent'), and its index.
function M.last_message(th, by)
  for i = #th.messages, 1, -1 do
    if th.messages[i].by == by then
      return th.messages[i], i
    end
  end
end

--- A thread from a comment of an older state file. A question stays one;
--- issues and suggestions asked for a change. The text is the first message,
--- the answer the second; the state follows from what happened to it.
function M.thread_from_comment(c)
  local messages = { { by = 'user', text = c.text } }
  if c.answer ~= nil then
    table.insert(messages, { by = 'agent', text = M.text_of(c.answer) })
  end
  local state
  if c.resolved then
    state = 'done'
  elseif c.answer ~= nil then
    state = 'answered'
  elseif c.sent then
    state = 'waiting'
  else
    state = 'draft'
  end
  return {
    id = 't' .. c.id:sub(2), kind = c.type == 'question' and 'question' or 'change', from = c.from, to = c.to,
    messages = messages, state = state, sent = (c.answer ~= nil) and #messages or (c.sent and 1 or 0), stale = c.stale,
  }
end

--- Ranges of the reviewed group in `step`, as { from, to }. Ranges an edit
--- has cut into are left out when `skip_stale` is set.
function M.group_ranges(step, skip_stale)
  local ranges = {}
  for _, h in ipairs(step.hunks or {}) do
    if (h.group == nil or h.group == step.group) and not (skip_stale and h.stale) then
      table.insert(ranges, { from = h.from, to = h.to or h.from })
    end
  end
  return ranges
end

--- Bring a validated step into its stored shape. `group` is the tour's.
function M.prepare_step(step, group)
  step.group = step.group or group
  -- A step that lists hunks is about changes, so it always gets the
  -- overlay; without it, staging would show no ✓ at all.
  if step.hunks and step.diff == nil then
    step.diff = true
  end
  M.number_notes(step)
  M.snapshot(step)
  return step
end

--- Validate and prepare a whole tour (`data.steps`). Nothing is shown here.
--- Returns { steps, group, start } or nil and a message.
function M.prepare_tour(data)
  if data.group ~= nil and type(data.group) ~= 'string' then
    return nil, '"group" must be a string'
  end
  if data.start ~= nil and not is_int(data.start, 1) then
    return nil, '"start" must be an integer >= 1'
  end
  if type(data.steps) ~= 'table' or not vim.islist(data.steps) then
    return nil, '"steps" must be a list'
  end
  if #data.steps == 0 then
    return nil, '"steps" is empty'
  end
  -- Check every step up front, so a typo in step 5 is reported now rather
  -- than when the user reaches it.
  for i, s in ipairs(data.steps) do
    local ok, err = M.validate_step(s, { index = i })
    if not ok then
      return nil, err
    end
  end
  for _, s in ipairs(data.steps) do
    M.prepare_step(s, data.group)
  end
  local start = math.max(1, math.min(data.start or 1, #data.steps))
  return { steps = data.steps, group = data.group, start = start }
end

-- Patching ---------------------------------------------------------------------

local function check_names(i, names, allowed, kind)
  if type(names) ~= 'table' or not vim.islist(names) then
    error(('patch %d: "unset" must be a list of field names'):format(i), 0)
  end
  for _, name in ipairs(names) do
    if not allowed[name] then
      error(('patch %d: cannot unset unknown %s field "%s"'):format(i, kind, tostring(name)), 0)
    end
  end
end

local function patch_note(i, n, step, p)
  M.number_notes(step)
  local k = p.note
  if not is_int(k, 1) then
    error(('patch %d: "note" must be an integer >= 1'):format(i), 0)
  end
  local note, idx = M.find_note(step, k)
  if p.remove ~= nil and type(p.remove) ~= 'boolean' then
    error(('patch %d: "remove" must be true or false'):format(i), 0)
  end
  if p.remove then
    if not note then
      error(('patch %d: step %d has no note %d'):format(i, n, k), 0)
    end
    table.remove(step.notes, idx)
    return
  end
  if not note then
    if k ~= step.next_note or p.line == nil then
      error(('patch %d: step %d has no note %d (a new note must be number %d and have "line")')
        :format(i, n, k, step.next_note), 0)
    end
    note = { n = k }
    step.notes = step.notes or {}
    table.insert(step.notes, note)
    step.next_note = k + 1
  end
  for key, v in pairs(p) do
    if key ~= 'step' and key ~= 'note' and key ~= 'unset' and key ~= 'remove' then
      if not M.note_fields[key] then
        error(('patch %d: unknown note field "%s"'):format(i, key), 0)
      end
      note[key] = v
    end
  end
  -- The agent states where the note is now.
  if p.line ~= nil then
    note.stale = nil
  end
  if p.unset ~= nil then
    check_names(i, p.unset, M.note_fields, 'note')
    for _, name in ipairs(p.unset) do
      note[name] = nil
    end
  end
end

-- The agent answers a thread of the user, proposes a change in it, rewrites
-- its last message or closes it. Everything else about a thread is the
-- user's.
local function patch_thread(i, history, changed, p, limit)
  if type(p.thread) ~= 'string' then
    error(('patch %d: "thread" must be a thread id such as t1'):format(i), 0)
  end
  if p.note ~= nil then
    error(('patch %d: a patch addresses a note or a thread, not both'):format(i), 0)
  end
  for key in pairs(p) do
    if not M.thread_patch_fields[key] then
      error(('patch %d: unknown thread field "%s" (an agent can only answer, propose, replace and close threads)')
        :format(i, key), 0)
    end
  end
  local only
  if p.step ~= nil then
    if not is_int(p.step, 1) then
      error(('patch %d: "step" must be an integer >= 1'):format(i), 0)
    end
    if not history[p.step] or p.step > limit then
      error(('patch %d: there is no step %d'):format(i, p.step), 0)
    end
    only = p.step
  end
  for _, key in ipairs({ 'proposal', 'replace', 'done' }) do
    if p[key] ~= nil and type(p[key]) ~= 'boolean' then
      error(('patch %d: "%s" must be true or false'):format(i, key), 0)
    end
  end
  if p.answer ~= nil then
    if not is_text(p.answer) then
      error(('patch %d: "answer" must be a string or a list of strings'):format(i), 0)
    end
    if vim.trim(M.text_of(p.answer)) == '' then
      error(('patch %d: "answer" is empty'):format(i), 0)
    end
  end
  if p.answer == nil and (p.proposal or p.replace) then
    error(('patch %d: "%s" needs "answer"'):format(i, p.proposal and 'proposal' or 'replace'), 0)
  end
  if p.answer == nil and not p.done then
    error(('patch %d: a thread patch needs "answer" or "done"'):format(i), 0)
  end
  if p.done and p.proposal then
    error(('patch %d: "done" and "proposal" cannot go together'):format(i), 0)
  end
  if p.replace and (p.done or p.proposal) then
    error(('patch %d: "replace" cannot be combined with "done" or "proposal"'):format(i), 0)
  end
  -- Items earlier in the list may have changed a step already.
  local view = {}
  for n, step in ipairs(history) do
    view[n] = changed[n] or step
  end
  local _, _, n = M.find_thread(view, p.thread, only)
  if not n then
    error(('patch %d: there is no thread %s%s'):format(i, p.thread, only and (' in step ' .. only) or ''), 0)
  end
  changed[n] = changed[n] or vim.deepcopy(history[n])
  -- `changed` is keyed by step index and has holes: look in the step itself.
  local th
  for _, x in ipairs(changed[n].threads or {}) do
    if x.id == p.thread then
      th = x
    end
  end
  if p.replace then
    local last = M.last_message(th, 'agent')
    if not last then
      error(('patch %d: thread %s has no message of the agent to replace'):format(i, p.thread), 0)
    end
    last.text = M.text_of(p.answer)
    return
  end
  local pending = M.pending_index(th)
  if p.answer ~= nil then
    table.insert(th.messages, { by = 'agent', text = M.text_of(p.answer), proposal = p.proposal or nil })
    th.state = p.proposal and 'proposed' or 'answered'
  end
  -- What the user wrote before this answer is answered by it; a message of
  -- the user still waiting to be sent keeps its place.
  if not pending then
    th.sent = #th.messages
  end
  if p.done then
    th.state = 'done'
  end
end

-- The agent's commit message for a tour. Only checked here (and collected in
-- `commits`): the tour it goes to is the caller's to find, once the whole list
-- is known to be valid.
local function patch_commit(i, p, commits)
  for key in pairs(p) do
    if not M.commit_patch_fields[key] then
      error(('patch %d: unknown commit message field "%s" (it has only "commit_message" and "group")')
        :format(i, tostring(key)), 0)
    end
  end
  if not is_text(p.commit_message) then
    error(('patch %d: "commit_message" must be a string or a list of strings'):format(i), 0)
  end
  local text = vim.trim(M.text_of(p.commit_message))
  if text == '' then
    error(('patch %d: "commit_message" is empty'):format(i), 0)
  end
  if p.group ~= nil and type(p.group) ~= 'string' then
    error(('patch %d: "group" must be a string'):format(i), 0)
  end
  table.insert(commits, { i = i, group = p.group, text = text })
end

-- Returns whether the focus moved (file, from or to touched).
local function patch_step(i, step, p)
  local moved = false
  for key, v in pairs(p) do
    if key ~= 'step' and key ~= 'unset' then
      if not M.step_fields[key] then
        error(('patch %d: unknown step field "%s"'):format(i, key), 0)
      end
      step[key] = v
      moved = moved or key == 'file' or key == 'from' or key == 'to'
    end
  end
  if p.unset ~= nil then
    check_names(i, p.unset, M.step_fields, 'step')
    for _, name in ipairs(p.unset) do
      step[name] = nil
      moved = moved or name == 'file' or name == 'from' or name == 'to'
    end
  end
  -- The plugin's flags are not for the agent to set.
  local guarded = {
    hunks = { 'stale' }, notes = { 'stale', 'decision', 'decision_sent' },
  }
  for _, kind in ipairs({ 'hunks', 'notes' }) do
    for _, item in ipairs(type(p[kind]) == 'table' and p[kind] or {}) do
      for _, flag in ipairs(guarded[kind]) do
        if type(item) == 'table' and item[flag] ~= nil then
          error(('patch %d: unknown %s field "%s"'):format(i, kind == 'hunks' and 'hunk' or 'note', flag), 0)
        end
      end
    end
  end
  if p.notes ~= nil then
    -- A replaced list is a new set of notes: number them from 1 again.
    for _, note in ipairs(type(p.notes) == 'table' and p.notes or {}) do
      if type(note) == 'table' then
        note.n = nil
      end
    end
    step.next_note = nil
    if type(p.notes) == 'table' and vim.islist(p.notes) then
      M.number_notes(step)
    end
  end
  if step.hunks and step.diff == nil then
    step.diff = true
  end
  return moved
end

--- Apply a list of patch items to deep copies of the steps in `history`.
--- Item `step` defaults to `default_n`. Only the first `limit` steps (default
--- all) can be named by number; a thread patch without `step` finds its
--- thread in the whole of `history`, which is how threads of other tours are
--- reached. Returns changed, moved (both keyed by step index) and `commits`
--- (the commit messages the list delivers, `{ i, group, text }`, for the
--- caller to store), or nil and a message; `history` itself is never modified,
--- so a failing list changes nothing.
function M.apply_patches(history, default_n, patches, limit)
  limit = limit or #history
  local changed, moved, commits = {}, {}, {}
  for i, p in ipairs(patches) do
    if type(p) ~= 'table' or vim.islist(p) and next(p) ~= nil then
      return nil, ('patch %d: must be an object'):format(i)
    end
    local ok, err = pcall(function()
      if p.commit_message ~= nil then
        return patch_commit(i, p, commits)
      end
      if p.thread ~= nil then
        return patch_thread(i, history, changed, p, limit)
      end
      if p.step == nil and default_n < 1 then
        error(('patch %d: no map is open'):format(i), 0)
      end
      local n = p.step == nil and default_n or p.step
      if not is_int(n, 1) then
        error(('patch %d: "step" must be an integer >= 1'):format(i), 0)
      end
      if not history[n] or n > limit then
        error(('patch %d: there is no step %d'):format(i, n), 0)
      end
      changed[n] = changed[n] or vim.deepcopy(history[n])
      if p.note ~= nil then
        patch_note(i, n, changed[n], p)
      else
        if patch_step(i, changed[n], p) then
          moved[n] = true
        end
      end
    end)
    if not ok then
      return nil, tostring(err)
    end
  end
  for n, step in pairs(changed) do
    local ok, err = M.validate_step(step, { index = n, stored = true })
    if not ok then
      return nil, err
    end
  end
  -- The agent's numbers refer to the file as it is on disk right now.
  for _, step in pairs(changed) do
    M.snapshot(step)
  end
  return changed, moved, commits
end

return M
