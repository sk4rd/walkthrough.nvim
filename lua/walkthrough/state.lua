-- All tour state lives in one global table, so it survives the module being
-- loaded again (a rebuild, or a live update with dofile): a fresh copy picks
-- up the running tour instead of starting empty while old marks stay drawn.
_G.walkthrough_state = _G.walkthrough_state or {
  code_win = nil, -- window showing the code
  panel_win = nil, -- window and buffer of the map panel
  panel_buf = nil,
  note_lines = {}, -- note number -> line, for jumping between notes
}
local st = _G.walkthrough_state
st.tours = st.tours or {} -- the loaded tours, each { group, steps, pos, root }
st.active = st.active or 0 -- index in `tours` of the tour on screen (0: none)
-- Thread ids: the next free number per repository root (one id space for all
-- tours of a root, see tours.new_thread_id). Roots whose stored state was
-- looked at, or that were closed, are not restored by themselves again
-- (store.restore_for). The git root of each directory seen, `false` outside a
-- repository, so showing a buffer costs no git call after the first.
st.counters = st.counters or {}
st.restored = st.restored or {}
st.dir_roots = st.dir_roots or {}
-- Plan reviews (plan.lua): the answer of an approved plan, by review id, kept
-- until the hook has read it (`plan_results`, with `plan_order` its oldest-first
-- ids), and the last number used per session (`plan_counters`).
st.plan_results = st.plan_results or {}
st.plan_order = st.plan_order or {}
st.plan_counters = st.plan_counters or {}
-- The compact view's scratch buffers (compact.lua): buffer -> { buf, t, view }.
st.compact = st.compact or {}
-- Maps asked of the agent that have not arrived (request.lua): root -> { root, base, files }.
st.map_requests = st.map_requests or {}
-- `st.drawn` is where the code window's full draw (ui.draw) put its marks:
-- { buf, step }. The thread drawer leaves that step's threads to it (drawer.lua).

-- An older copy of the module kept a single tour in these fields.
if rawget(st, 'history') ~= nil then
  if #st.history > 0 then
    st.tours = { { group = rawget(st, 'tour_group'), steps = st.history, pos = rawget(st, 'pos') or 1 } }
    st.active = 1
  end
  st.history, st.pos, st.tour_group = nil, nil, nil
end

-- `history`, `pos` and `tour_group` mean "the active tour's": other code
-- reads and writes them as plain fields, while the data lives on the tour,
-- so switching tours cannot leave a copy behind that disagrees.
local mirrored = { history = 'steps', pos = 'pos', tour_group = 'group' }
local mt = getmetatable(st) or {}
mt.__index = function(t, key)
  local field = mirrored[key]
  if not field then
    return nil
  end
  local tour = rawget(t, 'tours')[rawget(t, 'active')]
  if field == 'steps' then
    return tour and tour.steps or {}
  elseif field == 'pos' then
    return tour and tour.pos or 0
  end
  return tour and tour.group
end
mt.__newindex = function(t, key, value)
  local field = mirrored[key]
  if not field then
    return rawset(t, key, value)
  end
  local tour = rawget(t, 'tours')[rawget(t, 'active')]
  if tour then
    tour[field] = value
  end
end
setmetatable(st, mt)

-- Layout. The default puts the panel left of the code, which suits an agent
-- terminal on the far left: [ agent | panel | code ]. Kept in the state
-- table so a reload does not reset what setup() chose.
-- 'keep' adds options a newer version introduced to a state table that an
-- older copy of the module created.
st.config = vim.tbl_extend('keep', st.config or {}, {
  panel_side = 'left',
  panel_width = 40,
  view = 'compact', -- the view a tour opens in: 'compact' (the changed parts of its files) or 'file'
  panel_min_width = 30, -- the panel never shrinks below this to make room
  code_min_ratio = 0.5, -- the code window keeps at least this share of the screen
  max_removed_lines = 10, -- deleted lines shown per hunk before "… N more"
  sender = 'auto', -- 'auto', 'claudecode', 'terminal', 'clipboard' or fun(msg)
  -- A message is delivered so that the agent starts on it (typed and submitted,
  -- focus stays where it is). false: typed, not sent, and the focus moves.
  submit = true,
  -- Lua patterns, matched case-insensitively against the name and title of a
  -- terminal buffer; or fun(name, title, buf) -> boolean.
  terminal_pattern = { 'claude', 'codex', 'opencode', 'gemini', 'aider', '%f[%w]amp%f[%W]' },
  state_dir = vim.fn.stdpath('state') .. '/walkthrough', -- review state, one file per repository
  keys = false, -- true: map the default keys that are still free under <leader>w; a string: under that prefix
})

return st
