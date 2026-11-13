-- What the user sees: overlay, notes, the map panel and window layout.
local state = require('walkthrough.state')
local git = require('walkthrough.git')
local tour = require('walkthrough.tour')
local tours = require('walkthrough.tours')

local M = {}

local st = state
local ns = vim.api.nvim_create_namespace('walkthrough')
M.ns = ns

local to_lines = tour.to_lines

-- Highlights ------------------------------------------------------------------

local verdict_hl = {
  keep = 'WalkthroughKeep',
  simplify = 'WalkthroughSimplify',
  remove = 'WalkthroughRemove',
  done = 'WalkthroughKeep', -- a suggestion that has been applied
  moved = 'WalkthroughMoved', -- code that was only relocated
}

-- A badge is a diagnostic color turned into a background, with the editor
-- background as text color, so it reads as a small label.
local function badge(name, from)
  local fg = vim.api.nvim_get_hl(0, { name = from, link = false }).fg
  local bg = vim.api.nvim_get_hl(0, { name = 'Normal', link = false }).bg
  vim.api.nvim_set_hl(0, name, { fg = bg or 0, bg = fg, bold = true })
end

function M.define_highlights()
  -- `default = true` keeps any colors a colorscheme already set for these groups.
  vim.api.nvim_set_hl(0, 'WalkthroughRange', { link = 'Visual', default = true })
  vim.api.nvim_set_hl(0, 'WalkthroughBar', { link = 'DiagnosticInfo', default = true })
  vim.api.nvim_set_hl(0, 'WalkthroughNote', { link = 'DiagnosticInfo', default = true })
  vim.api.nvim_set_hl(0, 'WalkthroughNoteDetail', { link = 'Comment', default = true })
  vim.api.nvim_set_hl(0, 'WalkthroughAdded', { link = 'DiffAdd', default = true })
  vim.api.nvim_set_hl(0, 'WalkthroughRemoved', { link = 'DiffDelete', default = true })
  vim.api.nvim_set_hl(0, 'WalkthroughStaged', { link = 'CursorLine', default = true })
  vim.api.nvim_set_hl(0, 'WalkthroughStagedSign', { link = 'DiagnosticOk', default = true })
  vim.api.nvim_set_hl(0, 'WalkthroughStagedRemoved', { link = 'Comment', default = true })
  vim.api.nvim_set_hl(0, 'WalkthroughOther', { link = 'Comment', default = true })
  vim.api.nvim_set_hl(0, 'WalkthroughUnassigned', { link = 'DiagnosticWarn', default = true })
  badge('WalkthroughUnassignedLabel', 'DiagnosticWarn')
  -- The name of the commit a dimmed line belongs to: a grey block. It is
  -- readable as a label, without a colour that pulls the eye away from the
  -- commit under review.
  badge('WalkthroughOtherLabel', 'Comment')
  -- Where a thread stands (waiting, not sent, proposal, ...), under the code
  -- and in the map's count line: the one thing that asks for attention.
  vim.api.nvim_set_hl(0, 'WalkthroughState', { link = 'DiagnosticInfo', default = true })
  badge('WalkthroughMixed', 'DiagnosticWarn')
  badge('WalkthroughBadge', 'DiagnosticInfo')
  badge('WalkthroughKeep', 'DiagnosticOk')
  badge('WalkthroughSimplify', 'DiagnosticWarn')
  badge('WalkthroughRemove', 'DiagnosticError')
  badge('WalkthroughMoved', 'Comment')
  badge('WalkthroughAccepted', 'DiagnosticOk')
  badge('WalkthroughRejected', 'DiagnosticError')
  vim.api.nvim_set_hl(0, 'WalkthroughEvidence', { link = 'Comment', default = true })
  vim.api.nvim_set_hl(0, 'WalkthroughThread', { link = 'DiagnosticHint', default = true })
  vim.api.nvim_set_hl(0, 'WalkthroughThreadDim', { link = 'Comment', default = true })
  -- The map panel: the active commit's heading stands out, titles are dim.
  vim.api.nvim_set_hl(0, 'WalkthroughMapHeading', { link = 'Normal', default = true })
  vim.api.nvim_set_hl(0, 'WalkthroughMapActive', { link = 'Title', default = true })
  vim.api.nvim_set_hl(0, 'WalkthroughMapMarker', { link = 'DiagnosticInfo', default = true })
  vim.api.nvim_set_hl(0, 'WalkthroughMapTitle', { link = 'Comment', default = true })
  vim.api.nvim_set_hl(0, 'WalkthroughMapSeen', { link = 'Comment', default = true })
  vim.api.nvim_set_hl(0, 'WalkthroughMapCount', { link = 'Comment', default = true })
  -- The compact view: file headings, the number column, and what is only context.
  vim.api.nvim_set_hl(0, 'WalkthroughHeading', { link = 'Title', default = true })
  vim.api.nvim_set_hl(0, 'WalkthroughGutter', { link = 'LineNr', default = true })
  vim.api.nvim_set_hl(0, 'WalkthroughDim', { link = 'Comment', default = true })
end

-- Windows ---------------------------------------------------------------------

-- Wrap a user entry point: it reports a problem with a notification instead
-- of raising into a mapping.
function M.safe(fn)
  return function(...)
    local ok, err = pcall(fn, ...)
    if not ok then
      vim.notify('walkthrough: ' .. tour.clean_error(err), vim.log.levels.ERROR)
    end
  end
end

-- The window where code is shown. Reuses the last one, else the first window
-- showing a normal file, else splits off a new one (e.g. when only the agent
-- terminal is open).
local function get_code_win()
  -- Reuse it only in the current tab; a tour left open in another tab must
  -- not draw over there.
  if st.code_win and vim.api.nvim_win_is_valid(st.code_win)
    and vim.api.nvim_win_get_tabpage(st.code_win) == vim.api.nvim_get_current_tabpage() then
    return st.code_win
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if win ~= st.panel_win and vim.bo[vim.api.nvim_win_get_buf(win)].buftype == '' then
      st.code_win = win
      return win
    end
  end
  -- No file window yet (e.g. only the agent terminal): open one along the
  -- whole edge opposite the panel, so code ends up on the outside.
  local side = st.config.panel_side == 'left' and 'right' or 'left'
  st.code_win = vim.api.nvim_open_win(0, false, { split = side, win = -1 })
  return st.code_win
end
M.get_code_win = get_code_win

local function code_buf()
  return vim.api.nvim_win_get_buf(get_code_win())
