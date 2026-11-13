-- U-5: staged/seen progress in the winbar, and group-wide staging over
-- several files (one of them untracked). Needs gitsigns.nvim.
local H = require('helpers')
local check, send, w = H.check, H.send, H.w
local st = _G.walkthrough_state

local gs = H.gitsigns()
if not gs then
  H.skip('progress tests (gitsigns.nvim not on the packpath; set WALKTHROUGH_GITSIGNS)')
  H.finish()
  return
end
local log, find = H.capture_notify()
local function reset_log()
  for i = #log, 1, -1 do
    log[i] = nil
  end
end
local function status()
  return vim.json.decode(w.status())
end
-- The winbar as it reads on screen, without highlight groups.
local function bar()
  return (H.panel_winbar():gsub('%%#[%w]*#', ''):gsub('%%%*', ''):gsub('%%%%', '%%'))
end
local function bar_has(pattern)
  return H.wait(function()
    return bar():match(pattern) ~= nil
  end)
end
local function lines(n, prefix)
  local out = {}
  for i = 1, n do
    out[i] = (prefix or 'l') .. i
  end
  return out
end
local function with(base, changes)
  local out = vim.list_slice(base)
  for i, v in pairs(changes) do
    out[i] = v
  end
  return out
end
local function cached(repo, file)
  return H.git_in(repo, 'diff', '--cached', '-U0', '--', file)
end
-- a.txt: lines 2-3 are group A, 5 is group B. b.txt: line 4 is A. c.txt is
-- untracked and all A. In group A that makes 2 + 1 + 3 = 6 lines.
local function fixture()
  local repo = H.repo({ ['a.txt'] = lines(10), ['b.txt'] = lines(10, 'b') }, {
    ['a.txt'] = with(lines(10), { [2] = 'A2', [3] = 'A3', [5] = 'B5' }),
    ['b.txt'] = with(lines(10, 'b'), { [4] = 'A4' }),
    ['c.txt'] = { 'c1', 'c2', 'c3' },
  })
  vim.cmd('cd ' .. vim.fn.fnameescape(repo))
  return repo
end
local function tour_for(repo, extra)
  return vim.tbl_extend('force', {
    group = 'A',
    steps = {
      { file = repo .. '/a.txt', title = 'a', hunks = { { from = 2, to = 3, group = 'A' }, { from = 5, group = 'B' } } },
      { file = repo .. '/b.txt', title = 'b', hunks = { { from = 4, group = 'A' } } },
      { file = repo .. '/c.txt', title = 'c', hunks = { { from = 1, to = 3, group = 'A' } } },
    },
  }, extra or {})
end
local function open(repo, extra)
  w.close()
  vim.cmd('silent! %bwipeout!')
  assert(send('load', tour_for(repo, extra)) == 'ok')
  H.attach()
  reset_log()
end

-- Progress numbers -----------------------------------------------------------------
local repo = fixture()
open(repo)
check('winbar: seen, staged and the rest in order', bar_has('Step 1/3  · A · seen 1/3 · staged 0/6 · a'), bar())
w.step(1)
check('winbar: seen follows the steps', bar_has('seen 2/3 · staged 0/6 · b'), bar())
w.step(-1)

-- Single-file staging changes the count.
vim.api.nvim_win_set_cursor(0, { 5, 0 })
H.attach()
w.stage_group()
H.wait_notify(find, 'staged group')
check('winbar: staged follows the first file', bar_has('staged 2/6'), bar())
check('staged is what git has', cached(repo, 'a.txt'):match('%+A2\n%+A3') ~= nil and not cached(repo, 'a.txt'):match('B5'))

-- No ranges, no number --------------------------------------------------------------------
check('no hunks: no staged part', (function()
  w.close()
  send('load', { group = 'N', steps = { { file = repo .. '/a.txt', title = 'plain' } } })
  vim.wait(300)
  return bar():match('seen 1/1') and not bar():match('staged')
end)(), bar())
check('diff off: no staged part', (function()
  send('load', { group = 'N', steps = { { file = repo .. '/a.txt', title = 'plain', diff = false, hunks = { { from = 2, group = 'N' } } } } })
  vim.wait(300)
  return not bar():match('staged')
end)(), bar())
local plain = vim.fn.tempname()
vim.fn.mkdir(plain)
vim.fn.writefile({ 'one', 'two' }, plain .. '/p.txt')
check('outside a repository: no staged part', (function()
  send('load', { group = 'P', steps = { { file = plain .. '/p.txt', hunks = { { from = 1, group = 'P' } } } } })
  vim.wait(300)
  return bar():match('seen 1/1') and not bar():match('staged')
end)(), bar())
vim.cmd('cd ' .. vim.fn.fnameescape(repo))

