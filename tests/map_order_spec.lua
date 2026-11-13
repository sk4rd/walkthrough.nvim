-- The first commit of a map is the current one. An agent sends a map as
-- several calls, one per commit: the first becomes the commit on screen, a
-- later one is added to the map without switching and without moving the
-- view; a commit that is loaded already is replaced where the user is.
local H = require('helpers')
local check, send, w = H.check, H.send, H.w
local st = _G.walkthrough_state
local tours = require('walkthrough.tours')
local store = require('walkthrough.store')
local compact = require('walkthrough.compact')
local log, find = H.capture_notify()

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
local function with(list, changes)
  local out = vim.deepcopy(list)
  for n, text in pairs(changes) do
    out[n] = text
  end
  return out
end
local function groups()
  return vim.tbl_map(function(g)
    return g.group
  end, status().groups)
end
local function reset()
  w.discard()
  w.close()
  vim.cmd('silent! %bwipeout!')
  vim.cmd('silent! only')
  st.restored, st.dir_roots = {}, {}
  reset_log()
end

local function new_repo()
  local base = { ['a.txt'] = lines(12), ['b.txt'] = lines(12, 'b'), ['c.txt'] = lines(12, 'c'), ['d.txt'] = lines(12, 'd') }
  local repo = H.repo(base, {
    ['a.txt'] = with(base['a.txt'], { [3] = 'A3', [9] = 'A9' }), ['b.txt'] = with(base['b.txt'], { [4] = 'B4' }),
    ['c.txt'] = with(base['c.txt'], { [5] = 'C5' }), ['d.txt'] = with(base['d.txt'], { [6] = 'D6' }),
  })
  return repo
end
local repo = new_repo()
vim.cmd('cd ' .. vim.fn.fnameescape(repo))
local function commit_a(extra)
  local c = {
    group = 'A',
    steps = {
      { file = repo .. '/a.txt', title = 'a first', hunks = { { from = 3, group = 'A' }, { from = 9, group = 'A' } } },
      { file = repo .. '/b.txt', title = 'a second', hunks = { { from = 4, group = 'A' } } },
    },
  }
  return vim.tbl_extend('force', c, extra or {})
end
local function commit_b()
  return { group = 'B', steps = { { file = repo .. '/c.txt', title = 'b only', hunks = { { from = 5, group = 'B' } } } } }
end
local function commit_c()
  return { group = 'C', steps = { { file = repo .. '/d.txt', title = 'c only', hunks = { { from = 6, group = 'C' } } } } }
end
local function code_name()
  return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(st.code_win))
end

