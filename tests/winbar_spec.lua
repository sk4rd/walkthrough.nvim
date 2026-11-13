-- The panel's bar: group and progress are never cut off, and hints that do
-- not fit are repeated under the map. Also the wrapping of long text in the
-- code window.
local H = require('helpers')
local check, send, w = H.check, H.send, H.w
local st = _G.walkthrough_state
local footer_ns = function() return vim.api.nvim_get_namespaces().walkthrough_panel end

local function footer()
  local marks = vim.api.nvim_buf_get_extmarks(st.panel_buf, footer_ns(), 0, -1, { details = true })
  local text = {}
  for _, m in ipairs(marks) do
    for _, line in ipairs(m[4].virt_lines or {}) do
      table.insert(text, line[1][1])
    end
  end
  return marks, table.concat(text, '\n')
end
local function shown_bar()
  return vim.api.nvim_eval_statusline(H.panel_winbar(), { winid = st.panel_win, use_winbar = true }).str
end

vim.o.columns = 200
check('load', send('load', { group = 'A group with a long name', steps = {
  { file = H.work .. '/f.txt', title = 'a title that is long enough to push the hints out of the bar' },
  { file = H.work .. '/g.txt', title = 'two' } } }) == 'ok')

check('the bar is cut in the hints, not at the start', H.panel_winbar():find('%<', 1, true) ~= nil
  and H.panel_winbar():find('seen 1/2', 1, true) < H.panel_winbar():find('%<', 1, true), H.panel_winbar())

vim.api.nvim_win_set_width(st.panel_win, 40)
w.step(0)
check('narrow panel: the group is still at the start of the bar', shown_bar():match('^%s*A group with a long name') ~= nil, shown_bar())
local marks, text = footer()
check('narrow panel: the hints are under the text', #marks == 1 and text:match('open') and text:match('stage all')
  and text:match('all keys'), text)
check('narrow panel: the footer is on the last line', marks[1] and marks[1][2] == vim.api.nvim_buf_line_count(st.panel_buf) - 1)
local too_wide = false
for _, line in ipairs(vim.split(text, '\n')) do
  too_wide = too_wide or vim.fn.strdisplaywidth(line) > 40
end
check('narrow panel: footer lines fit the panel', not too_wide, text)
check('the hints are not part of the buffer text', not H.panel_text():match('stage all'))

w.step(1)
marks, text = footer()
check('next step: one footer, on the new last line', #marks == 1 and marks[1][2] == vim.api.nvim_buf_line_count(st.panel_buf) - 1)

-- The code window keeps half the screen, so the screen has to grow as well.
vim.o.columns = 300
vim.api.nvim_win_set_width(st.panel_win, 140)
w.step(0)
marks = footer()
check('wide panel: the bar fits, no footer', #marks == 0, shown_bar())

-- Virtual lines do not wrap: a long thread or answer is wrapped by hand ----
do
  local ui = require('walkthrough.ui')
  local wrapped = ui.wrap('one two three four five six seven eight nine ten eleven twelve', 20)
  local ok = #wrapped > 1
  for _, l in ipairs(wrapped) do
    ok = ok and vim.fn.strdisplaywidth(l) <= 20
  end
  check('wrap: lines fit the width', ok, vim.inspect(wrapped))
  check('wrap: nothing is lost', table.concat(wrapped, ' ') == 'one two three four five six seven eight nine ten eleven twelve')
  check('wrap: keeps given line breaks', #ui.wrap('a\nb', 40) == 2)

  vim.o.columns = 120
  send('load', { steps = { { file = H.work .. '/f.txt', title = 't' } } })
  vim.api.nvim_set_current_win(st.code_win)
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  require('walkthrough.state').config.sender = function() end
  w.ask('why?')
  local long = string.rep('a fairly long answer that goes on ', 40)
  check('long answer patch', send('patch', { thread = 't1', answer = long }) == 'ok')
  local width = vim.api.nvim_win_get_width(st.code_win) - vim.fn.getwininfo(st.code_win)[1].textoff
  local lines, fits = {}, true
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, H.ns, 0, -1, { details = true })) do
    for _, vl in ipairs(m[4].virt_lines or {}) do
      table.insert(lines, H.vtext(vl))
      fits = fits and vim.fn.strdisplaywidth(H.vtext(vl)) <= width
    end
  end
  check('long answer: every virtual line fits the code window', fits and #lines > 2, vim.inspect(lines))
  check('long answer: the whole thread is capped at 6 lines, ending with how to open it', #lines == 6
    and lines[#lines]:match('^%s+… full thread: ') ~= nil, vim.inspect(lines))
end

-- A note's detail is read under its text in the code window ------------------------
do
  send('load', { steps = { { file = H.work .. '/f.txt', title = 't',
    notes = { { line = 2, text = 'one', detail = { 'first line', 'second line' } }, { line = 4, text = 'two' },
      { line = 6, text = 'six', detail = string.rep('a long detail that goes on ', 40) } } } } })
  vim.api.nvim_set_current_win(st.code_win)
  local function virt_at(row)
    local out = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, H.ns, { row - 1, 0 }, { row - 1, -1 }, { details = true })) do
      for _, vl in ipairs(m[4].virt_lines or {}) do
        table.insert(out, H.vtext(vl))
      end
    end
    return out
  end
  check('detail: under the text, indented to it, one line per line of detail',
    vim.deep_equal(virt_at(2), { '[1] one', '    first line', '    second line' }), vim.inspect(virt_at(2)))
  check('detail: a note without one is just its text', vim.deep_equal(virt_at(4), { '[2] two' }), vim.inspect(virt_at(4)))
  local long = virt_at(6)
  local width = vim.api.nvim_win_get_width(st.code_win) - vim.fn.getwininfo(st.code_win)[1].textoff
  local fits = true
  for _, l in ipairs(long) do
    fits = fits and vim.fn.strdisplaywidth(l) <= width
  end
  check('detail: a long one is wrapped to the window and capped at 6 lines', #long == 1 + 6 + 1 and fits
    and long[#long]:match('^%s+… %d+ more lines$') ~= nil, vim.inspect(long))
  check('detail: the cap says how many lines are not shown', (function()
    local total = #require('walkthrough.ui').wrap(string.rep('a long detail that goes on ', 40), width - 4 - 1)
    return long[#long]:match('… (%d+) more') == tostring(total - 6)
  end)(), vim.inspect(long))
  local hl = H.marks(function(d)
    return d.virt_lines and d.virt_lines[2] and d.virt_lines[2][1][2] == 'WalkthroughNoteDetail'
  end)
  check('detail: dimmed, apart from the text', hl == 2, hl)
end

w.close()
H.finish()
