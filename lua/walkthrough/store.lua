-- Review state on disk: one JSON file per repository, so the tours survive
-- a restart and `resume` can bring them back. Nothing here may fail the
-- operation that triggered it.
local st = require('walkthrough.state')
local git = require('walkthrough.git')
local tour = require('walkthrough.tour')
local tours = require('walkthrough.tours')

local M = {}

-- Format 2 has no `panel`, `check` and `total` on steps, and threads where
-- format 1 had comments. Format 1 files, and files of format 2 written while threads
-- were being built that still have `comments`, are read and converted (see
-- `migrate`); the next save writes format 2.
local FORMAT = 2

--- The repository a file belongs to: its git top-level directory, else the
--- directory it is in.
function M.root_of(file)
  local abs = vim.fn.fnamemodify(file, ':p')
  local dir = vim.fs.dirname(abs)
  local ok, res = pcall(git.run, dir, { 'rev-parse', '--show-toplevel' })
  local top = ok and res.code == 0 and vim.trim(res.stdout) or ''
  return top ~= '' and top or dir
end

function M.path(root)
  return st.config.state_dir .. '/' .. vim.fn.sha256(root) .. '.json'
end

-- Write beside the file and rename, so a crash never leaves half of it.
local function write_atomic(path, json)
  vim.fn.mkdir(st.config.state_dir, 'p')
  local tmp = path .. '.tmp'
  if vim.fn.writefile({ json }, tmp) ~= 0 then
    error('cannot write ' .. tmp, 0)
  end
  local renamed, rename_err = vim.uv.fs_rename(tmp, path)
  if not renamed then
    error(rename_err, 0)
  end
end

--- Write all loaded tours of a repository: that of `root`, else that of the
--- active tour. With no tour left for the root the file is deleted. A failure
--- is reported once per session and otherwise ignored.
function M.save(root)
  local ok, err = pcall(function()
    local active = tours.active()
    if root == nil and active then
      active.root = active.root or M.root_of(active.steps[1].file)
      root = active.root
    end
    if not root then
      return
    end
    local list = {}
    for _, t in ipairs(tours.in_root(root, true)) do
      if #t.steps > 0 then
        table.insert(list, {
          group = t.group, pos = t.pos, steps = t.steps, depth = t.depth, next_thread = t.next_thread,
          auto = t.auto, extra = t.extra, commit_message = t.commit_message,
          plan = t.plan, plan_id = t.plan_id, plan_session = t.plan_session, plan_state = t.plan_state,
        })
      end
    end
    local path = M.path(root)
    if #list == 0 then
      vim.fn.delete(path)
      return
    end
    local shown = active and active.root == root and not active.extra and active.group or nil
    write_atomic(path, vim.json.encode({
      version = FORMAT, root = root, active = shown, next_thread = tours.counter(root), tours = list,
    }))
  end)
  if not ok and not st.save_warned then
    st.save_warned = true
    vim.notify('walkthrough: cannot save the review state (' .. tour.clean_error(err) .. '); continuing without',
      vim.log.levels.WARN)
  end
end

-- Directories that may be the repository the user means, best first.
local function candidates()
  local dirs = { vim.fn.getcwd() }
  local name = vim.api.nvim_buf_get_name(0)
  if name ~= '' and vim.bo.buftype == '' then
    table.insert(dirs, vim.fs.dirname(name))
  end
  local roots = {}
  for _, dir in ipairs(dirs) do
    local res = git.run(dir, { 'rev-parse', '--show-toplevel' })
    local top = res.code == 0 and vim.trim(res.stdout) or ''
    for _, r in ipairs({ top, vim.fn.fnamemodify(dir, ':p:h') }) do
      if r ~= '' and not vim.tbl_contains(roots, r) then
        table.insert(roots, r)
      end
    end
  end
  return roots
end

--- The first repository of the working directory or current file that has a
--- state file. Returns its root, or nil.
function M.find()
  for _, root in ipairs(candidates()) do
    if vim.fn.filereadable(M.path(root)) == 1 then
      return root
    end
  end
end

