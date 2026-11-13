-- The default keys (setup({ keys = ... })) and the key cheat sheet. Every
-- action has a <Plug> mapping (plugin/walkthrough.lua); the keys here map to
-- those, so a user can map the same actions to other keys.

local ui = require('walkthrough.ui')

local M = {}

-- { key, <Plug> name, modes, absolute }. A key is appended to the prefix
-- (`<leader>w` unless setup() got a string), except when `absolute` is set.
M.defaults = {
  { ']w', 'next', { 'n' }, true },
  { '[w', 'prev', { 'n' }, true },
  { ']n', 'note-next', { 'n' }, true },
  { '[n', 'note-prev', { 'n' }, true },
  { 'w', 'back' },
  { ']', 'group-next' },
  { '[', 'group-prev' },
  { 'a', 'ask' },
  { 'c', 'comment', { 'n', 'x' } },
  { 'i', 'comment-issue', { 'n', 'x' } },
  { 'u', 'comment-suggestion', { 'n', 'x' } },
  { 'X', 'comment-delete' },
  { 'm', 'send' },
  { 'y', 'accept' },
  { 'd', 'decline' },
  { '0', 'undecide' },
  { '-', 'simpler' },
  { '+', 'deeper' },
  { '=', 'deeper' },
  { 'r', 'check-reveal' },
  { 'e', 'check-answer' },
  { 's', 'stage' },
  { 'S', 'stage-all' },
  { 'x', 'reject' },
  { 'b', 'base' },
  { 'v', 'reviewed' },
  { 'R', 'resume' },
  { 'q', 'close' },
  { '?', 'keys' },
}

--- The prefix `setup({ keys = ... })` means: `true` is `<leader>w`, a string
--- is itself, anything else (`false`) maps nothing.
function M.prefix(keys)
  if keys == true then
    return '<leader>w'
  end
  return type(keys) == 'string' and keys ~= '' and keys or nil
end

-- <Plug> name -> what it does, in words (filled from the cheat sheet below),
-- so which-key and :map show "Walkthrough: stage the group in this file"
-- rather than a mapping name.
local text_of = {}

--- Map the default keys whose key is still free. A mapping that is there
--- already is left as it is, whoever made it: that includes our own from an
--- earlier setup(), which already does what we would set.
function M.map(prefix)
  for _, k in ipairs(M.defaults) do
    local lhs = k[4] and k[1] or prefix .. k[1]
    for _, mode in ipairs(k[3] or { 'n' }) do
      if vim.fn.maparg(lhs, mode) == '' then
        vim.keymap.set(mode, lhs, '<Plug>(walkthrough-' .. k[2] .. ')', {
          remap = true,
          desc = 'Walkthrough: ' .. (text_of[k[2]] or k[2]),
        })
      end
    end
  end
  -- which-key shows the group's name instead of "+prefix". Optional.
  local ok, wk = pcall(require, 'which-key')
  if ok and type(wk) == 'table' and type(wk.add) == 'function' then
    pcall(wk.add, { { prefix, group = 'walkthrough', mode = { 'n', 'x' } } })
  end
end

