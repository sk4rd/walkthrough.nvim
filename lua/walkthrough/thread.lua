-- A thread or a note in full, in a centered float: the code it is about and
-- every message, as plain text. The keys act on what the float shows:
-- reply (also in a closed thread, which it continues), accept, decline, undo
-- the decision, simpler, deeper, delete (threads only), close.
-- The float draws itself again when its thread changes while it is open (a
-- patch arrives, a reply is added); ui.update tells it.
local st = require('walkthrough.state')
local tour = require('walkthrough.tour')
local ui = require('walkthrough.ui')
local feedback = require('walkthrough.feedback')
local input = require('walkthrough.input')

local M = {}

-- The open float: { win, buf, t, si, thread = <id>, note = <number> }. The
-- step and the thread are looked up again on every use, because a patch
-- replaces the step.
local float

local function short(step)
  return vim.fn.fnamemodify(step.file, ':~:.')
end

local function where(from, to)
  return to > from and ('%d-%d'):format(from, to) or tostring(from)
end

-- The step, and the thread or note, that the float is about now. Nil when
-- they are gone.
local function resolve()
  if not float or not vim.tbl_contains(st.tours, float.t) then
    return nil
  end
  if float.thread then
    -- An entry of `Other files` that went away moves the others up: look for
    -- the thread in the whole tour.
    local th, step, si = tour.find_thread(float.t.steps, float.thread)
    if not th then
      return nil
    end
    float.si = si
    return { t = float.t, si = si, step = step, thread = th }
  end
  local step = float.t.steps[float.si]
  if not step then
    return nil
  end
  local target = { t = float.t, si = float.si, step = step }
  target.note = tour.find_note(step, float.note)
  return target.note and target or nil
end

