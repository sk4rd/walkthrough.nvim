-- What the user sees: overlay, notes, panel and window layout.
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
  vim.api.nvim_set_hl(0, 'WalkthroughAdded', { link = 'DiffAdd', default = true })
  vim.api.nvim_set_hl(0, 'WalkthroughRemoved', { link = 'DiffDelete', default = true })
  vim.api.nvim_set_hl(0, 'WalkthroughStaged', { link = 'CursorLine', default = true })
  vim.api.nvim_set_hl(0, 'WalkthroughStagedSign', { link = 'DiagnosticOk', default = true })
  vim.api.nvim_set_hl(0, 'WalkthroughStagedRemoved', { link = 'Comment', default = true })
  vim.api.nvim_set_hl(0, 'WalkthroughOther', { link = 'Comment', default = true })
  vim.api.nvim_set_hl(0, 'WalkthroughUnassigned', { link = 'DiagnosticWarn', default = true })
  badge('WalkthroughUnassignedLabel', 'DiagnosticWarn')
  badge('WalkthroughMixed', 'DiagnosticWarn')
  badge('WalkthroughBadge', 'DiagnosticInfo')
  badge('WalkthroughKeep', 'DiagnosticOk')
  badge('WalkthroughSimplify', 'DiagnosticWarn')
  badge('WalkthroughRemove', 'DiagnosticError')
  badge('WalkthroughMoved', 'Comment')
  badge('WalkthroughAccepted', 'DiagnosticOk')
  badge('WalkthroughRejected', 'DiagnosticError')
  vim.api.nvim_set_hl(0, 'WalkthroughEvidence', { link = 'Comment', default = true })
  vim.api.nvim_set_hl(0, 'WalkthroughComment', { link = 'DiagnosticHint', default = true })
  vim.api.nvim_set_hl(0, 'WalkthroughCommentResolved', { link = 'Comment', default = true })
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
    return { ' → ' .. group .. ' ', 'WalkthroughOther' }
  end,
  unassigned = function()
    return { ' ? not in any group ', 'WalkthroughUnassignedLabel' }
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
          virt_text = { { ' ⚠ mixed hunk: stage by selection or stage_group ', 'WalkthroughMixed' } },
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

