-- Approval by staging: stage exactly the reviewed group's lines.
local st = require('walkthrough.state')
local git = require('walkthrough.git')
local ui = require('walkthrough.ui')
local tour = require('walkthrough.tour')
local tours = require('walkthrough.tours')

local M = {}

-- gitsigns reports an attach as finished before it has read the file's git
-- state; the line counts it puts in the buffer's status are what to wait
-- for. Gives up after about 3 seconds and goes on, so the caller can report
-- the problem.
local function await_attached(buf, fn)
  local tries = 0
  local function check()
    tries = tries + 1
    local status = vim.api.nvim_buf_is_valid(buf) and vim.b[buf].gitsigns_status_dict
    if (status and status.added ~= nil) or tries > 100 or not vim.api.nvim_buf_is_valid(buf) then
      return fn()
    end
    vim.defer_fn(check, 30)
  end
  check()
end

-- Run `fn` once git and gitsigns know the buffer's file. Neither can stage
-- parts of an untracked file, and an "unstage all" (`git reset`) turns new
-- files back into untracked ones. Such a file is registered with
-- `git add -N` first: that stages no content, it only makes git (and the
-- flake) see the file. gitsigns then has to re-attach to notice it.
-- `cancel(reason)`, when given, is called instead of `fn` if the file cannot
-- be registered, so a caller that waits for `fn` can go on.
function M.with_tracked(buf, fn, cancel)
  cancel = cancel or function() end
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  local file = vim.api.nvim_buf_get_name(buf)
  local dir = vim.fs.dirname(file)
  if file == '' or vim.bo[buf].buftype ~= '' then
    return fn()
  end
  if git.is_tracked(dir, file) then
    return fn() -- already tracked (or intent-to-add)
  end
  if not git.in_repo(dir) then
    return fn() -- not in a repository; let gitsigns report it
  end
  if git.run(dir, { 'check-ignore', '-q', '--', file }).code == 0 then
    vim.notify('walkthrough: file is ignored by git, not staging it', vim.log.levels.WARN)
    return cancel('ignored by git')
  end
  local res = git.write(dir, { 'add', '--intent-to-add', '--', file })
  if res.code ~= 0 then
    vim.notify('walkthrough: git add -N failed: ' .. git.first_line(res.stderr), vim.log.levels.ERROR)
    return cancel('git add -N failed')
  end
  vim.notify('walkthrough: new file registered with git add -N')
  local gitsigns = require('gitsigns')
  gitsigns.detach(buf)
  gitsigns.attach(buf, nil, nil, function()
    vim.schedule(function()
      await_attached(buf, function()
        vim.api.nvim_buf_call(buf, fn)
      end)
    end)
  end)
end

-- The lines of `range` that are still unstaged, in order.
local function pending_lines(unstaged, range)
  local lines = {}
  for line = range.from, range.to do
    if unstaged[line] then
      table.insert(lines, line)
    end
  end
  return lines
end

-- What git still has unstaged in the file, read fresh every time.
local function unstaged_now(buf)
  local hunks = git.hunks(vim.api.nvim_buf_get_name(buf), nil) or {}
  return git.unstaged_set(hunks, vim.api.nvim_buf_line_count(buf))
end

local function plural(n, word)
  return ('%d %s%s'):format(n, word, n == 1 and '' or 's')
end

-- gitsigns matches a range against hunks by their new-file lines, and a
-- deletion above line 1 has none (git reports it at line 0), so no range
-- finds it. Its hunk lookup for "no range" is by cursor, and that one
-- knows the case: line 1 finds a hunk that starts at 0 (gitsigns'
-- Hunks.find_hunk). The cursor and window are put back afterwards.
local function stage_top_deletion(buf, gitsigns, done)
  local win = vim.fn.win_findbuf(buf)[1]
  if not win then
    return done()
  end
  local prev_win = vim.api.nvim_get_current_win()
  local prev_cursor = vim.api.nvim_win_get_cursor(win)
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  gitsigns.stage_hunk(nil, {}, function()
    vim.schedule(function()
      pcall(function()
        if vim.api.nvim_win_is_valid(win) then
          vim.api.nvim_win_set_cursor(win, prev_cursor)
        end
        if vim.api.nvim_win_is_valid(prev_win) then
          vim.api.nvim_set_current_win(prev_win)
        end
      end)
      ui.safe(done)()
    end)
  end)
