-- Annotated code tours, driven from outside Neovim over its server socket.
--
-- An external process (an agent) writes a step or tour as JSON and calls:
--   nvim --server $NVIM --remote-expr "v:lua.require'walkthrough'.load('/path/step.json')"
--
-- The step format is described in `:help walkthrough-format`. This file is
-- the public API; the work happens in:
--   state.lua  the global state table and config defaults
--   git.lua    everything that runs or parses git
--   tour.lua   validation, normalisation and patching (no windows)
--   ui.lua     overlay, notes, panel, layout
--   tours.lua  the list of loaded tours
--   store.lua  review state on disk (resume)
--   progress.lua  staged lines of the reviewed group
--   stage.lua  stage_group, with_tracked
--   send.lua   asking the agent about a note (senders)
--   feedback.lua  comments, decisions, checks, send/inbox, explain
--   reject.lua    discarding a group's unstaged changes
--   base.lua      the base version of the file in a float
--   snapshot.lua  the working tree as a commit under refs/walkthrough/
--   keys.lua      the default keys (setup) and the key cheat sheet
--   health.lua :checkhealth walkthrough
-- plugin/walkthrough.lua defines :Walkthrough and the <Plug> mappings.
--
-- The diff overlay redraws itself when the file is written, reloaded or
-- staged, so it stays correct while the user edits and stages during a tour.

local st = require('walkthrough.state')
local tour = require('walkthrough.tour')
local tours = require('walkthrough.tours')
local store = require('walkthrough.store')
local ui = require('walkthrough.ui')
local stage = require('walkthrough.stage')
local send = require('walkthrough.send')
local feedback = require('walkthrough.feedback')
local reject = require('walkthrough.reject')
local base = require('walkthrough.base')
local snapshot = require('walkthrough.snapshot')
local keys = require('walkthrough.keys')

local M = {}

local senders = { auto = true, claudecode = true, terminal = true, clipboard = true }

--- Optional: setup({ panel_side, panel_width, panel_min_width, code_min_ratio,
--- max_removed_lines, sender, terminal_pattern, state_dir, keys })
--- `keys`: true maps the default keys under <leader>w, a string uses that
--- prefix, false (default) maps nothing.
function M.setup(opts)
  opts = opts or {}
  if opts.panel_side and opts.panel_side ~= 'left' and opts.panel_side ~= 'right' then
    error('walkthrough: panel_side must be "left" or "right"')
  end
  if opts.code_min_ratio and (opts.code_min_ratio <= 0 or opts.code_min_ratio >= 1) then
    error('walkthrough: code_min_ratio must be between 0 and 1')
  end
  if opts.sender ~= nil and type(opts.sender) ~= 'function' and not senders[opts.sender] then
    error('walkthrough: sender must be "auto", "claudecode", "terminal", "clipboard" or a function')
  end
  st.config = vim.tbl_extend('force', st.config, opts)
  -- `keys` is true (prefix <leader>w), a prefix string, or false.
  local prefix = keys.prefix(st.config.keys)
  if prefix then
    keys.map(prefix)
  end
end

local function current()
  return st.history[st.pos]
end

-- Socket entry points ----------------------------------------------------------
--
-- They return "ok" or "error: <message>" instead of raising, so the caller
-- sees the problem in its shell output rather than the user getting an error
-- popup in the editor.

local function socket(fn)
  return function(...)
    local ok, err = pcall(fn, ...)
    return ok and 'ok' or ('error: ' .. tour.clean_error(err))
  end
end

local function read_json(path)
  local json = table.concat(vim.fn.readfile(path), '\n')
  return vim.json.decode(json, { luanil = { object = true, array = true } })
end