-- Show note number `n` on `line`: a badge at the end of the line, and the
-- text as virtual lines underneath, indented to match the code. `extra` may
-- hold `decision` ('accept' or 'reject', the user's stance) and `evidence`
-- ('ran', 'read' or 'opinion'), shown after the verdict.
function M.annotate(line, text, n, verdict, stale, extra)
  extra = extra or {}
  local buf = code_buf()
  if line < 1 or line > vim.api.nvim_buf_line_count(buf) then
    return
  end
  local indent = vim.api.nvim_buf_call(buf, function()
    return vim.fn.indent(line)
  end)
  local pad = string.rep(' ', indent)
  local tag = n and ('[' .. n .. '] ') or '▸ '

  local virt_lines = {}
  for i, l in ipairs(to_lines(text or '')) do
    local prefix = i == 1 and tag or string.rep(' ', vim.fn.strdisplaywidth(tag))
    table.insert(virt_lines, { { pad .. prefix .. l, 'WalkthroughNote' } })
  end

  local badges = {}
  if n then
    table.insert(badges, { ' ' .. n .. ' ', 'WalkthroughBadge' })
  end
  if verdict_hl[verdict] then
    table.insert(badges, { ' ' })
    table.insert(badges, { ' ' .. verdict:upper() .. ' ', verdict_hl[verdict] })
  end
  if extra.decision == 'accept' then
    table.insert(badges, { ' ' })
    table.insert(badges, { ' ✓ accepted ', 'WalkthroughAccepted' })
  elseif extra.decision == 'reject' then
    table.insert(badges, { ' ' })
    table.insert(badges, { ' ✗ rejected ', 'WalkthroughRejected' })
  end
  if extra.evidence then
    table.insert(badges, { ' ' .. extra.evidence, 'WalkthroughEvidence' })
  end

  if stale then
    table.insert(badges, { ' ' })
    table.insert(badges, { ' (code changed) ', 'WalkthroughMixed' })
  end

  vim.api.nvim_buf_set_extmark(buf, ns, line - 1, 0, {
    virt_lines = virt_lines,
    virt_text = #badges > 0 and badges or nil,
    virt_text_pos = 'eol',
  })
  if n then
    st.note_lines[n] = line
  end
end

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

-- An answer can be long; the code shows its beginning, the panel all of it.
local max_answer_lines = 6

-- A comment of the user: `» c1 question: text` under its last line, then
-- `↳ answer` lines once the agent replied. Resolved ones are dimmed.
local function draw_comment(buf, c)
  local row = math.min(c.to, vim.api.nvim_buf_line_count(buf))
  local indent = vim.api.nvim_buf_call(buf, function()
    return vim.fn.indent(row)
  end)
  local pad = string.rep(' ', indent)
  local hl = c.resolved and 'WalkthroughCommentResolved' or 'WalkthroughComment'
  local head = ('» %s %s: '):format(c.id, c.type)
  local width = text_width(buf) - indent - 1
  local virt = {}
  local suffix = c.stale and ' (code changed)' or ''
  for i, l in ipairs(wrap(c.text, width - vim.fn.strdisplaywidth(head .. suffix))) do
    local prefix = i == 1 and head or string.rep(' ', vim.fn.strdisplaywidth(head))
    table.insert(virt, { { pad .. prefix .. l .. (i == 1 and suffix or ''), hl } })
  end
  if c.answer then
    local lines = wrap(c.answer, width - 4)
    for i, l in ipairs(lines) do
      if i > max_answer_lines then
        table.insert(virt, { { pad .. '    … ' .. (#lines - max_answer_lines) .. ' more lines in the panel', hl } })
        break
      end
      table.insert(virt, { { pad .. (i == 1 and '  ↳ ' or '    ') .. l, hl } })
    end
  end
  vim.api.nvim_buf_set_extmark(buf, ns, row - 1, 0, { virt_lines = virt })
end

-- Remove highlights and notes from every buffer. Panel and history stay.
function M.clear()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  end
  st.note_lines = {}
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
        { decision = note.decision, evidence = note.evidence })
    end
    for _, c in ipairs(step.comments or {}) do
      draw_comment(buf, c)
    end
  end)
  if not ok then
    M.clear()
    error(err, 0)
  end
end

--- Sync the step with its file, draw it, and bring the panel up to date when
--- a number moved (its headings name the lines). Opens no window.
function M.redraw(step, pos, count)
  local moved = tour.sync(step)
  M.draw(step)
  if moved and st.panel_win and vim.api.nvim_win_is_valid(st.panel_win) then
    M.show_panel(step, pos, count, true)
  end
end

--- Draw the current step again after the user's data changed (a comment, a
--- decision, a check): marks only when the code window shows the step's file,
--- and the panel with its cursor kept.
function M.update()
  local step = st.history[st.pos]
  if not step then
    return
  end
  pcall(tour.sync, step)
  local win = st.code_win
  if win and vim.api.nvim_win_is_valid(win)
    and vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)) == vim.fn.fnamemodify(step.file, ':p') then
    M.draw(step)
  end
  if st.panel_win and vim.api.nvim_win_is_valid(st.panel_win) then
    M.show_panel(step, st.pos, #st.history, true)
  end
end

-- Panel -----------------------------------------------------------------------

-- The heading of the panel section the cursor is in: a note or comment is
-- its `###` heading and the text under it, so "this note" works from
-- anywhere in its text, not only on the heading. Outside the panel it is
-- just the current line.
local function section_heading()
  local line = vim.api.nvim_get_current_line()
  if vim.api.nvim_get_current_buf() ~= st.panel_buf or line:sub(1, 1) == '#' then
    return line
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  for _, l in ipairs(vim.fn.reverse(vim.api.nvim_buf_get_lines(0, 0, row - 1, false))) do
    if l:sub(1, 1) == '#' then
      return l
    end
  end
  return line
end

local function note_under_cursor()
  local n = tonumber(section_heading():match('^### %[(%d+)%]'))
  return n, n and st.note_lines[n]
end
M.note_under_cursor = note_under_cursor

--- The id of the comment whose `### (c1)` section the cursor is in.
function M.comment_under_cursor()
  return section_heading():match('^### %((c%d+)%)')
end

-- The file a `path:line` in `text` names, found under the repository root or
-- the working directory (or as an absolute path). The reference at column
-- `col` (0-based) wins; else the first one that exists. Returns nil when
-- there is none.
local function line_reference(text, col)
  local step = st.history[st.pos]
  local function resolve(path)
    local candidates = {}
    if path:sub(1, 1) == '/' then
      candidates = { path }
    elseif path:sub(1, 2) == '~/' then
      candidates = { vim.fn.expand(path) }
    else
      local t = tours.active()
      local root = step and (t and t.root or require('walkthrough.store').root_of(step.file))
      candidates = { root and (root .. '/' .. path) or nil, vim.fn.getcwd() .. '/' .. path }
    end
    for _, c in ipairs(candidates) do
      if vim.fn.filereadable(c) == 1 then
        return vim.fn.fnamemodify(c, ':p')
      end
    end
  end
  local first
  local init = 1
  while true do
    local s, e, path, lnum = text:find('([%w_%.~/%-][^%s:`"\'()<>%[%]{},;|]*):(%d+)', init)
    if not s then
      break
    end
    local file = resolve(path)
    if file then
      local ref = { file = file, line = tonumber(lnum) }
      if col >= s - 1 and col <= e - 1 then
        return ref
      end
      first = first or ref
    end
    init = e + 1
  end
  return first
end

-- <CR> on a `### [n]` heading moves the code to note n; on a line naming
-- `path:line` it opens that file there, in the code window.
local function jump_to_note()
  local n, line = note_under_cursor()
  if n then
    if line then
      center(get_code_win(), line)
    end
    return
  end
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local ref = line_reference(vim.api.nvim_get_current_line(), col)
  if not ref then
    return
  end
  local win = get_code_win()
  vim.api.nvim_win_call(win, function()
    vim.cmd.edit(vim.fn.fnameescape(ref.file))
  end)
  center(win, math.max(1, math.min(ref.line, vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win)))))
