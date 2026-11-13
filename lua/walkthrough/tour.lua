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
-- Kinds of comment the user can write, and their stances on a verdict.
M.comment_types = { question = true, issue = true, suggestion = true }
M.decisions = { accept = true, reject = true }
-- How deep the explanations are asked to be (see feedback.explain).
M.depths = { simpler = true, deeper = true }

-- Fields of incoming JSON. Anything else is an error, so a typo is reported
-- instead of being silently ignored.
M.step_fields = {
  file = true, title = true, total = true, from = true, to = true, diff = true,
  hunks = true, notes = true, panel = true, group = true, check = true,
}
M.note_fields = { line = true, text = true, verdict = true, detail = true, evidence = true }
M.check_fields = { question = true, answer = true, feedback = true }
M.hunk_fields = { from = true, to = true, group = true }

-- Fields only the plugin writes. Valid on stored steps, never from JSON.
-- _snap: the file's lines that the step's numbers refer to; stale: set when
-- an edit invalidated a note's line or a hunk range (see anchor.lua); seen:
-- the step has been shown to the user; comments: what the user wrote on the
-- code (the agent answers them with a patch, see apply_patches).
M.internal_step_fields = { next_note = true, _snap = true, seen = true, comments = true }
-- decision: the user's stance on the verdict ('accept' or 'reject');
-- decision_sent: the agent has been told.
M.internal_note_fields = { n = true, stale = true, decision = true, decision_sent = true }
M.internal_hunk_fields = { stale = true }
-- revealed: the user looked at the answer; reply: what the user answered;
-- reply_sent: the agent has been told.
M.internal_check_fields = { revealed = true, reply = true, reply_sent = true }
M.comment_fields = {
  id = true, from = true, to = true, type = true, text = true, answer = true,
  resolved = true, sent = true, stale = true,
}
-- What a patch may say about a comment. Creating, deleting and re-typing
-- them is the user's.
M.comment_patch_fields = { comment = true, step = true, answer = true, resolved = true }

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
  if step.total ~= nil and type(step.total) ~= 'number' then
    return fail(nil, '"total" must be a number')
  end
  if step.next_note ~= nil and not is_int(step.next_note, 1) then
    return fail(nil, '"next_note" must be an integer >= 1')
  end
  if step.seen ~= nil and type(step.seen) ~= 'boolean' then
    return fail(nil, '"seen" must be true or false')
  end
  if step.comments ~= nil then
    if type(step.comments) ~= 'table' or not vim.islist(step.comments) then
      return fail(nil, '"comments" must be a list')
    end
    local ids = {}
    for i, c in ipairs(step.comments) do
      local sub = 'comment ' .. i
      if type(c) ~= 'table' or (next(c) ~= nil and vim.islist(c)) then
        return fail(sub, 'must be an object')
      end
      local bad_c = unknown_field(c, M.comment_fields)
      if bad_c then
        return fail(sub, ('unknown comment field "%s"'):format(bad_c))
      end
      if type(c.id) ~= 'string' or not c.id:match('^c%d+$') then
        return fail(sub, '"id" must look like c1')
      end
      if ids[c.id] then
        return fail(sub, ('id %s is used twice'):format(c.id))
      end
      ids[c.id] = true
      if not is_int(c.from, 1) or not is_int(c.to, c.from) then
        return fail(sub, '"from" and "to" must be integers, 1 <= from <= to')
      end
      if not M.comment_types[c.type] then
        return fail(sub, '"type" must be question, issue or suggestion')
      end
      if type(c.text) ~= 'string' then
        return fail(sub, '"text" must be a string')
      end
      if c.answer ~= nil and not is_text(c.answer) then
        return fail(sub, '"answer" must be a string or a list of strings')
      end
      for _, k in ipairs({ 'resolved', 'sent', 'stale' }) do
        if c[k] ~= nil and type(c[k]) ~= 'boolean' then
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
  if step.panel ~= nil and not is_text(step.panel) then
    return fail(nil, '"panel" must be a string or a list of strings')
  end

  if step.check ~= nil then
    local c = step.check
    if type(c) ~= 'table' or (next(c) ~= nil and vim.islist(c)) then
      return fail('check', 'must be an object')
    end
    local bad_c = unknown_field(c, M.check_fields, opts.stored and M.internal_check_fields)
    if bad_c then
      return fail('check', ('unknown check field "%s"'):format(bad_c))
    end
    if c.question == nil then
      return fail('check', '"question" is missing')
    end
    for _, k in ipairs({ 'question', 'answer', 'feedback' }) do
      if c[k] ~= nil and not is_text(c[k]) then
        return fail('check', ('"%s" must be a string or a list of strings'):format(k))
      end
    end
    if vim.trim(M.text_of(c.question)) == '' then
      return fail('check', '"question" must not be empty')
    end
    if c.reply ~= nil and type(c.reply) ~= 'string' then
      return fail('check', '"reply" must be a string')
    end
    for _, k in ipairs({ 'revealed', 'reply_sent' }) do
      if c[k] ~= nil and type(c[k]) ~= 'boolean' then
        return fail('check', ('"%s" must be true or false'):format(k))
      end
    end
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

