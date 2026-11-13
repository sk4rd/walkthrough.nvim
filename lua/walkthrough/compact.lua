-- The compact view: one read-only scratch buffer per tour with only the
-- changed parts of the tour's files, all of them in map order, in the code
-- window:
--
--   backup.sh  ·  the destination can be set from outside
--      8   fi
--     10 - dest=/tmp/backups
--     10 + dest=${BACKUP_DIR:-/tmp/backups}
--     11
--
-- A line is the line number (the old one for a removed line), a sign (` `,
-- `+`, `-`) and the text. Every buffer line maps to (entry, new line, old
-- line) in `view.rows`, which is how the cursor is translated to the file
-- (threads, staging, ...). The buffer is built from `git diff`: one call per
-- base for all files of the tour, one for the index (the staged marks). It
-- is built again, with the cursor kept, when a file is written, staged or a
-- thread changes (ui.refresh_compact, init.lua).
--
-- `build` reads git and the files and draws nothing; `layout` is pure.
local st = require('walkthrough.state')
local git = require('walkthrough.git')
local tour = require('walkthrough.tour')
local tours = require('walkthrough.tours')
local ui = require('walkthrough.ui')

local M = {}

local ns = ui.ns

-- Context lines around a change, and the lines of a new file that are shown.
local CONTEXT = 3
local CAP = 200

local function valid(buf)
  return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
end

-- Buffers --------------------------------------------------------------------

--- The compact view of tour `t` when its buffer exists.
local function info_of_tour(t)
  local info = t.compact
  return info and valid(info.buf) and info or nil
end

--- The info of a compact buffer of a loaded tour, with a view built; else nil.
function M.info_of(buf)
  local info = st.compact[buf]
  if info and info.view and valid(buf) and vim.tbl_contains(st.tours, info.t) then
    return info
  end
end

--- Whether the code window shows the compact buffer of tour `t`; returns its
--- info.
function M.shown(t)
  local win = st.code_win
  local info = t and info_of_tour(t)
  if info and info.view and win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == info.buf then
    return info
  end
end

-- The loaded buffer of a file, if any.
local function loaded_buf(file)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].buftype == '' and vim.api.nvim_buf_get_name(b) == file then
      return b
    end
  end
end

--- The buffer of a file when it is loaded and has unsaved changes.
function M.modified_buf(file)
  local b = loaded_buf(file)
  return b and vim.bo[b].modified and b or nil
end

--- Whether a file of tour `t` has unsaved changes.
function M.dirty(t)
  for _, step in ipairs(t.steps) do
    if M.modified_buf(vim.fn.fnamemodify(step.file, ':p')) then
      return true
    end
  end
  return false
end

--- Whether `buf` is a loaded buffer of a file the compact view of `t` shows.
function M.owns(t, buf)
  local info = t and info_of_tour(t)
  if not (info and info.view) or not valid(buf) then
    return false
  end
  return info.view.files[vim.api.nvim_buf_get_name(buf)] == true
end

-- A buffer that no tour shows any more goes away; one still on screen goes
-- when it leaves it.
function M.sweep()
  for buf, info in pairs(st.compact) do
    if not valid(buf) then
      st.compact[buf] = nil
    elseif not vim.tbl_contains(st.tours, info.t) then
      if #vim.fn.win_findbuf(buf) == 0 then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
        st.compact[buf] = nil
      else
        vim.bo[buf].bufhidden = 'wipe'
      end
    end
  end
end

-- An entry that has been under the cursor has been seen.
local function watch_cursor(info)
  vim.api.nvim_create_autocmd('CursorMoved', {
    buffer = info.buf,
    callback = function()
      pcall(function()
        local view = info.view
        local row = vim.api.nvim_win_get_cursor(0)[1]
        local meta = view and view.rows[row]
        local step = meta and meta.si and info.t.steps[meta.si]
        if step and not step.seen then
          step.seen = true
          require('walkthrough.store').save(info.t.root)
          ui.update_map()
        end
      end)
    end,
  })
end

local function ensure_buf(t)
  local info = info_of_tour(t)
  if info then
    return info
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.b[buf].walkthrough_compact = true
  pcall(vim.api.nvim_buf_set_name, buf, ('walkthrough://compact/%d'):format(buf))
  info = { buf = buf, t = t }
  t.compact = info
  st.compact[buf] = info
  watch_cursor(info)
  return info