end

M.jump_to_note = jump_to_note

-- Scroll the panel so note n's `### [n]` heading is at the top.
local function show_note_in_panel(n)
  if not (st.panel_win and vim.api.nvim_win_is_valid(st.panel_win)) then
    return
  end
  for i, l in ipairs(vim.api.nvim_buf_get_lines(st.panel_buf, 0, -1, false)) do
    if l:match('^### %[' .. n .. '%]') then
      vim.api.nvim_win_set_cursor(st.panel_win, { i, 0 })
      vim.api.nvim_win_call(st.panel_win, function()
        vim.cmd('normal! zt')
      end)
      return
    end
  end
end

-- Jump to the next (1) or previous (-1) note from the code cursor, and show
-- its section in the panel.
function M.note(delta)
  local win = get_code_win()
  local cur = vim.api.nvim_win_get_cursor(win)[1]
  local best_n, best_line
  for n, line in pairs(st.note_lines) do
    local ahead = delta > 0 and line > cur or delta < 0 and line < cur
    local closer = not best_line or (delta > 0 and line < best_line) or (delta < 0 and line > best_line)
    if ahead and closer then
      best_n, best_line = n, line
    end
  end
  if not best_line then
    vim.notify('walkthrough: no ' .. (delta < 0 and 'earlier' or 'later') .. ' note', vim.log.levels.INFO)
    return
  end
  center(win, best_line)
  show_note_in_panel(best_n)
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

-- The panel's own keys, local to its buffer (the buffer is not modifiable, so
-- single keys are free). `keys` are the lhs, `label` the hint and the cheat
-- sheet's text, `check` marks the ones that exist only on a step with a check.
-- Motion and search keys (n, q, j, k, /) are left alone.
local function lazy(module, fn, ...)
  local args = { ... }
  return function()
    require('walkthrough.' .. module)[fn](unpack(args))
  end