-- Comments ---------------------------------------------------------------------

--- The comment with this id in `steps`, the step holding it and the step's
--- index. `only` restricts the search to one step index.
function M.find_comment(steps, id, only)
  for i, step in ipairs(steps) do
    if only == nil or only == i then
      for _, c in ipairs(step.comments or {}) do
        if c.id == id then
          return c, step, i
        end
      end
    end
  end
end

--- A new comment id for tour `t` ({ steps, next_comment }): unique within
--- the tour and never used again, even after the comment was deleted.
function M.new_comment_id(t)
  local top = 0
  for _, step in ipairs(t.steps) do
    for _, c in ipairs(step.comments or {}) do
      top = math.max(top, tonumber(tostring(c.id):match('^c(%d+)$')) or 0)
    end
  end
  local n = math.max(t.next_comment or 1, top + 1)
  t.next_comment = n + 1
  return 'c' .. n
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

-- The agent answers (and may resolve) a comment of the user. Everything else
-- about a comment is the user's.
local function patch_comment(i, history, changed, p)
  if type(p.comment) ~= 'string' then
    error(('patch %d: "comment" must be a comment id such as c1'):format(i), 0)
  end
  if p.note ~= nil then
    error(('patch %d: a patch addresses a note or a comment, not both'):format(i), 0)
  end
  for key in pairs(p) do
    if not M.comment_patch_fields[key] then
      error(('patch %d: unknown comment field "%s" (an agent can only answer and resolve comments)')
        :format(i, key), 0)
    end
  end
  local only
  if p.step ~= nil then
    if not is_int(p.step, 1) then
      error(('patch %d: "step" must be an integer >= 1'):format(i), 0)
    end
    if not history[p.step] then
      error(('patch %d: there is no step %d'):format(i, p.step), 0)
    end
    only = p.step
  end
  -- Items earlier in the list may have changed a step already.
  local view = {}
  for n, step in ipairs(history) do
    view[n] = changed[n] or step
  end
  local _, _, n = M.find_comment(view, p.comment, only)
  if not n then
    error(('patch %d: there is no comment %s%s'):format(i, p.comment, only and (' in step ' .. only) or ''), 0)
  end
  changed[n] = changed[n] or vim.deepcopy(history[n])
  local c = M.find_comment(changed, p.comment, n)
  if p.answer ~= nil then
    if not is_text(p.answer) then
      error(('patch %d: "answer" must be a string or a list of strings'):format(i), 0)
    end
    c.answer = p.answer
  end
  if p.resolved ~= nil then
    if type(p.resolved) ~= 'boolean' then
      error(('patch %d: "resolved" must be true or false'):format(i), 0)
    end
    c.resolved = p.resolved
  end
end

-- Returns whether the focus moved (file, from or to touched).
local function patch_step(i, step, p)
  local moved = false
  local old_check = step.check
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
  if type(p.check) == 'table' then
    for flag in pairs(M.internal_check_fields) do
      if p.check[flag] ~= nil then
        error(('patch %d: unknown check field "%s"'):format(i, flag), 0)
      end
    end
    -- What the user did with the question stays while the question is the
    -- same; a new question starts afresh.
    if type(old_check) == 'table' and is_text(old_check.question) and is_text(p.check.question)
      and M.text_of(old_check.question) == M.text_of(p.check.question) then
      for flag in pairs(M.internal_check_fields) do
        p.check[flag] = old_check[flag]
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
--- Item `step` defaults to `default_n`. Returns changed, moved (both keyed by
--- step index) or nil and a message; `history` itself is never modified, so a
--- failing list changes nothing.
function M.apply_patches(history, default_n, patches)
  local changed, moved = {}, {}
  for i, p in ipairs(patches) do
    if type(p) ~= 'table' or vim.islist(p) and next(p) ~= nil then
      return nil, ('patch %d: must be an object'):format(i)
    end
    local ok, err = pcall(function()
      if p.comment ~= nil then
        return patch_comment(i, history, changed, p)
      end
      if p.step == nil and default_n < 1 then
        error(('patch %d: no tour is open'):format(i), 0)
      end
      local n = p.step == nil and default_n or p.step
      if not is_int(n, 1) then
        error(('patch %d: "step" must be an integer >= 1'):format(i), 0)
      end
      if not history[n] then
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
  return changed, moved
end

return M