-- Group-wide staging: the confirm gate -------------------------------------------------------
repo = fixture()
open(repo)
local asked, answer = {}, 2
local real_confirm = vim.fn.confirm
vim.fn.confirm = function(msg, choices, default)
  table.insert(asked, { msg = msg, choices = choices, default = default })
  return answer
end
w.stage_group({ all = true })
check('gate: unseen steps ask once, default is cancel', #asked == 1 and asked[1].default == 2 and asked[1].msg:match('2 of 3 steps'), vim.inspect(asked))
check('gate: cancelling stages nothing', find('not staged') ~= nil and H.git_in(repo, 'diff', '--cached', '--stat') == '')

answer = 1
reset_log()
asked = {}
w.stage_group({ all = true })
local n = H.wait_notify(find, 'staged group') or H.wait_notify(find, 'skipped')
check('stage all: asks once', #asked == 1, vim.inspect(asked))
check('stage all: the message reports lines and files from git', n ~= nil and n.msg == 'walkthrough: staged group "A": 6 lines in 3 files'
  and n.level == vim.log.levels.INFO, vim.inspect(log))
check('stage all: a.txt, only group A', cached(repo, 'a.txt'):match('%+A2\n%+A3') ~= nil and not cached(repo, 'a.txt'):match('B5'))
check('stage all: b.txt', cached(repo, 'b.txt'):match('%+A4') ~= nil, cached(repo, 'b.txt'))
check('stage all: the untracked c.txt is tracked and staged', H.git_in(repo, 'ls-files', 'c.txt') == 'c.txt'
  and H.git_in(repo, 'diff', '--cached', '--numstat', '--', 'c.txt'):match('^3%s+0') ~= nil, H.git_in(repo, 'diff', '--cached', '--numstat'))
check('stage all: B5 stays unstaged', H.git_in(repo, 'diff', '-U0', '--', 'a.txt'):match('%+B5') ~= nil)
check('stage all: winbar shows the total', bar_has('staged 6/6'), bar())

-- Again: nothing left, and no second question.
reset_log()
asked = {}
w.stage_group({ all = true })
n = H.wait_notify(find, 'nothing left')
check('stage all again: nothing left, nothing unstaged by mistake', n ~= nil and cached(repo, 'b.txt'):match('%+A4') ~= nil, vim.inspect(log))

-- All steps seen: no question --------------------------------------------------------------------
repo = fixture()
open(repo)
w.step(1)
w.step(1)
asked = {}
w.stage_group({ all = true })
n = H.wait_notify(find, 'staged group')
check('seen everything: no question', #asked == 0 and n ~= nil and n.msg:match('6 lines in 3 files'), vim.inspect(log) .. vim.inspect(asked))

-- A stale range in one file is skipped and named ----------------------------------------------------
repo = fixture()
open(repo)
w.step(1)
w.step(1)
w.step(-2)
-- An edit that reaches over the edge of b.txt's range (line 4) makes it stale.
vim.fn.writefile(with(lines(10, 'b'), { [3] = 'Z3', [4] = 'Z4' }), repo .. '/b.txt')
asked = {}
reset_log()
w.stage_group({ all = true })
n = H.wait_notify(find, 'skipped')
check('stale: b.txt is skipped and named', n ~= nil and n.msg:match('skipped .*b%.txt %(lines %d+%-%d+ were edited') ~= nil
  and n.level == vim.log.levels.WARN, vim.inspect(log))
check('stale: the other files were staged', n ~= nil and n.msg:match('staged group "A": 5 lines in 2 files') ~= nil, vim.inspect(log))
check('stale: nothing of b.txt is staged', cached(repo, 'b.txt') == '')
check('stale: a.txt and c.txt are', cached(repo, 'a.txt'):match('%+A2') ~= nil and H.git_in(repo, 'diff', '--cached', '--numstat', '--', 'c.txt'):match('^3') ~= nil)
check('stale: single-file staging refuses it too', (function()
  w.step(1)
  H.attach()
  reset_log()
  w.stage_group()
  return find('were edited') ~= nil
end)())

-- What git still has is reported when gitsigns cannot stage a range ----------------------------------
repo = fixture()
open(repo)
w.step(1)
w.step(1)
local real = gs.stage_hunk
gs.stage_hunk = function(range, opts, cb)
  if range and range[1] == 4 then
    return cb() -- b.txt's range does nothing
  end
  return real(range, opts, cb)
end
reset_log()
w.stage_group({ all = true })
n = H.wait_notify(find, 'left unstaged')
gs.stage_hunk = real
check('partial: lines left are counted from git', n ~= nil and n.msg:match('staged group "A": 5 lines in 2 files; 1 line left unstaged %(.*b%.txt: 4%)') ~= nil
  and n.level == vim.log.levels.WARN, vim.inspect(log))
check('partial: git indeed has nothing of b.txt', cached(repo, 'b.txt') == '')

vim.fn.confirm = real_confirm
H.finish()
