-- The list of loaded tours. No windows and no files: adding, replacing,
-- switching and counting. `st.tours` holds the tours and `st.active` the
-- one on screen; `st.history`, `st.pos` and `st.tour_group` are its views
-- (see state.lua).
local st = require('walkthrough.state')
local tour = require('walkthrough.tour')

local M = {}

--- The name the map and the messages give the tour of threads on files that
--- are in no review (flagged `extra`).
M.OTHER = 'Other files'

function M.active()
  return st.tours[st.active]
end

-- A step is "the same" across resends when file and title match.
local function key(step)
  return vim.fn.fnamemodify(step.file, ':p') .. '\0' .. (step.title or '')
end

--- Index and tour with this group (nil is the unnamed tour). The tour of
--- `Other files` has no group but is not the unnamed tour.
function M.find(group)
  for i, t in ipairs(st.tours) do
    if t.group == group and not t.extra and not t.plan then
      return i, t
    end
  end
end

--- Index and tour of `Other files` for this repository root.
function M.find_extra(root)
  for i, t in ipairs(st.tours) do
    if t.extra and t.root == root then
      return i, t
    end
  end
end

--- The loaded tours of a repository root: those of a change in load order,
--- then `Other files`. A plan review (flagged `plan`, see plan.lua) is none of
--- them: it is listed only when `with_plans` asks, last (the saved state wants
--- it, nothing else).
function M.in_root(root, with_plans)
  local out = {}
  for _, t in ipairs(st.tours) do
    if t.root == root and not t.extra and not t.plan then
      table.insert(out, t)
    end
  end
  for _, t in ipairs(st.tours) do
    if t.root == root and t.extra then
      table.insert(out, t)
    end
  end
  for _, t in ipairs(with_plans and st.tours or {}) do
    if t.root == root and t.plan then
      table.insert(out, t)
    end
  end
  return out
end

--- The plan reviews, in load order.
function M.plans()
  local out = {}
  for _, t in ipairs(st.tours) do
    if t.plan then
      table.insert(out, t)
    end
  end
  return out
end

--- The number of loaded tours that are not plan reviews.
function M.count()
  return #st.tours - #M.plans()
end

function M.has_root(root)
  for _, t in ipairs(st.tours) do
    if t.root == root then
      return true
    end
  end
  return false
end

--- The tours "the repository" means when nothing says which: those of the
--- active tour's root, else every loaded tour. A plan review is in neither.
function M.scope()
  local active = M.active()
  if active then
    return M.in_root(active.root)
  end
  local out = vim.tbl_filter(function(t)
    return not t.plan
  end, st.tours)
  table.sort(out, function(a, b)
    return (a.extra and 1 or 0) < (b.extra and 1 or 0)
  end)
  return out
end

local function realpath(path)
  return vim.uv.fs_realpath(path) or path
end

--- Where `file` is an entry of a loaded tour: a list of { t, si, step },
--- the active tour first, then the other tours of a change, then `Other
--- files`; within a tour the shown step first. With `root`, only tours of
--- that repository root. A thread on the file goes to the first one.
function M.entries(file, root)
  local abs = vim.fn.fnamemodify(file, ':p')
  local real = realpath(abs)
  local active = M.active()
  local order = { active }
  for _, t in ipairs(st.tours) do
    if t ~= active and not t.extra then
      table.insert(order, t)
    end
  end
  for _, t in ipairs(st.tours) do
    if t ~= active and t.extra then
      table.insert(order, t)
    end
  end
  local out = {}
  for _, t in ipairs(order) do
    if root == nil or t.root == root then
      local found = {}
      for si, step in ipairs(t.steps) do
        local candidate = vim.fn.fnamemodify(step.file, ':p')
        if candidate == abs or realpath(candidate) == real then
          table.insert(found, { t = t, si = si, step = step })
        end
      end
      table.sort(found, function(a, b)
        local pa, pb = a.si == t.pos and 0 or 1, b.si == t.pos and 0 or 1
        return pa ~= pb and pa < pb or a.si < b.si
      end)
      vim.list_extend(out, found)
    end
  end
  return out
end

