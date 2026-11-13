-- The commit flow: step two of approval. Staging a commit's lines (stage.lua)
-- is step one; `commit` then
--   - runs the project's check on exactly the index, in the background
--     (skills/walkthrough/commit-check.sh),
--   - asks the agent for a commit message, and
--   - shows both in an editable float, laid out like git's own message file:
--     the message on top, then lines that start with `#` and are never part
--     of it (the group, the staged files, the state of the check, whether the
--     agent's proposal is awaited, warnings).
-- <CR> (or :w) makes the commit with `git commit -F -`, hooks enabled; q and
-- <Esc> cancel. After the commit the tour is gone with its threads and the
-- next tour of the repository is shown.
--
-- The agent's message comes back as a patch (init.lua, tour.lua):
-- { "commit_message": ..., "group": ... }. It is stored on the tour
-- (`commit_message`, saved with it) and shown in the dialog when one is open.
--
-- One dialog per repository, kept in the state table (`st.commit_dialogs`,
-- keyed by repository root).
local st = require('walkthrough.state')
local git = require('walkthrough.git')
local tour = require('walkthrough.tour')
local tours = require('walkthrough.tours')
local store = require('walkthrough.store')
local send = require('walkthrough.send')
local ui = require('walkthrough.ui')
local compact = require('walkthrough.compact')

local M = {}

--- The rules the agent is given for the message, word for word.
M.RULES = 'Conventional Commits. One line. Add further lines only when the change is really complex.'
  .. ' Never add a Co-authored-by line.'

-- Lines of the check's output that are kept.
local KEEP = 15

-- The script that runs the check, relative to the plugin's own files: this
-- file is <plugin>/lua/walkthrough/commit.lua.
local script = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h:h') .. '/skills/walkthrough/commit-check.sh'

local ns = vim.api.nvim_create_namespace('walkthrough_commit')
local hl_ns = vim.api.nvim_create_namespace('walkthrough_commit_lines')
-- The extmark that marks where the managed `#` lines start.
local MARK = 1

st.commit_dialogs = st.commit_dialogs or {}
local dialogs = st.commit_dialogs

local function notify(msg, level)
  vim.notify('walkthrough: ' .. msg, level or vim.log.levels.INFO)
end

local function valid_buf(buf)
  return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
end

local function valid_win(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

-- The tour of a change of repository `root` with this group (nil: the unnamed one).
local function find_tour(root, group)
  for _, t in ipairs(st.tours) do
    if t.root == root and not t.extra and not t.plan and t.group == group then
      return t
    end
  end
end

-- The check -------------------------------------------------------------------------

-- The last lines of the output, without the empty ones at the end.
local function tail(text)
  local lines = vim.split(text or '', '\n', { plain = true })
  while #lines > 0 and vim.trim(lines[#lines]) == '' do
    table.remove(lines)
  end
  return vim.list_slice(lines, math.max(1, #lines - KEEP + 1))
end

local render

local function finish_check(d, res)
  local check = d.check
  if d.closed or check.state ~= 'running' then
    return
  end
  local text = (res.stdout or '') .. (res.stderr or '')
  check.lines = tail(text)
  if res.code == 0 then
    check.state = text:find('no check defined', 1, true) and 'none' or 'passed'
  else
    check.state = 'failed'
  end
  render(d)
end

-- Run the script in the background. It gets a process group of its own, so
-- that stopping it takes the check it started along.
local function start_check(d)
  d.check = { state = 'none', lines = {} }
  if vim.fn.executable(script) ~= 1 then
    return
  end
  local ok, obj = pcall(vim.system, { script }, { cwd = d.root, text = true, detach = true }, function(res)
    vim.schedule(function()
      pcall(finish_check, d, res)
    end)
  end)
  if ok then
    d.check.state = 'running'
    d.check.obj = obj
  end
end

local function kill_check(d)
  local check = d.check
  if not (check and check.obj and check.state == 'running') then
    return
  end
  check.state = 'killed'
  -- The process group (the script is its leader), else the script alone.
  local ok, res = pcall(vim.uv.kill, -check.obj.pid, 'sigterm')
  if not (ok and res == 0) then
    pcall(check.obj.kill, check.obj, 'sigterm')
  end
end

-- The text of the dialog ------------------------------------------------------------

-- The message: the buffer without its `#` lines, trimmed.
local function message_text(d)
  local out = {}
  for _, line in ipairs(vim.api.nvim_buf_get_lines(d.buf, 0, -1, false)) do
    if line:sub(1, 1) ~= '#' then
      table.insert(out, line)
    end
  end
  return vim.trim(table.concat(out, '\n'))
end

-- The `#` lines, and what to color each with.
local function comment_lines(d)
  local lines, hls = {}, {}
  local function add(text, hl)
    table.insert(lines, text == '' and '#' or ('# ' .. text))
    hls[#lines] = hl or 'Comment'
  end
  add(d.group and ('Commit: ' .. d.group) or 'Commit: the staged changes')
  add('Staged:')
  for _, f in ipairs(d.files) do
    add(('  %s  %s'):format(f.status, f.path))
  end
  local check = d.check
  if check.state == 'running' then
    add('check: running…')
  elseif check.state == 'passed' then
    add('check: passed', 'DiagnosticOk')
  elseif check.state == 'failed' then
    add('check: FAILED', 'DiagnosticError')
    for _, l in ipairs(check.lines) do
      add('  ' .. l)
    end
  else
    add('check: none defined')
  end
  if d.proposal then
    add('agent: a proposal arrived; <C-r> in normal mode replaces the text with it', 'DiagnosticInfo')
  elseif d.send_error then
    add(('agent: not asked (%s); write the message yourself'):format(d.send_error), 'DiagnosticWarn')
  elseif d.awaiting then
    add('agent: waiting for a proposed message…')
  else
    add('agent: message received')
  end
  for _, f in ipairs(d.files) do
    if not d.listed[f.path] then
      add('staged but not part of this commit in the map: ' .. f.path, 'DiagnosticWarn')
    end
  end
  if d.committing then
    add('committing…', 'DiagnosticInfo')
  elseif d.error then
    add('commit FAILED: ' .. d.error, 'DiagnosticError')
  end
  add('')
  add('Lines that start with # are not part of the message. <CR> commits, q cancels.')
  return lines, hls
end

-- The row where the managed `#` lines start (0-based).
local function block_row(d)
  local m = vim.api.nvim_buf_get_extmark_by_id(d.buf, ns, MARK, {})
  return math.min(m and m[1] or math.huge, vim.api.nvim_buf_line_count(d.buf))
end

local function paint(d, row, hls)
  vim.api.nvim_buf_clear_namespace(d.buf, hl_ns, 0, -1)
  for i, hl in pairs(hls) do
    vim.api.nvim_buf_set_extmark(d.buf, hl_ns, row + i - 1, 0, { line_hl_group = hl })
  end
end

-- The window is as high as its text, within the screen.
local function resize(d)
  if not valid_win(d.win) then
    return
  end
  local room = math.max(vim.o.lines - vim.o.cmdheight - 6, 8)
  local height = math.max(10, math.min(vim.api.nvim_buf_line_count(d.buf) + 1, room))
  local width = vim.api.nvim_win_get_config(d.win).width
  vim.api.nvim_win_set_config(d.win, {
    relative = 'editor', width = width, height = height,
    row = math.max(0, math.floor((vim.o.lines - vim.o.cmdheight - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
  })
end

-- Write the whole buffer: `text` on top (the message), then the `#` lines.
local function fill(d, text)
  local body = text ~= '' and vim.split(text, '\n', { plain = true }) or { '' }
  if text ~= '' then
    table.insert(body, '')
  end
  local lines, hls = comment_lines(d)
  vim.api.nvim_buf_set_lines(d.buf, 0, -1, false, vim.list_extend(vim.list_slice(body), lines))
  vim.api.nvim_buf_set_extmark(d.buf, ns, #body, 0, { id = MARK, right_gravity = true })
  paint(d, #body, hls)
  d.inserted = text
  resize(d)
end

-- Write the `#` lines again, where they are: what the user typed in the message
-- area and the cursor stay.
render = function(d)
  if d.closed or not valid_buf(d.buf) then
    return
  end
  local row = block_row(d)
  local lines, hls = comment_lines(d)
  -- The managed block is the run of `#` lines from the mark on.
  local stop = row
  local rest = vim.api.nvim_buf_get_lines(d.buf, row, -1, false)
  for _, l in ipairs(rest) do
    if l:sub(1, 1) ~= '#' then
      break
    end
    stop = stop + 1
  end
  local cursor = valid_win(d.win) and vim.api.nvim_win_get_cursor(d.win) or nil
  vim.api.nvim_buf_set_lines(d.buf, row, stop, false, lines)
  vim.api.nvim_buf_set_extmark(d.buf, ns, row, 0, { id = MARK, right_gravity = true })
  paint(d, row, hls)
  if cursor then
    cursor[1] = math.min(cursor[1], vim.api.nvim_buf_line_count(d.buf))
    pcall(vim.api.nvim_win_set_cursor, d.win, cursor)
  end
  resize(d)
end

-- The agent's message ---------------------------------------------------------------

local function receive(d, text)
  d.awaiting = false
  -- Nothing typed in the message area yet: the proposal is the message.
  -- Otherwise it waits for <C-r>.
  if message_text(d) == vim.trim(d.inserted) then
    d.proposal = nil
    fill(d, text)
  else
    d.proposal = text
    render(d)
  end
end

--- The dialog of repository `root`, when one is open.
local function dialog_of(root)
  local d = dialogs[root]
  return d and not d.closed and valid_buf(d.buf) and d or nil
end

--- Tours that a list of commit messages from a patch (`{ i, group, text }`, see
--- tour.apply_patches) go to: the tour of `group`, else the active tour. Raises
--- (no tour is changed) when one has none, so a patch list stays transactional.
--- Returns the list of `{ t, text }`.
function M.resolve(commits)
  local out = {}
  for _, c in ipairs(commits) do
    local active = tours.active()
    local t
    if c.group == nil then
      t = active
      if not t or t.extra then
        error(('patch %d: no commit of the map is active; give "group"'):format(c.i), 0)
      end
    else
      -- Group names repeat across repositories: the active tour's repository wins.
      for _, x in ipairs(st.tours) do
        local better = not t or (active and x.root == active.root and t.root ~= x.root)
        if x.group == c.group and not x.extra and not x.plan and better then
          t = x
        end
      end
      if not t then
        error(('patch %d: no commit "%s" is loaded'):format(c.i, c.group), 0)
      end
    end
    table.insert(out, { t = t, text = c.text })
  end
  return out
end

--- Keep `text` as the commit message of tour `t` and show it in the dialog of
--- its repository when one is open. Never raises.
function M.receive(t, text)
  t.commit_message = text
  pcall(function()
    local d = dialog_of(t.root)
    if d and d.group == t.group then
      receive(d, text)
    end
  end)
end

--- The requests to the agent that wait for a message, for the repositories of
--- `roots` (a set): `{ { group, stat } }`. They are not marked as delivered:
--- the request stays until the message arrived or the dialog closed.
function M.pending(roots)
  local out = {}
  for root, d in pairs(dialogs) do
    if roots[root] and not d.closed and d.awaiting then
      table.insert(out, { group = d.group, stat = d.stat })
    end
  end
  table.sort(out, function(a, b)
    return (a.group or '') < (b.group or '')
  end)
  return out
end

-- Status ----------------------------------------------------------------------------

--- `{ group, check, message }` of the dialog of the active tour's repository,
--- else of any open one; nil when none is open.
function M.status()
  local active = tours.active()
  local d = active and dialog_of(active.root)
  if not d then
    for root in pairs(dialogs) do
      d = d or dialog_of(root)
    end
  end
  if not d then
    return nil
  end
  return { group = d.group, check = d.check.state, message = message_text(d) ~= '' }
end

-- Closing ---------------------------------------------------------------------------

local function close(d)
  if d.closed then
    return
  end
  d.closed = true
  kill_check(d)
  if dialogs[d.root] == d then
    dialogs[d.root] = nil
  end
  if valid_win(d.win) then
    pcall(vim.api.nvim_win_close, d.win, true)
  end
  if valid_buf(d.buf) then
    pcall(vim.api.nvim_buf_delete, d.buf, { force = true })
  end
  if valid_win(d.prev) then
    pcall(vim.api.nvim_set_current_win, d.prev)
  end
end

--- Close every dialog (the session ends), stopping their checks.
function M.close_all()
  for _, d in pairs(vim.list_slice(vim.tbl_values(dialogs))) do
    close(d)
  end
end

vim.api.nvim_create_autocmd('VimLeavePre', {
  group = vim.api.nvim_create_augroup('walkthrough_commit', { clear = true }),
  callback = function()
    for _, d in pairs(dialogs) do
      kill_check(d)
    end
  end,
})

-- After the commit -------------------------------------------------------------------

-- The tour is committed: it goes, with its threads, and the next tour of the
-- repository is shown in its view. With none left the panel closes and the
-- code window stays on the file it shows (`Other files` stays loaded).
local function advance(root, group)
  local t = find_tour(root, group)
  if not t then
    return
  end
  local was_active = tours.active() == t
  local siblings = {}
  for _, x in ipairs(tours.in_root(root)) do
    if not x.extra then
      table.insert(siblings, x)
    end
  end
  local idx = 1
  for i, x in ipairs(siblings) do
    if x == t then
      idx = i
    end
  end
  local nxt = siblings[idx + 1] or siblings[idx - 1]
  if was_active and not nxt then
    -- The compact view of this tour is a buffer that goes with it.
    pcall(compact.leave)
  end
  tours.remove(t)
  pcall(compact.sweep)
  store.save(root)
  if was_active then
    local shown = false
    if nxt then
      for i, x in ipairs(st.tours) do
        if x == nxt then
          st.active = i
        end
      end
      shown = pcall(ui.render, nxt.steps[nxt.pos], nxt.pos)
      if not shown then
        notify('the next commit could not be shown', vim.log.levels.WARN)
        st.active = 0
      end
    end
    if not shown then
      ui.clear()
      if valid_win(st.panel_win) then
        pcall(vim.api.nvim_win_close, st.panel_win, true)
      end
      st.panel_win, st.progress, st.map_rows = nil, nil, {}
    end
  end
  ui.update_map()
  ui.refresh_progress()
  ui.refresh_float()
  ui.redraw_threads()
end

-- Committing ------------------------------------------------------------------------

-- The message without its `Co-authored-by` lines, and how many there were.
local function strip_coauthors(text)
  local out, removed = {}, 0
  for _, line in ipairs(vim.split(text, '\n', { plain = true })) do
    if line:lower():match('^co%-authored%-by:') then
      removed = removed + 1
    else
      table.insert(out, line)
    end
  end
  return vim.trim(table.concat(out, '\n')), removed
end

local function committed(d, message)
  local head = git.run(d.root, { 'rev-parse', '--short', 'HEAD' })
  local hash = head.code == 0 and vim.trim(head.stdout) or '?'
  local subject = vim.split(message, '\n', { plain = true })[1]
  close(d)
  notify(('committed %s %s'):format(hash, subject))
  advance(d.root, d.group)
end

local function commit_now(d)
  if d.closed then
    return
  end
  if d.committing then
    return notify('a commit is being made already')
  end
  local message, removed = strip_coauthors(message_text(d))
  if message == '' then
    return notify('the commit message is empty: write one, or wait for the agent\'s', vim.log.levels.WARN)
  end
  if removed > 0 then
    notify(('removed %d Co-authored-by line%s from the message'):format(removed, removed == 1 and '' or 's'))
  end
  local state = d.check.state
  if state == 'failed' or state == 'running' then
    local what = state == 'failed' and 'The check failed.' or 'The check has not finished.'
    if vim.fn.confirm(what .. ' Commit anyway?', '&Yes\n&No', 2) ~= 1 then
      return notify('not committed')
    end
  end
  d.committing, d.error = true, nil
  render(d)
  local ok, err = pcall(git.commit_async, d.root, message .. '\n', function(res)
    local done, e = pcall(function()
      if res.code == 0 then
        return committed(d, message)
      end
      -- git's own first line; a hook may write to either stream.
      local why = git.first_line(res.stderr)
      if why == '' then
        why = git.first_line(res.stdout)
      end
      why = why ~= '' and why or ('git commit exited with ' .. res.code)
      d.committing, d.error = false, why
      render(d)
      -- The window was closed meanwhile: nothing is left to keep open.
      if not valid_buf(d.buf) then
        close(d)
      end
      notify('commit failed: ' .. why, vim.log.levels.ERROR)
    end)
    if not done then
      notify('after the commit: ' .. tour.clean_error(e), vim.log.levels.WARN)
    end
  end)
  if not ok then
    d.committing = false
    d.error = tour.clean_error(err)
    render(d)
    notify('commit failed: ' .. d.error, vim.log.levels.ERROR)
  end
end

-- The dialog -------------------------------------------------------------------------

local function cancel(d)
  if d.committing then
    return notify('a commit is being made; it cannot be cancelled now')
  end
  close(d)
end

local function open_window(d)
  local buf = vim.api.nvim_create_buf(false, true)
  d.buf = buf
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'walkthrough-commit'
  pcall(vim.api.nvim_buf_set_name, buf, 'walkthrough-commit://' .. d.root)
  fill(d, d.inserted)
  vim.bo[buf].modified = false

  local width = math.min(math.max(60, math.floor(vim.o.columns * 0.6)), vim.o.columns - 4)
  d.prev = vim.api.nvim_get_current_win()
  d.win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor', width = math.max(width, 20), height = 10, row = 0, col = 0,
    style = 'minimal', border = 'rounded',
    title = ' Commit: <CR> commit · :w commit · q cancel ', title_pos = 'center',
  })
  vim.wo[d.win].wrap = true
  vim.wo[d.win].linebreak = true
  resize(d)
  vim.api.nvim_win_set_cursor(d.win, { 1, 0 })

  local function map(lhs, fn, desc)
    vim.keymap.set('n', lhs, ui.safe(fn), { buffer = buf, nowait = true, desc = 'Walkthrough: ' .. desc })
  end
  map('<CR>', function() commit_now(d) end, 'commit')
  map('q', function() cancel(d) end, 'cancel the commit')
  map('<Esc>', function() cancel(d) end, 'cancel the commit')
  -- <C-r> takes a proposal that arrived while the user was typing; otherwise it stays redo.
  map('<C-r>', function()
    if d.proposal then
      local text = d.proposal
      d.proposal = nil
      fill(d, text)
      vim.api.nvim_win_set_cursor(d.win, { 1, 0 })
    else
      vim.cmd(('normal! %d\18'):format(vim.v.count1))
    end
  end, 'take the proposed message')

  local group = vim.api.nvim_create_augroup('walkthrough_commit_' .. buf, { clear = true })
  vim.api.nvim_create_autocmd('BufWriteCmd', {
    group = group, buffer = buf,
    callback = function()
      vim.bo[buf].modified = false
      ui.safe(commit_now)(d)
    end,
  })
  -- The dialog is not a file: `:q` after typing closes it (cancels) instead
  -- of complaining about unsaved changes.
  vim.api.nvim_create_autocmd('QuitPre', {
    group = group,
    callback = function()
      if not valid_buf(buf) then
        return true
      end
      if vim.api.nvim_get_current_buf() == buf then
        vim.bo[buf].modified = false
      end
    end,
  })
  -- However it goes away (`:q`, `:close`, a wipe), the check stops with it.
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = group, buffer = buf,
    callback = function()
      vim.schedule(function()
        if not d.committing then
          close(d)
        end
      end)
    end,
  })
end

-- Message of the request to the agent.
local function request(d)
  local patch = d.group
    and ('{ "commit_message": "<message>", "group": %s }'):format(vim.json.encode(d.group))
    or '{ "commit_message": "<message>" }'
  return table.concat({
    ('Walkthrough: write the commit message for %s.'):format(d.group and ('commit "' .. d.group .. '"') or 'the staged changes'),
    'The user staged these files and is about to commit them (git diff --cached --stat):',
    '',
    d.stat,
    '',
    'Rules: ' .. M.RULES,
    '',
    'Reply with a patch (a message of several lines is a list of strings); do not stage or commit anything yourself:',
    '  ' .. patch,
  }, '\n')
end

--- Commit what is staged for the active tour: the check starts in the
--- background, the agent is asked for a message, and a dialog shows both
--- (see the top of this file). Says why and changes nothing when there is no
--- tour of a change, nothing staged, or a dialog open already.
function M.commit()
  local t = tours.active()
  if not t or t.extra then
    return notify('commit needs a review: start one first (:Walkthrough review)'
      .. (t and ' (only threads on other files are loaded)' or ''), vim.log.levels.WARN)
  end
  local root = t.root
  if not root then
    return notify('this review has no repository', vim.log.levels.WARN)
  end
  if not git.has_staged(root) then
    return notify('nothing is staged: stage the commit first (stage, stage all)', vim.log.levels.WARN)
  end
  if dialog_of(root) then
    return notify('a commit dialog is open for this repository already', vim.log.levels.INFO)
  end
  -- What is left of a dialog whose window went away while it committed.
  if dialogs[root] then
    close(dialogs[root])
  end

  local files = git.staged_files(root)
  local stat = git.run(root, { 'diff', '--cached', '--stat' })
  -- What the map lists for this tour, as the real paths the staged files have.
  local function real(path)
    return vim.uv.fs_realpath(path) or path
  end
  local top = real(root)
  local mine = {}
  for _, step in ipairs(t.steps) do
    mine[real(vim.fn.fnamemodify(step.file, ':p'))] = true
  end
  local listed = {}
  for _, f in ipairs(files) do
    listed[f.path] = mine[top .. '/' .. f.path] or mine[root .. '/' .. f.path] or false
  end

  local d = {
    root = root, group = t.group, files = files, listed = listed, stat = vim.trim(stat.stdout or ''),
    awaiting = true, inserted = t.commit_message or '',
  }
  dialogs[root] = d
  start_check(d)
  open_window(d)

  local ok, err = pcall(send.send, { text = request(d), refs = {} })
  if not ok then
    d.send_error = tour.clean_error(err)
    render(d)
  end
end

return M
