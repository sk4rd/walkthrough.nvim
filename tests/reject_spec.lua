-- P-7: rejecting a group discards its unstaged changes in the current file
-- and nothing else. Needs gitsigns.nvim (it restores the lines).
local H = require('helpers')
local check, send, w = H.check, H.send, H.w
local st = _G.walkthrough_state

local gs = H.gitsigns()
if not gs then
  H.skip('reject tests (gitsigns.nvim not on the packpath; set WALKTHROUGH_GITSIGNS)')
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

-- vim.fn.confirm answers from `choice`; the question and default are kept.
local asked, choice = {}, 1
vim.fn.confirm = function(msg, choices, default)
  table.insert(asked, { msg = msg, choices = choices, default = default })
  return choice
end

local base = {}
for i = 1, 12 do
  base[i] = 'a' .. i
end
local function edited(changes)
  local out = vim.deepcopy(base)
  for line, text in pairs(changes) do
    out[line] = text
  end
  return out
end
local function open(dir, file, hunks, notes)
  w.discard()
  w.close()
  vim.cmd('silent! %bwipeout!')
  vim.cmd('cd ' .. vim.fn.fnameescape(dir))
  assert(send('load', { group = 'A', steps = { { file = dir .. '/' .. file, hunks = hunks, notes = notes } } }) == 'ok')
  H.attach()
  reset_log()
  asked, choice = {}, 1
end
local function disk(dir, file)
  return vim.fn.readfile(dir .. '/' .. file)
end

-- Staged part and unstaged part, next to another group ------------------------------------
-- Line 2 is staged (group A), lines 4 and 8 are unstaged (group A), line 5 is
-- group B and in the same git hunk as line 4.
local final = edited({ [2] = 'A2', [4] = 'A4', [5] = 'B5', [8] = 'A8' })
local repo = H.repo({ ['f.txt'] = base }, { ['f.txt'] = edited({ [2] = 'A2' }) })
H.git_in(repo, 'add', 'f.txt')
vim.fn.writefile(final, repo .. '/f.txt')
local hunks = { { from = 2, to = 2, group = 'A' }, { from = 4, to = 4, group = 'A' }, { from = 5, to = 5, group = 'B' },
  { from = 8, to = 8, group = 'A' } }
open(repo, 'f.txt', hunks, { { line = 11, text = 'below' }, { line = 4, text = 'on a rejected line' } })
local staged_before = H.git_in(repo, 'diff', '--cached', '-U0', '--', 'f.txt')

-- Refusals first: none of them may touch the file or ask.
local function refuses(name, pattern)
  local n = H.wait_notify(find, pattern)
  check('refused: ' .. name, n ~= nil and #asked == 0 and vim.deep_equal(disk(repo, 'f.txt'), final), vim.inspect(log))
  reset_log()
end
vim.api.nvim_buf_set_lines(0, 0, 1, false, { 'typed' })
w.reject_group()
refuses('unsaved changes', 'save the file first')
vim.cmd('edit!')
H.attach()
reset_log()
vim.cmd('edit ' .. vim.fn.fnameescape(repo .. '/f.txt'))
local other = H.repo({ ['o.txt'] = base }, {})
vim.cmd('edit ' .. vim.fn.fnameescape(other .. '/o.txt'))
w.reject_group()
refuses('the code window shows another file', 'shows another file')
vim.cmd('edit ' .. vim.fn.fnameescape(repo .. '/f.txt'))
H.attach()
-- A stale range: the user rewrote lines 4 and 5 outside, over the range's edge.
local rewritten = vim.deepcopy(final)
rewritten[4], rewritten[5] = 'rewritten', 'both'
vim.fn.writefile(rewritten, repo .. '/f.txt')
status()
w.reject_group()
local n = H.wait_notify(find, 'were edited')
check('refused: a stale range', n ~= nil and #asked == 0 and vim.deep_equal(disk(repo, 'f.txt'), rewritten), vim.inspect(log))
reset_log()
vim.fn.writefile(final, repo .. '/f.txt')
open(repo, 'f.txt', hunks, { { line = 11, text = 'below' }, { line = 4, text = 'on a rejected line' } })

-- Cancel is the default and changes nothing.
choice = 2
w.reject_group()
check('confirm: names the group and the number of unstaged lines, default is cancel', #asked == 1
  and asked[1].msg:match('Discard 2 unstaged lines of group "A" in f%.txt') and asked[1].default == 2
  and asked[1].choices == '&Discard\n&Cancel', vim.inspect(asked))
check('confirm: cancelling changes nothing', vim.deep_equal(disk(repo, 'f.txt'), final) and find('not rejected') ~= nil
  and not vim.bo.modified)

-- The real thing.
choice = 1
reset_log()
w.reject_group()
n = H.wait_notify(find, 'discarded')
check('reject: message says what was discarded', n ~= nil and n.msg == 'walkthrough: discarded 2 unstaged lines of group "A" in f.txt; staged changes were kept',
  vim.inspect(log))
local expected = edited({ [2] = 'A2', [5] = 'B5' })
check('reject: the unstaged lines of group A are gone, group B\'s line stays', vim.deep_equal(disk(repo, 'f.txt'), expected), vim.inspect(disk(repo, 'f.txt')))
check('reject: the buffer was written', not vim.bo.modified and vim.deep_equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), expected))
check('reject: the staged part is untouched', H.git_in(repo, 'diff', '--cached', '-U0', '--', 'f.txt') == staged_before)
local unstaged = H.git_in(repo, 'diff', '-U0', '--', 'f.txt')
check('reject: only group B is left unstaged', unstaged:match('%+B5') and not unstaged:match('A4') and not unstaged:match('A8'), unstaged)
local step = st.history[1]
local ranges = vim.tbl_map(function(h) return h.group .. h.from .. '-' .. (h.to or h.from) end, step.hunks)
check('reject: ranges that are no changes any more are dropped, the others stay', vim.deep_equal(ranges, { 'A2-2', 'B5-5' }), vim.inspect(ranges))
local s = status()
check('reject: nothing is stale because of the reject', s.stale == nil, vim.inspect(s.stale))
check('reject: a note on a rejected line is not stale and did not move', step.notes[2].line == 4 and not step.notes[2].stale
  and step.notes[1].line == 11, vim.inspect(step.notes))
