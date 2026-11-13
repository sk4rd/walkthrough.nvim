-- The commit flow (commit.lua): preconditions, the request to the agent, the
-- check in the background, the dialog, the commit_message patch, committing,
-- what happens after the commit, and cancelling. Every commit is made in a
-- throwaway repository, never in the repository of the plugin.
local H = require('helpers')
local check, send, w = H.check, H.send, H.w
local st = _G.walkthrough_state
local store = require('walkthrough.store')
local commit = require('walkthrough.commit')
local log, find = H.capture_notify()

-- The commits of the tests need an identity and no user configuration.
for k, v in pairs({
  GIT_AUTHOR_NAME = 'test', GIT_AUTHOR_EMAIL = 'test@example.com', GIT_COMMITTER_NAME = 'test',
  GIT_COMMITTER_EMAIL = 'test@example.com', GIT_CONFIG_GLOBAL = '/dev/null', GIT_CONFIG_SYSTEM = '/dev/null',
}) do
  vim.env[k] = v
end
vim.env.WALKTHROUGH_CHECK = nil

local function reset_log()
  for i = #log, 1, -1 do
    log[i] = nil
  end
end
local function press(lhs)
  vim.api.nvim_feedkeys(vim.keycode(lhs), 'x', false)
end

-- The agent: every message handed to the sender.
local sent = {}
st.config.sender = function(msg)
  table.insert(sent, msg)
end
local function requests()
  return vim.tbl_filter(function(m)
    return m.text:match('commit message') ~= nil
  end, sent)
end

local function lines(n, prefix)
  local out = {}
  for i = 1, n do
    out[i] = (prefix or 'l') .. i
  end
  return out
end
local function edited(base, at, text)
  local out = vim.list_slice(base)
  out[at] = text
  return out
end

-- A repository with a.txt, b.txt and c.txt committed and all three changed.
-- Tours A (a.txt) and B (b.txt) are loaded, A on screen, and a.txt is staged.
-- Returns the directory.
local function setup(opts)
  opts = opts or {}
  w.close()
  vim.cmd('silent! %bwipeout!')
  reset_log()
  for i = #sent, 1, -1 do
    sent[i] = nil
  end
  local base = lines(6)
  local repo = H.repo({ ['a.txt'] = base, ['b.txt'] = lines(6, 'b'), ['c.txt'] = lines(6, 'c') }, {
    ['a.txt'] = edited(base, 3, 'A3'), ['b.txt'] = edited(lines(6, 'b'), 3, 'B3'), ['c.txt'] = edited(lines(6, 'c'), 3, 'C3'),
  })
  vim.cmd('cd ' .. vim.fn.fnameescape(repo))
  send('load', { group = 'A', steps = { { file = repo .. '/a.txt', title = 'the a change', diff = opts.diff } } })
  if not opts.single then
    -- The first commit of a map is the current one: B joins without taking over.
    send('load', { group = 'B', steps = { { file = repo .. '/b.txt', title = 'the b change' } } })
  end
  if not opts.nothing_staged then
    H.git_in(repo, 'add', 'a.txt')
  end
  return repo
end

-- The dialog of a repository: its window, buffer and text.
local function dialog()
  for _, d in pairs(st.commit_dialogs) do
    if not d.closed then
      return d
    end
  end
end
local function text(d)
  d = d or dialog()
  return table.concat(vim.api.nvim_buf_get_lines(d.buf, 0, -1, false), '\n')
end
local function open_count()
  local n = 0
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)):match('^walkthrough%-commit://') then
      n = n + 1
    end
  end
  return n
end
-- Put `msg` (a list of lines) where the message goes, like typing it.
local function type_message(d, msg)
  local rows = vim.api.nvim_buf_get_lines(d.buf, 0, -1, false)
  local first = #rows
  for i, l in ipairs(rows) do
    if l:sub(1, 1) == '#' then
      first = i
      break
    end
  end
  vim.api.nvim_buf_set_lines(d.buf, 0, first - 1, false, vim.list_extend(vim.list_slice(msg), { '' }))
end
local function status()
  return vim.json.decode(w.status())
end
local function cached(repo)
  return H.git_in(repo, 'diff', '--cached', '--stat')
end
local function alive(pid)
  return vim.uv.kill(pid, 0) == 0
end

-- A check that runs until the test creates `flag`, then ends with `exit_code`.
local function gated_check(flag, exit_code, extra)
  vim.env.WALKTHROUGH_CHECK = ('%swhile [ ! -e %s ]; do sleep 0.05; done; exit %d'):format(extra or '', flag, exit_code or 0)
end
local function release(flag)
  vim.fn.writefile({ '' }, flag)
end