end
M.code_buf = code_buf

local function center(win, line)
  vim.api.nvim_win_set_cursor(win, { line, 0 })
  vim.api.nvim_win_call(win, function()
    vim.cmd('normal! zz')
  end)
end

-- Groups ----------------------------------------------------------------------
--
-- A step may list which feature ("group") each change in its file belongs to:
--   "hunks": [{ "from": 144, "to": 150, "group": "Shared LAN constants" }, ...]
-- The tour's "group" is the one being reviewed. Changes of other groups are
-- dimmed and labelled, changes in no range are flagged, so the user can stage
-- exactly one feature. A deletion counts as being on the line it is shown on.

-- 'mine', 'other' (plus its group name), 'unassigned' or 'stale' for a
-- changed line. Without "hunks" every change counts as 'mine', as before
-- groups existed. A range an edit has cut into (see anchor.lua) is 'stale'
-- and wins over any other range: nobody knows whose line it is.
local function classify(step, line)
  if not step.hunks then
    return 'mine'
  end
  for _, h in ipairs(step.hunks) do
    if h.stale and line >= h.from and line <= (h.to or h.from) then
      return 'stale'
    end
  end
  for _, h in ipairs(step.hunks) do
    if line >= h.from and line <= (h.to or h.from) then
      if h.group == nil or h.group == step.group then
        return 'mine'
      end
      return 'other', h.group
    end
  end
  return 'unassigned'
end
M.classify = classify

-- Diff overlay ----------------------------------------------------------------

local label = {
  other = function(group)
    return { ' → ' .. group .. ' ', 'WalkthroughOtherLabel' }
  end,
  unassigned = function()
    return { ' ? not in any commit ', 'WalkthroughUnassignedLabel' }
  end,
  stale = function()
    return { ' ? stale range ', 'WalkthroughUnassignedLabel' }
  end,
}

