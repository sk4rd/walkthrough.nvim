-- Plan review: the agent's plan, opened in Neovim while the agent waits.
--
-- When the agent leaves plan mode, a hook (skills/walkthrough/hooks/plan-review.sh)
-- hands the plan over with `plan(path)` and then asks `plan_result(id)` about
-- once a second. The plan is stored as a file, `<state_dir>/plans/<id>.md`,
-- and opened read-only in a window of the current tab, next to the agent's
-- terminal (see "Where the plan is shown"). It is a tour flagged `plan`
-- with one entry, the plan file, so the threads work as on any code: they
-- follow edits, are drawn under the lines, are saved, and the agent answers
-- them with ordinary thread patches. A plan is in no map and no other action
-- (review, stage, commit, send, inbox) sees it.
--
-- The user writes comments on the plan's lines (one kind of thread, whichever
-- of `ask` and `change` is used; feedback.lua), all collected. `approve` lets
-- the plan through. `feedback` sends the comments back, the agent revises
-- the plan and shows it again (`plan` again for the same session: the same
-- review, the same window, the threads kept and moved along with the text).
--
-- The review lives on the tour: `plan_id`, `plan_session`, `plan_state`
-- ('pending' or 'feedback-sent') and, until the hook has taken it,
-- `plan_result` (the queued feedback). They are saved with it, except
-- `plan_result`. What an approval answers is kept in `st.plan_results` until
-- the hook has had time to read it.
local st = require('walkthrough.state')
local tour = require('walkthrough.tour')
local tours = require('walkthrough.tours')
local store = require('walkthrough.store')
local ui = require('walkthrough.ui')
local input = require('walkthrough.input')

local M = {}

local function notify(msg, level)
  vim.notify('walkthrough: ' .. msg, level or vim.log.levels.INFO)
end

-- The most approvals kept for hooks that have not asked yet.
local KEEP_RESULTS = 20
-- A quoted plan line, a message of the user, and the lines quoted for a thread.
local QUOTE_LINES = 5
local QUOTE_WIDTH = 200

-- Plans and their files ------------------------------------------------------------

local function plans_dir()
  return st.config.state_dir .. '/plans'
end

-- A name made of the session id that is safe in a file name.
local function slug(session)
  local s = tostring(session or ''):gsub('[^%w_.-]', '_'):sub(1, 64)
  if s == '' or s:match('^%.+$') then
    s = 'session'
  end
  return s
end

local function file_of(id)
  return plans_dir() .. '/' .. id .. '.md'
end

local function find_by_id(id)
  for _, t in ipairs(tours.plans()) do
    if t.plan_id == id then
      return t
    end
  end
end

local function find_by_session(session)
  local found
  for _, t in ipairs(tours.plans()) do
    if t.plan_session == session then
      found = t
    end
  end
  return found
end

-- The plan text as the lines of the file: no carriage returns, no empty
-- lines at the end.
local function to_lines(text)
  local lines = vim.split((text:gsub('\r\n?', '\n')), '\n', { plain = true })
  while #lines > 1 and lines[#lines] == '' do
    table.remove(lines)
  end
  return lines
end

local function write_file(path, lines)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  if vim.fn.writefile(lines, path) ~= 0 then
    error('cannot write ' .. path, 0)
  end
end

local function same_file(a, b)
  return a == b or (vim.uv.fs_realpath(a) or a) == (vim.uv.fs_realpath(b) or b)
end

-- The loaded buffer of a plan's file, if there is one.
local function buffer_of(t)
  local abs = vim.fn.fnamemodify(t.steps[1].file, ':p')
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf) ~= ''
      and same_file(vim.api.nvim_buf_get_name(buf), abs) then
      return buf
    end
  end
end

local function windows_of(t)
  local buf = buffer_of(t)
  return buf and vim.fn.win_findbuf(buf) or {}
end

