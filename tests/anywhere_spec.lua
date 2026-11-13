-- Annotating anywhere and sessions on existing code: threads on any file in
-- any window (in a tour, in no tour, with nothing loaded, outside a
-- repository), the thread drawer in buffers the code window does not cover,
-- one id space per repository, send / inbox / status over all tours, the
-- automatic restore, close, and the hand-over to a review. The agent's channel
-- is stubbed as in feedback_spec.lua.
local H = require('helpers')
local check, send, w = H.check, H.send, H.w
local st = _G.walkthrough_state
local tour = require('walkthrough.tour')
local tours = require('walkthrough.tours')
local store = require('walkthrough.store')
local ui = require('walkthrough.ui')
local thread = require('walkthrough.thread')
local log, find = H.capture_notify()
local ns_threads = vim.api.nvim_get_namespaces().walkthrough_threads

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
local function reset_log()
  for i = #log, 1, -1 do
    log[i] = nil
  end
end
local function cd(dir)
  vim.cmd('cd ' .. vim.fn.fnameescape(dir))
end

local sent = {}
local function collecting(msg)
  table.insert(sent, msg)
end
st.config.sender = collecting
local answer
vim.ui.input = function(_, cb)
  cb(answer)
end
local confirm_result = 1
vim.fn.confirm = function()
  return confirm_result
end

local repo = H.repo({
  ['a.txt'] = lines(30), ['b.txt'] = lines(10, 'b'), ['c.txt'] = lines(10, 'c'), ['d.txt'] = lines(10, 'd'),
  ['x.txt'] = lines(10, 'x'),
}, {})
cd(repo)
local a, b, c, d, x = repo .. '/a.txt', repo .. '/b.txt', repo .. '/c.txt', repo .. '/d.txt', repo .. '/x.txt'
local root = store.root_of(a)

local function reset()
  w.discard()
  w.close()
  vim.cmd('silent! %bwipeout!')
  vim.cmd('silent! only')
  st.restored, st.dir_roots = {}, {}
  sent, answer = {}, nil
  st.config.sender = collecting
  reset_log()
  vim.fn.writefile(lines(30), a)
  vim.fn.writefile(lines(10, 'b'), b)
  vim.fn.writefile(lines(10, 'c'), c)
  vim.fn.writefile(lines(10, 'd'), d)
  vim.fn.writefile(lines(10, 'x'), x)
end
-- A tour A of a and b, shown on a.
local function load_a()
  assert(send('load', { group = 'A', steps = { { file = a, title = 'one' }, { file = b, title = 'two' } } }) == 'ok')
  -- The first commit of a map stays current: when another commit was loaded
  -- before, A is shown by choice.
  w.group('A')
  vim.cmd('edit! ' .. vim.fn.fnameescape(a))
end
local function at(line)
  vim.api.nvim_win_set_cursor(0, { line, 0 })
end
local function th(id)
  for _, t in ipairs(st.tours) do
    local x_, step, si = tour.find_thread(t.steps, id)
    if x_ then
      return x_, t, step, si
    end
  end
end
local function extra()
  return select(2, tours.find_extra(root))
end
local function saved()
  local path = store.path(root)
  if vim.fn.filereadable(path) == 0 then
    return nil
  end
  return vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
end
-- Every virtual line of the plugin in `buf`: { text, ns, row } (row 0-based).
local function vtexts(buf)
  local out = {}
  for _, id in ipairs({ H.ns, ns_threads }) do
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, id, 0, -1, { details = true })) do
      for _, vl in ipairs(m[4].virt_lines or {}) do
        table.insert(out, { text = H.vtext(vl), ns = id, row = m[2] })
      end
    end
  end
  return out
end
local function count_threads(buf)
  local n = 0
  for _, v in ipairs(vtexts(buf)) do
    if v.text:match('^%s*» t%d+') then
      n = n + 1
    end
  end
  return n
end
local function marks_everywhere()
  local n = 0
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    for _, id in ipairs({ H.ns, ns_threads }) do
      n = n + #vim.api.nvim_buf_get_extmarks(buf, id, 0, -1, {})
    end
  end
  return n
end
local function press(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), 'x', false)
end

check('the drawer has a namespace of its own', ns_threads ~= nil and ns_threads ~= H.ns)

