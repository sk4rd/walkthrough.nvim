-- Review state on disk (P-3): save after every change, `resume` after a
-- restart, merge on load, discard, separate repositories, write failures.
local H = require('helpers')
local check, send, w = H.check, H.send, H.w
local st = _G.walkthrough_state
local store = require('walkthrough.store')
local log, find = H.capture_notify()
local function status()
  return vim.json.decode(w.status())
end
local function reset_log()
  for i = #log, 1, -1 do
    log[i] = nil
  end
end
local function reset()
  w.close()
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
local function lines(n, prefix)
  local out = {}
  for i = 1, n do
    out[i] = (prefix or 'l') .. i
  end
  return out
end
local function edited(base, from, to, text)
  local out = vim.list_slice(base)
  for i = from, to do
    out[i] = text .. i
  end
  return out
end
local function write(repo, name, content)
  vim.fn.writefile(content, repo .. '/' .. name)
end
local function cd(dir)
  vim.cmd('cd ' .. vim.fn.fnameescape(dir))
end
local home = H.work

check('the state directory is the one run.sh made', st.config.state_dir == vim.env.WALKTHROUGH_STATE_DIR
  and not st.config.state_dir:find(H.work, 1, true), st.config.state_dir)

-- Round trip, with edits in between ------------------------------------------------
local base = lines(8)
local repo = H.repo({ ['a.txt'] = base, ['b.txt'] = lines(4, 'b') }, { ['a.txt'] = edited(base, 3, 3, 'NEW'), ['b.txt'] = edited(lines(4, 'b'), 2, 2, 'NEW') })
cd(repo)
local a, b = repo .. '/a.txt', repo .. '/b.txt'
local root = store.root_of(a)
check('root is the git top-level', root == vim.uv.fs_realpath(repo) or root == repo, root)
check('load', send('load', { group = 'A', steps = {
  { file = a, title = 'a', notes = { { line = 5, text = 'five' } }, hunks = { { from = 3, to = 3, group = 'A' } } },
  { file = b, title = 'b' },
} }) == 'ok')
w.step(1)
local data = saved(root)
check('the file is named by the sha256 of the root', vim.fn.filereadable(st.config.state_dir .. '/' .. vim.fn.sha256(root) .. '.json') == 1)
check('format: version, root, active, tours', data and data.version == 1 and data.root == root and data.active == 'A' and #data.tours == 1, vim.inspect(data))
local t = data and data.tours[1]
check('format: all step fields incl. internal ones', t and t.pos == 2 and t.steps[1]._snap[1] == 'l1' and t.steps[1].seen == true
  and t.steps[1].notes[1].n == 1 and t.steps[1].next_note == 2 and t.steps[2].seen == true, vim.inspect(t))
check('the fixture repository is untouched by the state file', H.git(('status'), '--porcelain'):find('walkthrough') == nil)

w.close()
check('close: status is {"step":0}', w.status() == '{"step":0}')
check('close keeps the file', saved(root) ~= nil)
check('close clears the screen', H.marks(function() return true end, vim.fn.bufnr(a)) == 0 and st.panel_win == nil)

-- Edit while nothing is open: two lines inserted at the top.
write(repo, 'a.txt', vim.list_extend({ 'x1', 'x2' }, edited(base, 3, 3, 'NEW')))
check('resume', w.resume() == 'ok', w.resume())
local s = status()
check('resume: back on the step it was left on', s.step == 2 and s.group == 'A' and s.title == 'b' and s.total == 2, vim.inspect(s))
check('resume: seen survived', s.seen == 2)
w.step(-1)
check('resume: the note followed the edit', st.history[1].notes[1].line == 7 and not st.history[1].notes[1].stale, vim.inspect(st.history[1].notes))
check('resume: the range followed the edit', st.history[1].hunks[1].from == 5 and st.history[1].hunks[1].to == 5 and not st.history[1].hunks[1].stale)
check('resume: the note is drawn on its new line', H.marks(function(d, m)
  return m[2] == 6 and d.virt_lines ~= nil and d.virt_lines[1][1][1]:match('%[1%] five') ~= nil
end, vim.fn.bufnr(a)) == 1)
check('resume: the panel is shown', H.panel_text() ~= '' and H.panel_winbar():match('Step 1/2') ~= nil, H.panel_winbar())
check('resume: nothing was added twice', #st.tours == 1)

-- Resume with nothing saved / outside any state --------------------------------------
local empty = H.repo({ ['z.txt'] = lines(2) }, {})
reset()
cd(empty)
local res = w.resume()
check('resume: nothing to resume says so', res:match('^error: nothing to resume') ~= nil and not res:match('\n'), res)
vim.cmd('Walkthrough resume')
check(':Walkthrough resume reports the same as a notification', find('nothing to resume') ~= nil)

-- The current file's repository counts as well ------------------------------------------
cd(empty)
vim.cmd('edit ' .. vim.fn.fnameescape(a))
check('resume from the current buffer\'s repository', w.resume() == 'ok' and status().group == 'A')
cd(home)

-- A committed tour is pruned; a tour without a diff stays ---------------------------------
reset()
repo = H.repo({ ['a.txt'] = lines(6), ['b.txt'] = lines(6, 'b') },
  { ['a.txt'] = edited(lines(6), 2, 2, 'NEW'), ['b.txt'] = edited(lines(6, 'b'), 2, 2, 'NEW') })
cd(repo)
a, b = repo .. '/a.txt', repo .. '/b.txt'
root = store.root_of(a)
send('load', { group = 'A', steps = { { file = a, hunks = { { from = 2, group = 'A' } } } } })
send('load', { group = 'B', steps = { { file = b, diff = false } } })
send('load', { group = 'C', steps = { { file = b, hunks = { { from = 2, group = 'C' } } } } })
w.close()
H.git_in(repo, 'add', 'a.txt')
H.git_in(repo, 'commit', '-qm', 'A done')
check('resume after committing A', w.resume() == 'ok')
local groups = vim.tbl_map(function(g) return g.group end, status().groups)
check('the committed tour is dropped, the others stay', vim.deep_equal(groups, { 'B', 'C' }), vim.inspect(groups))
check('... the active one is shown', status().group == 'C')
w.close()
H.git_in(repo, 'commit', '-qam', 'rest')
check('resume: B has no diff so it stays; C was committed', w.resume() == 'ok' and #status().groups == 1 and status().group == 'B')
reset()
-- Staged but not committed is still uncommitted.
write(repo, 'b.txt', edited(lines(6, 'b'), 2, 2, 'AGAIN'))
send('load', { group = 'D', steps = { { file = b, hunks = { { from = 2, group = 'D' } } } } })
w.close()
H.git_in(repo, 'add', 'b.txt')
check('a staged tour is kept', w.resume() == 'ok' and status().group == 'D')
reset()
-- Everything committed: nothing to resume.
local done = H.repo({ ['a.txt'] = lines(4) }, { ['a.txt'] = edited(lines(4), 2, 2, 'NEW') })
cd(done)
send('load', { group = 'A', steps = { { file = done .. '/a.txt', hunks = { { from = 2, group = 'A' } } } } })
w.close()
H.git_in(done, 'commit', '-qam', 'all')
res = w.resume()
check('resume: only committed tours leave nothing to resume', res:match('^error: nothing to resume') and res:match('committed'), res)
check('... and nothing is shown', status().step == 0)

-- A step whose file is gone is dropped ---------------------------------------------------
reset()
repo = H.repo({ ['a.txt'] = lines(5), ['b.txt'] = lines(5, 'b'), ['c.txt'] = lines(5, 'c') }, { ['a.txt'] = edited(lines(5), 2, 2, 'N') })
cd(repo)
a, b = repo .. '/a.txt', repo .. '/b.txt'
local c = repo .. '/c.txt'
send('load', { group = 'A', start = 2, steps = { { file = a, title = 'a' }, { file = b, title = 'b' }, { file = c, title = 'c' } } })
send('load', { group = 'Gone', steps = { { file = b, title = 'only b' } } })
w.close()
vim.fn.delete(b)
check('resume with a deleted file', w.resume() == 'ok')
s = status()
check('the tour that lost all its files is dropped', #s.groups == 1 and s.group == 'A', vim.inspect(s))
check('the step is dropped and the position moves to the next one', s.total == 2 and s.title == 'c' and s.step == 2, vim.inspect(s))
reset()

-- Merge on load after a restart ---------------------------------------------------------------
repo = H.repo({ ['a.txt'] = lines(6), ['b.txt'] = lines(6, 'b') }, { ['a.txt'] = edited(lines(6), 2, 2, 'N'), ['b.txt'] = edited(lines(6, 'b'), 2, 2, 'N') })
cd(repo)
a, b = repo .. '/a.txt', repo .. '/b.txt'
root = store.root_of(a)
send('load', { group = 'A', steps = { { file = a, title = 'a1' }, { file = a, title = 'a2' } } })
w.step(1)
send('load', { group = 'B', steps = { { file = b, title = 'b1' } } })
-- The editor is gone: memory is empty, the file is not.
st.tours, st.active = {}, 0
check('restart: memory is empty', #st.tours == 0)
check('load of a third group after the restart', send('load', { group = 'C', steps = { { file = a, title = 'c1' } } }) == 'ok')
s = status()
local gn = vim.tbl_map(function(g) return g.group end, s.groups)
check('merge: the stored tours came back first', vim.deep_equal(gn, { 'A', 'B', 'C' }), vim.inspect(gn))
check('merge: the new tour is active', s.group == 'C' and s.step == 1)
check('merge: positions and seen survived', st.tours[1].pos == 2 and st.tours[1].steps[2].seen == true and st.tours[1].steps[1].seen == true)
check('merge: the file still holds all three', #saved(root).tours == 3)
-- And a resent group replaces the stored one.
st.tours, st.active = {}, 0
send('load', { group = 'A', steps = { { file = a, title = 'a1' }, { file = a, title = 'a2' }, { file = a, title = 'a3' } } })
gn = vim.tbl_map(function(g) return g.group end, status().groups)
check('merge: the same group replaces the stored one', vim.deep_equal(gn, { 'A', 'B', 'C' }) and status().group == 'A'
  and #st.tours[1].steps == 3 and st.tours[1].steps[2].seen == true and not st.tours[1].steps[3].seen, vim.inspect(gn))
-- A lone step after a restart does not wipe either.
st.tours, st.active = {}, 0
check('lone step after a restart', send('load', { file = b, title = 'late' }) == 'ok' and #status().groups == 3, vim.inspect(status().groups))
reset()

-- Discard ------------------------------------------------------------------------------------
send('load', { group = 'A', steps = { { file = a } } })
check('discard: the file exists first', saved(root) ~= nil)
check('discard', w.discard() == 'ok')
check('discard: the file is gone', saved(root) == nil)
check('discard: memory and screen are clear', status().step == 0 and #st.tours == 0 and st.panel_win == nil)
check('discard: resume has nothing', w.resume():match('^error: nothing to resume') ~= nil)
check('discard: twice is fine', w.discard() == 'ok')
vim.cmd('Walkthrough discard')
check(':Walkthrough discard', #log == 0 or not find('error'))

-- Two repositories never mix ---------------------------------------------------------------------
reset()
local r1 = H.repo({ ['a.txt'] = lines(4) }, { ['a.txt'] = edited(lines(4), 2, 2, 'N') })
local r2 = H.repo({ ['a.txt'] = lines(4) }, { ['a.txt'] = edited(lines(4), 2, 2, 'M') })
cd(r1)
send('load', { group = 'One', steps = { { file = r1 .. '/a.txt' } } })
cd(r2)
send('load', { group = 'Two', steps = { { file = r2 .. '/a.txt' } } })
local root1, root2 = store.root_of(r1 .. '/a.txt'), store.root_of(r2 .. '/a.txt')
check('two files', root1 ~= root2 and saved(root1) ~= nil and saved(root2) ~= nil)
check('each file holds only its own repository', #saved(root1).tours == 1 and saved(root1).tours[1].group == 'One'
  and #saved(root2).tours == 1 and saved(root2).tours[1].group == 'Two' and saved(root1).root == root1)
w.close()
cd(r1)
check('resume in the first repository', w.resume() == 'ok' and #status().groups == 1 and status().group == 'One')
w.close()
cd(r2)
check('resume in the second', w.resume() == 'ok' and #status().groups == 1 and status().group == 'Two')
-- Merge on load does not pull in the other repository either.
w.close()
cd(r1)
send('load', { group = 'Three', steps = { { file = r1 .. '/a.txt' } } })
gn = vim.tbl_map(function(g) return g.group end, status().groups)
check('merge stays inside the repository', vim.deep_equal(gn, { 'One', 'Three' }), vim.inspect(gn))
reset()

-- Outside a repository the file's directory is the root ---------------------------------------------------
local plain = vim.fn.tempname()
vim.fn.mkdir(plain)
vim.fn.writefile({ 'one', 'two' }, plain .. '/p.txt')
cd(plain)
send('load', { group = 'P', steps = { { file = plain .. '/p.txt' } } })
check('no repository: root is the directory', saved(vim.fn.fnamemodify(plain .. '/p.txt', ':p:h')) ~= nil)
w.close()
check('no repository: resume works', w.resume() == 'ok' and status().group == 'P')
reset()

-- A corrupt state file -------------------------------------------------------------------------------------
cd(r1)
vim.fn.writefile({ '{ not json' }, store.path(root1))
res = w.resume()
check('corrupt file: resume reports it', res:match('^error: .*cannot be read') ~= nil and not res:match('\n'), res)
check('corrupt file: load still works and replaces it', send('load', { group = 'Fresh', steps = { { file = r1 .. '/a.txt' } } }) == 'ok'
  and saved(root1) ~= nil and saved(root1).tours[1].group == 'Fresh')
vim.fn.writefile({ vim.json.encode({ version = 99, root = root1, tours = {} }) }, store.path(root1))
check('unknown format is reported', w.resume():match('unknown format') ~= nil)
reset()

-- A write that fails never fails the operation -----------------------------------------------------------
local good = st.config.state_dir
st.config.state_dir = '/dev/null/cannot/exist'
st.save_warned = nil
cd(r1)
check('unwritable state_dir: load still succeeds', send('load', { group = 'W', steps = { { file = r1 .. '/a.txt' }, { file = r1 .. '/a.txt', title = 't' } } }) == 'ok')
check('... the tour is loaded and shown', status().group == 'W' and status().step == 1)
check('... the user is told once', (function()
  local n = 0
  for _, l in ipairs(log) do
    if l.msg:match('cannot save the review state') then
      n = n + 1
    end
  end
  return n == 1
end)(), vim.inspect(log))
w.step(1)
send('patch', { title = 'again' })
local n = 0
for _, l in ipairs(log) do
  if l.msg:match('cannot save the review state') then
    n = n + 1
  end
end
check('... and not again on later changes', n == 1 and status().step == 2, n)
st.config.state_dir = good
reset()

cd(home)
H.finish()
