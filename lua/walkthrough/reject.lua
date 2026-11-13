-- Rejecting a group: discard the reviewed group's unstaged changes in the
-- file of the current step. The counterpart of staging (stage.lua), with the
-- same rules: the ranges must be current, the buffer saved, and what is
-- already staged is never touched. gitsigns restores the lines
-- (`reset_hunk` with a range edits the buffer, taking the old text from the
-- index), the buffer is then written.
local st = require('walkthrough.state')
local git = require('walkthrough.git')
local ui = require('walkthrough.ui')
local tour = require('walkthrough.tour')
local tours = require('walkthrough.tours')
local store = require('walkthrough.store')
local stage = require('walkthrough.stage')
local compact = require('walkthrough.compact')

local M = {}

local rejecting = false
local perform -- the second half of reject_group
local perform_synced -- the last part of it, once gitsigns agrees with git

local function notify(msg, level)
  vim.notify('walkthrough: ' .. msg, level or vim.log.levels.INFO)
end

-- Every note, thread and hunk range of `steps` that is flagged stale, as a
-- set, so that the flags an edit adds later can be told from those before.
local function stale_set(steps)
  local set = {}
  for _, step in ipairs(steps) do
    for _, list in ipairs({ step.notes or {}, step.threads or {}, step.hunks or {} }) do
      for _, item in ipairs(list) do
        if item.stale then
          set[item] = true
        end
      end
    end
  end
  return set
end

-- gitsigns finds a deletion above line 1 only through the cursor on line 1
-- (see stage.lua); the cursor and window are put back afterwards.
local function reset_top_deletion(buf, gitsigns, done)
  local win = vim.fn.win_findbuf(buf)[1]
  if not win then
    return done()
  end
  local prev_win = vim.api.nvim_get_current_win()
  local prev_cursor = vim.api.nvim_win_get_cursor(win)
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  gitsigns.reset_hunk(nil, {}, function()
    vim.schedule(function()
      pcall(function()
        if vim.api.nvim_win_is_valid(win) then
          vim.api.nvim_win_set_cursor(win, { math.min(prev_cursor[1], vim.api.nvim_buf_line_count(buf)), prev_cursor[2] })
        end
        if vim.api.nvim_win_is_valid(prev_win) then
          vim.api.nvim_set_current_win(prev_win)
        end
      end)
      ui.safe(done)()
    end)
  end)
end

--- Discard the unstaged changes of the reviewed group in the current step's
--- file (in the compact view: in the file of the entry under the cursor),
--- after asking. Ranges are reset from the bottom of the file to the top,
--- so the lines of the ones still to do do not move.
function M.reject_group()
  local entry = compact.target()
  local t = entry and entry.t or tours.active()
  local step = entry and entry.step or (t and t.steps[t.pos])
  if not step then
    return notify('no review open')
  end
  if not step.hunks then
    return notify('this entry assigns no lines to commits ("hunks")', vim.log.levels.WARN)
  end
  local ok, gitsigns = pcall(require, 'gitsigns')
  if not ok then
    return notify('gitsigns is not available', vim.log.levels.WARN)
  end
  if rejecting then
    return notify('already rejecting')
  end
  local buf
  if entry then
    -- The compact view shows no file: load it, and show it where gitsigns
    -- can see it for as long as the reject takes.
    local abs = vim.fn.fnamemodify(step.file, ':p')
    buf = vim.fn.bufadd(abs)
    vim.fn.bufload(buf)
  else
    buf = ui.code_buf()
    if vim.api.nvim_buf_get_name(buf) ~= vim.fn.fnamemodify(step.file, ':p') then
      return notify('the code window shows another file; switch back to ' .. vim.fn.fnamemodify(step.file, ':~:.'),
        vim.log.levels.WARN)
    end
  end
  if vim.bo[buf].modified then
    return notify('save the file first', vim.log.levels.WARN)
  end
  vim.cmd('silent! checktime ' .. buf)

  local view = entry and stage.show_for_gitsigns(buf)
  local function leave()
    if view and vim.api.nvim_win_is_valid(view) then
      vim.api.nvim_win_close(view, true)
    end
  end
  local function bail(msg, level)
    leave()
    notify(msg, level)
  end
  if entry and not vim.b[buf].gitsigns_status_dict then
    gitsigns.attach(buf)
  end
  local function run()
    perform(t, step, buf, gitsigns, { leave = leave, bail = bail })
  end
  if entry then
    return stage.await_attached(buf, run)
  end
  run()
end