--- Delete the state file of the current repository. Returns its root, or nil
--- when there was none.
function M.remove()
  local root = M.find()
  if root then
    vim.fn.delete(M.path(root))
  end
  return root
end

-- Whether none of the files has an uncommitted change (untracked files count
-- as changes). Unknown counts as "still changed".
local function committed(root, files)
  local args = { 'status', '--porcelain', '--untracked-files=all', '--' }
  vim.list_extend(args, files)
  local ok, res = pcall(git.run, root, args)
  return ok and res.code == 0 and vim.trim(res.stdout) == ''
end

-- A stored tour as it is today: steps whose file is gone or that no longer
-- validate are dropped, the others follow the edits made meanwhile. Returns
-- nil when no step is left or when the tour was committed.
local function revive(t, root)
  if type(t) ~= 'table' or type(t.steps) ~= 'table' or not vim.islist(t.steps)
    or (t.group ~= nil and type(t.group) ~= 'string') then
    return nil
  end
  local steps, pos = {}, nil
  for i, s in ipairs(t.steps) do
    local keep = type(s) == 'table' and type(s.file) == 'string' and vim.fn.filereadable(s.file) == 1
    -- A malformed step may fail anywhere in sync; it is dropped then.
    keep = keep and pcall(tour.sync, s) and tour.validate_step(s, { stored = true }) == true
    if keep then
      table.insert(steps, s)
    end
    if i == t.pos then
      -- Where the shown step went: itself, or else the step that took its place.
      pos = #steps + (keep and 0 or 1)
    end
  end
  if #steps == 0 then
    return nil
  end
  local extra = t.extra == true
  -- A plan review (plan.lua) is never "committed", and is no use without the
  -- id and the session its hook knows it by.
  local plan = t.plan == true
  if plan and (type(t.plan_id) ~= 'string' or type(t.plan_session) ~= 'string') then
    return nil
  end
  local files, all_diff = {}, true
  for _, s in ipairs(steps) do
    all_diff = all_diff and s.diff == true
    table.insert(files, vim.fn.fnamemodify(s.file, ':p'))
  end
  if not extra and not plan and all_diff and committed(root, files) then
    return nil
  end
  local depth = tour.depths[t.depth] and t.depth or nil
  local counter = type(t.next_thread) == 'number' and t.next_thread >= 1 and t.next_thread == math.floor(t.next_thread)
    and t.next_thread or nil
  return {
    group = (not extra and not plan) and t.group or nil, steps = steps,
    pos = math.max(1, math.min(pos or 1, #steps)), root = root,
    depth = depth, next_thread = counter, auto = (not plan and t.auto == true) or nil, extra = t.extra == true or nil,
    plan = plan or nil, plan_id = plan and t.plan_id or nil, plan_session = plan and t.plan_session or nil,
    plan_state = plan and (t.plan_state == 'feedback-sent' and 'feedback-sent' or 'pending') or nil,
    commit_message = (not extra) and type(t.commit_message) == 'string' and vim.trim(t.commit_message) ~= ''
      and t.commit_message or nil,
  }
end

-- Older files -> format 2: steps lose `total` (all versions), format 1 steps
-- also `panel` and `check`; comments
-- (formats 1 and 2) become threads and `next_comment` becomes `next_thread`.
-- Done on the decoded data, before the steps are validated, because the
-- validator knows none of these fields any more.
local function migrate(data)
  for _, t in ipairs(data.tours) do
    if type(t) == 'table' then
      if t.next_comment ~= nil then
        t.next_thread, t.next_comment = t.next_thread or t.next_comment, nil
      end
      for _, s in ipairs(type(t.steps) == 'table' and t.steps or {}) do
        if type(s) == 'table' then
          s.total = nil
          if data.version == 1 then
            s.panel, s.check = nil, nil
          end
          if type(s.comments) == 'table' then
            local threads = {}
            for _, c in ipairs(s.comments) do
              -- What is not a comment stays as it is, and fails validation.
              local ok = type(c) == 'table' and type(c.id) == 'string' and c.id:match('^c%d+$')
                and type(c.text) == 'string'
              table.insert(threads, ok and tour.thread_from_comment(c) or c)
            end
            s.threads, s.comments = s.threads or threads, nil
          end
        end
      end
    end
  end
end

--- Read the state file of `root` and bring it up to date. Returns
--- { tours, active } (`active` is the group to show) or nil and a message.
function M.read(root)
  local path = M.path(root)
  if vim.fn.filereadable(path) == 0 then
    return nil, 'nothing to resume for ' .. root
  end
  local ok, data = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(path), '\n'), { luanil = { object = true, array = true } })
  end)
  if not ok or type(data) ~= 'table' or type(data.tours) ~= 'table' then
    return nil, 'the saved state of ' .. root .. ' cannot be read'
  end
  if data.version ~= 1 and data.version ~= FORMAT then
    return nil, 'the saved state of ' .. root .. ' has an unknown format'
  end
  migrate(data)
  local list = {}
  for _, t in ipairs(data.tours) do
    local alive = revive(t, root)
    if alive then
      table.insert(list, alive)
    end
  end
  if #list == 0 then
    return nil, 'nothing to resume for ' .. root .. ' (the saved map was committed or lost its files)'
  end
  local counter = type(data.next_thread) == 'number' and data.next_thread >= 1 and data.next_thread == math.floor(data.next_thread)
    and data.next_thread or nil
  return { tours = list, active = data.active, next_thread = counter }
