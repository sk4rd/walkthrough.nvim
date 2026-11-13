-- Links in a thread or finding: found in the text, and opened from the line
-- (the text under a line is virtual, so the cursor cannot go to a URL).
local H = require('helpers')
local check, send, w = H.check, H.send, H.w
local st = _G.walkthrough_state
local links = require('walkthrough.links')
local thread = require('walkthrough.thread')

local function urls(text)
  return vim.tbl_map(function(l)
    return l.url
  end, links.find(text))
end

-- Finding them ---------------------------------------------------------------------------
check('find: a bare URL', vim.deep_equal(urls('see https://example.org/a/b?x=1#frag for it'), { 'https://example.org/a/b?x=1#frag' }))
check('find: the full stop of the sentence is not part of it', vim.deep_equal(urls('Read https://example.org/a.'), { 'https://example.org/a' }))
check('find: a dot inside stays', vim.deep_equal(urls('https://example.org/a.html, then'), { 'https://example.org/a.html' }))
check('find: a URL in brackets', vim.deep_equal(urls('(see https://example.org/a)'), { 'https://example.org/a' }))
check('find: brackets that belong to the URL stay', vim.deep_equal(urls('https://en.wikipedia.org/wiki/Bash_(Unix_shell) is it'),
  { 'https://en.wikipedia.org/wiki/Bash_(Unix_shell)' }))
check('find: ... also at the end of a bracket', vim.deep_equal(urls('(https://en.wikipedia.org/wiki/Bash_(Unix_shell))'),
  { 'https://en.wikipedia.org/wiki/Bash_(Unix_shell)' }))
local md = links.find('Read [the Bash manual](https://www.gnu.org/software/bash/manual/html_node/Exit-Status.html).')
check('find: a Markdown link, with its text', #md == 1 and md[1].url == 'https://www.gnu.org/software/bash/manual/html_node/Exit-Status.html'
  and md[1].label == 'the Bash manual', vim.inspect(md))
check('find: bold and code around a URL', vim.deep_equal(urls('**https://example.org/a** and `https://example.org/b`'),
  { 'https://example.org/a', 'https://example.org/b' }))
check('find: each URL once, in order', vim.deep_equal(urls('https://b.example https://a.example https://b.example'),
  { 'https://b.example', 'https://a.example' }))
check('find: several lines', vim.deep_equal(urls('one http://a.example\ntwo https://b.example/x\n'), { 'http://a.example', 'https://b.example/x' }))
check('find: nothing', #links.find('no link here, not even www.example.org or ftp://x') == 0)
check('find: a scheme alone is no link', #links.find('write https:// first') == 0)

-- Opening them ---------------------------------------------------------------------------
local opened, picked, offered = {}, nil, nil
vim.ui.open = function(url)
  table.insert(opened, url)
  return {}, nil
end
vim.ui.select = function(items, opts, on_choice)
  offered = vim.tbl_map(opts.format_item, items)
  on_choice(picked and items[picked] or nil)
end
local log, find = H.capture_notify()
local function reset()
  opened, offered = {}, nil
  for i = #log, 1, -1 do
    log[i] = nil
  end
end

local f = H.work .. '/f.txt'
check('load', send('load', { steps = { { file = f, title = 't', notes = {
  { line = 5, text = 'a finding', verdict = 'keep', detail = 'see https://example.org/finding.' },
} } } }) == 'ok')
vim.api.nvim_set_current_win(st.code_win)
vim.api.nvim_win_set_cursor(0, { 2, 0 })
w.ask('what is this?')
local th = st.tours[1].steps[1].threads[1]

reset()
w.link()
check('open: a thread without a link says so', #opened == 0 and find('no link in this thread') ~= nil, vim.inspect(log))

check('patch: an answer with one link', send('patch', { thread = th.id, answer = 'It is a list. See https://example.org/one.' }) == 'ok')
reset()
w.link()
check('open: the only link is opened at once', vim.deep_equal(opened, { 'https://example.org/one' }) and offered == nil, vim.inspect(opened))

w.ask('and more?')
check('patch: an answer with two links', send('patch', { thread = th.id,
  answer = 'Read [the manual](https://example.org/manual) and https://example.org/two.' }) == 'ok')
reset()
picked = 2
w.link()
check('open: several links are offered, the newest message first', offered ~= nil and #offered == 3
  and offered[1] == 'the manual  https://example.org/manual' and offered[2] == 'https://example.org/two'
  and offered[3] == 'https://example.org/one', vim.inspect(offered))
check('open: ... and the one picked is opened', vim.deep_equal(opened, { 'https://example.org/two' }), vim.inspect(opened))
reset()
picked = nil
w.link()
check('open: picking none opens nothing', #opened == 0 and offered ~= nil)

reset()
vim.api.nvim_win_set_cursor(0, { 5, 0 })
w.link()
check('open: the link in the detail of a finding', vim.deep_equal(opened, { 'https://example.org/finding' }), vim.inspect(opened))

reset()
vim.api.nvim_win_set_cursor(0, { 8, 0 })
w.link()
check('open: a line without a thread or finding says so', #opened == 0 and find('no thread or finding on this line') ~= nil, vim.inspect(log))

reset()
vim.ui.open = function()
  return nil, 'no handler'
end
vim.api.nvim_win_set_cursor(0, { 5, 0 })
w.link()
check('open: a failure is a warning, not an error', find('could not open https://example.org/finding') ~= nil
  and find('could not open').level == vim.log.levels.WARN, vim.inspect(log))
vim.ui.open = function(url)
  table.insert(opened, url)
  return {}, nil
end

-- The command, the <Plug> mapping and the float ----------------------------------------------
reset()
vim.cmd('Walkthrough link')
check(':Walkthrough link opens it', vim.deep_equal(opened, { 'https://example.org/finding' }))
reset()
vim.api.nvim_feedkeys(vim.keycode('<Plug>(walkthrough-link)'), 'x', false)
check('<Plug>(walkthrough-link) opens it', vim.deep_equal(opened, { 'https://example.org/finding' }))

vim.api.nvim_win_set_cursor(0, { 2, 0 })
w.thread()
local win = thread.win()
check('float: open', win ~= nil)
local cfg = vim.api.nvim_win_get_config(win)
local footer = table.concat(vim.tbl_map(function(c) return c[1] end, cfg.footer or {}), '')
check('float: the footer names the key', footer:match('o open a link') ~= nil, footer)
check('float: URLs are underlined', (function()
  for _, m in ipairs(vim.fn.getmatches(win)) do
    if m.group == 'Underlined' then
      return true
    end
  end
  return false
end)())
reset()
picked = 1
vim.api.nvim_feedkeys('o', 'x', false)
check('float key o: offers the links of the thread and opens the one picked', offered ~= nil and #offered == 3
  and vim.deep_equal(opened, { 'https://example.org/manual' }), vim.inspect({ offered, opened }))
check('float key o: the float stays open', thread.win() == win)
vim.api.nvim_win_close(win, true)

w.close()
H.finish()