--- The steps that carry threads, by the real path of their file:
--- path -> list of { t, si, step }. What the thread drawer needs, with one
--- lookup per buffer instead of one scan of the tours.
function M.threaded_index()
  local index = {}
  for _, t in ipairs(st.tours) do
    for si, step in ipairs(t.steps) do
      if step.threads and #step.threads > 0 then
        local key = realpath(vim.fn.fnamemodify(step.file, ':p'))
        index[key] = index[key] or {}
        table.insert(index[key], { t = t, si = si, step = step })
      end
    end
  end
  return index
end

--- The key of `index` (see threaded_index) for a buffer's file.
function M.index_key(file)
  return realpath(vim.fn.fnamemodify(file, ':p'))
end

--- The tour `Other files` of this root, made when missing, and in it the
--- entry for `file` (made when missing, with no diff and no group). Returns
--- { t, si, step }. Changes nothing else: the active tour stays.
function M.extra_entry(root, file)
  local abs = vim.fn.fnamemodify(file, ':p')
  local _, t = M.find_extra(root)
  if t then
    for si, step in ipairs(t.steps) do
      if vim.fn.fnamemodify(step.file, ':p') == abs then
        return { t = t, si = si, step = step }
      end
    end
  end
  local step = { file = abs, diff = false }
  local ok, err = tour.validate_step(step)
  if not ok then
    error(err, 0)
  end
  tour.prepare_step(step)
  if not t then
    t = { extra = true, steps = {}, pos = 1, root = root }
    table.insert(st.tours, t)
  end
  table.insert(t.steps, step)
  return { t = t, si = #t.steps, step = step }
end

--- Take `t` out of the loaded tours. The active tour is none afterwards
--- when it was `t`.
function M.remove(t)
  for i, x in ipairs(st.tours) do
    if x == t then
      table.remove(st.tours, i)
      if st.active == i then
        st.active = 0
      elseif st.active > i then
        st.active = st.active - 1
      end
      return
    end
  end
end

--- A new thread id for tour `t`: unique among all tours of its repository
--- root and never used again, even after the thread was deleted. The counter
--- of the root is kept in `st.counters` and in the state file.
function M.new_thread_id(t)
  local n = 1
  local peers = { t }
  for _, p in ipairs(st.tours) do
    if p ~= t and t.root ~= nil and p.root == t.root then
      table.insert(peers, p)
    end
  end
  if t.root ~= nil then
    n = math.max(n, st.counters[t.root] or 1)
  end
  for _, p in ipairs(peers) do
    n = math.max(n, p.next_thread or 1)
    for _, step in ipairs(p.steps) do
      for _, th in ipairs(step.threads or {}) do
        n = math.max(n, (tonumber(tostring(th.id):match('^t(%d+)$')) or 0) + 1)
      end
    end
  end
  if t.root ~= nil then
    st.counters[t.root] = n + 1
  end
  t.next_thread = n + 1
  return 't' .. n
end

--- The next free thread number of a root: what the state file keeps.
function M.counter(root)
  local n = st.counters[root] or 1
  for _, t in ipairs(st.tours) do
    if t.root == root then
      n = math.max(n, t.next_thread or 1)
      for _, step in ipairs(t.steps) do
        for _, th in ipairs(step.threads or {}) do
          n = math.max(n, (tonumber(tostring(th.id):match('^t(%d+)$')) or 0) + 1)
        end
      end
    end
  end
  return n
end

--- Number of steps of `t` that have been shown.
function M.seen_count(t)
  local n = 0
  for _, s in ipairs(t.steps) do
    if s.seen then
      n = n + 1
    end
  end
  return n
end

--- How many threads of `list` (tours) are in each state: { draft, waiting,
--- answered, proposed, ... }, only the states that occur. What the user
--- marked and the agent was not told counts as `draft` ("not sent"): a thread
--- with a decision marked, and a finding with a decision marked.
function M.thread_counts(list)
  local counts = {}
  local function add(state)
    counts[state] = (counts[state] or 0) + 1
  end
  for _, t in ipairs(list) do
    for _, s in ipairs(t.steps) do
      for _, th in ipairs(s.threads or {}) do
        add(tour.unsent_decision(th) and 'draft' or th.state)
      end
      for _, note in ipairs(s.notes or {}) do
        if note.decision and not note.decision_sent then
          add('draft')
        end
      end
    end
  end
  return counts
end

--- The tour with this repository root that `:Walkthrough review` made from
--- git (see `auto` in init.lua), with its index.
function M.find_auto(root)
  for i, t in ipairs(st.tours) do
    if t.auto and (root == nil or t.root == root) then
      return i, t
    end
  end
end

-- What the user wrote on the steps of `old` goes to the steps of `t`. The
-- steps of a local review have no title, so they are matched by file alone;
-- a step that is gone takes its threads with it.
local function carry_threads(old, t)
  local by_file = {}
  for _, s in ipairs(old.steps) do
    -- The threads' lines are those of the file as it is now.
    pcall(tour.sync, s)
    local abs = vim.fn.fnamemodify(s.file, ':p')
    if s.threads and #s.threads > 0 then
      by_file[abs] = by_file[abs] or s
    end
  end
  for _, s in ipairs(t.steps) do
    local o = by_file[vim.fn.fnamemodify(s.file, ':p')]
    if o and not (s.threads and #s.threads > 0) then
      s.threads = vim.deepcopy(o.threads)
      by_file[vim.fn.fnamemodify(s.file, ':p')] = nil -- once: two steps must not share one thread
    end
  end
  t.next_thread = math.max(t.next_thread or 1, old.next_thread or 1)
end

--- Whether the user has a commit of the agent in front of them for `root`: a
--- tour that is not the local review (`auto`), `Other files` or a plan
--- review, and that was shown in this session. Tours that came back from the
--- state file silently (store.restore_for) and were never shown are not open
--- yet: a new commit of the agent takes over from them, as it always did.
function M.has_agent_commit(root)
  for _, t in ipairs(st.tours) do
    if t.root == root and not t.auto and not t.extra and not t.plan and t.shown then
      return true
    end
  end
  return false
end

--- Put `t` among the loaded tours: it replaces the loaded tour of the same
--- group or is added after the others. What the user did survives the resend:
--- steps with the same file and title keep their `seen` flag and their
--- threads; the tour keeps its depth, its view (compact or file), the commit
--- message proposed for it and its thread counter.
---
--- A tour with a group also replaces the local review of its repository (the
--- tour flagged `auto`), which hands its threads over by file. So does a
--- tour without a group that takes the place of a review.
---
--- `t` becomes the active tour, except a commit with a group that arrives
--- while the user is already in a map (a commit of the agent was shown, see
--- has_agent_commit): the first commit of a map is the
--- current one, so a later commit is added without switching, and a commit
--- that replaces one that is loaded keeps the user where they are (the
--- replaced tour stays the active tour when it was, and is not made active
--- when it was not). Returns the index of `t` and whether it is the active
--- tour now.
function M.put(t)
  local prev = M.active()
  local _, old = M.find(t.group)
  local activate = true
  if t.group ~= nil and prev then
    -- Nothing of this repository in front of the user: the commit is shown.
    activate = not M.has_agent_commit(t.root) or old == prev
  end
  if t.group ~= nil then
    local i, auto = M.find_auto(t.root)
    if auto then
      carry_threads(auto, t)
      t.view = t.view or auto.view
      table.remove(st.tours, i)
      -- The review on screen is gone: the commit takes its place.
      activate = activate or auto == prev
    end
  end
  local idx
  idx, old = M.find(t.group)
  if old then
    if old.auto then
      carry_threads(old, t)
    else
      local before = {}
      for _, s in ipairs(old.steps) do
        -- The threads' lines are those of the file as it is now.
        pcall(tour.sync, s)
        before[key(s)] = before[key(s)] or s
      end
      for _, s in ipairs(t.steps) do
        local o = before[key(s)]
        if o then
          s.seen = o.seen or s.seen
          if o.threads and #o.threads > 0 then
            s.threads = vim.deepcopy(o.threads)
          end
        end
      end
    end
    t.depth = t.depth or old.depth
    t.view = t.view or old.view
    -- The message the agent proposed for the commit stays until it is made.
    t.commit_message = t.commit_message or old.commit_message
    t.next_thread = math.max(t.next_thread or 1, old.next_thread or 1)
    st.tours[idx] = t
  else
    table.insert(st.tours, t)
    idx = #st.tours
  end
  if activate then
    st.active = idx
  else
    -- Indexes may have moved: find the tour that was on screen again.
    st.active = 0
    for i, x in ipairs(st.tours) do
      if x == prev then
        st.active = i
      end
    end
  end
  return idx, st.active == idx
end

--- Add tours read from the state file. Tours of the same repository that are
--- loaded already are replaced by them. `active` is the group to show; the
--- tour of `Other files` is never the one to show. `silent`: the tour on
--- screen, when it is of another repository, stays the active one.
function M.adopt(list, root, active, silent)
  local prev = M.active()
  -- A plan review that is loaded is the live one: the saved copy of it is
  -- dropped (its hook may be waiting).
  local kept, live = {}, {}
  for _, t in ipairs(st.tours) do
    if t.root ~= root or t.plan then
      table.insert(kept, t)
    end
    if t.plan then
      live[t.plan_id] = true
    end
  end
  local first = #kept + 1
  for _, t in ipairs(list) do
    if not (t.plan and live[t.plan_id]) then
      table.insert(kept, t)
    end
  end
  st.tours = kept
  local pick, match
  for i = first, #kept do
    if not kept[i].extra and not kept[i].plan then
      pick = i -- the last one, unless the stored active tour is found
      if kept[i].group == active then
        match = i
      end
    end
  end
  st.active = match or pick or 0
  if silent and prev and prev.root ~= root then
    for i, t in ipairs(kept) do
      if t == prev then
        st.active = i
      end
    end
  end
end

--- What the user wrote on `Other files` entries whose file is a step of `t`
--- goes to that step, and the entry goes away; an `Other files` tour left
--- without entries is removed. Called when a review or an agent's map has
--- been shown, so a failure on the way loses nothing. Returns whether
--- anything moved.
function M.absorb_extra(t)
  local _, extra = M.find_extra(t.root)
  if not extra or extra == t then
    return false
  end
  local keep = M.active()
  local moved = false
  local free = vim.list_slice(extra.steps)
  for _, s in ipairs(t.steps) do
    local abs = vim.fn.fnamemodify(s.file, ':p')
    for i, e in ipairs(free) do
      if vim.fn.fnamemodify(e.file, ':p') == abs then
        -- The lines are those of the file as it is now.
        pcall(tour.sync, e)
        s.threads = s.threads or {}
        vim.list_extend(s.threads, e.threads or {})
        for j, x in ipairs(extra.steps) do
          if x == e then
            table.remove(extra.steps, j)
            break
          end
        end
        table.remove(free, i)
        moved = true
        break
      end
    end
  end
  if moved then
    t.next_thread = math.max(t.next_thread or 1, extra.next_thread or 1)
    extra.pos = math.max(1, math.min(extra.pos or 1, #extra.steps))
    if #extra.steps == 0 then
      M.remove(extra)
      for i, x in ipairs(st.tours) do
        if x == keep then
          st.active = i
        end
      end
    end
  end
  return moved
end

--- Remove every tour but the plan reviews: a hook may be waiting for them,
--- and `close` does not answer it.
function M.clear()
  st.tours, st.active = M.plans(), 0
  -- The counters live as long as the tours; the state file keeps them.
  st.counters = {}
end

--- Move the active tour by `delta` tours, wrapping around.
function M.shift(delta)
  local n = #st.tours
  st.active = (st.active - 1 + delta) % n + 1
end

--- What to put back when something fails half-way: the list, the active tour
--- and every tour's position.
function M.snapshot()
  local pos = {}
  for i, t in ipairs(st.tours) do
    pos[i] = t.pos
  end
  return { tours = vim.list_slice(st.tours), active = st.active, pos = pos }
end

function M.restore(snap)
  st.tours, st.active = snap.tours, snap.active
  for i, t in ipairs(st.tours) do
    t.pos = snap.pos[i]
  end
end

--- A tour's name for messages.
function M.name(t)
  return t.extra and M.OTHER or t.group or '(unnamed)'
end

return M