end
M.panel_keys = {
  { keys = { '<CR>' }, label = 'jump to note', desc = 'Jump to note in code', run = function() M.jump_to_note() end },
  { keys = { 'a' }, label = 'ask', desc = 'Ask the agent about this note', run = lazy('send', 'ask_panel') },
  { keys = { '-' }, label = 'simpler', desc = 'Ask for a simpler explanation', run = lazy('feedback', 'explain', 'simpler') },
  { keys = { '+', '=' }, label = 'deeper', desc = 'Ask for a deeper explanation', run = lazy('feedback', 'explain', 'deeper') },
  { keys = { 'r' }, label = 'reveal', desc = 'Reveal the answer of the check', check = true, run = lazy('feedback', 'check', 'reveal') },
  { keys = { 'e' }, label = 'answer', desc = 'Write your answer to the check', check = true, run = lazy('feedback', 'check', 'answer') },
  { keys = { 's' }, label = 'stage', desc = 'Stage the group in this file', run = lazy('stage', 'stage_group') },
  { keys = { 'S' }, label = 'stage all', desc = 'Stage the group in every file of the tour', run = lazy('stage', 'stage_group', { all = true }) },
  { keys = { 'y' }, label = 'accept', desc = 'Accept the verdict of this note', run = lazy('feedback', 'decide', 'accept') },
  { keys = { 'd' }, label = 'decline', desc = 'Decline the verdict of this note', run = lazy('feedback', 'decide', 'reject') },
  { keys = { 'u' }, label = 'clear decision', desc = 'Clear the decision on this note', run = lazy('feedback', 'decide', 'clear') },
  { keys = { 'm' }, label = 'send', desc = 'Send comments, decisions and answers to the agent', run = lazy('feedback', 'send') },
  { keys = { 'b' }, label = 'base view', desc = 'Show the file as it was before the change', run = lazy('base', 'show') },
  { keys = { 'x' }, label = 'reject group', desc = "Discard the group's unstaged lines in this file", run = lazy('reject', 'reject_group') },
  { keys = { '?' }, label = 'all keys', desc = 'Show all keys', run = lazy('keys', 'show') },
}

-- Key hints name only keys that exist: the panel's own keys, and the key of
-- the cheat sheet. Every other key is in the cheat sheet (keys.lua).
local function hint_parts(step)
  local parts = { '<CR> jump to note', 'a ask', '- simpler', '+ deeper' }
  if step and step.check then
    vim.list_extend(parts, { 'r reveal', 'e answer' })
  end
  table.insert(parts, '? all keys')
  return parts
end

-- `%<` marks where a too long bar is cut: in the hints, never in the step
-- and progress in front of them.
local function key_hints(step)
  return '%<%#Comment#  ' .. table.concat(hint_parts(step), ' · '):gsub('%%', '%%%%')
end

-- When the bar does not fit the panel, its hints are cut off. They are then
-- repeated under the panel text, wrapped to the panel's width, as virtual
-- lines: the buffer text stays what the agent wrote.
local footer_ns = vim.api.nvim_create_namespace('walkthrough_panel')
local function panel_footer(step, bar)
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
  for _, part in ipairs(hint_parts(step)) do
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

