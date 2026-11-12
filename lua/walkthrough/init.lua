-- Annotated code tours, driven from outside Neovim over its server socket.
--
-- An external process (Claude) writes a step or tour as JSON and calls:
--   nvim --server $NVIM --remote-expr "v:lua.require'walkthrough'.load('/path/step.json')"
--
-- Step format (every field except `file` is optional):
--   {
--     "file":  "/abs/path/to/file.nix",
--     "title": "What this step is about",   -- shown in the winbar
--     "total": 8,                           -- planned number of steps
--     "from":  10, "to": 20,                -- 1-based, inclusive focus range
--     "diff":  true,                        -- overlay uncommitted changes, staged ones muted (or a git ref)
--     "notes": [{
--       "line": 12,
--       "text": "short inline note",
--       "verdict": "keep" | "simplify" | "remove" | "done",
--       "detail": "longer explanation, shown in the panel"
--     }],
--     "panel": "markdown text",             -- or a list of lines
--     "hunks": [{ "from": 3, "to": 5, "group": "Feature" }]  -- which feature each change is
--   }
--
-- A whole tour is { "group": "Feature", "steps": [step, ...], "start": n }.
-- M.patch changes parts of it in place (see there). It replaces the
-- history and opens step `start` (default 1); the user pages with M.step().
--
-- Notes are numbered: a badge at the end of the code line and a `### [n]`
-- heading in the panel. In the panel, <CR> on a heading jumps to the note and
-- `a` sends it to Claude (claudecode.nvim) to ask about it.
--
-- The diff overlay redraws itself when the file is written, reloaded or
-- staged, so it stays correct while the user edits and stages during a tour.

local M = {}

local ns = vim.api.nvim_create_namespace('walkthrough')
-- All tour state lives in one global table, so it survives the module being
-- loaded again (a rebuild, or a live update with dofile): a fresh copy picks
-- up the running tour instead of starting empty while old marks stay drawn.
_G.walkthrough_state = _G.walkthrough_state or {
  code_win = nil, -- window showing the code
  panel_win = nil, -- window and buffer of the explanation panel
  panel_buf = nil,
  saved_winbar = nil, -- the code window's winbar before the tour took it over
  history = {}, -- the tour's steps
  pos = 0, -- index of the shown step in history
  tour_group = nil, -- the group (feature) the current tour reviews
  note_lines = {}, -- note number -> line, for jumping from the panel
}
local st = _G.walkthrough_state

-- Layout. The default puts the panel left of the code, which suits a Claude
-- terminal on the far left: [ Claude | panel | code ]. Kept in the state
-- table so a reload does not reset what setup() chose.
-- 'keep' adds options a newer version introduced to a state table that an
-- older copy of the module created.
st.config = vim.tbl_extend('keep', st.config or {}, {
  panel_side = 'left',
  panel_width = 70,
  panel_min_width = 30, -- the panel never shrinks below this to make room
  code_min_ratio = 0.5, -- the code window keeps at least this share of the screen
})

--- Optional: setup({ panel_side, panel_width, panel_min_width, code_min_ratio })
function M.setup(opts)
  opts = opts or {}
  if opts.panel_side and opts.panel_side ~= 'left' and opts.panel_side ~= 'right' then
    error('walkthrough: panel_side must be "left" or "right"')
  end
  if opts.code_min_ratio and (opts.code_min_ratio <= 0 or opts.code_min_ratio >= 1) then
    error('walkthrough: code_min_ratio must be between 0 and 1')
  end
  st.config = vim.tbl_extend('force', st.config, opts)
end

-- Highlights ------------------------------------------------------------------

local verdict_hl = {
  keep = 'WalkthroughKeep',
  simplify = 'WalkthroughSimplify',
  remove = 'WalkthroughRemove',
  done = 'WalkthroughKeep', -- a suggestion that has been applied
}

-- A badge is a diagnostic color turned into a background, with the editor
-- background as text color, so it reads as a small label.
local function badge(name, from)
  local fg = vim.api.nvim_get_hl(0, { name = from, link = false }).fg
  local bg = vim.api.nvim_get_hl(0, { name = 'Normal', link = false }).bg
  vim.api.nvim_set_hl(0, name, { fg = bg or 0, bg = fg, bold = true })
end

local function define_highlights()
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
end

-- Helpers ---------------------------------------------------------------------

