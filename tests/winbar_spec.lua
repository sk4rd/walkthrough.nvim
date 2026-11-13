-- The panel's bar: step and progress are never cut off, and hints that do
-- not fit are repeated under the panel text.
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
  { file = H.work .. '/f.txt', title = 'a title that is long enough to push the hints out of the bar', panel = { '# One', 'text' },
    check = { question = 'q?', answer = 'a' } },
  { file = H.work .. '/g.txt', title = 'two' } } }) == 'ok')

check('the bar is cut in the hints, not at the start', H.panel_winbar():find('%<', 1, true) ~= nil
  and H.panel_winbar():find('Step 1/2', 1, true) < H.panel_winbar():find('%<', 1, true), H.panel_winbar())

vim.api.nvim_win_set_width(st.panel_win, 40)
w.step(0)
check('narrow panel: the step is still at the start of the bar', shown_bar():match('^%s*Step 1/2') ~= nil, shown_bar())
local marks, text = footer()
check('narrow panel: the hints are under the text', #marks == 1 and text:match('jump to note') and text:match('r reveal') and text:match('simpler'), text)
check('narrow panel: the footer is on the last line', marks[1] and marks[1][2] == vim.api.nvim_buf_line_count(st.panel_buf) - 1)
local too_wide = false
for _, line in ipairs(vim.split(text, '\n')) do
  too_wide = too_wide or vim.fn.strdisplaywidth(line) > 40
end
check('narrow panel: footer lines fit the panel', not too_wide, text)
check('the hints are not part of the buffer text', not H.panel_text():match('jump to note'))

w.step(1)
marks, text = footer()
check('next step: one footer, on the new last line', #marks == 1 and marks[1][2] == vim.api.nvim_buf_line_count(st.panel_buf) - 1)
check('next step: no check keys without a check', not text:match('r reveal'), text)

-- The code window keeps half the screen, so the screen has to grow as well.
vim.o.columns = 300
vim.api.nvim_win_set_width(st.panel_win, 140)
w.step(0)
marks = footer()
check('wide panel: the bar fits, no footer', #marks == 0, shown_bar())

-- Virtual lines do not wrap: a long comment or answer is wrapped by hand ----
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
  w.comment('question', 'why?')
  local long = string.rep('a fairly long answer that goes on ', 40)
  check('long answer patch', send('patch', { comment = 'c1', answer = long }) == 'ok')
  local width = vim.api.nvim_win_get_width(st.code_win) - vim.fn.getwininfo(st.code_win)[1].textoff
  local lines, fits = {}, true
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, H.ns, 0, -1, { details = true })) do
    for _, vl in ipairs(m[4].virt_lines or {}) do
      table.insert(lines, vl[1][1])
      fits = fits and vim.fn.strdisplaywidth(vl[1][1]) <= width
    end
  end
  check('long answer: every virtual line fits the code window', fits and #lines > 2, vim.inspect(lines))
  check('long answer: capped, with a pointer to the panel', lines[#lines]:match('more lines in the panel') ~= nil, lines[#lines])
  check('long answer: the panel has all of it', H.panel_text():find(long, 1, true) ~= nil)
end

-- "This note" in the panel means the heading or any line of its text ------
do
  local ui = require('walkthrough.ui')
  send('load', { steps = { { file = H.work .. '/f.txt', title = 't', panel = { '# T', 'intro' },
    notes = { { line = 2, text = 'one', detail = { 'first line', 'second line' } }, { line = 4, text = 'two', detail = 'other' } } } } })
  vim.api.nvim_set_current_win(st.panel_win)
  local function at(pattern)
    for i, l in ipairs(vim.api.nvim_buf_get_lines(st.panel_buf, 0, -1, false)) do
      if l:match(pattern) then
        vim.api.nvim_win_set_cursor(st.panel_win, { i, 0 })
        return true
      end
    end
  end
  at('^### %[1%]')
  check('panel: on a note heading', ui.note_under_cursor() == 1)
  at('^second line')
  check('panel: in the text of note 1', ui.note_under_cursor() == 1)
  at('^other')
  check('panel: in the text of note 2', ui.note_under_cursor() == 2)
  at('^intro')
  check('panel: in the step text is no note', ui.note_under_cursor() == nil)
  at('^## Notes')
  check('panel: on the section heading is no note', ui.note_under_cursor() == nil)
end

w.close()
H.finish()
