-- `:Walkthrough review`: a local tour from git, without an agent; its
-- replacement by the agent's tour; staging of entries that list no ranges.
local H = require('helpers')
local check, send, w = H.check, H.send, H.w
local st = _G.walkthrough_state
local store = require('walkthrough.store')
local log, find = H.capture_notify()
-- Questions are sent at once: to nobody here.
st.config.sender = function() end
local function reset_log()
  for i = #log, 1, -1 do
    log[i] = nil
  end
end
local function status()
  return vim.json.decode(w.status())
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
local function cd(dir)
  vim.cmd('cd ' .. vim.fn.fnameescape(dir))
end
local function reset()
  w.discard()
  vim.cmd('silent! %bwipeout!')
  reset_log()
end
local function saved(root)
  local path = store.path(root)
  if vim.fn.filereadable(path) == 0 then
    return nil
  end
  return vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
end
-- File names of the steps of the tour, relative to the repository.
local function names(t, dir)
  return vim.tbl_map(function(s)
    return s.file:sub(#dir + 2)
  end, t.steps)
end
local function code_file()
  return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(st.code_win))
end

-- A repository with two commits and, in the working tree: a modified file
-- (a.txt), a modified and staged one (b.txt), a new staged file
-- (new_staged.txt), an untracked one (untracked.txt), a modified one in a
-- directory (sub/s.txt), a deleted one (d.txt) and an ignored one
-- (ignored.log). c.txt differs from HEAD~1 only.
local function fixture()
  local dir = H.repo({
    ['a.txt'] = lines(8), ['b.txt'] = lines(6, 'b'), ['c.txt'] = lines(4, 'c'), ['d.txt'] = lines(3, 'd'),
    ['sub/s.txt'] = lines(5, 's'), ['.gitignore'] = { '*.log' },
  }, {})
  vim.fn.writefile(with(lines(4, 'c'), { [2] = 'C2' }), dir .. '/c.txt')
  H.git_in(dir, 'commit', '-qam', 'second')
  vim.fn.writefile(with(lines(8), { [3] = 'A3' }), dir .. '/a.txt')
  vim.fn.writefile(with(lines(6, 'b'), { [2] = 'B2' }), dir .. '/b.txt')
  H.git_in(dir, 'add', 'b.txt')
  vim.fn.writefile({ 'n1', 'n2' }, dir .. '/new_staged.txt')
  H.git_in(dir, 'add', 'new_staged.txt')
  vim.fn.writefile({ 'u1', 'u2', 'u3' }, dir .. '/untracked.txt')
  vim.fn.writefile(with(lines(5, 's'), { [4] = 'S4' }), dir .. '/sub/s.txt')
  vim.fn.delete(dir .. '/d.txt')
  vim.fn.writefile({ 'log' }, dir .. '/ignored.log')
  cd(dir)
  return dir
end

