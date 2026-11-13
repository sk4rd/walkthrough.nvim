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
check('format: version, root, active, tours', data and data.version == 2 and data.root == root and data.active == 'A' and #data.tours == 1, vim.inspect(data))
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
check('resume: the map is shown, with the marker on the step shown', H.panel_text() == 'A\n> ✓ a.txt\n    a\n  ✓ b.txt\n    b'
  and H.panel_winbar():match('seen 2/2') ~= nil, H.panel_text() .. H.panel_winbar())
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

-- A state file of format 1 is migrated -----------------------------------------------
-- Written by hand as an older version wrote it: steps carry `panel` and
-- `check`; everything else must survive.
reset()
local old_repo = H.repo({ ['a.txt'] = lines(6), ['b.txt'] = lines(3, 'b') },
  { ['a.txt'] = edited(lines(6), 2, 2, 'NEW') })
cd(old_repo)
local old_root = store.root_of(old_repo .. '/a.txt')
local format1 = ([[{"version":1,"root":"%s","active":"A","tours":[{"group":"A","pos":1,"depth":"deeper","next_comment":6,
"steps":[
{"file":"%s/a.txt","title":"first","group":"A","diff":true,"seen":true,
 "panel":"# One\n\nan explanation","check":{"question":"q?","answer":"a","revealed":true,"reply":"mine","reply_sent":true},
 "hunks":[{"from":2,"to":2,"group":"A"}],"notes":[{"line":2,"text":"n","detail":"d","n":1}],"next_note":2,
 "comments":[
  {"id":"c1","from":3,"to":3,"type":"question","text":"why?"},
  {"id":"c2","from":4,"to":5,"type":"issue","text":"bug here","sent":true},
  {"id":"c3","from":2,"to":2,"type":"suggestion","text":"use a loop","sent":true,"answer":["agreed","will do"]},
  {"id":"c4","from":6,"to":6,"type":"question","text":"and this?","sent":true,"answer":"because","resolved":true},
  {"id":"c5","from":1,"to":1,"type":"question","text":"first line?","sent":true,"answer":"yes","stale":true}],
 "_snap":["l1","NEW2","l3","l4","l5","l6"]},
{"file":"%s/b.txt","title":"second","group":"A","panel":["# Two","text"],"_snap":["b1","b2","b3"]}
]}]}]]):format(old_root, old_root, old_root)
vim.fn.mkdir(st.config.state_dir, 'p')
vim.fn.writefile({ format1 }, store.path(old_root))
check('format 1: resume reads it', w.resume() == 'ok', w.resume())
local step1, step2 = st.history[1], st.history[2]
check('format 1: panel and check are dropped from every step', step1 and step2 and step1.panel == nil and step1.check == nil
  and step2.panel == nil, vim.inspect(st.history))
check('format 1: everything else is kept', step1.title == 'first' and step1.seen == true and step1.hunks[1].from == 2
  and step1.notes[1].detail == 'd' and step1.notes[1].n == 1
  and st.tours[1].depth == 'deeper' and step2.title == 'second', vim.inspect(st.tours[1]))
local function thread(id)
  for _, x in ipairs(step1.threads or {}) do
    if x.id == id then
      return x
    end
  end
end
check('format 1: comments become threads, the comment fields are gone', #step1.threads == 5 and step1.comments == nil
  and st.tours[1].next_thread == 6 and st.tours[1].next_comment == nil, vim.inspect(step1.threads))
check('format 1: an unsent question is a draft question with its text as the first message', thread('t1') and thread('t1').kind == 'question'
  and thread('t1').state == 'draft' and thread('t1').sent == 0 and thread('t1').from == 3 and thread('t1').to == 3
  and vim.deep_equal(thread('t1').messages, { { by = 'user', text = 'why?' } }), vim.inspect(thread('t1')))
check('format 1: an issue that was sent is a change request that waits', thread('t2').kind == 'change' and thread('t2').state == 'waiting'
  and thread('t2').sent == 1 and thread('t2').from == 4 and thread('t2').to == 5 and #thread('t2').messages == 1, vim.inspect(thread('t2')))
check('format 1: an answered suggestion is a change request with the answer as an agent message', thread('t3').kind == 'change'
  and thread('t3').state == 'answered' and thread('t3').sent == 2
  and vim.deep_equal(thread('t3').messages, { { by = 'user', text = 'use a loop' }, { by = 'agent', text = 'agreed\nwill do' } }),
  vim.inspect(thread('t3')))
check('format 1: a resolved comment is done', thread('t4').kind == 'question' and thread('t4').state == 'done'
  and thread('t4').messages[2].text == 'because', vim.inspect(thread('t4')))
check('format 1: stale stays', thread('t5').stale == true and thread('t5').state == 'answered')
check('format 1: the map shows the migrated tour, and counts its threads', H.panel_text()
  == 'A\n> ✓ a.txt\n    first\n    b.txt\n    second\n1 waiting · 1 not sent', H.panel_text())
w.step(1)
local written = table.concat(vim.fn.readfile(store.path(old_root)), '\n')
check('format 1: the next save writes format 2 without the old fields', saved(old_root).version == 2 and not written:match('"panel"')
  and not written:match('"check"'), written)
w.close()
check('format 1: and the new file resumes', w.resume() == 'ok' and #st.history == 2 and #st.history[1].threads == 5
  and st.history[1].threads[1].messages[1].text == 'why?' and not written:match('"comments"') and not written:match('next_comment'))
reset()
-- A format 2 file written while threads were being built still has comments.
local format2 = format1:gsub('"version":1', '"version":2'):gsub('\n "panel":[^\n]*', ''):gsub('"panel":%["# Two","text"%],', '')
vim.fn.writefile({ format2 }, store.path(old_root))
check('format 2 with comments: converted the same way', w.resume() == 'ok' and #st.history[1].threads == 5
  and st.history[1].threads[3].state == 'answered' and st.history[1].comments == nil and st.tours[1].next_thread == 6,
  vim.inspect(st.history))
-- A comment that is not one fails validation: the step is dropped, as for any bad step.
reset()
vim.fn.writefile({ (format1:gsub('"type":"issue"', '"type":"issue","from":"x"'):gsub('"id":"c2"', '"id":"cx"')) }, store.path(old_root))
local bad_res = w.resume()
check('format 1: a malformed comment drops its step, like any bad step', bad_res == 'ok' and #st.history == 1
  and st.history[1].title == 'second', tostring(bad_res) .. vim.inspect(st.history))
reset()
vim.fn.writefile({ (format1:gsub('"version":1', '"version":3')) }, store.path(old_root))
check('an unknown newer format is still refused', w.resume():match('unknown format') ~= nil)
reset()

-- A comment is a thread of a plan only ---------------------------------------------------
reset()
repo = H.repo({ ['a.txt'] = lines(6), ['b.txt'] = lines(6, 'b') },
  { ['a.txt'] = edited(lines(6), 2, 2, 'NEW'), ['b.txt'] = edited(lines(6, 'b'), 2, 2, 'NEW') })
cd(repo)
a, b = repo .. '/a.txt', repo .. '/b.txt'
root = store.root_of(a)
send('load', { group = 'K', steps = { { file = a, title = 'one' }, { file = b, title = 'two' } } })
vim.cmd('edit ' .. vim.fn.fnameescape(a))
w.ask('why here?', { 2, 2 })
w.change('rename it', { 3, 3 })
vim.cmd('edit ' .. vim.fn.fnameescape(b))
w.change('and this', { 2, 2 })
local kinds_saved = vim.tbl_map(function(th) return th.kind end, saved(root).tours[1].steps[1].threads)
check('in a review of code a question and a change request are saved as such', vim.deep_equal(kinds_saved, { 'question', 'change' })
  and saved(root).tours[1].steps[2].threads[1].kind == 'change', vim.inspect(kinds_saved))
local forged = saved(root)
forged.tours[1].steps[1].threads[1].kind = 'comment'
w.close()
vim.fn.writefile({ vim.json.encode(forged) }, store.path(root))
check('a saved comment in a tour of code is refused like any unknown kind: its step is dropped, the other stays',
  w.resume() == 'ok' and #st.history == 1 and st.history[1].title == 'two' and st.history[1].threads[1].kind == 'change',
  vim.inspect(st.history))
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