-- Bring back the plan reviews saved in an earlier session (the plans
-- directory's state file); nothing happens when there is none.
local function restore()
  if vim.uv.fs_stat(plans_dir()) then
    store.merge_saved(store.root_of(plans_dir() .. '/plan.md'))
  end
end

-- The review the user means: the one whose buffer is current, else the only
-- one. `id` names one explicitly.
local function target(id)
  if id then
    local t = find_by_id(id)
    if not t then
      error('no plan review ' .. tostring(id), 0)
    end
    return t
  end
  local all = tours.plans()
  local cur = vim.api.nvim_get_current_buf()
  for _, t in ipairs(all) do
    if buffer_of(t) == cur then
      return t
    end
  end
  if #all == 0 then
    error('no plan is waiting for review', 0)
  elseif #all > 1 then
    error('several plans are waiting: do this in the window of the plan', 0)
  end
  return all[1]
end

-- The threads a plan carries that are not closed: what an approval drops.
local function open_threads(t)
  local n = 0
  for _, th in ipairs(t.steps[1].threads or {}) do
    if th.state ~= 'done' and th.state ~= 'declined' then
      n = n + 1
    end
  end
  return n
end

-- The window's bar: where the plan stands and the keys, only ones that are
-- really mapped (the others by their command).
local function winbar_text(t)
  local function esc(s)
    return (s:gsub('%%', '%%%%'))
  end
  local mapped = ui.plug_keys()
  local function label(name, word)
    local keys = mapped[name]
    return keys and (keys[1] .. ' ' .. word) or (':Walkthrough ' .. name)
  end
  local state = t.plan_state == 'feedback-sent' and 'feedback sent; waiting for the revised plan' or 'waiting for you'
  -- `ask` and `change` write the same comment: one of them is named.
  local write = mapped.ask and label('ask', 'comment') or mapped.change and label('change', 'comment')
    or ':Walkthrough ask to comment'
  local hints = { 'A approve', 'F feedback', write }
  return '%#WalkthroughBadge# Plan %*  ' .. esc(state) .. '  %#Comment#' .. esc(table.concat(hints, ' · '))
end

local function set_winbar(t)
  local buf = buffer_of(t)
  if not buf then
    return
  end
  local bar
  vim.api.nvim_buf_call(buf, function()
    bar = winbar_text(t)
  end)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    vim.api.nvim_set_option_value('winbar', bar, { scope = 'local', win = win })
  end
end

-- The buffer of a plan: read-only markdown, with the keys of the review.
local function setup_buffer(t, buf)
  vim.bo[buf].swapfile = false
  -- Not set again when it is shown again: that would run the FileType autocmds again.
  if vim.bo[buf].filetype ~= 'markdown' then
    vim.bo[buf].filetype = 'markdown'
  end
  vim.bo[buf].readonly = true
  vim.bo[buf].modifiable = false
  vim.keymap.set('n', 'A', ui.safe(function()
    M.approve(t.plan_id)
  end), { buffer = buf, nowait = true, silent = true, desc = 'Walkthrough: approve the plan' })
  vim.keymap.set('n', 'F', ui.safe(function()
    M.feedback(t.plan_id)
  end), { buffer = buf, nowait = true, silent = true, desc = 'Walkthrough: send feedback on the plan' })
  -- The keys of asking may have been mapped since.
  local group = vim.api.nvim_create_augroup('walkthrough_plan_' .. buf, { clear = true })
  vim.api.nvim_create_autocmd('BufWinEnter', {
    group = group,
    buffer = buf,
    callback = function()
      if find_by_id(t.plan_id) then
        pcall(set_winbar, t)
      end
    end,
  })
end

-- Where the plan is shown ---------------------------------------------------------
--
-- The plan goes into a window of the current tab that holds code, so the
-- agent's terminal stays on screen. When the review ends, the window shows
-- again what it showed before the first plan.

-- The plan window and what it showed before: `{ win, buf, view, split, from }`.
-- `split` says the window was made for the plan; `from` is the window the user
-- came from. Nil while no plan is on screen.
local place

-- The review whose plan the buffer shows, if any.
local function plan_of_buf(buf)
  for _, t in ipairs(tours.plans()) do
    if buffer_of(t) == buf then
      return t
    end
  end
end

local function is_float(win)
  return vim.api.nvim_win_get_config(win).relative ~= ''
end

-- Whether the plan may take the window: it is in this tab and holds code
-- (a file, or the compact view of the review), and it is no terminal, panel,
-- float or window fixed to its buffer.
local function fits(win)
  if not (win and win > 0 and vim.api.nvim_win_is_valid(win)) then
    return false
  end
  if vim.api.nvim_win_get_tabpage(win) ~= vim.api.nvim_get_current_tabpage()
    or win == st.panel_win or is_float(win) or vim.wo[win].winfixbuf then
    return false
  end
  local buf = vim.api.nvim_win_get_buf(win)
  return vim.bo[buf].buftype == '' or vim.b[buf].walkthrough_compact == true
end

-- The window for a plan that is not on screen: the code window of the review,
-- else the window in use most recently (the current one, the previous one,
-- then the others in order).
local function pick_window()
  if fits(st.code_win) then
    return st.code_win
  end
  local previous = vim.fn.winnr('#')
  local order = { vim.api.nvim_get_current_win(), previous > 0 and vim.fn.win_getid(previous) or 0 }
  vim.list_extend(order, vim.api.nvim_tabpage_list_wins(0))
  for _, win in ipairs(order) do
    if fits(win) then
      return win
    end
  end
end

-- Show `buf` in `win`, which keeps the alternate file. Raises when the buffer
-- in it cannot be left (unsaved changes, 'nohidden').
local function put_buf(win, buf)
  vim.api.nvim_win_call(win, function()
    vim.cmd('keepalt buffer ' .. buf)
  end)
end

-- A vertical split for the plan beside the terminal (else beside the current
-- window), on the side of it that faces the middle of the screen, so the
-- terminal stays where it is; a window that fills the screen gets the plan on
-- its left. Returns the window.
local function open_split(buf)
  local wins = vim.tbl_filter(function(win)
    return not is_float(win)
  end, vim.api.nvim_tabpage_list_wins(0))
  local current = vim.api.nvim_get_current_win()
  local anchor
  for _, win in ipairs({ current, unpack(wins) }) do
    if not anchor and vim.tbl_contains(wins, win) and vim.bo[vim.api.nvim_win_get_buf(win)].buftype == 'terminal' then
      anchor = win
    end
  end
  anchor = anchor or (vim.tbl_contains(wins, current) and current or wins[1])
  local middle = vim.api.nvim_win_get_position(anchor)[2] + vim.api.nvim_win_get_width(anchor) / 2
  return vim.api.nvim_open_win(buf, true, { split = middle < vim.o.columns / 2 and 'right' or 'left', win = anchor })
end

-- Leave Insert, Replace or Terminal mode, so that the first key in the window
-- we go to is a Normal mode key.
local function leave_modes()
  if vim.api.nvim_get_mode().mode:match('^[itR]') then
    vim.cmd('stopinsert')
  end
end

-- The loaded buffer of the plan's file with its keys (the file is loaded
-- without a swap file).
local function plan_buffer(t)
  local buf = buffer_of(t) or vim.fn.bufadd(vim.fn.fnamemodify(t.steps[1].file, ':p'))
  if not vim.api.nvim_buf_is_loaded(buf) then
    vim.cmd(('noswapfile call bufload(%d)'):format(buf))
  end
  setup_buffer(t, buf)
  return buf