for _, view in ipairs({ 'file', 'compact' }) do
  st.config.view = view
  reset()
  check(view .. ': the first commit is loaded and shown', send('load', commit_a()) == 'ok' and tours.active().group == 'A')
  w.step(1)
  local before = {
    buf = vim.api.nvim_win_get_buf(st.code_win), cursor = vim.api.nvim_win_get_cursor(st.code_win), win = st.code_win,
    panel = vim.api.nvim_win_get_cursor(st.panel_win), pos = st.pos,
  }
  vim.api.nvim_win_set_cursor(st.code_win, { math.min(2, vim.api.nvim_buf_line_count(before.buf)), 0 })
  before.cursor = vim.api.nvim_win_get_cursor(st.code_win)
  local wins = #vim.api.nvim_list_wins()
  reset_log()
  check(view .. ': a second commit is added', send('load', commit_b()) == 'ok')
  check(view .. ': a third commit is added', send('load', commit_c()) == 'ok')
  check(view .. ': the first commit stays the current one', tours.active().group == 'A' and status().group == 'A'
    and vim.deep_equal(groups(), { 'A', 'B', 'C' }), vim.inspect(groups()))
  check(view .. ': ... at the step the user is on', st.pos == before.pos and status().step == 2 and status().title == 'a second')
  check(view .. ': ... the code window shows what it showed', vim.api.nvim_win_get_buf(st.code_win) == before.buf and st.code_win == before.win
    and vim.deep_equal(vim.api.nvim_win_get_cursor(st.code_win), before.cursor), vim.inspect(vim.api.nvim_win_get_cursor(st.code_win)))
  check(view .. ': ... no window was opened or closed', #vim.api.nvim_list_wins() == wins)
  check(view .. ': ... the view of the current commit is the same', status().view == view
    and (view ~= 'compact' or compact.shown(tours.active()) ~= nil))
  check(view .. ': a notification names each later commit', find('commit "B" added to the map') ~= nil and find('commit "C" added to the map') ~= nil
    and find('commit "B" added to the map').msg:match('A stays on screen'), vim.inspect(log))
  check(view .. ': the map lists all three', H.wait(function()
    local text = H.panel_text()
    return text:match('\nB\n') and text:match('\nC\n') and text:match('b only') and text:match('c only')
  end), H.panel_text())
  check(view .. ': ... and the marker is on the step of the current commit', H.panel_text():match('\n> [^\n]*b%.txt') ~= nil, H.panel_text())
  check(view .. ': the commits that were not shown are not marked as seen', not st.tours[2].steps[1].seen and not st.tours[3].steps[1].seen)
  check(view .. ': the state file has all three, with A as the current', (function()
    local data = vim.json.decode(table.concat(vim.fn.readfile(store.path(store.root_of(repo .. '/a.txt'))), '\n'))
    return #data.tours == 3 and data.active == 'A'
  end)())
  -- Another call for a commit that is loaded replaces it where the user is.
  reset_log()
  check(view .. ': replacing the commit on screen', send('load', commit_a()) == 'ok')
  check(view .. ': ... keeps the position', tours.active().group == 'A' and st.pos == 2 and status().step == 2, vim.inspect(status()))
  check(view .. ': ... and the order of the map', vim.deep_equal(groups(), { 'A', 'B', 'C' }))
  check(view .. ': ... no notification of an added commit', find('added to the map') == nil)
  check(view .. ': ... "start" still says where to go', send('load', commit_a({ start = 1 })) == 'ok' and st.pos == 1)
  w.step(1)
  reset_log()
  local screen = { buf = vim.api.nvim_win_get_buf(st.code_win), cursor = vim.api.nvim_win_get_cursor(st.code_win) }
  check(view .. ': replacing a commit that is not on screen leaves the screen alone', send('load', commit_b()) == 'ok'
    and tours.active().group == 'A' and st.pos == 2 and vim.deep_equal(groups(), { 'A', 'B', 'C' }))
  check(view .. ': ... and says it was updated', find('commit "B" updated in the map') ~= nil, vim.inspect(log))
  check(view .. ': ... the code window did not move', vim.api.nvim_win_get_buf(st.code_win) == screen.buf
    and vim.deep_equal(vim.api.nvim_win_get_cursor(st.code_win), screen.cursor))
  check(view .. ': the user can go to a later commit by choice', (function()
    w.group('B')
    return status().group == 'B' and status().step == 1
  end)())
  w.group('A')
  check(view .. ': ... and back to where they were', status().group == 'A' and status().step == 2)
  -- A commit that cannot be shown is an error now, not when the user gets there.
  reset_log()
  local bad = send('load', { group = 'Bad', steps = { { file = repo .. '/d.txt', diff = 'no-such-ref' } } })
  check(view .. ': a later commit with a base that does not exist is refused', bad:match('^error: git diff failed') ~= nil
    and vim.deep_equal(groups(), { 'A', 'B', 'C' }) and tours.active().group == 'A', bad)
  check(view .. ': ... also with a file that cannot be read', send('load', { group = 'Bad', steps = { { file = repo .. '/nope.txt' } } })
    :match('^error: .*cannot read file') ~= nil and #st.tours == 3)
end
st.config.view = 'file'

-- A review of git is replaced by the first commit; the next one is added --------------------------
reset()
w.review()
check('review: the local review is the unnamed tour, flagged auto', #st.tours == 1 and st.tours[1].auto == true and tours.active().auto == true)
check('review: the first commit of the agent takes over', send('load', commit_a()) == 'ok' and #st.tours == 1 and tours.active().group == 'A'
  and not st.tours[1].auto, vim.inspect(groups()))
check('review: the next one is added without switching', send('load', commit_b()) == 'ok' and tours.active().group == 'A'
  and vim.deep_equal(groups(), { 'A', 'B' }))

-- Nothing open, or only threads on files that are in no map -------------------------------------------------
reset()
vim.cmd('edit ' .. vim.fn.fnameescape(repo .. '/d.txt'))
vim.api.nvim_win_set_cursor(0, { 3, 0 })
w.ask('what is this?')
check('setup: a session with only Other files', #st.tours == 1 and st.tours[1].extra == true and st.active == 0)
check('Other files: the first commit becomes the current one', send('load', commit_a()) == 'ok' and tours.active().group == 'A')
check('... a second is added', send('load', commit_b()) == 'ok' and tours.active().group == 'A')

-- A restored map that was never shown is not "open" ------------------------------------------------------------
reset()
check('setup: two commits saved', send('load', commit_a()) == 'ok' and send('load', commit_b()) == 'ok')
local root = store.root_of(repo .. '/a.txt')
st.tours, st.active = {}, 0
st.restored, st.dir_roots = {}, {}
check('restored: the saved commits come back silently', store.restore_for(repo .. '/a.txt') == true and #st.tours == 2
  and tours.active() ~= nil and tours.active().shown == nil)
check('restored: a commit of the agent takes over, as it did before', send('load', commit_c()) == 'ok' and tours.active().group == 'C',
  tours.active() and tours.active().group)
check('restored: and the next one does not', send('load', commit_a()) == 'ok' and tours.active().group == 'C')

-- Another repository ------------------------------------------------------------------------------------------
reset()
local other = new_repo()
check('setup: two commits of the first repository', send('load', commit_a()) == 'ok' and send('load', commit_b()) == 'ok'
  and tours.active().group == 'A')
w.step(1)
local first = st.tours[1]
local snapshot = { pos = first.pos, steps = #first.steps, b_pos = st.tours[2].pos }
check('other repository: its first commit is the one on screen', send('load', {
  group = 'X', steps = { { file = other .. '/a.txt', title = 'x first', hunks = { { from = 3, group = 'X' } } } },
}) == 'ok' and tours.active().group == 'X' and tours.active().root ~= first.root, vim.inspect(groups()))
check('other repository: the commits of the first one are as they were', st.tours[1] == first and first.pos == snapshot.pos
  and #first.steps == snapshot.steps and st.tours[2].group == 'B' and st.tours[2].pos == snapshot.b_pos and #st.tours == 3)
check('other repository: its later commit is added without switching', send('load', {
  group = 'Y', steps = { { file = other .. '/b.txt', title = 'y first', hunks = { { from = 4, group = 'Y' } } } },
}) == 'ok' and tours.active().group == 'X' and #st.tours == 4)
check('a later commit of the first repository does not switch back', send('load', commit_c()) == 'ok' and tours.active().group == 'X'
  and #st.tours == 5)
check('... and the map of the active repository lists only its own commits', (function()
  local text = H.panel_text()
  return text:match('x first') ~= nil and text:match('y first') ~= nil and not text:match('a first') and not text:match('c only')
end)(), H.panel_text())

-- A lone step still joins the active commit, a commit without a group still takes the place -----------------------
reset()
send('load', commit_a())
send('load', commit_b())
check('a lone step joins the current commit, not the last one', send('load', { file = repo .. '/d.txt', title = 'lone' }) == 'ok'
  and #st.tours[1].steps == 3 and #st.tours[2].steps == 1, vim.inspect(groups()))
check('a map without a group is the active one', send('load', { steps = { { file = repo .. '/d.txt', title = 'unnamed' } } }) == 'ok'
  and tours.active().group == nil and #st.tours == 3)

w.close()
vim.cmd('silent! %bwipeout!')
H.finish()
