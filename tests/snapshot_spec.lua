-- P-11: snapshots of the working tree and tours of "what changed since";
-- P-12: the `moved` verdict.
local H = require('helpers')
local check, send, w = H.check, H.send, H.w
local log, find = H.capture_notify()

local function lines(n, prefix)
  local out = {}
  for i = 1, n do
    out[i] = (prefix or 'l') .. i
  end
  return out
end

-- Everything a snapshot must leave alone, as one string.
local function observe(dir)
  return table.concat({
    H.git_in(dir, 'status', '--porcelain'),
    H.git_in(dir, 'diff'),
    H.git_in(dir, 'diff', '--cached'),
    H.git_in(dir, 'rev-parse', 'HEAD'),
    H.git_in(dir, 'branch', '--list'),
  }, '\n--\n')
end

-- A repository with a tracked file, a staged one, an untracked one and an ignored one.
local dir = H.repo({ ['a.txt'] = lines(6), ['.gitignore'] = { 'ignored.txt' } },
  { ['a.txt'] = { 'l1', 'changed2', 'l3', 'l4', 'l5', 'l6' }, ['u.txt'] = lines(4, 'u'), ['ignored.txt'] = { 'x' },
    ['s.txt'] = { 's' } })
H.git_in(dir, 'add', 's.txt')
vim.cmd('cd ' .. vim.fn.fnameescape(dir))

