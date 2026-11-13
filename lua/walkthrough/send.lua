-- Handing a message to the agent. The request is built in feedback.lua and
-- passed to a sender (config.sender), so any agent that lives in a Neovim
-- terminal, or in the clipboard, can receive it:
--   msg = { text = <markdown>, refs = { { file, from, to }, ... }, prefill = <string|nil>,
--           submit = <boolean, config.submit unless set> }
local st = require('walkthrough.state')
local tour = require('walkthrough.tour')

local M = {}

-- Senders ---------------------------------------------------------------------

local function ref_line(ref)
  local path = vim.fn.fnamemodify(ref.file, ':~:.')
  return ref.from and ('%s:%d-%d'):format(path, ref.from, ref.to or ref.from) or path
end

-- The message as plain text, for senders that have only a text channel.
local function flatten(msg)
  local lines = vim.split(msg.text, '\n', { plain = true })
  if msg.refs and #msg.refs > 0 then
    table.insert(lines, '')
    for _, ref in ipairs(msg.refs) do
      table.insert(lines, ref_line(ref))
    end
  end
  if msg.prefill then
    table.insert(lines, '')
    table.insert(lines, msg.prefill)
  end
  return table.concat(lines, '\n')
end

local senders = {}

-- claudecode.nvim: the context as a temp file plus an @file#L reference to
-- the code. The context file is what makes "simplify this" unambiguous, even
-- after the code moved or in another session. With `submit` one line that
-- points at the context file is typed into the agent's prompt and submitted,
-- and the focus stays where it is; without it the agent terminal gets focus
-- and the line (the prefill, if the message has one) is typed but not sent,
-- so the user can edit it and press Enter.
-- Enter is a key press of its own. In the same write as the text, or right
-- behind it, the agent's prompt reads it as part of what was pasted: the text
-- stays in the prompt and nothing is submitted. So it follows after a pause.
local submit_delay = 300

local function press_enter(chan)
  vim.defer_fn(function()
    pcall(vim.api.nvim_chan_send, chan, '\r')
  end, submit_delay)
end

function senders.claudecode(msg)
  if vim.fn.exists(':ClaudeCodeAdd') ~= 2 then
    error('sender "claudecode" needs claudecode.nvim (the :ClaudeCodeAdd command is missing)', 0)
  end
  local ctx = vim.fn.tempname() .. '-walkthrough-note.md'
  vim.fn.writefile(vim.split(msg.text, '\n', { plain = true }), ctx)
  vim.cmd('ClaudeCodeAdd ' .. vim.fn.fnameescape(ctx))

  for _, ref in ipairs(msg.refs or {}) do
    -- Absolute, so the escaped path never starts with `~`.
    local file = vim.fn.fnameescape(vim.fn.fnamemodify(ref.file, ':p'))
    vim.cmd(ref.from and ('ClaudeCodeAdd %s %d %d'):format(file, ref.from, ref.to or ref.from) or ('ClaudeCodeAdd ' .. file))
  end

  local line = (not msg.submit and msg.prefill)
    or ('Walkthrough: act on the feedback in %s (also added as context), as its "Expected" lines say.'):format(ctx)
  if not msg.submit then
    vim.cmd('ClaudeCodeFocus')
  end
  -- The @-references travel over claudecode's websocket, the typed text over
  -- the terminal; a short delay keeps the text after the references.
  vim.defer_fn(function()
    local ok, err = pcall(function()
      local term = require('claudecode.terminal')
      local buf = msg.submit and term.get_active_terminal_bufnr and term.get_active_terminal_bufnr()
      local chan = buf and vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].channel or 0
      if chan ~= 0 then
        -- Typed without Enter; Enter is pressed on its own (see press_enter).
        term.send_to_terminal(line, { submit = false })
        press_enter(chan)
      else
        -- No terminal to press Enter in is known: claudecode does both.
        term.send_to_terminal(line, { submit = msg.submit == true })
      end
    end)
    if not ok then
      vim.notify('walkthrough: ' .. tour.clean_error(err), vim.log.levels.WARN)
    end
  end, 200)
end

-- Whether a terminal buffer looks like an agent.
local function is_agent(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  local title = vim.b[buf].term_title or ''
  local pattern = st.config.terminal_pattern
  if type(pattern) == 'function' then
    local ok, res = pcall(pattern, name, title, buf)
    return ok and res and true or false
  end
  local hay = name .. '\n' .. title
  local lower = hay:lower()
  for _, p in ipairs(type(pattern) == 'string' and { pattern } or pattern or {}) do
    if lower:find(p) or hay:find(p) then
      return true
    end
  end
  return false
end

--- The terminal buffer of an agent with a running job: one shown in the
--- current tab first, else the most recently used. Returns the buffer and the
--- window showing it in this tab, if any.
function M.find_terminal()
  local shown = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    shown[vim.api.nvim_win_get_buf(win)] = win
  end
  local best, best_rank
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == 'terminal' and vim.bo[buf].channel > 0
      and is_agent(buf) then
      local rank = (shown[buf] and 1e12 or 0) + vim.fn.getbufinfo(buf)[1].lastused
      if not best_rank or rank > best_rank then
        best, best_rank = buf, rank
      end
    end
  end
  return best, best and shown[best]
end

-- A terminal running an agent: the text is pasted as a bracketed paste, so
-- the agent takes it as one block. With `submit` a carriage return follows
-- after a pause (see press_enter)
-- and the cursor stays where it is; without it nothing is submitted (no
-- trailing newline, no Enter) and the cursor moves to the terminal.
function senders.terminal(msg)
  local buf, win = M.find_terminal()
  if not buf then
    error('no agent terminal found (see terminal_pattern in the setup options)', 0)
  end
  local chan = vim.bo[buf].channel
  vim.api.nvim_chan_send(chan, '\27[200~' .. flatten(msg) .. '\27[201~')
  if msg.submit then
    press_enter(chan)
  elseif win then
    vim.api.nvim_set_current_win(win)
    vim.cmd.startinsert()
  end
end

function senders.clipboard(msg)
  -- Without a clipboard provider the unnamed register is all there is.
  local reg = vim.fn.has('clipboard') == 1 and '+' or '"'
  vim.fn.setreg(reg, flatten(msg))
  vim.notify('walkthrough: copied to the clipboard; paste it into your agent', vim.log.levels.INFO)
end

--- The sender `auto` picks right now: 'claudecode', 'terminal' or 'clipboard'.
function M.resolve()
  if vim.fn.exists(':ClaudeCodeAdd') == 2 then
    return 'claudecode'
  end
  if M.find_terminal() then
    return 'terminal'
  end
  return 'clipboard'
end

--- Hand `msg` to the configured sender. Raises with a short message.
function M.send(msg)
  if msg.submit == nil then
    msg.submit = st.config.submit ~= false
  end
  local sender = st.config.sender
  if type(sender) == 'function' then
    return sender(msg)
  end
  if sender == 'auto' or sender == nil then
    sender = M.resolve()
  end
  if not senders[sender] then
    error(('unknown sender "%s"'):format(tostring(sender)), 0)
  end
  return senders[sender](msg)
end

return M