-- Put the screen back after a step failed to render: show the active tour's
-- step, or draw nothing when there is none.
local function reshow()
  local t = tours.active()
  if t and t.steps[t.pos] and pcall(ui.render, t.steps[t.pos], t.pos, #t.steps) then
    return
  end
  ui.clear()
end

-- Nothing is loaded and the repository has saved tours: bring them back
-- first, so that the next group sent after a restart does not wipe them. A
-- state file that cannot be used is left for the next save to replace.
local function merge_saved(root)
  if #st.tours > 0 then
    return
  end
  pcall(function()
    local saved = vim.fn.filereadable(store.path(root)) == 1 and store.read(root)
    if saved then
      tours.adopt(saved.tours, root, saved.active)
    end
  end)
end

-- Everything that can fail happens before the state changes: validation
-- first, then rendering the start step. If that still fails, the previous
-- view comes back, so state and screen agree.
M.load = socket(function(path)
  local data = read_json(path)
  if type(data) ~= 'table' or (next(data) ~= nil and vim.islist(data)) then
    error('a tour or step must be a JSON object', 0)
  end
  local snap = tours.snapshot()
  local function fail(err)
    tours.restore(snap)
    reshow()
    error(err, 0)
  end

  if data.steps ~= nil then
    local t, err = tour.prepare_tour(data)
    if not t then
      error(err, 0)
    end
    local root = store.root_of(t.steps[1].file)
    merge_saved(root)
    -- A tour of a group that is loaded already replaces it.
    local new = { group = t.group, steps = t.steps, pos = t.start, root = root }
    tours.put(new)
    local ok, e = pcall(ui.render, new.steps[new.pos], new.pos, #new.steps)
    if not ok then
      fail(e)
    end
    store.save()
    return
  end

  -- A lone step joins the active tour (and its group).
  local valid, err = tour.validate_step(data)
  if not valid then
    error(err, 0)
  end
  local root = store.root_of(data.file)
  merge_saved(root)
  local active = tours.active()
  if not active then
    active = { steps = {}, pos = 0, root = root }
    tours.put(active)
  end
  tour.prepare_step(data, active.group)
  table.insert(active.steps, data)
  local ok, e = pcall(ui.render, data, #active.steps, #active.steps)
  if not ok then
    -- Only steps that rendered stay, so a fixed and resent step does not
    -- leave a broken one behind.
    table.remove(active.steps)
    fail(e)
  end
  active.pos = #active.steps
  store.save()
end)

-- Change parts of the tour in place instead of resending it (far less for
-- the agent to write after an edit). The file holds one patch or a list:
--   { "step": 2, "from": 5, "to": 9, "panel": "..." }          step fields
--   { "step": 2, "unset": ["panel", "to"] }                     remove step fields
--   { "step": 2, "note": 3, "verdict": "done", "text": "..." }  one note, by number
--   { "step": 2, "note": 4, "line": 30, "text": "..." }         the next free number adds a note
--   { "step": 2, "note": 1, "remove": true }                    drops a note
--   { "step": 2, "note": 3, "unset": ["detail"] }               remove note fields
-- `step` defaults to the current one and refers to the active tour. The
-- whole list is applied to copies and swapped in only if every item and the
-- result are valid, so a failing list changes nothing. The current step is
-- redrawn without moving the cursor, unless its file or focus changed.
M.patch = socket(function(path)
  local data = read_json(path)
  local patches = (type(data) == 'table' and vim.islist(data)) and data or { data }
  -- The agent's numbers refer to the file as it is now: bring the steps it
  -- patches up to date first. A file that cannot be read is left for the
  -- patch to fix (or to fail validation).
  for _, p in ipairs(patches) do
    if type(p) == 'table' and p.comment ~= nil and p.step == nil then
      -- A comment patch names no step: any of them may be changed.
      for _, s in ipairs(st.history) do
        pcall(tour.sync, s)
      end
    else
      local n = type(p) == 'table' and (p.step == nil and st.pos or p.step) or nil
      if type(n) == 'number' and st.history[n] then
        pcall(tour.sync, st.history[n])
      end
    end
  end
  local changed, moved = tour.apply_patches(st.history, st.pos, patches)
  if not changed then
    error(moved, 0)
  end

  local old = {}
  for n, step in pairs(changed) do
    old[n] = st.history[n]
    st.history[n] = step
  end
  local step = changed[st.pos]
  if step then
    local ok, err = pcall(function()
      local count = #st.history
      local shown = st.code_win and vim.api.nvim_win_is_valid(st.code_win)
        and vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(st.code_win)) == vim.fn.fnamemodify(step.file, ':p')
      if moved[st.pos] or not shown then
        ui.render(step, st.pos, count)
      else
        ui.draw(step)
        ui.show_panel(step, st.pos, count, true)
      end
    end)
    if not ok then
      for n, s in pairs(old) do
        st.history[n] = s
      end
      reshow()
      error(err, 0)
    end
  end
  store.save()
  ui.refresh_progress()
end)

-- Where the user is, as JSON, so the agent can resend a fixed tour at the
-- same step: {"step":3,"total":8,"title":"...","file":"...","seen":2,
-- "groups":[...]} or {"step":0}. "stale" lists what edits have invalidated
-- (notes and group ranges to patch) or files that can no longer be read.
-- "groups" lists the loaded tours.
function M.status()
  local ok, res = pcall(function()
    local step = current()
    if not step then
      return vim.json.encode({ step = 0 })
    end
    -- Bring every step up to date so the agent hears about what an edit broke.
    local stale = {}
    for i, s in ipairs(st.history) do
      if vim.fn.filereadable(s.file) == 0 then
        table.insert(stale, { step = i, kind = 'missing' })
      else
        tour.sync(s)
        for _, note in ipairs(s.notes or {}) do
          if note.stale then
            table.insert(stale, { step = i, kind = 'note', note = note.n, line = note.line })
          end
        end
        for _, h in ipairs(s.hunks or {}) do
          if h.stale then
            table.insert(stale, { step = i, kind = 'hunk', from = h.from, to = h.to or h.from, group = h.group })
          end
        end
      end
    end
    local groups = {}
    for i, t in ipairs(st.tours) do
      table.insert(groups, {
        group = t.group, steps = #t.steps, seen = tours.seen_count(t), current = i == st.active,
        checks = tours.check_counts(t),
      })
    end
    local check
    if step.check then
      check = step.check.reply and 'answered' or step.check.revealed and 'revealed' or 'open'
    end
    return vim.json.encode({
      step = st.pos, total = #st.history, title = step.title, file = step.file, group = step.group,
      seen = tours.seen_count(tours.active()), groups = groups,
      stale = #stale > 0 and stale or nil,
      depth = tours.active().depth, check = check,
    })
  end)
  return ok and res or ('error: ' .. tour.clean_error(res))
end

-- Clear everything and close the panel; forget the loaded tours. What was
-- saved on disk stays, `resume` brings it back.
M.close = socket(ui.close)

-- Bring back the tours saved for the current repository (the working
-- directory's, else the current file's) and show the active one where the
-- user left it. Steps follow the edits made meanwhile; tours that were
-- committed and steps whose file is gone are dropped.
M.resume = socket(function()
  local root = store.find()
  if not root then
    error('nothing to resume: no saved review for this directory', 0)
  end
  local saved, err = store.read(root)
  if not saved then
    error(err, 0)
  end
  local snap = tours.snapshot()
  tours.adopt(saved.tours, root, saved.active)
  local t = tours.active()
  local ok, e = pcall(ui.render, t.steps[t.pos], t.pos, #t.steps)
  if not ok then
    tours.restore(snap)
    reshow()
    error(e, 0)
  end
  store.save()
end)

-- Record the working tree as refs/walkthrough/<name> (default "reviewed"),
-- for tours of "what changed since" (`"diff": "refs/walkthrough/<name>"`).
-- Returns the commit id, or "error: ...". Never raises.
function M.snapshot(name)
  local ok, res = pcall(snapshot.create, name)
  return ok and res or ('error: ' .. tour.clean_error(res))
end

-- Delete the saved review of the current repository and clear the screen.
M.discard = socket(function()
  store.remove()
  ui.close()
end)

-- User entry points ------------------------------------------------------------
--
-- Called from mappings: a problem becomes a notification, never an error.

-- Move through the tour: -1 back, 1 forward, 0 shows the current step again
-- (back from a jump to another file). The position changes only after the
-- target step rendered.
M.step = ui.safe(function(delta)
  local idx = st.pos + delta
  local target = st.history[idx]
  if not target then
    vim.notify('walkthrough: no ' .. (delta < 0 and 'earlier' or 'later') .. ' step', vim.log.levels.INFO)
    return
  end
  local ok, err = pcall(ui.render, target, idx, #st.history)
  if not ok then
    reshow()
    error(err, 0)
  end
  st.pos = idx
  store.save()
end)

-- Switch between the loaded tours: a number moves by that many tours
-- (wrapping), a name selects one ("next" and "prev" move by one), no argument
-- lists them. The tour shows the step where it was left.
M.group = ui.safe(function(arg)
  local n = #st.tours
  if n == 0 then
    vim.notify('walkthrough: no tour open', vim.log.levels.INFO)
    return
  end
  if arg == nil or arg == '' then
    local lines = {}
    for i, t in ipairs(st.tours) do
      table.insert(lines, ('%s %s: step %d/%d, seen %d'):format(
        i == st.active and '*' or ' ', tours.name(t), t.pos, #t.steps, tours.seen_count(t)))
    end
    vim.notify('walkthrough: loaded tours\n' .. table.concat(lines, '\n'), vim.log.levels.INFO)
    return
  end
  local delta
  local target
  if type(arg) == 'number' then
    delta = arg
  else
    for i, t in ipairs(st.tours) do
      if t.group == arg then
        target = i
      end
    end
    delta = not target and ({ next = 1, prev = -1 })[arg] or tonumber(arg)
    if not target and not delta then
      error(('no tour named "%s"'):format(arg), 0)
    end
  end
  target = target or (st.active - 1 + delta) % n + 1
  if target == st.active then
    vim.notify('walkthrough: already on this tour', vim.log.levels.INFO)
    return
  end
  local prev = st.active
  st.active = target
  local t = tours.active()
  local ok, err = pcall(ui.render, t.steps[t.pos], t.pos, #t.steps)
  if not ok then
    st.active = prev
    reshow()
    error(err, 0)
  end
  store.save()
end)

M.note = ui.safe(ui.note)
M.ask_line = ui.safe(send.ask_line)
-- `{ all = true }` stages the group in every file of the tour.
M.stage_group = ui.safe(stage.stage_group)

-- The user's side: comments, decisions, checks, and what goes to the agent.
M.comment = ui.safe(feedback.comment)
M.comment_delete = ui.safe(feedback.comment_delete)
M.decide = ui.safe(feedback.decide)
M.send = ui.safe(feedback.send)
M.explain = ui.safe(feedback.explain)
M.check = ui.safe(feedback.check)
M.reject_group = ui.safe(reject.reject_group)
M.base = ui.safe(base.show)
M.keys = ui.safe(keys.show)
-- The same items as `send`, as JSON; a socket entry point (see feedback.lua).
M.inbox = feedback.inbox

-- Helpers for mappings and other plugins.
M.with_tracked = stage.with_tracked
M.clear = ui.clear
M.panel = ui.panel
M.annotate = ui.annotate
M.keep_code_wide = ui.keep_code_wide

-- Live refresh ----------------------------------------------------------------

-- Redraw the marks when the tour's file changes on disk or in git. Unsaved
-- buffers are skipped: git only knows the file on disk, so the overlay would
-- not match what is on screen. The panel's winbar says so.
local function refresh(buf)
  local step = current()
  buf = buf or (st.code_win and vim.api.nvim_win_is_valid(st.code_win) and vim.api.nvim_win_get_buf(st.code_win))
  if not buf then
    return
  end
  if not step or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  -- Check the existing window only; a background event must never open one.
  if not (st.code_win and vim.api.nvim_win_is_valid(st.code_win)) or vim.api.nvim_win_get_buf(st.code_win) ~= buf then
    return
  end
  if vim.api.nvim_buf_get_name(buf) ~= vim.fn.fnamemodify(step.file, ':p') then
    return
  end
  if vim.bo[buf].modified then
    ui.update_winbar(step, st.pos, #st.history)
    return
  end
  local ok, err = pcall(ui.redraw, step, st.pos, #st.history)
  if not ok then
    vim.notify('walkthrough: ' .. tour.clean_error(err), vim.log.levels.WARN)
  end
  ui.update_winbar(step, st.pos, #st.history)
end

-- Events come in bursts (a stage fires several gitsigns updates), so they
-- only schedule one redraw of the code buffer, and one count of the staged
-- lines, a moment later. The count covers every file of the tour, so it also
-- runs for updates of buffers that are not on screen.
local refresh_pending, redraw_needed = false, false
local function schedule_refresh(buf)
  if not current() then
    return
  end
  local shown = st.code_win and vim.api.nvim_win_is_valid(st.code_win) and vim.api.nvim_win_get_buf(st.code_win)
  if shown and (not buf or buf == shown) then
    redraw_needed = true
  end
  if refresh_pending then
    return
  end
  refresh_pending = true
  vim.defer_fn(function()
    refresh_pending = false
    local redraw = redraw_needed
    redraw_needed = false
    if redraw then
      refresh()
    end
    ui.refresh_progress(true)
  end, 80)
end

local group = vim.api.nvim_create_augroup('walkthrough', { clear = true })
-- Windows opening (the agent terminal), being resized, or the screen size
-- changing can squeeze the code window; scheduled so the layout has settled.
vim.api.nvim_create_autocmd({ 'WinResized', 'VimResized', 'WinNew' }, {
  group = group,
  callback = function()
    if current() then
      vim.schedule(function()
        ui.keep_code_wide()
        -- A narrower panel may no longer fit its bar; the hints move below.
        pcall(ui.update_winbar, current(), st.pos, #st.history)
      end)
    end
  end,
})
-- Badges copy colors from the theme, so recompute them when the theme changes.
vim.api.nvim_create_autocmd('ColorScheme', { group = group, callback = ui.define_highlights })
-- Written by the user, accepted from an agent's diff, or reloaded after an
-- outside edit.
vim.api.nvim_create_autocmd({ 'BufWritePost', 'FileChangedShellPost' }, {
  group = group,
  callback = function(ev)
    schedule_refresh(ev.buf)
  end,
})
-- Typing or saving flips the buffer's modified flag: show or clear the
-- "unsaved changes" notice in the panel's winbar. BufModifiedSet alone does
-- not fire for edits made by typing, and newer Neovim versions no longer
-- have that event, so it is only used where it exists.
local modified_events = { 'TextChanged', 'TextChangedI', 'TextChangedP' }
if vim.fn.exists('##BufModifiedSet') == 1 then
  table.insert(modified_events, 'BufModifiedSet')
end
vim.api.nvim_create_autocmd(modified_events, {
  group = group,
  callback = function(ev)
    local step = current()
    if step and st.code_win and vim.api.nvim_win_is_valid(st.code_win)
      and vim.api.nvim_win_get_buf(st.code_win) == ev.buf then
      ui.update_winbar(step, st.pos, #st.history)
    end
  end,
})
-- Neovim only notices outside edits (sed, an agent's tools) on :checktime,
-- which it runs on few events by itself. Check whenever the user comes back
-- to the code window or to Neovim, so the overlay redraws on its own. Not
-- with unsaved changes: Neovim would ask the user what to do.
vim.api.nvim_create_autocmd({ 'WinEnter', 'FocusGained' }, {
  group = group,
  callback = function()
    if current() and st.code_win and vim.api.nvim_get_current_win() == st.code_win then
      local buf = vim.api.nvim_win_get_buf(st.code_win)
      if not vim.bo[buf].modified then
        vim.cmd('silent! checktime ' .. buf)
      end
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

ui.define_highlights()

return M