--- The float's text for `target` ({ t, si, step, thread | note }): a heading,
--- then the code, then every message. Plain lines.
function M.lines(target)
  local step, th, note = target.step, target.thread, target.note
  local out = {}
  local function text(prefix, body)
    local indent = string.rep(' ', #prefix)
    for i, l in ipairs(tour.to_lines(body)) do
      table.insert(out, (i == 1 and prefix or indent) .. l)
    end
  end
  if th then
    -- A decision that was not sent says so; otherwise the state is the word.
    local state = tour.unsent_decision(th) and ('(' .. ui.thread_label(th) .. ')') or th.state
    table.insert(out, ('%s · %s · %s:%s · %s'):format(th.id, th.kind, short(step), where(th.from, th.to), state))
    table.insert(out, '')
    local code = vim.fn.filereadable(step.file) == 1 and vim.fn.readfile(step.file) or {}
    local shown = 0
    for line = th.from, th.to do
      if shown == 12 then
        table.insert(out, ('  … %d more lines'):format(th.to - line + 1))
        break
      end
      table.insert(out, ('%4d  %s'):format(line, code[line] or ''))
      shown = shown + 1
    end
    for _, m in ipairs(th.messages) do
      table.insert(out, '')
      text(m.by == 'user' and 'You: ' or (m.proposal and 'Agent (proposal): ' or 'Agent: '), m.text)
    end
  else
    table.insert(out, ('Finding [%d] · %s:%d'):format(note.n, short(step), note.line))
    table.insert(out, '')
    table.insert(out, 'Verdict: ' .. (note.verdict or '-'))
    table.insert(out, 'Evidence: ' .. (note.evidence or '-'))
    table.insert(out, 'Decision: ' .. (note.decision == 'accept' and 'accepted' or note.decision == 'reject' and 'rejected'
      or 'none') .. ((note.decision and not note.decision_sent) and ' (not sent)' or ''))
    if note.text then
      table.insert(out, '')
      vim.list_extend(out, tour.to_lines(note.text))
    end
    if note.detail then
      table.insert(out, '')
      table.insert(out, 'Detail:')
      vim.list_extend(out, tour.to_lines(note.detail))
    end
  end
  return out
end

local function size(lines)
  local width = math.min(math.max(60, math.floor(vim.o.columns * 0.6)), vim.o.columns - 4)
  local height = 0
  for _, l in ipairs(lines) do
    height = height + math.max(1, math.ceil(vim.fn.strdisplaywidth(l) / width))
  end
  return width, math.max(1, math.min(height, vim.o.lines - vim.o.cmdheight - 6))
end

local function close()
  if float and vim.api.nvim_win_is_valid(float.win) then
    vim.api.nvim_win_close(float.win, true)
  end
  float = nil
end
M.close = close

--- Draw the float again from the stored thread; closes it when the thread
--- or note is gone. Does nothing when no float is open.
function M.refresh()
  if not float then
    return
  end
  if not (vim.api.nvim_win_is_valid(float.win) and vim.api.nvim_buf_is_valid(float.buf)) then
    float = nil
    return
  end
  local target = resolve()
  if not target then
    return close()
  end
  local lines = M.lines(target)
  vim.bo[float.buf].modifiable = true
  vim.api.nvim_buf_set_lines(float.buf, 0, -1, false, lines)
  vim.bo[float.buf].modifiable = false
  local width, height = size(lines)
  vim.api.nvim_win_set_config(float.win, {
    relative = 'editor', width = width, height = height,
    row = math.max(0, math.floor((vim.o.lines - vim.o.cmdheight - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
  })
end

-- Run `fn(target)` for what the float shows, then draw it again.
local function act(fn)
  return function()
    local target = resolve()
    if not target then
      return close()
    end
    ui.safe(fn)(target)
    M.refresh()
  end
end

local function map_keys(buf)
  local function map(keys, desc, fn)
    for _, key in ipairs(keys) do
      vim.keymap.set('n', key, fn, { buffer = buf, nowait = true, desc = 'Walkthrough: ' .. desc })
    end
  end
  map({ 'q', '<Esc>' }, 'close the thread', close)
  map({ 'r' }, 'reply', act(function(target)
    local th = target.thread
    if not th then
      return vim.notify('walkthrough: a note has no thread to reply in; ask on its line', vim.log.levels.INFO)
    end
    -- The float is not the place for the text: it opens its own, and the
    -- thread float stays where it is behind it.
    input.ask({ title = ('Reply in %s'):format(th.id), prompt = ('Reply in %s: '):format(th.id) }, function(answer)
      local t = resolve()
      if t and t.thread then
        feedback.reply(t.t, t.step, t.thread, answer)
        M.refresh()
      end
    end)
  end))
  map({ 'y' }, 'accept', act(function(target)
    feedback.decide_on(target, 'accept')
  end))
  map({ 'd' }, 'decline', act(function(target)
    feedback.decide_on(target, 'reject')
  end))
  map({ 'u' }, 'take the decision back', act(function(target)
    feedback.decide_on(target, nil)
  end))
  map({ '-' }, 'explain simpler', act(function(target)
    feedback.explain_on(target, 'simpler')
  end))
  map({ '+', '=' }, 'explain deeper', act(function(target)
    feedback.explain_on(target, 'deeper')
  end))
  map({ 'X' }, 'delete the thread', act(function(target)
    if not target.thread then
      return vim.notify('walkthrough: only threads can be deleted, not notes', vim.log.levels.INFO)
    end
    local th = target.thread
    if vim.fn.confirm(('Delete thread %s?'):format(th.id), '&Yes\n&No', 2) == 1 then
      feedback.delete_thread(target.step, th)
    end
  end))
end

--- Show the thread or note under the cursor in full. The float is entered;
--- `q` and `<Esc>` close it.
function M.show()
  local target = feedback.here()
  if not (target.thread or target.note) then
    return vim.notify('walkthrough: no thread or note on this line', vim.log.levels.INFO)
  end
  close()
  local lines = M.lines(target)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = 'wipe'
  local width, height = size(lines)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - vim.o.cmdheight - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = 'minimal',
    border = 'rounded',
    title = target.thread and (' Thread %s '):format(target.thread.id) or (' Finding [%d] '):format(target.note.n),
    title_pos = 'center',
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  float = {
    win = win, buf = buf, t = target.t, si = target.si,
    thread = target.thread and target.thread.id or nil, note = (not target.thread) and target.note.n or nil,
  }
  map_keys(buf)
  vim.api.nvim_create_autocmd('WinClosed', {
    pattern = tostring(win),
    once = true,
    callback = function()
      if float and float.win == win then
        float = nil
      end
    end,
  })
  return win
end

--- The window of the open float, if any.
function M.win()
  return float and vim.api.nvim_win_is_valid(float.win) and float.win or nil
end

return M