end

-- Show the plan of `t` in the plan window and go there, in Normal mode. The
-- window stays the same for every plan and revision (in whatever tab the user
-- is); when it is gone, or no longer shows a plan, one is picked in the
-- current tab again.
local function go_to(t)
  local buf = plan_buffer(t)
  local from = vim.api.nvim_get_current_win()
  leave_modes()
  local reused = false
  if place and vim.api.nvim_win_is_valid(place.win) and plan_of_buf(vim.api.nvim_win_get_buf(place.win)) then
    reused = vim.api.nvim_win_get_buf(place.win) == buf or pcall(put_buf, place.win, buf)
    if reused and place.win ~= from then
      place.from = from
    end
  end
  if not reused then
    local win = pick_window()
    local found
    if win then
      found = {
        win = win, buf = vim.api.nvim_win_get_buf(win), split = false,
        view = vim.api.nvim_win_call(win, vim.fn.winsaveview),
      }
      -- A buffer with unsaved changes may not be left: make a window instead.
      if not pcall(put_buf, win, buf) then
        found = nil
      end
    end
    found = found or { win = open_split(buf), split = true }
    found.from = from
    place = found
  end
  vim.api.nvim_set_current_win(place.win)
  set_winbar(t)
  ui.redraw_threads()
end

-- A window the review is done with and that shows no plan any more (the
-- buffer is deleted next): the buffer it had before the plan, in the same
-- place; if that is gone, another listed buffer, else an empty one.
local function give_back(win, p)
  if p.split and #vim.tbl_filter(function(w)
    return not is_float(w)
  end, vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(win))) > 1 then
    return vim.api.nvim_win_close(win, true)
  end
  if p.buf and vim.api.nvim_buf_is_valid(p.buf) and not plan_of_buf(p.buf) and pcall(put_buf, win, p.buf) then
    if p.view then
      pcall(vim.api.nvim_win_call, win, function()
        vim.fn.winrestview(p.view)
      end)
    end
    return
  end
  local infos = vim.fn.getbufinfo({ buflisted = 1 })
  table.sort(infos, function(a, b)
    return a.lastused > b.lastused
  end)
  for _, info in ipairs(infos) do
    if vim.bo[info.bufnr].buftype == '' and not plan_of_buf(info.bufnr) and pcall(put_buf, win, info.bufnr) then
      return
    end
  end
  vim.api.nvim_win_call(win, function()
    vim.cmd('keepalt enew')
  end)