-- The rest of `reject_group`, once the buffer of the step's file is ready.
perform = function(t, step, buf, gitsigns, done)
  local leave, bail = done.leave, done.bail

  -- Every step of the tour about this file holds ranges of the group.
  local steps = {}
  for _, s in ipairs(t.steps) do
    if s.hunks and vim.fn.fnamemodify(s.file, ':p') == vim.fn.fnamemodify(step.file, ':p') then
      table.insert(steps, s)
    end
  end
  for _, s in ipairs(steps) do
    pcall(tour.sync, s)
  end
  for _, s in ipairs(steps) do
    for _, h in ipairs(s.hunks) do
      if h.stale and (h.group == nil or h.group == s.group) then
        return bail(('lines %d-%d of commit "%s" were edited; not rejecting until the ranges are updated (patch "hunks")')
          :format(h.from, h.to or h.from, s.group or 'this entry'), vim.log.levels.WARN)
      end
    end
  end

  local file = vim.api.nvim_buf_get_name(buf)
  if not git.is_tracked(vim.fs.dirname(file), file) then
    return bail('this file is new to git: there is nothing to restore it to', vim.log.levels.WARN)
  end
  if not vim.b[buf].gitsigns_status_dict then
    return bail('gitsigns is not attached to this file yet, try again', vim.log.levels.WARN)
  end

  -- gitsigns resets from its cache of the buffer's hunks, which is stale
  -- after a commit or reset until it has read the buffer again.
  rejecting = true -- no second reject while this waits
  stage.synced(buf, gitsigns, function(ok)
    rejecting = false -- perform_synced sets it again for the resets
    if not ok then
      return bail('gitsigns has not caught up with git, nothing was discarded (try again)', vim.log.levels.WARN)
    end
    local pok, perr = pcall(perform_synced, step, steps, buf, gitsigns, done)
    if not pok then
      rejecting = false
      leave()
      notify(tour.clean_error(perr), vim.log.levels.ERROR)
    end
  end)
end

perform_synced = function(step, steps, buf, gitsigns, done)
  local leave, bail = done.leave, done.bail
  local name = step.group or 'this entry'
  local unstaged, _, top_deletion = stage.unstaged_now(buf)
  local list, lines, pending_total = {}, {}, 0
  for _, r in ipairs(stage.merged_ranges(steps)) do
    local pending = stage.pending_lines(unstaged, r)
    if #pending > 0 then
      table.insert(list, r)
      pending_total = pending_total + #pending
      for _, l in ipairs(pending) do
        lines[l] = true
      end
    end
  end
  if pending_total == 0 then
    return bail(('nothing to reject: commit "%s" has no unstaged changes in this file'):format(name))
  end
  local question = ('Discard %s of commit "%s" in %s? Staged changes stay. This cannot be undone.')
    :format(stage.plural(pending_total, 'unstaged line'), name, vim.fn.fnamemodify(step.file, ':~:.'))
  if vim.fn.confirm(question, '&Discard\n&Cancel', 2) ~= 1 then
    return bail('not rejected')
  end

  local was_stale = stale_set(steps)
  table.sort(list, function(a, b)
    return a.from > b.from
  end)

  local function finish()
    rejecting = false
    leave()
    local pok, perr = pcall(function()
      if vim.bo[buf].modified then
        vim.api.nvim_buf_call(buf, function()
          vim.cmd('silent write')
        end)
      end
      local after = stage.unstaged_now(buf)
      local left = 0
      for _, r in ipairs(list) do
        left = left + #stage.pending_lines(after, r)
      end
      if left == 0 then
        -- These ranges are no longer changes: nothing is left to approve in them.
        for _, s in ipairs(steps) do
          s.hunks = vim.tbl_filter(function(h)
            if not (h.group == nil or h.group == s.group) then
              return true
            end
            for l = h.from, h.to or h.from do
              if not lines[l] then
                return true
              end
            end
            return false
          end, s.hunks)
        end
      end
      for _, s in ipairs(steps) do
        pcall(tour.sync, s)
        -- The reject moved the numbers, it did not make anything doubtful.
        for _, kind in ipairs({ 'notes', 'threads', 'hunks' }) do
          for _, item in ipairs(s[kind] or {}) do
            if item.stale and not was_stale[item] then
              item.stale = nil
            end
          end
        end
      end
      store.save()
      ui.update()
      ui.refresh_progress()
      local discarded = pending_total - left
      if left > 0 then
        notify(('discarded %s of commit "%s"; %s could not be discarded'):format(
          stage.plural(discarded, 'line'), name, stage.plural(left, 'line')), vim.log.levels.WARN)
      else
        notify(('discarded %s of commit "%s" in %s; staged changes were kept'):format(
          stage.plural(discarded, 'unstaged line'), name, vim.fn.fnamemodify(step.file, ':~:.')))
      end
    end)
    if not pok then
      notify(tour.clean_error(perr), vim.log.levels.ERROR)
    end
  end

  local function reset(i)
    local r = list[i]
    if not r then
      return finish()
    end
    -- Line 1 counts as pending only because of a deletion above it, which
    -- is reset on its own below.
    local top = top_deletion and r.from <= 1
    local from = top and 2 or r.from
    local function next_range()
      vim.schedule(ui.safe(function()
        reset(i + 1)
      end))
    end
    local function after_range()
      if top then
        return reset_top_deletion(buf, gitsigns, next_range)
      end
      next_range()
    end
    local has_lines = false
    for l = from, r.to do
      has_lines = has_lines or unstaged[l] == true
    end
    if not has_lines then
      return after_range()
    end
    vim.api.nvim_buf_call(buf, function()
      gitsigns.reset_hunk({ from, r.to }, {}, function()
        vim.schedule(ui.safe(after_range))
      end)
    end)
  end

  rejecting = true
  local run_ok, run_err = pcall(reset, 1)
  if not run_ok then
    rejecting = false
    leave()
    error(run_err, 0)
  end
end

return M
