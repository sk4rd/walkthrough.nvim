-- The list of loaded tours. No windows and no files: adding, replacing,
-- switching and counting. `st.tours` holds the tours and `st.active` the
-- one on screen; `st.history`, `st.pos` and `st.tour_group` are its views
-- (see state.lua).
local st = require('walkthrough.state')
local tour = require('walkthrough.tour')

local M = {}

function M.active()
  return st.tours[st.active]
end

-- A step is "the same" across resends when file and title match.
local function key(step)
  return vim.fn.fnamemodify(step.file, ':p') .. '\0' .. (step.title or '')
end

--- Index and tour with this group (nil is the unnamed tour).
function M.find(group)
  for i, t in ipairs(st.tours) do
    if t.group == group then
      return i, t
    end
  end
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

--- { total, answered, revealed } over the steps of `t` that have a check, or
--- nil when none has one.
function M.check_counts(t)
  local counts
  for _, s in ipairs(t.steps) do
    if s.check then
      counts = counts or { total = 0, answered = 0, revealed = 0 }
      counts.total = counts.total + 1
      counts.answered = counts.answered + (s.check.reply and 1 or 0)
      counts.revealed = counts.revealed + (s.check.revealed and 1 or 0)
    end
  end
  return counts
end

--- Make `t` the active tour: it replaces the loaded tour of the same group
--- or is added after the others. What the user did survives the resend: steps
--- with the same file and title keep their `seen` flag, their comments and
--- the state of their check (while its question is the same); the tour keeps
--- its depth and its comment counter.
function M.put(t)
  local idx, old = M.find(t.group)
  if old then
    local before = {}
    for _, s in ipairs(old.steps) do
      -- The comments' lines are those of the file as it is now.
      pcall(tour.sync, s)
      before[key(s)] = before[key(s)] or s
    end
    for _, s in ipairs(t.steps) do
      local o = before[key(s)]
      if o then
        s.seen = o.seen or s.seen
        if o.comments and #o.comments > 0 then
          s.comments = vim.deepcopy(o.comments)
        end
        if type(o.check) == 'table' and type(s.check) == 'table'
          and tour.text_of(o.check.question) == tour.text_of(s.check.question) then
          for flag in pairs(tour.internal_check_fields) do
            s.check[flag] = o.check[flag]
          end
        end
      end
    end
    t.depth = t.depth or old.depth
    t.next_comment = math.max(t.next_comment or 1, old.next_comment or 1)
    st.tours[idx] = t
  else
    table.insert(st.tours, t)
    idx = #st.tours
  end
  st.active = idx
  return idx
end

--- Add tours read from the state file. Tours of the same repository that are
--- loaded already are replaced by them. `active` is the group to show.
function M.adopt(list, root, active)
  local kept = {}
  for _, t in ipairs(st.tours) do
    if t.root ~= root then
      table.insert(kept, t)
    end
  end
  local first = #kept + 1
  vim.list_extend(kept, list)
  st.tours = kept
  st.active = first + #list - 1 -- the last one, unless the stored active tour is found
  for i = first, #kept do
    if kept[i].group == active then
      st.active = i
    end
  end
end

--- Remove every tour.
function M.clear()
  st.tours, st.active = {}, 0
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
  return t.group or '(unnamed)'
end

return M