-- `step.diff` is `true` or a git ref string.
--   ref:  one plain diff against that ref, all in the "changed" colors.
--   true: everything uncommitted (diff vs HEAD), where the staged parts get
--         muted colors and a ✓. Both diffs end at the file on disk, so their
--         line numbers match: a line changed vs HEAD but not vs the index
--         is exactly a staged line.
-- With `step.hunks`, changes are also styled by group (see "Groups").
-- Every git call happens before the first mark, so a failure draws nothing.
local function draw_diff(buf, step)
  local diff = step.diff
  local file = vim.api.nvim_buf_get_name(buf)
  local tab = string.rep(' ', vim.bo[buf].tabstop)
  local last = vim.api.nvim_buf_line_count(buf)

  -- One index diff serves both the staged/unstaged split and the mixed-hunk
  -- check below; every git call blocks the editor for a moment.
  local index_hunks = diff == true and git.hunks(file, nil) or nil
  local head_hunks = git.hunks(file, diff == true and 'HEAD' or diff)
  if not head_hunks or (diff == true and not index_hunks) then
    return -- not in a repository: nothing to compare with
  end
  local unstaged_lines, unstaged_removed -- nil means "don't split by stage"
  if index_hunks then
    unstaged_lines, unstaged_removed = git.unstaged_set(index_hunks, last)
  end
  local cap = st.config.max_removed_lines or 10

  for _, h in ipairs(head_hunks) do
    local labelled = false -- one group label per hunk, on its first line
    for line = h.start, math.min(h.start + h.count - 1, last) do
      local class, other = classify(step, line)
      local mark
      if class == 'mine' then
        local staged = unstaged_lines and not unstaged_lines[line]
        mark = {
          line_hl_group = staged and 'WalkthroughStaged' or 'WalkthroughAdded',
          sign_text = staged and '✓' or nil,
          sign_hl_group = staged and 'WalkthroughStagedSign' or nil,
        }
      else
        -- No line background: only the code of the reviewed group stands out.
        mark = {
          sign_text = class == 'other' and '·' or '?',
          sign_hl_group = class == 'other' and 'WalkthroughOther' or 'WalkthroughUnassigned',
        }
        if not labelled then
          mark.virt_text, mark.virt_text_pos = { label[class](other) }, 'eol'
          labelled = true
        end
      end
      vim.api.nvim_buf_set_extmark(buf, ns, line - 1, 0, mark)
    end

    if #h.removed > 0 then
      local row, above = git.removed_anchor(h, last)
      local class, other = classify(step, row + 1)
      local hl
      if class == 'other' then
        hl = 'WalkthroughOther'
      elseif class ~= 'mine' then
        hl = 'WalkthroughUnassigned'
      else
        local staged = unstaged_removed and not unstaged_removed[row .. (above and 'a' or 'b')]
        hl = staged and 'WalkthroughStagedRemoved' or 'WalkthroughRemoved'
      end
      local virt = {}
      for i, old in ipairs(h.removed) do
        if i > cap then
          break
        end
        local chunks = { { '- ' .. old:gsub('\t', tab), hl } }
        if i == 1 and class ~= 'mine' and not labelled then
          table.insert(chunks, label[class](other))
        end
        table.insert(virt, chunks)
      end
      if #h.removed > cap then
        table.insert(virt, { { ('… %d more removed lines'):format(#h.removed - cap), hl } })
      end
      vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { virt_lines = virt, virt_lines_above = above })
    end
  end

  -- A git hunk is what a plain stage in one go would take. If an unstaged
  -- hunk mixes groups, staging it whole would pull another feature into the
  -- commit.
  if index_hunks and step.hunks then
    for _, h in ipairs(index_hunks) do
      local seen, kinds, first = {}, 0, nil
      local lines = {}
      for line = h.start, h.start + h.count - 1 do
        table.insert(lines, line)
      end
      if #h.removed > 0 then
        table.insert(lines, (git.removed_anchor(h, last)) + 1)
      end
      for _, line in ipairs(lines) do
        local class, other = classify(step, line)
        local key = class .. (other or '')
        if not seen[key] then
          seen[key], kinds = true, kinds + 1
        end
        first = first and math.min(first, line) or line
      end
      if kinds > 1 then
        vim.api.nvim_buf_set_extmark(buf, ns, math.min(first, last) - 1, 0, {
          virt_text = { { ' ⚠ mixed hunk: stage by selection or with :Walkthrough stage ', 'WalkthroughMixed' } },
          virt_text_pos = 'eol',
        })
      end
    end
  end
end

-- Marks -----------------------------------------------------------------------

-- Mark lines `from`..`to` as the focus. With a diff overlay the line
-- background shows changes, so the focus is a bar in the sign column instead.
local function mark_focus(buf, from, to, with_diff)
  for line = from, to do
    -- Extmark rows are 0-based, editor line numbers are 1-based.
    vim.api.nvim_buf_set_extmark(buf, ns, line - 1, 0, {
      sign_text = '▎',
      sign_hl_group = 'WalkthroughBar',
      number_hl_group = 'WalkthroughBar',
      line_hl_group = not with_diff and 'WalkthroughRange' or nil,
      priority = 200, -- above gitsigns, so the bar wins the sign column
    })
  end
end

-- Clamp the step's range to the buffer. Returns nil when the step has none.
local function focus_range(step, buf)
  if not step.from then
    return nil
  end
  local last = vim.api.nvim_buf_line_count(buf)
  local from = math.max(1, math.min(step.from, last))
  return from, math.max(from, math.min(step.to or from, last))
end
M.focus_range = focus_range

-- Break `text` into lines of at most `width` cells, at spaces where it can.
-- Virtual lines do not wrap by themselves: what is too long is cut off at the
-- window's edge.
local function wrap(text, width)
  width = math.max(width, 20)
  local out = {}
  for _, line in ipairs(to_lines(text)) do
    local cur = ''
    for word in line:gmatch('%S+') do
      if cur ~= '' and vim.fn.strdisplaywidth(cur .. ' ' .. word) > width then
        table.insert(out, cur)
        cur = word
      else
        cur = cur == '' and word or (cur .. ' ' .. word)
      end
    end
    table.insert(out, cur)
  end
  return out
end
M.wrap = wrap

-- Cells for text in the window showing `buf` (without signs and numbers).
local function text_width(buf)
  local win = st.code_win
  if not (win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf) then
    win = vim.fn.win_findbuf(buf)[1]
  end
  if not win then
    return 80
  end
  return vim.api.nvim_win_get_width(win) - vim.fn.getwininfo(win)[1].textoff
end

-- A long reply or detail is cut after this many lines; the thread float of a
-- later stage will show the rest.
local max_text_lines = 6

-- Show note `n` under row `row` of `buf`: a badge at the end of the line, and
-- the text as virtual lines underneath, after `pad`. See `annotate`.
local function annotate_at(buf, row, pad, text, n, verdict, stale, extra)
  extra = extra or {}
  local indent = #pad
  local tag = n and ('[' .. n .. '] ') or '▸ '

  local virt_lines = {}
  for i, l in ipairs(to_lines(text or '')) do
    local prefix = i == 1 and tag or string.rep(' ', vim.fn.strdisplaywidth(tag))
    table.insert(virt_lines, { { pad .. prefix .. l, 'WalkthroughNote' } })
  end
  if extra.detail then
    local blank = string.rep(' ', vim.fn.strdisplaywidth(tag))
    local detail = wrap(extra.detail, text_width(buf) - indent - vim.fn.strdisplaywidth(tag) - 1)
    for i, l in ipairs(detail) do
      if i > max_text_lines then
        table.insert(virt_lines, { { pad .. blank .. '… ' .. (#detail - max_text_lines) .. ' more lines', 'WalkthroughNoteDetail' } })
        break
      end
      table.insert(virt_lines, { { pad .. blank .. l, 'WalkthroughNoteDetail' } })
    end
  end

  local badges = {}
  if n then
    table.insert(badges, { ' ' .. n .. ' ', 'WalkthroughBadge' })
  end
  if verdict_hl[verdict] then
    table.insert(badges, { ' ' })
    table.insert(badges, { ' ' .. verdict:upper() .. ' ', verdict_hl[verdict] })
  end
  -- A decision the agent was not told yet says so: `send` delivers it.
  local hint = extra.decision and not extra.decision_sent and ', not sent' or ''
  if extra.decision == 'accept' then
    table.insert(badges, { ' ' })
    table.insert(badges, { ' ✓ accepted' .. hint .. ' ', 'WalkthroughAccepted' })
  elseif extra.decision == 'reject' then
    table.insert(badges, { ' ' })
    table.insert(badges, { ' ✗ rejected' .. hint .. ' ', 'WalkthroughRejected' })
  end
  if extra.evidence then
    table.insert(badges, { ' ' .. extra.evidence, 'WalkthroughEvidence' })
  end

  if stale then
    table.insert(badges, { ' ' })
    table.insert(badges, { ' (code changed) ', 'WalkthroughMixed' })
  end

  vim.api.nvim_buf_set_extmark(buf, ns, row - 1, 0, {
    virt_lines = virt_lines,
    virt_text = #badges > 0 and badges or nil,
    virt_text_pos = 'eol',
  })
end
M.annotate_at = annotate_at

-- Show note number `n` on `line`: a badge at the end of the line, and the
-- text as virtual lines underneath, indented to match the code. `extra` may
-- hold `decision` ('accept' or 'reject', the user's stance) and
-- `decision_sent` (the agent was told), `evidence`
-- ('ran', 'read' or 'opinion'), shown after the verdict, and `detail`, the
-- longer explanation, wrapped under the text.
function M.annotate(line, text, n, verdict, stale, extra)
  local buf = code_buf()
  if line < 1 or line > vim.api.nvim_buf_line_count(buf) then
    return
  end
  local indent = vim.api.nvim_buf_call(buf, function()
    return vim.fn.indent(line)
  end)
  annotate_at(buf, line, string.rep(' ', indent), text, n, verdict, stale, extra)
  if n then
    st.note_lines[n] = line
  end
end

-- The short label after a thread's id for the states that need one.
local state_label = {
  draft = 'not sent', waiting = 'waiting', proposed = 'proposal', accepted = 'accepted', declined = 'declined',
  done = 'done',
}

--- The label of thread `th` (nil when it needs none): its state, or, for a
--- decision the user marked and the agent was not told, the decision and
--- `not sent`.
function M.thread_label(th)
  local decision, sent = tour.thread_decision(th)
  if decision and not sent then
    return (decision == 'accept' and 'accepted' or 'declined') .. ', not sent'
  end
  return state_label[th.state]
end

-- A thread is cut after this many virtual lines; the thread float shows the rest.
local max_thread_lines = 6

-- The key that opens the thread float, as the user mapped it, else the command.
local function thread_key()
  local keys = M.plug_keys().thread
  return keys and keys[1] or ':Walkthrough thread'
end

-- A thread of the user: `» t1 you: text` under its last line, then
-- `↳ answer` lines once the agent replied; a label after the id says where
-- it stands. Done and declined ones are dimmed. At most 6 lines; a longer
-- thread ends with a hint for the float.
local function draw_thread(buf, th, ns_id, at)
  local row = at and at.row or math.min(th.to, vim.api.nvim_buf_line_count(buf))
  local pad = at and at.pad
  if not pad then
    pad = string.rep(' ', vim.api.nvim_buf_call(buf, function()
      return vim.fn.indent(row)
    end))
  end
  local indent = #pad
  local dim = th.state == 'done' or th.state == 'declined'
  local hl = dim and 'WalkthroughThreadDim' or 'WalkthroughThread'
  local label = M.thread_label(th)
  local state = label and ('(' .. label .. ')') or nil
  local head = ('» %s%s you: '):format(th.id, state and (' ' .. state) or '')
  local width = text_width(buf) - indent - 1
  local suffix = th.stale and ' (code changed)' or ''
  local lines = {}
  local user, agent = tour.last_message(th, 'user'), tour.last_message(th, 'agent')
  if user then
    for i, l in ipairs(wrap(user.text, width - vim.fn.strdisplaywidth(head .. suffix))) do
      local prefix = i == 1 and head or string.rep(' ', vim.fn.strdisplaywidth(head))
      table.insert(lines, prefix .. l .. (i == 1 and suffix or ''))
    end
  end
  if agent then
    for i, l in ipairs(wrap(agent.text, width - 4)) do
      table.insert(lines, (i == 1 and '  ↳ ' or '    ') .. l)
    end
  end
  if #lines > max_thread_lines then
    lines = vim.list_slice(lines, 1, max_thread_lines - 1)
    table.insert(lines, '    … full thread: ' .. thread_key())
  end
  local virt = {}
  for i, l in ipairs(lines) do
    local open = ('» %s '):format(th.id)
    if i == 1 and user and state and not dim and l:sub(1, #open + #state) == open .. state then
      -- The state is a chunk of its own, so it can have its own colour.
      table.insert(virt, { { pad .. open, hl }, { state, 'WalkthroughState' }, { l:sub(#open + #state + 1), hl } })
    else
      table.insert(virt, { { pad .. l, hl } })
    end
  end
  vim.api.nvim_buf_set_extmark(buf, ns_id or ns, row - 1, 0, { virt_lines = virt })
end

--- Draw thread `th` under its last line in `buf`, in namespace `ns_id` (the
--- full draw's own by default). The thread drawer uses it for the buffers the
--- full draw does not cover (drawer.lua). `at` ({ row, pad }) puts it under
--- another row, indented by `pad`: the compact view's lines are not the file's.
M.draw_thread = draw_thread

-- Remove highlights and notes from every buffer. Panel and history stay.
function M.clear()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  end
  st.note_lines = {}
  st.drawn = nil
end

-- Draw all marks of `step` on the code buffer. Does not move the cursor, so
-- it can run again after an edit or a stage without disturbing the user. On
-- failure nothing stays drawn. A buffer with unsaved changes gets no diff
-- overlay: git only knows the file on disk, so it would not match the screen.
function M.draw(step)
  M.clear()
  local ok, err = pcall(function()
    -- Numbers first follow the edits made since they were written.
    tour.sync(step)
    local buf = code_buf()
    local from, to = focus_range(step, buf)
    if from then
      mark_focus(buf, from, to, step.diff)
    end
    if step.diff and not vim.bo[buf].modified then
      draw_diff(buf, step)
    end
    for _, note in ipairs(step.notes or {}) do
      M.annotate(note.line, note.text, note.n, note.verdict, note.stale,
        { decision = note.decision, decision_sent = note.decision_sent, evidence = note.evidence, detail = note.detail })
    end
    for _, th in ipairs(step.threads or {}) do
      draw_thread(buf, th)
    end
    -- The drawer leaves this step's threads in this buffer to us.
    st.drawn = { buf = buf, step = step }
  end)
  if not ok then
    M.clear()
    error(err, 0)
  end
end

--- Sync the step with its file and draw it. Opens no window.
function M.redraw(step)
  tour.sync(step)
  M.draw(step)
end

--- Draw the current step again after the user's data changed (a thread, a
--- decision): marks only, and only when the code window shows the step's
--- file. The map's counts, an open thread float and the threads in other
--- buffers follow.
function M.update()
  local step = st.history[st.pos]
  if step then
    pcall(tour.sync, step)
    local win = st.code_win
    if M.refresh_compact() then
      -- The compact view was built again.
    elseif win and vim.api.nvim_win_is_valid(win)
      and vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)) == vim.fn.fnamemodify(step.file, ':p') then
      M.draw(step)
    end
  end
  M.update_map()
  M.refresh_float()
  M.redraw_threads()
end

--- Build the active tour's compact view again, with the cursor kept, when the
--- code window shows it. Returns whether it was shown. A failure is reported
--- as a warning, never raised: background events call this.
function M.refresh_compact()
  local t = tours.active()
  local compact = require('walkthrough.compact')
  if not (t and compact.shown(t)) then
    return false
  end
  local ok, err = pcall(compact.rebuild, t)
  if not ok then
    vim.notify('walkthrough: ' .. tour.clean_error(err), vim.log.levels.WARN)
  end
  return true
end

--- Draw the threads of the buffers the full draw does not cover (see
--- drawer.lua). Never raises.
function M.redraw_threads()
  pcall(function()
    require('walkthrough.drawer').redraw()
  end)
end

--- Redraw the thread float if one is open (see thread.lua). Never loads it.
function M.refresh_float()
  local float = package.loaded['walkthrough.thread']
  if float then
    pcall(float.refresh)
  end
end

-- Notes -----------------------------------------------------------------------

-- The lines of notes and threads on the file in `buf`, from every loaded
-- tour that lists it; nil when no tour does. Positions are brought up to date
-- first, unless the buffer has unsaved changes (they are those of the file).
local function marked_lines(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == '' or vim.bo[buf].buftype ~= '' then
    return nil
  end
  local entries = tours.entries(name)
  if #entries == 0 then
    return nil
  end
  local last = vim.api.nvim_buf_line_count(buf)
  local lines = {}
  for _, e in ipairs(entries) do
    if not vim.bo[buf].modified then
      pcall(tour.sync, e.step)
    end
    for _, note in ipairs(e.step.notes or {}) do
      table.insert(lines, math.min(note.line, last))
    end
    for _, th in ipairs(e.step.threads or {}) do
      table.insert(lines, math.min(th.from, last))
    end
  end
  return lines
end

-- Jump to the next (1) or previous (-1) note or thread of the file in the
-- current window, when a loaded tour lists it; else of the code window.
function M.note(delta)
  local win = vim.api.nvim_get_current_win()
  local compact = require('walkthrough.compact')
  -- In the compact view the lines are its own rows.
  local info = compact.info_of(vim.api.nvim_win_get_buf(win))
  if not info then
    local code = st.code_win
    if code and vim.api.nvim_win_is_valid(code) and not marked_lines(vim.api.nvim_win_get_buf(win)) then
      info = compact.info_of(vim.api.nvim_win_get_buf(code))
      win = info and code or win
    end
  end
  local lines
  if info then
    lines = compact.marked_rows(info)
  else
    lines = marked_lines(vim.api.nvim_win_get_buf(win))
    if not lines then
      win = get_code_win()
      lines = marked_lines(vim.api.nvim_win_get_buf(win)) or {}
    end
  end
  local cur = vim.api.nvim_win_get_cursor(win)[1]
  local best_line
  for _, line in ipairs(lines) do
    local ahead = delta > 0 and line > cur or delta < 0 and line < cur
    local closer = not best_line or (delta > 0 and line < best_line) or (delta < 0 and line > best_line)
    if ahead and closer then
      best_line = line
    end
  end
  if not best_line then
    vim.notify('walkthrough: no ' .. (delta < 0 and 'earlier' or 'later') .. ' thread or finding', vim.log.levels.INFO)
    return
  end
  center(win, best_line)
end

-- Keep the code window at least `code_min_ratio` of the screen wide. Space
-- comes from the panel first, down to `panel_min_width`, then from the other
-- windows (the agent terminal): the code window is fixed while the panel
-- takes its minimum back, so that width can only come from the far side.
local enforcing = false
function M.keep_code_wide()
  local code = st.code_win
  if enforcing or not (code and vim.api.nvim_win_is_valid(code)) then
    return
  end
  if vim.api.nvim_win_get_tabpage(code) ~= vim.api.nvim_get_current_tabpage() then
    return
  end
  local target = math.ceil(vim.o.columns * st.config.code_min_ratio)
  if vim.api.nvim_win_get_width(code) >= target then
    return
  end
  enforcing = true
  pcall(function()
    vim.api.nvim_win_set_width(code, target)
    local panel = st.panel_win
    if panel and vim.api.nvim_win_is_valid(panel) and vim.api.nvim_win_get_width(panel) < st.config.panel_min_width then
      local fixed = vim.wo[code].winfixwidth
      vim.wo[code].winfixwidth = true
      vim.api.nvim_win_set_width(panel, st.config.panel_min_width)
      vim.wo[code].winfixwidth = fixed
    end
  end)
  enforcing = false
end

-- The keys the <Plug> mappings (plugin/walkthrough.lua) are mapped to right
-- now, looked up in the mappings as they are: name -> list of keys, shortest
-- first. Buffer-local mappings of the code and current buffers count too;
-- they win over global ones. A leader key is shown as <leader>.
function M.plug_keys()
  local maps = {}
  local code = st.code_win and vim.api.nvim_win_is_valid(st.code_win) and vim.api.nvim_win_get_buf(st.code_win)
  for _, buf in ipairs({ code or -1, vim.api.nvim_get_current_buf() }) do
    if buf ~= -1 and vim.api.nvim_buf_is_valid(buf) then
      vim.list_extend(maps, vim.api.nvim_buf_get_keymap(buf, 'n'))
    end
  end
  vim.list_extend(maps, vim.api.nvim_get_keymap('n'))
  -- Neovim versions write the same key differently (`\\` or `<Bslash>`), in
  -- mapping lists and in keytrans(). Both sides go through one notation
  -- before the leader is recognised.
  local function notation(keys)
    return vim.fn.keytrans(vim.api.nvim_replace_termcodes(keys, true, true, true))
  end
  local leader = notation(vim.g.mapleader or '\\')
  local keys = {}
  for _, m in ipairs(maps) do
    local name = m.rhs and m.rhs:match('^<Plug>%(walkthrough%-([%w-]+)%)$')
    if name then
      local lhs = notation(m.lhs)
      if lhs:sub(1, #leader) == leader and #lhs > #leader then
        lhs = '<leader>' .. lhs:sub(#leader + 1)
      else
        lhs = m.lhs
      end
      keys[name] = keys[name] or {}
      if not vim.tbl_contains(keys[name], lhs) then
        table.insert(keys[name], lhs)
      end
    end
  end
  for _, list in pairs(keys) do
    table.sort(list, function(x, y)
      return #x ~= #y and #x < #y or (#x == #y and x < y)
    end)
  end
  return keys
end

-- Panel -----------------------------------------------------------------------
--
-- The panel is the map: the loaded tours of the repository, each a heading
-- with its steps below. A step is its file, the lines of the reviewed group
-- that are staged, and its title on the next line. The buffer is a plain
-- scratch buffer; the colors are extmarks.

local map_ns = vim.api.nvim_create_namespace('walkthrough_map')

-- The panel's own keys, local to its buffer (the buffer is not modifiable, so
-- single keys are free). `keys` are the lhs, `label` the hint and the cheat
-- sheet's text. Motion and search keys (n, q, j, k, /) are left alone.
local function lazy(module, fn, ...)
  local args = { ... }
  return function()
    require('walkthrough.' .. module)[fn](unpack(args))
  end
end
M.panel_keys = {
  { keys = { '<CR>' }, label = 'open', desc = 'Open the entry under the cursor', run = function() M.open_under_cursor() end },
  { keys = { 's' }, label = 'stage', desc = 'Stage the commit in this file', run = lazy('stage', 'stage_group') },
  { keys = { 'S' }, label = 'stage all', desc = 'Stage the commit in every file', run = lazy('stage', 'stage_group', { all = true }) },
  { keys = { 'm' }, label = 'send', desc = 'Send collected change requests and decisions to the agent', run = lazy('feedback', 'send') },
  { keys = { 'b' }, label = 'base view', desc = 'Show the file as it was before the change', run = lazy('base', 'show') },
  { keys = { 'x' }, label = 'reject', desc = "Discard the commit's unstaged lines in this file", run = lazy('reject', 'reject_group') },
  { keys = { '?' }, label = 'all keys', desc = 'Show all keys', run = lazy('keys', 'show') },
}

-- Key hints name only keys that exist: the panel's own keys, and the key of
-- the cheat sheet. Every other key is in the cheat sheet (keys.lua).
local function hint_parts()
  return { '<CR> open', 's stage', 'S stage all', '? all keys' }
end

-- `%<` marks where a too long bar is cut: in the hints, never in the group
-- and progress in front of them.
local function key_hints()
  return '%<%#Comment#  ' .. table.concat(hint_parts(), ' · '):gsub('%%', '%%%%')
end

-- When the bar does not fit the panel, its hints are cut off. They are then
-- repeated under the panel text, wrapped to the panel's width, as virtual
-- lines: the buffer text stays what the map says.
local footer_ns = vim.api.nvim_create_namespace('walkthrough_panel')
local function panel_footer(bar)
  local win, buf = st.panel_win, st.panel_buf
  local width = vim.api.nvim_win_get_width(win)
  local last = vim.api.nvim_buf_line_count(buf)
  -- Typing calls this on every key: do nothing while the bar, the width and
  -- the text are the same and the footer is still under the last line (a
  -- rewritten panel moves the mark).
  local key = table.concat({ bar, width, last }, '\0')
  local marks = vim.api.nvim_buf_get_extmarks(buf, footer_ns, 0, -1, {})
  if st.footer_key == key and ((not st.footer_shown and #marks == 0)
    or (st.footer_shown and #marks == 1 and marks[1][2] == last - 1)) then
    return
  end
  st.footer_key = key
  vim.api.nvim_buf_clear_namespace(buf, footer_ns, 0, -1)
  local needed = vim.api.nvim_eval_statusline(bar, { winid = win, use_winbar = true, maxwidth = 10000 }).width
  st.footer_shown = needed > width
  if not st.footer_shown then
    return
  end
  local lines, cur = { {} }, ''
  for _, part in ipairs(hint_parts()) do
    local add = (cur == '' and '' or ' · ') .. part
    if cur ~= '' and vim.fn.strdisplaywidth(cur .. add) > width - 1 then
      table.insert(lines, {})
      cur, add = '', part
    end
    cur = cur .. add
    lines[#lines] = { { cur, 'Comment' } }
  end
  table.insert(lines, 1, { { '' } })
  vim.api.nvim_buf_set_extmark(buf, footer_ns, last - 1, 0, { virt_lines = lines })
end

-- The window the panel is split off: the code window, else the first window
-- showing a normal file (without making it the code window: a map opened by
-- itself changes nothing about the code), else a code window is made.
local function panel_anchor()
  if st.code_win and vim.api.nvim_win_is_valid(st.code_win)
    and vim.api.nvim_win_get_tabpage(st.code_win) == vim.api.nvim_get_current_tabpage() then
    return st.code_win
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if win ~= st.panel_win and vim.bo[vim.api.nvim_win_get_buf(win)].buftype == '' then
      return win
    end
  end
  return get_code_win()
end

-- The panel's buffer and window, created when missing.
local function ensure_panel()
  if not (st.panel_buf and vim.api.nvim_buf_is_valid(st.panel_buf)) then
    st.panel_buf = vim.api.nvim_create_buf(false, true) -- unlisted scratch buffer
    vim.bo[st.panel_buf].bufhidden = 'hide'
    for _, k in ipairs(M.panel_keys) do
      for _, lhs in ipairs(k.keys) do
        vim.keymap.set('n', lhs, M.safe(k.run), { buffer = st.panel_buf, desc = 'Walkthrough: ' .. k.desc })
      end
    end
  end
  if not (st.panel_win and vim.api.nvim_win_is_valid(st.panel_win)) then
    st.panel_win = vim.api.nvim_open_win(st.panel_buf, false, {
      split = st.config.panel_side,
      win = panel_anchor(),
      width = st.config.panel_width,
    })
    -- The map fits the width by itself (see layout_map).
    vim.wo[st.panel_win].wrap = false
    vim.wo[st.panel_win].cursorline = true
    vim.wo[st.panel_win].number = false
    vim.wo[st.panel_win].relativenumber = false
    vim.wo[st.panel_win].signcolumn = 'no'
    vim.wo[st.panel_win].winbar = key_hints()
  end
end

--- Show `text` (a string or a list of lines) in a scratch split next to the
--- code. The map panel uses it; text of your own stays until the next step.
function M.panel(text, keep_cursor)
  ensure_panel()
  -- Highlights and rows belong to the map that was there.
  vim.api.nvim_buf_clear_namespace(st.panel_buf, map_ns, 0, -1)
  st.map_rows = {}
  local cursor = keep_cursor and vim.api.nvim_win_get_cursor(st.panel_win)[1] or 1
  vim.bo[st.panel_buf].modifiable = true
  vim.api.nvim_buf_set_lines(st.panel_buf, 0, -1, false, to_lines(text))
  vim.bo[st.panel_buf].modifiable = false
  vim.api.nvim_win_set_cursor(st.panel_win, { math.min(cursor, vim.api.nvim_buf_line_count(st.panel_buf)), 0 })
  M.keep_code_wide()
end

-- The path of a step's file as the map shows it: relative to the repository
-- root, else to the working directory.
local function relative_path(root, file)
  local abs = vim.fn.fnamemodify(file, ':p')
  if root then
    for _, candidate in ipairs({ abs, vim.uv.fs_realpath(abs) or abs }) do
      if vim.startswith(candidate, root .. '/') then
        return candidate:sub(#root + 2)
      end
    end
  end
  return vim.fn.fnamemodify(abs, ':~:.')
end

-- `text` cut from the left to `room` cells, so the end (the file name) stays.
local function fit(text, room)
  room = math.max(room, 1)
  if vim.fn.strdisplaywidth(text) <= room then
    return text
  end
  local n = vim.fn.strchars(text)
  local keep = n
  repeat
    keep = keep - 1
  until keep <= 1 or vim.fn.strdisplaywidth('…' .. vim.fn.strcharpart(text, n - keep)) <= room
  return '…' .. vim.fn.strcharpart(text, n - keep)
end

-- The repository the map shows: the one of the tour on screen, else of the
-- file in the current window when a loaded tour lists it, else of the first
-- loaded tour.
local function map_root()
  local active = tours.active()
  if active then
    return active.root
  end
  local buf = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(buf)
  if name ~= '' and vim.bo[buf].buftype == '' then
    local e = tours.entries(name)[1]
    if e and not e.t.plan then
      return e.t.root
    end
  end
  -- A plan review is in no map.
  for _, t in ipairs(st.tours) do
    if not t.plan then
      return t.root
    end
  end
end

-- The map of the tours that belong to one repository (see map_root) as
-- `lines`, the `marks` that color them ({ row, col, end_col, hl }, 0-based),
-- the `rows` that <CR> opens (line -> { tour, step }; `step` is nil on a
-- heading) and `current`, the line of the shown step. `pos` is the shown step
-- of the active tour. `Other files`, the tour of threads on files no change
-- lists, comes last with each entry's path and nothing else. Pure: it reads
-- the state and draws nothing.
function M.layout_map(pos, width)
  local active = tours.active()
  local root = map_root()
  local lines, marks, rows, current = {}, {}, {}, nil
  if not root then
    return lines, marks, rows, current
  end
  local function add(text)
    table.insert(lines, text)
    return #lines
  end
  local mine = tours.in_root(root)
  for _, t in ipairs(mine) do
    local ti
    for i, x in ipairs(st.tours) do
      if x == t then
        ti = i
      end
    end
    local is_active = t == active
    local progress = st.progress and st.progress[t]
    local n = add((t.extra and tours.OTHER or t.group or 'Changes'):gsub('%s+', ' '))
    table.insert(marks, { n - 1, 0, #lines[n], is_active and 'WalkthroughMapActive' or 'WalkthroughMapHeading' })
    rows[n] = { tour = ti }
    for si, step in ipairs(t.steps) do
      local shown = is_active and si == (pos or t.pos)
      -- Marker, seen mark, file name: the names start where the titles do.
      local prefix = (shown and '>' or ' ') .. ' ' .. (step.seen and '✓' or ' ') .. ' '
      local counts
      local per_file = progress and progress.files[vim.fn.fnamemodify(step.file, ':p')]
      if step.hunks and step.diff == true and per_file then
        counts = ('%d/%d'):format(per_file.staged, per_file.total)
      end
      local room = width - 1 - vim.fn.strdisplaywidth(prefix) - (counts and (#counts + 1) or 0)
      local path = fit(relative_path(t.root, step.file), room)
      local line = prefix .. path
      if counts then
        line = line .. string.rep(' ', width - 1 - vim.fn.strdisplaywidth(line) - #counts) .. counts
      end
      local row = add(line)
      rows[row] = { tour = ti, step = si }
      if shown then
        current = row
        table.insert(marks, { row - 1, 0, 1, 'WalkthroughMapMarker' })
      end
      if step.seen then
        table.insert(marks, { row - 1, 2, 2 + #'✓', 'WalkthroughMapSeen' })
      end
      if counts then
        table.insert(marks, { row - 1, #line - #counts, #line, 'WalkthroughMapCount' })
      end
      if step.title and vim.trim(step.title) ~= '' then
        for _, l in ipairs(wrap(step.title, width - 5)) do
          local title_row = add('    ' .. l)
          rows[title_row] = { tour = ti, step = si }
          table.insert(marks, { title_row - 1, 4, #lines[title_row], 'WalkthroughMapTitle' })
        end
      end
    end
  end
  -- The threads of the repository, as a last line: what waits for the agent
  -- and for the user.
  local counts = tours.thread_counts(mine)
  local parts = {}
  for _, c in ipairs({
    { 'waiting', 'waiting', 'waiting' }, { 'proposed', 'proposal', 'proposals' }, { 'draft', 'not sent', 'not sent' },
  }) do
    local n = counts[c[1]]
    if n then
      table.insert(parts, ('%d %s'):format(n, n == 1 and c[2] or c[3]))
    end
  end
  if #parts > 0 then
    local n = add(table.concat(parts, ' · '))
    table.insert(marks, { n - 1, 0, #lines[n], 'WalkthroughState' })
  end
  return lines, marks, rows, current
end

--- Draw the map in the panel (opening it when needed). The cursor goes to the
--- shown step, unless `keep_cursor` asks to leave it where it is.
function M.show_map(pos, keep_cursor)
  ensure_panel()
  local width = vim.api.nvim_win_get_width(st.panel_win)
  local lines, marks, rows, current = M.layout_map(pos, width)
  M.panel(#lines > 0 and lines or { '' }, keep_cursor)
  st.map_rows, st.map_width = rows, width
  for _, m in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(st.panel_buf, map_ns, m[1], m[2], { end_col = m[3], hl_group = m[4] })
  end
  if current and not keep_cursor then
    vim.api.nvim_win_set_cursor(st.panel_win, { current, 0 })
  end
  M.update_winbar()
end

--- Redraw the map where the panel is open, with the cursor kept. Never opens
--- a window: background events call it.
function M.update_map()
  if st.panel_win and vim.api.nvim_win_is_valid(st.panel_win) then
    M.show_map(nil, true)
  end
end

--- Redraw the map when the panel has another width than the one it was laid
--- out for.
function M.refit_map()
  if st.panel_win and vim.api.nvim_win_is_valid(st.panel_win)
    and vim.api.nvim_win_get_width(st.panel_win) ~= st.map_width then
    M.update_map()
  end
end

-- Staged lines of every loaded tour of the repository, computed apart from
-- the winbar (it costs git calls, and the winbar is redrawn on every key).
-- Several things can ask at once, so one run serves them all.
local progress_pending = false
function M.refresh_progress(now)
  local function run()
    progress_pending = false
    local active = tours.active()
    local progress = {}
    for _, t in ipairs(st.tours) do
      if active and t.root == active.root then
        local ok, res = pcall(function()
          return require('walkthrough.progress').compute(t)
        end)
        progress[t] = ok and res or nil
      end
    end
    st.progress = progress
    M.update_map()
  end
  if now then
    run()
  elseif not progress_pending then
    progress_pending = true
    vim.schedule(run)
  end
end

-- The panel's own winbar: the tour's group (`Changes` for the unnamed one),
-- `staged x/y` and `seen a/b`, key hints, and a notice while the code buffer
-- has unsaved changes (the overlay is paused then). The code window's winbar
-- is not touched.
function M.update_winbar()
  local active = tours.active()
  if not (active and st.panel_win and vim.api.nvim_win_is_valid(st.panel_win)) then
    return
  end
  local function esc(s)
    return (s:gsub('%%', '%%%%'))
  end
  local parts = { ('%%#WalkthroughBadge# %s %%*'):format(esc(active.extra and tours.OTHER or active.group or 'Changes')) }
  local function add(text)
    table.insert(parts, ' · ' .. text)
  end
  local p = st.progress and st.progress[active]
  if p then
    add(('staged %d/%d'):format(p.staged, p.total))
  end
  add(('seen %d/%d'):format(tours.seen_count(active), #active.steps))
  local buf = st.code_win and vim.api.nvim_win_is_valid(st.code_win) and vim.api.nvim_win_get_buf(st.code_win)
  -- In the compact view the code window shows no file: any file of the tour
  -- with unsaved changes counts.
  local dirty = buf and (active.compact and active.compact.buf == buf
    and require('walkthrough.compact').dirty(active) or vim.bo[buf].modified)
  if dirty then
    table.insert(parts, '  %#WalkthroughMixed# unsaved changes: save to refresh %*')
  end
  table.insert(parts, key_hints())
  -- Typing calls this on every key; skip the write when nothing changed.
  local bar = table.concat(parts)
  if vim.wo[st.panel_win].winbar ~= bar then
    vim.wo[st.panel_win].winbar = bar
  end
  if st.panel_buf and vim.api.nvim_buf_is_valid(st.panel_buf) then
    panel_footer(bar)
  end
end

--- Open the step the map line `row` belongs to: the tour becomes the active
--- one when needed, and the step is shown in the code window. On a heading
--- the tour shows the step where it was left. A step that cannot be shown
--- leaves everything as it was.
function M.open_entry(row)
  local target = (st.map_rows or {})[row]
  local t = target and st.tours[target.tour]
  if not t then
    return
  end
  local si = target.step or t.pos
  local step = t.steps[si]
  if not step then
    return
  end
  local prev_active, prev_pos = st.active, t.pos
  st.active, t.pos = target.tour, si
  local ok, err = pcall(M.render, step, si)
  if not ok then
    st.active, t.pos = prev_active, prev_pos
    local back = tours.active()
    if not (back and back.steps[back.pos] and pcall(M.render, back.steps[back.pos], back.pos)) then
      M.clear()
    end
    error(err, 0)
  end
  require('walkthrough.store').save(t.root)
end

--- <CR> in the panel: open the step under the cursor.
function M.open_under_cursor()
  M.open_entry(vim.api.nvim_win_get_cursor(0)[1])
end

--- Show the map panel, or hide it when it is open. Changes nothing about the
--- code window or the shown step. Says so when no tour is loaded.
function M.toggle_map()
  if st.panel_win and vim.api.nvim_win_is_valid(st.panel_win) then
    pcall(vim.api.nvim_win_close, st.panel_win, true)
    st.panel_win = nil
    return
  end
  if tours.count() == 0 then
    vim.notify('walkthrough: nothing to show: no review and no thread yet', vim.log.levels.INFO)
    return
  end
  M.show_map(nil)
  M.refresh_progress()
end

-- Clear everything and close the panel; forget every loaded tour (the saved
-- state on disk stays, see store.lua).
function M.close()
  -- The window goes back to a file, at the line the cursor was on.
  pcall(function()
    require('walkthrough.compact').leave()
  end)
  M.clear()
  pcall(function()
    require('walkthrough.drawer').clear()
  end)
  if st.panel_win and vim.api.nvim_win_is_valid(st.panel_win) then
    vim.api.nvim_win_close(st.panel_win, true)
  end
  st.panel_win = nil
  st.progress = nil
  st.map_rows = {}
  tours.clear()
end

-- Steps -----------------------------------------------------------------------

-- The view a tour opens in: its own choice (`view`), else the `view` option;
-- never the compact one for `Other files`.
function M.view_of(t)
  if t and t.extra then
    return 'file'
  end
  return (t and t.view) or st.config.view or 'compact'
end

--- The view the code window shows for tour `t` now: 'compact' when it shows
--- the tour's compact buffer, 'file' when it shows anything else; the view
--- the tour was shown in last, else the one it would open in, when there is
--- no code window.
function M.current_view(t)
  local win = st.code_win
  if t and win and vim.api.nvim_win_is_valid(win) then
    if t.compact and t.compact.buf == vim.api.nvim_win_get_buf(win) then
      return 'compact'
    end
    return 'file'
  end
  return t and t.shown or M.view_of(t)
end

-- What every view does once it is on screen: the step counts as seen, the
-- map follows.
local function shown(step, pos)
  step.seen = true
  M.show_map(pos)
  M.keep_code_wide()
  M.refresh_progress()
  -- The step before may have covered a buffer that no longer is the code.
  M.redraw_threads()
end

--- Show a step in its tour's view (see `view_of`). `pos` is the step's place
--- in its tour, which the map marks. Returns the view used.
---
--- File view: open the step's file, draw it, move to its focus (or to
--- `opts.line`). Compact view (compact.lua): the tour's buffer, the cursor
--- on the step's heading (or on `opts.target`, { si, line }); a tour with
--- nothing to show there is shown in the file view, and `opts.explicit` says
--- why. `opts.view` overrides the tour's view; `opts.reuse` keeps a compact
--- buffer that is still current.
function M.render(step, pos, opts)
  opts = opts or {}
  tour.check_file(step)
  local t = tours.active()
  local compact = require('walkthrough.compact')
  compact.sweep()
  if (opts.view or M.view_of(t)) == 'compact' and t then
    local ok, why = compact.render(t, step, pos, opts)
    if ok then
      t.shown = 'compact'
      shown(step, pos)
      return 'compact'
    end
    if opts.explicit and why then
      vim.notify('walkthrough: ' .. why, vim.log.levels.INFO)
    end
  end
  local win = get_code_win()
  vim.api.nvim_win_call(win, function()
    -- `:edit` on the shown file with unsaved changes fails with E37, and
    -- there is nothing to load then: the buffer is what the user is editing.
    local on_screen = vim.api.nvim_buf_get_name(0) == vim.fn.fnamemodify(step.file, ':p')
    if not (on_screen and vim.bo.modified) then
      vim.cmd.edit(vim.fn.fnameescape(step.file))
    end
    -- `:edit` keeps an already loaded buffer as is; pick up changes made on
    -- disk (e.g. an edit the agent just made) before drawing on it. Not with
    -- unsaved changes: if the file also changed on disk, Neovim would ask the
    -- user, and the remote caller would block until they answer.
    if not vim.bo.modified then
      vim.cmd('checktime')
    end
  end)
  M.draw(step)
  local buf = code_buf()
  local from = focus_range(step, buf)
  if opts.line then
    from = math.max(1, math.min(opts.line, vim.api.nvim_buf_line_count(buf)))
  end
  if from then
    center(win, from)
  end
  if t then
    t.shown = 'file'
  end
  shown(step, pos)
  return 'file'
end

return M
