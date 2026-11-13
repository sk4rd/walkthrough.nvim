-- Annotate a plan, a change or any code in Neovim; the agent is driven from
-- outside Neovim over its server socket.
--
-- An external process (an agent) writes a commit of the map as JSON and calls:
--   nvim --server $NVIM --remote-expr "v:lua.require'walkthrough'.load('/path/commit.json')"
--
-- The format is described in `:help walkthrough-format`. This file is the
-- public API; the work happens in:
--   state.lua  the global state table and config defaults
--   git.lua    everything that runs or parses git
--   tour.lua   validation, normalisation and patching (no windows)
--   ui.lua     overlay, notes, the map panel, layout
--   tours.lua  the list of loaded tours
--   store.lua  review state on disk (resume)
--   progress.lua  staged lines of the reviewed group, per tour and per file
--   stage.lua  stage_group, with_tracked
--   send.lua   handing a message to the agent (senders)
--   feedback.lua  threads, decisions, send/inbox, explain
--   thread.lua    a thread or note in full, in a float
--   drawer.lua    threads in every buffer the code window's draw does not cover
--   reject.lua    discarding a group's unstaged changes
--   base.lua      the base version of the file in a float
--   compact.lua   the compact view: the changed parts of a tour's files in one buffer
--   commit.lua    step two of approval: check, message and commit what is staged
--   plan.lua      the agent's plan as a document to annotate, approve or send back
--   request.lua   asking the agent for the map of the change under review
--   snapshot.lua  the working tree as a commit under refs/walkthrough/
--   keys.lua      the default keys (setup) and the key cheat sheet
--   health.lua :checkhealth walkthrough
-- plugin/walkthrough.lua defines :Walkthrough and the <Plug> mappings.
--
-- The diff overlay redraws itself when the file is written, reloaded or
-- staged, so it stays correct while the user edits and stages during a tour.

local st = require('walkthrough.state')
local git = require('walkthrough.git')
local tour = require('walkthrough.tour')
local tours = require('walkthrough.tours')
local store = require('walkthrough.store')
local ui = require('walkthrough.ui')
local stage = require('walkthrough.stage')
local feedback = require('walkthrough.feedback')
local thread = require('walkthrough.thread')
local drawer = require('walkthrough.drawer')
local reject = require('walkthrough.reject')
local base = require('walkthrough.base')
local compact = require('walkthrough.compact')
local commit = require('walkthrough.commit')
local plan = require('walkthrough.plan')
local request = require('walkthrough.request')
local send = require('walkthrough.send')
local snapshot = require('walkthrough.snapshot')
local keys = require('walkthrough.keys')

local M = {}

local senders = { auto = true, claudecode = true, terminal = true, clipboard = true }

--- Optional: setup({ panel_side, panel_width, panel_min_width, code_min_ratio,
--- max_removed_lines, view, sender, submit, terminal_pattern, state_dir, keys })
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
  if opts.view ~= nil and opts.view ~= 'compact' and opts.view ~= 'file' then
    error('walkthrough: view must be "compact" or "file"')
  end
  if opts.sender ~= nil and type(opts.sender) ~= 'function' and not senders[opts.sender] then
    error('walkthrough: sender must be "auto", "claudecode", "terminal", "clipboard" or a function')
  end
  if opts.submit ~= nil and type(opts.submit) ~= 'boolean' then
    error('walkthrough: submit must be true or false')
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
  if t and t.steps[t.pos] and pcall(ui.render, t.steps[t.pos], t.pos) then
    return
  end
  ui.clear()
end