local function to_lines(text)
  if type(text) == 'table' then
    return text
  end
  return vim.split(text, '\n', { plain = true })
end

local function current()
  return st.history[st.pos]
end

-- The window where code is shown. Reuses the last one, else the first window
-- showing a normal file, else splits off a new one (e.g. when only the Claude
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
  -- No file window yet (e.g. only the Claude terminal): open one along the
  -- whole edge opposite the panel, so code ends up on the outside.
  local side = st.config.panel_side == 'left' and 'right' or 'left'
  st.code_win = vim.api.nvim_open_win(0, false, { split = side, win = -1 })
  return st.code_win
end

local function code_buf()
  return vim.api.nvim_win_get_buf(get_code_win())
end

local function center(win, line)
  vim.api.nvim_win_set_cursor(win, { line, 0 })
  vim.api.nvim_win_call(win, function()
    vim.cmd('normal! zz')
  end)
end

-- Diff overlay ----------------------------------------------------------------

-- Ask git which lines of `file` changed against `ref`, or against the index
-- when `ref` is nil. Returns hunks
-- { start, count, removed } in new-file line numbers, where `removed` holds
-- the old lines deleted at that spot.
local function git_hunks(file, ref)
  local dir = vim.fs.dirname(file)
  local cmd = { 'git', '-C', dir, 'diff', '-U0', '--no-color', '--no-ext-diff' }
  if ref then
    table.insert(cmd, ref)
  end
  vim.list_extend(cmd, { '--', file })
  local res = vim.system(cmd, { text = true }):wait()
  if res.code ~= 0 then
    error('git diff failed: ' .. vim.trim(res.stderr))
  end

  -- An untracked file has no diff output, but every line is new.
  if res.stdout == '' then
    local tracked = vim.system({ 'git', '-C', dir, 'ls-files', '--error-unmatch', '--', file }):wait()
    if tracked.code ~= 0 then
      return { { start = 1, count = #vim.fn.readfile(file), removed = {} } }
    end
  end

  local hunks, cur = {}, nil
  for _, l in ipairs(vim.split(res.stdout, '\n', { plain = true })) do
    -- Hunk header: @@ -old_start,old_count +new_start,new_count @@
    -- A missing count means 1.
    local start, count = l:match('^@@ %-%d+,?%d* %+(%d+),?(%d*) @@')
    if start then
      cur = { start = tonumber(start), count = count == '' and 1 or tonumber(count), removed = {} }
      table.insert(hunks, cur)
    elseif cur and l:sub(1, 1) == '-' then
      table.insert(cur.removed, l:sub(2))
    end
  end
  return hunks
end

-- Where a hunk's deleted lines are shown. It depends on what replaced them:
--   lines changed (count > 0): above the new lines
--   pure deletion at the top (start 0): above the first line
--   pure deletion elsewhere: git gives the line *before* the gap, so below it
local function removed_anchor(h, last)
  local row, above
  if h.count > 0 then
    row, above = h.start - 1, true
  elseif h.start == 0 then
    row, above = 0, true
  else
    row, above = h.start - 1, false
  end
  return math.min(row, last - 1), above
end

-- Groups ----------------------------------------------------------------------
--
-- A step may list which feature ("group") each change in its file belongs to:
--   "hunks": [{ "from": 144, "to": 150, "group": "Shared LAN constants" }, ...]
-- The tour's "group" is the one being reviewed. Changes of other groups are
-- dimmed and labelled, changes in no range are flagged, so the user can stage
-- exactly one feature. A deletion counts as being on the line it is shown on.

local function step_group(step)
  return step.group
end

-- 'mine', 'other' (plus its group name) or 'unassigned' for a changed line.
-- Without "hunks" every change counts as 'mine', as before groups existed.
local function classify(step, line)
  if not step.hunks then
    return 'mine'
  end
  for _, h in ipairs(step.hunks) do
    if line >= h.from and line <= (h.to or h.from) then
      if h.group == nil or h.group == step_group(step) then
        return 'mine'
      end
      return 'other', h.group
    end
  end
  return 'unassigned'
end

-- Changed lines vs the index (what is still unstaged), as a set of line
-- numbers, from the hunks of `git_hunks(file, nil)`. A deletion is entered
-- under the line it is shown on.
local function unstaged_set(index_hunks, last)
  local lines, removed = {}, {}
  for _, h in ipairs(index_hunks) do
    for line = h.start, h.start + h.count - 1 do
      lines[line] = true
    end
    if #h.removed > 0 then
      local row, above = removed_anchor(h, last)
      removed[row .. (above and 'a' or 'b')] = true
      lines[row + 1] = true
    end
  end
  return lines, removed
end

-- Diff overlay drawing --------------------------------------------------------

local label = {
  other = function(group)
    return { ' → ' .. group .. ' ', 'WalkthroughOther' }
  end,
  unassigned = function()
    return { ' ? not in any group ', 'WalkthroughUnassignedLabel' }
  end,
}

-- `step.diff` is `true` or a git ref string.
--   ref:  one plain diff against that ref, all in the "changed" colors.
--   true: everything uncommitted (diff vs HEAD), where the staged parts get
--         muted colors and a ✓. Both diffs end at the file on disk, so their
--         line numbers match: a line changed vs HEAD but not vs the index
--         is exactly a staged line.
-- With `step.hunks`, changes are also styled by group (see "Groups").
local function draw_diff(buf, step)
  local diff = step.diff
  local file = vim.api.nvim_buf_get_name(buf)
  local tab = string.rep(' ', vim.bo[buf].tabstop)
  local last = vim.api.nvim_buf_line_count(buf)

  -- One index diff serves both the staged/unstaged split and the mixed-hunk
  -- check below; every git call blocks the editor for a moment.
  local index_hunks = diff == true and git_hunks(file, nil) or nil
  local unstaged_lines, unstaged_removed -- nil means "don't split by stage"
  if index_hunks then
    unstaged_lines, unstaged_removed = unstaged_set(index_hunks, last)
  end

  for _, h in ipairs(git_hunks(file, diff == true and 'HEAD' or diff)) do
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
      local row, above = removed_anchor(h, last)
      local class, other = classify(step, row + 1)
      local hl
      if class == 'other' then
        hl = 'WalkthroughOther'
      elseif class == 'unassigned' then
        hl = 'WalkthroughUnassigned'
      else
        local staged = unstaged_removed and not unstaged_removed[row .. (above and 'a' or 'b')]
        hl = staged and 'WalkthroughStagedRemoved' or 'WalkthroughRemoved'
      end
      local virt = {}
      for i, old in ipairs(h.removed) do
        local chunks = { { '- ' .. old:gsub('\t', tab), hl } }
        if i == 1 and class ~= 'mine' and not labelled then
          table.insert(chunks, label[class](other))
        end
        table.insert(virt, chunks)
      end
      vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { virt_lines = virt, virt_lines_above = above })
    end
  end

  -- A git hunk is what <leader>gh stages in one go. If an unstaged hunk mixes
  -- groups, staging it whole would pull another feature into the commit.
  if index_hunks and step.hunks then
    for _, h in ipairs(index_hunks) do
      local seen, kinds, first = {}, 0, nil
      local lines = {}
      for line = h.start, h.start + h.count - 1 do
        table.insert(lines, line)
      end
      if #h.removed > 0 then
        table.insert(lines, (removed_anchor(h, last)) + 1)
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
          virt_text = { { ' ⚠ mixed hunk: stage by selection or <leader>gw ', 'WalkthroughMixed' } },
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

-- Show note number `n` on `line`: a badge at the end of the line, and the
-- text as virtual lines underneath, indented to match the code.
function M.annotate(line, text, n, verdict)
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

  vim.api.nvim_buf_set_extmark(buf, ns, line - 1, 0, {
    virt_lines = virt_lines,
    virt_text = #badges > 0 and badges or nil,
    virt_text_pos = 'eol',
  })
  if n then
    st.note_lines[n] = line
  end
end

-- Remove highlights and notes from every buffer. Panel and history stay.
function M.clear()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  end
  st.note_lines = {}
end

-- Draw all marks of `step` on the code buffer. Does not move the cursor, so
-- it can run again after an edit or a stage without disturbing the user.
local function draw(step)
  M.clear()
  local buf = code_buf()
  local from, to = focus_range(step, buf)
  if from then
    mark_focus(buf, from, to, step.diff)
  end
  if step.diff then
    draw_diff(buf, step)
  end
  for n, note in ipairs(step.notes or {}) do
    M.annotate(note.line, note.text, n, note.verdict)
  end
end

-- Panel -----------------------------------------------------------------------

local function note_under_cursor()
  local n = tonumber(vim.api.nvim_get_current_line():match('^### %[(%d+)%]'))
  return n, n and st.note_lines[n]
end

-- <CR> on a `### [n]` heading moves the code to note n.
local function jump_to_note()
  local _, line = note_under_cursor()
  if line then
    center(get_code_win(), line)
  end
end

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

-- What the user is looking at, as text for Claude: the step, and the note
-- (with verdict and detail) when `n` is given, else the step's panel text.
local function ask_context(step, n, from, to)
  local file = vim.fn.fnamemodify(step.file, ':~:.')
  local lines = {
    ('Walkthrough step %d/%d: "%s"'):format(st.pos, #st.history, step.title or file),
  }
  local note = n and (step.notes or {})[n]
  if note then
    local head = ('Note [%d] on %s line %d'):format(n, file, from)
    if note.verdict then
      head = head .. ' · verdict: ' .. note.verdict
    end
    table.insert(lines, head)
    table.insert(lines, 'Inline: ' .. (note.text or ''))
    if note.detail then
      table.insert(lines, 'Detail:')
      vim.list_extend(lines, to_lines(note.detail))
    end
  else
    table.insert(lines, from and ('Focus: %s lines %d-%d'):format(file, from, to) or ('File: ' .. file))
    if step.panel then
      vim.list_extend(lines, { '', 'Panel:' })
      vim.list_extend(lines, to_lines(step.panel))
    end
  end
  return lines
end

-- `a` sends the note under the cursor (or, off a heading, the step) to
-- Claude: a temp file with the note's context (verdict, detail, step) plus
-- an @file#L reference to the code, then focuses the Claude terminal so the
-- user can type a question. The context file is what makes "simplify this"
-- unambiguous, even after the code moved or in another Claude session.
-- Send the context file and the code reference, then focus Claude. With
-- `request`, that text is typed into Claude's prompt but not sent, so the
-- user can edit it and press Enter.
local function send_to_claude(step, n, from, to, request)
  if vim.fn.exists(':ClaudeCodeAdd') ~= 2 then
    vim.notify('walkthrough: claudecode.nvim is not loaded', vim.log.levels.WARN)
    return
  end
  local ctx = vim.fn.tempname() .. '-walkthrough-note.md'
  vim.fn.writefile(ask_context(step, n, from, to), ctx)
  vim.cmd('ClaudeCodeAdd ' .. ctx)

  local file = vim.fn.fnamemodify(step.file, ':~')
  vim.cmd(from and ('ClaudeCodeAdd %s %d %d'):format(file, from, to) or ('ClaudeCodeAdd ' .. file))
  vim.cmd('ClaudeCodeFocus')

  if request then
    -- The @-references travel over claudecode's websocket, the typed text
    -- over the terminal; a short delay keeps the text after the references.
    vim.defer_fn(function()
      require('claudecode.terminal').send_to_terminal(request, { submit = false })
    end, 200)
  end
end

local function ask_claude()
  local step = current()
  if not step then
    return
  end
  local n, line = note_under_cursor()
  local from, to = line, line
  if not line then
    n = nil
    from, to = focus_range(step, code_buf())
  end
  send_to_claude(step, n, from, to)
end

local requests = {
  simplify = 'Apply the simplification from note [%d]: ',
  remove = 'Remove this as described in note [%d]: ',
}

-- From the code window: send the note on the cursor line (or just the line)
-- to Claude, with a request typed in for simplify/remove notes.
function M.ask_line()
  local step = current()
  if not step then
    vim.notify('walkthrough: no tour open', vim.log.levels.INFO)
    return
  end
  local buf = vim.api.nvim_get_current_buf()
  if vim.api.nvim_buf_get_name(buf) ~= vim.fn.fnamemodify(step.file, ':p') then
    vim.notify('walkthrough: this file is not the current step\'s file', vim.log.levels.WARN)
    return
  end
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local n
  for num, l in pairs(st.note_lines) do
    if l == line and (not n or num < n) then
      n = num
    end
  end
  local note = n and step.notes[n]
  local request = note and requests[note.verdict] and requests[note.verdict]:format(n)
  send_to_claude(step, n, line, line, request)
end

-- Keep the code window at least `code_min_ratio` of the screen wide. Space
-- comes from the panel first, down to `panel_min_width`, then from the other
-- windows (the Claude terminal): the code window is fixed while the panel
-- takes its minimum back, so that width can only come from the far side.
local enforcing = false
local function keep_code_wide()
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
M.keep_code_wide = keep_code_wide

-- Show `text` (markdown) in a scratch split to the right of the code.
function M.panel(text, keep_cursor)
  if not (st.panel_buf and vim.api.nvim_buf_is_valid(st.panel_buf)) then
    st.panel_buf = vim.api.nvim_create_buf(false, true) -- unlisted scratch buffer
    vim.bo[st.panel_buf].filetype = 'markdown'
    vim.bo[st.panel_buf].bufhidden = 'hide'
    vim.keymap.set('n', '<CR>', jump_to_note, { buffer = st.panel_buf, desc = 'Jump to note in code' })
    vim.keymap.set('n', 'a', ask_claude, { buffer = st.panel_buf, desc = 'Ask Claude about this note' })
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
    vim.wo[st.panel_win].winbar = '%#Comment# <CR> jump to note   a ask Claude'
  end

  local cursor = keep_cursor and vim.api.nvim_win_get_cursor(st.panel_win)[1] or 1
  vim.bo[st.panel_buf].modifiable = true
  vim.api.nvim_buf_set_lines(st.panel_buf, 0, -1, false, to_lines(text))
  vim.bo[st.panel_buf].modifiable = false
  vim.api.nvim_win_set_cursor(st.panel_win, { math.min(cursor, vim.api.nvim_buf_line_count(st.panel_buf)), 0 })
  keep_code_wide()
end

-- Clear everything and close the panel; forget the history.
function M.close()
  M.clear()
  if st.panel_win and vim.api.nvim_win_is_valid(st.panel_win) then
    vim.api.nvim_win_close(st.panel_win, true)
  end
  if st.code_win and vim.api.nvim_win_is_valid(st.code_win) and st.saved_winbar ~= nil then
    vim.wo[st.code_win].winbar = st.saved_winbar
  end
  st.panel_win, st.saved_winbar = nil, nil
  st.history, st.pos, st.tour_group = {}, 0, nil
end

-- Steps -----------------------------------------------------------------------

-- The panel text: the step's own explanation, then one section per note so
-- every inline badge has a matching heading.
local function panel_text(step)
  local lines = step.panel and vim.deepcopy(to_lines(step.panel)) or {}
  local notes = step.notes or {}
  if #notes > 0 then
    if #lines > 0 then
      table.insert(lines, '')
    end
    table.insert(lines, '## Notes')
    for n, note in ipairs(notes) do
      local head = ('### [%d] line %d'):format(n, note.line)
      if note.verdict then
        head = head .. ' · ' .. note.verdict
      end
      vim.list_extend(lines, { '', head })
      vim.list_extend(lines, to_lines(note.detail or note.text or ''))
    end
  end
  return lines
end

local function check_file(step)
  if type(step.file) ~= 'string' then
    error('step needs a "file" string')
  end
  -- Without this, a typo would silently open a new empty buffer.
  if vim.fn.filereadable(step.file) == 0 then
    error('cannot read file: ' .. step.file)
  end
end

local function update_winbar(step)
  local win = get_code_win()
  if st.saved_winbar == nil then
    st.saved_winbar = vim.wo[win].winbar
  end
  local total = math.max(step.total or 0, #st.history)
  local title = (step.title or vim.fn.fnamemodify(step.file, ':~:.')):gsub('%%', '%%%%')
  vim.wo[win].winbar = ('%%#WalkthroughBadge# Step %d/%d %%* %s   %%#Comment#[w ]w'):format(st.pos, total, title)
end

-- Open the step's file, draw it, move to its focus and fill the panel.
local function render(step)
  check_file(step)
  local win = get_code_win()
  vim.api.nvim_win_call(win, function()
    vim.cmd.edit(vim.fn.fnameescape(step.file))
    -- `:edit` keeps an already loaded buffer as is; pick up changes made on
    -- disk (e.g. an edit Claude just made) before drawing on it.
    vim.cmd('checktime')
  end)
  draw(step)
  local from = focus_range(step, code_buf())
  if from then
    center(win, from)
  end
  local text = panel_text(step)
  if #text > 0 then
    M.panel(text)
  end
  keep_code_wide()
end

-- Move through the tour: -1 back, 1 forward.
function M.step(delta)
  local target = st.history[st.pos + delta]
  if not target then
    vim.notify('walkthrough: no ' .. (delta < 0 and 'earlier' or 'later') .. ' step', vim.log.levels.INFO)
    return
  end
  st.pos = st.pos + delta
  render(target)
  update_winbar(target)
end

-- Where the user is, as JSON, so Claude can resend a fixed tour at the same
-- step: {"step":3,"total":8,"title":"...","file":"..."} or {"step":0}.
function M.status()
  local step = current()
  if not step then
    return vim.json.encode({ step = 0 })
  end
  return vim.json.encode({ step = st.pos, total = #st.history, title = step.title, file = step.file, group = step_group(step) })
end

-- Entry point for the socket. Returns "ok" or an error message instead of
-- raising, so the caller sees the problem in its shell output rather than
-- the user getting an error popup in the editor.
local function read_json(path)
  local json = table.concat(vim.fn.readfile(path), '\n')
  return vim.json.decode(json, { luanil = { object = true, array = true } })
end

function M.load(path)
  local ok, err = pcall(function()
    local data = read_json(path)

    if data.steps then
      if #data.steps == 0 then
        error('"steps" is empty')
      end
      -- Check every step up front, so a typo in step 5 is reported now
      -- rather than when the user reaches it.
      for i, s in ipairs(data.steps) do
        local ok_file, msg = pcall(check_file, s)
        if not ok_file then
          error(('step %d: %s'):format(i, msg))
        end
      end
      -- Every step carries its group, so drawing never depends on load order.
      for _, s in ipairs(data.steps) do
        s.group = s.group or data.group
        -- A step that lists hunks is about changes, so it always gets the
        -- overlay; without it, staging would show no ✓ at all.
        if s.hunks and s.diff == nil then
          s.diff = true
        end
      end
      local start = math.max(1, math.min(data.start or 1, #data.steps))
      render(data.steps[start])
      st.history, st.pos, st.tour_group = data.steps, start, data.group
      update_winbar(data.steps[start])
      return
    end

    data.group = data.group or st.tour_group -- a lone step joins the current tour's group
    if data.hunks and data.diff == nil then
      data.diff = true
    end
    render(data)
    -- Only steps that rendered go into the history, so a fixed and resent
    -- step does not leave a broken one behind.
    table.insert(st.history, data)
    st.pos = #st.history
    update_winbar(data)
  end)
  return ok and 'ok' or ('error: ' .. tostring(err))
end

-- Change parts of the tour in place instead of resending it (far less for
-- Claude to write after an edit). The file holds one patch or a list:
--   { "step": 2, "from": 5, "to": 9, "panel": "..." }        step fields
--   { "step": 2, "note": 3, "verdict": "done", "text": "..." } one note
--   { "step": 2, "note": 4, "line": 30, "text": "..." }       n+1 adds a note
--   { "step": 2, "note": 1, "remove": true }                   drops a note
-- `step` defaults to the current one. The current step is redrawn without
-- moving the cursor, unless its file or focus changed.
local step_fields = { file = 1, title = 1, total = 1, from = 1, to = 1, diff = 1, hunks = 1, notes = 1, panel = 1, group = 1 }
local note_fields = { line = 1, text = 1, verdict = 1, detail = 1 }

local function apply_patch(i, p)
  local n = p.step or st.pos
  local step = st.history[n]
  if not step then
    error(('patch %d: there is no step %s'):format(i, tostring(n)))
  end

  if p.note then
    step.notes = step.notes or {}
    if p.remove then
      table.remove(step.notes, p.note)
      return n, false
    end
    local note = step.notes[p.note]
    if not note then
      if p.note ~= #step.notes + 1 or not p.line then
        error(('patch %d: step %d has no note %d (a new note must be number %d and have "line")'):format(i, n, p.note, #step.notes + 1))
      end
      note = {}
      step.notes[p.note] = note
    end
    for k, v in pairs(p) do
      if k ~= 'step' and k ~= 'note' then
        if not note_fields[k] then
          error(('patch %d: unknown note field "%s"'):format(i, k))
        end
        note[k] = v
      end
    end
    return n, false
  end

  for k, v in pairs(p) do
    if k ~= 'step' then
      if not step_fields[k] then
        error(('patch %d: unknown step field "%s"'):format(i, k))
      end
      step[k] = v
    end
  end
  check_file(step)
  if step.hunks and step.diff == nil then
    step.diff = true
  end
  return n, p.file ~= nil or p.from ~= nil or p.to ~= nil
end

function M.patch(path)
  local ok, err = pcall(function()
    local data = read_json(path)
    local patches = vim.islist(data) and data or { data }
    local redraw, move = false, false
    for i, p in ipairs(patches) do
      local n, moved = apply_patch(i, p)
      if n == st.pos then
        redraw, move = true, move or moved
      end
    end
    if not redraw then
      return
    end
    local step = current()
    local shown = st.code_win and vim.api.nvim_win_is_valid(st.code_win)
      and vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(st.code_win)) == vim.fn.fnamemodify(step.file, ':p')
    if move or not shown then
      render(step)
    else
      draw(step)
      local text = panel_text(step)
      if #text > 0 then
        M.panel(text, true)
      end
    end
    update_winbar(step)
  end)
  return ok and 'ok' or ('error: ' .. tostring(err))
end

-- Run `fn` once git and gitsigns know the buffer's file. Neither can stage
-- parts of an untracked file, and an "unstage all" (`git reset`) turns new
-- files back into untracked ones. Such a file is registered with
-- `git add -N` first: that stages no content, it only makes git (and the
-- flake) see the file. gitsigns then has to re-attach to notice it.
function M.with_tracked(buf, fn)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  local file = vim.api.nvim_buf_get_name(buf)
  local dir = vim.fs.dirname(file)
  local function git(...)
    return vim.system({ 'git', '-C', dir, ... }, { text = true }):wait()
  end
  if file == '' or vim.bo[buf].buftype ~= '' then
    return fn()
  end
  if git('ls-files', '--error-unmatch', '--', file).code == 0 then
    return fn() -- already tracked (or intent-to-add)
  end
  if git('rev-parse', '--is-inside-work-tree').code ~= 0 then
    return fn() -- not in a repository; let gitsigns report it
  end
  if git('check-ignore', '-q', '--', file).code == 0 then
    vim.notify('walkthrough: file is ignored by git, not staging it', vim.log.levels.WARN)
    return
  end
  local res = git('add', '--intent-to-add', '--', file)
  if res.code ~= 0 then
    vim.notify('walkthrough: git add -N failed: ' .. vim.trim(res.stderr), vim.log.levels.ERROR)
    return
  end
  vim.notify('walkthrough: new file registered with git add -N')
  local gitsigns = require('gitsigns')
  gitsigns.detach(buf)
  gitsigns.attach(buf, nil, nil, function()
    vim.schedule(function()
      vim.api.nvim_buf_call(buf, fn)
    end)
  end)
end

-- Stage exactly the current group's changes in the code window's file, by
-- line range, so mixed hunks are split and other groups are never touched.
-- gitsigns' stage_hunk toggles (a range with nothing to stage gets unstaged),
-- so only ranges that still have unstaged lines are passed to it.
local stage_ranges -- defined below stage_group, which calls it

function M.stage_group()
  local step = current()
  if not (step and step.hunks) then
    vim.notify('walkthrough: this step lists no group ranges ("hunks")', vim.log.levels.WARN)
    return
  end
  local ok, gitsigns = pcall(require, 'gitsigns')
  if not ok then
    vim.notify('walkthrough: gitsigns is not available', vim.log.levels.WARN)
    return
  end
  local buf = code_buf()
  -- The ranges belong to the step's file. If the user opened another file
  -- in the code window, applying them there would stage unrelated lines.
  if vim.api.nvim_buf_get_name(buf) ~= vim.fn.fnamemodify(step.file, ':p') then
    vim.notify('walkthrough: the code window shows another file; switch back to ' .. vim.fn.fnamemodify(step.file, ':~:.'), vim.log.levels.WARN)
    return
  end
  if vim.bo[buf].modified then
    vim.notify('walkthrough: save the file first', vim.log.levels.WARN)
    return
  end
  M.with_tracked(buf, function()
    stage_ranges(step, buf, gitsigns)
  end)
end

-- The part of stage_group that runs once the file is known to git.
stage_ranges = function(step, buf, gitsigns)
  -- gitsigns attaches to buffers asynchronously and silently does nothing
  -- for a buffer it is not attached to yet.
  if not vim.b[buf].gitsigns_status_dict then
    vim.notify('walkthrough: gitsigns is not attached to this file yet, try again', vim.log.levels.WARN)
    return
  end

  local unstaged = unstaged_set(git_hunks(step.file, nil), vim.api.nvim_buf_line_count(buf))
  local ranges = {}
  for _, h in ipairs(step.hunks) do
    if h.group == nil or h.group == step_group(step) then
      for line = h.from, h.to or h.from do
        if unstaged[line] then
          table.insert(ranges, { h.from, h.to or h.from })
          break
        end
      end
    end
  end
  if #ranges == 0 then
    vim.notify('walkthrough: nothing left to stage for this group in this file', vim.log.levels.INFO)
    return
  end

  -- stage_hunk is asynchronous, so stage one range after the other.
  local function stage(i)
    if i > #ranges then
      vim.notify(('walkthrough: staged %d range(s) of "%s"'):format(#ranges, step_group(step) or 'this step'))
      return
    end
    vim.api.nvim_buf_call(buf, function()
      gitsigns.stage_hunk(ranges[i], {}, function()
        vim.schedule(function()
          stage(i + 1)
        end)
      end)
    end)
  end
  stage(1)
end

-- Live refresh ----------------------------------------------------------------

-- Redraw the marks when the tour's file changes on disk or in git. Unsaved
-- buffers are skipped: git only knows the file on disk, so the overlay would
-- not match what is on screen.
local function refresh(buf)
  local step = current()
  buf = buf or (st.code_win and vim.api.nvim_win_is_valid(st.code_win) and vim.api.nvim_win_get_buf(st.code_win))
  if not buf then
    return
  end
  if not step or not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].modified then
    return
  end
  -- Check the existing window only; a background event must never open one.
  if not (st.code_win and vim.api.nvim_win_is_valid(st.code_win)) or vim.api.nvim_win_get_buf(st.code_win) ~= buf then
    return
  end
  if vim.api.nvim_buf_get_name(buf) ~= vim.fn.fnamemodify(step.file, ':p') then
    return
  end
  local ok, err = pcall(draw, step)
  if not ok then
    vim.notify('walkthrough: ' .. tostring(err), vim.log.levels.WARN)
  end
end

-- Events come in bursts (a stage fires several gitsigns updates), so they
-- only schedule one redraw of the code buffer a moment later.
local refresh_pending = false
local function schedule_refresh(buf)
  local step = current()
  if refresh_pending or not step or not (st.code_win and vim.api.nvim_win_is_valid(st.code_win)) then
    return
  end
  if buf and buf ~= vim.api.nvim_win_get_buf(st.code_win) then
    return
  end
  refresh_pending = true
  vim.defer_fn(function()
    refresh_pending = false
    refresh()
  end, 80)
end

local group = vim.api.nvim_create_augroup('walkthrough', { clear = true })
-- Windows opening (the Claude terminal), being resized, or the screen size
-- changing can squeeze the code window; scheduled so the layout has settled.
vim.api.nvim_create_autocmd({ 'WinResized', 'VimResized', 'WinNew' }, {
  group = group,
  callback = function()
    if current() then
      vim.schedule(keep_code_wide)
    end
  end,
})
-- Badges copy colors from the theme, so recompute them when the theme changes.
vim.api.nvim_create_autocmd('ColorScheme', { group = group, callback = define_highlights })
-- Written by the user, accepted from a Claude diff, or reloaded after an
-- outside edit.
vim.api.nvim_create_autocmd({ 'BufWritePost', 'FileChangedShellPost' }, {
  group = group,
  callback = function(ev)
    schedule_refresh(ev.buf)
  end,
})
-- Neovim only notices outside edits (sed, Claude's tools) on :checktime,
-- which it runs on few events by itself. Check whenever the user comes back
-- to the code window or to Neovim, so the overlay redraws on its own.
vim.api.nvim_create_autocmd({ 'WinEnter', 'FocusGained' }, {
  group = group,
  callback = function()
    if current() and st.code_win and vim.api.nvim_get_current_win() == st.code_win then
      vim.cmd('silent! checktime ' .. vim.api.nvim_win_get_buf(st.code_win))
    end
  end,
})
-- gitsigns fires this after staging, unstaging or any other git change.
vim.api.nvim_create_autocmd('User', {
  group = group,
  pattern = 'GitSignsUpdate',
  callback = function(ev)
    schedule_refresh(ev.data and ev.data.buffer)
  end,
})

define_highlights()

return M