end

-- The user is back where they came from; a terminal is typed into at once.
local function go_back(p)
  if p.from and vim.api.nvim_win_is_valid(p.from) then
    vim.api.nvim_set_current_win(p.from)
    if vim.bo[vim.api.nvim_win_get_buf(p.from)].buftype == 'terminal' then
      vim.cmd('startinsert')
    end
  end
end

-- Socket: the hook hands a plan over ---------------------------------------------------

local function read_json(path)
  local json = table.concat(vim.fn.readfile(path), '\n')
  return vim.json.decode(json, { luanil = { object = true, array = true } })
end

-- The new text for a plan under review: the file and the buffer change, the
-- threads move along with the lines (and are stale where those were rewritten).
local function revise(t, lines)
  local step = t.steps[1]
  -- Positions refer to the text as it was.
  pcall(tour.sync, step)
  write_file(step.file, lines)
  tour.sync(step)
  local buf = buffer_of(t)
  if buf and vim.api.nvim_buf_is_loaded(buf) then
    -- Read-only would warn about the change (W10).
    vim.bo[buf].readonly = false
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].readonly = true
    vim.bo[buf].modified = false
  end
  -- Feedback the hook has not taken yet is still on its way.
  t.plan_state = t.plan_result and 'feedback-sent' or 'pending'
  -- The user waits for the revision: show it.
  local shown, err = pcall(go_to, t)
  if not shown then
    notify('the revised plan could not be shown: ' .. tour.clean_error(err) .. '; :Walkthrough plan shows it', vim.log.levels.WARN)
  end
  set_winbar(t)
  store.save(t.root)
  ui.update()
  notify('the plan was revised; threads kept: ' .. #(step.threads or {}))
end

--- Socket entry point of the hook. `path` is a file with the hook input
--- (JSON: `tool_input.plan`, `session_id`). Opens the plan in a window of the
--- current tab, next to the agent's terminal, or, when the same session has a review under way, puts the new text
--- in it. Returns the review id, or "error: ...". Never raises.
function M.open(path)
  local ok, res = pcall(function()
    local data = read_json(path)
    local input = type(data) == 'table' and data.tool_input
    local text = type(input) == 'table' and input.plan
    if type(text) ~= 'string' or vim.trim(text) == '' then
      error('the hook input has no tool_input.plan text', 0)
    end
    if data.tool_name ~= nil and data.tool_name ~= 'ExitPlanMode' then
      error('the hook input is not about ExitPlanMode', 0)
    end
    local session = slug(data.session_id)
    local lines = to_lines(text)
    vim.fn.mkdir(plans_dir(), 'p')
    restore()
    local existing = find_by_session(session)
    if existing then
      revise(existing, lines)
      return existing.plan_id
    end

    -- A number that was not used for this session in this run, nor by a
    -- file that is still there.
    local n = st.plan_counters[session] or 0
    local id
    repeat
      n = n + 1
      id = session .. '-' .. n
    until vim.fn.filereadable(file_of(id)) == 0 and not st.plan_results[id] and not find_by_id(id)
    st.plan_counters[session] = n

    local file = file_of(id)
    write_file(file, lines)
    local step = { file = file, diff = false }
    local valid, err = tour.validate_step(step)
    if not valid then
      vim.fn.delete(file)
      error(err, 0)
    end
    tour.prepare_step(step)
    local t = {
      plan = true, plan_id = id, plan_session = session, plan_state = 'pending', steps = { step }, pos = 1,
      root = store.root_of(file),
    }
    -- Not the active tour: the plan is in no map and no review.
    table.insert(st.tours, t)
    local opened, open_err = pcall(go_to, t)
    if not opened then
      tours.remove(t)
      if #tours.plans() == 0 then
        place = nil
      end
      vim.fn.delete(file)
      error(open_err, 0)
    end
    store.save(t.root)
    notify('a plan is waiting for review: write comments on its lines, then A approves and F sends them')
    return id
  end)
  return ok and res or ('error: ' .. tour.clean_error(res))
end

-- Socket: the hook asks ------------------------------------------------------------------

local function remember(id, result)
  st.plan_results[id] = result
  table.insert(st.plan_order, id)
  while #st.plan_order > KEEP_RESULTS do
    st.plan_results[table.remove(st.plan_order, 1)] = nil
  end
end

-- The feedback has reached the agent: what it was given counts as delivered.
local function handed_out(t, queued)
  for _, m in ipairs(queued.marks) do
    local th = tour.find_thread(t.steps, m.id)
    if th then
      th.sent = math.max(th.sent or 0, m.count)
      -- A message the user added meanwhile keeps the thread a draft.
      if #th.messages == m.count and th.state == 'draft' then
        th.state = 'waiting'
      end
    end
  end
  store.save(t.root)
  ui.update()
end

--- Socket entry point of the hook: where the review `id` stands, as JSON.
--- `{"state":"pending"}` (keep waiting), `{"state":"approve"}`, or
--- `{"state":"feedback","message":"..."}`. A feedback is handed out once; the
--- state is pending again afterwards, until the agent shows the revised plan.
--- An unknown id is "error: ...". Never raises.
function M.result(id)
  local ok, res = pcall(function()
    id = tostring(id)
    if st.plan_results[id] then
      return vim.json.encode({ state = st.plan_results[id].state })
    end
    local t = find_by_id(id)
    if not t then
      error('unknown plan review ' .. id, 0)
    end
    local queued = t.plan_result
    if queued then
      t.plan_result = nil
      handed_out(t, queued)
      return vim.json.encode({ state = 'feedback', message = queued.message })
    end
    return vim.json.encode({ state = 'pending' })
  end)
  return ok and res or ('error: ' .. tour.clean_error(res))
end

-- User: feedback -----------------------------------------------------------------------

local function id_number(id)
  return tonumber(tostring(id):match('^t(%d+)$')) or 0
end

-- The threads with a message of the user the agent has not been given, by place.
local function pending_threads(t)
  local step = t.steps[1]
  -- The lines are those of the plan as it is now.
  pcall(tour.sync, step)
  local out = {}
  for _, th in ipairs(step.threads or {}) do
    if th.state ~= 'done' and th.state ~= 'declined' and tour.pending_index(th) then
      table.insert(out, th)
    end
  end
  table.sort(out, function(a, b)
    if a.from ~= b.from then
      return a.from < b.from
    end
    return id_number(a.id) < id_number(b.id)
  end)
  return out
end

local function cap(text, width)
  return #text > width and (text:sub(1, width - 3) .. '...') or text
end

local function squash(text)
  return (tour.text_of(text):gsub('%s*\n%s*', ' / '))
end

--- The message for the agent: every comment in `threads`, numbered, with its
--- thread, the plan lines it is about (at most 5 quoted), and what the user
--- wrote. Ends with what is expected.
function M.build_message(t, threads)
  local plan_lines = vim.fn.readfile(t.steps[1].file)
  local lines = {
    ('Walkthrough: feedback from the user on your plan (%d comment%s).'):format(#threads, #threads == 1 and '' or 's'),
  }
  for i, th in ipairs(threads) do
    table.insert(lines, '')
    table.insert(lines, ('%d. Comment %s on plan %s %s:'):format(
      i, th.id, th.to > th.from and 'lines' or 'line',
      th.to > th.from and ('%d-%d'):format(th.from, th.to) or tostring(th.from)))
    for line = th.from, math.min(th.to, th.from + QUOTE_LINES - 1) do
      table.insert(lines, '   > ' .. cap(plan_lines[line] or '', QUOTE_WIDTH))
    end
    local more = th.to - th.from + 1 - QUOTE_LINES
    if more > 0 then
      table.insert(lines, ('   (%d more line%s)'):format(more, more == 1 and '' or 's'))
    end
    if th.stale then
      table.insert(lines, '   (The plan text on these lines was changed after this was written.)')
    end
    local first = tour.pending_index(th) or (#th.messages + 1)
    if first > 1 then
      table.insert(lines, '   Earlier in this thread:')
      for j = 1, first - 1 do
        local m = th.messages[j]
        table.insert(lines, ('     %s: %s'):format(m.by == 'user' and 'User' or 'You (agent)', cap(squash(m.text), 300)))
      end
    end
    for j = first, #th.messages do
      if th.messages[j].by == 'user' then
        table.insert(lines, '   User: ' .. (tour.text_of(th.messages[j].text):gsub('\n', '\n         ')))
      end
    end
  end
  table.insert(lines, '')
  table.insert(lines, 'Reply to every comment with a patch { "thread": "<id>", "answer": "..." } (tour.sh --patch),'
    .. ' and revise the plan where a comment asks for a change or shows that one is needed,'
    .. ' before presenting the plan again.')
  return table.concat(lines, '\n')
end

-- Make `message` what the hook gets next; the plan waits for the revision.
local function queue(t, message, marks)
  t.plan_result = { message = message, marks = marks }
  t.plan_state = 'feedback-sent'
  set_winbar(t)
  store.save(t.root)
  ui.update()
end

--- Send the comments on the plan back to the agent: one message with all
--- that was not delivered yet. Without any, ask what should change and send
--- that. The plan stays on screen. `id` names the review (default: the one of the
--- current buffer, else the only one).
function M.feedback(id)
  local t = target(id)
  local threads = pending_threads(t)
  if #threads == 0 then
    if t.plan_result then
      return notify('the feedback is on its way to the agent already')
    end
    input.ask({ title = 'Plan feedback', prompt = 'What should change? ' }, function(text)
      text = vim.trim(text or '')
      if text == '' then
        return notify('no feedback sent')
      end
      if not find_by_id(t.plan_id) then
        return notify('the plan is gone', vim.log.levels.WARN)
      end
      queue(t, table.concat({
        'Walkthrough: feedback from the user on your plan.',
        '',
        'User: ' .. (text:gsub('\n', '\n      ')),
        '',
        'Revise the plan for this feedback before presenting it again.',
      }, '\n'), {})
      notify('feedback sent; waiting for the revised plan')
    end)
    return
  end
  local marks = {}
  for _, th in ipairs(threads) do
    table.insert(marks, { id = th.id, count = #th.messages })
  end
  queue(t, M.build_message(t, threads), marks)
  notify(('feedback sent (%d comment%s); waiting for the revised plan'):format(#threads, #threads == 1 and '' or 's'))
end

-- User: approve -------------------------------------------------------------------------

--- Let the plan through: the hook gets `approve`, the plan and its file are
--- deleted, and the window shows again what it showed before (a window made
--- for the plan is closed). Comments still open are dropped, and the
--- notification says how many. `id` as in `feedback`.
function M.approve(id)
  local t = target(id)
  local dropped = open_threads(t)
  local buf = buffer_of(t)
  remember(t.plan_id, { state = 'approve' })
  tours.remove(t)
  local rest = tours.plans()

  for _, win in ipairs(buf and vim.fn.win_findbuf(buf) or {}) do
    if vim.api.nvim_win_is_valid(win) then
      if place and win == place.win then
        -- Another plan that waits takes the window; else it gets its place back.
        local ok = false
        if #rest > 0 then
          ok = pcall(function()
            put_buf(win, plan_buffer(rest[#rest]))
            set_winbar(rest[#rest])
          end)
        end
        if not ok then
          local given = pcall(give_back, win, place)
          if not given and vim.api.nvim_win_is_valid(win) and #vim.api.nvim_list_wins() > 1 then
            pcall(vim.api.nvim_win_close, win, true)
          end
        end
      else
        -- Another window of the plan: closed, a last one stays and shows an
        -- empty buffer.
        local tab = vim.api.nvim_win_get_tabpage(win)
        if #vim.api.nvim_list_tabpages() > 1 or #vim.api.nvim_tabpage_list_wins(tab) > 1 then
          pcall(vim.api.nvim_win_close, win, true)
        else
          pcall(vim.api.nvim_win_call, win, function()
            vim.cmd('enew')
          end)
        end
      end
    end
  end
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
  if #rest == 0 then
    local p = place
    place = nil
    if p then
      pcall(go_back, p)
    end
  end
  vim.fn.delete(t.steps[1].file)
  store.save(t.root)
  ui.update()
  notify('plan approved' .. (dropped > 0
    and ('; dropped %d comment%s that %s still open'):format(dropped, dropped == 1 and '' or 's', dropped == 1 and 'was' or 'were')
    or ''))
end

-- User: go to the plan ------------------------------------------------------------------

--- `:Walkthrough plan` without an argument: the plan that waits for a decision,
--- in the plan window (shown again when it was closed or left). With several,
--- the newest.
function M.show()
  restore()
  local all = tours.plans()
  if #all == 0 then
    return notify('no plan is waiting for review')
  end
  go_to(all[#all])
end

-- Status ---------------------------------------------------------------------------------

--- `{ id, state, threads }` of the plan under review (the one in the current
--- buffer, else the newest), `state` being "pending" or "feedback-sent"; nil
--- when there is none.
function M.status()
  local all = tours.plans()
  if #all == 0 then
    return nil
  end
  local pick = all[#all]
  local cur = vim.api.nvim_get_current_buf()
  for _, t in ipairs(all) do
    if buffer_of(t) == cur then
      pick = t
    end
  end
  return { id = pick.plan_id, state = pick.plan_state or 'pending', threads = #(pick.steps[1].threads or {}) }
end

return M