-- Ask and change ------------------------------------------------------------------------------------------
reset()
load_a()
local code_win, code_buf = st.code_win, vim.api.nvim_win_get_buf(st.code_win)
local win_count = #vim.api.nvim_list_wins()
vim.cmd('split')
local split_win = vim.api.nvim_get_current_win()
at(5)
w.ask('why five?')
check('ask: in the shown entry\'s file from another window', th('t1') and th('t1').from == 5 and tours.active().steps[1].threads[1].id == 't1')
check('ask: ... nothing was switched', st.code_win == code_win and vim.api.nvim_win_get_buf(code_win) == code_buf
  and st.pos == 1 and vim.api.nvim_get_current_win() == split_win and #vim.api.nvim_list_wins() == win_count + 1)
check('ask: ... sent at once', #sent == 1 and th('t1').state == 'waiting')
check('ask: ... drawn once, in the buffer both windows show', count_threads(code_buf) == 1)

vim.cmd('edit ' .. vim.fn.fnameescape(b))
at(3)
w.change('rename it')
check('change: in another entry of the active tour', th('t2') and select(3, th('t2')) == tours.active().steps[2] and th('t2').kind == 'change'
  and th('t2').state == 'draft')
check('change: ... the shown step and the code window stay', st.pos == 1 and vim.api.nvim_win_get_buf(code_win) == code_buf)
check('change: ... drawn in the buffer the full draw does not cover', count_threads(vim.fn.bufnr(b)) == 1
  and #H.marks_at(3, vim.fn.bufnr(b)) == 0 and (function()
    for _, v in ipairs(vtexts(vim.fn.bufnr(b))) do
      if v.ns == ns_threads and v.text == '» t2 (not sent) you: rename it' then
        return true
      end
    end
  end)(), vim.inspect(vtexts(vim.fn.bufnr(b))))
answer = 'and the tests'
at(3)
w.ask()
check('ask: on the lines of an open change request, it is a reply in it', #th('t2').messages == 2 and not th('t3'))

-- A tour that is not the active one.
reset()
assert(send('load', { group = 'X', steps = { { file = x, title = 'x' } } }) == 'ok')
load_a()
check('setup: A is active, X is loaded', tours.active().group == 'A' and #st.tours == 2)
vim.cmd('split ' .. vim.fn.fnameescape(x))
at(4)
w.ask('what is x4?')
local _, tx = th('t1')
check('ask: an entry of a tour that is not active', tx and tx.group == 'X' and tours.active().group == 'A' and #st.tours == 2)
check('ask: ... that tour is saved', (function()
  local data = saved()
  return data and #data.tours == 2
end)())

-- A file two tours list: the active tour first, else the first that lists it.
reset()
assert(send('load', { group = 'X', steps = { { file = a, title = 'a in X' } } }) == 'ok')
load_a()
vim.cmd('split')
at(5)
w.ask('goes to the active tour')
check('ask: a file in two tours goes to the active one', select(2, th('t1')).group == 'A')
w.group('X')
vim.cmd('edit ' .. vim.fn.fnameescape(a))
at(9)
w.ask('goes to X now')
check('ask: ... else to the one that is active', select(2, th('t2')).group == 'X')
w.group('X') -- already on it: nothing
vim.cmd('edit ' .. vim.fn.fnameescape(c))
w.group('A')
vim.cmd('edit ' .. vim.fn.fnameescape(a))
at(9)
w.thread()
check('thread: the float finds the thread of the tour that is not active, on its line', thread.win() ~= nil
  and vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(thread.win()), 0, 1, false)[1]:match('^t2 ') ~= nil)
press('q')
-- Only the first tour that lists the file when the active one does not.
w.group('X')
vim.cmd('edit ' .. vim.fn.fnameescape(b))
at(2)
w.ask('b is only in A')
check('ask: a file only a tour that is not active lists goes there', select(2, th('t3')).group == 'A')

-- A file in no tour -------------------------------------------------------------------------------------------
reset()
load_a()
vim.cmd('split ' .. vim.fn.fnameescape(d))
at(2)
w.ask('what is this file?')
local ex = extra()
check('ask: a file in no tour creates the tour Other files', ex and ex.extra == true and ex.group == nil and #ex.steps == 1
  and ex.steps[1].file == d and ex.steps[1].diff == false and ex.steps[1].threads[1].id == 't1' and ex.root == root, vim.inspect(ex))
check('ask: ... the active tour and the shown step stay', tours.active().group == 'A' and st.pos == 1 and #st.tours == 2)
check('ask: ... it is the last of the map, with the path and no numbers', (function()
  local text = H.panel_text()
  return text:match('\nOther files\n   +d%.txt') ~= nil and not text:match('d%.txt%s+%d+/%d+')
end)(), H.panel_text())
check('ask: ... saved with the flag', (function()
  local data = saved()
  return data and #data.tours == 2 and data.tours[2].extra == true and data.tours[2].group == nil
end)(), vim.inspect(saved()))
vim.cmd('edit ' .. vim.fn.fnameescape(c))
at(1)
w.change('c1')
check('change: a second file joins Other files', #ex.steps == 2 and ex.steps[2].file == c and th('t2'))

-- Nothing loaded: a session starts by itself ------------------------------------------------------------------
reset()
vim.cmd('edit ' .. vim.fn.fnameescape(c))
local wins, buf_before, win_before = vim.api.nvim_list_wins(), vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
local code_before = st.code_win
at(4)
w.ask('hello?')
check('start: a session without a review', #st.tours == 1 and st.tours[1].extra == true and st.active == 0)
check('start: ... no panel, no window or buffer change', st.panel_win == nil
  and vim.deep_equal(vim.api.nvim_list_wins(), wins) and vim.api.nvim_get_current_buf() == buf_before
  and vim.api.nvim_get_current_win() == win_before and st.code_win == code_before)
check('start: ... the thread is drawn and sent', count_threads(buf_before) == 1 and #sent == 1 and th('t1').state == 'waiting')
check('start: ... saved', saved() and #saved().tours == 1 and saved().tours[1].extra == true)
local s = status()
check('status: with only Other files it is step 0 with threads and groups', s.step == 0 and s.threads.waiting == 1
  and s.groups[1].group == 'Other files' and s.groups[1].extra == true and s.groups[1].steps == 1 and s.total == nil, w.status())
check('socket entry points work with no step shown', w.inbox(true):match('"t1"') ~= nil and send('patch', { thread = 't1', answer = 'hi' }) == 'ok'
  and th('t1').state == 'answered')
check('start: ... a patch drew no window either', st.panel_win == nil and st.code_win == code_before and #vim.api.nvim_list_wins() == #wins)

-- Stored tours come first when a session starts
reset()
load_a()
at(2)
w.ask('in a')
st.tours, st.active = {}, 0 -- a restart
st.counters = {}
vim.cmd('silent! only')
vim.cmd('edit ' .. vim.fn.fnameescape(d))
at(3)
w.ask('in d')
check('start: the saved tours of the repository are merged first', #st.tours == 2 and tours.find('A') and th('t1') and th('t2')
  and select(2, th('t2')).extra == true, vim.inspect(vim.tbl_map(function(t_) return t_.group end, st.tours)))
check('start: ... without a panel, and the review is not on screen', not (st.panel_win and vim.api.nvim_win_is_valid(st.panel_win))
  and #vim.api.nvim_list_wins() == 1)

-- A file outside any repository -------------------------------------------------------------------------------
reset()
local plain = vim.fn.tempname()
vim.fn.mkdir(plain, 'p')
vim.fn.writefile(lines(5, 'p'), plain .. '/p.txt')
vim.cmd('edit ' .. vim.fn.fnameescape(plain .. '/p.txt'))
at(2)
w.ask('outside?')
local proot = store.root_of(plain .. '/p.txt')
check('outside a repository: the directory is the root', #st.tours == 1 and st.tours[1].extra and st.tours[1].root == proot
  and proot == vim.fs.dirname(vim.fn.fnamemodify(plain .. '/p.txt', ':p')), proot)
check('outside a repository: saved under that root', vim.fn.filereadable(store.path(proot)) == 1)
w.close()
check('outside a repository: close deletes the file', vim.fn.filereadable(store.path(proot)) == 0)

-- An unsaved buffer is refused ---------------------------------------------------------------------------------
reset()
vim.cmd('edit ' .. vim.fn.fnameescape(c))
vim.cmd('normal! ix')
w.ask('unsaved')
w.change('unsaved')
check('unsaved: refused, nothing created', #st.tours == 0 and find('save the file first') ~= nil and #sent == 0)
vim.cmd('edit!')
vim.cmd('enew')
reset_log()
w.ask('no file')
check('a buffer that is not a file is refused', #st.tours == 0 and find('this buffer is not one') ~= nil)
vim.cmd('bwipeout!')

-- The drawer --------------------------------------------------------------------------------------------------
reset()
load_a()
vim.cmd('split ' .. vim.fn.fnameescape(d))
at(5)
w.ask('five?')
local dbuf = vim.fn.bufnr(d)
local function first_text(buf)
  local v = vtexts(buf)
  return v[1] and v[1].text, v[1] and v[1].row
end
local text, row = first_text(dbuf)
check('drawer: a thread appears in a window that is not the code window', text == '» t1 (waiting) you: five?' and row == 4, text)
vim.cmd('silent! only')
vim.cmd('vsplit ' .. vim.fn.fnameescape(d))
vim.cmd('split')
check('drawer: ... also in a split of that buffer, drawn once', count_threads(dbuf) == 1)
send('patch', { thread = 't1', answer = 'it is five' })
local vt = vtexts(dbuf)
check('drawer: after a patch answer', #vt == 2 and vt[1].text == '» t1 you: five?' and vt[2].text == '  ↳ it is five', vim.inspect(vt))
check('drawer: ... and the thread says answered', th('t1').state == 'answered')
-- Position follows an edit above the thread, after a save.
vim.api.nvim_set_current_buf(dbuf)
vim.api.nvim_buf_set_lines(dbuf, 0, 0, false, { 'new1', 'new2' })
local before = vtexts(dbuf)
vim.cmd('write')
vim.wait(1000, function()
  local v = vtexts(dbuf)
  return v[1] and v[1].row == 6
end, 20)
vt = vtexts(dbuf)
check('drawer: a modified buffer keeps its marks until it is saved', before[1] and before[1].row == 6, vim.inspect(before))
check('drawer: after a save above the thread its position follows', th('t1').from == 7 and vt[1] and vt[1].row == 6 and #vt == 2, vim.inspect(vt))
vim.fn.writefile(lines(10, 'd'), d)
vim.cmd('edit!')
-- No double drawing in the code window.
vim.cmd('silent! only')
w.step(0)
vim.cmd('vsplit')
at(7)
w.ask('seven in a')
w.thread()
press('q')
check('drawer: the code window\'s thread is drawn once', count_threads(vim.fn.bufnr(a)) == 1, vim.inspect(vtexts(vim.fn.bufnr(a))))
check('drawer: ... by the full draw, none by the drawer', #vim.tbl_filter(function(v) return v.ns == ns_threads end, vtexts(vim.fn.bufnr(a))) == 0)
check('drawer: ... and the thread on d is still there', count_threads(dbuf) == 1)
-- Leaving the step to another file hands the thread to the drawer.
w.step(1)
check('drawer: a step moved away: its threads are drawn by the drawer, once', count_threads(vim.fn.bufnr(a)) == 1
  and #vim.tbl_filter(function(v) return v.ns == ns_threads end, vtexts(vim.fn.bufnr(a))) == 1, vim.inspect(vtexts(vim.fn.bufnr(a))))
w.close()
check('drawer: close removes every mark', marks_everywhere() == 0)

-- ]n, the float, decide, explain, thread-delete in a buffer that is not the code window -------------------------------
reset()
vim.cmd('edit ' .. vim.fn.fnameescape(c))
at(3)
w.change('first')
at(7)
w.change('second')
at(1)
w.note(1)
local stops = { vim.api.nvim_win_get_cursor(0)[1] }
w.note(1)
table.insert(stops, vim.api.nvim_win_get_cursor(0)[1])
reset_log()
w.note(1)
check(']n: walks the threads of the file in the current window', vim.deep_equal(stops, { 3, 7 }) and find('no later thread or finding') ~= nil, vim.inspect(stops))
w.note(-1)
check('[n: and back', vim.api.nvim_win_get_cursor(0)[1] == 3)
check(']n: no window was made', #vim.api.nvim_list_wins() == 1)
w.thread()
check('thread: the float opens from a plain buffer', thread.win() ~= nil and vim.api.nvim_win_get_buf(thread.win()) ~= vim.fn.bufnr(c)
  and vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(thread.win()), 0, 1, false)[1]:match('^t1 · change · c%.txt:3'))
press('q')
w.send()
send('patch', { thread = 't1', answer = 'rename x to y', proposal = true })
check('patch: a proposal in Other files', th('t1').state == 'proposed')
sent = {}
w.decide('accept')
check('decide: marks a proposal in a plain buffer, nothing is sent', th('t1').state == 'proposed' and th('t1').decision == 'accept' and #sent == 0)
w.send()
check('decide: send delivers it, and the message names Other files', th('t1').state == 'accepted' and #sent == 1
  and sent[1].text:match('Decision on your proposal in thread t1') and sent[1].text:match('Other files'), sent[1] and sent[1].text)
sent = {}
w.explain('simpler')
check('explain: on the thread there', #sent == 1 and sent[1].text:match('explain this simpler') and sent[1].text:match('thread t1')
  and sent[1].text:match('Other files: c%.txt'), sent[1] and sent[1].text)
w.thread_delete()
check('thread-delete: removes the thread under the cursor', th('t1') == nil and th('t2') ~= nil and #extra().steps == 1)
at(7)
w.thread_delete()
check('thread-delete: the last thread of an entry removes the entry and the tour', #st.tours == 0 and extra() == nil
  and saved() == nil and marks_everywhere() == 0)

-- Ids, patches by id -------------------------------------------------------------------------------------------------
reset()
assert(send('load', { group = 'X', steps = { { file = x, title = 'x' } } }) == 'ok')
load_a()
vim.cmd('split ' .. vim.fn.fnameescape(a))
at(2)
w.change('in a')
vim.cmd('edit ' .. vim.fn.fnameescape(x))
at(2)
w.change('in x')
vim.cmd('edit ' .. vim.fn.fnameescape(d))
at(2)
w.change('in d')
check('ids: unique across the tours of a repository', th('t1') and th('t2') and th('t3')
  and select(2, th('t1')).group == 'A' and select(2, th('t2')).group == 'X' and select(2, th('t3')).extra, vim.inspect(vim.tbl_map(function(t_) return t_.next_thread end, st.tours)))
check('patch: a thread of a tour that is not active, by id', send('patch', { thread = 't2', answer = 'x answer' }) == 'ok'
  and #th('t2').messages == 2 and th('t2').state == 'answered')
check('patch: a thread in Other files, by id', send('patch', { thread = 't3', answer = 'maybe', proposal = true }) == 'ok'
  and th('t3').state == 'proposed')
check('patch: ... the others stay', #th('t1').messages == 1)
check('patch: a step number reaches the active tour only', send('patch', { step = 3, title = 'x' }) == 'error: patch 1: there is no step 3'
  and send('patch', { thread = 't2', step = 1, answer = 'z' }) == 'error: patch 1: there is no thread t2 in step 1')
check('patch: a list with a wrong item changes nothing', send('patch', { { thread = 't1', answer = 'one' }, { thread = 't9', answer = 'two' } })
  :match('^error: patch 2: there is no thread t9$') and #th('t1').messages == 1)
check('patch: ... and the title of an entry of the active tour still works', send('patch', { step = 2, title = 'second' }) == 'ok'
  and tours.active().steps[2].title == 'second')
check('patch: the map still shows A active', tours.active().group == 'A')
s = status()
check('status: the thread counts cover the repository', s.step == 1 and s.threads.draft == 1 and s.threads.answered == 1
  and s.threads.proposed == 1, w.status())
check('status: groups list Other files', (function()
  for _, g in ipairs(s.groups) do
    if g.group == 'Other files' and g.extra then
      return true
    end
  end
end)())

-- send and inbox cover all tours ---------------------------------------------------------------------------------------
sent = {}
vim.api.nvim_set_current_buf(vim.fn.bufnr(d))
w.send()
check('send: one message for all tours', #sent == 1 and sent[1].text:match('%(3 items%)') and sent[1].text:match('the commits of this repository'), sent[1] and sent[1].text)
check('send: ... items name their group, or Other files', sent[1].text:match('Change request t1 at a%.txt:2, step 1, commit "A"')
  and sent[1].text:match('Change request t3 at d%.txt:2, Other files'), sent[1].text)
check('send: ... after the send they are waiting', th('t1').state == 'waiting' and th('t3').state == 'waiting')
reset_log()
vim.cmd('edit ' .. vim.fn.fnameescape(x))
at(5)
w.change('x again')
vim.cmd('edit ' .. vim.fn.fnameescape(d))
at(5)
w.change('d again')
local inbox = vim.json.decode(w.inbox())
local groups = {}
for _, item in ipairs(inbox.items) do
  groups[item.group] = (groups[item.group] or 0) + 1
end
check('inbox: all tours of the repository, each item with its group', #inbox.items == 2 and groups['X'] == 1 and groups['Other files'] == 1
  and inbox.group == 'A', vim.inspect(inbox))
check('inbox: ... the file is there', inbox.items[1].file == x or inbox.items[2].file == x)
check('inbox: ... once delivered, empty', #vim.json.decode(w.inbox()).items == 0)

-- The counter is kept in the file ----------------------------------------------------------------------------------------
reset()
assert(send('load', { group = 'X', steps = { { file = x, title = 'x' } } }) == 'ok')
load_a()
vim.cmd('split ' .. vim.fn.fnameescape(a))
at(2)
w.ask('t1 in a')
vim.cmd('edit ' .. vim.fn.fnameescape(d))
at(2)
w.ask('t2 in d')
at(4)
w.ask('t3 in d')
at(4)
w.thread_delete()
at(2)
w.thread_delete()
check('counter: the highest ids are deleted and the tour is gone', th('t3') == nil and extra() == nil and th('t1'))
check('counter: ... the file keeps the next number', saved().next_thread == 4, vim.inspect(saved().next_thread))
st.tours, st.active = {}, 0 -- a restart: only the config is kept
st.counters, st.restored, st.dir_roots = {}, {}, {}
vim.api.nvim_exec_autocmds('BufWinEnter', { buffer = vim.fn.bufnr(d) })
check('restart: the tours came back by themselves', #st.tours == 2 and th('t1') ~= nil)
at(6)
w.ask('after the restart')
check('counter: ids go on above the highest ever used', th('t4') ~= nil and th('t3') == nil, vim.inspect(vim.tbl_map(function(t_) return t_.next_thread end, st.tours)))

-- Automatic restore ------------------------------------------------------------------------------------------------------
reset()
load_a()
vim.cmd('split ' .. vim.fn.fnameescape(d))
at(3)
w.ask('in d')
vim.cmd('edit ' .. vim.fn.fnameescape(b))
at(4)
w.ask('in b')
vim.cmd('silent! only')
vim.cmd('enew')
w.close()
-- close deleted Other files and marked the root; a restart:
check('close: Other files is gone from the file, the tours of the change stay', (function()
  local data = saved()
  return data and #data.tours == 1 and data.tours[1].group == 'A' and data.tours[1].extra == nil
end)(), vim.inspect(saved()))
check('close: the screen is clean and nothing is loaded', #st.tours == 0 and marks_everywhere() == 0 and st.panel_win == nil)
check('close: ... the threads of the change are kept in the file', #saved().tours[1].steps[2].threads == 1)
st.restored, st.dir_roots, st.counters = {}, {}, {}
reset_log()
local nbuf = vim.fn.bufnr(b, true)
vim.cmd('buffer ' .. nbuf) -- a real BufWinEnter
check('restore: showing a file brings the saved review back, silently', #st.tours == 1 and st.tours[1].group == 'A' and th('t2') ~= nil
  and st.panel_win == nil and #vim.api.nvim_list_wins() == 1 and vim.api.nvim_get_current_buf() == nbuf and #log == 0, vim.inspect(log))
check('restore: ... the threads are drawn', count_threads(nbuf) == 1, vim.inspect(vtexts(nbuf)))
check('restore: ... Other files did not come back', extra() == nil and th('t1') == nil)
check('restore: ... the review is not shown, but it is there for status', status().step == 1 and status().group == 'A')
-- Once per root.
st.tours, st.active = {}, 0
vim.api.nvim_exec_autocmds('BufWinEnter', { buffer = nbuf })
check('restore: once per repository and session', #st.tours == 0)
-- A repository without a state file costs nothing.
reset()
local clean = H.repo({ ['k.txt'] = lines(3) }, {})
reset_log()
vim.cmd('edit ' .. vim.fn.fnameescape(clean .. '/k.txt'))
check('restore: a repository without a state file: no tours, no error, no notification', #st.tours == 0 and #log == 0 and st.restored[store.root_of(clean .. '/k.txt')] == true, vim.inspect(log))
local calls = 0
local orig = vim.system
vim.system = function(...)
  calls = calls + 1
  return orig(...)
end
vim.cmd('split')
vim.cmd('silent! only')
vim.system = orig
check('restore: the directory is looked up once (no git call on later events)', calls == 0, calls)
-- A file that is not in a repository, and a buffer that is not a file.
reset_log()
vim.cmd('edit ' .. vim.fn.fnameescape(plain .. '/p.txt'))
vim.cmd('enew')
vim.cmd('help')
check('restore: outside a repository and in help: quiet', #st.tours == 0 and #log == 0, vim.inspect(log))
vim.cmd('silent! only')
cd(repo)

-- A corrupt state file is no problem
reset()
local junk = H.repo({ ['j.txt'] = lines(3) }, {})
vim.fn.mkdir(st.config.state_dir, 'p')
vim.fn.writefile({ 'not json' }, store.path(store.root_of(junk .. '/j.txt')))
reset_log()
vim.cmd('edit ' .. vim.fn.fnameescape(junk .. '/j.txt'))
check('restore: a file that cannot be read is left alone, quietly', #st.tours == 0 and #log == 0)

-- close and resume ------------------------------------------------------------------------------------------------------
reset()
load_a()
vim.cmd('split ' .. vim.fn.fnameescape(d))
at(2)
w.ask('in d')
w.close()
check('close: the stored state has no Other files', #saved().tours == 1 and saved().tours[1].group == 'A')
check('resume: shows the review without them', w.resume() == 'ok' and tours.active().group == 'A' and extra() == nil and #st.tours == 1
  and H.panel_text():match('Other files') == nil)
check('resume: ... and the old threads of the review are back', st.history ~= nil and #st.history == 2)
w.close()
-- A repository nothing of which is loaded: close still deletes its Other files.
reset()
load_a()
vim.cmd('edit ' .. vim.fn.fnameescape(d))
at(2)
w.ask('in d, stored only')
st.tours, st.active = {}, 0 -- a restart, and the user did not open a file yet
check('close: the stored state has Other files before', #saved().tours == 2)
w.close()
check('close: a repository that is not loaded loses its Other files too', #saved().tours == 1 and saved().tours[1].group == 'A')
-- Other-only: close deletes the file.
reset()
vim.cmd('edit ' .. vim.fn.fnameescape(d))
w.ask('only d')
check('close: the file exists before', saved() ~= nil)
w.close()
check('close: Other files only: the file is deleted', saved() == nil)
local res = w.resume()
check('resume: ... nothing to resume', res:match('^error: nothing to resume') ~= nil, res)

-- Hand-over to a review or an agent map -------------------------------------------------------------------------------------
reset()
vim.cmd('edit ' .. vim.fn.fnameescape(a))
at(4)
w.ask('in a')
vim.cmd('edit ' .. vim.fn.fnameescape(d))
at(6)
w.ask('in d')
check('hand over: two entries in Other files', #extra().steps == 2)
assert(send('load', { group = 'A', steps = { { file = a, title = 'one' }, { file = b, title = 'two' } } }) == 'ok')
check('hand over: an agent map takes the threads of its files', tours.find('A') and select(2, tours.find('A')).steps[1].threads
  and select(2, tours.find('A')).steps[1].threads[1].id == 't1' and select(2, tours.find('A')).steps[1].threads[1].from == 4, vim.inspect(st.tours[1]))
check('hand over: ... the entry went, the other file stays', extra() and #extra().steps == 1 and extra().steps[1].file == d)
check('hand over: ... A is shown', tours.active().group == 'A' and st.pos == 1)
check('hand over: ... the thread is drawn once', count_threads(vim.fn.bufnr(a)) == 1)
vim.cmd('edit ' .. vim.fn.fnameescape(d))
at(6)
w.thread_delete()
check('hand over: deleting the last thread removes Other files', extra() == nil)
-- An emptied Other files disappears.
reset()
vim.cmd('edit ' .. vim.fn.fnameescape(b))
at(2)
w.ask('in b')
assert(send('load', { group = 'A', steps = { { file = b, title = 'two' } } }) == 'ok')
check('hand over: an Other files tour left empty is removed', extra() == nil and #st.tours == 1 and tours.active().steps[1].threads[1].id == 't1')
check('hand over: ... also in the file', #saved().tours == 1 and saved().tours[1].extra == nil)
-- A review (from git) does the same.
reset()
local rrepo = H.repo({ ['r.txt'] = lines(6), ['s.txt'] = lines(4) }, { ['r.txt'] = lines(7) })
cd(rrepo)
local r, sfile = rrepo .. '/r.txt', rrepo .. '/s.txt'
local rroot = store.root_of(r)
vim.cmd('edit ' .. vim.fn.fnameescape(r))
at(3)
w.ask('before the review')
vim.cmd('edit ' .. vim.fn.fnameescape(sfile))
at(1)
w.ask('in s')
w.review()
local auto = select(2, tours.find_auto(rroot))
check('review: takes the threads of the changed files', auto and auto.steps[1].threads and auto.steps[1].threads[1].id == 't1', vim.inspect(auto))
local _, rextra = tours.find_extra(rroot)
check('review: ... s.txt is unchanged, so it stays in Other files', rextra and #rextra.steps == 1 and rextra.steps[1].file == sfile)
vim.cmd('edit ' .. vim.fn.fnameescape(sfile))
at(1)
w.thread_delete()
check('review: ... and goes with its last thread', select(2, tours.find_extra(rroot)) == nil)
w.close()
cd(repo)

-- map --------------------------------------------------------------------------------------------------------------------------
reset()
load_a()
local cw, cb = st.code_win, vim.api.nvim_win_get_buf(st.code_win)
check('map: the panel is open after a step', st.panel_win and vim.api.nvim_win_is_valid(st.panel_win))
w.map()
check('map: toggles it closed', st.panel_win == nil and st.code_win == cw and vim.api.nvim_win_get_buf(cw) == cb)
w.map()
check('map: ... and open again, the code window untouched', st.panel_win and vim.api.nvim_win_is_valid(st.panel_win)
  and st.code_win == cw and vim.api.nvim_win_get_buf(cw) == cb and st.pos == 1 and H.panel_text():match('^A\n> ') ~= nil, H.panel_text())
vim.cmd('Walkthrough map')
check(':Walkthrough map toggles', st.panel_win == nil)
press('<Plug>(walkthrough-map)')
check('<Plug>(walkthrough-map) toggles', st.panel_win and vim.api.nvim_win_is_valid(st.panel_win))
-- Other files only.
reset()
vim.cmd('edit ' .. vim.fn.fnameescape(c))
at(2)
w.ask('in c')
local cur = vim.api.nvim_get_current_win()
w.map()
check('map: with only Other files the panel lists them', st.panel_win and vim.api.nvim_win_is_valid(st.panel_win)
  and H.panel_text():match('^Other files\n   +c%.txt') ~= nil and H.panel_text():match('1 waiting') ~= nil, H.panel_text())
check('map: ... the current window is the same', vim.api.nvim_get_current_win() == cur
  and vim.api.nvim_win_get_buf(cur) == vim.fn.bufnr(c))
vim.api.nvim_set_current_win(st.panel_win)
vim.api.nvim_win_set_cursor(0, { 2, 0 })
vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'x', false)
check('map: <CR> opens the file in the code window', st.code_win and vim.api.nvim_win_get_buf(st.code_win) == vim.fn.bufnr(c)
  and tours.active() and tours.active().extra, vim.inspect({ st.code_win, st.active }))
w.map()
check('map: and hides it', st.panel_win == nil)
-- An open panel with a map of the repository, then the file is closed on its own
-- Nothing loaded.
reset()
w.map()
check('map: with nothing loaded it says so', st.panel_win == nil and find('nothing to show') ~= nil)

reset()
-- setup() names the state directory after a file is on screen already (`nvim
-- file` with setup in a `-c` command, or a plugin manager that configures
-- late): the file was looked up in the old directory, and is looked at again.
do
  reset()
  local real_dir = st.config.state_dir
  vim.cmd('edit ' .. vim.fn.fnameescape(x))
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  w.ask('kept over a restart?')
  local id = st.tours[1] and st.tours[1].steps[1].threads[1].id
  check('late setup: a thread on a file with no review is saved', id ~= nil and vim.fn.filereadable(store.path(store.root_of(x))) == 1)
  -- A new session: nothing loaded, and the file was shown while the state
  -- directory was still another one.
  st.tours, st.active, st.restored, st.dir_roots = {}, 0, {}, {}
  st.config.state_dir = vim.fn.tempname()
  vim.fn.mkdir(st.config.state_dir, 'p')
  vim.api.nvim_exec_autocmds('BufWinEnter', { buffer = vim.api.nvim_get_current_buf() })
  check('late setup: nothing is found in the other directory', #st.tours == 0 and st.restored[store.root_of(x)] == true)
  reset_log()
  w.setup({ state_dir = real_dir })
  check('late setup: the file on screen is looked at again, and its thread is back', H.wait(function()
    return #st.tours == 1 and th(id) ~= nil
  end) and count_threads(vim.api.nvim_get_current_buf()) == 1 and st.panel_win == nil and #log == 0, vim.inspect(log))
  -- The same directory again: nothing is looked up twice.
  st.tours, st.active = {}, 0
  w.setup({ state_dir = real_dir })
  vim.wait(50)
  check('late setup: setup with the same directory restores nothing again', #st.tours == 0)
  st.restored, st.dir_roots = {}, {}
end

H.finish()