end

--- Take the tours read by `read` into memory (see tours.adopt) and the
--- thread counter of the root. `silent` leaves the tour on screen alone.
function M.adopt(root, saved, silent)
  tours.adopt(saved.tours, root, saved.active, silent)
  if saved.next_thread then
    st.counters[root] = math.max(st.counters[root] or 1, saved.next_thread)
  end
end

--- Nothing is loaded for the repository and it has saved tours: bring them
--- back first, so that the next group sent after a restart does not wipe
--- them. A state file that cannot be used is left for the next save to
--- replace. Starts a session, so the root can be restored by itself again
--- should it be emptied.
function M.merge_saved(root)
  st.restored[root] = nil
  if tours.has_root(root) then
    return
  end
  pcall(function()
    local saved = vim.fn.filereadable(M.path(root)) == 1 and M.read(root)
    if saved then
      M.adopt(root, saved, true)
    end
  end)
end

--- Called when a normal file is shown: the first time for a repository with
--- nothing loaded, bring back what it has saved, silently (no window, no
--- buffer, no map). Once per root; never raises and never notifies. The git
--- root of a directory is looked up once. Returns whether tours came back.
function M.restore_for(file)
  local ok, restored = pcall(function()
    -- Nothing was ever saved here: no reason to ask git about the directory.
    if not vim.uv.fs_stat(st.config.state_dir) then
      return false
    end
    local dir = vim.fs.dirname(file)
    local root = st.dir_roots[dir]
    if root == nil then
      root = git.toplevel(dir) or false
      st.dir_roots[dir] = root
    end
    if not root or st.restored[root] or tours.has_root(root) then
      return false
    end
    st.restored[root] = true
    if vim.fn.filereadable(M.path(root)) == 0 then
      return false
    end
    local saved = M.read(root)
    if not saved then
      return false
    end
    M.adopt(root, saved, true)
    return true
  end)
  return ok and restored or false
end

--- Delete the tour `Other files` from the state file of `root`: threads on
--- existing code do not outlive the session. The tours of a change stay;
--- a file left without tours is deleted. Works on the file as it is, so it
--- needs nothing loaded.
function M.drop_extra(root)
  local path = M.path(root)
  if vim.fn.filereadable(path) == 0 then
    return
  end
  local ok, data = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
  end)
  if not ok or type(data) ~= 'table' or type(data.tours) ~= 'table' then
    return
  end
  local kept, dropped = {}, false
  for _, t in ipairs(data.tours) do
    if type(t) == 'table' and t.extra == true then
      dropped = true
    else
      table.insert(kept, t)
    end
  end
  if not dropped then
    return
  end
  if #kept == 0 then
    vim.fn.delete(path)
    return
  end
  data.tours = kept
  write_atomic(path, vim.json.encode(data))
end

return M