check('reject: the overlay is consistent', H.marks(function(d) return d.line_hl_group == 'WalkthroughAdded' end) == 0
  and H.marks(function(d) return H.sign(d, '✓') end) == 1 and H.marks(function(d) return H.sign(d, '·') end) == 1
  and H.marks(function(d) return d.virt_text and d.virt_text[1][1]:match('stale') ~= nil end) == 0)
reset_log()
w.reject_group()
check('reject: again has nothing left', find('nothing to reject') ~= nil and #asked == 2)

-- A deleted line comes back, positions below it move down ---------------------------------------
local gone = vim.deepcopy(base)
table.remove(gone, 11) -- a11 deleted: shown under a10
repo = H.repo({ ['f.txt'] = base }, { ['f.txt'] = gone })
open(repo, 'f.txt', { { from = 10, to = 10, group = 'A' } }, { { line = 11, text = 'last but one' } })
w.reject_group()
n = H.wait_notify(find, 'discarded')
check('deletion: the line is restored', n ~= nil and vim.deep_equal(disk(repo, 'f.txt'), base) and H.git_in(repo, 'status', '--porcelain') == '',
  vim.inspect(log) .. vim.inspect(disk(repo, 'f.txt')))
check('deletion: the note below moved with the restored line, not stale', st.history[1].notes[1].line == 12 and not st.history[1].notes[1].stale
  and #st.history[1].hunks == 0, vim.inspect(st.history[1]))

-- Deletion at the top of the file, and a change below it ----------------------------------------------
local top = { unpack(base, 2) }
top[3] = 'A4'
repo = H.repo({ ['f.txt'] = base }, { ['f.txt'] = top })
open(repo, 'f.txt', { { from = 1, to = 1, group = 'A' }, { from = 3, to = 3, group = 'A' } })
w.reject_group()
n = H.wait_notify(find, 'discarded')
check('top deletion: restored together with the change below it', n ~= nil and vim.deep_equal(disk(repo, 'f.txt'), base)
  and H.git_in(repo, 'status', '--porcelain') == '', vim.inspect(log) .. vim.inspect(disk(repo, 'f.txt')))

-- Everything staged: nothing to discard ------------------------------------------------------------------
repo = H.repo({ ['f.txt'] = base }, { ['f.txt'] = edited({ [3] = 'A3' }) })
H.git_in(repo, 'add', 'f.txt')
open(repo, 'f.txt', { { from = 3, to = 3, group = 'A' } })
w.reject_group()
check('everything staged: nothing to reject, nothing asked', find('nothing to reject') ~= nil and #asked == 0
  and disk(repo, 'f.txt')[3] == 'A3')

-- A new file has nothing to go back to -----------------------------------------------------------------------
repo = H.repo({ ['f.txt'] = base }, { ['n.txt'] = { 'x', 'y' } })
open(repo, 'n.txt', { { from = 1, to = 2, group = 'A' } })
w.reject_group()
check('untracked file: refused', find('new to git') ~= nil and #asked == 0 and #disk(repo, 'n.txt') == 2, vim.inspect(log))

-- No tour, no ranges ----------------------------------------------------------------------------------------------
reset_log()
w.close()
w.reject_group()
check('no tour: says so', find('no tour open') ~= nil)
vim.cmd('Walkthrough reject')
check(':Walkthrough reject exists and does not raise', true)

w.close()
vim.cmd('silent! %bwipeout!')
H.finish()