end

-- Git ------------------------------------------------------------------------

-- The path of `abs` relative to the repository `root`, else nil.
local function rel_of(root, abs)
  if not root then
    return nil
  end
  local roots = { root, vim.uv.fs_realpath(root) or root }
  for _, candidate in ipairs({ abs, vim.uv.fs_realpath(abs) or abs }) do
    for _, r in ipairs(roots) do
      if vim.startswith(candidate, r .. '/') then
        return candidate:sub(#r + 2)
      end
    end
  end
end

-- A file that is all new: one hunk with every line added.
local function all_added(abs)
  local lines = vim.fn.filereadable(abs) == 1 and vim.fn.readfile(abs) or {}
  if #lines == 0 then
    return {}
  end
  local hunk = { old_start = 0, old_count = 0, new_start = 1, new_count = #lines, lines = {} }
  for i, text in ipairs(lines) do
    hunk.lines[i] = { kind = '+', text = text, new = i }
  end
  return { hunk }
end

-- A signature of the files on disk: a change after it was taken makes the
-- built view out of date.
local function signature(t)
  local parts = {}
  for i, step in ipairs(t.steps) do
    local s = vim.uv.fs_stat(step.file)
    parts[i] = s and ('%d.%d:%d'):format(s.mtime.sec, s.mtime.nsec, s.size) or '-'
  end
  return table.concat(parts, ',')
end

--- Whether a file of the tour changed on disk since the view was built.
function M.stale(t)
  local info = info_of_tour(t)
  return info ~= nil and info.view ~= nil and info.view.sig ~= signature(t)
end

-- For every entry of `t`: { rel, path, abs, hunks, new, binary, unstaged, err }.
-- `hunks` are the git hunks (git.parse_diff) against the entry's base: HEAD,
-- or its ref. `unstaged` ({ lines, removed }, as git.unstaged_set) is there
-- for a diff against HEAD: what is still different from the index. An entry
-- with no `diff` has none of it. A git failure for a ref raises.
local function collect(t)
  local root = t.root
  local data = {}
  local by_base, any = {}, false
  for si, step in ipairs(t.steps) do
    local abs = vim.fn.fnamemodify(step.file, ':p')
    local rel = rel_of(root, abs)
    local d = { si = si, abs = abs, rel = rel, path = rel or vim.fn.fnamemodify(abs, ':~:.'), hunks = {} }
    data[si] = d
    if step.diff then
      any = true
      d.base = step.diff == true and 'HEAD' or step.diff
      if not rel then
        d.err = 'not in the repository'
      elseif type(d.base) ~= 'string' or d.base:sub(1, 1) == '-' then
        d.err = 'bad base'
      else
        by_base[d.base] = by_base[d.base] or {}
        table.insert(by_base[d.base], d)
      end
    end
  end
  if not any or next(by_base) == nil then
    return data
  end

  local has_head = git.has_head(root)
  if not has_head and not git.in_repo(root) then
    for _, d in ipairs(data) do
      if d.base and not d.err then
        d.err = 'not in a git repository'
      end
    end
    return data
  end

  -- Which files git knows (an intent-to-add file counts).
  local all_rels = {}
  for _, group in pairs(by_base) do
    for _, d in ipairs(group) do
      table.insert(all_rels, d.rel)
    end
  end
  local listed = git.run(root, vim.list_extend({ 'ls-files', '-z', '--' }, all_rels))
  local tracked = {}
  for _, name in ipairs(vim.split(listed.stdout or '', '\0', { plain = true })) do
    if name ~= '' then
      tracked[name] = true
    end
  end

  for base, group in pairs(by_base) do
    local rels, parsed = {}, {}
    for _, d in ipairs(group) do
      table.insert(rels, d.rel)
    end
    if base ~= 'HEAD' or has_head then
      parsed = git.diff_files(root, base, rels, CONTEXT)
    end
    for _, d in ipairs(group) do
      if not has_head and base == 'HEAD' then
        -- Nothing is committed: everything in the file is new.
        d.hunks, d.new = all_added(d.abs), true
      elseif tracked[d.rel] then
        local p = parsed[d.rel]
        if p then
          d.hunks, d.new, d.binary = p.hunks, p.new, p.binary
        end
      else
        -- Not in the index: git diff does not look at it. All new, unless
        -- the base has it.
        local shown = git.run(root, { 'show', base .. ':' .. d.rel })
        if shown.code ~= 0 then
          d.hunks, d.new = all_added(d.abs), true
        else
          local old = vim.split(shown.stdout, '\n', { plain = true })
          if old[#old] == '' then
            table.remove(old)
          end
          d.hunks = git.diff_lines(old, vim.fn.readfile(d.abs), CONTEXT)
        end
      end
    end
  end

  -- What is staged: a line that differs from HEAD but not from the index.
  local against_head = {}
  for _, d in ipairs(data) do
    if t.steps[d.si].diff == true and d.rel and not d.err then
      table.insert(against_head, d)
    end
  end
  if #against_head > 0 then
    local rels = vim.tbl_map(function(d)
      return d.rel
    end, against_head)
    local index = git.diff_files(root, nil, rels, 0)
    local everything = setmetatable({}, { __index = function() return true end })
    for _, d in ipairs(against_head) do
      if tracked[d.rel] then
        local runs = git.runs(index[d.rel] and index[d.rel].hunks or {})
        local lines, removed = git.unstaged_set(runs, math.huge)
        d.unstaged = { lines = lines, removed = removed }
      else
        -- Not registered with git: nothing of it is staged.
        d.unstaged = { lines = everything, removed = everything }
      end
    end
  end
  return data
end

-- Layout ---------------------------------------------------------------------

-- The key that opens the file view, as the user mapped it, else the command.
local function view_key()
  local keys = ui.plug_keys().view
  return keys and keys[1] or ':Walkthrough view'
end

-- The last line of `from`..`to` that is shown, or nil.
local function last_shown(shown, from, to)
  for line = to, from, -1 do
    if shown[line] then
      return line
    end
  end
end

--- The buffer lines of the view of tour `t` for the git data `data`
--- (see `collect`): `{ lines, rows, marks, heads, ranges, by_new, hunks }`.
--- `rows[r]` is `{ si, kind, new, old, text }` where `kind` is 'head',
--- 'blank', 'code', 'sep' (⋯) or 'more' (a cut-off new file); `by_new[si]`
--- maps a file line to its row; `heads[si]` is the row of the heading and
--- `ranges[si]` the first and last row of the entry; `marks` are extmarks
--- `{ row, col, opts }`; `hunks` is how many hunks are shown. Pure.
function M.layout(t, data, key)
  local lines, rows, marks = {}, {}, {}
  local heads, ranges, by_new, files = {}, {}, {}, {}
  local total = 0

  local width = 4
  for _, d in ipairs(data) do
    for _, h in ipairs(d.hunks) do
      width = math.max(width, #tostring(math.max(h.old_start + h.old_count, h.new_start + h.new_count)))
    end
  end
  local gutter = width + 3

  for si, step in ipairs(t.steps) do
    local d = data[si]
    files[d.abs] = true
    -- The body first: the heading says how many threads it does not show.
    local body, shown, n_hunks = {}, {}, 0
    local function put(text, meta, ms)
      table.insert(body, { text = text, meta = meta, marks = ms or {} })
    end
    local _, of = git.runs(d.hunks)
    local function class_of(line)
      if line.kind == '+' then
        return ui.classify(step, line.new)
      end
      return ui.classify(step, git.removed_anchor(of[line], math.huge) + 1)
    end
    for _, h in ipairs(d.hunks) do
      -- A hunk is shown when the reviewed group has a line in it (or
      -- always, when the entry lists no ranges).
      local keep = not step.hunks
      local classes = {}
      for _, line in ipairs(h.lines) do
        if line.kind ~= ' ' then
          local class, group = class_of(line)
          classes[line] = { class, group }
          keep = keep or class == 'mine' or class == 'stale'
        end
      end
      if keep then
        n_hunks = n_hunks + 1
        if n_hunks > 1 then
          put('  ⋯', { si = si, kind = 'sep' }, { { opts = { end_col = #'  ⋯', hl_group = 'WalkthroughDim' } } })
        end
        local limit = d.new and CAP or #h.lines
        local run_key -- the class and group of the run of changes the line is in
        for i, line in ipairs(h.lines) do
          if i > limit then
            break
          end
          local num = line.kind == '-' and line.old or line.new
          local text = ('%' .. width .. 'd %s %s'):format(num, line.kind, line.text)
          if line.text == '' then
            text = text:gsub('%s+$', '')
          end
          local ms = { { opts = { end_col = math.min(gutter, #text), hl_group = 'WalkthroughGutter' } } }
          if line.kind == ' ' then
            run_key = nil
          else
            local class, group = unpack(classes[line])
            local mark
            if class == 'mine' then
              run_key = nil
              local staged, anchor_key
              if d.unstaged then
                if line.kind == '+' then
                  staged = not d.unstaged.lines[line.new]
                else
                  local row, above = git.removed_anchor(of[line], math.huge)
                  anchor_key = row .. (above and 'a' or 'b')
                  staged = not d.unstaged.removed[anchor_key]
                end
              end
              if line.kind == '+' then
                mark = {
                  line_hl_group = staged and 'WalkthroughStaged' or 'WalkthroughAdded',
                  sign_text = staged and '✓' or nil, sign_hl_group = staged and 'WalkthroughStagedSign' or nil,
                }
              else
                mark = {
                  line_hl_group = staged and 'WalkthroughStagedRemoved' or 'WalkthroughRemoved',
                  sign_text = staged and '✓' or nil, sign_hl_group = staged and 'WalkthroughStagedSign' or nil,
                }
              end
            else
              mark = {
                sign_text = class == 'other' and '·' or '?',
                sign_hl_group = class == 'other' and 'WalkthroughOther' or 'WalkthroughUnassigned',
                hl_group = class == 'other' and 'WalkthroughOther' or nil, end_col = #text,
              }
              local this = class .. '\0' .. (group or '')
              if this ~= run_key then
                run_key = this
                local label = {
                  other = ' → ' .. tostring(group) .. ' ', unassigned = ' ? not in any commit ',
                  stale = ' ? stale range ',
                }
                mark.virt_text = { { label[class], class == 'other' and 'WalkthroughOther' or 'WalkthroughUnassignedLabel' } }
                mark.virt_text_pos = 'eol'
              end
            end
            table.insert(ms, { opts = mark })
          end
          if line.new then
            shown[line.new] = true
          end
          put(text, { si = si, kind = 'code', new = line.new, old = line.old, text = line.text }, ms)
        end
        if #h.lines > limit then
          local more = ('  … %d more lines (file view: %s)'):format(#h.lines - limit, key)
          put(more, { si = si, kind = 'more' }, { { opts = { end_col = #more, hl_group = 'WalkthroughDim' } } })
        end
      end
    end
    total = total + n_hunks

    -- What the entry has that this view does not show.
    local out_threads, out_notes = 0, 0
    for _, th in ipairs(step.threads or {}) do
      if not last_shown(shown, th.from, th.to) then
        out_threads = out_threads + 1
      end
    end
    for _, note in ipairs(step.notes or {}) do
      if not shown[note.line] then
        out_notes = out_notes + 1
      end
    end

    -- The heading.
    local title = step.title and vim.trim((step.title:gsub('%s*\n%s*', ' '))) or ''
    local head = d.path .. (title ~= '' and ('  ·  ' .. title) or '')
    local notes = {}
    if d.binary then
      table.insert(notes, '(binary file)')
    elseif d.new then
      table.insert(notes, '(new file)')
    end
    if d.err then
      table.insert(notes, ('(%s)'):format(d.err))
    elseif not step.diff then
      table.insert(notes, '(no diff)')
    elseif n_hunks == 0 and not d.binary then
      table.insert(notes, #d.hunks > 0 and '(no lines of this commit)' or '(no changes)')
    end
    local elsewhere = {}
    if out_threads > 0 then
      table.insert(elsewhere, ('%d thread%s'):format(out_threads, out_threads == 1 and '' or 's'))
    end
    if out_notes > 0 then
      table.insert(elsewhere, ('%d finding%s'):format(out_notes, out_notes == 1 and '' or 's'))
    end
    if #elsewhere > 0 then
      table.insert(notes, ('(%s elsewhere)'):format(table.concat(elsewhere, ', ')))
    end
    local line = head
    if #notes > 0 then
      line = line .. '   ' .. table.concat(notes, '   ')
    end

    if #lines > 0 then
      table.insert(lines, '')
      rows[#lines] = { si = si, kind = 'blank' }
    end
    table.insert(lines, line)
    local first = #lines
    rows[first] = { si = si, kind = 'head' }
    heads[si] = first
    table.insert(marks, { row = first, col = 0, opts = { end_col = #head, hl_group = 'WalkthroughHeading' } })
    if #line > #head then
      table.insert(marks, { row = first, col = #head, opts = { end_col = #line, hl_group = 'WalkthroughDim' } })
    end
    by_new[si] = {}
    for _, item in ipairs(body) do
      table.insert(lines, item.text)
      local row = #lines
      rows[row] = item.meta
      if item.meta.new then
        by_new[si][item.meta.new] = row
      end
      for _, m in ipairs(item.marks) do
        table.insert(marks, { row = row, col = m.col or 0, opts = m.opts })
      end
    end
    ranges[si] = { first, #lines }
  end
  return {
    lines = lines, rows = rows, marks = marks, heads = heads, ranges = ranges, by_new = by_new, files = files,
    hunks = total, width = width, gutter = gutter, nsteps = #t.steps,
  }
end

--- Read git and the files and lay the view of `t` out. Draws nothing.
function M.build(t)
  local sig = signature(t)
  for _, step in ipairs(t.steps) do
    -- Numbers first follow the edits made since they were written.
    pcall(tour.sync, step)
  end
  local view = M.layout(t, collect(t), view_key())
  view.sig = sig
  return view
end

-- Drawing --------------------------------------------------------------------

-- The width of the indent of `text`.
local function indent_of(text, ts)
  local col = 0
  for c in text:match('^%s*'):gmatch('.') do
    col = c == '\t' and (col + ts - col % ts) or (col + 1)
  end
  return col
end

-- The spaces that put a thread or note under the code of `row`.
local function pad_of(buf, view, row)
  local meta = view.rows[row]
  return string.rep(' ', view.gutter + indent_of(meta and meta.text or '', vim.bo[buf].tabstop))
end

--- The row where a thread on `from`..`to` of entry `si` is drawn: under its
--- last line that is shown. Nil when none is.
function M.thread_row(view, si, from, to)
  local map = view.by_new[si] or {}
  for line = to, from, -1 do
    if map[line] then
      return map[line]
    end
  end
end

-- Put the view in the buffer and draw its marks, threads and notes.
local function apply(t, info, view)
  local buf = info.buf
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, view.lines)
  vim.bo[buf].modifiable = false
  info.view = view
  ui.clear()
  local ok, err = pcall(function()
    for _, m in ipairs(view.marks) do
      vim.api.nvim_buf_set_extmark(buf, ns, m.row - 1, m.col, m.opts)
    end
    for si, step in ipairs(t.steps) do
      for _, note in ipairs(step.notes or {}) do
        local row = (view.by_new[si] or {})[note.line]
        if row then
          ui.annotate_at(buf, row, pad_of(buf, view, row), note.text, note.n, note.verdict, note.stale,
            { decision = note.decision, evidence = note.evidence, detail = note.detail })
        end
      end
      for _, th in ipairs(step.threads or {}) do
        local row = M.thread_row(view, si, th.from, th.to)
        if row then
          ui.draw_thread(buf, th, ns, { row = row, pad = pad_of(buf, view, row) })
        end
      end
    end
  end)
  if not ok then
    ui.clear()
    error(err, 0)
  end
end

-- Cursor ---------------------------------------------------------------------

--- The row of file line `line` in entry `si`; when the line is not shown, the
--- nearest line that is (the earlier one on a tie); the heading when the
--- entry shows no line.
function M.row_for_line(view, si, line)
  local map = view.by_new[si] or {}
  if line and map[line] then
    return map[line]
  end
  local best, dist
  for l in pairs(map) do
    local dd = line and math.abs(l - line) or l
    if not best or dd < dist or (dd == dist and l < best) then
      best, dist = l, dd
    end
  end
  return best and map[best] or view.heads[si]
end

-- The row a remembered position (a row's `meta`) has in `view`.
local function row_of_meta(view, meta)
  if not (meta and meta.si and view.heads[meta.si]) then
    return nil
  end
  if meta.kind == 'code' then
    if meta.new then
      return M.row_for_line(view, meta.si, meta.new)
    end
    -- A removed line: the same old line.
    local range = view.ranges[meta.si]
    for r = range[1], range[2] do
      local m = view.rows[r]
      if m.kind == 'code' and not m.new and m.old == meta.old then
        return r
      end
    end
  end
  return view.heads[meta.si]
end

local function capture(info)
  local out = {}
  for _, win in ipairs(vim.fn.win_findbuf(info.buf)) do
    local cursor = vim.api.nvim_win_get_cursor(win)
    out[#out + 1] = {
      win = win, col = cursor[2], row = cursor[1], meta = info.view and info.view.rows[cursor[1]],
      top = vim.fn.getwininfo(win)[1].topline,
    }
  end
  return out
end

local function restore(info, saved)
  local last = vim.api.nvim_buf_line_count(info.buf)
  for _, s in ipairs(saved) do
    if vim.api.nvim_win_is_valid(s.win) and vim.api.nvim_win_get_buf(s.win) == info.buf then
      local row = math.max(1, math.min(row_of_meta(info.view, s.meta) or s.row, last))
      pcall(vim.api.nvim_win_call, s.win, function()
        vim.fn.winrestview({ lnum = row, col = s.col, topline = math.max(1, row - (s.row - s.top)) })
      end)
    end
  end
end

-- The file line a row stands for, and its entry: a removed line is the line
-- it is shown above, a heading the first line shown, a separator the next
-- line. Returns si and a line (nil when the entry shows no line).
function M.file_line(view, row)
  local meta = view.rows[row]
  if not (meta and meta.si) then
    return nil
  end
  local range = view.ranges[meta.si]
  if meta.kind == 'code' and meta.new then
    return meta.si, meta.new
  end
  if meta.kind == 'head' or meta.kind == 'blank' then
    row = view.heads[meta.si]
  end
  for r = row, range[2] do
    local m = view.rows[r]
    if m.kind == 'code' and m.new then
      return meta.si, m.new
    end
  end
  for r = row, range[1], -1 do
    local m = view.rows[r]
    if m.kind == 'code' and m.new then
      return meta.si, m.new
    end
  end
  return meta.si, nil
end

-- The cursor row of the window showing `buf`.
local function cursor_row(win)
  return vim.api.nvim_win_get_cursor(win)[1]
end

--- The entry (and line) under the cursor of the code window when it shows
--- tour `t`'s compact view: { si, line }. Nil otherwise.
function M.cursor_entry(t)
  local info = M.shown(t)
  if not info then
    return nil
  end
  local meta = info.view.rows[cursor_row(st.code_win)]
  if not (meta and meta.si) then
    return nil
  end
  return { si = meta.si, line = meta.new, kind = meta.kind }
end

--- The file line under the cursor of the code window and its entry, as
--- `file_line` translates them. Nil when the code window does not show the
--- compact view of `t`.
function M.cursor_file_line(t)
  local info = M.shown(t)
  if not info then
    return nil
  end
  return M.file_line(info.view, cursor_row(st.code_win))
end

--- The entry the user means in the compact view: the one under the cursor
--- when the current buffer is a compact buffer; else the current entry when
--- the code window shows the active tour's compact view (a key in the map).
--- Returns { t, si, step, line } or nil.
function M.target()
  local info = M.info_of(vim.api.nvim_get_current_buf())
  if info then
    local meta = info.view.rows[cursor_row(0)]
    if meta and meta.si then
      return { t = info.t, si = meta.si, step = info.t.steps[meta.si], line = meta.new }
    end
  end
  local t = tours.active()
  if t and M.shown(t) and t.steps[t.pos] then
    return { t = t, si = t.pos, step = t.steps[t.pos] }
  end
end

local refusal = {
  head = 'this is the heading of a file, not a line of code; put the cursor on a line of the change',
  blank = 'this is the blank line between two files, not a line of code',
  sep = 'this is a separator between hunks (⋯), not a line of code',
  more = 'this line only says that more lines follow; use the file view to write on them',
}

--- The file lines the rows `r1`..`r2` of compact view `info` stand for:
--- { t, si, step, from, to }. Raises (with a message for the user) when a
--- heading, a blank or separator line is in the range, when it spans more
--- than one entry, and when it holds nothing but removed lines.
function M.resolve(info, r1, r2)
  local view = info.view
  local first = view.rows[r1]
  local last = view.rows[r2]
  if not (first and last) then
    error('nothing here', 0)
  end
  if first.si ~= last.si then
    error('a range must stay inside one entry (one file of the change)', 0)
  end
  local from, to
  for r = r1, r2 do
    local m = view.rows[r]
    if m.kind ~= 'code' then
      error(refusal[m.kind], 0)
    end
    if m.new then
      from = math.min(from or m.new, m.new)
      to = math.max(to or m.new, m.new)
    end
  end
  if not from then
    error('this line was removed, so it is not in the file any more; write on a line that is, for example the one that replaced it', 0)
  end
  return { t = info.t, si = first.si, step = info.t.steps[first.si], from = from, to = to }
end

--- The rows of the notes and threads the view shows, for `]n` and `[n`.
function M.marked_rows(info)
  local view, out = info.view, {}
  for si, step in ipairs(info.t.steps) do
    for _, note in ipairs(step.notes or {}) do
      local row = (view.by_new[si] or {})[note.line]
      if row then
        table.insert(out, row)
      end
    end
    for _, th in ipairs(step.threads or {}) do
      local row = M.thread_row(view, si, th.from, th.to)
      if row then
        table.insert(out, row)
      end
    end
  end
  return out
end

-- Showing --------------------------------------------------------------------

local function window_options(win)
  local function set(name, value)
    vim.api.nvim_set_option_value(name, value, { scope = 'local', win = win })
  end
  set('number', false)
  set('relativenumber', false)
  set('cursorline', true)
  set('wrap', false)
  set('list', false)
end

--- Show `step` (number `pos` of tour `t`) in the compact view: build it,
--- put it in the code window and move the cursor to the step's heading, or
--- to `opts.target` ({ si, line }). With `opts.reuse` a view that is still
--- current is kept. Returns true, or false and why the tour has nothing to
--- show here (then nothing was changed).
function M.render(t, step, pos, opts)
  opts = opts or {}
  if t.extra then
    return false, 'the compact view shows changes; there are none in Other files, so it stays in the file view'
  end
  M.sweep()
  local info = info_of_tour(t)
  local view = info and info.view
  if not (opts.reuse and view and view.nsteps == #t.steps and view.sig == signature(t)) then
    view = M.build(t)
    if view.hunks == 0 then
      return false, 'nothing to show in the compact view: no entry of this commit has changed lines; staying in the file view'
    end
    info = ensure_buf(t)
    apply(t, info, view)
  end
  local win = ui.get_code_win()
  if vim.api.nvim_win_get_buf(win) ~= info.buf then
    vim.api.nvim_win_set_buf(win, info.buf)
  end
  window_options(win)
  local row
  if opts.target then
    row = M.row_for_line(view, opts.target.si, opts.target.line)
  else
    row = view.heads[pos]
  end
  row = math.min(row or 1, vim.api.nvim_buf_line_count(info.buf))
  vim.api.nvim_win_set_cursor(win, { row, 0 })
  vim.api.nvim_win_call(win, function()
    vim.cmd(opts.target and 'normal! zz' or 'normal! zt')
  end)
  return true
end

--- Build the view of `t` again where it is shown (in any window), with the
--- cursors kept on the same (entry, line). Does nothing when it is not shown.
--- Raises when git fails.
function M.rebuild(t)
  local info = info_of_tour(t)
  if not (info and info.view and #vim.fn.win_findbuf(info.buf) > 0) then
    return false
  end
  local saved = capture(info)
  apply(t, info, M.build(t))
  restore(info, saved)
  return true
end

--- Leave the compact view for the file: the code window shows the file at
--- the line under the cursor, and the compact buffers go. For `close`.
function M.leave()
  local win = st.code_win
  if win and vim.api.nvim_win_is_valid(win) then
    local info = M.info_of(vim.api.nvim_win_get_buf(win))
    if info then
      local si, line = M.file_line(info.view, cursor_row(win))
      local step = si and info.t.steps[si]
      if step and vim.fn.filereadable(step.file) == 1 then
        pcall(vim.api.nvim_win_call, win, function()
          vim.cmd.edit(vim.fn.fnameescape(step.file))
          if line then
            vim.api.nvim_win_set_cursor(win, { math.min(line, vim.api.nvim_buf_line_count(0)), 0 })
          end
        end)
      end
    end
  end
  for buf in pairs(st.compact) do
    if valid(buf) then
      if #vim.fn.win_findbuf(buf) == 0 then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      else
        vim.bo[buf].bufhidden = 'wipe'
      end
    end
    st.compact[buf] = nil
  end
  for _, t in ipairs(st.tours) do
    t.compact = nil
  end
end

return M