end

-- The part of stage_group that runs once the file is known to git.
-- gitsigns' stage_hunk toggles (a range with nothing to stage gets unstaged),
-- so a range is only passed to it while it still has unstaged lines. The
-- result is read back from git and handed to `done`:
--   { detached = true }                        gitsigns is not attached
--   { staged = n, left = n, left_lines = {} }  lines staged, lines still
--                                              unstaged, first line of each
--                                              range that was not staged
local function stage_ranges(ranges, buf, gitsigns, done)
  -- gitsigns attaches to buffers asynchronously and silently does nothing
  -- for a buffer it is not attached to yet.
  if not vim.b[buf].gitsigns_status_dict then
    return done({ detached = true })
  end

  local before = unstaged_now(buf)
  local total = 0
  for _, r in ipairs(ranges) do
    total = total + #pending_lines(before, r)
  end
  if total == 0 then
    return done({ staged = 0, left = 0, left_lines = {} })
  end

  local function finish()
    local after = unstaged_now(buf)
    local left, left_lines = 0, {}
    for _, r in ipairs(ranges) do
      local p = pending_lines(after, r)
      if #p > 0 then
        left = left + #p
        table.insert(left_lines, p[1])
      end
    end
    done({ staged = math.max(0, total - left), left = left, left_lines = left_lines })
  end

  -- stage_hunk is asynchronous, so stage one range after the other.
  local tried_top = {}
  local function stage(i)
    if i > #ranges then
      return finish()
    end
    local r = ranges[i]
    local unstaged, _, top_deletion = unstaged_now(buf)
    if top_deletion and r.from <= 1 and not tried_top[i] then
      tried_top[i] = true
      return stage_top_deletion(buf, gitsigns, function()
        stage(i) -- look again: the range may have more to stage
      end)
    end
    if #pending_lines(unstaged, r) == 0 then
      return stage(i + 1)
    end
    vim.api.nvim_buf_call(buf, function()
      gitsigns.stage_hunk({ r.from, r.to }, {}, function()
        vim.schedule(ui.safe(function()
          stage(i + 1)
        end))
      end)
    end)
  end
  stage(1)
end

-- The message for one file: what happened, as git reports it.
local function report_file(res, name)
  local level = vim.log.levels.INFO
  local msg
  if res.detached then
    level, msg = vim.log.levels.WARN, 'gitsigns is not attached to this file yet, try again'
  elseif res.staged == 0 and res.left == 0 then
    msg = 'nothing left to stage for this group in this file'
  else
    local left = #res.left_lines
    if left == 0 then
      msg = ('staged group "%s": %s'):format(name, plural(res.staged, 'line'))
    else
      local rest = ('%s could not be staged (%s %s)'):format(
        plural(left, 'range'), left == 1 and 'line' or 'lines', table.concat(res.left_lines, ', '))
      msg = res.staged > 0 and ('staged %s of group "%s"; %s'):format(plural(res.staged, 'line'), name, rest)
        or ('group "%s": %s'):format(name, rest)
      level = vim.log.levels.WARN
    end
  end
  vim.notify('walkthrough: ' .. msg, level)
end