-- Show `text` (markdown) in a scratch split next to the code.
function M.panel(text, keep_cursor)
  if not (st.panel_buf and vim.api.nvim_buf_is_valid(st.panel_buf)) then
    st.panel_buf = vim.api.nvim_create_buf(false, true) -- unlisted scratch buffer
    vim.bo[st.panel_buf].filetype = 'markdown'
    vim.bo[st.panel_buf].bufhidden = 'hide'
    for _, k in ipairs(M.panel_keys) do
      if not k.check then
        for _, lhs in ipairs(k.keys) do
          vim.keymap.set('n', lhs, M.safe(k.run), { buffer = st.panel_buf, desc = 'Walkthrough: ' .. k.desc })
        end
      end
    end
  end
  if not (st.panel_win and vim.api.nvim_win_is_valid(st.panel_win)) then
    st.panel_win = vim.api.nvim_open_win(st.panel_buf, false, {
      split = st.config.panel_side,
      win = get_code_win(),
      width = st.config.panel_width,
    })
    vim.wo[st.panel_win].wrap = true
    vim.wo[st.panel_win].linebreak = true
    vim.wo[st.panel_win].number = false
    vim.wo[st.panel_win].relativenumber = false
    vim.wo[st.panel_win].signcolumn = 'no'
    vim.wo[st.panel_win].winbar = key_hints()
  end

  local cursor = keep_cursor and vim.api.nvim_win_get_cursor(st.panel_win)[1] or 1
  vim.bo[st.panel_buf].modifiable = true
  vim.api.nvim_buf_set_lines(st.panel_buf, 0, -1, false, to_lines(text))
  vim.bo[st.panel_buf].modifiable = false
  vim.api.nvim_win_set_cursor(st.panel_win, { math.min(cursor, vim.api.nvim_buf_line_count(st.panel_buf)), 0 })
  M.keep_code_wide()
end