-- The cheat sheet: { group, { { <Plug> name, text, :Walkthrough fallback } } }.
local sheet = {
  { 'Move', {
    { 'next', 'next step', 'next' },
    { 'prev', 'previous step', 'prev' },
    { 'back', 'show the current step again', 'back' },
    { 'note-next', 'next note', 'note-next' },
    { 'note-prev', 'previous note', 'note-prev' },
    { 'group-next', 'next tour', 'group next' },
    { 'group-prev', 'previous tour', 'group prev' },
  } },
  { 'Ask and comment', {
    { 'ask', 'ask the agent about this note or line', 'ask' },
    { 'comment', 'comment: question', 'comment question' },
    { 'comment-issue', 'comment: issue', 'comment issue' },
    { 'comment-suggestion', 'comment: suggestion', 'comment suggestion' },
    { 'comment-delete', 'delete the comment here', 'comment-delete' },
    { 'send', 'send comments, decisions and answers', 'send' },
  } },
  { 'Decide', {
    { 'accept', "accept the note's verdict", 'decide accept' },
    { 'decline', "decline the note's verdict", 'decide reject' },
    { 'undecide', 'clear the decision', 'decide clear' },
  } },
  { 'Understand', {
    { 'simpler', 'explain simpler', 'explain simpler' },
    { 'deeper', 'explain deeper', 'explain deeper' },
    { 'check-reveal', "reveal the check's answer", 'check reveal' },
    { 'check-answer', 'answer the check', 'check answer' },
  } },
  { 'Approve', {
    { 'stage', 'stage the group in this file', 'stage' },
    { 'stage-all', 'stage the group in every file', 'stage all' },
    { 'reject', "discard the group's unstaged lines", 'reject' },
    { 'base', 'base view', 'base' },
  } },
  { 'Review state', {
    { 'reviewed', 'record a reviewed snapshot', 'reviewed' },
    { 'resume', 'bring back the saved review', 'resume' },
    { 'close', 'close the tour', 'close' },
    { 'keys', 'this cheat sheet', 'keys' },
  } },
}

for _, group in ipairs(sheet) do
  for _, a in ipairs(group[2]) do
    text_of[a[1]] = a[2]
  end
end

--- The <Plug> names the cheat sheet lists.
function M.actions()
  local out = {}
  for _, group in ipairs(sheet) do
    for _, a in ipairs(group[2]) do
      table.insert(out, a[1])
    end
  end
  return out
end

-- Plain text lines of the sheet, and the highlight of each (group titles).
local function sheet_lines()
  local mapped = ui.plug_keys()
  local rows, titles = {}, {}
  local function row(left, right)
    table.insert(rows, { left, right })
  end
  for _, group in ipairs(sheet) do
    if #rows > 0 then
      row('', '')
    end
    titles[#rows + 1] = true
    row(group[1], '')
    for _, a in ipairs(group[2]) do
      local keys = mapped[a[1]]
      row(keys and table.concat(keys, ' ') or (':Walkthrough ' .. a[3]), a[2])
    end
  end
  row('', '')
  titles[#rows + 1] = true
  row('In the panel', '')
  for _, k in ipairs(ui.panel_keys) do
    row(table.concat(k.keys, ' '), k.desc:sub(1, 1):lower() .. k.desc:sub(2) .. (k.check and ' (steps with a check)' or ''))
  end
  local width = 0
  for i, r in ipairs(rows) do
    if not titles[i] then
      width = math.max(width, vim.fn.strdisplaywidth(r[1]))
    end
  end
  local lines = {}
  for i, r in ipairs(rows) do
    if titles[i] then
      lines[i] = r[1]
    elseif r[1] == '' then
      lines[i] = ''
    else
      lines[i] = '  ' .. r[1] .. string.rep(' ', width - vim.fn.strdisplaywidth(r[1]) + 2) .. r[2]
    end
  end
  return lines, titles
end

local win

--- Show every action with the key it has right now, or the command when it
--- has none, in a centered float. `q` and `<Esc>` close it.
function M.show()
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
  local lines, titles = sheet_lines()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = 'walkthrough-keys'
  for row in pairs(titles) do
    vim.api.nvim_buf_set_extmark(buf, ui.ns, row - 1, 0, { line_hl_group = 'Title' })
  end
  local width = 20
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l) + 2)
  end
  width = math.min(width, vim.o.columns - 4)
  local height = math.min(#lines, vim.o.lines - vim.o.cmdheight - 4)
  win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = math.max(height, 1),
    row = math.max(0, math.floor((vim.o.lines - vim.o.cmdheight - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = 'minimal',
    border = 'rounded',
    title = ' Walkthrough keys ',
    title_pos = 'center',
  })
  local this = win
  local function close()
    if vim.api.nvim_win_is_valid(this) then
      vim.api.nvim_win_close(this, true)
    end
  end
  for _, key in ipairs({ 'q', '<Esc>' }) do
    vim.keymap.set('n', key, close, { buffer = buf, nowait = true, desc = 'Close the key cheat sheet' })
  end
  return win
end

return M