-- The entries ---------------------------------------------------------------------------------
local dir = fixture()
local root = store.root_of(dir .. '/a.txt')
check('review: no file open, the tour is built from the working directory\'s repository', w.review() == nil)
local t = st.tours[1]
check('review: one unnamed tour flagged auto', #st.tours == 1 and t.auto == true and t.group == nil and st.active == 1, vim.inspect(st.tours))
check('review: modified, staged, new and untracked files, deleted and ignored ones left out, in git status order',
  vim.deep_equal(names(t, dir), { 'a.txt', 'b.txt', 'new_staged.txt', 'sub/s.txt', 'untracked.txt' }), vim.inspect(names(t, dir)))
check('review: steps have the diff overlay and nothing else', (function()
  for _, s in ipairs(t.steps) do
    if s.diff ~= true or s.title ~= nil or s.hunks ~= nil or s.group ~= nil then
      return false
    end
  end
  return true
end)(), vim.inspect(t.steps[1]))
check('review: the first entry is shown', status().step == 1 and code_file() == dir .. '/a.txt' and t.pos == 1)
check('review: ... with its diff', H.marks(function(d)
  return d.line_hl_group == 'WalkthroughAdded'
end, vim.fn.bufnr(dir .. '/a.txt')) == 1)
check('review: the map lists the files under Changes, without numbers or titles', H.panel_text() == table.concat({
  'Changes', '> ✓ a.txt', '    b.txt', '    new_staged.txt', '    sub/s.txt', '    untracked.txt',
}, '\n'), H.panel_text())
check('review: the bar', H.wait(function()
  return (H.panel_winbar():gsub('%%#[%w]*#', ''):gsub('%%%*', '')):match('^ Changes  · seen 1/5') ~= nil
end), H.panel_winbar())
check('review: the flag is saved', saved(root) and saved(root).tours[1].auto == true and saved(root).version == 2, vim.inspect(saved(root)))
w.close()
check('review: and comes back with resume', w.resume() == 'ok' and st.tours[1].auto == true and #st.tours[1].steps == 5)

-- Nothing is lost by going through the entries.
w.step(1)
check('review: the entries can be paged through', status().step == 2 and code_file() == dir .. '/b.txt')

-- Called twice: the review is made again, not added -------------------------------------------------
vim.fn.writefile({ 'u1', 'u2', 'u3', 'u4' }, dir .. '/untracked2.txt')
w.review()
check('review: a second one replaces the first', #st.tours == 1 and #st.tours[1].steps == 6 and st.tours[1].auto == true
  and status().step == 1, vim.inspect(names(st.tours[1], dir)))
vim.fn.delete(dir .. '/untracked2.txt')

-- A ref ---------------------------------------------------------------------------------------------
reset()
w.review('HEAD~1')
t = st.tours[1]
check('ref: files that differ from the ref, with c.txt', t and vim.deep_equal(names(t, dir),
  { 'a.txt', 'b.txt', 'c.txt', 'new_staged.txt', 'sub/s.txt', 'untracked.txt' }), t and vim.inspect(names(t, dir)))
check('ref: the steps diff against it', t and t.steps[1].diff == 'HEAD~1' and t.steps[3].diff == 'HEAD~1' and t.auto == true)
check('ref: the overlay shows the change since the ref', H.marks(function(d)
  return d.line_hl_group == 'WalkthroughAdded'
end, vim.fn.bufnr(dir .. '/a.txt')) == 1)
reset()
vim.cmd('Walkthrough review HEAD~1')
check(':Walkthrough review takes the ref', st.tours[1] and #st.tours[1].steps == 6 and st.tours[1].steps[1].diff == 'HEAD~1')
reset()
vim.cmd('Walkthrough review')
check(':Walkthrough review without a ref', st.tours[1] and #st.tours[1].steps == 5 and st.tours[1].steps[1].diff == true)
reset()
w.review('no-such-ref')
check('ref: an unknown one is reported and nothing is loaded', find('unknown revision no%-such%-ref') ~= nil and #st.tours == 0
  and st.panel_win == nil, vim.inspect(log))
reset()
w.review('-x')
check('ref: an option is no ref', find('unknown revision') ~= nil and #st.tours == 0)

-- The repository of the current file, else of the working directory -----------------------------------------
reset()
local other = H.repo({ ['o.txt'] = lines(3, 'o') }, { ['o.txt'] = with(lines(3, 'o'), { [2] = 'O2' }) })
vim.cmd('edit ' .. vim.fn.fnameescape(other .. '/o.txt'))
w.review()
check('review: the repository of the current file wins over the working directory', st.tours[1] and #st.tours[1].steps == 1
  and st.tours[1].steps[1].file == other .. '/o.txt' and st.tours[1].root == store.root_of(other .. '/o.txt'), vim.inspect(names(st.tours[1] or { steps = {} }, dir)))
reset()
vim.cmd('enew')
vim.bo.buftype = 'nofile'
w.review()
check('review: a buffer that is no file falls back to the working directory', st.tours[1] and #st.tours[1].steps == 5)
reset()

-- Nothing changed, not a repository -----------------------------------------------------------------------------------
local clean = H.repo({ ['k.txt'] = lines(2, 'k') }, {})
cd(clean)
vim.cmd('enew')
w.review()
check('nothing changed: it says so', find('no changed files') ~= nil and not find('against'), vim.inspect(log))
check('nothing changed: and changes nothing', #st.tours == 0 and st.panel_win == nil and status().step == 0
  and saved(store.root_of(clean .. '/k.txt')) == nil)
reset_log()
w.review('HEAD')
check('nothing changed against a ref: the ref is named', find('no changed files against HEAD') ~= nil and #st.tours == 0)
-- A review left from before stays when there is nothing new to show.
cd(dir)
w.review()
cd(clean)
vim.cmd('enew')
reset_log()
w.review()
check('nothing changed: a tour that is open stays', find('no changed files') ~= nil and #st.tours == 1 and st.tours[1].root ~= nil
  and #st.tours[1].steps == 5)
reset()
local plain = vim.fn.tempname()
vim.fn.mkdir(plain)
cd(plain)
vim.cmd('enew')
w.review()
check('review outside a repository says so', find('not in a git repository') ~= nil and #st.tours == 0, vim.inspect(log))
cd(dir)

-- An agent's tour replaces it, and the threads follow by file ---------------------------------------------------------------
reset()
w.review()
local function at(line)
  vim.api.nvim_set_current_win(st.code_win)
  vim.api.nvim_win_set_cursor(0, { line, 0 })
end
local function step_for(tour, name)
  for _, s in ipairs(tour.steps) do
    if s.file == dir .. '/' .. name then
      return s
    end
  end
end
at(3)
w.ask('why A3?')
w.step(1)
w.step(1)
w.step(1)
at(4)
w.change('the s file')
check('replace: threads on the review', #step_for(st.tours[1], 'a.txt').threads == 1 and #step_for(st.tours[1], 'sub/s.txt').threads == 1)
check('replace: the agent sends a tour with a group', send('load', { group = 'Feature', steps = {
  { file = dir .. '/b.txt', title = 'b changed', hunks = { { from = 2, group = 'Feature' } } },
  { file = dir .. '/a.txt', title = 'a changed', hunks = { { from = 3, group = 'Feature' } } },
} }) == 'ok')
check('replace: the review is gone, the tour is there', #st.tours == 1 and st.tours[1].group == 'Feature' and not st.tours[1].auto
  and status().group == 'Feature', vim.inspect(st.tours))
local a_step = step_for(st.tours[1], 'a.txt')
check('replace: the thread went to the step with the same file', a_step.threads and #a_step.threads == 1
  and a_step.threads[1].messages[1].text == 'why A3?' and a_step.threads[1].id == 't1' and a_step.threads[1].from == 3
  and a_step.threads[1].state == 'waiting', vim.inspect(a_step.threads))
check('replace: a file the agent does not list takes its threads with it', step_for(st.tours[1], 'b.txt').threads == nil
  and not vim.inspect(st.tours[1]):find('the s file', 1, true))
check('replace: the thread counter goes on', (st.tours[1].next_thread or 0) >= 3, st.tours[1].next_thread)
check('replace: the state file holds the agent\'s tour only', #saved(root).tours == 1 and saved(root).tours[1].group == 'Feature'
  and saved(root).tours[1].auto == nil)
w.step(1)
check('replace: the thread is drawn', H.marks(function(d)
  return d.virt_lines ~= nil and d.virt_lines[1][1][1]:match('t1 %(waiting%) you: why A3%?') ~= nil
end, vim.fn.bufnr(dir .. '/a.txt')) == 1)

-- A tour with a group does not touch the review of another repository, and a failing load keeps the review.
reset()
w.review()
check('replace: a tour that fails to load leaves the review alone', send('load', { group = 'Bad', steps = { { file = dir .. '/a.txt', diff = 'no-such-ref' } } })
  :match('^error:') ~= nil and #st.tours == 1 and st.tours[1].auto == true and status().step == 1, vim.inspect(st.tours))
reset()
w.review()
at(3)
w.ask('carry me')
check('replace: an unnamed tour of the agent takes the place of the review too, threads by file', send('load', { steps = {
  { file = dir .. '/a.txt', title = 'a changed' },
} }) == 'ok' and #st.tours == 1 and not st.tours[1].auto and st.tours[1].steps[1].threads
  and st.tours[1].steps[1].threads[1].messages[1].text == 'carry me', vim.inspect(st.tours))
-- ... and the review does not take the agent's unnamed tour away.
reset_log()
w.review()
check('review: the unnamed tour of the agent is not replaced', find('without a commit name') ~= nil and #st.tours == 1
  and not st.tours[1].auto and st.tours[1].steps[1].title == 'a changed', vim.inspect(log))
reset()

-- Staging an entry without ranges (needs gitsigns) -----------------------------------------------------------------------
local gs = H.gitsigns()
if not gs then
  H.skip('review staging tests (gitsigns.nvim not on the packpath; set WALKTHROUGH_GITSIGNS)')
  H.finish()
  return
end
local function cached(d, file)
  return H.git_in(d, 'diff', '--cached', '--numstat', '--', file)
end
-- What is still unstaged, apart from the deleted d.txt of the fixture.
local function unstaged(d)
  return H.git_in(d, 'diff', '--stat', '--', ':(exclude)d.txt')
end

dir = fixture()
w.review()
H.attach()
reset_log()
w.stage_group()
local n = H.wait_notify(find, 'staged a%.txt')
check('stage: an entry without ranges stages the unstaged changes of its file and says so', n ~= nil and n.msg == 'walkthrough: staged a.txt'
  and n.level == vim.log.levels.INFO, vim.inspect(log))
check('stage: git has it', H.wait(function() return cached(dir, 'a.txt'):match('^1%s+1') ~= nil end), cached(dir, 'a.txt'))
check('stage: nothing is left unstaged in the file', H.git_in(dir, 'diff', '--', 'a.txt') == '')
reset_log()
w.stage_group()
n = H.wait_notify(find, 'nothing left to stage')
check('stage: again, nothing is left and nothing is unstaged', n ~= nil and n.msg == 'walkthrough: nothing left to stage in a.txt'
  and cached(dir, 'a.txt'):match('^1%s+1') ~= nil, vim.inspect(log))

-- An untracked file: registered first, then staged.
w.step(4)
H.attach()
check('stage: the untracked entry is shown', code_file() == dir .. '/untracked.txt')
check('stage: it is untracked', H.git_in(dir, 'ls-files', 'untracked.txt') == '')
reset_log()
w.stage_group()
n = H.wait_notify(find, 'staged untracked%.txt')
check('stage: the untracked file is staged and reported', n ~= nil and n.msg == 'walkthrough: staged untracked.txt', vim.inspect(log))
check('stage: it is tracked now, with all its lines staged', H.git_in(dir, 'ls-files', 'untracked.txt') == 'untracked.txt'
  and H.wait(function() return cached(dir, 'untracked.txt'):match('^3%s+0') ~= nil end), cached(dir, 'untracked.txt'))
check('stage: the registration was announced too', find('registered with git add %-N') ~= nil)

-- stage all: every entry without ranges; the gate asks about unseen steps.
local asked, answer = {}, 2
local real_confirm = vim.fn.confirm
vim.fn.confirm = function(msg, choices, default)
  table.insert(asked, { msg = msg, default = default })
  return answer
end
reset_log()
w.stage_group({ all = true })
check('stage all: unseen entries ask once, the default is to cancel, files are counted', #asked == 1 and asked[1].default == 2
  and asked[1].msg:match('3 of 5 entries were not shown yet%. Stage 5 files anyway%?') ~= nil, vim.inspect(asked))
check('stage all: cancelling stages nothing more', find('not staged') ~= nil and unstaged(dir):match('sub/s%.txt') ~= nil)
answer = 1
asked = {}
reset_log()
w.stage_group({ all = true })
n = H.wait_notify(find, 'staged')
check('stage all: the message names the files that were staged now', n ~= nil and n.level == vim.log.levels.INFO
  and n.msg:match('^walkthrough: staged ') ~= nil and n.msg:match('sub/s%.txt') ~= nil and not n.msg:match('a%.txt,') and not n.msg:match('group'),
  vim.inspect(log))
check('stage all: sub/s.txt is staged', H.wait(function() return cached(dir, 'sub/s.txt'):match('^1%s+1') ~= nil end), cached(dir, 'sub/s.txt'))
check('stage all: nothing is left unstaged in the repository', unstaged(dir) == '', unstaged(dir))
reset_log()
asked = {}
w.stage_group({ all = true })
n = H.wait_notify(find, 'nothing left')
check('stage all again: nothing left, nothing unstaged by mistake', n ~= nil and n.msg == 'walkthrough: nothing left to stage in 5 files'
  and unstaged(dir) == '' and cached(dir, 'a.txt'):match('^1%s+1') ~= nil, vim.inspect(log))

-- Ranges and no ranges in one tour ---------------------------------------------------------------------------------------------
dir = fixture()
w.close()
vim.cmd('silent! %bwipeout!')
assert(send('load', { group = 'G', steps = {
  { file = dir .. '/a.txt', title = 'by range', hunks = { { from = 3, group = 'G' } } },
  { file = dir .. '/sub/s.txt', title = 'whole file' },
} }) == 'ok')
H.attach()
w.step(1)
reset_log()
asked = {}
w.stage_group({ all = true })
n = H.wait_notify(find, 'staged commit')
check('stage all, mixed: the ranges are staged by line, the other file as a whole', n ~= nil
  and n.msg == 'walkthrough: staged commit "G": 1 line in 1 file; staged sub/s.txt', vim.inspect(log))
check('stage all, mixed: git agrees', H.wait(function() return cached(dir, 'sub/s.txt'):match('^1%s+1') ~= nil end)
  and cached(dir, 'a.txt'):match('^1%s+1') ~= nil)
vim.fn.confirm = real_confirm

reset()
H.finish()
