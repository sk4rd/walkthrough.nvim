-- The default keys (setup({ keys = ... })) and the key cheat sheet. Every
-- action has a <Plug> mapping (plugin/walkthrough.lua); the keys here map to
-- those, so a user can map the same actions to other keys.

local ui = require('walkthrough.ui')

local M = {}

-- { key, <Plug> name, modes, absolute }. A key is appended to the prefix
-- (`<leader>w` unless setup() got a string), except when `absolute` is set.
M.defaults = {
  -- Start
  { 'r', 'review' },
  { 'M', 'request' },
  { 'R', 'resume' },
  { 'q', 'close' },
  -- Move
  { ']w', 'next', { 'n' }, true },
  { '[w', 'prev', { 'n' }, true },
  { ']n', 'note-next', { 'n' }, true },
  { '[n', 'note-prev', { 'n' }, true },
  { ']', 'group-next' },
  { '[', 'group-prev' },
  { 'v', 'view' },
  { 'p', 'map' },
  { 'h', 'inline' },
  { 'w', 'back' },
  -- Write
  { 'a', 'ask', { 'n', 'x' } },
  { 'c', 'change', { 'n', 'x' } },
  { 'm', 'send' },
  { 't', 'thread' },
  { 'o', 'link' },
  { 'X', 'thread-delete' },
  { '-', 'simpler' },
  { '+', 'deeper' },
  { '=', 'deeper' },
  -- Decide
  { 'y', 'accept' },
  { 'd', 'decline' },
  { '0', 'undecide' },
  -- Approve
  { 's', 'stage' },
  { 'S', 'stage-all' },
  { 'x', 'reject' },
  { 'b', 'base' },
  { 'C', 'commit' },
  -- Plan
  { 'A', 'plan-approve' },
  { 'F', 'plan-feedback' },
  -- Help
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
-- so which-key and :map show "Walkthrough: stage the commit in this file"
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
  { 'Start', {
    { 'review', 'review the uncommitted changes (the files, from git)', 'review' },
    { 'request', 'ask the agent for the map of the change', 'request' },
    { 'resume', 'bring back the saved review', 'resume' },
    { 'close', 'end the session', 'close' },
  } },
  { 'Move', {
    { 'next', 'next entry', 'next' },
    { 'prev', 'previous entry', 'prev' },
    { 'note-next', 'next thread or finding', 'note-next' },
    { 'note-prev', 'previous thread or finding', 'note-prev' },
    { 'group-next', 'next commit', 'group next' },
    { 'group-prev', 'previous commit', 'group prev' },
    { 'view', 'switch between the compact view and the file view', 'view' },
    { 'map', 'show or hide the map panel', 'map' },
    { 'inline', 'hide or show the text under the lines', 'inline' },
    { 'back', 'back to the current entry', 'back' },
  } },
  { 'Write', {
    { 'ask', 'ask a question here (sent at once)', 'ask' },
    { 'change', 'write a change request here (collected)', 'change' },
    { 'send', 'send the change requests and decisions', 'send' },
    { 'thread', 'open the thread or finding here in full', 'thread' },
    { 'link', 'open a link of the thread or finding here', 'link' },
    { 'thread-delete', 'delete the thread here', 'thread-delete' },
    { 'simpler', 'ask for a simpler answer here', 'explain simpler' },
    { 'deeper', 'ask for a deeper answer here', 'explain deeper' },
  } },
  { 'Decide', {
    { 'accept', 'accept the proposal or finding here (marked; send delivers it)', 'decide accept' },
    { 'decline', 'decline the proposal or finding here (marked; send delivers it)', 'decide reject' },
    { 'undecide', 'clear a decision that is not sent yet', 'decide clear' },
  } },
  { 'Approve', {
    { 'stage', "stage the commit's lines in this file", 'stage' },
    { 'stage-all', "stage the commit's lines in every file", 'stage all' },
    { 'reject', "discard the commit's unstaged lines", 'reject' },
    { 'base', 'show the base version of the file', 'base' },
    { 'commit', 'check, message and commit what is staged', 'commit' },
  } },
  { 'Plan', {
    { 'plan-approve', 'approve the plan (A in the plan)', 'plan approve' },
    { 'plan-feedback', 'send the plan feedback (F in the plan)', 'plan feedback' },
  } },
  { 'Help', {
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
    row(table.concat(k.keys, ' '), k.desc:sub(1, 1):lower() .. k.desc:sub(2))
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