-- Everything that can fail happens before the state changes: validation
-- first, then rendering the start step. If that still fails, the previous
-- view comes back, so state and screen agree.
M.load = socket(function(path)
  local data = read_json(path)
  if type(data) ~= 'table' or (next(data) ~= nil and vim.islist(data)) then
    error('a map or an entry must be a JSON object', 0)
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
    store.merge_saved(root)
    -- A tour of a group that is loaded already replaces it.
    local new = { group = t.group, steps = t.steps, pos = t.start, root = root }
    tours.put(new)
    local ok, e = pcall(ui.render, new.steps[new.pos], new.pos)
    if not ok then
      fail(e)
    end
    -- What was written on files of this map before it came is theirs now.
    if tours.absorb_extra(new) then
      ui.update()
    end
    -- The map that was asked for has arrived.
    request.clear(root)
    store.save(root)
    return
  end

  -- A lone step joins the active tour (and its group).
  local valid, err = tour.validate_step(data)
  if not valid then
    error(err, 0)
  end
  local root = store.root_of(data.file)
  store.merge_saved(root)
  local active = tours.active()
  -- Files outside every review are not where a step of a tour goes.
  if active and active.extra then
    active = nil
  end
  if not active then
    active = { steps = {}, pos = 0, root = root }
    tours.put(active)
  end
  tour.prepare_step(data, active.group)
  table.insert(active.steps, data)
  local ok, e = pcall(ui.render, data, #active.steps)
  if not ok then
    -- Only steps that rendered stay, so a fixed and resent step does not
    -- leave a broken one behind.
    table.remove(active.steps)
    fail(e)
  end
  active.pos = #active.steps
  store.save(active.root)
end)

-- Change parts of what is loaded in place instead of resending it (far less
-- for the agent to write after an edit). The file holds one patch or a list:
--   { "step": 2, "from": 5, "to": 9, "title": "..." }          step fields
--   { "step": 2, "unset": ["title", "to"] }                     remove step fields
--   { "step": 2, "note": 3, "verdict": "done", "text": "..." }  one note, by number
--   { "step": 2, "note": 4, "line": 30, "text": "..." }         the next free number adds a note
--   { "step": 2, "note": 1, "remove": true }                    drops a note
--   { "step": 2, "note": 3, "unset": ["detail"] }               remove note fields
--   { "thread": "t1", "answer": "...", "proposal": true }       the agent's side of a thread
--   { "commit_message": "feat: ...", "group": "A" }             the message asked for by `commit`
-- `step` defaults to the current one and refers to the active tour. A thread
-- patch without `step` finds its thread in any tour of the repository (the
-- active tour's, else of every loaded one), `Other files` included: thread
-- ids are unique there. A commit message goes to the tour of `group` (default:
-- the active tour) and is shown in the open commit dialog. The whole list is applied to copies and swapped in
-- only if every item and the result are valid, so a failing list changes
-- nothing. The current step is redrawn without moving the cursor, unless its
-- file or focus changed. Works with no step shown.
M.patch = socket(function(path)
  local data = read_json(path)
  local patches = (type(data) == 'table' and vim.islist(data)) and data or { data }
  -- What a patch can reach: the steps of the active tour first, so their
  -- numbers are the steps' numbers, then the steps of its repository's other
  -- tours (only threads are addressed there, by id). Without an active tour,
  -- the steps of every loaded tour.
  local active = tours.active()
  local history, owners, reach = {}, {}, 0
  local function add(t)
    for i, step in ipairs(t.steps) do
      table.insert(history, step)
      owners[#history] = { t = t, i = i }
    end
  end
  if active then
    add(active)
    reach = #active.steps
    for _, t in ipairs(tours.in_root(active.root)) do
      if t ~= active then
        add(t)
      end
    end
  else
    for _, t in ipairs(tours.scope()) do
      add(t)
    end
  end
  -- The threads of a plan review are answered like any other, by id.
  for _, t in ipairs(tours.plans()) do
    add(t)
  end
  -- The agent's numbers refer to the file as it is now: bring the steps it
  -- patches up to date first. A file that cannot be read is left for the
  -- patch to fix (or to fail validation).
  for _, p in ipairs(patches) do
    if type(p) == 'table' and p.commit_message ~= nil then
      -- Not about a step.
    elseif type(p) == 'table' and p.thread ~= nil and p.step == nil then
      -- A thread patch names no step: any of them may be changed.
      for _, s in ipairs(history) do
        pcall(tour.sync, s)
      end
    else
      local n = type(p) == 'table' and (p.step == nil and st.pos or p.step) or nil
      if type(n) == 'number' and n <= reach and history[n] then
        pcall(tour.sync, history[n])
      end
    end
  end
  local changed, moved, commits = tour.apply_patches(history, st.pos, patches, reach)
  if not changed then
    error(moved, 0)
  end
  -- The tours the commit messages go to: found before anything changes, so a
  -- group that is not loaded fails the whole list.
  local messages = commit.resolve(commits)

  local old = {}
  for n, step in pairs(changed) do
    local o = owners[n]
    old[n] = o.t.steps[o.i]
    o.t.steps[o.i] = step
  end
  -- An answer in a thread never brings the shown step back to the code
  -- window: the user may be reading another file; the threads of any file are
  -- drawn where it is shown (drawer.lua).
  local only_threads = true
  for _, p in ipairs(patches) do
    only_threads = only_threads and type(p) == 'table' and p.thread ~= nil
  end
  local step = active and changed[st.pos]
  -- The compact view shows every step of the tour: a change to any of them
  -- builds it again.
  local in_compact = active and compact.shown(active)
  local touched = false
  for n in pairs(in_compact and changed or {}) do
    touched = touched or owners[n].t == active
  end
  if step or touched then
    local ok, err = pcall(function()
      if in_compact then
        if touched then
          compact.rebuild(active)
        end
        return
      end
      local shown = st.code_win and vim.api.nvim_win_is_valid(st.code_win)
        and vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(st.code_win)) == vim.fn.fnamemodify(step.file, ':p')
      if only_threads then
        if shown then
          ui.draw(step)
        end
      elseif moved[st.pos] or not shown then
        ui.render(step, st.pos)
      else
        ui.draw(step)
      end
    end)
    if not ok then
      for n, s in pairs(old) do
        owners[n].t.steps[owners[n].i] = s
      end
      reshow()
      error(err, 0)
    end
  end
  -- Marks of a step that was replaced and not drawn again would show its old
  -- text next to the drawer's.
  for _, replaced in pairs(old) do
    if st.drawn and st.drawn.step == replaced then
      ui.clear()
    end
  end
  local saved = {}
  for n in pairs(changed) do
    saved[owners[n].t.root or ''] = owners[n].t.root
  end
  for _, m in ipairs(messages) do
    commit.receive(m.t, m.text)
    saved[m.t.root or ''] = m.t.root
  end
  if active then
    saved[active.root or ''] = active.root
  end
  for _, root in pairs(saved) do
    store.save(root)
  end
  -- A title of any step may have changed, and a thread its state.
  ui.update_map()
  ui.refresh_float()
  ui.refresh_progress()
  ui.redraw_threads()
end)

-- Where the user is, as JSON, so the agent can resend a fixed tour at the
-- same step: {"step":3,"total":8,"title":"...","file":"...","seen":2,
-- "groups":[...]} or {"step":0}. "stale" lists what edits have invalidated
-- (notes and group ranges to patch) or files that can no longer be read.
-- "groups" lists the loaded tours (`Other files` is one, flagged "extra");
-- "commit" is {"group","check","message"} while a commit dialog is open;
-- "threads" counts the threads of the whole repository by state; "view" is
-- "compact" or "file", the view on screen. With
-- tours loaded but no step shown (only `Other files`, or a restored review
-- nobody opened) it is {"step":0,"threads":{...},"groups":[...]}. While a plan
-- review exists (plan.lua) "plan" is {"id","state","threads"}, state being
-- "pending" or "feedback-sent"; the plan is no tour of "groups".
function M.status()
  local ok, res = pcall(function()
    local step = current()
    local groups = {}
    for i, t in ipairs(st.tours) do
      if not t.plan then
        table.insert(groups, {
          group = t.extra and tours.OTHER or t.group, extra = t.extra, steps = #t.steps, seen = tours.seen_count(t),
          current = i == st.active,
        })
      end
    end
    local counts = tours.thread_counts(tours.scope())
    local function threads_of(always)
      if always or counts.draft or counts.waiting or counts.answered or counts.proposed then
        return {
          draft = counts.draft or 0, waiting = counts.waiting or 0, answered = counts.answered or 0,
          proposed = counts.proposed or 0,
        }
      end
    end
    if not step then
      if #groups == 0 then
        return vim.json.encode({ step = 0, plan = plan.status(), map = request.status() })
      end
      return vim.json.encode({
        step = 0, threads = threads_of(true), groups = groups, commit = commit.status(), plan = plan.status(),
        map = request.status(),
      })
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
    return vim.json.encode({
      step = st.pos, total = #st.history, title = step.title, file = step.file, group = step.group,
      seen = tours.seen_count(tours.active()), groups = groups,
      stale = #stale > 0 and stale or nil,
      depth = tours.active().depth,
      threads = threads_of(false),
      view = ui.current_view(tours.active()),
      commit = commit.status(),
      plan = plan.status(),
      map = request.status(),
    })
  end)
  return ok and res or ('error: ' .. tour.clean_error(res))
end

-- End the session: clear everything and close the panel; forget the loaded
-- tours. The tours of a change stay in the saved state (`resume` brings them
-- back); the threads on files no change lists (`Other files`) are deleted
-- from it, and the repository is not restored by itself again.
M.close = socket(function()
  local roots = {}
  for _, t in ipairs(st.tours) do
    if t.root and not t.plan then
      roots[t.root] = true
    end
  end
  -- The repository of the working directory or current file, even when
  -- nothing of it is loaded: its saved `Other files` goes too.
  local found_ok, found = pcall(store.find)
  if found_ok and found then
    roots[found] = true
  end
  commit.close_all()
  request.clear_all()
  ui.close()
  -- A plan review is left as it is (its hook may be waiting): its threads
  -- were wiped with the others' marks.
  ui.redraw_threads()
  for root in pairs(roots) do
    st.restored[root] = true
    pcall(store.drop_extra, root)
  end
end)

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
  store.adopt(root, saved)
  local t = tours.active()
  if t then
    local ok, e = pcall(ui.render, t.steps[t.pos], t.pos)
    if not ok then
      tours.restore(snap)
      reshow()
      error(e, 0)
    end
  else
    -- Only threads on files outside every review: nothing to show.
    ui.update()
  end
  store.save(root)
end)

-- The repository `review` looks at: the one of the current file, else the
-- one of the working directory.
local function review_dir()
  local name = vim.api.nvim_buf_get_name(0)
  if name ~= '' and vim.bo.buftype == '' then
    local dir = vim.fs.dirname(name)
    if git.in_repo(dir) then
      return dir
    end
  end
  return vim.fn.getcwd()
end

--- Start a review without an agent: one step per file that differs from
--- `ref` (default HEAD), in `git status` order, each with the diff overlay
--- and no title or ranges. It is the unnamed tour, flagged `auto`, and gives
--- way to a tour of the agent (see tours.put). Shows the first file. With no
--- changed file it says so and changes nothing.
M.review = ui.safe(function(ref)
  ref = (type(ref) == 'string' and vim.trim(ref) ~= '') and vim.trim(ref) or nil
  local root = git.toplevel(review_dir())
  if not root then
    error('not in a git repository', 0)
  end
  local names = git.changed_files(root, ref)
  if #names == 0 then
    vim.notify('walkthrough: no changed files' .. (ref and (' against ' .. ref) or ''), vim.log.levels.INFO)
    return
  end
  store.merge_saved(root)
  -- The unnamed tour is where a review goes; one from the agent must not be
  -- replaced by it.
  local _, unnamed = tours.find(nil)
  if unnamed and not unnamed.auto then
    error('a map of the agent without a commit name is loaded; close it first (:Walkthrough close)', 0)
  end
  local steps = {}
  for i, name in ipairs(names) do
    local step = { file = root .. '/' .. name, diff = ref or true }
    local ok, err = tour.validate_step(step, { index = i })
    if not ok then
      error(err, 0)
    end
    steps[i] = tour.prepare_step(step)
  end
  local snap = tours.snapshot()
  local new = { steps = steps, pos = 1, root = root, auto = true }
  tours.put(new)
  local ok, e = pcall(ui.render, steps[1], 1)
  if not ok then
    tours.restore(snap)
    reshow()
    error(e, 0)
  end
  -- What was written on these files before the review is theirs now.
  if tours.absorb_extra(new) then
    ui.update()
  end
  store.save(root)
end)

--- Ask the working session for the map of the change under review: one
--- message through the sender with the repository root, the base, the list of
--- changed files and what is expected. With no review open it starts the local
--- one first (`review`). Until a map of the agent arrives, `inbox` lists the
--- request and `status` has `"map": "requested"`. A failure to send is a
--- notification and changes nothing else.
M.request = ui.safe(function()
  local t = tours.active()
  if not t or t.extra then
    M.review()
    t = tours.active()
    if not t or t.extra then
      return -- review said why
    end
  end
  local info = request.describe(t)
  local ok, err = pcall(send.send, request.message(info))
  if not ok then
    vim.notify(('walkthrough: the agent was not asked for the map (%s)'):format(tour.clean_error(err)),
      vim.log.levels.WARN)
    return
  end
  request.record(info)
  vim.notify(('walkthrough: asked the agent for the map (%d file%s)'):format(
    #info.files, #info.files == 1 and '' or 's'), vim.log.levels.INFO)
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
  commit.close_all()
  request.clear_all()
  ui.close()
  ui.redraw_threads() -- a plan under review keeps its threads
end)

-- User entry points ------------------------------------------------------------
--
-- Called from mappings: a problem becomes a notification, never an error.

-- Move through the tour: -1 back, 1 forward, 0 shows the current step again
-- (back from a jump to another file). The position changes only after the
-- target step rendered.
M.step = ui.safe(function(delta)
  -- In the compact view the steps are the headings in the buffer: move from
  -- the entry the cursor is in.
  local t = tours.active()
  local at = delta ~= 0 and t and compact.cursor_entry(t)
  local idx = (at and at.si or st.pos) + delta
  local target = st.history[idx]
  if not target then
    vim.notify('walkthrough: no ' .. (delta < 0 and 'earlier' or 'later') .. ' entry', vim.log.levels.INFO)
    return
  end
  local ok, err = pcall(ui.render, target, idx, at and { reuse = true } or nil)
  if not ok then
    reshow()
    error(err, 0)
  end
  st.pos = idx
  store.save(tours.active().root)
end)

-- Switch between the loaded tours: a number moves by that many tours
-- (wrapping), a name selects one ("next" and "prev" move by one), no argument
-- lists them. The tour shows the step where it was left.
M.group = ui.safe(function(arg)
  -- The tours one can switch to: a plan review is none of them.
  local list = {}
  for i, t in ipairs(st.tours) do
    if not t.plan then
      table.insert(list, i)
    end
  end
  local n = #list
  if n == 0 then
    vim.notify('walkthrough: no review open', vim.log.levels.INFO)
    return
  end
  if arg == nil or arg == '' then
    local lines = {}
    for _, i in ipairs(list) do
      local t = st.tours[i]
      table.insert(lines, ('%s %s: entry %d/%d, seen %d'):format(
        i == st.active and '*' or ' ', tours.name(t), t.pos, #t.steps, tours.seen_count(t)))
    end
    vim.notify('walkthrough: loaded commits\n' .. table.concat(lines, '\n'), vim.log.levels.INFO)
    return
  end
  local delta
  local target
  if type(arg) == 'number' then
    delta = arg
  else
    for _, i in ipairs(list) do
      if st.tours[i].group == arg then
        target = i
      end
    end
    delta = not target and ({ next = 1, prev = -1 })[arg] or tonumber(arg)
    if not target and not delta then
      error(('no commit named "%s"'):format(arg), 0)
    end
  end
  if not target then
    local at = 0
    for k, i in ipairs(list) do
      at = i == st.active and k or at
    end
    target = list[(at - 1 + delta) % n + 1]
  end
  if target == st.active then
    vim.notify('walkthrough: already on this commit', vim.log.levels.INFO)
    return
  end
  local prev = st.active
  st.active = target
  local t = tours.active()
  local ok, err = pcall(ui.render, t.steps[t.pos], t.pos)
  if not ok then
    st.active = prev
    reshow()
    error(err, 0)
  end
  store.save(tours.active().root)
end)

--- Switch between the compact view and the file view of the active tour, or
--- go to the one named (`compact` or `file`). From the compact view the file
--- opens at the line under the cursor (a removed line goes to the line it is
--- shown above); from the file view the compact view opens on the same file
--- and line, or the nearest line it shows. The tour keeps the view while it
--- is loaded. A tour with nothing to show in the compact view stays in the
--- file view, and says why.
M.view = ui.safe(function(which)
  if which == '' then
    which = nil
  end
  if which ~= nil and which ~= 'compact' and which ~= 'file' then
    error('view takes compact or file', 0)
  end
  local t = tours.active()
  local step = t and t.steps[t.pos]
  if not step then
    vim.notify('walkthrough: no review open', vim.log.levels.INFO)
    return
  end
  local current = ui.current_view(t)
  local target = which or (current == 'compact' and 'file' or 'compact')
  if target == current then
    vim.notify(('walkthrough: already in the %s view'):format(current), vim.log.levels.INFO)
    t.view = target
    return
  end

  local si, line = t.pos, nil
  if current == 'compact' then
    si, line = compact.cursor_file_line(t)
    si = si or t.pos
  else
    -- The file in the code window, at its cursor: the current step when it
    -- lists the file, else the first one that does.
    local win = st.code_win
    if win and vim.api.nvim_win_is_valid(win) then
      local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
      local function lists(i)
        return vim.fn.fnamemodify(t.steps[i].file, ':p') == name
      end
      local found = lists(t.pos) and t.pos
      for i = 1, found and 0 or #t.steps do
        found = found or (lists(i) and i)
      end
      if found then
        si, line = found, vim.api.nvim_win_get_cursor(win)[1]
      end
    end
  end
  local entry = t.steps[si]
  local opts = { view = target, explicit = true }
  if target == 'compact' then
    opts.target = { si = si, line = line }
  else
    opts.line = line
  end
  local ok, err = pcall(ui.render, entry, si, opts)
  if not ok then
    reshow()
    error(err, 0)
  end
  st.pos = si
  -- A view that could not be shown is not the tour's choice.
  if ui.current_view(t) == target then
    t.view = target
  end
  store.save(t.root)
end)

M.note = ui.safe(ui.note)
--- Show the map panel, or hide it when it is open. Changes nothing about the
--- code window or the shown step.
M.map = ui.safe(ui.toggle_map)
-- `{ all = true }` stages the group in every file of the tour.
M.stage_group = ui.safe(stage.stage_group)

-- The user's side: threads, decisions, and what goes to the agent. `ask`
-- sends at once, `change` collects until `send`; `ask_line` is the old name
-- of `ask`.
M.ask = ui.safe(feedback.ask)
M.ask_line = M.ask
M.change = ui.safe(feedback.change)
M.thread = ui.safe(thread.show)
M.thread_delete = ui.safe(feedback.thread_delete)
M.decide = ui.safe(feedback.decide)
M.send = ui.safe(feedback.send)
M.explain = ui.safe(feedback.explain)
M.reject_group = ui.safe(reject.reject_group)
--- Step two of approval: run the check on what is staged, ask the agent for a
--- message, and commit from a dialog (commit.lua).
M.commit = ui.safe(commit.commit)
M.base = ui.safe(base.show)
M.keys = ui.safe(keys.show)
--- The plan of the agent (plan.lua). `plan` and `plan_result` are the socket
--- entry points of the hook script; the others are for the user.
M.plan = plan.open
M.plan_result = plan.result
M.plan_feedback = ui.safe(plan.feedback)
M.plan_approve = ui.safe(plan.approve)
M.plan_show = ui.safe(plan.show)
-- The same items as `send`, as JSON; a socket entry point (see feedback.lua).
M.inbox = feedback.inbox

-- Helpers for mappings and other plugins.
M.with_tracked = stage.with_tracked
-- Every mark of the plugin, the thread drawer's too.
function M.clear()
  ui.clear()
  drawer.clear()
end
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
    ui.update_winbar()
    return
  end
  local ok, err = pcall(ui.redraw, step)
  if not ok then
    vim.notify('walkthrough: ' .. tour.clean_error(err), vim.log.levels.WARN)
  end
  ui.update_winbar()
end

-- Events come in bursts (a stage fires several gitsigns updates), so they
-- only schedule one redraw of the code buffer, and one count of the staged
-- lines, a moment later. The count covers every file of the tour, so it also
-- runs for updates of buffers that are not on screen.
local refresh_pending, redraw_needed, compact_needed = false, false, false
local function schedule_refresh(buf)
  if not current() then
    return
  end
  local t = tours.active()
  if compact.shown(t) then
    -- The compact view is built from every file of the tour.
    if not buf or compact.owns(t, buf) then
      compact_needed = true
    end
  else
    local shown = st.code_win and vim.api.nvim_win_is_valid(st.code_win) and vim.api.nvim_win_get_buf(st.code_win)
    if shown and (not buf or buf == shown) then
      redraw_needed = true
    end
  end
  if refresh_pending then
    return
  end
  refresh_pending = true
  vim.defer_fn(function()
    refresh_pending = false
    local redraw, rebuild = redraw_needed, compact_needed
    redraw_needed, compact_needed = false, false
    if redraw then
      refresh()
    end
    if rebuild then
      ui.refresh_compact()
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
        -- A narrower panel may no longer fit its bar; the hints move below,
        -- and the map is laid out again for the new width.
        pcall(ui.update_winbar)
        pcall(ui.refit_map)
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
-- Threads are drawn wherever their file is shown (drawer.lua): again after a
-- save or an outside edit, which move them.
vim.api.nvim_create_autocmd({ 'BufWritePost', 'FileChangedShellPost' }, {
  group = group,
  callback = function(ev)
    pcall(drawer.on_event, ev)
  end,
})
-- A normal file comes on screen: the first time for a repository with nothing
-- loaded, its saved state comes back by itself (silently: no panel, no window
-- or buffer changes); then its threads are drawn. Cheap and quiet for every
-- other buffer.
local function on_shown(buf)
  pcall(function()
    if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= '' then
      return
    end
    local name = vim.api.nvim_buf_get_name(buf)
    -- Buffers of plugins (oil://, fugitive://) are not files on disk.
    if name == '' or name:match('^%a[%w+.-]*://') then
      return
    end
    if store.restore_for(name) then
      drawer.redraw()
    else
      drawer.on_event({ buf = buf })
    end
  end)
end
vim.api.nvim_create_autocmd('BufWinEnter', {
  group = group,
  callback = function(ev)
    on_shown(ev.buf)
  end,
})
-- The plugin may load after files are on screen (a lazy-loading plugin
-- manager, or setup() called late): those windows had their BufWinEnter
-- before anyone listened, so look at them once now.
vim.schedule(function()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    on_shown(vim.api.nvim_win_get_buf(win))
  end
end)
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
      and (vim.api.nvim_win_get_buf(st.code_win) == ev.buf or compact.owns(tours.active(), ev.buf)) then
      ui.update_winbar()
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
      if compact.shown(tours.active()) then
        -- A file of the tour changed on disk (an agent's edit): build the
        -- view again.
        if compact.stale(tours.active()) then
          schedule_refresh()
        end
      elseif not vim.bo[buf].modified then
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