-- Preconditions --------------------------------------------------------------------------
w.close()
reset_log()
w.commit()
check('no tour: says so', find('commit needs a review') ~= nil, vim.inspect(log))
check('no tour: no dialog, nothing sent', dialog() == nil and #sent == 0)

local repo = setup()
-- An `Other files` tour on screen is not a change.
vim.cmd('edit ' .. vim.fn.fnameescape(repo .. '/c.txt'))
reset_log()
w.ask('what is C3?', { 3, 3 })
local extra
for i, t in ipairs(st.tours) do
  if t.extra then
    extra = i
  end
end
check('the thread on c.txt made an `Other files` tour', extra ~= nil)
st.active = extra
reset_log()
w.commit()
check('Other files on screen: refused with a notification', find('commit needs a review') ~= nil, vim.inspect(log))
check('Other files on screen: no dialog', dialog() == nil and #requests() == 0)

repo = setup({ nothing_staged = true })
reset_log()
w.commit()
check('nothing staged: says so', find('nothing is staged') ~= nil, vim.inspect(log))
check('nothing staged: no dialog, no request, no check', dialog() == nil and #requests() == 0)

repo = setup()
vim.env.WALKTHROUGH_CHECK = 'true'
w.commit()
local d = dialog()
check('a dialog opens when a tour of a change has staged lines', d ~= nil and open_count() == 1)
reset_log()
w.commit()
check('a second dialog for the repository: refused', find('already') ~= nil and open_count() == 1 and #requests() == 0,
  vim.inspect(log))

-- The window ------------------------------------------------------------------------------
local cfg = vim.api.nvim_win_get_config(d.win)
check('the dialog is a centered float with an editable scratch buffer', cfg.relative == 'editor'
  and vim.bo[d.buf].modifiable and vim.bo[d.buf].buftype == 'acwrite' and vim.api.nvim_get_current_win() == d.win)
local title = table.concat(vim.tbl_map(function(c) return c[1] end, cfg.title), '')
check('the title names the keys', title:match('<CR>') and title:match('q') and title:match('cc') and title:match('<C%-g>'), title)
check('the message area is empty at first, then the # lines', vim.api.nvim_buf_get_lines(d.buf, 0, 1, false)[1] == ''
  and vim.api.nvim_buf_get_lines(d.buf, 1, 2, false)[1]:sub(1, 1) == '#', text(d))
check('the # lines name the group and the staged file', text(d):match('# Commit: A') and text(d):match('M  a%.txt'), text(d))
check('a staged file of the tour gets no warning', not text(d):match('not part of this commit'), text(d))
check('the agent is not asked by opening the dialog', #requests() == 0 and text(d):match('# agent: not asked; <C%-g>') ~= nil
  and #vim.json.decode(w.inbox()).items == 0, text(d))
check('status: the dialog, the check and no message', (function()
  local s = status().commit
  return s and s.group == 'A' and s.message == false and (s.check == 'running' or s.check == 'passed')
end)(), w.status())
press('q')
check('q closes the dialog', dialog() == nil and open_count() == 0 and status().commit == nil)

-- The request to the agent -----------------------------------------------------------------
repo = setup()
for i = #sent, 1, -1 do
  sent[i] = nil
end
w.commit()
d = dialog()
check('opening the dialog sends nothing', #requests() == 0)
press('<C-g>')
local req = requests()[1]
check('<C-g> sends one request', #requests() == 1 and req ~= nil)
check('<C-g>: the dialog says the agent is awaited', text(d):match('# agent: waiting for a proposed message') ~= nil, text(d))
reset_log()
press('<C-g>')
check('<C-g> again while waiting: no second request', #requests() == 1 and find('asked already') ~= nil, vim.inspect(log))
local rq = req and req.text or ''
check('the request names the group', rq:match('commit "A"') ~= nil, rq)
check('the request holds the --stat of the staged files', rq:match('a%.txt%s+|%s+2') ~= nil and not rq:match('b%.txt'), rq)
check('the request holds the rules, word for word', rq:find(
  'Conventional Commits. One line. Add further lines only when the change is really complex. Never add a Co-authored-by line.',
  1, true) ~= nil, rq)
check('the request names the patch form', rq:find('{ "commit_message": "<message>", "group": "A" }', 1, true) ~= nil, rq)
check('the request tells the agent not to commit', rq:match('do not stage or commit') ~= nil, rq)
check('the inbox lists the pending request, with the stat', (function()
  local items = vim.json.decode(w.inbox()).items
  local item = vim.tbl_filter(function(i) return i.kind == 'commit' end, items)[1]
  return item and item.group == 'A' and item.stat:match('a%.txt') ~= nil
end)(), w.inbox())
check('the inbox keeps listing it (it is not delivered by being read)', #vim.tbl_filter(function(i)
  return i.kind == 'commit'
end, vim.json.decode(w.inbox()).items) == 1)
press('q')
check('the inbox does not list it once the dialog is closed', #vim.json.decode(w.inbox()).items == 0, w.inbox())

-- Sending fails: the dialog says so and the user can type.
repo = setup()
local before = st.config.sender
st.config.sender = function()
  error('no agent terminal found', 0)
end
reset_log()
w.commit()
d = dialog()
check('a sender that raises does not raise out of the ask', pcall(w.commit_ask))
check('sending fails: the dialog says so', d ~= nil and text(d):match('# agent: could not be asked %(no agent terminal found%)'), d and text(d))
check('sending fails: nothing is pending, so the user can ask again', #vim.json.decode(w.inbox()).items == 0, w.inbox())
type_message(d, { 'fix: typed by the user' })
check('sending fails: the user can still type a message', status().commit.message == true)
press('q')
st.config.sender = before

-- The check -------------------------------------------------------------------------------
-- none defined
repo = setup()
vim.env.WALKTHROUGH_CHECK = nil
w.commit()
d = dialog()
check('check: none defined', H.wait(function() return d.check.state == 'none' and text(d):match('# check: none defined') end), text(d))
check('status: check none', status().commit.check == 'none')
press('q')

-- passed
repo = setup()
vim.env.WALKTHROUGH_CHECK = 'true'
w.commit()
d = dialog()
check('check: passed', H.wait(function() return text(d):match('# check: passed') ~= nil end), text(d))
check('status: check passed', status().commit.check == 'passed')
press('q')

-- failed, with the end of its output
repo = setup()
vim.env.WALKTHROUGH_CHECK = 'echo boom-one; echo boom-two; exit 1'
w.commit()
d = dialog()
check('check: FAILED with its output', H.wait(function() return text(d):match('# check: FAILED') ~= nil end)
  and text(d):match('# check: FAILED\n[^\n]*\n') ~= nil and text(d):match('boom%-one') ~= nil and text(d):match('boom%-two') ~= nil, text(d))
check('check: the output lines are # lines too', (function()
  for _, l in ipairs(vim.api.nvim_buf_get_lines(d.buf, 0, -1, false)) do
    if l:match('boom') and l:sub(1, 1) ~= '#' then
      return false
    end
  end
  return true
end)())
check('check: at most 15 lines of output are kept', #d.check.lines <= 15)
check('status: check failed', status().commit.check == 'failed')
press('q')

-- The output is cut to its last 15 lines.
repo = setup()
vim.env.WALKTHROUGH_CHECK = 'i=1; while [ $i -le 40 ]; do echo "row-$i"; i=$((i+1)); done; exit 1'
w.commit()
d = dialog()
H.wait(function() return d.check.state == 'failed' end)
check('check: only the last 15 lines of a long output', #d.check.lines == 15 and d.check.lines[15]:match('already broken')
  and text(d):match('row%-40') ~= nil and not text(d):match('row%-5\n'), vim.inspect(d.check.lines))
press('q')

-- running, then refreshed in place: what the user typed and the cursor stay
repo = setup()
local flag = vim.fn.tempname()
gated_check(flag, 0)
w.commit()
d = dialog()
check('check: running…', text(d):match('# check: running…') ~= nil and status().commit.check == 'running', text(d))
vim.api.nvim_feedkeys(vim.keycode('ifeat: typed<CR>second line<Esc>'), 'x', false)
vim.api.nvim_win_set_cursor(d.win, { 1, 3 })
local typed = vim.api.nvim_buf_get_lines(d.buf, 0, 2, false)
release(flag)
check('check: refreshed when it finishes', H.wait(function() return text(d):match('# check: passed') ~= nil end), text(d))
check('refresh: the typed text stays', vim.deep_equal(vim.api.nvim_buf_get_lines(d.buf, 0, 2, false), typed)
  and typed[1] == 'feat: typed' and typed[2] == 'second line', text(d))
check('refresh: the cursor stays', vim.deep_equal(vim.api.nvim_win_get_cursor(d.win), { 1, 3 }))
check('refresh: no other check line is left', select(2, text(d):gsub('# check:', '')) == 1, text(d))
press('q')

-- closing the dialog stops a running check, and everything it started
repo = setup()
flag = vim.fn.tempname()
local pidfile = vim.fn.tempname()
gated_check(flag, 0, ('echo $$ > %s; '):format(pidfile))
w.commit()
d = dialog()
local script_pid = d.check.obj.pid
check('kill: the check runs', H.wait(function() return vim.fn.filereadable(pidfile) == 1 and vim.fn.readfile(pidfile)[1] ~= nil end)
  and alive(script_pid))
local sh_pid = tonumber(vim.fn.readfile(pidfile)[1])
check('kill: the check started a process of its own', sh_pid ~= nil and alive(sh_pid))
press('q')
check('kill: closing the dialog stops the script and its check', H.wait(function()
  return not alive(script_pid) and not alive(sh_pid)
end), ('script %s sh %s'):format(alive(script_pid), alive(sh_pid)))
release(flag)
vim.env.WALKTHROUGH_CHECK = nil

-- A temporary directory of a stopped check does not stay behind.
do
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, 'p')
  local old_tmpdir = vim.env.TMPDIR
  vim.env.TMPDIR = tmp
  repo = setup()
  flag = vim.fn.tempname()
  pidfile = vim.fn.tempname()
  gated_check(flag, 0, ('echo $$ > %s; '):format(pidfile))
  w.commit()
  d = dialog()
  H.wait(function() return vim.fn.filereadable(pidfile) == 1 end)
  local before_close = #vim.fn.glob(tmp .. '/walkthrough-check.*', false, true)
  press('q')
  local gone = H.wait(function() return #vim.fn.glob(tmp .. '/walkthrough-check.*', false, true) == 0 end)
  check('kill: the checkout of a stopped check is removed', before_close == 1 and gone, before_close)
  release(flag)
  vim.env.TMPDIR = old_tmpdir
  vim.env.WALKTHROUGH_CHECK = nil
end

-- A staged file the tour does not list ----------------------------------------------------
repo = setup()
H.git_in(repo, 'add', 'c.txt')
w.commit()
d = dialog()
check('warning: a staged file outside the tour', text(d):match('# staged but not part of this commit in the map: c%.txt') ~= nil, text(d))
check('warning: only that one', select(2, text(d):gsub('not part of this commit', '')) == 1, text(d))
press('q')

-- The commit_message patch ----------------------------------------------------------------
repo = setup()
vim.env.WALKTHROUGH_CHECK = 'true'
w.commit()
d = dialog()
check('patch: accepted', send('patch', { commit_message = 'feat(a): change a' }) == 'ok')
check('patch: fills the empty message area', vim.api.nvim_buf_get_lines(d.buf, 0, 1, false)[1] == 'feat(a): change a', text(d))
check('patch: the agent is no longer awaited', text(d):match('# agent: message received') ~= nil and not text(d):match('waiting for'), text(d))
check('status: a message', status().commit.message == true)
check('the inbox does not list the answered request', #vim.tbl_filter(function(i) return i.kind == 'commit' end,
  vim.json.decode(w.inbox()).items) == 0, w.inbox())
check('patch: stored on the tour', st.tours[st.active].commit_message == 'feat(a): change a')
local saved = vim.json.decode(table.concat(vim.fn.readfile(store.path(store.root_of(repo .. '/a.txt'))), '\n'))
local saved_a
for _, t in ipairs(saved.tours) do
  if t.group == 'A' then
    saved_a = t
  end
end
check('patch: saved with the tour', saved_a and saved_a.commit_message == 'feat(a): change a', vim.inspect(saved_a))
-- A second proposal while nothing was typed replaces the first.
send('patch', { commit_message = 'feat(a): better' })
check('patch: another proposal replaces an untouched one', vim.api.nvim_buf_get_lines(d.buf, 0, 1, false)[1] == 'feat(a): better', text(d))

-- Typed text is not overwritten: <C-r> takes the proposal.
type_message(d, { 'my own words' })
check('patch: typed text before the proposal', status().commit.message == true)
send('patch', { commit_message = 'feat(a): agent words' })
check('patch: typed text is not overwritten', vim.api.nvim_buf_get_lines(d.buf, 0, 1, false)[1] == 'my own words', text(d))
check('patch: a # line says a proposal arrived', text(d):match('# agent: a proposal arrived; <C%-r> in normal mode replaces the text with it') ~= nil, text(d))
press('<C-r>')
check('<C-r> replaces the text with the proposal', vim.api.nvim_buf_get_lines(d.buf, 0, 1, false)[1] == 'feat(a): agent words'
  and not text(d):match('my own words') and not text(d):match('a proposal arrived'), text(d))
press('q')

-- Before the dialog opens, for a tour that is not on screen, unknown groups, lists -------------------
repo = setup()
check('patch: a message for a tour that is not on screen (group)', send('patch', { commit_message = 'fix(b): b', group = 'B' }) == 'ok')
local function tour_of(group)
  for _, t in ipairs(st.tours) do
    if t.group == group then
      return t
    end
  end
end
check('patch: stored on the named tour only', tour_of('B').commit_message == 'fix(b): b' and tour_of('A').commit_message == nil)
check('patch: unknown group rejected', send('patch', { commit_message = 'x', group = 'Nope' }):match('^error: patch 1: no commit "Nope" is loaded') ~= nil,
  send('patch', { commit_message = 'x', group = 'Nope' }))
check('patch: nothing was stored by the rejected one', tour_of('A').commit_message == nil and tour_of('B').commit_message == 'fix(b): b')
check('patch: an empty message is rejected', send('patch', { commit_message = '  ' }):match('is empty') ~= nil)
check('patch: a wrong type is rejected', send('patch', { commit_message = 5 }):match('must be a string or a list of strings') ~= nil)
check('patch: unknown fields are rejected', send('patch', { commit_message = 'x', title = 'y' }):match('unknown commit message field "title"') ~= nil)
check('patch: a list of strings is the lines of the message', send('patch', { commit_message = { 'feat(a): list', '', 'the body' } }) == 'ok'
  and tour_of('A').commit_message == 'feat(a): list\n\nthe body')
-- transactional
tour_of('A').commit_message = nil
local res = send('patch', { { commit_message = 'feat(a): lost' }, { thread = 't99', answer = 'no such thread' } })
check('patch: a list with a failing item changes nothing', res:match('^error: patch 2') ~= nil and tour_of('A').commit_message == nil, res)
res = send('patch', { { commit_message = 'feat(a): lost' }, { commit_message = 'x', group = 'Nope' } })
check('patch: a list with an unknown group changes nothing', res:match('^error: patch 2: no commit "Nope" is loaded') ~= nil
  and tour_of('A').commit_message == nil, res)
check('patch: works together with other patches', send('patch', { { commit_message = 'feat(a): both' },
  { step = 1, title = 'renamed' } }) == 'ok' and tour_of('A').commit_message == 'feat(a): both'
  and tour_of('A').steps[1].title == 'renamed')
tour_of('A').commit_message = nil
-- The message of B is not A's: the dialog of A is empty; a message that came before is shown
w.commit()
d = dialog()
check('a message for another tour does not show in this dialog', vim.api.nvim_buf_get_lines(d.buf, 0, 1, false)[1] == '', text(d))
press('q')
send('patch', { commit_message = 'feat(a): before the dialog' })
local asked_before = #requests()
w.commit()
d = dialog()
check('a message that arrived before the dialog opens is shown', vim.api.nvim_buf_get_lines(d.buf, 0, 1, false)[1] == 'feat(a): before the dialog'
  and status().commit.message == true, text(d))
check('... and the agent is not asked again', #requests() == asked_before and text(d):match('# agent: message received') ~= nil, text(d))
press('q')
-- No tour is loaded: nothing to store the message on.
w.close()
check('patch: no map loaded: rejected', send('patch', { commit_message = 'x' }):match('^error: patch 1: no commit of the map is active') ~= nil
  and send('patch', { commit_message = 'x', group = 'A' }):match('no commit "A" is loaded') ~= nil)

-- Committing ------------------------------------------------------------------------------
local function commit_with(msg, opts)
  opts = opts or {}
  local r = setup()
  vim.env.WALKTHROUGH_CHECK = opts.check or 'true'
  w.commit()
  local dd = dialog()
  if opts.wait ~= false then
    H.wait(function() return dd.check.state ~= 'running' end)
  end
  if msg then
    type_message(dd, msg)
  end
  return r, dd
end
local function message_of(r)
  return H.git_in(r, 'log', '-1', '--format=%B')
end

-- <CR>: subject and body, # lines and Co-authored-by lines out
repo, d = commit_with({ 'feat(a): change a', '', 'The body.', 'co-AUTHORED-by: A Bot <bot@example.com>', '# a comment of mine', 'Last line.' })
reset_log()
press('<CR>')
check('<CR>: commits', H.wait(function() return dialog() == nil end) and H.git_in(repo, 'rev-list', '--count', 'HEAD') == '2')
check('<CR>: exactly the message, without # and Co-authored-by lines', message_of(repo) == 'feat(a): change a\n\nThe body.\nLast line.', message_of(repo))
check('<CR>: says that a Co-authored-by line was removed', find('removed 1 Co%-authored%-by line') ~= nil, vim.inspect(log))
check('<CR>: notifies with the short hash and the subject', find('committed ' .. H.git_in(repo, 'rev-parse', '--short', 'HEAD') .. ' feat%(a%): change a') ~= nil, vim.inspect(log))
check('<CR>: what was staged is committed, the rest is not', H.git_in(repo, 'show', '--stat', '--format=', 'HEAD'):match('a%.txt') ~= nil
  and H.git_in(repo, 'status', '--porcelain'):match('M b%.txt') ~= nil)
check('<CR>: the dialog window is gone', open_count() == 0)

-- :w
repo, d = commit_with({ 'chore: via write' })
vim.cmd('write')
check(':w commits', H.wait(function() return dialog() == nil end) and message_of(repo) == 'chore: via write', message_of(repo))

-- cc commits too, as in fugitive and Neogit; it is a mapping of this buffer only.
repo, d = commit_with({ 'chore: via cc' })
check('cc is mapped in the dialog, in Normal mode only', vim.fn.maparg('cc', 'n') ~= '' and vim.fn.maparg('cc', 'i') == '')
vim.api.nvim_feedkeys('cc', 'x', false)
check('cc commits', H.wait(function() return dialog() == nil end) and message_of(repo) == 'chore: via cc', message_of(repo))
check('cc: outside the dialog it is not mapped', vim.fn.maparg('cc', 'n') == '')

-- empty message refused
repo, d = commit_with(nil)
reset_log()
press('<CR>')
check('an empty message is refused', find('commit message is empty') ~= nil and dialog() ~= nil and H.git_in(repo, 'rev-list', '--count', 'HEAD') == '1', vim.inspect(log))
type_message(d, { '# nothing but a comment', '', '   ' })
press('<CR>')
check('a message of # lines and blanks is empty too', H.git_in(repo, 'rev-list', '--count', 'HEAD') == '1' and dialog() ~= nil)
type_message(d, { 'Co-authored-by: Only <only@example.com>' })
reset_log()
press('<CR>')
check('a message that is only a Co-authored-by line is empty after removal', find('commit message is empty') ~= nil
  and H.git_in(repo, 'rev-list', '--count', 'HEAD') == '1')
press('q')

-- The check decides whether to ask
local asked, answer
local confirm_orig = vim.fn.confirm
vim.fn.confirm = function(msg, choices, default)
  table.insert(asked, { msg = msg, choices = choices, default = default })
  return answer
end
asked, answer = {}, 2
repo, d = commit_with({ 'feat: failing check' }, { check = 'exit 1' })
press('<CR>')
check('failed check: asks, default no', #asked == 1 and asked[1].msg:match('^The check failed%.') and asked[1].msg:match('Commit anyway%?$')
  and asked[1].default == 2, vim.inspect(asked))
check('failed check, answer no: nothing committed, dialog open', dialog() ~= nil and H.git_in(repo, 'rev-list', '--count', 'HEAD') == '1')
asked, answer = {}, 1
press('<CR>')
check('failed check, answer yes: committed', H.wait(function() return dialog() == nil end) and #asked == 1
  and message_of(repo) == 'feat: failing check', message_of(repo))

asked, answer = {}, 2
flag = vim.fn.tempname()
gated_check(flag, 0)
repo, d = commit_with({ 'feat: running check' }, { check = vim.env.WALKTHROUGH_CHECK, wait = false })
press('<CR>')
check('running check: asks, default no', #asked == 1 and asked[1].msg:match('^The check has not finished%.') and asked[1].default == 2
  and dialog() ~= nil and H.git_in(repo, 'rev-list', '--count', 'HEAD') == '1', vim.inspect(asked))
asked, answer = {}, 1
press('<CR>')
check('running check, answer yes: committed', H.wait(function() return dialog() == nil end)
  and message_of(repo) == 'feat: running check')
release(flag)
check('a passed check does not ask', (function()
  asked, answer = {}, 2
  local r, dd = commit_with({ 'feat: passing check' })
  press('<CR>')
  return H.wait(function() return dialog() == nil end) and #asked == 0 and message_of(r) == 'feat: passing check'
end)())
vim.fn.confirm = confirm_orig

-- a failing hook: git's error is shown and the dialog stays open
repo, d = commit_with({ 'feat: hook says no' })
local hook = repo .. '/.git/hooks/pre-commit'
vim.fn.writefile({ '#!/bin/sh', 'echo "hook says no" >&2', 'exit 1' }, hook)
vim.uv.fs_chmod(hook, tonumber('755', 8))
reset_log()
press('<CR>')
check('hook fails: git\'s error is shown', H.wait(function() return find('commit failed: hook says no') ~= nil end), vim.inspect(log))
check('hook fails: the dialog stays open, with the error in it', dialog() ~= nil and H.wait(function()
  return text(d):match('# commit FAILED: hook says no') ~= nil
end), text(d))
check('hook fails: nothing was committed, the message is kept', H.git_in(repo, 'rev-list', '--count', 'HEAD') == '1'
  and vim.api.nvim_buf_get_lines(d.buf, 0, 1, false)[1] == 'feat: hook says no' and cached(repo) ~= '')
-- The hook is not skipped, and it can be fixed: the same dialog commits.
vim.fn.writefile({ '#!/bin/sh', 'exit 0' }, hook)
press('<CR>')
check('hook fixed: the same dialog commits', H.wait(function() return dialog() == nil end) and message_of(repo) == 'feat: hook says no')

-- After the commit -------------------------------------------------------------------------
repo = setup()
vim.env.WALKTHROUGH_CHECK = 'true'
-- a thread in the committed tour and one in the other
vim.cmd('edit ' .. vim.fn.fnameescape(repo .. '/a.txt'))
w.ask('why A3?', { 3, 3 })
vim.cmd('edit ' .. vim.fn.fnameescape(repo .. '/b.txt'))
w.ask('why B3?', { 3, 3 })
vim.cmd('edit ' .. vim.fn.fnameescape(repo .. '/a.txt'))
local function threads_in(group)
  local n = 0
  for _, t in ipairs(st.tours) do
    if t.group == group then
      for _, s in ipairs(t.steps) do
        n = n + #(s.threads or {})
      end
    end
  end
  return n
end
check('before: both tours hold a thread', threads_in('A') == 1 and threads_in('B') == 1)
local root = store.root_of(repo .. '/a.txt')
check('before: the map lists a.txt and b.txt', H.panel_text():match('a%.txt') and H.panel_text():match('b%.txt'), H.panel_text())
w.commit()
d = dialog()
H.wait(function() return d.check.state ~= 'running' end)
type_message(d, { 'feat(a): change a' })
press('<CR>')
check('after: committed', H.wait(function() return dialog() == nil end))
check('after: the tour is gone from memory, with its threads', tour_of('A') == nil and threads_in('A') == 0)
local on_disk = table.concat(vim.fn.readfile(store.path(root)), '\n')
check('after: and from the stored state', not on_disk:find('"A"', 1, true) and not on_disk:find('why A3', 1, true)
  and on_disk:find('why B3', 1, true) ~= nil, on_disk)
check('after: the other tour keeps its thread', threads_in('B') == 1)
check('after: the next tour is the one on screen', st.tours[st.active] and st.tours[st.active].group == 'B'
  and status().group == 'B', w.status())
check('after: ... shown in the code window', vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(st.code_win)) == repo .. '/b.txt'
  or vim.uv.fs_realpath(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(st.code_win))) == vim.uv.fs_realpath(repo .. '/b.txt'))
check('after: the map no longer lists the committed tour', H.panel_text():match('b%.txt') and not H.panel_text():match('a%.txt'), H.panel_text())
check('after: status has no dialog', status().commit == nil)

-- the last tour: panel closes, `Other files` stays
local b_win_file = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(st.code_win))
repo = setup({ single = true })
vim.env.WALKTHROUGH_CHECK = 'true'
vim.cmd('edit ' .. vim.fn.fnameescape(repo .. '/c.txt'))
w.ask('what is C3?', { 3, 3 })
check('last: `Other files` holds the thread', (function()
  for _, t in ipairs(st.tours) do
    if t.extra then
      return #t.steps[1].threads == 1
    end
  end
end)())
for i, t in ipairs(st.tours) do
  if t.group == 'A' then
    st.active = i
  end
end
w.step(0)
check('last: the panel is open', st.panel_win and vim.api.nvim_win_is_valid(st.panel_win))
w.commit()
d = dialog()
H.wait(function() return d.check.state ~= 'running' end)
type_message(d, { 'feat(a): last one' })
press('<CR>')
check('last: committed', H.wait(function() return dialog() == nil end))
check('last: the panel is closed', st.panel_win == nil or not vim.api.nvim_win_is_valid(st.panel_win))
check('last: no tour of a change is loaded, `Other files` is', tour_of('A') == nil and (function()
  local extras = 0
  for _, t in ipairs(st.tours) do
    extras = extras + (t.extra and 1 or 0)
    if not t.extra then
      return false
    end
  end
  return extras == 1
end)())
check('last: the code window shows the file it showed', vim.uv.fs_realpath(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(st.code_win)))
  ~= nil and vim.bo[vim.api.nvim_win_get_buf(st.code_win)].buftype == '')
check('last: status lists `Other files`', (function()
  local s = status()
  return s.step == 0 and s.groups and #s.groups == 1 and s.groups[1].group == 'Other files'
end)(), w.status())
check('last: the thread of `Other files` is stored', table.concat(vim.fn.readfile(store.path(store.root_of(repo .. '/a.txt'))), '\n'):find('what is C3', 1, true) ~= nil)

-- the compact view of the committed tour goes with it
w.close()
st.config.view = 'compact'
repo = setup({ single = true, diff = true })
vim.env.WALKTHROUGH_CHECK = 'true'
w.step(0)
local compact_buf = vim.api.nvim_win_get_buf(st.code_win)
check('compact: the tour is shown in the compact view', st.compact[compact_buf] ~= nil)
w.commit()
d = dialog()
H.wait(function() return d.check.state ~= 'running' end)
type_message(d, { 'feat(a): from compact' })
press('<CR>')
check('compact: committed', H.wait(function() return dialog() == nil end))
check('compact: the code window shows the file, the compact buffer is gone', vim.bo[vim.api.nvim_win_get_buf(st.code_win)].buftype == ''
  and not vim.api.nvim_buf_is_valid(compact_buf), vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(st.code_win)))
st.config.view = 'file'

-- Cancel ---------------------------------------------------------------------------------
repo = setup()
vim.env.WALKTHROUGH_CHECK = 'true'
local staged_before = H.git_in(repo, 'diff', '--cached')
w.commit()
d = dialog()
send('patch', { commit_message = 'feat(a): kept for later' })
type_message(d, { 'edited and then cancelled' })
press('<Esc>')
check('cancel: <Esc> closes the dialog', dialog() == nil and open_count() == 0)
check('cancel: what is staged stays staged', H.git_in(repo, 'diff', '--cached') == staged_before and H.git_in(repo, 'rev-list', '--count', 'HEAD') == '1')
check('cancel: the stored message is kept', tour_of('A').commit_message == 'feat(a): kept for later')
w.commit()
d = dialog()
check('cancel: and shown the next time', vim.api.nvim_buf_get_lines(d.buf, 0, 1, false)[1] == 'feat(a): kept for later', text(d))
press('q')
check('cancel: q closes it as well', dialog() == nil)
check('cancel: back in the window the user came from', vim.api.nvim_get_current_win() == st.code_win or vim.bo.buftype == '')

-- :q on a dialog with typed text cancels it, and stops the check
repo = setup()
flag = vim.fn.tempname()
gated_check(flag, 0)
w.commit()
d = dialog()
vim.api.nvim_feedkeys(vim.keycode('itext<Esc>'), 'x', false)
vim.cmd('quit')
check(':q closes the dialog although text was typed', H.wait(function() return dialog() == nil end) and open_count() == 0)
check(':q stops the check', d.check.state == 'killed')
release(flag)

-- commit persists in the stored state across a resume ------------------------------------------
repo = setup()
send('patch', { commit_message = 'feat(a): after a restart' })
local saved_tours = store.read(store.root_of(repo .. '/a.txt'))
local revived
for _, t in ipairs(saved_tours and saved_tours.tours or {}) do
  if t.group == 'A' then
    revived = t
  end
end
check('resume: the stored message comes back with the tour', revived and revived.commit_message == 'feat(a): after a restart', vim.inspect(revived))

-- A load of the same group keeps the message ------------------------------------------------------
send('load', { group = 'A', steps = { { file = repo .. '/a.txt', title = 'sent again' } } })
check('load: a map sent again keeps the proposed message', tour_of('A').commit_message == 'feat(a): after a restart')

-- A review without an agent is the unnamed tour: it commits too ----------------------------------
w.close()
vim.cmd('silent! %bwipeout!')
repo = H.repo({ ['a.txt'] = lines(6) }, { ['a.txt'] = edited(lines(6), 3, 'A3') })
vim.cmd('cd ' .. vim.fn.fnameescape(repo))
vim.env.WALKTHROUGH_CHECK = 'true'
w.review()
H.git_in(repo, 'add', 'a.txt')
for i = #sent, 1, -1 do
  sent[i] = nil
end
w.commit()
d = dialog()
check('review: a dialog opens for the unnamed tour', d ~= nil and d.group == nil and text(d):match('# Commit: the staged changes') ~= nil, d and text(d))
w.commit_ask()
check('review: the request names no group and the patch has none', requests()[1] ~= nil and not requests()[1].text:match('commit "')
  and requests()[1].text:find('{ "commit_message": "<message>" }', 1, true) ~= nil, requests()[1] and requests()[1].text)
check('review: the inbox item has no group', (function()
  local item = vim.tbl_filter(function(i) return i.kind == 'commit' end, vim.json.decode(w.inbox()).items)[1]
  return item ~= nil and item.group == nil
end)())
check('review: a message without a group goes to the unnamed tour', send('patch', { commit_message = 'fix: unnamed' }) == 'ok'
  and vim.api.nvim_buf_get_lines(d.buf, 0, 1, false)[1] == 'fix: unnamed')
H.wait(function() return d.check.state ~= 'running' end)
press('<CR>')
check('review: committed, and the tour is gone', H.wait(function() return dialog() == nil end) and #st.tours == 0
  and message_of(repo) == 'fix: unnamed', message_of(repo))


-- Staging the next commit's lines of a file shared by two commits ---------------------------------------
-- gitsigns drops its hunks of a file when HEAD or the index change under it and rebuilds them only
-- while a window shows the file. The compact view shows no file, so the staging must wait until
-- gitsigns agrees with git (stage.lua, `synced`). Needs gitsigns.nvim.
local gs = H.gitsigns()
if not gs then
  H.skip('staging after a commit (gitsigns.nvim not on the packpath; set WALKTHROUGH_GITSIGNS)')
else
  local confirm_saved = vim.fn.confirm
  vim.fn.confirm = function()
    return 1
  end
  vim.env.WALKTHROUGH_CHECK = 'true'

  -- One file, two commits: A2 belongs to A, B5 to B. Returns the repository.
  local function shared_map(view)
    w.close()
    vim.cmd('silent! %bwipeout!')
    reset_log()
    st.config.view = view
    local r = H.repo({ ['f.txt'] = lines(6) }, { ['f.txt'] = { 'l1', 'A2', 'l3', 'l4', 'B5', 'l6' } })
    vim.cmd('cd ' .. vim.fn.fnameescape(r))
    local f = r .. '/f.txt'
    send('load', { group = 'A', steps = { { file = f, hunks = { { from = 2, to = 2 }, { from = 5, to = 5, group = 'B' } } } } })
    send('load', { group = 'B', steps = { { file = f, hunks = { { from = 2, to = 2, group = 'A' }, { from = 5, to = 5 } } } } })
    return r
  end
  local function index_diff(r)
    return H.git_in(r, 'diff', '--cached', '-U0', '--', 'f.txt')
  end
  -- Stage the group's lines of every file; waits for the report and for the index to hold `want`.
  local function stage_group_all(r, group, want)
    w.group(group)
    reset_log()
    w.stage_group({ all = true })
    H.wait_notify(find, 'commit "' .. group .. '"')
    return H.wait(function()
      return index_diff(r):match(want) ~= nil
    end)
  end
  -- Commit what is staged with the plugin's dialog.
  local function commit_staged(group, msg)
    w.group(group)
    w.commit()
    local dd = dialog()
    if not dd then
      return false
    end
    H.wait(function() return dd.check.state ~= 'running' end)
    type_message(dd, { msg })
    press('<CR>')
    return H.wait(function() return dialog() == nil end)
  end
  local function count(r)
    return H.git_in(r, 'rev-list', '--count', 'HEAD')
  end
  -- gitsigns takes its diff algorithm from 'diffopt'; git has its own. With `algorithm:histogram`
  -- and `linematch` gitsigns cuts "a line added, the next one changed" into two hunks where git
  -- reports one, so the two never report the same hunks. They still agree: staging must not wait
  -- for the same shape.
  do
    local saved = vim.o.diffopt
    vim.opt.diffopt:append('algorithm:histogram')
    vim.opt.diffopt:append('linematch:40')
    for _, view in ipairs({ 'file', 'compact' }) do
      w.close()
      vim.cmd('silent! %bwipeout!')
      reset_log()
      st.config.view = view
      local r = H.repo({ ['f.txt'] = { 'src=$1', 'dest=/tmp', '', 'mkdir -p "$dest"', 'tar -czf "$dest/backup.tar.gz" "$src"', 'echo done' } },
        { ['f.txt'] = { 'src=$1', 'if [ ! -d "$src" ]; then', '  exit 2', 'fi', 'dest=/tmp', '', 'mkdir -p "$dest"',
          'name=$(basename "$src")', 'tar -czf "$dest/$name.tar.gz" "$src"', 'echo done' } })
      vim.cmd('cd ' .. vim.fn.fnameescape(r))
      local f = r .. '/f.txt'
      send('load', { group = 'A', steps = { { file = f, hunks = { { from = 2, to = 4 }, { from = 8, to = 9, group = 'B' } } } } })
      send('load', { group = 'B', steps = { { file = f, hunks = { { from = 2, to = 4, group = 'A' }, { from = 8, to = 9 } } } } })
      check(view .. ' view, histogram and linematch: the first commit is staged', stage_group_all(r, 'A', '%+  exit 2')
        and not index_diff(r):match('basename') and find('has not caught up') == nil, vim.inspect(log) .. index_diff(r))
      check(view .. ' view, histogram and linematch: the second commit is staged', stage_group_all(r, 'B', 'basename')
        and index_diff(r):match('%$name%.tar%.gz') ~= nil and find('has not caught up') == nil, vim.inspect(log) .. index_diff(r))
      check(view .. ' view, histogram and linematch: nothing is left unstaged', H.wait(function()
        return H.git_in(r, 'diff', '--', 'f.txt') == ''
      end), H.git_in(r, 'diff', '--', 'f.txt'))
    end
    vim.o.diffopt = saved
  end
  -- The same without depending on how a gitsigns or Neovim version cuts hunks: a gitsigns that
  -- reports three hunks where git reports two (a line added, the next one changed) agrees with git,
  -- because its hunks lead from the buffer back to the text in the index. One whose hunks do not
  -- (it still has what was there before a commit) does not agree.
  do
    w.close()
    vim.cmd('silent! %bwipeout!')
    local r = H.repo({ ['f.txt'] = { 'src=$1', 'dest=/tmp', 'tar -czf "$dest/backup.tar.gz" "$src"', 'echo done' } },
      { ['f.txt'] = { 'src=$1', 'if [ ! -d "$src" ]; then', '  exit 2', 'fi', 'dest=/tmp', 'name=$(basename "$src")',
        'tar -czf "$dest/$name.tar.gz" "$src"', 'echo done' } })
    vim.cmd('edit ' .. vim.fn.fnameescape(r .. '/f.txt'))
    local buf = vim.api.nvim_get_current_buf()
    local function hunk(added_start, added, removed_start, removed)
      return { added = { start = added_start, count = #added, lines = added },
        removed = { start = removed_start, count = #removed, lines = removed } }
    end
    local cut_differently = {
      hunk(2, { 'if [ ! -d "$src" ]; then', '  exit 2', 'fi' }, 1, {}),
      hunk(6, { 'name=$(basename "$src")' }, 2, {}),
      hunk(7, { 'tar -czf "$dest/$name.tar.gz" "$src"' }, 3, { 'tar -czf "$dest/backup.tar.gz" "$src"' }),
    }
    check('synced: git reports two hunks here', select(2, H.git_in(r, 'diff', '-U0', '--', 'f.txt'):gsub('\n@@', '')) == 2,
      H.git_in(r, 'diff', '-U0', '--', 'f.txt'))
    local stage = require('walkthrough.stage')
    local result
    stage.synced(buf, { get_hunks = function() return cut_differently end, refresh = function() end }, function(ok)
      result = ok
    end)
    check('synced: hunks cut differently than git cuts them agree with git', H.wait(function() return result ~= nil end) and result == true)
    -- Hunks of another state of the index: the first change is missing, as if it had been committed.
    local stale = { cut_differently[2], cut_differently[3] }
    result = nil
    local asked = 0
    local t0 = vim.uv.now()
    stage.synced(buf, { get_hunks = function() return stale end, refresh = function() asked = asked + 1 end }, function(ok)
      result = ok
    end)
    vim.wait(8000, function() return result ~= nil end, 50)
    check('synced: hunks of another index do not agree; it asks gitsigns to read again, then gives up', result == false and asked >= 1
      and vim.uv.now() - t0 >= 4000, vim.inspect({ result, asked, vim.uv.now() - t0 }))
    vim.cmd('silent! %bwipeout!')
  end

  -- In the compact view the file is hidden. gitsigns' watcher notices a commit or reset made behind
  -- its back after a short debounce and then drops its hunks of the hidden buffer
  -- (`update_on_view`); a user stages minutes later, so wait for that to have happened. The test does
  -- not depend on it: it only makes the hidden-buffer case the one under test.
  local function after_git_moved(r, view)
    if view ~= 'compact' then
      return
    end
    local ok, gcache = pcall(require, 'gitsigns.cache')
    local buf = vim.fn.bufnr(r .. '/f.txt')
    if ok and buf > 0 then
      H.wait(function()
        local c = gcache.cache[buf]
        return c == nil or c.update_on_view == true
      end)
    end
  end
  local function clean(r)
    return H.git_in(r, 'status', '--porcelain') == ''
  end

  for _, view in ipairs({ 'compact', 'file' }) do
    local r = shared_map(view)
    check(view .. ' view, commit dialog: the first commit stages its line only',
      stage_group_all(r, 'A', '%+A2') and not index_diff(r):match('B5'), index_diff(r))
    check(view .. ' view, commit dialog: the first commit is made', commit_staged('A', 'feat: a') and count(r) == '2')
    after_git_moved(r, view)
    check(view .. ' view, commit dialog: the next commit\'s line in the same file is staged',
      stage_group_all(r, 'B', '%+B5'), vim.inspect(log) .. index_diff(r))
    check(view .. ' view, commit dialog: ... exactly that line, and the plugin says so',
      not index_diff(r):match('A2') and find('staged commit "B": 1 line in 1 file') ~= nil, vim.inspect(log) .. index_diff(r))
    check(view .. ' view, commit dialog: ... and it can be committed, leaving a clean tree',
      commit_staged('B', 'feat: b') and count(r) == '3' and clean(r), H.git_in(r, 'status', '--short'))
  end

  -- The commit made in the compact view, the next commit staged in the file view.
  do
    local r = shared_map('compact')
    stage_group_all(r, 'A', '%+A2')
    commit_staged('A', 'feat: a')
    after_git_moved(r, 'compact')
    w.group('B')
    w.view('file')
    check('switching views after a commit: the next commit is staged in the file view', stage_group_all(r, 'B', '%+B5')
      and commit_staged('B', 'feat: b') and clean(r), vim.inspect(log) .. H.git_in(r, 'status', '--short'))
  end

  -- A commit made from a shell while the tour is open.
  for _, view in ipairs({ 'compact', 'file' }) do
    local r = shared_map(view)
    stage_group_all(r, 'A', '%+A2')
    H.git_in(r, 'commit', '-qm', 'a (external)')
    after_git_moved(r, view)
    check(view .. ' view, external git commit: the next commit is staged', stage_group_all(r, 'B', '%+B5')
      and not index_diff(r):match('A2'), vim.inspect(log) .. index_diff(r))
    H.git_in(r, 'commit', '-qm', 'b (external)')
    check(view .. ' view, external git commit: ... and the tree is clean after committing it', count(r) == '3' and clean(r))
  end

  -- An external git reset un-stages everything the plugin staged.
  for _, view in ipairs({ 'compact', 'file' }) do
    local r = shared_map(view)
    stage_group_all(r, 'A', '%+A2')
    H.git_in(r, 'reset', '-q')
    after_git_moved(r, view)
    check(view .. ' view, external git reset: nothing is staged', index_diff(r) == '')
    check(view .. ' view, external git reset: the same commit can be staged again', stage_group_all(r, 'A', '%+A2')
      and not index_diff(r):match('B5'), vim.inspect(log) .. index_diff(r))
    check(view .. ' view, external git reset: ... and the other one on top of it', stage_group_all(r, 'B', '%+B5')
      and index_diff(r):match('%+A2') ~= nil, vim.inspect(log) .. index_diff(r))
    H.git_in(r, 'commit', '-qm', 'all')
    check(view .. ' view, external git reset: ... leaving a clean tree', clean(r), H.git_in(r, 'status', '--short'))
  end

  -- Reject (gitsigns' reset_hunk) works from the same cache.
  do
    local r = shared_map('compact')
    stage_group_all(r, 'A', '%+A2')
    commit_staged('A', 'feat: a')
    after_git_moved(r, 'compact')
    w.group('B')
    reset_log()
    w.reject_group()
    check('compact view, reject after a commit: the next commit\'s line is discarded', H.wait(function()
      return vim.deep_equal(vim.fn.readfile(r .. '/f.txt'), { 'l1', 'A2', 'l3', 'l4', 'l5', 'l6' })
    end) and clean(r), vim.inspect(vim.fn.readfile(r .. '/f.txt')) .. vim.inspect(log))
    check('compact view, reject after a commit: ... and the plugin says so', H.wait_notify(find, 'discarded 1 unstaged line of commit "B"') ~= nil,
      vim.inspect(log))
  end

  -- The same after a commit from a shell.
  do
    local r = shared_map('compact')
    stage_group_all(r, 'A', '%+A2')
    H.git_in(r, 'commit', '-qm', 'a (external)')
    after_git_moved(r, 'compact')
    w.group('B')
    reset_log()
    w.reject_group()
    check('compact view, reject after an external commit: the line is discarded', H.wait(function()
      return vim.deep_equal(vim.fn.readfile(r .. '/f.txt'), { 'l1', 'A2', 'l3', 'l4', 'l5', 'l6' })
    end) and clean(r), vim.inspect(vim.fn.readfile(r .. '/f.txt')) .. vim.inspect(log))
  end

  vim.fn.confirm = confirm_saved
  st.config.view = 'file'
end

w.close()
H.finish()
