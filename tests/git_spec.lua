-- git.lua against real repositories: no optional locks (T-12), no HEAD and
-- no repository (T-10).
local H = require('helpers')
local check = H.check
local git = require('walkthrough.git')
local w = H.w

-- T-12: every read-only call passes --no-optional-locks ----------------------------
local repo = H.repo({ ['a.txt'] = { '1', '2', '3' } }, { ['a.txt'] = { '1', 'two', '3' }, ['u.txt'] = { 'u' } })
local trace = vim.fn.tempname()
vim.env.GIT_TRACE2_EVENT = trace
git.hunks(repo .. '/a.txt', nil)
git.hunks(repo .. '/a.txt', 'HEAD')
git.hunks(repo .. '/u.txt', nil)
H.send('load', { file = repo .. '/a.txt', diff = true, hunks = { { from = 2 } } })
vim.env.GIT_TRACE2_EVENT = nil
local seen, bare = 0, {}
for _, line in ipairs(vim.fn.readfile(trace)) do
  local ok, ev = pcall(vim.json.decode, line)
  if ok and ev.event == 'start' and ev.argv and ev.argv[2] ~= 'maintenance' and ev.argv[2] ~= '--version' then
    seen = seen + 1
    if not vim.tbl_contains(ev.argv, '--no-optional-locks') then
      table.insert(bare, table.concat(ev.argv, ' '))
    end
  end
end
check('T-12: git was traced', seen >= 5, seen)
check('T-12: all reads pass --no-optional-locks', #bare == 0, table.concat(bare, '; '))

-- hunks() ------------------------------------------------------------------------------
local hunks = git.hunks(repo .. '/a.txt', nil)
check('hunks: changed line', #hunks == 1 and hunks[1].start == 2 and hunks[1].count == 1 and hunks[1].removed[1] == '2')
hunks = git.hunks(repo .. '/u.txt', 'HEAD')
check('hunks: untracked file is all new', #hunks == 1 and hunks[1].start == 1 and hunks[1].count == 1)

-- T-10 -----------------------------------------------------------------------------------
local plain = vim.fn.tempname()
vim.fn.writefile({ 'x' }, plain)
check('hunks: nil outside a repository', git.hunks(plain, nil) == nil and git.hunks(plain, 'HEAD') == nil and git.hunks(plain, 'main') == nil)

local fresh = H.repo(nil, { ['n.txt'] = { 'a', 'b' } })
hunks = git.hunks(fresh .. '/n.txt', 'HEAD')
check('hunks: no commits means every line is new', #hunks == 1 and hunks[1].start == 1 and hunks[1].count == 2)
check('hunks: no commits, index diff of an untracked file', #git.hunks(fresh .. '/n.txt', nil) == 1)

local ok, err = pcall(git.hunks, repo .. '/a.txt', 'no-such-ref')
check('hunks: bad ref is one line without a path', not ok and not err:match('\n') and err:match('^git diff failed: ') ~= nil
  and not err:match('lua/walkthrough'), err)
check('first_line of git usage text', git.first_line('usage: git diff --no-index\n\n    --cached\n') == 'usage: git diff --no-index')

-- unstaged_set --------------------------------------------------------------------------
local lines, removed, top = git.unstaged_set({ { start = 0, count = 0, removed = { 'x' } }, { start = 5, count = 2, removed = {} } }, 10)
check('unstaged_set: lines, top deletion', lines[1] and lines[5] and lines[6] and top and removed['0a'], vim.inspect({ lines, removed, top }))
_, _, top = git.unstaged_set({ { start = 4, count = 0, removed = { 'x' } } }, 10)
check('unstaged_set: inner deletion is not a top deletion', not top)

w.close()
H.finish()