-- Stage exactly the current group's changes in the code window's file, by
-- line range, so mixed hunks are split and other groups are never touched.
-- With `{ all = true }`: in every file of the tour (see stage_all).
function M.stage_group(opts)
  if opts and opts.all then
    return M.stage_all()
  end
  local step = st.history[st.pos]
  if not (step and step.hunks) then
    vim.notify('walkthrough: this step lists no group ranges ("hunks")', vim.log.levels.WARN)
    return
  end
  local ok, gitsigns = pcall(require, 'gitsigns')
  if not ok then
    vim.notify('walkthrough: gitsigns is not available', vim.log.levels.WARN)
    return
  end
  local buf = ui.code_buf()
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
  -- The numbers are synced against the file on disk, and gitsigns stages from
  -- the buffer: load an outside edit first, so both see the same lines.
  vim.cmd('silent! checktime ' .. buf)
  -- Numbers first follow the edits made since they were written, or the
  -- wrong lines would be staged.
  ui.redraw(step, st.pos, #st.history)
  for _, h in ipairs(step.hunks) do
    if h.stale and (h.group == nil or h.group == step.group) then
      vim.notify(('walkthrough: lines %d-%d of group "%s" were edited; not staging until the ranges are updated (patch "hunks")')
        :format(h.from, h.to or h.from, step.group or 'this step'), vim.log.levels.WARN)
      return
    end
  end
  M.with_tracked(buf, function()
    stage_ranges(tour.group_ranges(step), buf, gitsigns, function(res)
      report_file(res, step.group or 'this step')
    end)
  end)
end

-- Group-wide staging --------------------------------------------------------

local staging_all = false

-- gitsigns reads the git state of a buffer only while some window of the
-- current tab shows it (it defers the update until then), and stages from
-- that state. Files of the tour that are not on screen get a one-cell
-- floating window for as long as they are being staged. Returns the window to
-- close afterwards, or nil when the buffer is on screen already.
local function show_for_gitsigns(buf)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == buf then
      return nil
    end
  end
  local win = vim.api.nvim_open_win(buf, false, {
    relative = 'editor', row = 0, col = 0, width = 1, height = 1, style = 'minimal', focusable = true,
  })
  -- gitsigns catches up on BufEnter, which a window that is not entered
  -- does not fire.
  vim.api.nvim_exec_autocmds('BufEnter', { buffer = buf })
  return win
end

-- Prepare one file of the tour for staging. Returns its buffer, or nil and
-- why the file is skipped. Same rules as the single-file form: no unsaved
-- changes, outside edits loaded, ranges synced, none of them stale.
local function prepare_file(abs, steps)
  local buf = vim.fn.bufadd(abs)
  vim.fn.bufload(buf)
  if vim.bo[buf].modified then
    return nil, 'unsaved changes'
  end
  vim.cmd('silent! checktime ' .. buf)
  for _, step in ipairs(steps) do
    local ok, err = pcall(tour.sync, step)
    if not ok then
      return nil, tour.clean_error(err)
    end
    for _, h in ipairs(step.hunks) do
      if h.stale and (h.group == nil or h.group == step.group) then
        return nil, ('lines %d-%d were edited; patch "hunks" first'):format(h.from, h.to or h.from)
      end
    end
  end
  return buf
end

-- The ranges of all steps of one file, overlaps merged so no line is counted
-- twice.
local function merged_ranges(steps)
  local all = {}
  for _, step in ipairs(steps) do
    vim.list_extend(all, tour.group_ranges(step))
  end
  table.sort(all, function(a, b)
    return a.from < b.from
  end)
  local out = {}
  for _, r in ipairs(all) do
    local last = out[#out]
    if last and r.from <= last.to then
      last.to = math.max(last.to, r.to)
    else
      table.insert(out, { from = r.from, to = r.to })
    end
  end
  return out
end

-- Stage the reviewed group in every file of the active tour, one file after
-- the other. Files that are not open are loaded; untracked ones are
-- registered first. A file with edited (stale) ranges is skipped and named
-- in the final message, which reports what git has afterwards.
function M.stage_all()
  local t = tours.active()
  if not t then
    vim.notify('walkthrough: no tour open', vim.log.levels.INFO)
    return
  end
  local ok, gitsigns = pcall(require, 'gitsigns')
  if not ok then
    vim.notify('walkthrough: gitsigns is not available', vim.log.levels.WARN)
    return
  end
  if staging_all then
    vim.notify('walkthrough: already staging', vim.log.levels.INFO)
    return
  end

  local order, by_file = {}, {}
  for _, step in ipairs(t.steps) do
    if step.hunks then
      local abs = vim.fn.fnamemodify(step.file, ':p')
      if not by_file[abs] then
        by_file[abs] = {}
        table.insert(order, abs)
      end
      table.insert(by_file[abs], step)
    end
  end
  if #order == 0 then
    vim.notify('walkthrough: no step of this tour lists group ranges ("hunks")', vim.log.levels.WARN)
    return
  end
  local name = t.group or (t.steps[t.pos] or {}).group or 'this tour'

  -- Staging approves the code; the steps record that it was read.
  local unseen = #t.steps - tours.seen_count(t)
  if unseen > 0 then
    local question = ('%d of %d steps were not shown yet. Stage group "%s" in %s anyway?')
      :format(unseen, #t.steps, name, plural(#order, 'file'))
    if vim.fn.confirm(question, '&Stage\n&Cancel', 2) ~= 1 then
      vim.notify('walkthrough: not staged', vim.log.levels.INFO)
      return
    end
  end

  staging_all = true
  local staged, files, left, left_in, skipped = 0, 0, 0, {}, {}
  local function shown(abs)
    return vim.fn.fnamemodify(abs, ':~:.')
  end

  local function finish()
    staging_all = false
    local msg
    if staged == 0 and left == 0 and #skipped == 0 then
      msg = ('nothing left to stage for group "%s" in %s'):format(name, plural(#order, 'file'))
    else
      msg = ('staged group "%s": %s in %s'):format(name, plural(staged, 'line'), plural(files, 'file'))
      if left > 0 then
        msg = msg .. ('; %s left unstaged (%s)'):format(plural(left, 'line'), table.concat(left_in, ', '))
      end
      if #skipped > 0 then
        msg = msg .. '; skipped ' .. table.concat(skipped, ', ')
      end
    end
    vim.notify('walkthrough: ' .. msg, (left > 0 or #skipped > 0) and vim.log.levels.WARN or vim.log.levels.INFO)
    ui.refresh_progress()
  end

  local run
  local function advance(i)
    vim.schedule(function()
      run(i + 1)
    end)
  end

  -- Each file ends in exactly one of: skipped, or counted.
  run = function(i)
    local abs = order[i]
    if not abs then
      return finish()
    end
    local view
    local function leave()
      if view and vim.api.nvim_win_is_valid(view) then
        vim.api.nvim_win_close(view, true)
      end
    end
    local function skip(why)
      leave()
      table.insert(skipped, ('%s (%s)'):format(shown(abs), why))
      advance(i)
    end
    local steps = by_file[abs]
    local pok, err = pcall(function()
      local buf, why = prepare_file(abs, steps)
      if not buf then
        return skip(why)
      end
      local ranges = merged_ranges(steps)
      local function stage_it()
        M.with_tracked(buf, function()
          await_attached(buf, function()
            stage_ranges(ranges, buf, gitsigns, function(res)
              if res.detached then
                return skip('gitsigns is not attached')
              end
              if res.staged > 0 then
                files = files + 1
                staged = staged + res.staged
              end
              if res.left > 0 then
                left = left + res.left
                table.insert(left_in, ('%s: %s'):format(shown(abs), table.concat(res.left_lines, ' ')))
              end
              leave()
              advance(i)
            end)
          end)
        end, skip)
      end
      -- gitsigns attaches to a buffer that was read, but not before the
      -- event loop turned; ask for it (a no-op when attached) and let
      -- stage_it wait.
      view = show_for_gitsigns(buf)
      if not vim.b[buf].gitsigns_status_dict then
        gitsigns.attach(buf)
      end
      stage_it()
    end)
    if not pok then
      skip(tour.clean_error(err))
    end
  end
  run(1)
end

-- Shared with reject.lua.
M.merged_ranges = merged_ranges
M.pending_lines = pending_lines
M.unstaged_now = unstaged_now
M.plural = plural

return M
