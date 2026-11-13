-- Review state on disk: one JSON file per repository, so the tours survive
-- a restart and `resume` can bring them back. Nothing here may fail the
-- operation that triggered it.
local st = require('walkthrough.state')
local git = require('walkthrough.git')
local tour = require('walkthrough.tour')
local tours = require('walkthrough.tours')

local M = {}

local FORMAT = 1

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

--- Write all loaded tours of the active tour's repository. A failure is
--- reported once per session and otherwise ignored.
function M.save()
  local ok, err = pcall(function()
    local active = tours.active()
    if not active then
      return
    end
    local function root(t)
      t.root = t.root or M.root_of(t.steps[1].file)
      return t.root
    end
    local list = {}
    for _, t in ipairs(st.tours) do
      if root(t) == root(active) then
        table.insert(list, {
          group = t.group, pos = t.pos, steps = t.steps, depth = t.depth, next_comment = t.next_comment,
        })
      end
    end
    local json = vim.json.encode({ version = FORMAT, root = active.root, active = active.group, tours = list })
    vim.fn.mkdir(st.config.state_dir, 'p')
    local path = M.path(active.root)
    -- Write beside the file and rename, so a crash never leaves half of it.
    local tmp = path .. '.tmp'
    if vim.fn.writefile({ json }, tmp) ~= 0 then
      error('cannot write ' .. tmp, 0)
    end
    local renamed, rename_err = vim.uv.fs_rename(tmp, path)
    if not renamed then
      error(rename_err, 0)
    end
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

--- Delete the state file of the current repository. Returns whether there was one.
function M.remove()
  local root = M.find()
  if root then
    vim.fn.delete(M.path(root))
  end
  return root ~= nil
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
  local files, all_diff = {}, true
  for _, s in ipairs(steps) do
    all_diff = all_diff and s.diff == true
    table.insert(files, vim.fn.fnamemodify(s.file, ':p'))
  end
  if all_diff and committed(root, files) then
    return nil
  end
  local depth = tour.depths[t.depth] and t.depth or nil
  local counter = type(t.next_comment) == 'number' and t.next_comment >= 1 and t.next_comment == math.floor(t.next_comment)
    and t.next_comment or nil
  return {
    group = t.group, steps = steps, pos = math.max(1, math.min(pos or 1, #steps)), root = root,
    depth = depth, next_comment = counter,
  }
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
  if data.version ~= FORMAT then
    return nil, 'the saved state of ' .. root .. ' has an unknown format'
  end
  local list = {}
  for _, t in ipairs(data.tours) do
    local alive = revive(t, root)
    if alive then
      table.insert(list, alive)
    end
  end
  if #list == 0 then
    return nil, 'nothing to resume for ' .. root .. ' (every saved tour was committed or lost its files)'
  end
  return { tours = list, active = data.active }
end

return M