-- Creating a snapshot ---------------------------------------------------------------
local before = observe(dir)
local id = w.snapshot()
check('snapshot: returns a commit id', id:match('^%x+$') ~= nil and #id >= 40, id)
check('snapshot: refs/walkthrough/reviewed exists', H.git_in(dir, 'rev-parse', 'refs/walkthrough/reviewed') == id)
check('snapshot: status, diffs, HEAD and branches are unchanged', observe(dir) == before)
check('snapshot: its parent is HEAD', H.git_in(dir, 'rev-parse', id .. '^') == H.git_in(dir, 'rev-parse', 'HEAD'))
local tree = H.git_in(dir, 'ls-tree', '-r', '--name-only', id)
local files = vim.split(tree, '\n', { plain = true })
check('snapshot: tracked, staged and untracked files are in the tree',
  vim.tbl_contains(files, 'a.txt') and vim.tbl_contains(files, 's.txt') and vim.tbl_contains(files, 'u.txt'), tree)
check('snapshot: an ignored file is not', not vim.tbl_contains(files, 'ignored.txt'))
check('snapshot: the tree holds the working tree version', H.git_in(dir, 'show', id .. ':a.txt'):match('changed2') ~= nil)
check('snapshot: no temporary index is left in the repository', vim.fn.glob(dir .. '/.git/*.lock') == '')

check('snapshot: a name', w.snapshot('second'):match('^%x+$') ~= nil and H.git_in(dir, 'rev-parse', '--verify', 'refs/walkthrough/second') ~= '')
check('snapshot: the same name moves the ref', (function()
  vim.fn.writefile({ 'more' }, dir .. '/u.txt')
  local again = w.snapshot('second')
  return again ~= id and H.git_in(dir, 'rev-parse', 'refs/walkthrough/second') == again
end)())
for _, bad in ipairs({ '../x', 'a b', '-x', '.x', 'a..b', 'x.lock', 'x.', 'a/b', "a'b" }) do
  local res = w.snapshot(bad)
  check('snapshot: bad name ' .. vim.inspect(bad) .. ' is rejected', res:match('^error: snapshot name') ~= nil and not res:match('\n'), res)
end
check('snapshot: a rejected name creates no ref',
  #vim.split(H.git_in(dir, 'for-each-ref', '--format=%(refname)', 'refs/walkthrough/'), '\n', { plain = true }) == 2)

-- A repository without commits -------------------------------------------------------------
local fresh = H.repo(nil, { ['n.txt'] = { 'a', 'b' }, ['m.txt'] = { 'c' } })
vim.cmd('cd ' .. vim.fn.fnameescape(fresh))
local fresh_before = H.git_in(fresh, 'status', '--porcelain')
local fid = w.snapshot()
check('snapshot: works before the first commit', fid:match('^%x+$') ~= nil, fid)
check('snapshot: such a commit has no parent', H.git_in(fresh, 'rev-parse', '--verify', '--quiet', fid .. '^') == '')
check('snapshot: its files are there', H.git_in(fresh, 'ls-tree', '-r', '--name-only', fid) == 'm.txt\nn.txt')
check('snapshot: still no HEAD, nothing staged', H.git_in(fresh, 'status', '--porcelain') == fresh_before)

-- Outside a repository --------------------------------------------------------------------
local plain = vim.fn.tempname()
vim.fn.mkdir(plain, 'p')
vim.cmd('cd ' .. vim.fn.fnameescape(plain))
local res = w.snapshot()
check('snapshot: outside a repository is an error line', res:match('^error: ') ~= nil and not res:match('\n'), res)

-- The repository of the active tour wins over the working directory ----------------------------
vim.cmd('cd ' .. vim.fn.fnameescape(plain))
send('load', { file = dir .. '/a.txt' })
check('snapshot: uses the repository of the active tour', w.snapshot('from-tour'):match('^%x+$') ~= nil
  and H.git_in(dir, 'rev-parse', '--verify', 'refs/walkthrough/from-tour') ~= '')
w.discard()
w.close()

-- The command ----------------------------------------------------------------------------
vim.cmd('cd ' .. vim.fn.fnameescape(dir))
vim.cmd('Walkthrough reviewed cmd')
local note = find('recorded refs/walkthrough/cmd at %x%x%x%x%x%x%x$')
check(':Walkthrough reviewed [name] notifies with the short id', note ~= nil
  and note.msg:match('at (%x+)$') == H.git_in(dir, 'rev-parse', '--short=7', 'refs/walkthrough/cmd'), note and note.msg)
vim.cmd('Walkthrough reviewed bad..name')
check(':Walkthrough reviewed reports an error', find('snapshot name') ~= nil)
check(':Walkthrough reviewed completes', vim.tbl_contains(vim.fn.getcompletion('Walkthrough rev', 'cmdline'), 'reviewed'))

-- A tour against the snapshot ----------------------------------------------------------------
-- a.txt is tracked and changed; u.txt is untracked and changed; both change again.
local base = H.repo({ ['a.txt'] = lines(8) },
  { ['a.txt'] = { 'l1', 'X2', 'l3', 'l4', 'l5', 'l6', 'l7', 'l8' }, ['u.txt'] = lines(6, 'u'), ['v.txt'] = { 'v1' } })
vim.cmd('cd ' .. vim.fn.fnameescape(base))
local sid = w.snapshot()
check('since: snapshot made', sid:match('^%x+$') ~= nil, sid)
vim.fn.writefile({ 'l1', 'X2', 'l3', 'l4', 'NEW5', 'l6', 'l7', 'l8' }, base .. '/a.txt')
local u = lines(6, 'u')
u[3] = 'U3'
table.insert(u, 'u7')
vim.fn.writefile(u, base .. '/u.txt')
vim.fn.writefile({ 'v1', 'v2' }, base .. '/v.txt')
vim.fn.writefile({ 'w1', 'w2', 'w3' }, base .. '/w.txt') -- created after the snapshot
local ref = 'refs/walkthrough/reviewed'

local git = require('walkthrough.git')
local function spans(hunks)
  local out = {}
  for _, h in ipairs(hunks) do
    table.insert(out, ('%d+%d-%d'):format(h.start, h.count, #h.removed))
  end
  return table.concat(out, ' ')
end
check('since: tracked file, only the later change', spans(git.hunks(base .. '/a.txt', ref)) == '5+1-1', spans(git.hunks(base .. '/a.txt', ref)))
check('since: untracked file that is in the snapshot, only the later changes',
  spans(git.hunks(base .. '/u.txt', ref)) == '3+1-1 7+1-0', spans(git.hunks(base .. '/u.txt', ref)))
check('since: untracked file, removed lines are the old ones', git.hunks(base .. '/u.txt', ref)[1].removed[1] == 'u3')
check('since: untracked file, one line appended', spans(git.hunks(base .. '/v.txt', ref)) == '2+1-0')
check('since: file created after the snapshot is all new', spans(git.hunks(base .. '/w.txt', ref)) == '1+3-0')
check('since: an unknown ref still fails for an untracked file', (function()
  local ok, err = pcall(git.hunks, base .. '/u.txt', 'refs/walkthrough/none')
  return not ok and err:match('^git diff failed: ') ~= nil
end)())
check('since: untracked file against the index is all new', spans(git.hunks(base .. '/u.txt', nil)) == '1+7-0')

local function overlay(file, from)
  w.discard()
  w.close()
  vim.cmd('silent! %bwipeout!')
  assert(send('load', { group = 'G', steps = { { file = file, diff = ref, from = from } } }) == 'ok')
  local changed = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, H.ns, 0, -1, { details = true })) do
    if m[4].line_hl_group == 'WalkthroughAdded' then
      table.insert(changed, m[2] + 1)
    end
  end
  table.sort(changed)
  return table.concat(changed, ',')
end
check('since: tracked file shows only the change made after the snapshot', overlay(base .. '/a.txt', 1) == '5')
check('since: untracked file shows only the changes made after the snapshot', overlay(base .. '/u.txt', 1) == '3,7',
  overlay(base .. '/u.txt', 1))
check('since: file created after the snapshot is all marked', overlay(base .. '/w.txt', 1) == '1,2,3')
check('since: the old line shows as removed in the untracked file', (function()
  overlay(base .. '/u.txt', 1)
  return H.marks(function(d)
    return d.virt_lines ~= nil and d.virt_lines[1][1][1]:match('%- u3') ~= nil
  end) == 1
end)())
check('since: base view opens the snapshot version', (function()
  w.base()
  local win = vim.api.nvim_get_current_win()
  local ok = vim.api.nvim_win_get_config(win).relative ~= ''
    and vim.api.nvim_buf_get_lines(0, 0, -1, false)[3] == 'u3'
  vim.cmd('close')
  return ok
end)())

-- moved (P-12) ------------------------------------------------------------------------------
w.discard()
w.close()
vim.cmd('silent! %bwipeout!')
check('moved: is accepted by the validator', send('load', { group = 'M', steps = { {
  file = base .. '/a.txt', title = 'moved',
  notes = { { line = 2, text = 'same code, new place', verdict = 'moved', evidence = 'ran', detail = 'Moved from b.lua.' } },
} } }) == 'ok')
check('moved: a MOVED badge is drawn', H.marks(function(d)
  return d.virt_text and vim.iter(d.virt_text):any(function(c)
    return c[1]:match('MOVED') ~= nil and c[2] == 'WalkthroughMoved'
  end)
end) == 1)
check('moved: the panel heading names the verdict', H.panel_text():match('### %[1%] line 2 · moved · ran') ~= nil, H.panel_text())
local hl = vim.api.nvim_get_hl(0, { name = 'WalkthroughMoved', link = false })
check('moved: the badge colour is derived from Comment', hl.bold == true and hl.bg == vim.api.nvim_get_hl(0, { name = 'Comment', link = false }).fg)
check('moved: a patch may set it', send('patch', { note = 1, verdict = 'keep' }) == 'ok' and send('patch', { note = 1, verdict = 'moved' }) == 'ok')
check('moved: the error for a wrong verdict lists it', send('patch', { note = 1, verdict = 'nope' }):match('moved') ~= nil)

w.discard()
w.close()
H.finish()