-- Staged lines of the reviewed group over the whole tour, computed apart from
-- the winbar (it costs git calls, and the winbar is redrawn on every key).
-- Several things can ask at once, so one run serves them all.
local progress_pending = false
function M.refresh_progress(now)
  local function run()
    progress_pending = false
    local t = tours.active()
    local ok, res = pcall(function()
      return t and require('walkthrough.progress').compute(t)
    end)
    st.progress = ok and res and { tour = t, staged = res.staged, total = res.total } or nil
    if t then
      M.update_winbar(t.steps[t.pos], t.pos, #t.steps)
    end
  end
  if now then
    run()
  elseif not progress_pending then
    progress_pending = true
    vim.schedule(run)
  end
end

-- Progress for the panel's own winbar: `Step n/total · group · seen a/b ·
-- staged x/y · title`, key hints, and a notice while the code buffer has
-- unsaved changes (the overlay is paused then). The code window's winbar is
-- not touched.
function M.update_winbar(step, pos, count)
  if not (step and st.panel_win and vim.api.nvim_win_is_valid(st.panel_win)) then
    return
  end
  local function esc(s)
    return (s:gsub('%%', '%%%%'))
  end
  local total = math.max(step.total or 0, count)
  local parts = { ('%%#WalkthroughBadge# Step %d/%d %%*'):format(pos, total) }
  local function add(text)
    table.insert(parts, ' · ' .. text)
  end
  if step.group then
    add(esc(step.group))
  end
  local active = tours.active()
  if active then
    add(('seen %d/%d'):format(tours.seen_count(active), #active.steps))
    local p = st.progress
    if p and p.tour == active then
      add(('staged %d/%d'):format(p.staged, p.total))
    end
  end
  add(esc(step.title or vim.fn.fnamemodify(step.file, ':~:.')))
  local buf = st.code_win and vim.api.nvim_win_is_valid(st.code_win) and vim.api.nvim_win_get_buf(st.code_win)
  if buf and vim.bo[buf].modified then
    table.insert(parts, '  %#WalkthroughMixed# unsaved changes: save to refresh %*')
  end
  table.insert(parts, key_hints(step))
  -- Typing calls this on every key; skip the write when nothing changed.
  local bar = table.concat(parts)
  if vim.wo[st.panel_win].winbar ~= bar then
    vim.wo[st.panel_win].winbar = bar
  end
  if st.panel_buf and vim.api.nvim_buf_is_valid(st.panel_buf) then
    panel_footer(step, bar)
  end
end

-- The panel text: the step's own explanation, then one section per note so
-- every inline badge has a matching heading. A step with neither still gets
-- its title, so the panel never shows the previous step's text.
function M.panel_text(step)
  local lines = step.panel and vim.deepcopy(to_lines(step.panel)) or {}
  local function section(title)
    if #lines > 0 then
      table.insert(lines, '')
    end
    table.insert(lines, title)
  end

  local check = step.check
  if check then
    section('## Check')
    vim.list_extend(lines, to_lines(check.question))
    if check.reply then
      vim.list_extend(lines, { '', '### Your answer' })
      vim.list_extend(lines, to_lines(check.reply))
    end
    if check.feedback then
      vim.list_extend(lines, { '', '### Feedback' })
      vim.list_extend(lines, to_lines(check.feedback))
    end
    -- The answer is not in the buffer until the user asks for it.
    if check.revealed and check.answer then
      vim.list_extend(lines, { '', '### Answer' })
      vim.list_extend(lines, to_lines(check.answer))
    end
  end

  local notes = step.notes or {}
  if #notes > 0 then
    section('## Notes')
    for _, note in ipairs(notes) do
      local head = ('### [%d] line %d'):format(note.n, note.line)
      if note.stale then
        head = head .. ' (code changed)'
      end
      if note.verdict then
        head = head .. ' · ' .. note.verdict
      end
      if note.evidence then
        head = head .. ' · ' .. note.evidence
      end
      if note.decision then
        head = head .. ' · ' .. (note.decision == 'accept' and '✓ accepted' or '✗ rejected')
      end
      vim.list_extend(lines, { '', head })
      vim.list_extend(lines, to_lines(note.detail or note.text or ''))
    end
  end

  local comments = step.comments or {}
  if #comments > 0 then
    section('## Your comments')
    for _, c in ipairs(comments) do
      local where = c.to > c.from and ('%d-%d'):format(c.from, c.to) or tostring(c.from)
      local head = ('### (%s) line %s · %s'):format(c.id, where, c.type)
      if c.stale then
        head = head .. ' (code changed)'
      end
      if c.resolved then
        head = head .. ' · resolved'
      end
      vim.list_extend(lines, { '', head })
      vim.list_extend(lines, to_lines(c.text))
      if c.answer then
        local answer = to_lines(c.answer)
        for i, l in ipairs(answer) do
          table.insert(lines, (i == 1 and '↳ ' or '  ') .. l)
        end
      end
    end
  end
  if #lines == 0 then
    lines = { '# ' .. (step.title or vim.fn.fnamemodify(step.file, ':~:.')) }
  end
  return lines
end

-- `r` and `e` exist in the panel only while the step has a check.
local function set_check_keys(step)
  for _, k in ipairs(M.panel_keys) do
    if k.check then
      for _, lhs in ipairs(k.keys) do
        if step.check then
          vim.keymap.set('n', lhs, M.safe(k.run), { buffer = st.panel_buf, desc = 'Walkthrough: ' .. k.desc })
        else
          pcall(vim.keymap.del, 'n', lhs, { buffer = st.panel_buf })
        end
      end
    end
  end
end

function M.show_panel(step, pos, count, keep_cursor)
  M.panel(M.panel_text(step), keep_cursor)
  set_check_keys(step)
  M.update_winbar(step, pos, count)
end

-- Clear everything and close the panel; forget every loaded tour (the saved
-- state on disk stays, see store.lua).
function M.close()
  M.clear()
  if st.panel_win and vim.api.nvim_win_is_valid(st.panel_win) then
    vim.api.nvim_win_close(st.panel_win, true)
  end
  st.panel_win = nil
  st.progress = nil
  tours.clear()
end

-- Steps -----------------------------------------------------------------------

--- Open the step's file, draw it, move to its focus and fill the panel.
--- `pos` and `count` are the step's place in the tour, for the winbar.
function M.render(step, pos, count)
  tour.check_file(step)
  local win = get_code_win()
  vim.api.nvim_win_call(win, function()
    -- `:edit` on the shown file with unsaved changes fails with E37, and
    -- there is nothing to load then: the buffer is what the user is editing.
    local shown = vim.api.nvim_buf_get_name(0) == vim.fn.fnamemodify(step.file, ':p')
    if not (shown and vim.bo.modified) then
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
  local from = focus_range(step, code_buf())
  if from then
    center(win, from)
  end
  -- Shown to the user: the review state counts it from now on.
  step.seen = true
  M.show_panel(step, pos, count)
  M.keep_code_wide()
  M.refresh_progress()
end

return M
