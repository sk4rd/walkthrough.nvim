-- Staging (T-5): a deletion above line 1, and a message that reports what
-- git really has afterwards. Needs gitsigns.nvim.
local H = require('helpers')
local check, send, w = H.check, H.send, H.w

local gs = H.gitsigns()
if not gs then
  H.skip('staging tests (gitsigns.nvim not on the packpath; set WALKTHROUGH_GITSIGNS)')
  H.finish()
  return
end
local log, find = H.capture_notify()

local base = { 'a1', 'a2', 'a3', 'a4', 'a5', 'a6', 'a7', 'a8', 'a9', 'a10' }
local function cached(dir, file)
  return H.git_in(dir, 'diff', '--cached', '--numstat', '--', file)
end
local function reset_notes()
  for i = #log, 1, -1 do
    log[i] = nil
  end
end
-- Load a one-step tour for group A over `file` and wait for gitsigns.
local function open(dir, file, hunks)
  w.close()
  vim.cmd('silent! %bwipeout!')
  assert(send('load', { group = 'A', steps = { { file = dir .. '/' .. file, hunks = hunks } } }) == 'ok')
  H.attach()
  reset_notes()
end

-- The fixture of tests/run.sh: A2 A3 are group A, B4 group B (same git hunk),
-- X8 in no group, and a10 deleted under line 9 (group A).
local f = H.work .. '/f.txt'
open(H.work, 'f.txt', { { from = 2, to = 3, group = 'A' }, { from = 4, to = 4, group = 'B' }, { from = 9, to = 9, group = 'A' } })
vim.api.nvim_win_set_cursor(0, { 5, 0 })
w.stage_group()
local n = H.wait_notify(find, 'staged commit')
check('message: reports the lines staged', n ~= nil and n.msg == 'walkthrough: staged commit "A": 3 lines', vim.inspect(log))
check('staged: only group A (A2, A3 and the deletion of a10)', (function()
  H.wait(function() return cached(H.work, 'f.txt') ~= '' end)
  local diff = H.git_in(H.work, 'diff', '--cached', '-U0', '--', 'f.txt')
  return diff:match('%-a2\n%-a3\n%+A2\n%+A3') ~= nil and diff:match('%-a10') ~= nil
    and not diff:match('B4') and not diff:match('X8')
end)())
check('staging leaves the cursor alone', vim.api.nvim_win_get_cursor(0)[1] == 5)
reset_notes()
w.stage_group()
n = H.wait_notify(find, 'nothing left')
check('second stage_group has nothing left and does not unstage', n ~= nil and cached(H.work, 'f.txt'):match('^2%s+3') ~= nil,
  cached(H.work, 'f.txt'))

-- T-5: deletion of the first line, claimed by a range containing line 1.
local repo = H.repo({ ['d.txt'] = base }, { ['d.txt'] = { unpack(base, 2) } })
open(repo, 'd.txt', { { from = 1, to = 1, group = 'A' } })
local before = H.git_in(repo, 'diff', '--cached', '--stat')
check('top deletion: nothing staged before', before == '', before)
w.stage_group()
n = H.wait_notify(find, 'staged commit') or find('could not')
check('top deletion: message says it was staged', n ~= nil and n.msg == 'walkthrough: staged commit "A": 1 line', vim.inspect(log))
check('top deletion: git has the deletion staged', (function()
  H.wait(function() return cached(repo, 'd.txt') ~= '' end)
  return cached(repo, 'd.txt'):match('^0%s+1%s') ~= nil
end)(), cached(repo, 'd.txt'))
check('top deletion: nothing left unstaged', H.git_in(repo, 'diff', '--stat') == '')

-- The same deletion plus a change in the same file, in two ranges.
repo = H.repo({ ['d.txt'] = base }, { ['d.txt'] = { 'a2', 'a3', 'A4', 'a5', 'a6', 'a7', 'a8', 'a9', 'a10' } })
open(repo, 'd.txt', { { from = 1, to = 1, group = 'A' }, { from = 3, to = 3, group = 'A' } })
w.stage_group()
n = H.wait_notify(find, 'staged commit') or find('could not')
check('top deletion and a change: both staged', n ~= nil and n.msg == 'walkthrough: staged commit "A": 2 lines'
  and H.git_in(repo, 'diff', '--stat') == '', vim.inspect(log) .. H.git_in(repo, 'diff', '--stat'))

-- A deletion between unchanged lines, claimed on the line it is shown under.
repo = H.repo({ ['d.txt'] = base }, { ['d.txt'] = { 'a1', 'a2', 'a3', 'a4', 'a6', 'a7', 'a8', 'a9', 'a10' } })
open(repo, 'd.txt', { { from = 4, to = 4, group = 'A' } })
w.stage_group()
n = H.wait_notify(find, 'staged commit') or find('could not')
check('inner deletion still stages', n ~= nil and n.msg == 'walkthrough: staged commit "A": 1 line'
  and H.git_in(repo, 'diff', '--stat') == '', vim.inspect(log))

-- T-5: the message follows git, not the number of calls. Stubbing
-- stage_hunk simulates a range that gitsigns cannot stage.
local real = gs.stage_hunk
repo = H.repo({ ['d.txt'] = base }, { ['d.txt'] = { 'a1', 'A2', 'a3', 'a4', 'a5', 'a6', 'a7', 'a8', 'A9', 'a10' } })
open(repo, 'd.txt', { { from = 2, to = 2, group = 'A' }, { from = 9, to = 9, group = 'A' } })
gs.stage_hunk = function(_, _, cb)
  cb() -- does nothing, as when no hunk matches
end
w.stage_group()
n = H.wait_notify(find, 'could not')
check('truthful: nothing staged is not reported as success', n ~= nil
  and n.msg == 'walkthrough: commit "A": 2 ranges could not be staged (lines 2, 9)' and n.level == vim.log.levels.WARN
  and not find('staged commit'), vim.inspect(log))
check('truthful: git indeed has nothing staged', H.git_in(repo, 'diff', '--cached', '--stat') == '')

reset_notes()
gs.stage_hunk = function(range, opts, cb)
  if range and range[1] == 9 then
    return cb()
  end
  return real(range, opts, cb)
end
w.stage_group()
n = H.wait_notify(find, 'could not')
check('truthful: partial success is reported as such', n ~= nil
  and n.msg == 'walkthrough: staged 1 line of commit "A"; 1 range could not be staged (line 9)', vim.inspect(log))
gs.stage_hunk = real

H.finish()
