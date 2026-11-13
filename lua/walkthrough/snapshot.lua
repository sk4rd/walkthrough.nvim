-- Incremental review: record the working tree as a commit object under
-- refs/walkthrough/<name>, so that a later tour can show only what changed
-- since (`"diff": "refs/walkthrough/<name>"`). The index, the working tree,
-- HEAD and the branches are not touched.
local git = require('walkthrough.git')
local store = require('walkthrough.store')
local tours = require('walkthrough.tours')

local M = {}

M.default_name = 'reviewed'

--- Raises with a short message when `name` cannot be the last part of a ref
--- under refs/walkthrough/.
function M.check_name(name)
  if type(name) ~= 'string' or not name:match('^[%w][%w._-]*$') then
    error('snapshot name must start with a letter or digit and contain only letters, digits, ".", "_" and "-"', 0)
  end
  if name:find('..', 1, true) or name:match('%.$') or name:match('%.lock$') then
    error('snapshot name must not contain "..", end with "." or end with ".lock"', 0)
  end
end

-- The repository of the active tour, else the one of the working directory.
local function repo_root()
  local t = tours.active()
  if t and t.steps[1] then
    return t.root or store.root_of(t.steps[1].file)
  end
  local res = git.run(vim.fn.getcwd(), { 'rev-parse', '--show-toplevel' })
  local top = res.code == 0 and vim.trim(res.stdout) or ''
  if top == '' then
    error('not inside a git repository', 0)
  end
  return top
end

local function must(res, what)
  if res.code ~= 0 then
    error(('%s failed: %s'):format(what, git.first_line(res.stderr)), 0)
  end
  return vim.trim(res.stdout or '')
end

--- Record the working tree (tracked and untracked files, not ignored ones)
--- as a commit whose parent is HEAD, when there is one, and point
--- refs/walkthrough/<name> at it. Returns the commit id. Raises on failure.
function M.create(name)
  name = (name == nil or name == '') and M.default_name or name
  M.check_name(name)
  local root = repo_root()

  -- The tree is built in an index file of its own, seeded from HEAD so that
  -- git does not have to hash the unchanged files again.
  local index = vim.fn.tempname()
  local env = { GIT_INDEX_FILE = index }
  local ok, res = pcall(function()
    local head = git.has_head(root)
    if head then
      must(git.run(root, { 'read-tree', 'HEAD' }, env), 'git read-tree')
    end
    must(git.write(root, { 'add', '-A' }, env), 'git add')
    local tree = must(git.run(root, { 'write-tree' }, env), 'git write-tree')
    -- commit-tree needs an identity; a machine without one still gets a snapshot.
    local commit_env = {}
    if git.run(root, { 'var', 'GIT_AUTHOR_IDENT' }).code ~= 0
      or git.run(root, { 'var', 'GIT_COMMITTER_IDENT' }).code ~= 0 then
      commit_env = {
        GIT_AUTHOR_NAME = 'walkthrough', GIT_AUTHOR_EMAIL = 'walkthrough@localhost',
        GIT_COMMITTER_NAME = 'walkthrough', GIT_COMMITTER_EMAIL = 'walkthrough@localhost',
      }
    end
    local args = { 'commit-tree', tree, '-m', 'walkthrough snapshot ' .. name }
    if head then
      vim.list_extend(args, { '-p', 'HEAD' })
    end
    local id = must(git.write(root, args, commit_env), 'git commit-tree')
    must(git.write(root, { 'update-ref', 'refs/walkthrough/' .. name, id }), 'git update-ref')
    return id
  end)
  vim.fn.delete(index)
  vim.fn.delete(index .. '.lock')
  if not ok then
    error(res, 0)
  end
  return res
end

return M
